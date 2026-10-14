//! CSV export of a scanned tree, streamed to disk.
//!
//! One writer serves the app (`bz_export_*` in `ffi.rs`) and the CLI
//! (`blitztree export-csv`). Nothing here builds the file in memory: the walk
//! is iterative, keeps one reusable path buffer and writes each row through a
//! `BufWriter`, so the memory a row costs is constant: the write buffer, the
//! path buffer and a stack as deep as the folder nesting, none of it growing
//! with the row count. The one allocation that scales with the tree is
//! `subtree_len`'s bitset for a folder export (n/8 bytes for n nodes, about
//! 125 KB per million nodes), used to size the progress bar; a whole-scan
//! export allocates none.
//!
//! # The file
//!
//! RFC 4180: a header row, then one row per node, every row ended by CRLF, the
//! file UTF-8 without a byte-order mark. Columns:
//!
//! | column            | value                                                       |
//! |-------------------|-------------------------------------------------------------|
//! | `path`            | the full path (the scan root's name, then each name below)  |
//! | `allocated_bytes` | on-disk bytes; a folder's is its subtree's total            |
//! | `logical_bytes`   | content bytes; a folder's is its subtree's total            |
//! | `file_count`      | a folder: files below it; a file (or link): 1               |
//! | `is_folder`       | `true` or `false`                                           |
//! | `complete`        | `true` when everything in the node's subtree was read       |
//!
//! These are the numbers the window and the JSON CLI show (`file_count` is
//! `report.rs::entry`'s, and the status bar's). Rows come in pre-order, a
//! folder before what it holds and its children largest first (the order of
//! `Tree::kids`, the list and the map). Symlinks are never followed: a link to
//! a folder is one `is_folder=false` row. A hard link or whole APFS clone
//! carries the data's bytes on one path only (the scan's accounting): the
//! other paths are rows with 0 bytes that still count as one file each.
//!
//! # Quoting
//!
//! A field is quoted when it contains a comma, a double quote, CR or LF, or
//! begins or ends with a space; a quote inside is doubled. Bytes are written
//! as the tree stores them. A child's name is valid UTF-8: the scan drops an
//! entry whose name is not (and counts it in `invalid_names`), so such an
//! entry has no row. The root's name is the path's encoded bytes, which may
//! not be UTF-8. A tree built some other way with other bytes in a name has
//! those bytes written unchanged, never replaced or skipped.
//!
//! # Spreadsheet formulas
//!
//! The only free-text column is `path`, and a path is absolute: it begins with
//! `/`, which no spreadsheet reads as a formula, so no file name can reach the
//! start of a cell. Should a tree's root name be relative and begin with
//! `=`, `+`, `-`, `@`, TAB or CR, the cell is quoted and prefixed with a single
//! quote (the usual neutralisation), so the spreadsheet shows text. Every
//! other column is a number or `true`/`false`.
//!
//! # Writing the file
//!
//! `export_file` writes to a hidden temporary file in the destination's folder
//! and renames it over the destination only when the whole file is written
//! and synced. A cancel, a write error or a vanished folder removes the
//! temporary file and leaves the destination as it was.

use std::fs::{File, OpenOptions};
use std::io::{self, BufWriter, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use crate::{join_name, Tree};

pub const HEADER: &str = "path,allocated_bytes,logical_bytes,file_count,is_folder,complete\r\n";

/// Buffered bytes before a write reaches the file.
const BUFFER: usize = 256 * 1024;

#[cfg(test)]
type RowHook = Box<dyn Fn(u64, &Control) + Send>;
#[cfg(test)]
type SyncHook = Box<dyn Fn(&Control) + Send>;

/// Progress and the stop switch of one export, shared with whoever watches
/// it. All of it is safe to read and set from any thread.
#[derive(Default)]
pub struct Control {
    cancelled: AtomicBool,
    rows_done: AtomicU64,
    rows_total: AtomicU64,
    /// Test seam: called after each row with the number of rows written.
    #[cfg(test)]
    row_hook: std::sync::Mutex<Option<RowHook>>,
    /// Test seam: called after the rows are written and before the file is synced.
    #[cfg(test)]
    before_sync: std::sync::Mutex<Option<SyncHook>>,
    /// Set only when `sync_all` actually runs, so a test can see a cancel that
    /// arrived in the window after the last row.
    #[cfg(test)]
    synced: AtomicBool,
}

impl Control {
    pub const fn new() -> Control {
        Control {
            cancelled: AtomicBool::new(false),
            rows_done: AtomicU64::new(0),
            rows_total: AtomicU64::new(0),
            #[cfg(test)]
            row_hook: std::sync::Mutex::new(None),
            #[cfg(test)]
            before_sync: std::sync::Mutex::new(None),
            #[cfg(test)]
            synced: AtomicBool::new(false),
        }
    }

    /// Ask the export to stop. It checks before every row, before the file is
    /// synced, and again before the rename. An export that has already renamed
    /// its file is done.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    /// Test seam: run `hook(rows_written, self)` after every row.
    #[cfg(test)]
    pub(crate) fn on_row(&self, hook: impl Fn(u64, &Control) + Send + 'static) {
        *self.row_hook.lock().unwrap() = Some(Box::new(hook));
    }

    /// Test seam: run `hook` after the last row and before `sync_all`.
    #[cfg(test)]
    pub(crate) fn before_sync(&self, hook: impl Fn(&Control) + Send + 'static) {
        *self.before_sync.lock().unwrap() = Some(Box::new(hook));
    }

    /// Whether `sync_all` ran. A cancelled export must leave this false.
    #[cfg(test)]
    pub(crate) fn did_sync(&self) -> bool {
        self.synced.load(Ordering::Relaxed)
    }

    #[cfg(test)]
    fn run_before_sync(&self) {
        if let Some(hook) = self.before_sync.lock().unwrap().as_ref() {
            hook(self);
        }
    }

    /// Rows written so far, refreshed every few thousand rows and at the end.
    pub fn rows_done(&self) -> u64 {
        self.rows_done.load(Ordering::Relaxed)
    }

    /// Rows the export will write; 0 until it has started.
    pub fn rows_total(&self) -> u64 {
        self.rows_total.load(Ordering::Relaxed)
    }
}

#[derive(Debug)]
pub enum Error {
    /// `Control::cancel` was called before the file was committed.
    Cancelled,
    /// The request itself is wrong: a node outside the tree, a tree that is
    /// not in the finished layout, a destination that cannot name a file.
    Invalid(String),
    /// The file system or the writer failed; `what` says doing what.
    Io { what: String, source: io::Error },
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Cancelled => f.write_str("The export was cancelled"),
            Error::Invalid(why) => f.write_str(why),
            Error::Io { what, source } => write!(f, "{what}: {source}"),
        }
    }
}

impl std::error::Error for Error {}

fn io_error(what: impl Into<String>) -> impl Fn(io::Error) -> Error {
    let what = what.into();
    move |source| Error::Io {
        what: what.clone(),
        source,
    }
}

/// What a finished export wrote.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Summary {
    pub rows: u64,
    pub bytes: u64,
}

/// Counts what passes through, so the summary can say how big the file is.
struct Counting<W> {
    inner: W,
    bytes: u64,
}

impl<W: Write> Write for Counting<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = self.inner.write(buf)?;
        self.bytes += n as u64;
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// One CSV field, quoted when it needs to be (see the module docs).
fn write_field(out: &mut impl Write, field: &[u8]) -> io::Result<()> {
    let formula = matches!(
        field.first(),
        Some(b'=' | b'+' | b'-' | b'@' | b'\t' | b'\r')
    );
    let quote = formula
        || field.first() == Some(&b' ')
        || field.last() == Some(&b' ')
        || field
            .iter()
            .any(|b| matches!(b, b',' | b'"' | b'\r' | b'\n'));
    if !quote {
        return out.write_all(field);
    }
    out.write_all(if formula { b"\"'" } else { b"\"" })?;
    let mut rest = field;
    while let Some(at) = rest.iter().position(|&b| b == b'"') {
        out.write_all(&rest[..=at])?;
        out.write_all(b"\"")?;
        rest = &rest[at + 1..];
    }
    out.write_all(rest)?;
    out.write_all(b"\"")
}

fn write_row(out: &mut impl Write, tree: &Tree, node: usize, path: &[u8]) -> io::Result<()> {
    write_field(out, path)?;
    let is_dir = tree.is_dir(node);
    write!(
        out,
        ",{},{},{},{},{}\r\n",
        tree.alloc[node],
        tree.logical[node],
        if is_dir { tree.n_files[node] } else { 1 },
        is_dir,
        tree.complete[node]
    )
}

/// The arrays a walk indexes agree in length: a tree not yet `finish`ed (no
/// child lists) is refused, not indexed out of range.
fn check_layout(tree: &Tree, root: usize) -> Result<(), Error> {
    let n = tree.len();
    let same = [
        tree.alloc.len(),
        tree.logical.len(),
        tree.n_files.len(),
        tree.flags.len(),
        tree.complete.len(),
    ]
    .iter()
    .all(|&len| len == n);
    if root >= n {
        return Err(Error::Invalid(format!(
            "Node {root} is not in the tree ({n} nodes)"
        )));
    }
    if !same || tree.child_off.len() != n + 1 || tree.name_off.len() != n + 1 {
        return Err(Error::Invalid(
            "The tree is not in its finished layout".into(),
        ));
    }
    Ok(())
}

/// How many nodes the pre-order walk from `root` visits. Children come after
/// their parent in the tree's numbering, so one forward pass over the parent
/// column finds them with a bit per node.
fn subtree_len(tree: &Tree, root: usize) -> u64 {
    if root == 0 {
        return tree.len() as u64;
    }
    let mut inside = vec![0u64; tree.len().div_ceil(64)];
    let has = |bits: &[u64], i: usize| bits[i / 64] >> (i % 64) & 1 != 0;
    inside[root / 64] |= 1 << (root % 64);
    let mut count = 1;
    for i in root + 1..tree.len() {
        let parent = tree.parents[i] as usize;
        if parent < i && has(&inside, parent) {
            inside[i / 64] |= 1 << (i % 64);
            count += 1;
        }
    }
    count
}

struct Frame {
    node: u32,
    next: u32,
    /// Length of `node`'s path in the shared path buffer.
    base: usize,
}

/// Stream the CSV of the subtree at `root` (the whole scan for node 0) to
/// `out`; returns the rows written. `out` should be buffered. Stops with
/// `Error::Cancelled` as soon as `ctl` is cancelled. Writes the header even
/// for a root with nothing below it.
pub fn write_csv<W: Write>(
    tree: &Tree,
    root: usize,
    out: &mut W,
    ctl: &Control,
) -> Result<u64, Error> {
    check_layout(tree, root)?;
    let total = subtree_len(tree, root);
    ctl.rows_total.store(total, Ordering::Relaxed);
    ctl.rows_done.store(0, Ordering::Relaxed);
    if ctl.is_cancelled() {
        return Err(Error::Cancelled);
    }
    let failed = io_error("Could not write the CSV");
    out.write_all(HEADER.as_bytes()).map_err(&failed)?;

    let mut path = tree.path_bytes(root);
    let mut rows = 0u64;
    let mut emit = |out: &mut W, node: usize, path: &[u8]| -> Result<(), Error> {
        write_row(out, tree, node, path).map_err(&failed)?;
        rows += 1;
        if rows > total {
            return Err(Error::Invalid(
                "The tree lists more nodes than it holds".into(),
            ));
        }
        if rows.is_multiple_of(4096) {
            ctl.rows_done.store(rows, Ordering::Relaxed);
        }
        #[cfg(test)]
        if let Some(hook) = ctl.row_hook.lock().unwrap().as_ref() {
            hook(rows, ctl);
        }
        if ctl.is_cancelled() {
            return Err(Error::Cancelled);
        }
        Ok(())
    };

    emit(out, root, &path)?;
    let mut stack = Vec::new();
    if !tree.kids(root).is_empty() {
        stack.push(Frame {
            node: root as u32,
            next: 0,
            base: path.len(),
        });
    }
    while let Some(top) = stack.last_mut() {
        let kids = tree.kids(top.node as usize);
        let Some(&child) = kids.get(top.next as usize) else {
            stack.pop();
            continue;
        };
        top.next += 1;
        path.truncate(top.base);
        join_name(&mut path, tree.name_bytes(child as usize));
        emit(out, child as usize, &path)?;
        if !tree.kids(child as usize).is_empty() {
            stack.push(Frame {
                node: child,
                next: 0,
                base: path.len(),
            });
        }
    }
    ctl.rows_done.store(rows, Ordering::Relaxed);
    Ok(rows)
}

/// A temporary file beside its destination; removed on drop unless committed.
struct Temp {
    path: PathBuf,
    file: Option<File>,
    committed: bool,
}

impl Temp {
    /// A new file next to `dest`, created exclusively (an existing path, link
    /// included, is never opened) with the name `.blitztree-export-…tmp`.
    fn create(dest: &Path) -> Result<Temp, Error> {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let folder = match dest.parent() {
            Some(p) if !p.as_os_str().is_empty() => p,
            _ => Path::new("."),
        };
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        for _ in 0..16 {
            let name = format!(
                ".blitztree-export-{}-{}-{nanos}.tmp",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            );
            let path = folder.join(name);
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => {
                    return Ok(Temp {
                        path,
                        file: Some(file),
                        committed: false,
                    })
                }
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => {
                    return Err(Error::Io {
                        what: format!("Could not create a file in {}", folder.display()),
                        source: e,
                    })
                }
            }
        }
        Err(Error::Invalid(format!(
            "Could not find a free temporary name in {}",
            folder.display()
        )))
    }

    /// Put the finished file in place of `dest`.
    fn commit(mut self, dest: &Path) -> Result<(), Error> {
        std::fs::rename(&self.path, dest)
            .map_err(io_error(format!("Could not save {}", dest.display())))?;
        self.committed = true;
        Ok(())
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        drop(self.file.take());
        if !self.committed {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// `dest` can name a file: it has a file name and is not a folder.
fn check_name(dest: &Path) -> Result<(), Error> {
    if dest.file_name().is_none() || dest.as_os_str().as_bytes().ends_with(b"/") {
        return Err(Error::Invalid(format!(
            "{} does not name a file",
            dest.display()
        )));
    }
    if dest.is_dir() {
        return Err(Error::Invalid(format!(
            "{} is a folder, not a file",
            dest.display()
        )));
    }
    Ok(())
}

/// Whether `export_file` could create its file at `dest` right now: the name
/// is usable and a temporary file can be made (and is removed again) in the
/// folder. For a caller that scans first and wants to fail before a long wait.
/// Nothing is reserved: the folder can still change before the export.
pub fn check_destination(dest: &Path) -> Result<(), Error> {
    check_name(dest)?;
    Temp::create(dest).map(drop)
}

/// Replacing a regular file keeps its permission bits (rwx for owner, group
/// and others), set on the new file before any of the CSV is written: a 0600
/// file must not come back 0644. Without a regular file at `dest` (nothing
/// there, or a link, which is replaced rather than followed) the new file
/// keeps the mode the umask gives it. Owner, ACLs, extended attributes and
/// hard links of the old file are not carried over: the new file is a rename.
fn keep_mode(file: &File, dest: &Path) -> Result<(), Error> {
    use std::os::unix::fs::PermissionsExt;
    let Ok(old) = std::fs::symlink_metadata(dest) else {
        return Ok(());
    };
    if !old.file_type().is_file() {
        return Ok(());
    }
    file.set_permissions(std::fs::Permissions::from_mode(
        old.permissions().mode() & 0o777,
    ))
    .map_err(io_error(format!(
        "Could not keep the permissions of {}",
        dest.display()
    )))
}

/// Export the subtree at `root` to the file `dest`, all or nothing: the CSV is
/// written to a temporary file in `dest`'s folder, synced, and renamed over
/// `dest`. Any error or a cancel before the rename leaves `dest` untouched and
/// no temporary file behind. An existing `dest` is replaced (a link there is
/// replaced, not followed) and keeps its permission bits (see `keep_mode`); a
/// folder there is an error.
pub fn export_file(tree: &Tree, root: usize, dest: &Path, ctl: &Control) -> Result<Summary, Error> {
    check_layout(tree, root)?;
    check_name(dest)?;
    let mut temp = Temp::create(dest)?;
    let file = temp.file.take().expect("a new temporary file is open");
    keep_mode(&file, dest)?;
    let mut out = Counting {
        inner: BufWriter::with_capacity(BUFFER, file),
        bytes: 0,
    };
    let rows = write_csv(tree, root, &mut out, ctl)?;
    let file = out.inner.into_inner().map_err(|e| Error::Io {
        what: "Could not write the CSV".into(),
        source: e.into_error(),
    })?;
    // A stop that arrived after the last row must not wait out a sync of a
    // file that will be discarded. A stop that arrives during the sync still
    // wins before the rename. One after the rename is too late.
    #[cfg(test)]
    ctl.run_before_sync();
    if ctl.is_cancelled() {
        return Err(Error::Cancelled);
    }
    #[cfg(test)]
    ctl.synced.store(true, Ordering::Relaxed);
    file.sync_all()
        .map_err(io_error("Could not write the CSV"))?;
    drop(file);
    if ctl.is_cancelled() {
        return Err(Error::Cancelled);
    }
    let bytes = out.bytes;
    temp.commit(dest)?;
    Ok(Summary { rows, bytes })
}

#[cfg(test)]
mod tests;
