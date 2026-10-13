//! How the scanner meets volumes that are not APFS.
//!
//! The first test answers `getattrlistbulk` the way an old or foreign file
//! system does: EINVAL when the extended common attributes are asked for. No
//! volume `hdiutil` can make answers that way on current macOS (HFS+, ExFAT,
//! FAT12/16/32, UDF and devfs all accept the request and just omit clone ids),
//! so the kernel's answer is injected, through the same test hook as the EINTR
//! tests, and everything after it is the real code.
//!
//! The rest scan real volumes through disk images: HFS+, ExFAT and FAT32, and
//! a volume mounted inside the scanned tree. `hdiutil` makes and mounts the
//! images in a disposable folder, with no root and nothing under /Volumes;
//! every image is detached again, even when an assertion fails. They need
//! `/usr/bin/hdiutil` and a few seconds each, so they are `#[ignore]`d: plain
//! `cargo test` reports them as ignored, never as passed, and
//! `tests/run-cleanup.sh` runs them with `--ignored` (or says SKIPPED when
//! there is no hdiutil). A failure to create or attach an image fails the test
//! with hdiutil's own message.

use super::*;
use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;

/// What this thread's `getattrlistbulk` calls answer instead of the kernel.
#[derive(Clone, Copy)]
enum Injected {
    Kernel,
    /// EINVAL whenever extended common attributes are requested.
    RefuseExtended,
    /// `errno` on the n-th call (1-based), the kernel on the others.
    FailCall(u32, c_int),
}

thread_local! {
    static INJECTED: Cell<Injected> = const { Cell::new(Injected::Kernel) };
    static CALLS: Cell<u32> = const { Cell::new(0) };
    static EXTENDED_REQUESTS: Cell<u32> = const { Cell::new(0) };
}

/// Called by `bulk_syscall` in test builds with the options of the call.
pub(super) fn injected_failure(options: u64) -> Option<c_int> {
    let call = CALLS.with(|c| {
        c.set(c.get() + 1);
        c.get()
    });
    if options & FSOPT_ATTR_CMN_EXTENDED != 0 {
        EXTENDED_REQUESTS.with(|c| c.set(c.get() + 1));
    }
    match INJECTED.with(Cell::get) {
        Injected::Kernel => None,
        Injected::RefuseExtended => {
            (options & FSOPT_ATTR_CMN_EXTENDED != 0).then_some(libc::EINVAL)
        }
        Injected::FailCall(n, errno) => (call == n).then_some(errno),
    }
}

fn inject(mode: Injected) {
    INJECTED.with(|c| c.set(mode));
    CALLS.with(|c| c.set(0));
    EXTENDED_REQUESTS.with(|c| c.set(0));
}

/// Removes its folder and stops injecting failures when dropped, so a failed
/// assertion cleans up too.
struct Fixture(PathBuf);

impl Drop for Fixture {
    fn drop(&mut self) {
        inject(Injected::Kernel);
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn einval_on_extended_attributes_falls_back_to_the_plain_set() {
    let root = std::fs::canonicalize(std::env::temp_dir())
        .unwrap()
        .join(format!("bz-test-einval-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let _cleanup = Fixture(root.clone());
    std::fs::create_dir_all(root.join("sub")).unwrap();
    for (name, bytes) in [("a", 10_000usize), ("b", 20_000), ("c", 1)] {
        std::fs::write(root.join(name), vec![7u8; bytes]).unwrap();
    }
    std::fs::write(root.join("sub/d"), vec![7u8; 30_000]).unwrap();
    let path = CString::new(root.as_os_str().as_encoded_bytes()).unwrap();
    let sub = CString::new(root.join("sub").as_os_str().as_encoded_bytes()).unwrap();

    // The volume refuses the extended attributes: the first call is asked
    // again for the plain set, nothing is lost, and the flag is remembered.
    let (mut scratch, progress) = (Scratch::default(), Progress::default());
    inject(Injected::RefuseExtended);
    let complete = read_dir_bulk(&path, &mut scratch, &progress);
    let (extended_first, calls_first) = (EXTENDED_REQUESTS.with(Cell::get), CALLS.with(Cell::get));
    assert_eq!(
        complete,
        Some(true),
        "the listing is complete after the retry"
    );
    assert_eq!(scratch.entries.len(), 4, "a, b, c and sub");
    assert!(
        scratch.entries.iter().all(|e| e.no_clone_id || e.is_dir),
        "no clone ids from a volume without extended attributes"
    );
    assert!(
        progress.no_extended_attrs.load(Ordering::Relaxed),
        "the refusal is remembered"
    );
    assert_eq!(
        progress.errors.load(Ordering::Relaxed),
        0,
        "falling back is not an error"
    );
    assert_eq!(extended_first, 1, "the extended set was asked for once");
    assert!(calls_first >= 2, "and the plain set asked for after it");

    // Later directories ask for the plain set straight away.
    inject(Injected::RefuseExtended);
    assert_eq!(read_dir_bulk(&sub, &mut scratch, &progress), Some(true));
    assert_eq!(scratch.entries.len(), 1);
    assert_eq!(
        EXTENDED_REQUESTS.with(Cell::get),
        0,
        "no more extended requests once refused"
    );

    // A whole scan with the flag already set reads the same tree.
    inject(Injected::Kernel);
    let sizes = |p: &Progress| scan(&root, p);
    let plain = Progress::default();
    plain.no_extended_attrs.store(true, Ordering::Relaxed);
    let (with_fallback, normal) = (sizes(&plain), sizes(&Progress::default()));
    assert_eq!(
        (with_fallback.n_files[0], with_fallback.logical[0]),
        (normal.n_files[0], normal.logical[0])
    );
    assert_eq!(with_fallback.n_files[0], 4);
    assert_eq!(with_fallback.logical[0], 60_001);

    // An EINVAL after entries were already read is a real failure, not a
    // reason to start over: nothing may be listed twice.
    let (mut scratch, progress) = (Scratch::default(), Progress::default());
    inject(Injected::FailCall(2, libc::EINVAL));
    let complete = read_dir_bulk(&path, &mut scratch, &progress);
    inject(Injected::Kernel);
    assert_eq!(
        complete,
        Some(false),
        "a failure mid-listing leaves the directory partial"
    );
    assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
    assert!(
        !progress.no_extended_attrs.load(Ordering::Relaxed),
        "only a refusal on the first call switches to the plain set"
    );
    assert_eq!(
        scratch.entries.len(),
        4,
        "what was read before the failure is kept, once"
    );

    // Any other first-call failure is an error too, not a fallback.
    let (mut scratch, progress) = (Scratch::default(), Progress::default());
    inject(Injected::FailCall(1, libc::EIO));
    let complete = read_dir_bulk(&path, &mut scratch, &progress);
    inject(Injected::Kernel);
    assert_eq!(complete, Some(false));
    assert!(
        !progress.no_extended_attrs.load(Ordering::Relaxed)
            && progress.errors.load(Ordering::Relaxed) == 1
    );
    assert!(scratch.entries.is_empty());
}

/// hdiutil attaches one image at a time; the tests share the machine's disk
/// arbitration, so they take turns.
static ONE_IMAGE_AT_A_TIME: Mutex<()> = Mutex::new(());

fn hdiutil(args: &[&str]) {
    let out = Command::new("/usr/bin/hdiutil")
        .args(args)
        .output()
        .unwrap_or_else(|e| panic!("cannot run hdiutil: {e}"));
    assert!(
        out.status.success(),
        "hdiutil {} failed ({}): {}",
        args.join(" "),
        out.status,
        String::from_utf8_lossy(&out.stderr)
    );
}

/// A mounted image. Dropping it detaches the volume and removes its folder.
struct Volume {
    work: PathBuf,
    mount: PathBuf,
}

impl Volume {
    /// Creates a sparse image formatted `fs` ("HFS+", "ExFAT", "MS-DOS FAT32")
    /// under a fresh folder in the temp directory, mounted at `mount_in_work`
    /// (a path relative to that folder, created if missing).
    fn attach(fs: &str, label: &str, mount_in_work: &str) -> Volume {
        let temp = std::fs::canonicalize(std::env::temp_dir()).unwrap();
        let work = temp.join(format!(
            "bz-image-{}-{}",
            std::process::id(),
            label.to_lowercase()
        ));
        let _ = std::fs::remove_dir_all(&work);
        std::fs::create_dir_all(&work).unwrap();
        let mount = work.join(mount_in_work);
        std::fs::create_dir_all(&mount).unwrap();
        let image = work.join("disk");
        // Constructed first so a failed attach still removes the folder.
        let volume = Volume { work, mount };
        hdiutil(&[
            "create",
            "-quiet",
            "-size",
            "64m",
            "-type",
            "SPARSE",
            "-fs",
            fs,
            "-volname",
            label,
            image.to_str().unwrap(),
        ]);
        hdiutil(&[
            "attach",
            "-quiet",
            "-nobrowse",
            "-noverify",
            "-mountpoint",
            volume.mount.to_str().unwrap(),
            volume.work.join("disk.sparseimage").to_str().unwrap(),
        ]);
        volume
    }
}

impl Drop for Volume {
    fn drop(&mut self) {
        // -force: a file left open by a failed test must not keep the image mounted.
        let _ = Command::new("/usr/bin/hdiutil")
            .args(["detach", "-quiet", "-force"])
            .arg(&self.mount)
            .status();
        let _ = std::fs::remove_dir_all(&self.work);
    }
}

fn node(t: &Tree, path: &str) -> usize {
    let mut at = 0;
    for part in path.split('/') {
        at = t
            .kids(at)
            .iter()
            .map(|&k| k as usize)
            .find(|&k| t.name(k) == part)
            .unwrap_or_else(|| panic!("{path}: no {part:?} under {:?}", t.path(at)));
    }
    at
}

fn write(root: &Path, relative: &str, bytes: usize) {
    let path = root.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, vec![0x42u8; bytes]).unwrap();
}

/// (path, bytes): ASCII names only, since HFS+ stores names decomposed.
const FILES: [(&str, usize); 7] = [
    ("empty", 0),
    ("one-byte", 1),
    ("small.txt", 5_000),
    ("docs/readme.md", 70_000),
    ("docs/deep/er/blob.bin", 1_048_576),
    ("media/clip.mov", 3_000_000),
    ("media/photo.jpg", 400_000),
];

/// Each file system gets the same tree; the scan must find every file with
/// its exact logical size and a plausible allocated size, whichever way the
/// volume answers getattrlistbulk.
#[test]
#[ignore = "needs /usr/bin/hdiutil: scans HFS+, ExFAT and FAT32 disk images (run by tests/run-cleanup.sh)"]
fn scan_is_exact_on_non_apfs_volumes() {
    let _turn = ONE_IMAGE_AT_A_TIME
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    for (fs, label) in [
        ("HFS+", "BZHFS"),
        ("ExFAT", "BZEXFAT"),
        ("MS-DOS FAT32", "BZFAT"),
    ] {
        let volume = Volume::attach(fs, label, "mnt");
        for (path, bytes) in FILES {
            write(&volume.mount, path, bytes);
        }
        // Only HFS+ of the three has hard links.
        let hard_links = fs == "HFS+";
        if hard_links {
            write(&volume.mount, "links/a.bin", 40_000);
            std::fs::hard_link(
                volume.mount.join("links/a.bin"),
                volume.mount.join("links/b.bin"),
            )
            .unwrap();
        }
        let progress = Progress::default();
        let tree = scan(&volume.mount, &progress);

        assert_eq!(tree.errors, 0, "{fs}: a clean volume scans without errors");
        let mut logical = 0u64;
        for (path, bytes) in FILES {
            let i = node(&tree, path);
            assert!(!tree.is_dir(i), "{fs}: {path} is a file");
            assert_eq!(tree.logical[i], bytes as u64, "{fs}: {path} logical size");
            // Allocation is at least the data and at most a generous cluster of slack.
            assert!(
                tree.alloc[i] >= bytes as u64,
                "{fs}: {path} allocated {} for {bytes} bytes",
                tree.alloc[i]
            );
            assert!(
                tree.alloc[i] <= bytes as u64 + (256 << 10),
                "{fs}: {path} allocated {} for {bytes} bytes",
                tree.alloc[i]
            );
            logical += bytes as u64;
        }
        // The file system's own bookkeeping (.fseventsd, .Trashes ...) may add files;
        // ours are all there and nothing of ours is counted twice.
        assert!(
            tree.n_files[0] as usize >= FILES.len(),
            "{fs}: {} files",
            tree.n_files[0]
        );
        assert!(
            tree.logical[0] >= logical,
            "{fs}: root logical {} < {logical}",
            tree.logical[0]
        );
        let dirs = ["docs", "docs/deep", "docs/deep/er", "media"];
        for d in dirs {
            assert!(tree.is_dir(node(&tree, d)), "{fs}: {d} is a folder");
        }
        // FAT-family volumes keep AppleDouble "._name" files for extended
        // attributes, which are real files and counted, so totals are checked
        // for being consistent rather than equal to what was written.
        for i in 0..tree.len().min(10_000) {
            if tree.is_dir(i) {
                let kids = tree.kids(i).iter().map(|&k| k as usize);
                assert_eq!(
                    tree.logical[i],
                    kids.clone().map(|k| tree.logical[k]).sum::<u64>(),
                    "{fs}: {:?} logical total",
                    tree.path(i)
                );
                assert_eq!(
                    tree.alloc[i],
                    kids.clone().map(|k| tree.alloc[k]).sum::<u64>(),
                    "{fs}: {:?} allocated total",
                    tree.path(i)
                );
                let files = kids
                    .map(|k| if tree.is_dir(k) { tree.n_files[k] } else { 1 })
                    .sum::<u32>();
                assert_eq!(
                    tree.n_files[i],
                    files,
                    "{fs}: {:?} file count",
                    tree.path(i)
                );
            }
        }
        assert!(
            tree.logical[node(&tree, "docs")] >= 70_000 + (1 << 20),
            "{fs}: docs holds its files"
        );
        assert!(
            tree.n_files[node(&tree, "media")] >= 2,
            "{fs}: media holds its files"
        );
        assert_eq!(
            progress.skipped_mount_points.load(Ordering::Relaxed),
            0,
            "{fs}: scanning the volume itself skips no mount"
        );

        if hard_links {
            let (a, b) = (node(&tree, "links/a.bin"), node(&tree, "links/b.bin"));
            assert_eq!(
                tree.logical[a] + tree.logical[b],
                40_000,
                "{fs}: two names of one file count its bytes once"
            );
            assert!(
                tree.logical[a] == 0 || tree.logical[b] == 0,
                "{fs}: the second name carries no bytes"
            );
            assert_eq!(
                tree.n_files[node(&tree, "links")],
                2,
                "{fs}: both names are listed"
            );
            assert!(
                progress.shared_bytes.load(Ordering::Relaxed) >= 40_000,
                "{fs}: the shared bytes are reported"
            );
        }

        // None of these volumes reports clone ids, and the scan says so: clones
        // (there are none here) would count once per path.
        let fell = progress.no_extended_attrs.load(Ordering::Relaxed);
        let untracked = progress.clone_ids_unavailable_dirs.load(Ordering::Relaxed);
        eprintln!("{fs}: extended attributes refused (EINVAL): {fell}; directories without clone ids: {untracked}");
        assert!(
            untracked > 0,
            "{fs}: a volume without clone ids must be reported as such"
        );
    }
    // Which of these volumes answer EINVAL depends on the macOS release: none
    // does on the current one (see the log lines above), so the fallback
    // itself is exercised by `einval_on_extended_attributes_falls_back_to_the_plain_set`.
}

/// A volume mounted inside the scanned tree is a boundary: its files are not
/// counted, the mount point is a folder with nothing under it, the walk is
/// marked incomplete, and scanning the volume directly still works.
#[test]
#[ignore = "needs /usr/bin/hdiutil: mounts a disk image inside a scanned folder (run by tests/run-cleanup.sh)"]
fn mount_point_inside_the_scan_is_a_boundary() {
    let _turn = ONE_IMAGE_AT_A_TIME
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let volume = Volume::attach("HFS+", "BZINNER", "root/inner/vol");
    let root = volume.work.join("root");
    write(&root, "outer.bin", 100_000);
    write(&root, "inner/beside.bin", 20_000);
    write(&volume.mount, "inside.bin", 300_000);
    write(&volume.mount, "sub/more.bin", 50_000);

    let progress = Progress::default();
    let tree = scan(&root, &progress);
    assert_eq!(tree.errors, 0);
    assert_eq!(
        progress.skipped_mount_points.load(Ordering::Relaxed),
        1,
        "the volume is skipped once"
    );
    let vol = node(&tree, "inner/vol");
    assert!(
        tree.is_dir(vol) && tree.kids(vol).is_empty(),
        "the mount point is an empty folder"
    );
    assert_eq!(tree.alloc[vol], 0);
    assert_eq!(
        tree.logical[0], 120_000,
        "only the files on the scanned volume are counted"
    );
    assert_eq!(tree.n_files[0], 2);
    for hidden in ["inside.bin", "more.bin"] {
        assert!(
            (0..tree.len()).all(|i| tree.name(i) != hidden),
            "{hidden} lives on the other volume and must not appear"
        );
    }
    assert!(
        !tree.complete[0] && !tree.complete[node(&tree, "inner")],
        "a skipped boundary marks its ancestors partial"
    );
    assert!(
        tree.complete[node(&tree, "outer.bin")],
        "files beside it stay complete"
    );

    // Starting on the mounted volume itself is not a boundary.
    let progress = Progress::default();
    let inner = scan(&volume.mount, &progress);
    assert_eq!(progress.skipped_mount_points.load(Ordering::Relaxed), 0);
    assert_eq!(inner.logical[node(&inner, "sub")], 50_000);
    assert_eq!(inner.logical[node(&inner, "inside.bin")], 300_000);
}
