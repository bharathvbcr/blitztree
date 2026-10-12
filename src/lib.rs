//! Ultra-fast APFS directory tree scanner using getattrlistbulk(2).
//!
//! getattrlistbulk returns a whole batch of directory entries *with* their
//! metadata (name, type, sizes) per syscall, so we never pay the classic
//! readdir-then-stat-per-file cost that makes naive scanners slow on macOS.

pub mod cleanup;
pub mod ffi;
pub mod ranking;
mod pool;
mod search;
pub use search::{AsciiToken, PatternToken, QueryMatcher};
pub mod types;

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_int, c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

// ---- FFI: getattrlistbulk ----

#[repr(C)]
struct AttrList {
    bitmapcount: u16,
    reserved: u16,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
}

extern "C" {
    fn getattrlistbulk(
        dirfd: c_int,
        attr_list: *mut AttrList,
        attr_buf: *mut c_void,
        attr_buf_size: usize,
        options: u64,
    ) -> c_int;
}

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_NAME: u32 = 0x0000_0001;
const ATTR_CMN_DEVID: u32 = 0x0000_0002;
const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
const ATTR_CMN_FLAGS: u32 = 0x0004_0000;
const ATTR_CMN_FILEID: u32 = 0x0200_0000;
const ATTR_CMN_ERROR: u32 = 0x2000_0000;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
const ATTR_DIR_MOUNTSTATUS: u32 = 0x0000_0004;
const DIR_MNTSTATUS_MNTPOINT: u32 = 0x0000_0001;
const ATTR_FILE_LINKCOUNT: u32 = 0x0000_0001;
const ATTR_FILE_TOTALSIZE: u32 = 0x0000_0002;
const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;
/// With FSOPT_ATTR_CMN_EXTENDED, `forkattr` requests these extended common
/// attributes. They are packed after the file attributes, in bit order.
const FSOPT_ATTR_CMN_EXTENDED: u64 = 0x0000_0020;
const ATTR_CMNEXT_CLONEID: u32 = 0x0000_0100;
const ATTR_CMNEXT_EXT_FLAGS: u32 = 0x0000_0200;
/// The file may share blocks with another (an APFS clone, or a clone's source).
const EF_MAY_SHARE_BLOCKS: u64 = 0x0000_0001;

const VDIR: u32 = 2;
/// Contents live in the cloud (iCloud Drive, File Provider). Opening such a
/// directory asks the provider to materialize it, i.e. download.
const SF_DATALESS: u32 = 0x4000_0000;

const BUF_SIZE: usize = 256 * 1024;

// ---- Tree model ----

pub const NO_PARENT: u32 = u32::MAX;
/// `Tree::flags` bit: the node itself was not fully read (see `Tree::complete`).
/// Kept so a removal can recompute subtree completeness without the walk.
pub const SELF_INCOMPLETE: u8 = 2;

/// The finished tree as flat arrays, the layout the Swift UI reads in place
/// (see app/bz.h). Node 0 is the root; children come after their parent.
#[derive(Default)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
pub struct Tree {
    pub parents: Vec<u32>,
    /// Allocated (on-disk) bytes; subtree totals for directories.
    pub alloc: Vec<u64>,
    /// Logical bytes; subtree totals for directories.
    pub logical: Vec<u64>,
    /// Subtree file count for directories, 0 for files.
    pub n_files: Vec<u32>,
    /// bit0 = is_dir; bit1 (`SELF_INCOMPLETE`, set by `finish`) = this node's
    /// own listing or entry was incomplete, whatever its subtree holds.
    pub flags: Vec<u8>,
    /// False when an entry was unreadable or a cloud/mount boundary was skipped
    /// anywhere in this subtree. The observed sizes then describe a partial walk.
    /// The walk sets each node's own state; `finish` spreads it upward.
    pub complete: Vec<bool>,
    /// Node i's children are children[child_off[i]..child_off[i + 1]],
    /// largest allocated size first (treemap layout order).
    pub child_off: Vec<u32>,
    pub children: Vec<u32>,
    /// Node i's name is name_blob[name_off[i]..name_off[i + 1]], UTF-8.
    pub name_off: Vec<u32>,
    pub name_blob: Vec<u8>,
    pub errors: u64,
}

impl Tree {
    pub fn len(&self) -> usize {
        self.parents.len()
    }
    pub fn is_empty(&self) -> bool {
        self.parents.is_empty()
    }
    pub fn is_dir(&self, i: usize) -> bool {
        self.flags[i] & 1 != 0
    }
    pub fn kids(&self, i: usize) -> &[u32] {
        &self.children[self.child_off[i] as usize..self.child_off[i + 1] as usize]
    }
    fn name_bytes(&self, i: usize) -> &[u8] {
        &self.name_blob[self.name_off[i] as usize..self.name_off[i + 1] as usize]
    }
    /// Names are validated UTF-8 when scanned.
    pub fn name(&self, i: usize) -> &str {
        std::str::from_utf8(self.name_bytes(i)).unwrap_or("")
    }
    pub fn path(&self, mut i: usize) -> PathBuf {
        let mut parts = Vec::new();
        while i != 0 {
            parts.push(self.name(i));
            i = self.parents[i] as usize;
        }
        let mut path = PathBuf::from(self.name(0));
        for part in parts.into_iter().rev() {
            path.push(part);
        }
        path
    }
    /// Compare paths by their components without constructing either path.
    /// Shared ancestors cannot affect ordering: only the first divergent
    /// component matters, and an ancestor sorts before its descendants.
    pub fn compare_paths(&self, mut a: usize, mut b: usize) -> std::cmp::Ordering {
        if a == b {
            return std::cmp::Ordering::Equal;
        }
        if self.parents[a] == self.parents[b] {
            return self.name_bytes(a).cmp(self.name_bytes(b));
        }
        let depth = |mut i: usize| {
            let mut depth = 0;
            while i != 0 {
                depth += 1;
                i = self.parents[i] as usize;
            }
            depth
        };
        let (mut da, mut db) = (depth(a), depth(b));
        let ancestor_order = da.cmp(&db);
        while da > db {
            a = self.parents[a] as usize;
            da -= 1;
        }
        while db > da {
            b = self.parents[b] as usize;
            db -= 1;
        }
        if a == b {
            return ancestor_order;
        }
        while self.parents[a] != self.parents[b] {
            a = self.parents[a] as usize;
            b = self.parents[b] as usize;
        }
        self.name_bytes(a).cmp(self.name_bytes(b))
    }
}

#[derive(Default)]
pub struct Progress {
    pub files: AtomicU64,
    pub dirs: AtomicU64,
    pub bytes: AtomicU64,
    pub errors: AtomicU64,
    pub entry_errors: AtomicU64,
    pub invalid_names: AtomicU64,
    pub skipped_cloud_dirs: AtomicU64,
    pub skipped_mount_points: AtomicU64,
    /// Allocated bytes not counted again because another scanned path
    /// already holds the same data: hard links and whole APFS clones.
    pub shared_bytes: AtomicU64,
    /// Directories whose volume did not report clone ids. Clones there (if
    /// the volume has any) count once per path, as `du` counts them.
    pub clone_ids_unavailable_dirs: AtomicU64,
    /// Set after the volume refused the extended attributes once, so the
    /// remaining directories ask for the plain ones directly.
    no_extended_attrs: std::sync::atomic::AtomicBool,
    /// A stop was asked for (`cancel`). The walk checks it before reading
    /// each directory and between the batches of a large one.
    cancelled: std::sync::atomic::AtomicBool,
    /// The walk really left a directory unread because of `cancelled`. A
    /// stop that arrives after the last directory was read leaves this
    /// false: that tree is whole and is not reported as cut short.
    stopped_early: std::sync::atomic::AtomicBool,
    /// Test seam: cancel once this many directories have been entered (0
    /// is off). Per scan, so parallel tests cannot disturb each other.
    #[cfg(test)]
    cancel_after_dirs: AtomicU64,
}

impl Progress {
    /// Ask the scan to stop. The walk then reads no further directory; every
    /// one it did not read is left incomplete, and `stopped_early` says so.
    /// Safe from any thread, repeatable, and harmless once the walk is over.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    /// Whether a stop cut the walk short, so the tree describes only part of
    /// what was asked for. Final once `scan` has returned.
    pub fn stopped_early(&self) -> bool {
        self.stopped_early.load(Ordering::Acquire)
    }

    /// True (and recorded) when the walk should leave the directory it is
    /// about to read.
    fn stop_here(&self) -> bool {
        #[cfg(test)]
        if self.cancel_after_dirs.load(Ordering::Relaxed) != 0
            && self.cancel_after_dirs.fetch_sub(1, Ordering::Relaxed) == 1
        {
            self.cancel();
        }
        self.stopped()
    }

    /// Whether a stop was asked for, recording that it cut the walk short.
    fn stopped(&self) -> bool {
        let stop = self.is_cancelled();
        if stop {
            self.stopped_early.store(true, Ordering::Release);
        }
        stop
    }
}

/// What a finished scan could and could not read: the one account of
/// coverage, handed to the CLI report and (by value, `#[repr(C)]`) to the app
/// through `bz_coverage`. Built only by `Coverage::of`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Coverage {
    /// Failed reads of every kind: unreadable directories, failed listings,
    /// dropped entries.
    pub errors: u64,
    /// Entries that could not be read or whose record was malformed.
    pub entry_errors: u64,
    /// Entries dropped because their name is not valid UTF-8. They and
    /// anything below them are missing from the tree.
    pub invalid_names: u64,
    /// Cloud-only directories left unread (reading them would download them).
    pub skipped_cloud_directories: u64,
    /// Mount points left unread (a scan measures one volume).
    pub skipped_mount_points: u64,
    /// Allocated bytes not counted again because another scanned path holds
    /// the same data (hard links, whole APFS clones).
    pub shared_allocated_bytes: u64,
    /// Directories whose volume reported no clone ids.
    pub clone_ids_unavailable_directories: u64,
    /// Every directory was read in full: nothing unreadable or skipped.
    pub complete: bool,
    /// A worker pool could not be started when this was built, so work ran on
    /// rayon's global pool and may have been slower (the engine reports it on
    /// stderr too, which a GUI never sees). The results are the same:
    /// `complete` does not depend on it.
    pub workers_degraded: bool,
}

impl Coverage {
    /// The counters of a finished scan with its tree's root state.
    pub fn of(progress: &Progress, tree: &Tree) -> Coverage {
        let count = |c: &AtomicU64| c.load(Ordering::Relaxed);
        Coverage {
            errors: tree.errors,
            entry_errors: count(&progress.entry_errors),
            invalid_names: count(&progress.invalid_names),
            skipped_cloud_directories: count(&progress.skipped_cloud_dirs),
            skipped_mount_points: count(&progress.skipped_mount_points),
            shared_allocated_bytes: count(&progress.shared_bytes),
            clone_ids_unavailable_directories: count(&progress.clone_ids_unavailable_dirs),
            complete: tree.complete.first().copied().unwrap_or(false),
            workers_degraded: pool::degraded(),
        }
    }

    /// The same account for a tree derived from the scanned one (a removal).
    /// Every failed read, dropped entry and skipped folder leaves its folder
    /// incomplete, so a derived tree whose root reads complete has none of
    /// them left: the error- and skip-class counters are zero, and the
    /// account never says "read in full" next to "N items unreadable". The
    /// per-folder counts are not kept, so while any folder is still partial
    /// the scan's counters stay as scanned (upper bounds: a removed folder
    /// may have held some of them). Sharing figures describe data, not
    /// unread items, and stay.
    pub fn for_derived(&self, tree: &Tree) -> Coverage {
        if tree.complete.first().copied().unwrap_or(false) {
            Coverage {
                shared_allocated_bytes: self.shared_allocated_bytes,
                clone_ids_unavailable_directories: self.clone_ids_unavailable_directories,
                complete: true,
                workers_degraded: self.workers_degraded,
                ..Coverage::default()
            }
        } else {
            Coverage {
                complete: false,
                ..*self
            }
        }
    }
}

/// Identifies the data a file's allocated bytes belong to, for files that
/// may share them with another path. All hard links of an inode, and every
/// full APFS clone of a file, share one clone id: one data stream. A file
/// edited after cloning gets its own clone id and is counted in full.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct DataStream {
    dev: u32,
    id: u64,
    /// `id` is an APFS clone id rather than a file id; the two are kept apart
    /// so a volume that reports clone ids for only some entries can't merge
    /// unrelated files.
    by_clone_id: bool,
}

struct Entry {
    /// End of this entry's name in `Scratch::names` (it starts where the
    /// previous one ends).
    name_end: u32,
    is_dir: bool,
    /// Contents live in the cloud; not descended (that would download them).
    dataless: bool,
    /// Another volume is mounted here (a disk image, Recovery, a simulator
    /// runtime, autofs). Not descended: a scan measures one volume.
    mount_point: bool,
    size: u64,
    alloc: u64,
    /// Set when the file has more than one hard link or may share blocks
    /// with a clone, so its bytes are counted once per data stream.
    stream: Option<DataStream>,
    /// The volume reported no clone id for this file.
    no_clone_id: bool,
    /// The volume listed the file without its allocated size.
    alloc_missing: bool,
}

impl Entry {
    fn descend(&self) -> bool {
        self.is_dir && !self.dataless && !self.mount_point
    }
}

/// Per-thread buffers reused for every directory, so reading one allocates nothing.
#[derive(Default)]
struct Scratch {
    buf: Vec<u8>,
    entries: Vec<Entry>,
    names: Vec<u8>,
}

thread_local! {
    static SCRATCH: RefCell<Scratch> = RefCell::default();
}

/// Whether `BZ_LOG_ERRORS` is set: unreadable directories, failed reads and
/// dropped entries are then reported on stderr. Read once.
fn log_errors_enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("BZ_LOG_ERRORS").is_some())
}

fn log_error(message: impl FnOnce() -> String) {
    if log_errors_enabled() {
        eprintln!("[bz] {}", message());
    }
}

/// How many times in a row an interrupted `getattrlistbulk` is asked again
/// before the directory is reported partial.
const MAX_INTERRUPTS: u32 = 8;

/// Run `call` again while it fails with EINTR or EAGAIN, at most
/// `MAX_INTERRUPTS` times in a row. The last result (and its `errno`) is
/// returned untouched.
fn retry_interrupted(mut call: impl FnMut() -> c_int) -> c_int {
    let mut n = call();
    for _ in 0..MAX_INTERRUPTS {
        if n >= 0 || !matches!(std::io::Error::last_os_error().raw_os_error(), Some(libc::EINTR | libc::EAGAIN)) {
            break;
        }
        n = call();
    }
    n
}

/// # Safety
/// `fd` is an open directory and `buf` holds `BUF_SIZE` writable bytes.
unsafe fn bulk_syscall(fd: c_int, attrlist: &mut AttrList, buf: *mut c_void, options: u64) -> c_int {
    #[cfg(test)]
    if tests::take_injected_interrupt() {
        *libc::__error() = libc::EINTR;
        return -1;
    }
    #[cfg(test)]
    if let Some(errno) = volume_tests::injected_failure(options) {
        *libc::__error() = errno;
        return -1;
    }
    getattrlistbulk(fd, attrlist, buf, BUF_SIZE, options)
}

/// Read all entries of one directory in bulk into `s`. None if it can't be
/// opened, else whether every entry was read.
fn read_dir_bulk(path: &CStr, s: &mut Scratch, progress: &Progress) -> Option<bool> {
    s.entries.clear();
    s.names.clear();
    if s.buf.is_empty() {
        s.buf = vec![0u8; BUF_SIZE];
    }
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        progress.errors.fetch_add(1, Ordering::Relaxed);
        log_error(|| format!("skip {} ({})", path.to_string_lossy(), std::io::Error::last_os_error()));
        return None;
    }

    let mut attrlist = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | ATTR_CMN_NAME
            | ATTR_CMN_DEVID
            | ATTR_CMN_OBJTYPE
            | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID,
        volattr: 0,
        dirattr: ATTR_DIR_MOUNTSTATUS,
        fileattr: ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE,
        forkattr: ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS,
    };
    let mut options = FSOPT_ATTR_CMN_EXTENDED;
    if progress.no_extended_attrs.load(Ordering::Relaxed) {
        (attrlist.forkattr, options) = (0, 0);
    }

    let mut complete = true;
    let mut read_any = false;
    loop {
        // A directory of millions of entries is read in many batches: a stop
        // does not wait for the last one. What was listed so far is kept.
        if read_any && progress.stopped() {
            complete = false;
            break;
        }
        let n = retry_interrupted(|| unsafe {
            bulk_syscall(fd, &mut attrlist, s.buf.as_mut_ptr() as *mut c_void, options)
        });
        if n < 0
            && options != 0
            && !read_any
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINVAL)
        {
            // A file system without extended common attributes. Nothing was
            // consumed yet, so ask again for the plain set; clones there are
            // counted per path and reported as untracked.
            progress.no_extended_attrs.store(true, Ordering::Relaxed);
            (attrlist.forkattr, options) = (0, 0);
            continue;
        }
        if n <= 0 {
            if n < 0 {
                progress.errors.fetch_add(1, Ordering::Relaxed);
                complete = false;
                log_error(|| format!("read {} ({})", path.to_string_lossy(), std::io::Error::last_os_error()));
            }
            break;
        }
        read_any = true;
        complete &= parse_batch(
            &s.buf,
            n as usize,
            &mut s.entries,
            &mut s.names,
            progress,
            path,
        );
    }
    complete &= fill_missing_alloc(fd, s, progress);
    unsafe { libc::close(fd) };
    Some(complete)
}

/// Parse the `n` records one `getattrlistbulk` call put in `buf`. False if any
/// entry had to be dropped (unreadable, malformed, or a name that is not
/// UTF-8: it and everything below it are then missing from the tree, so its
/// directory is incomplete).
fn parse_batch(
    buf: &[u8],
    n: usize,
    entries: &mut Vec<Entry>,
    names: &mut Vec<u8>,
    progress: &Progress,
    path: &CStr,
) -> bool {
    let mut complete = true;
    let mut off = 0usize;
    for _ in 0..n {
        // A record must hold its own length and fit in the buffer.
        let len = buf
            .get(off..off + 4)
            .map_or(0, |_| u32_at(buf, off) as usize);
        let Some(record) = buf.get(off..off + len).filter(|_| len >= 4) else {
            progress.entry_errors.fetch_add(1, Ordering::Relaxed);
            progress.errors.fetch_add(1, Ordering::Relaxed);
            log_error(|| format!("malformed record list in {}", path.to_string_lossy()));
            return false;
        };
        if !parse_entry(record, entries, names, progress) {
            complete = false;
            log_error(|| {
                format!(
                    "entry dropped in {} (unreadable, malformed or non-UTF-8 name)",
                    path.to_string_lossy()
                )
            });
        }
        off += len;
    }
    complete
}

/// Some file systems (FAT32 through FSKit) list files without their
/// allocated size. Ask for each such file's blocks instead of counting it
/// as empty. False if any could not be read; those keep their logical size.
fn fill_missing_alloc(dir_fd: c_int, s: &mut Scratch, progress: &Progress) -> bool {
    let mut complete = true;
    let mut start = 0;
    let mut path = Vec::new();
    for e in s.entries.iter_mut() {
        let name = &s.names[start..e.name_end as usize];
        start = e.name_end as usize;
        if !e.alloc_missing {
            continue;
        }
        path.clear();
        path.extend_from_slice(name);
        path.push(0);
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        let status = unsafe {
            libc::fstatat(dir_fd, path.as_ptr().cast(), &mut st, libc::AT_SYMLINK_NOFOLLOW)
        };
        if status == 0 {
            e.alloc = (st.st_blocks.max(0) as u64).saturating_mul(512);
        } else {
            progress.entry_errors.fetch_add(1, Ordering::Relaxed);
            progress.errors.fetch_add(1, Ordering::Relaxed);
            e.alloc = e.size;
            complete = false;
            log_error(|| format!("stat {} ({})", String::from_utf8_lossy(name), std::io::Error::last_os_error()));
        }
    }
    complete
}

fn u32_at(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}

fn i64_at(b: &[u8], off: usize) -> i64 {
    i64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

fn u64_at(b: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

/// Parse one getattrlistbulk entry. Attribute order within an entry is fixed:
/// RETURNED_ATTRS, ERROR, then common attrs by bit (NAME, DEVID, OBJTYPE,
/// FLAGS, FILEID), then dir attrs (MOUNTSTATUS), then file attrs (LINKCOUNT,
/// TOTALSIZE, ALLOCSIZE), then extended common attrs (CLONEID, EXT_FLAGS).
/// Dir attrs come back only for directories and file attrs only for files;
/// each group is read only when RETURNED_ATTRS says it is there. False (and
/// counted) if the entry had to be dropped.
fn parse_entry(e: &[u8], out: &mut Vec<Entry>, names: &mut Vec<u8>, progress: &Progress) -> bool {
    let malformed = || {
        progress.entry_errors.fetch_add(1, Ordering::Relaxed);
        progress.errors.fetch_add(1, Ordering::Relaxed);
        false
    };
    let mut off = 4usize; // skip length
    if e.len() < off + 20 {
        return malformed();
    }
    let ret_common = u32_at(e, off);
    let ret_dir = u32_at(e, off + 8);
    let ret_file = u32_at(e, off + 12);
    let ret_ext = u32_at(e, off + 16);
    off += 20; // attribute_set_t: 5 x u32
    // Every fixed-size field the entry claims must fit inside it; the parse
    // below then reads only within `e`.
    let fixed: usize = [
        (ret_common & ATTR_CMN_ERROR, 4),
        (ret_common & ATTR_CMN_NAME, 8),
        (ret_common & ATTR_CMN_DEVID, 4),
        (ret_common & ATTR_CMN_OBJTYPE, 4),
        (ret_common & ATTR_CMN_FLAGS, 4),
        (ret_common & ATTR_CMN_FILEID, 8),
        (ret_dir & ATTR_DIR_MOUNTSTATUS, 4),
        (ret_file & ATTR_FILE_LINKCOUNT, 4),
        (ret_file & ATTR_FILE_TOTALSIZE, 8),
        (ret_file & ATTR_FILE_ALLOCSIZE, 8),
        (ret_ext & ATTR_CMNEXT_CLONEID, 8),
        (ret_ext & ATTR_CMNEXT_EXT_FLAGS, 8),
    ]
    .iter()
    .filter(|(bit, _)| *bit != 0)
    .map(|(_, len)| len)
    .sum();
    if e.len() < off + fixed {
        return malformed();
    }

    if ret_common & ATTR_CMN_ERROR != 0 {
        let err = u32_at(e, off);
        off += 4;
        if err != 0 {
            progress.entry_errors.fetch_add(1, Ordering::Relaxed);
            progress.errors.fetch_add(1, Ordering::Relaxed);
            return false;
        }
    }

    let invalid_name = || {
        progress.invalid_names.fetch_add(1, Ordering::Relaxed);
        progress.errors.fetch_add(1, Ordering::Relaxed);
        false
    };
    let mut name: &[u8] = &[];
    if ret_common & ATTR_CMN_NAME != 0 {
        let data_off = u32_at(e, off) as i32 as isize;
        let data_len = u32_at(e, off + 4) as usize;
        // data_len includes the trailing NUL
        let range = (off as isize)
            .checked_add(data_off)
            .and_then(|start| usize::try_from(start).ok())
            .and_then(|start| Some(start..start.checked_add(data_len.saturating_sub(1))?));
        let Some(name_bytes) = range.and_then(|r| e.get(r)) else {
            return malformed();
        };
        name = name_bytes;
        if std::str::from_utf8(name).is_err() {
            return invalid_name();
        }
        off += 8;
    }

    let mut dev = 0u32;
    if ret_common & ATTR_CMN_DEVID != 0 {
        dev = u32_at(e, off);
        off += 4;
    }

    let mut is_dir = false;
    if ret_common & ATTR_CMN_OBJTYPE != 0 {
        is_dir = u32_at(e, off) == VDIR;
        off += 4;
    }

    let mut flags = 0u32;
    if ret_common & ATTR_CMN_FLAGS != 0 {
        flags = u32_at(e, off);
        off += 4;
    }

    let mut file_id = 0u64;
    if ret_common & ATTR_CMN_FILEID != 0 {
        file_id = u64_at(e, off);
        off += 8;
    }

    let mut mount_point = false;
    if ret_dir & ATTR_DIR_MOUNTSTATUS != 0 {
        mount_point = u32_at(e, off) & DIR_MNTSTATUS_MNTPOINT != 0;
        off += 4;
    }

    let mut links = 1u32;
    if ret_file & ATTR_FILE_LINKCOUNT != 0 {
        links = u32_at(e, off);
        off += 4;
    }

    let mut size = 0u64;
    let mut alloc = 0u64;
    if ret_file & ATTR_FILE_TOTALSIZE != 0 {
        size = i64_at(e, off).max(0) as u64;
        off += 8;
    }
    if ret_file & ATTR_FILE_ALLOCSIZE != 0 {
        alloc = i64_at(e, off).max(0) as u64;
        off += 8;
    }

    let mut clone_id = None;
    if ret_ext & ATTR_CMNEXT_CLONEID != 0 {
        clone_id = Some(u64_at(e, off)).filter(|&id| id != 0);
        off += 8;
    }
    // Without the flag, sharing is unknown: only hard links are deduplicated.
    let mut may_share = false;
    if ret_ext & ATTR_CMNEXT_EXT_FLAGS != 0 {
        may_share = u64_at(e, off) & EF_MAY_SHARE_BLOCKS != 0;
    }

    if name.is_empty() {
        return invalid_name();
    }
    let before = names.len();
    names.extend_from_slice(name);
    let Ok(name_end) = u32::try_from(names.len()) else {
        names.truncate(before);
        return malformed();
    };
    let key = match clone_id {
        Some(id) => DataStream { dev, id, by_clone_id: true },
        None => DataStream { dev, id: file_id, by_clone_id: false },
    };
    let stream = (!is_dir && (links > 1 || (may_share && clone_id.is_some()))).then_some(key);
    out.push(Entry {
        name_end,
        is_dir,
        dataless: flags & SF_DATALESS != 0,
        mount_point,
        size,
        alloc,
        stream,
        no_clone_id: !is_dir && clone_id.is_none(),
        alloc_missing: !is_dir && ret_file & ATTR_FILE_ALLOCSIZE == 0,
    });
    true
}

// ---- Parallel walk ----

/// The tree as the walk grows it: every field of `Tree` except n_files,
/// child_off and children, which `finish` derives. A directory's entries are
/// appended under one short lock, so its children get one contiguous run of
/// indices, and no node owns a heap allocation.
struct Arena {
    tree: Tree,
    /// Attribute a data stream's bytes (an inode's hard links, or a family of
    /// whole APFS clones) to its lexicographically first scanned path,
    /// independently of worker scheduling. This is accounting, not an estimate
    /// of how many bytes deleting any one of those paths would reclaim.
    streams: HashMap<DataStream, u32>,
}

impl Arena {
    /// Called under the arena lock after appending a file, before totals are
    /// aggregated. Returns newly accounted bytes for the progress counter.
    fn account_file(&mut self, i: u32, stream: Option<DataStream>) -> u64 {
        let t = &mut self.tree;
        let Some(key) = stream else {
            return t.alloc[i as usize];
        };
        let Some(&previous) = self.streams.get(&key) else {
            self.streams.insert(key, i);
            return t.alloc[i as usize];
        };
        let (i, previous) = (i as usize, previous as usize);
        let loser = if t.compare_paths(i, previous).is_lt() {
            t.logical[i] = t.logical[previous];
            t.alloc[i] = t.alloc[previous];
            self.streams.insert(key, i as u32);
            previous
        } else {
            i
        };
        t.logical[loser] = 0;
        t.alloc[loser] = 0;
        0
    }
}

/// How much the tree's 32-bit ABI columns can hold: node numbers, and the
/// end offsets into the name blob. A walk that would pass either leaves that
/// directory unlisted and marks it incomplete instead of letting a count wrap.
/// Within these bounds the derived columns cannot wrap either: `n_files` and
/// `child_off` never exceed the node count.
#[derive(Clone, Copy)]
struct Limits {
    nodes: u64,
    name_bytes: u64,
}

impl Limits {
    const ABI: Limits = Limits { nodes: u32::MAX as u64, name_bytes: u32::MAX as u64 };
}

struct Shared<'a> {
    arena: Mutex<Arena>,
    progress: &'a Progress,
    limits: Limits,
}

impl Shared<'_> {
    fn mark_incomplete(&self, i: u32) {
        self.arena.lock().unwrap().tree.complete[i as usize] = false;
    }
}

fn child_path(dir: &CStr, name: &[u8]) -> Option<CString> {
    let dir = dir.to_bytes();
    let mut p = Vec::with_capacity(dir.len() + name.len() + 2);
    p.extend_from_slice(dir);
    if dir.last() != Some(&b'/') {
        p.push(b'/');
    }
    p.extend_from_slice(name);
    CString::new(p).ok()
}

fn walk<'s>(scope: &rayon::Scope<'s>, shared: &'s Shared<'s>, path: CString, dir_idx: u32) {
    #[cfg(test)]
    tests::inject_scan_fault(&path);
    // A stop leaves this directory unread: it is incomplete, and its
    // children, if any, were never listed.
    if shared.progress.stop_here() {
        shared.mark_incomplete(dir_idx);
        return;
    }
    // Nothing below runs another job on this thread (spawn only queues), so
    // the borrow can't nest.
    SCRATCH.with_borrow_mut(|s| {
        let progress = shared.progress;
        let Some(complete) = read_dir_bulk(&path, s, progress) else {
            shared.mark_incomplete(dir_idx);
            return;
        };
        let Scratch { entries, names, .. } = s;
        if entries.is_empty() {
            if !complete {
                shared.mark_incomplete(dir_idx);
            }
            return;
        }

        let mut n_files = 0u64;
        let mut n_dirs = 0u64;
        for e in entries.iter() {
            if !e.is_dir {
                n_files += 1;
                continue;
            }
            n_dirs += 1;
            if e.mount_point {
                progress.skipped_mount_points.fetch_add(1, Ordering::Relaxed);
            } else if e.dataless {
                progress.skipped_cloud_dirs.fetch_add(1, Ordering::Relaxed);
            }
        }

        let appended = {
            let mut arena = shared.arena.lock().unwrap();
            let t = &mut arena.tree;
            let limits = shared.limits;
            let fits = t.parents.len() as u64 + entries.len() as u64 <= limits.nodes
                && t.name_blob.len() as u64 + names.len() as u64 <= limits.name_bytes;
            if !fits {
                t.complete[dir_idx as usize] = false;
                None
            } else {
                t.complete[dir_idx as usize] = complete;
                // `fits` bounds every count below by `u32::MAX`.
                let base = t.parents.len() as u32;
                t.parents.extend(std::iter::repeat_n(dir_idx, entries.len()));
                t.alloc.extend(entries.iter().map(|e| e.alloc));
                t.logical.extend(entries.iter().map(|e| e.size));
                t.flags.extend(entries.iter().map(|e| e.is_dir as u8));
                t.complete.extend(entries.iter().map(|e| !e.is_dir || e.descend()));
                let blob = t.name_blob.len() as u32;
                t.name_off.extend(entries.iter().map(|e| blob + e.name_end));
                t.name_blob.extend_from_slice(names);
                let mut bytes = 0;
                let mut shared_bytes = 0;
                for (k, e) in entries.iter().enumerate() {
                    if !e.is_dir {
                        let added = arena.account_file(base + k as u32, e.stream);
                        bytes += added;
                        shared_bytes += e.alloc - added;
                    }
                }
                progress.shared_bytes.fetch_add(shared_bytes, Ordering::Relaxed);
                Some((base, bytes))
            }
        };
        let Some((base, bytes)) = appended else {
            progress.errors.fetch_add(1, Ordering::Relaxed);
            log_error(|| format!("tree too large for the 32-bit layout; {} left unlisted", path.to_string_lossy()));
            return;
        };
        progress.files.fetch_add(n_files, Ordering::Relaxed);
        progress.dirs.fetch_add(n_dirs, Ordering::Relaxed);
        progress.bytes.fetch_add(bytes, Ordering::Relaxed);
        if entries.iter().any(|e| e.no_clone_id) {
            progress.clone_ids_unavailable_dirs.fetch_add(1, Ordering::Relaxed);
        }

        let mut start = 0;
        for (i, e) in entries.iter().enumerate() {
            if e.descend() {
                let idx = base + i as u32;
                match child_path(&path, &names[start..e.name_end as usize]) {
                    Some(child) => scope.spawn(move |sc| walk(sc, shared, child, idx)),
                    None => {
                        progress.errors.fetch_add(1, Ordering::Relaxed);
                        shared.mark_incomplete(idx);
                    }
                }
            }
            start = e.name_end as usize;
        }
    });
}

/// Each directory's children form one run of equal parents: `(parent, first, len)`.
fn runs(parents: &[u32]) -> Vec<(u32, u32, u32)> {
    let mut out = Vec::new();
    let mut i = 1;
    while i < parents.len() {
        let j = i + parents[i..].iter().take_while(|&&p| p == parents[i]).count();
        out.push((parents[i], i as u32, (j - i) as u32));
        i = j;
    }
    out
}

/// Derive subtree totals and the sorted child lists from the walk's arrays.
fn finish(t: &mut Tree) {
    // `complete` still holds each node's own state: record it before it is
    // folded into the subtree's.
    for (f, &c) in t.flags.iter_mut().zip(&t.complete) {
        if !c {
            *f |= SELF_INCOMPLETE;
        }
    }
    let runs = runs(&t.parents);
    // Bottom-up: a directory's run starts after its parent's run, so reverse
    // run order finishes every child before its parent.
    t.n_files = vec![0u32; t.len()];
    for &(p, first, len) in runs.iter().rev() {
        let (mut a, mut l, mut f, mut c) = (0u64, 0u64, 0u32, true);
        for i in first as usize..(first + len) as usize {
            a += t.alloc[i];
            l += t.logical[i];
            f += if t.is_dir(i) { t.n_files[i] } else { 1 };
            c &= t.complete[i];
        }
        let p = p as usize;
        t.alloc[p] += a;
        t.logical[p] += l;
        t.n_files[p] += f;
        t.complete[p] &= c;
    }
    link(t, &runs);
}

/// child_off and children, largest first (treemap layout order).
fn link(t: &mut Tree, runs: &[(u32, u32, u32)]) {
    let n = t.len();
    t.child_off = vec![0u32; n + 1];
    for &(p, _, len) in runs {
        t.child_off[p as usize] = len;
    }
    let mut acc = 0u32;
    for c in &mut t.child_off {
        (*c, acc) = (acc, acc + *c);
    }
    t.children = vec![0u32; n.saturating_sub(1)];
    for &(p, first, len) in runs {
        let at = t.child_off[p as usize] as usize;
        let kids = &mut t.children[at..at + len as usize];
        for (k, c) in kids.iter_mut().enumerate() {
            *c = first + k as u32;
        }
        kids.sort_unstable_by_key(|&c| std::cmp::Reverse(t.alloc[c as usize]));
    }
}

impl Tree {
    /// A new tree without `nodes` and everything under them, for the UI to
    /// swap in after files were deleted: this tree is read-only once handed
    /// over, so a removal builds a copy instead of editing it. Each removed
    /// subtree's bytes and files are taken off every ancestor, and the rest
    /// is renumbered in the old order, which keeps parents before children
    /// and each directory's children in one run. The root, indices out of
    /// range and repeats are ignored; a node inside another chosen node
    /// counts once, in the outer one's total.
    ///
    /// Hard links and clone families follow the scan's accounting: a stream's
    /// bytes sit on one path, so removing the others subtracts nothing and
    /// removing that one subtracts them all, even if another link survives
    /// and still holds the data on disk. The scan does not keep which paths
    /// share a stream, so the bytes are not handed to a survivor.
    ///
    /// `complete` is recomputed from each survivor's own state (the
    /// `SELF_INCOMPLETE` flag), so a folder whose only partial subtree went
    /// reads complete again. `errors` counts the scan's failed reads and is
    /// kept as scanned. Needs a finished tree (totals and child lists built).
    pub fn without(&self, nodes: &[u32]) -> Tree {
        let n = self.len();
        // NO_PARENT marks a removed node; the rest get their new number.
        let mut renumber = vec![0u32; n];
        for &c in nodes {
            if c != 0 && (c as usize) < n {
                renumber[c as usize] = NO_PARENT;
            }
        }
        let mut t = Tree {
            parents: Vec::with_capacity(n),
            alloc: Vec::with_capacity(n),
            logical: Vec::with_capacity(n),
            n_files: Vec::with_capacity(n),
            flags: Vec::with_capacity(n),
            complete: Vec::with_capacity(n),
            name_off: Vec::with_capacity(n + 1),
            name_blob: Vec::with_capacity(self.name_blob.len()),
            errors: self.errors,
            ..Default::default()
        };
        t.name_off.push(0);
        // One forward pass copies the survivors. Parents come first, so a
        // parent's fate is known when its child is reached: a removed parent
        // takes the child with it, and a chosen node under a surviving parent
        // is an outermost one, whose totals leave its ancestors.
        let mut tops = Vec::new();
        for i in 0..n {
            let parent = self.parents[i];
            let parent_gone = parent != NO_PARENT && renumber[parent as usize] == NO_PARENT;
            if renumber[i] == NO_PARENT || parent_gone {
                if !parent_gone {
                    tops.push(i);
                }
                renumber[i] = NO_PARENT;
                continue;
            }
            renumber[i] = t.parents.len() as u32;
            t.parents.push(if parent == NO_PARENT { parent } else { renumber[parent as usize] });
            t.alloc.push(self.alloc[i]);
            t.logical.push(self.logical[i]);
            t.n_files.push(self.n_files[i]);
            t.flags.push(self.flags[i]);
            t.complete.push(self.flags[i] & SELF_INCOMPLETE == 0);
            t.name_blob.extend_from_slice(self.name_bytes(i));
            t.name_off.push(t.name_blob.len() as u32);
        }
        // Ancestors of a removed node all survive (it is outermost).
        for &top in &tops {
            let files = if self.is_dir(top) { self.n_files[top] } else { 1 };
            let mut up = self.parents[top];
            while up != NO_PARENT {
                let a = renumber[up as usize] as usize;
                t.alloc[a] = t.alloc[a].saturating_sub(self.alloc[top]);
                t.logical[a] = t.logical[a].saturating_sub(self.logical[top]);
                t.n_files[a] = t.n_files[a].saturating_sub(files);
                up = self.parents[up as usize];
            }
        }
        let runs = runs(&t.parents);
        // Bottom-up, as in `finish`: every child's run before its parent's.
        for &(p, first, len) in runs.iter().rev() {
            let c = t.complete[first as usize..(first + len) as usize].iter().all(|&c| c);
            t.complete[p as usize] &= c;
        }
        link(&mut t, &runs);
        t
    }
}

/// Hand-built trees for tests.
#[cfg(test)]
impl Tree {
    pub(crate) fn with_root(name: &str) -> Tree {
        let mut t = Tree { name_off: vec![0], ..Default::default() };
        t.push(name, NO_PARENT, 0, 0, true);
        t
    }
    /// Append a node as the walk does: each directory's children in one batch.
    pub(crate) fn push(&mut self, name: &str, parent: u32, logical: u64, alloc: u64, is_dir: bool) -> u32 {
        self.parents.push(parent);
        self.logical.push(logical);
        self.alloc.push(alloc);
        self.flags.push(is_dir as u8);
        self.complete.push(true);
        self.name_blob.extend_from_slice(name.as_bytes());
        self.name_off.push(self.name_blob.len() as u32);
        self.parents.len() as u32 - 1
    }
    /// Child lists only, keeping the sizes as given.
    pub(crate) fn link_children(&mut self) {
        let runs = runs(&self.parents);
        link(self, &runs);
    }
}

/// The directory a scan of `p` reads: `p` made absolute with every symbolic
/// link in it followed, since the walk opens directories without following
/// links. The scan root and the CLI both resolve through this.
///
/// Each ancestor is checked before resolving deeper: canonicalize/read_dir on
/// a cloud-only directory can ask its provider to materialize that directory,
/// so a cloud-only path is refused instead.
///
/// At most `MAX_SYMLINK_HOPS` links are followed in total (the kernel's
/// `MAXSYMLINKS`), however they nest, so a looping or doubling chain fails
/// at once instead of walking for ever.
///
/// A scan keeps the name it was given for its root, not this resolved path,
/// so for a tree scanned through a symlinked root Clean Up's rules, which
/// compare resolved paths, match nothing and every action is refused (fail
/// closed).
pub fn local_path(p: &Path) -> Result<PathBuf, String> {
    local_path_at(p, &mut 0)
}

/// Symbolic links `local_path` follows before giving up (ELOOP).
const MAX_SYMLINK_HOPS: u32 = 32;

fn local_path_at(p: &Path, hops: &mut u32) -> Result<PathBuf, String> {
    use std::os::macos::fs::MetadataExt;
    use std::path::Component;
    let absolute = if p.is_absolute() {
        p.to_owned()
    } else {
        std::env::current_dir().map_err(|e| e.to_string())?.join(p)
    };
    let mut resolved = PathBuf::from("/");
    let mut is_directory = true;
    for component in absolute.components() {
        if !is_directory {
            return Err(format!("Not a directory: {}", resolved.display()));
        }
        match component {
            Component::RootDir | Component::CurDir => continue,
            Component::ParentDir => {
                resolved.pop();
                continue;
            }
            Component::Normal(part) => resolved.push(part),
            _ => return Err("Unsupported path prefix".into()),
        }
        let m = std::fs::symlink_metadata(&resolved)
            .map_err(|e| format!("Cannot resolve {}: {e}", resolved.display()))?;
        if m.st_flags() & SF_DATALESS != 0 {
            return Err(format!("Cloud-only path; refusing to materialize {}", resolved.display()));
        }
        if m.file_type().is_symlink() {
            *hops += 1;
            if *hops > MAX_SYMLINK_HOPS {
                return Err(format!("Too many levels of symbolic links: {}", resolved.display()));
            }
            let target = std::fs::read_link(&resolved).map_err(|e| e.to_string())?;
            let target = if target.is_absolute() {
                target
            } else {
                resolved.parent().unwrap_or(Path::new("/")).join(target)
            };
            resolved = local_path_at(&target, hops)?;
            is_directory = std::fs::metadata(&resolved).map_err(|e| e.to_string())?.is_dir();
        } else {
            is_directory = m.is_dir();
        }
    }
    Ok(resolved)
}

/// Scan `root` and return the finished tree, ready for the UI. A symlinked
/// root is followed (see `local_path`); the root node keeps the name it was
/// given, as far as it is UTF-8 (the path that is read is always exact). A
/// root that cannot be resolved is counted as an error and left unread. Since
/// the root keeps its given name, Clean Up refuses every action in a tree
/// scanned through a symlinked root (it fails closed); scan the resolved path
/// for a tree it can act on.
pub fn scan(root: &Path, progress: &Progress) -> Tree {
    scan_with(root, progress, Limits::ABI)
}

/// `scan` for a root already resolved by `local_path`: it is not resolved again.
pub fn scan_resolved(root: &Path, progress: &Progress) -> Tree {
    scan_at(root, || Ok(root.to_path_buf()), progress, Limits::ABI)
}

fn scan_with(root: &Path, progress: &Progress, limits: Limits) -> Tree {
    scan_at(root, || local_path(root), progress, limits)
}

fn scan_at(
    root: &Path,
    resolve: impl FnOnce() -> Result<PathBuf, String>,
    progress: &Progress,
    limits: Limits,
) -> Tree {
    let root_name = root.to_string_lossy();
    let root_name = if u32::try_from(root_name.len()).is_ok() { root_name.as_bytes() } else { &[] };
    let tree = Tree {
        parents: vec![NO_PARENT],
        alloc: vec![0],
        logical: vec![0],
        flags: vec![1],
        complete: vec![true],
        name_off: vec![0, root_name.len() as u32],
        name_blob: root_name.to_vec(),
        ..Default::default()
    };
    let shared = Shared {
        arena: Mutex::new(Arena {
            tree,
            streams: HashMap::new(),
        }),
        progress,
        limits,
    };

    let t0 = std::time::Instant::now();
    use std::os::macos::fs::MetadataExt;
    let root_is_cloud_only =
        std::fs::symlink_metadata(root).is_ok_and(|m| m.st_flags() & SF_DATALESS != 0);
    if root_is_cloud_only {
        progress.skipped_cloud_dirs.fetch_add(1, Ordering::Relaxed);
        shared.mark_incomplete(0);
    } else {
        let target = resolve().and_then(|resolved| {
            CString::new(resolved.as_os_str().as_encoded_bytes())
                .map_err(|_| "The scan root contains a NUL byte".to_string())
        });
        match target {
            Ok(path) => pool::run(pool::Role::Scan, || {
                rayon::scope(|s| walk(s, &shared, path, 0))
            }),
            Err(reason) => {
                progress.errors.fetch_add(1, Ordering::Relaxed);
                shared.mark_incomplete(0);
                log_error(|| format!("skip {} ({reason})", root.to_string_lossy()));
            }
        }
    }
    let t1 = std::time::Instant::now();
    let mut tree = shared.arena.into_inner().unwrap().tree;
    finish(&mut tree);
    tree.errors = progress.errors.load(Ordering::Relaxed);
    if std::env::var_os("BZ_TIMING").is_some() {
        eprintln!(
            "[bz] walk {:.3}s  finish {:.1}ms  ({} nodes, {} workers)",
            (t1 - t0).as_secs_f64(),
            t1.elapsed().as_secs_f64() * 1e3,
            tree.len(),
            pool::threads()
        );
    }
    tree
}

/// Count-only walk with no tree building: measures the pure syscall floor.
pub fn scan_count(root: &Path, progress: &Progress) {
    fn go<'s>(scope: &rayon::Scope<'s>, progress: &'s Progress, dir: CString) {
        SCRATCH.with_borrow_mut(|s| {
            if read_dir_bulk(&dir, s, progress).is_none() {
                return;
            }
            let (mut start, mut n_files, mut n_dirs, mut bytes) = (0, 0u64, 0u64, 0u64);
            for e in &s.entries {
                if e.is_dir {
                    n_dirs += 1;
                    if e.descend() {
                        if let Some(p) = child_path(&dir, &s.names[start..e.name_end as usize]) {
                            scope.spawn(move |sc| go(sc, progress, p));
                        }
                    }
                } else {
                    n_files += 1;
                    bytes += e.alloc;
                }
                start = e.name_end as usize;
            }
            progress.files.fetch_add(n_files, Ordering::Relaxed);
            progress.dirs.fetch_add(n_dirs, Ordering::Relaxed);
            progress.bytes.fetch_add(bytes, Ordering::Relaxed);
        });
    }
    if let Ok(path) = CString::new(root.as_os_str().as_encoded_bytes()) {
        rayon::scope(|s| go(s, progress, path));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bulk_record(
        name: impl AsRef<[u8]>,
        is_dir: bool,
        flags: u32,
        mount_status: u32,
        links: u32,
        ext: Option<(u64, u64)>,
    ) -> Vec<u8> {
        let name = name.as_ref();
        let mut e = vec![0u8; 4];
        let common = ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | ATTR_CMN_NAME
            | ATTR_CMN_DEVID
            | ATTR_CMN_OBJTYPE
            | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID;
        let dir = if is_dir { ATTR_DIR_MOUNTSTATUS } else { 0 };
        let file = if is_dir {
            0
        } else {
            ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE
        };
        let ext_bits = if ext.is_some() { ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS } else { 0 };
        for value in [common, 0, dir, file, ext_bits, 0] {
            e.extend_from_slice(&value.to_le_bytes());
        }
        let name_ref = e.len();
        e.extend_from_slice(&[0u8; 8]);
        for value in [17u32, if is_dir { VDIR } else { 1 }, flags] {
            e.extend_from_slice(&value.to_le_bytes());
        }
        e.extend_from_slice(&123456u64.to_le_bytes());
        if is_dir {
            e.extend_from_slice(&mount_status.to_le_bytes());
        } else {
            e.extend_from_slice(&links.to_le_bytes());
            e.extend_from_slice(&12345i64.to_le_bytes());
            e.extend_from_slice(&16384i64.to_le_bytes());
        }
        if let Some((clone_id, ext_flags)) = ext {
            e.extend_from_slice(&clone_id.to_le_bytes());
            e.extend_from_slice(&ext_flags.to_le_bytes());
        }
        let name_offset = (e.len() - name_ref) as u32;
        e[name_ref..name_ref + 4].copy_from_slice(&name_offset.to_le_bytes());
        e[name_ref + 4..name_ref + 8].copy_from_slice(&(name.len() as u32 + 1).to_le_bytes());
        e.extend_from_slice(name);
        e.push(0);
        let len = e.len() as u32;
        e[..4].copy_from_slice(&len.to_le_bytes());
        e
    }

    #[test]
    fn bulk_parser_preserves_cloud_mount_and_hardlink_metadata() {
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        for (name, dir, flags, mount, links) in [
            ("cloud", true, SF_DATALESS, 0, 1),
            ("mounted", true, 0, DIR_MNTSTATUS_MNTPOINT, 1),
            ("plain", true, 0, 0, 1),
            ("linked-é", false, 0, 0, 2),
        ] {
            let record = bulk_record(name, dir, flags, mount, links, None);
            assert!(parse_entry(&record, &mut entries, &mut names, &Progress::default()));
        }
        assert_eq!(entries.len(), 4);
        assert!(entries[..3].iter().all(|e| e.is_dir) && !entries[3].is_dir);
        assert!(entries[0].dataless && !entries[0].mount_point);
        assert!(!entries[1].dataless && entries[1].mount_point);
        let descend: Vec<_> = entries.iter().map(|e| e.descend()).collect();
        assert_eq!(descend, [false, false, true, false], "cloud-only and mount points are skipped");
        assert_eq!(&names[entries[2].name_end as usize..], "linked-é".as_bytes());
        // No clone id from the volume: hard links still key by file id.
        assert_eq!(entries[3].stream, Some(DataStream { dev: 17, id: 123456, by_clone_id: false }));
        assert!(entries[3].no_clone_id && !entries[2].no_clone_id);
        assert_eq!((entries[3].size, entries[3].alloc), (12345, 16384));
    }

    #[test]
    fn bulk_parser_keys_clones_and_hardlinks_by_data_stream() {
        let parse = |links, ext, is_dir| {
            let (mut entries, mut names) = (Vec::new(), Vec::new());
            let record = bulk_record("f", is_dir, 0, 0, links, ext);
            assert!(parse_entry(&record, &mut entries, &mut names, &Progress::default()));
            assert_eq!(&names[..], b"f", "the name is read past the extended attributes");
            entries.pop().unwrap()
        };
        let clone = |id| DataStream { dev: 17, id, by_clone_id: true };
        // A clone (or a clone's source): keyed by clone id, sizes intact.
        let e = parse(1, Some((99, EF_MAY_SHARE_BLOCKS | 0x40)), false);
        assert_eq!(e.stream, Some(clone(99)));
        assert_eq!((e.size, e.alloc, e.no_clone_id), (12345, 16384, false));
        // A hard-linked clone: the clone id still names the shared data.
        assert_eq!(parse(3, Some((99, EF_MAY_SHARE_BLOCKS)), false).stream, Some(clone(99)));
        // A hard link that was never cloned: APFS reports clone id == file id.
        assert_eq!(parse(2, Some((123456, 0)), false).stream, Some(clone(123456)));
        // Plain files and directories are not tracked.
        assert_eq!(parse(1, Some((123456, 0)), false).stream, None);
        assert_eq!(parse(1, Some((5, EF_MAY_SHARE_BLOCKS)), true).stream, None);
        // May share, but the clone id is missing (0): nothing to key on.
        assert_eq!(parse(1, Some((0, EF_MAY_SHARE_BLOCKS)), false).stream, None);
        assert!(parse(1, Some((0, EF_MAY_SHARE_BLOCKS)), false).no_clone_id);
    }

    #[test]
    fn missing_allocated_size_is_read_per_file_or_reported() {
        let root = std::env::temp_dir().join(format!("bz-test-alloc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("here"), vec![1u8; 70_000]).unwrap();
        let expected = {
            use std::os::unix::fs::MetadataExt;
            std::fs::symlink_metadata(root.join("here")).unwrap().blocks() * 512
        };
        let mut s = Scratch::default();
        for (name, missing) in [("here", true), ("gone", true), ("kept", false)] {
            s.names.extend_from_slice(name.as_bytes());
            s.entries.push(Entry {
                name_end: s.names.len() as u32,
                is_dir: false,
                dataless: false,
                mount_point: false,
                size: 70_000,
                alloc: if missing { 0 } else { 12_345 },
                stream: None,
                no_clone_id: true,
                alloc_missing: missing,
            });
        }
        let dir = CString::new(root.as_os_str().as_encoded_bytes()).unwrap();
        let fd = unsafe { libc::open(dir.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY) };
        assert!(fd >= 0);
        let progress = Progress::default();
        let complete = fill_missing_alloc(fd, &mut s, &progress);
        unsafe { libc::close(fd) };
        let _ = std::fs::remove_dir_all(&root);
        assert!(!complete, "a file that vanished leaves the directory incomplete");
        assert_eq!(s.entries[0].alloc, expected, "read from the file's blocks");
        assert_eq!(s.entries[1].alloc, 70_000, "unknown: logical size, reported as an error");
        assert_eq!(s.entries[2].alloc, 12_345, "sizes the volume reported are kept");
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn bulk_parser_drops_truncated_records_without_panicking() {
        let full = bulk_record("name", false, 0, 0, 2, Some((9, EF_MAY_SHARE_BLOCKS)));
        let name_end = full.len() - 1; // the trailing NUL is not part of the name
        for cut in 0..name_end {
            let progress = Progress::default();
            let (mut entries, mut names) = (Vec::new(), Vec::new());
            let ok = parse_entry(&full[..cut], &mut entries, &mut names, &progress);
            assert!(!ok, "a record cut at {cut} of {name_end} bytes must be dropped");
            assert!(entries.is_empty() && names.is_empty());
            assert_eq!(progress.errors.load(Ordering::Relaxed), 1, "cut at {cut}");
        }
        // A name reference pointing outside the record.
        let mut bad = full.clone();
        bad[28..32].copy_from_slice(&0x7fff_fff0u32.to_le_bytes());
        let progress = Progress::default();
        assert!(!parse_entry(&bad, &mut Vec::new(), &mut Vec::new(), &progress));
        assert_eq!(progress.entry_errors.load(Ordering::Relaxed), 1);
        let mut negative = full;
        negative[28..32].copy_from_slice(&(-1000i32 as u32).to_le_bytes());
        assert!(!parse_entry(&negative, &mut Vec::new(), &mut Vec::new(), &Progress::default()));
    }

    /// Every child is listed once, under its parent, after it.
    fn assert_partition(t: &Tree) {
        let mut seen = vec![false; t.len()];
        seen[0] = true;
        for p in 0..t.len() {
            assert!(t.flags[p] & 1 != 0 || t.kids(p).is_empty());
            for &c in t.kids(p) {
                let c = c as usize;
                assert!(c > p, "aggregation requires parent-before-child order");
                assert!(!seen[c], "a child belongs to exactly one directory");
                seen[c] = true;
                assert_eq!(t.parents[c] as usize, p);
            }
        }
        assert!(seen.iter().all(|&v| v), "every node is reachable");
    }

    #[test]
    fn scan_preserves_parent_links_empty_dirs_and_symlinks() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!("bz-tree-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("nested/empty")).unwrap();
        std::fs::write(root.join("nested/document-é"), [7u8; 17]).unwrap();
        symlink(&root, root.join("loop")).unwrap();
        let t = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(t.errors, 0);
        assert_eq!(t.len(), 5, "directory symlinks are not followed");
        assert_eq!(t.n_files[0], 2);
        assert_partition(&t);
        let find = |n: &str| (0..t.len()).find(|&i| t.name(i) == n).unwrap();
        let empty = find("empty");
        assert!(t.flags[empty] & 1 != 0 && t.kids(empty).is_empty());
        assert_eq!(t.logical[find("document-é")], 17);
    }

    #[test]
    fn parallel_child_ranges_partition_wide_and_deep_tree() {
        let root = std::env::temp_dir().join(format!("bz-ranges-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let mut deep = root.clone();
        for depth in 1..=96 {
            deep.push("d");
            std::fs::create_dir(&deep).unwrap();
            std::fs::write(deep.join("data"), vec![1u8; depth]).unwrap();
        }
        for width in 0..64 {
            let dir = root.join(format!("wide-{width}"));
            std::fs::create_dir_all(dir.join("empty")).unwrap();
            std::fs::write(dir.join("data"), [1u8; 19]).unwrap();
        }
        let t = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(t.errors, 0);
        assert_eq!(t.len(), 385);
        assert_eq!(t.n_files[0], 160);
        assert_eq!(t.logical[0], 5872);
        assert_partition(&t);
    }

    /// A tree as the walk leaves it: each directory's entries appended as one
    /// batch after it, totals and child lists not yet derived.
    fn fixture(dirs: usize, files_per_dir: usize) -> Tree {
        let mut t = Tree::with_root("/fixture");
        t.errors = 3;
        for dir in 0..dirs {
            t.push(&format!("directory-{dir}"), 0, 0, 0, true);
        }
        for dir in 0..dirs {
            for file in 0..files_per_dir {
                let size = (file as u64 * 7919 + dir as u64 * 104729) % 1_000_000;
                let name = format!("document-{dir}-{file}-é-日本語.txt");
                t.push(&name, dir as u32 + 1, size, size.div_ceil(4096) * 4096, false);
            }
        }
        // One unreadable directory, to exercise incompleteness propagation.
        if dirs > 1 {
            t.complete[2] = false;
        }
        t
    }

    /// The pre-0.6 conversion, kept as an independent reference: per-node
    /// totals in reverse index order, then each child list sorted on its own.
    fn reference_finish(mut t: Tree) -> Tree {
        let n = t.len();
        for i in 0..n {
            if !t.complete[i] {
                t.flags[i] |= SELF_INCOMPLETE;
            }
        }
        t.n_files = vec![0; n];
        let mut lists = vec![Vec::new(); n];
        for i in (1..n).rev() {
            let p = t.parents[i] as usize;
            t.alloc[p] += t.alloc[i];
            t.logical[p] += t.logical[i];
            t.n_files[p] += if t.flags[i] & 1 != 0 { t.n_files[i] } else { 1 };
            t.complete[p] &= t.complete[i];
        }
        for i in 1..n {
            lists[t.parents[i] as usize].push(i as u32);
        }
        t.child_off = vec![0];
        for mut kids in lists {
            kids.sort_unstable_by_key(|&c| std::cmp::Reverse(t.alloc[c as usize]));
            t.children.extend(kids);
            t.child_off.push(t.children.len() as u32);
        }
        t
    }

    #[test]
    fn finish_preserves_every_abi_column_and_child_order() {
        for (dirs, files) in [(0, 0), (3, 0), (1, 1024), (128, 4)] {
            let mut t = fixture(dirs, files);
            finish(&mut t);
            assert_eq!(t, reference_finish(fixture(dirs, files)));
        }
    }

    #[test]
    #[ignore = "isolated performance measurement; run in release with --nocapture"]
    fn finish_benchmark() {
        // Alternate execution order to avoid favoring either implementation.
        for round in 0..10 {
            for variant in [round % 2, 1 - round % 2] {
                let mut t = fixture(256, 1024);
                let start = std::time::Instant::now();
                if variant == 0 {
                    t = reference_finish(t);
                } else {
                    finish(&mut t);
                }
                let elapsed = start.elapsed();
                std::hint::black_box(&t);
                println!("finish,{round},{variant},{}", elapsed.as_nanos());
            }
        }
    }

    #[test]
    fn hardlink_owner_does_not_depend_on_discovery_order() {
        for order in [[3, 4, 5], [5, 3, 4], [4, 5, 3]] {
            let mut tree = Tree::with_root("/root");
            tree.push("a", 0, 0, 0, true);
            tree.push("z", 0, 0, 0, true);
            tree.push("a", 2, 8192, 4096, false);
            tree.push("z", 1, 8192, 4096, false);
            tree.push("y", 1, 8192, 4096, false);
            let mut arena = Arena { tree, streams: HashMap::new() };
            let added: u64 = order
                .into_iter()
                .map(|i| arena.account_file(i, Some(DataStream { dev: 7, id: 42, by_clone_id: true })))
                .sum();
            let t = &mut arena.tree;
            assert_eq!(added, 4096, "progress counts the inode once");
            assert_eq!(t.alloc[3], 0); // /root/z/a
            assert_eq!(t.alloc[4], 0); // /root/a/z
            assert_eq!(t.alloc[5], 4096); // /root/a/y wins every time
            assert_eq!(t.logical[5], 8192);
            finish(t);
            assert_eq!((t.alloc[0], t.logical[0], t.n_files[0]), (4096, 8192, 3));
        }
    }

    #[test]
    fn path_order_matches_materialized_paths() {
        let mut t = Tree::with_root("/fixture/root with spaces");
        let mut random = 0x1248_acefu64;
        for i in 1..500 {
            random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
            let parent = if i < 40 { i - 1 } else { (random as usize) % i };
            let names = ["a", "a-", "a.", "a0", "a_", "é", "日本語", "line\n"];
            let name = format!("{}{i}", names[(random >> 32) as usize % names.len()]);
            t.push(&name, parent as u32, 0, 0, true);
        }
        let paths: Vec<_> = (0..t.len()).map(|i| t.path(i)).collect();
        for a in 0..t.len() {
            for b in 0..t.len() {
                assert_eq!(t.compare_paths(a, b), paths[a].cmp(&paths[b]), "{a} vs {b}");
            }
        }
    }

    #[test]
    fn incomplete_subtrees_propagate_without_hiding_healthy_siblings() {
        let mut t = Tree::with_root("/root");
        t.push("partial", 0, 0, 0, true);
        t.push("healthy", 0, 0, 0, true);
        let skipped = t.push("unreadable-or-skipped", 1, 0, 0, true);
        t.push("file", 2, 8192, 4096, false);
        t.complete[skipped as usize] = false;
        finish(&mut t);
        assert_eq!(t.complete[..3], [false, false, true]);
        assert_eq!(t.alloc[0], 4096, "partial scans still expose observed bytes");
    }

    #[test]
    fn entry_errors_are_reported_instead_of_silently_dropped() {
        let mut bytes = vec![0u8; 28];
        bytes[4..8].copy_from_slice(&ATTR_CMN_ERROR.to_le_bytes());
        bytes[24..28].copy_from_slice(&(libc::EACCES as u32).to_le_bytes());
        let progress = Progress::default();
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        assert!(!parse_entry(&bytes, &mut entries, &mut names, &progress));
        assert!(entries.is_empty());
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        assert_eq!(progress.entry_errors.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn invalid_utf8_is_not_replaced_with_an_actionable_path() {
        let mut bytes = vec![0u8; 34];
        bytes[4..8].copy_from_slice(&ATTR_CMN_NAME.to_le_bytes());
        bytes[24..28].copy_from_slice(&8u32.to_le_bytes());
        bytes[28..32].copy_from_slice(&2u32.to_le_bytes());
        bytes[32] = 0xff;
        let progress = Progress::default();
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        assert!(!parse_entry(&bytes, &mut entries, &mut names, &progress));
        assert!(entries.is_empty() && names.is_empty());
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        assert_eq!(progress.invalid_names.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn hardlinks_count_once() {
        let root = std::env::temp_dir().join(format!("bz-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("file"), vec![7u8; 1 << 20]).unwrap();
        std::fs::hard_link(root.join("file"), root.join("sub/link")).unwrap();

        let tree = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(tree.n_files[0], 2, "both names are listed");
        assert_eq!(tree.logical[0], 1 << 20, "but the bytes count once");
    }

    fn node(t: &Tree, path: &str) -> usize {
        let root = t.path(0);
        (0..t.len())
            .find(|&i| t.path(i) == root.join(path))
            .unwrap_or_else(|| panic!("{path} not scanned"))
    }

    fn clone_file(from: &Path, to: &Path) {
        let (from_c, to_c) = (
            CString::new(from.as_os_str().as_encoded_bytes()).unwrap(),
            CString::new(to.as_os_str().as_encoded_bytes()).unwrap(),
        );
        let status = unsafe { libc::clonefile(from_c.as_ptr(), to_c.as_ptr(), 0) };
        assert_eq!(
            status,
            0,
            "clonefile({}) failed: {}; this test needs an APFS temp directory",
            to.display(),
            std::io::Error::last_os_error()
        );
    }

    /// APFS clones (`cp -c`, Chrome's code_sign_clone)
    /// share one data stream; each reports the full allocated size.
    #[test]
    fn apfs_clones_count_once_and_edited_clones_count_again() {
        let root = std::env::temp_dir().join(format!("bz-test-clones-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for d in ["a", "b", "c", "d"] {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
        let data: Vec<u8> = (0..1u32 << 20).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8).collect();
        std::fs::write(root.join("a/orig"), &data).unwrap();
        clone_file(&root.join("a/orig"), &root.join("b/clone"));
        clone_file(&root.join("b/clone"), &root.join("c/clone-of-clone"));
        std::fs::hard_link(root.join("b/clone"), root.join("c/link-to-clone")).unwrap();
        // An edited clone gets its own clone id: its shared blocks cannot be
        // attributed, so it is counted in full like `du` does.
        clone_file(&root.join("a/orig"), &root.join("d/edited"));
        {
            use std::io::{Seek, SeekFrom, Write};
            let mut f = std::fs::OpenOptions::new().write(true).open(root.join("d/edited")).unwrap();
            f.seek(SeekFrom::Start(4096)).unwrap();
            f.write_all(b"edited").unwrap();
            f.sync_all().unwrap();
        }
        let one = std::fs::symlink_metadata(root.join("a/orig")).unwrap();
        let one_alloc = {
            use std::os::unix::fs::MetadataExt;
            one.blocks() * 512
        };

        let tree = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(tree.n_files[0], 5, "every name is listed");
        assert_eq!(tree.alloc[node(&tree, "a/orig")], one_alloc, "first path owns the stream");
        for shared in ["b/clone", "c/clone-of-clone", "c/link-to-clone"] {
            assert_eq!(tree.alloc[node(&tree, shared)], 0, "{shared} shares a's blocks");
            assert_eq!(tree.logical[node(&tree, shared)], 0, "{shared} shares a's bytes");
        }
        assert_eq!(tree.alloc[node(&tree, "d/edited")], one_alloc);
        assert_eq!(tree.alloc[0], 2 * one_alloc);
        assert_eq!(tree.logical[0], 2 * data.len() as u64);
    }

    /// After a volume refuses the extended attributes, clones can't be told
    /// apart: they count per path (hard links still once) and the scan says so.
    #[test]
    fn without_clone_ids_clones_count_per_path_and_are_reported() {
        let root = std::env::temp_dir().join(format!("bz-test-noext-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("orig"), vec![3u8; 1 << 20]).unwrap();
        clone_file(&root.join("orig"), &root.join("clone"));
        std::fs::hard_link(root.join("orig"), root.join("link")).unwrap();

        let progress = Progress::default();
        progress.no_extended_attrs.store(true, Ordering::Relaxed);
        let tree = scan(&root, &progress);
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(tree.n_files[0], 3);
        assert_eq!(tree.logical[0], 2 << 20, "the clone counts again, the hard link does not");
        assert_eq!(progress.clone_ids_unavailable_dirs.load(Ordering::Relaxed), 1);
        // "link" sorts first, so it owns the inode's bytes.
        assert_eq!(tree.alloc[node(&tree, "orig")], 0);
        assert_eq!(progress.shared_bytes.load(Ordering::Relaxed), tree.alloc[node(&tree, "link")]);
    }

    #[test]
    fn flat_layout() {
        let root = std::env::temp_dir().join(format!("bz-test-flat-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("big/deep")).unwrap();
        std::fs::create_dir_all(root.join("empty")).unwrap();
        std::fs::write(root.join("big/deep/blob"), vec![1u8; 1 << 20]).unwrap();
        std::fs::write(root.join("small"), b"hi").unwrap();

        let t = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(t.len(), 6);
        assert_eq!((t.child_off.len(), t.name_off.len(), t.children.len()), (7, 7, 5));
        let names = |i: usize| t.kids(i).iter().map(|&c| t.name(c as usize)).collect::<Vec<_>>();
        assert_eq!(names(0), ["big", "small", "empty"], "largest first");
        let big = t.kids(0)[0] as usize;
        assert_eq!(names(big), ["deep"]);
        assert_eq!((t.n_files[0], t.n_files[big]), (2, 1));
        assert_eq!(t.logical[0], (1 << 20) + 2);
        assert_eq!(t.flags[big], 1);
        for i in 1..t.len() {
            assert!(t.kids(t.parents[i] as usize).contains(&(i as u32)));
        }
    }

    #[test]
    fn c_abi_round_trip() {
        use ffi::*;
        let root = std::env::temp_dir().join(format!("bz-test-ffi-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("d")).unwrap();
        std::fs::write(root.join("d/f"), b"x").unwrap();
        let path = CString::new(root.as_os_str().as_encoded_bytes()).unwrap();

        let h = bz_scan_start(path.as_ptr());
        let (mut f, mut d, mut b, mut done) = (0, 0, 0, 0);
        while done == 0 {
            std::thread::sleep(std::time::Duration::from_millis(1));
            bz_progress(h, &mut f, &mut d, &mut b, &mut done);
        }
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(bz_take_tree(h), 3);
        let s = |p: *const u32, n| unsafe { std::slice::from_raw_parts(p, n) };
        assert_eq!(s(bz_parents(h), 3), [NO_PARENT, 0, 1]);
        assert_eq!(s(bz_child_off(h), 4), [0, 1, 2, 2]);
        assert_eq!(s(bz_children(h), 2), [1, 2]);
        assert_eq!(s(bz_nfiles(h), 3), [1, 1, 0]);
        let off = s(bz_name_off(h), 4);
        let blob = unsafe { std::slice::from_raw_parts(bz_name_blob(h), off[3] as usize) };
        assert_eq!(&blob[off[1] as usize..], b"df");
        bz_free(h);
    }

    /// Every directory's totals equal its children's, child lists are sorted
    /// and cover each non-root node once, and parents come first.
    fn assert_consistent(t: &Tree) {
        let n = t.len();
        assert_eq!(t.child_off.len(), n + 1);
        assert_eq!(t.name_off.len(), n + 1);
        assert_eq!(t.children.len(), n.saturating_sub(1));
        let mut seen = vec![0u32; n];
        for i in 0..n {
            assert!(i == 0 || (t.parents[i] as usize) < i, "parent before child at {i}");
            let kids = t.kids(i);
            assert!(kids.windows(2).all(|w| t.alloc[w[0] as usize] >= t.alloc[w[1] as usize]));
            for &k in kids {
                assert_eq!(t.parents[k as usize] as usize, i);
                seen[k as usize] += 1;
            }
            if t.is_dir(i) {
                let sum = |f: &dyn Fn(usize) -> u64| kids.iter().map(|&k| f(k as usize)).sum::<u64>();
                assert_eq!(t.alloc[i], sum(&|k| t.alloc[k]), "alloc of {}", t.path(i).display());
                assert_eq!(t.logical[i], sum(&|k| t.logical[k]), "logical of {}", t.path(i).display());
                assert_eq!(
                    t.n_files[i] as u64,
                    sum(&|k| if t.is_dir(k) { t.n_files[k] as u64 } else { 1 }),
                    "files of {}",
                    t.path(i).display()
                );
            }
        }
        assert!(seen[1..].iter().all(|&c| c == 1));
    }

    /// root: a/{big 700, small 100}, b 64, c/d/{deep 30}
    fn removal_fixture() -> Tree {
        let mut t = Tree::with_root("/root");
        let a = t.push("a", 0, 0, 0, true);
        t.push("b", 0, 50, 64, false);
        let c = t.push("c", 0, 0, 0, true);
        t.push("big", a, 600, 700, false);
        t.push("small", a, 90, 100, false);
        let d = t.push("d", c, 0, 0, true);
        t.push("deep", d, 20, 30, false);
        finish(&mut t);
        t
    }

    fn find(t: &Tree, path: &str) -> u32 {
        (0..t.len()).find(|&i| t.path(i) == Path::new("/root").join(path)).unwrap() as u32
    }

    #[test]
    fn removing_a_leaf_takes_its_bytes_off_every_ancestor() {
        let t = removal_fixture();
        assert_consistent(&t);
        let r = t.without(&[find(&t, "c/d/deep")]);
        assert_consistent(&r);
        assert_eq!(r.len(), t.len() - 1);
        assert!((0..r.len()).all(|i| r.name(i) != "deep"));
        let (c, d) = (find(&r, "c") as usize, find(&r, "c/d") as usize);
        assert_eq!((r.alloc[0], r.logical[0], r.n_files[0]), (t.alloc[0] - 30, t.logical[0] - 20, 3));
        assert_eq!((r.alloc[c], r.alloc[d], r.n_files[d]), (0, 0, 0));
        // The tree it was made from is untouched.
        assert_eq!(t, removal_fixture());
    }

    #[test]
    fn removing_a_folder_takes_its_whole_subtree_and_resorts_siblings() {
        let t = removal_fixture();
        // a (800) is the largest child of the root; without it b (64) leads.
        assert_eq!(t.name(t.kids(0)[0] as usize), "a");
        let r = t.without(&[find(&t, "a")]);
        assert_consistent(&r);
        assert_eq!(r.len(), t.len() - 3);
        assert_eq!((r.alloc[0], r.logical[0], r.n_files[0]), (64 + 30, 50 + 20, 2));
        assert_eq!(r.name(r.kids(0)[0] as usize), "b");
        assert!((0..r.len()).all(|i| !["a", "big", "small"].contains(&r.name(i))));
        // Names still line up with their nodes after the renumbering.
        assert_eq!(r.path(find(&r, "c/d/deep") as usize), Path::new("/root/c/d/deep"));
    }

    #[test]
    fn removal_ignores_the_root_repeats_strays_and_nodes_inside_a_removed_folder() {
        let t = removal_fixture();
        let a = find(&t, "a");
        let r = t.without(&[0, a, a, find(&t, "a/big"), 999]);
        assert_consistent(&r);
        assert_eq!((r.len(), r.alloc[0]), (t.len() - 3, 94), "a's bytes leave once");
        assert_eq!(t.without(&[0, 999]), t.without(&[]));
        assert_eq!(t.without(&[a]).without(&[find(&t.without(&[a]), "b")]).alloc[0], 30);
        // Everything removed leaves the empty root.
        let all: Vec<u32> = t.kids(0).to_vec();
        let r = t.without(&all);
        assert_consistent(&r);
        assert_eq!((r.len(), r.alloc[0], r.n_files[0], r.kids(0).len()), (1, 0, 0, 0));
    }

    /// Two names, one inode: the scan puts the bytes on the first path and
    /// leaves 0 on the other. Removing either keeps every total consistent.
    #[test]
    fn removing_a_hard_linked_file_keeps_totals_consistent() {
        let root = std::env::temp_dir().join(format!("bz-test-remove-link-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("a-file"), vec![7u8; 1 << 20]).unwrap();
        std::fs::hard_link(root.join("a-file"), root.join("sub/link")).unwrap();
        std::fs::write(root.join("other"), vec![1u8; 4096]).unwrap();
        let t = scan(&root, &Progress::default());
        assert_consistent(&t);
        let (owner, loser) = (node(&t, "a-file"), node(&t, "sub/link"));
        assert!(t.alloc[owner] > 0 && t.alloc[loser] == 0, "bytes counted once, on the first path");
        let total = t.alloc[0];

        // The extra name costs nothing: the same result as rescanning without it.
        let r = t.without(&[loser as u32]);
        assert_consistent(&r);
        assert_eq!((r.alloc[0], r.logical[0]), (total, t.logical[0]));
        assert_eq!(r.n_files[0], t.n_files[0] - 1);
        std::fs::remove_file(root.join("sub/link")).unwrap();
        let rescanned = scan(&root, &Progress::default());
        assert_eq!((r.alloc[0], r.n_files[0], r.len()), (rescanned.alloc[0], rescanned.n_files[0], rescanned.len()));

        // The counted path goes: its bytes come off, once. (A surviving link
        // is not re-credited; see `Tree::without`.)
        let r = t.without(&[owner as u32]);
        assert_consistent(&r);
        assert_eq!(r.alloc[0], total - t.alloc[owner]);
        assert_eq!(r.n_files[0], t.n_files[0] - 1);

        // Both names, and the folder holding one of them.
        let r = t.without(&[owner as u32, node(&t, "sub") as u32]);
        assert_consistent(&r);
        assert_eq!((r.alloc[0], r.n_files[0]), (total - t.alloc[owner], 1));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn removal_matches_a_rescan_of_a_real_folder() {
        let root = std::env::temp_dir().join(format!("bz-test-remove-scan-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("x/y")).unwrap();
        std::fs::create_dir_all(root.join("empty")).unwrap();
        std::fs::write(root.join("x/y/f1"), vec![1u8; 100_000]).unwrap();
        std::fs::write(root.join("x/f2"), vec![2u8; 30_000]).unwrap();
        std::fs::write(root.join("keep"), vec![3u8; 9_000]).unwrap();
        std::fs::create_dir_all(root.join("other/deeper")).unwrap();
        std::fs::write(root.join("other/deeper/f3"), vec![4u8; 50_000]).unwrap();
        std::fs::write(root.join("other/f4"), vec![5u8; 7_000]).unwrap();
        let t = scan(&root, &Progress::default());
        let r = t.without(&[node(&t, "x") as u32]);
        std::fs::remove_dir_all(root.join("x")).unwrap();
        let rescanned = scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);
        assert_consistent(&r);
        // Node numbers follow the walk's thread scheduling, so compare what
        // each path holds, not the arrays.
        assert_eq!(by_path(&r), by_path(&rescanned));
    }

    /// Every node's totals, completeness and kind, by path.
    fn by_path(t: &Tree) -> std::collections::BTreeMap<PathBuf, (u64, u64, u32, bool, u8)> {
        (0..t.len()).map(|i| (t.path(i), (t.alloc[i], t.logical[i], t.n_files[i], t.complete[i], t.flags[i]))).collect()
    }

    #[test]
    fn removing_the_only_incomplete_subtree_makes_its_ancestors_complete() {
        // root/{a/{partial/{x}, ok}, b/{unread}}: partial lost an entry and
        // b could not list itself; unread is fine on its own.
        let mut t = Tree::with_root("/root");
        let a = t.push("a", 0, 0, 0, true);
        let b = t.push("b", 0, 0, 0, true);
        let partial = t.push("partial", a, 0, 0, true);
        t.push("ok", a, 10, 4096, false);
        t.push("unread", b, 5, 4096, false);
        t.push("x", partial, 20, 4096, false);
        t.complete[partial as usize] = false;
        t.complete[b as usize] = false;
        finish(&mut t);
        assert_eq!(t.complete[..3], [false, false, false]);

        let r = t.without(&[partial]);
        assert_consistent(&r);
        assert!(r.complete[find(&r, "a") as usize], "a's only incomplete subtree is gone");
        assert!(!r.complete[find(&r, "b") as usize], "b itself was not fully read; that stays");
        assert!(!r.complete[0], "the root still holds b");
        assert!(r.complete[find(&r, "b/unread") as usize]);

        let r = r.without(&[find(&r, "b")]);
        assert!(r.complete.iter().all(|&c| c), "nothing incomplete is left");
        assert!(r.flags.iter().all(|&f| f & SELF_INCOMPLETE == 0));
        // A deleted folder's own incompleteness doesn't move to its parent.
        let r = t.without(&[find(&t, "b/unread")]);
        assert!(!r.complete[find(&r, "b") as usize] && r.complete[find(&r, "a/ok") as usize]);
    }

    /// The removal before it became one pass: three full copies, then each
    /// column filtered on its own, `complete` copied as scanned. Kept as an
    /// independent reference for the other columns and for the benchmark.
    fn reference_without(s: &Tree, nodes: &[u32]) -> Tree {
        let n = s.len();
        let mut gone = vec![false; n];
        for &c in nodes {
            if c != 0 && (c as usize) < n {
                gone[c as usize] = true;
            }
        }
        let mut tops = Vec::new();
        for i in 1..n {
            let parent_gone = gone[s.parents[i] as usize];
            if gone[i] {
                if !parent_gone {
                    tops.push(i);
                }
            } else if parent_gone {
                gone[i] = true;
            }
        }
        let (mut alloc, mut logical, mut n_files) = (s.alloc.clone(), s.logical.clone(), s.n_files.clone());
        for &top in &tops {
            let files = if s.is_dir(top) { s.n_files[top] } else { 1 };
            let mut up = s.parents[top];
            while up != NO_PARENT {
                let a = up as usize;
                alloc[a] = alloc[a].saturating_sub(s.alloc[top]);
                logical[a] = logical[a].saturating_sub(s.logical[top]);
                n_files[a] = n_files[a].saturating_sub(files);
                up = s.parents[a];
            }
        }
        fn kept<T: Copy>(v: &[T], gone: &[bool]) -> Vec<T> {
            v.iter().zip(gone).filter(|(_, &g)| !g).map(|(&x, _)| x).collect()
        }
        let mut renumber = vec![NO_PARENT; n];
        let mut next = 0u32;
        for i in (0..n).filter(|&i| !gone[i]) {
            renumber[i] = next;
            next += 1;
        }
        let mut t = Tree {
            parents: kept(&s.parents, &gone)
                .into_iter()
                .map(|p| if p == NO_PARENT { p } else { renumber[p as usize] })
                .collect(),
            alloc: kept(&alloc, &gone),
            logical: kept(&logical, &gone),
            n_files: kept(&n_files, &gone),
            flags: kept(&s.flags, &gone),
            complete: kept(&s.complete, &gone),
            name_off: Vec::with_capacity(next as usize + 1),
            errors: s.errors,
            ..Default::default()
        };
        t.name_off.push(0);
        for i in (0..n).filter(|&i| !gone[i]) {
            t.name_blob.extend_from_slice(s.name_bytes(i));
            t.name_off.push(t.name_blob.len() as u32);
        }
        let runs = runs(&t.parents);
        link(&mut t, &runs);
        t
    }

    /// Every 7th folder and every 13th file of the synthetic fixture, plus
    /// nodes inside chosen folders, repeats, the root and strays.
    fn removal_picks(t: &Tree) -> Vec<u32> {
        let mut picks: Vec<u32> = (1..t.len() as u32)
            .filter(|&i| if t.is_dir(i as usize) { i % 7 == 0 } else { i % 13 == 0 })
            .collect();
        picks.extend([0, 1, 1, u32::MAX, t.len() as u32]);
        picks
    }

    #[test]
    fn one_pass_removal_matches_the_reference_on_every_column() {
        for (dirs, files) in [(0, 0), (3, 0), (1, 1024), (128, 4), (40, 40)] {
            let mut t = fixture(dirs, files);
            finish(&mut t);
            for picks in [removal_picks(&t), vec![], t.kids(0).to_vec()] {
                let (got, mut want) = (t.without(&picks), reference_without(&t, &picks));
                assert_consistent(&got);
                // The reference copies `complete` as scanned; recompute it
                // independently: own state, then node by node in reverse
                // index order (children come after their parent).
                for i in 0..want.len() {
                    want.complete[i] = want.flags[i] & SELF_INCOMPLETE == 0;
                }
                for i in (1..want.len()).rev() {
                    let p = want.parents[i] as usize;
                    want.complete[p] &= want.complete[i];
                }
                assert_eq!(got, want, "{dirs} dirs x {files} files, {} picks", picks.len());
            }
        }
        let t = removal_fixture();
        assert_eq!(t.without(&[find(&t, "a")]), reference_without(&t, &[find(&t, "a")]));
    }

    #[test]
    #[ignore = "isolated performance measurement; run in release with --nocapture"]
    fn removal_benchmark() {
        let mut t = fixture(2048, 512);
        finish(&mut t);
        let picks = removal_picks(&t);
        // Interleaved, alternating which goes first; report min-of-N.
        let mut best = [u128::MAX; 2];
        for round in 0..12 {
            for variant in [round % 2, 1 - round % 2] {
                let start = std::time::Instant::now();
                let r = if variant == 0 { reference_without(&t, &picks) } else { t.without(&picks) };
                let elapsed = start.elapsed().as_nanos();
                std::hint::black_box(&r);
                best[variant] = best[variant].min(elapsed);
                println!("without,{round},{variant},{elapsed}");
            }
        }
        println!("without min ns: reference {} one-pass {} ({} nodes)", best[0], best[1], t.len());
    }


    thread_local! {
        static INTERRUPTS: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
    }

    /// Makes this thread's next `n` `getattrlistbulk` calls fail with EINTR.
    fn interrupt_next(n: u32) {
        INTERRUPTS.with(|c| c.set(n));
    }

    pub(super) fn take_injected_interrupt() -> bool {
        INTERRUPTS.with(|c| {
            let left = c.get();
            c.set(left.saturating_sub(1));
            left > 0
        })
    }

    /// Fault injection: a walk of any path containing this panics on a
    /// rayon worker. Keyed on the path so parallel tests are unaffected.
    pub(crate) const PANIC_MARKER: &str = "bz-inject-panic";

    pub(super) fn inject_scan_fault(path: &CStr) {
        let has = |marker: &str| {
            path.to_bytes()
                .windows(marker.len())
                .any(|w| w == marker.as_bytes())
        };
        if has(PANIC_MARKER) {
            panic!("injected scan fault");
        }
        if has(HOLD_MARKER) {
            HOLD.pass();
        }
    }

    /// Fault injection: a walk that reaches a path containing this parks its
    /// worker in `HOLD` until the test opens it, so a test can have a scan
    /// that is deterministically still running. One test at a time may use it.
    pub(crate) const HOLD_MARKER: &str = "bz-inject-hold";

    pub(crate) static HOLD: Hold = Hold::new();

    pub(crate) struct Hold {
        state: Mutex<(usize, bool)>,
        changed: std::sync::Condvar,
    }

    impl Hold {
        const fn new() -> Hold {
            Hold {
                state: Mutex::new((0, false)),
                changed: std::sync::Condvar::new(),
            }
        }

        /// Close the latch and forget earlier arrivals.
        pub(crate) fn arm(&self) {
            *self.state.lock().unwrap_or_else(|e| e.into_inner()) = (0, false);
        }

        /// Open the latch: parked walks continue.
        pub(crate) fn release(&self) {
            self.state.lock().unwrap_or_else(|e| e.into_inner()).1 = true;
            self.changed.notify_all();
        }

        /// Block until a walk has arrived (true), or `timeout` passes (false).
        pub(crate) fn wait_arrival(&self, timeout: std::time::Duration) -> bool {
            let deadline = std::time::Instant::now() + timeout;
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            while state.0 == 0 {
                let Some(left) = deadline.checked_duration_since(std::time::Instant::now()) else {
                    return false;
                };
                state = self
                    .changed
                    .wait_timeout(state, left)
                    .unwrap_or_else(|e| e.into_inner())
                    .0;
            }
            true
        }

        fn pass(&self) {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            state.0 += 1;
            self.changed.notify_all();
            while !state.1 {
                state = self.changed.wait(state).unwrap_or_else(|e| e.into_inner());
            }
        }
    }

    #[test]
    fn interrupted_calls_are_retried_a_bounded_number_of_times() {
        let calls = std::cell::Cell::new(0u32);
        let interrupted = |until: u32| {
            calls.set(0);
            retry_interrupted(|| {
                calls.set(calls.get() + 1);
                if calls.get() <= until {
                    unsafe { *libc::__error() = libc::EINTR };
                    -1
                } else {
                    7
                }
            })
        };
        assert_eq!(interrupted(0), 7);
        assert_eq!(interrupted(MAX_INTERRUPTS), 7, "the last allowed retry succeeds");
        assert_eq!(calls.get(), MAX_INTERRUPTS + 1);
        assert_eq!(interrupted(MAX_INTERRUPTS + 1), -1, "gives up after the bound");
        assert_eq!(calls.get(), MAX_INTERRUPTS + 1);
        assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::EINTR));
        // Any other failure is final on the first call.
        calls.set(0);
        let n = retry_interrupted(|| {
            calls.set(calls.get() + 1);
            unsafe { *libc::__error() = libc::EACCES };
            -1
        });
        assert_eq!((n, calls.get()), (-1, 1));
    }

    #[test]
    fn an_interrupted_directory_read_is_retried_instead_of_reported_partial() {
        let root = std::env::temp_dir().join(format!("bz-test-eintr-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        for name in ["a", "b", "c"] {
            std::fs::write(root.join(name), b"x").unwrap();
        }
        let path = CString::new(root.as_os_str().as_encoded_bytes()).unwrap();

        let (mut scratch, progress) = (Scratch::default(), Progress::default());
        interrupt_next(3);
        assert_eq!(read_dir_bulk(&path, &mut scratch, &progress), Some(true));
        assert_eq!(scratch.entries.len(), 3);
        assert_eq!(progress.errors.load(Ordering::Relaxed), 0);

        // A call that keeps being interrupted still ends: the listing is partial and counted.
        interrupt_next(1000);
        assert_eq!(read_dir_bulk(&path, &mut scratch, &progress), Some(false));
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        interrupt_next(0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_symlinked_root_is_scanned_through_the_link() {
        let base = std::env::temp_dir().join(format!("bz-test-symroot-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("real/sub")).unwrap();
        std::fs::write(base.join("real/sub/f"), b"x").unwrap();
        std::os::unix::fs::symlink(base.join("real"), base.join("abs")).unwrap();
        std::os::unix::fs::symlink("real", base.join("rel")).unwrap();
        std::os::unix::fs::symlink("rel", base.join("chain")).unwrap();

        for link in ["abs", "rel", "chain"] {
            let progress = Progress::default();
            let t = scan(&base.join(link), &progress);
            assert_eq!(t.len(), 3, "{link}: root, sub, f");
            assert_eq!(t.errors, 0, "{link}");
            assert!(t.complete[0], "{link}");
            assert_eq!(t.name(0), base.join(link).to_str().unwrap(), "the root keeps the name it was given");
            assert_eq!(t.name(2), "f");
        }

        // Nothing to follow: a loop, a dangling link and a link to a file are errors, not a walk.
        std::os::unix::fs::symlink("loop", base.join("loop")).unwrap();
        std::os::unix::fs::symlink("nowhere", base.join("dangling")).unwrap();
        std::os::unix::fs::symlink("real/sub/f", base.join("to_file")).unwrap();
        for link in ["loop", "dangling", "to_file"] {
            let t = scan(&base.join(link), &Progress::default());
            assert_eq!((t.len(), t.errors, t.complete[0]), (1, 1, false), "{link}");
        }
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn local_path_resolves_every_link_and_dot_segment() {
        let base = std::fs::canonicalize(std::env::temp_dir()).unwrap().join(format!("bz-test-local-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("a/b")).unwrap();
        std::os::unix::fs::symlink("..", base.join("a/b/up")).unwrap();
        assert_eq!(local_path(&base.join("a/b/up/./b/../b")).unwrap(), base.join("a/b"));
        assert!(local_path(&base.join("missing")).is_err());
        let _ = std::fs::remove_dir_all(&base);
    }

    /// A directory `root` with `root/f1..f4` and `root/s/g1,g2`.
    fn limit_fixture(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("s")).unwrap();
        for f in ["f1", "f2", "f3", "f4", "s/g1", "s/g2"] {
            std::fs::write(root.join(f), b"x").unwrap();
        }
        root
    }

    #[test]
    fn past_the_abi_limits_a_directory_is_left_unlisted_and_incomplete() {
        let root = limit_fixture("bz-test-limits");
        let label = root.to_str().unwrap().len() as u64;
        let full = scan(&root, &Progress::default());
        assert_eq!(full.len(), 8);
        assert!(full.complete[0] && full.errors == 0);

        // Root + its five entries fit exactly; the two files under `s` would be node 7 and 8.
        let progress = Progress::default();
        let t = scan_with(&root, &progress, Limits { nodes: 6, name_bytes: u32::MAX as u64 });
        assert_eq!(t.len(), 6, "s's listing is dropped whole, not cut");
        assert!(!t.complete[0], "the tree is marked incomplete");
        let s = (0..t.len()).find(|&i| t.name(i) == "s").unwrap();
        assert!(!t.complete[s] && t.kids(s).is_empty());
        assert_eq!(t.errors, 1);
        assert_eq!(progress.files.load(Ordering::Relaxed), 4, "dropped entries are not counted as scanned");
        assert_eq!(t.n_files[0], 4);
        assert_partition(&t);

        // The same for the name blob: the root label plus the five names fit, s's two do not.
        let t = scan_with(&root, &Progress::default(), Limits { nodes: u32::MAX as u64, name_bytes: label + 9 });
        assert_eq!(t.len(), 6);
        assert!(!t.complete[0]);
        assert_eq!(t.errors, 1);
        assert_eq!(*t.name_off.last().unwrap() as u64, label + 9);

        // A limit the root listing already passes leaves just the root, incomplete.
        let t = scan_with(&root, &Progress::default(), Limits { nodes: 3, name_bytes: u32::MAX as u64 });
        assert_eq!((t.len(), t.complete[0], t.errors), (1, false, 1));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_doubling_symlink_chain_fails_at_once_instead_of_walking_for_ever() {
        // Lk -> L(k+1)/L(k+1): resolving each hop twice made the walk 2^k long.
        let base = std::env::temp_dir().join(format!("bz-test-doubling-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        for k in 0..22 {
            std::os::unix::fs::symlink(format!("L{}/L{}", k + 1, k + 1), base.join(format!("L{k}"))).unwrap();
        }
        std::os::unix::fs::symlink(".", base.join("L22")).unwrap();

        // Off the test thread, so a regression fails here instead of hanging the suite.
        let (sender, receiver) = std::sync::mpsc::channel();
        let (start, link) = (std::time::Instant::now(), base.join("L0"));
        std::thread::spawn(move || {
            let resolved = local_path(&link);
            let scanned = scan(&link, &Progress::default());
            let _ = sender.send((resolved, scanned.errors, scanned.len(), start.elapsed()));
        });
        let (resolved, errors, nodes, elapsed) = receiver
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("resolving the chain did not finish");
        assert!(resolved.unwrap_err().contains("Too many levels of symbolic links"));
        assert_eq!((errors, nodes), (1, 1), "the scan counts the root as unreadable");
        assert!(elapsed < std::time::Duration::from_secs(1), "took {elapsed:?}");

        // A chain within the limit still resolves.
        for k in 0..30 {
            std::os::unix::fs::symlink(format!("M{}", k + 1), base.join(format!("M{k}"))).unwrap();
        }
        std::fs::create_dir(base.join("M30")).unwrap();
        assert_eq!(local_path(&base.join("M0")).unwrap(), std::fs::canonicalize(&base).unwrap().join("M30"));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_walk_that_panics_reaches_the_caller_of_scan() {
        let root = std::env::temp_dir().join(format!("{PANIC_MARKER}-lib-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let outcome = std::panic::catch_unwind(|| scan(&root, &Progress::default()));
        assert!(outcome.is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    /// `fan` folders, each with `fan` folders holding `files` files: about
    /// `fan * fan` directories to walk.
    fn wide_fixture(name: &str, fan: usize, files: usize) -> PathBuf {
        let root = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for a in 0..fan {
            for b in 0..fan {
                let dir = root.join(format!("a{a}/b{b}"));
                std::fs::create_dir_all(&dir).unwrap();
                for f in 0..files {
                    std::fs::write(dir.join(format!("f{f}")), b"x").unwrap();
                }
            }
        }
        root
    }

    /// Every folder the walk did not list reads as unread, and so does the root.
    fn assert_unread_folders_are_incomplete(t: &Tree) {
        assert!(!t.complete[0], "a tree cut short is not complete");
        for i in (0..t.len()).filter(|&i| t.is_dir(i) && t.kids(i).is_empty()) {
            assert!(
                !t.complete[i],
                "folder {i} was never listed but reads as complete"
            );
        }
    }

    #[test]
    fn cancel_stops_a_large_walk_early_and_marks_what_it_left() {
        let root = wide_fixture("bz-test-cancel-wide", 40, 3);
        let full = scan(&root, &Progress::default());
        assert!(full.complete[0] && full.len() > 6000);

        let progress = Progress {
            cancel_after_dirs: AtomicU64::new(25),
            ..Default::default()
        };
        let started = std::time::Instant::now();
        let t = scan(&root, &progress);
        let took = started.elapsed();
        assert!(progress.is_cancelled() && progress.stopped_early());
        assert!(
            t.len() < full.len() / 2,
            "{} of {} nodes: the walk went on after the stop",
            t.len(),
            full.len()
        );
        assert_unread_folders_are_incomplete(&t);
        assert_partition(&t);
        assert!(took < std::time::Duration::from_secs(5), "took {took:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cancel_before_the_first_folder_reads_nothing() {
        let root = limit_fixture("bz-test-cancel-first");
        let progress = Progress::default();
        progress.cancel();
        progress.cancel(); // repeating it changes nothing
        let t = scan(&root, &progress);
        assert!(progress.stopped_early());
        assert_eq!(t.len(), 1, "not even the root was listed");
        assert_unread_folders_are_incomplete(&t);
        assert_eq!(progress.files.load(Ordering::Relaxed), 0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cancel_after_the_walk_leaves_a_whole_tree_alone() {
        let root = limit_fixture("bz-test-cancel-after");
        let progress = Progress::default();
        let t = scan(&root, &progress);
        progress.cancel();
        assert!(!progress.stopped_early(), "nothing was left unread");
        assert!(t.complete[0] && t.errors == 0 && t.len() == 8);
        assert!(Coverage::of(&progress, &t).complete);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cancel_does_not_wait_for_the_end_of_a_huge_folder() {
        let root = std::env::temp_dir().join(format!("bz-test-cancel-huge-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        for i in 0..12_000 {
            std::fs::write(
                root.join(format!("a-rather-long-file-name-to-fill-the-buffer-{i:06}")),
                b"",
            )
            .unwrap();
        }
        let path = CString::new(root.as_os_str().as_encoded_bytes()).unwrap();
        let mut scratch = Scratch::default();

        let all = read_dir_bulk(&path, &mut scratch, &Progress::default());
        assert_eq!((all, scratch.entries.len()), (Some(true), 12_000));

        let progress = Progress::default();
        progress.cancel();
        let cut = read_dir_bulk(&path, &mut scratch, &progress);
        assert_eq!(cut, Some(false), "the listing is partial");
        assert!(progress.stopped_early());
        assert!(
            !scratch.entries.is_empty() && scratch.entries.len() < 12_000,
            "{} entries: a batch was read, the rest was not",
            scratch.entries.len()
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn coverage_is_the_one_account_the_cli_and_the_app_read() {
        let root = limit_fixture("bz-test-coverage");
        let progress = Progress::default();
        let t = scan(&root, &progress);
        let whole = Coverage::of(&progress, &t);
        assert_eq!(
            whole,
            Coverage {
                complete: true,
                ..Default::default()
            }
        );

        // Every counter lands in its own field.
        let progress = Progress::default();
        for (n, counter) in [
            &progress.entry_errors,
            &progress.invalid_names,
            &progress.skipped_cloud_dirs,
            &progress.skipped_mount_points,
            &progress.shared_bytes,
            &progress.clone_ids_unavailable_dirs,
        ]
        .into_iter()
        .enumerate()
        {
            counter.store(n as u64 + 10, Ordering::Relaxed);
        }
        let mut cut = Tree {
            errors: 3,
            ..Tree::with_root("/x")
        };
        cut.complete[0] = false;
        let c = Coverage::of(&progress, &cut);
        assert_eq!((c.errors, c.complete), (3, false));
        assert_eq!(
            [
                c.entry_errors,
                c.invalid_names,
                c.skipped_cloud_directories,
                c.skipped_mount_points,
                c.shared_allocated_bytes,
                c.clone_ids_unavailable_directories
            ],
            [10, 11, 12, 13, 14, 15]
        );

        // A derived tree that reads complete has nothing unread left to count;
        // only the sharing figures describe data and stay.
        let mut healthy = Tree::with_root("/x");
        healthy.link_children();
        let d = c.for_derived(&healthy);
        assert_eq!(
            d,
            Coverage {
                complete: true,
                shared_allocated_bytes: 14,
                clone_ids_unavailable_directories: 15,
                ..Default::default()
            }
        );
        // One that is still partial keeps the scan's counters (upper bounds).
        let d = c.for_derived(&cut);
        assert_eq!(d, c);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_entry_with_a_name_that_is_not_utf8_is_counted_and_its_folder_reads_partial() {
        // APFS, HFS+ and exFAT all refuse such a name (HFS+ stores it escaped
        // as "%FF"), so the records are built by hand.
        let mut batch = bulk_record("ok", true, 0, 0, 1, None);
        batch.extend(bulk_record(b"bad-\xff\xfe", true, 0, 0, 1, None));
        batch.extend(bulk_record("f", false, 0, 0, 1, None));
        let progress = Progress::default();
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        let complete = parse_batch(&batch, 3, &mut entries, &mut names, &progress, c"/dir");
        assert!(!complete, "a dropped entry makes its directory partial");
        assert_eq!(entries.len(), 2, "the entries around it are kept");
        assert_eq!(names, b"okf");
        assert_eq!(progress.invalid_names.load(Ordering::Relaxed), 1);
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);

        // The scan's account says what is missing.
        let mut tree = Tree::with_root("/dir");
        tree.complete[0] = complete;
        tree.errors = progress.errors.load(Ordering::Relaxed);
        let c = Coverage::of(&progress, &tree);
        assert_eq!((c.complete, c.invalid_names, c.errors), (false, 1, 1));

        // A record list cut short is reported too, not walked past.
        let progress = Progress::default();
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        assert!(!parse_batch(
            &batch[..batch.len() - 3],
            3,
            &mut entries,
            &mut names,
            &progress,
            c"/dir"
        ));
        assert_eq!(progress.entry_errors.load(Ordering::Relaxed), 1);
    }
}

#[cfg(test)]
mod volume_tests;
