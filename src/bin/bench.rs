//! Benchmark harness: compares scan strategies on a real directory tree.
//!
//! Usage: bench <mode> <path> [threads]
//!   modes: bulk        - parallel getattrlistbulk (our engine)
//!          ffi         - full app scan, flatten, handoff, and free
//!          digest      - ffi, then check the flat arrays' invariants and print
//!                        an order-independent digest of every (path, sizes, kind)
//!   BZ_DUMP=<file> (digest) also writes the sorted rows, for diffing.
//!   BZ_INCOMPLETE=<file> (bulk) writes the sorted paths of incomplete subtrees.
//!          search      - scan path, then benchmark interactive query matching
//!          search-synth- benchmark matching over synthetic 3.6M-entry disk scan
//!                        (BZ_SYNTH_COUNT sizes it; BZ_SYNTH_TIES=1 gives every entry
//!                        the same size, so top-K is decided by the path tie-break)
//!          types       - scan path, then time the file-type breakdown of the root
//!                        and of its largest folder (BZ_RUNS, default 11)
//!          search-during-scan - back-to-back synthetic searches while a scan of path runs
//!          scan-repeat - scan path BZ_RUNS (11) times in one process; first, min, median
//!          hardlink-fixture - create <path> (must not exist): BZ_HL_PROJECTS (200)
//!                        deep folders of BZ_HL_FILES (500) files each, every folder
//!                        after the first hard-linked to the first's files, or
//!                        independent files with BZ_HL_UNIQUE=1 (the control)
//!          naive       - serial read_dir + per-file lstat (Disk Inventory X style)
//!          naive-par   - parallel read_dir + per-file lstat
//!   BZ_TOP=1 also prints each top-level entry's allocated bytes (for diffing).
//!   BZ_JSON=1 emits machine-readable totals and timing.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use blitztree::{scan, Progress};

/// `n` entries under one root, named like a disk scan's; `ties` gives every entry
/// the same size, so a top-K selection is decided by the path tie-break.
fn synthetic_tree(n: usize, ties: bool) -> blitztree::Tree {
    let mut tree = blitztree::Tree::default();
    tree.parents.reserve(n);
    tree.alloc.reserve(n);
    tree.logical.reserve(n);
    tree.flags.reserve(n);
    tree.complete.reserve(n);
    tree.name_off.reserve(n + 1);
    tree.name_blob.reserve(n * 20);

    // Node 0 is root
    tree.parents.push(blitztree::NO_PARENT);
    tree.alloc.push(100_000_000_000);
    tree.logical.push(100_000_000_000);
    tree.flags.push(1);
    tree.complete.push(true);
    tree.name_off.push(0);
    let root_name = b"/System/Volumes/Data";
    tree.name_blob.extend_from_slice(root_name);
    tree.name_off.push(tree.name_blob.len() as u32);

    let extensions = [
        "png", "jpg", "pdf", "rs", "swift", "txt", "dylib", "json", "log", "münchen", "東京",
    ];
    for i in 1..n {
        let ext = extensions[i % extensions.len()];
        let name = format!(
            "entry_{i:07}_{}.{}",
            if i % 10 == 0 { "photo" } else { "file" },
            ext
        );
        tree.parents.push(0);
        let bytes = if ties {
            4096
        } else {
            (i as u64 * 1024) % 1_000_000_000
        };
        tree.alloc.push(bytes);
        tree.logical.push(bytes);
        tree.flags.push(if i % 8 == 0 { 1 } else { 0 });
        tree.complete.push(true);
        tree.name_blob.extend_from_slice(name.as_bytes());
        tree.name_off.push(tree.name_blob.len() as u32);
    }
    tree
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("bulk");
    let path = PathBuf::from(args.get(2).map(String::as_str).unwrap_or("."));
    if let Some(t) = args.get(3) {
        let threads: usize = t.parse().expect("threads must be a positive integer");
        assert!(threads > 0, "threads must be positive");
        // The shared worker pool (src/pool.rs) is built on first use with rayon's
        // default size, which reads this variable, so it must be set before any
        // scan, search or breakdown runs. Configuring only rayon's global pool
        // would leave the shared pool at the default thread count.
        std::env::set_var("RAYON_NUM_THREADS", threads.to_string());
    }

    let start = Instant::now();
    let (files, dirs, bytes, errors) = match mode {
        "bulk" => {
            let progress = Progress::default();
            let tree = scan(&path, &progress);
            if let Some(out) = std::env::var_os("BZ_INCOMPLETE") {
                let mut paths: Vec<_> = (0..tree.len())
                    .filter(|&i| !tree.complete[i])
                    .map(|i| tree.path(i).display().to_string())
                    .collect();
                paths.sort_unstable();
                std::fs::write(out, paths.join("\n")).unwrap();
            }
            if std::env::var_os("BZ_TOP").is_some() {
                for &c in tree.kids(0) {
                    eprintln!("TOP\t{}\t{}", tree.name(c as usize), tree.alloc[c as usize]);
                }
            }
            (
                tree.n_files[0] as u64,
                progress.dirs.load(Ordering::Relaxed),
                tree.alloc[0],
                tree.errors,
            )
        }
        "ffi" | "digest" => {
            use blitztree::ffi::*;
            let path = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
            let handle = bz_scan_start(path.as_ptr());
            let (mut files, mut dirs, mut bytes, mut done) = (0, 0, 0, 0);
            loop {
                bz_progress(handle, &mut files, &mut dirs, &mut bytes, &mut done);
                if done != 0 {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
            let n = bz_take_tree(handle) as usize;
            assert!(n > 0);
            if mode == "digest" {
                use std::slice::from_raw_parts as s;
                let v = unsafe {
                    let name_off = s(bz_name_off(handle), n + 1);
                    View {
                        parents: s(bz_parents(handle), n),
                        alloc: s(bz_alloc(handle), n),
                        logical: s(bz_logical(handle), n),
                        n_files: s(bz_nfiles(handle), n),
                        flags: s(bz_flags(handle), n),
                        child_off: s(bz_child_off(handle), n + 1),
                        children: s(bz_children(handle), n - 1),
                        name_off,
                        name_blob: s(bz_name_blob(handle), name_off[n] as usize),
                        errors: bz_errors(handle),
                        cleanup: (0..bz_cleanup_count(handle))
                            .map(|i| {
                                let label =
                                    std::ffi::CStr::from_ptr(bz_cleanup_description(handle, i));
                                (
                                    *bz_cleanup_nodes(handle).add(i as usize),
                                    label.to_string_lossy().into_owned(),
                                )
                            })
                            .collect(),
                    }
                };
                digest(&v);
            }
            let result = unsafe {
                (
                    *bz_nfiles(handle) as u64,
                    dirs,
                    *bz_alloc(handle),
                    bz_errors(handle),
                )
            };
            bz_free(handle);
            result
        }
        "bulk-count" => {
            let progress = Progress::default();
            blitztree::scan_count(&path, &progress);
            (
                progress.files.load(Ordering::Relaxed),
                progress.dirs.load(Ordering::Relaxed),
                progress.bytes.load(Ordering::Relaxed),
                progress.errors.load(Ordering::Relaxed),
            )
        }
        "search" => {
            let progress = Progress::default();
            let tree = scan(&path, &progress);
            let query = std::env::var("BZ_QUERY").unwrap_or_else(|_| "photo".to_string());
            let runs = 5;
            let mut min_dt = std::time::Duration::MAX;
            let mut total_matches = 0;
            let mut result_count = 0;
            for _ in 0..runs {
                let t0 = Instant::now();
                let (total, results) = tree.search(&query, 1000);
                let dt = t0.elapsed();
                if dt < min_dt {
                    min_dt = dt;
                }
                total_matches = total;
                result_count = results.len();
            }
            let entries = tree.len();
            let eps = entries as f64 / min_dt.as_secs_f64();
            if std::env::var_os("BZ_JSON").is_some() {
                println!(
                    "{{\"mode\":\"search\",\"query\":\"{query}\",\"entries\":{entries},\"matches\":{total_matches},\"returned\":{result_count},\"min_seconds\":{:.9},\"entries_per_sec\":{:.0}}}",
                    min_dt.as_secs_f64(),
                    eps
                );
                return;
            }
            println!(
                "search '{}' on {} entries: {:.3} ms (min of {runs}) -> {total_matches} matches (top {result_count} returned)  {:.0} entries/s",
                query,
                entries,
                min_dt.as_secs_f64() * 1000.0,
                eps
            );
            return;
        }
        "types" => {
            // The file-type breakdown for the scan root and for its largest
            // folder (a zoomed-in view), with the totals checked against the tree.
            let progress = Progress::default();
            let tree = scan(&path, &progress);
            let runs: usize = std::env::var("BZ_RUNS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(11);
            let largest_dir = tree
                .kids(0)
                .iter()
                .map(|&k| k as usize)
                .find(|&k| tree.is_dir(k));
            for (label, root) in [("root", Some(0)), ("largest-folder", largest_dir)] {
                let Some(root) = root else { continue };
                let mut times = Vec::with_capacity(runs);
                let mut rows = 0;
                for _ in 0..runs {
                    let t0 = Instant::now();
                    let b = tree.types(root);
                    times.push(t0.elapsed());
                    assert_eq!(
                        b.alloc.iter().sum::<u64>(),
                        tree.alloc[root],
                        "rows add up to the folder"
                    );
                    assert_eq!(
                        b.files.iter().sum::<u64>(),
                        tree.n_files[root] as u64,
                        "every file counted once"
                    );
                    rows = b.len();
                }
                times.sort();
                let (min, median) = (times[0], times[runs / 2]);
                let files = tree.n_files[root];
                if std::env::var_os("BZ_JSON").is_some() {
                    println!(
                        "{{\"mode\":\"types\",\"root\":\"{label}\",\"entries\":{},\"files\":{files},\"types\":{rows},\"runs\":{runs},\"min_seconds\":{:.9},\"median_seconds\":{:.9}}}",
                        tree.len(),
                        min.as_secs_f64(),
                        median.as_secs_f64()
                    );
                } else {
                    println!(
                        "types {label:>14}: {files:>9} files -> {rows:>6} extensions  min {:.2} ms  median {:.2} ms  ({runs} runs, {:.0} files/s)",
                        min.as_secs_f64() * 1e3,
                        median.as_secs_f64() * 1e3,
                        files as f64 / min.as_secs_f64()
                    );
                }
            }
            return;
        }
        "search-synth" => {
            let n: usize = std::env::var("BZ_SYNTH_COUNT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(3_600_000);
            let ties = std::env::var_os("BZ_SYNTH_TIES").is_some();
            println!("Building synthetic tree with {n} entries...");
            let tree = synthetic_tree(n, ties);

            println!("Synthetic tree ready. Benchmarking search queries (min of 5 runs each):");
            let test_queries = [
                "photo",             // substring (common)
                "entry_0000001",     // substring (rare)
                "*.png",             // wildcard extension
                "entry_*_photo.jpg", // complex wildcard
                "*münchen*",         // non-ASCII wildcard
                "東京*",             // non-ASCII prefix
            ];

            for q in test_queries {
                let mut min_dt = std::time::Duration::MAX;
                let mut total_matches = 0;
                let mut returned = 0;
                for _ in 0..5 {
                    let t0 = Instant::now();
                    let (total, res) = tree.search(q, 1000);
                    let dt = t0.elapsed();
                    if dt < min_dt {
                        min_dt = dt;
                    }
                    total_matches = total;
                    returned = res.len();
                }
                let ms = min_dt.as_secs_f64() * 1000.0;
                let eps = n as f64 / min_dt.as_secs_f64();
                println!(
                    "  {:20} -> {:8.2} ms  ({:7} matches, top {:4} returned)  {:10.0} entries/s",
                    format!("'{}'", q),
                    ms,
                    total_matches,
                    returned,
                    eps
                );
            }
            return;
        }
        "search-during-scan" => {
            // Searches a synthetic tree (BZ_SYNTH_COUNT, 1M) back to back while a
            // scan of `path` runs on its own threads, then the same searches idle.
            // Shows what a search costs when a scan holds the workers.
            let n: usize = std::env::var("BZ_SYNTH_COUNT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(1_000_000);
            let tree = synthetic_tree(n, false);
            let timed = || {
                let t0 = Instant::now();
                tree.search("photo", 1000);
                t0.elapsed().as_secs_f64() * 1e3
            };
            tree.search("photo", 1000);
            let idle = (0..5).map(|_| timed()).fold(f64::MAX, f64::min);

            use blitztree::ffi::*;
            let c_path = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
            let scan_started = Instant::now();
            let handle = bz_scan_start(c_path.as_ptr());
            let (mut files, mut dirs, mut bytes, mut done) = (0, 0, 0, 0);
            let mut during = Vec::new();
            loop {
                bz_progress(handle, &mut files, &mut dirs, &mut bytes, &mut done);
                if done != 0 {
                    break;
                }
                during.push(timed());
            }
            let scan_ms = scan_started.elapsed().as_secs_f64() * 1e3;
            bz_free(handle);
            during.sort_by(f64::total_cmp);
            let (searches, worst) = (during.len(), during.last().copied().unwrap_or(0.0));
            let median = during.get(searches / 2).copied().unwrap_or(0.0);
            println!(
                "search-during-scan: idle {idle:.2} ms  during {searches} searches: median {median:.2} ms  max {worst:.2} ms  (scan {scan_ms:.0} ms)"
            );
            return;
        }
        "scan-repeat" => {
            // BZ_RUNS (11) scans of the same folder in one process: what the app does
            // when it scans again. On a small folder the per-scan setup is most of it.
            let runs: usize = std::env::var("BZ_RUNS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(11);
            let mut times = Vec::with_capacity(runs);
            for _ in 0..runs {
                let t0 = Instant::now();
                let tree = scan(&path, &Progress::default());
                times.push(t0.elapsed());
                assert!(!tree.is_empty());
            }
            let first = times[0];
            times.sort();
            println!(
                "scan-repeat: first {:.3} ms  min {:.3} ms  median {:.3} ms  ({runs} scans)",
                first.as_secs_f64() * 1e3,
                times[0].as_secs_f64() * 1e3,
                times[runs / 2].as_secs_f64() * 1e3
            );
            return;
        }
        "hardlink-fixture" => {
            let env = |key: &str, default: usize| {
                std::env::var(key)
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(default)
            };
            let (projects, files) = (env("BZ_HL_PROJECTS", 200), env("BZ_HL_FILES", 500));
            let unique = std::env::var_os("BZ_HL_UNIQUE").is_some();
            // `path` must not exist yet; every project is a deep folder of `files` files.
            std::fs::create_dir(&path).expect("the fixture directory must be new");
            let folder = |project: usize| {
                path.join(format!(
                    "project-{project:04}/packages/linked/node_modules/package"
                ))
            };
            for project in 0..projects {
                let dir = folder(project);
                std::fs::create_dir_all(&dir).unwrap();
                for file in 0..files {
                    let name = format!("file-{file:04}.js");
                    if project == 0 || unique {
                        std::fs::write(dir.join(&name), [b'x'; 128]).unwrap();
                    } else {
                        std::fs::hard_link(folder(0).join(&name), dir.join(&name)).unwrap();
                    }
                }
            }
            println!(
                "{projects} projects x {files} files: {} ({} data streams)",
                if unique {
                    "independent files"
                } else {
                    "hard links to project 0's files"
                },
                if unique { projects * files } else { files }
            );
            return;
        }
        "naive" => {
            let mut c = Counts::default();
            naive_walk(&path, &mut c);
            (c.files, c.dirs, c.bytes, c.errors)
        }
        "naive-par" => {
            let c = AtomicCounts::default();
            rayon::scope(|s| naive_walk_par(s, &path, &c));
            (
                c.files.load(Ordering::Relaxed),
                c.dirs.load(Ordering::Relaxed),
                c.bytes.load(Ordering::Relaxed),
                c.errors.load(Ordering::Relaxed),
            )
        }
        m => {
            eprintln!("unknown mode {m}");
            std::process::exit(1);
        }
    };
    let dt = start.elapsed();

    let total = files + dirs;
    if std::env::var_os("BZ_JSON").is_some() {
        println!("{{\"mode\":\"{mode}\",\"seconds\":{:.9},\"files\":{files},\"dirs\":{dirs},\"bytes\":{bytes},\"errors\":{errors}}}", dt.as_secs_f64());
        return;
    }
    println!(
        "{mode:>9}  {:>8.3}s  {files:>9} files  {dirs:>8} dirs  {:>8.2} GB  {errors:>6} errs  {:>10.0} entries/s",
        dt.as_secs_f64(),
        bytes as f64 / 1e9,
        total as f64 / dt.as_secs_f64()
    );
}

#[derive(Default)]
struct Counts {
    files: u64,
    dirs: u64,
    bytes: u64,
    errors: u64,
}

fn naive_walk(dir: &Path, c: &mut Counts) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        c.errors += 1;
        return;
    };
    for entry in rd.flatten() {
        let (Ok(meta), Ok(ft)) = (entry.metadata(), entry.file_type()) else {
            c.errors += 1;
            continue;
        };
        if ft.is_dir() {
            c.dirs += 1;
            naive_walk(&entry.path(), c);
        } else {
            c.files += 1;
            c.bytes += meta.len();
        }
    }
}

#[derive(Default)]
struct AtomicCounts {
    files: AtomicU64,
    dirs: AtomicU64,
    bytes: AtomicU64,
    errors: AtomicU64,
}

fn naive_walk_par<'s>(scope: &rayon::Scope<'s>, dir: &Path, c: &'s AtomicCounts) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        c.errors.fetch_add(1, Ordering::Relaxed);
        return;
    };
    for entry in rd.flatten() {
        let Ok(meta) = entry.path().symlink_metadata() else {
            c.errors.fetch_add(1, Ordering::Relaxed);
            continue;
        };
        if meta.is_dir() {
            c.dirs.fetch_add(1, Ordering::Relaxed);
            let p = entry.path();
            scope.spawn(move |s| naive_walk_par(s, &p, c));
        } else {
            c.files.fetch_add(1, Ordering::Relaxed);
            c.bytes.fetch_add(meta.len(), Ordering::Relaxed);
        }
    }
}

/// The flat arrays exactly as the Swift UI sees them through the C ABI.
struct View<'a> {
    parents: &'a [u32],
    alloc: &'a [u64],
    logical: &'a [u64],
    n_files: &'a [u32],
    flags: &'a [u8],
    child_off: &'a [u32],
    children: &'a [u32],
    name_off: &'a [u32],
    name_blob: &'a [u8],
    errors: u64,
    /// Clean Up candidates in order: (node, label).
    cleanup: Vec<(u32, String)>,
}

const FNV: u64 = 0xcbf2_9ce4_8422_2325;
fn fnv(mut h: u64, bytes: &[u8]) -> u64 {
    for &b in bytes {
        h = (h ^ b as u64).wrapping_mul(0x100_0000_01b3);
    }
    h
}

/// Verify the flat tree's invariants, then hash it independently of node
/// order (which depends on thread scheduling).
fn digest(f: &View) {
    let n = f.parents.len();
    let name = |i: usize| &f.name_blob[f.name_off[i] as usize..f.name_off[i + 1] as usize];
    assert!(
        f.alloc.len() == n && f.logical.len() == n && f.n_files.len() == n && f.flags.len() == n
    );
    assert!(f.child_off.len() == n + 1 && f.name_off.len() == n + 1);
    assert_eq!(f.child_off[0], 0);
    assert_eq!(f.name_off[0], 0);
    assert_eq!(f.child_off[n] as usize, f.children.len());
    assert_eq!(f.children.len(), n - 1);
    assert_eq!(f.name_off[n] as usize, f.name_blob.len());
    assert_eq!(f.parents[0], u32::MAX);
    let mut seen = vec![false; n];
    for i in 0..n {
        let kids = &f.children[f.child_off[i] as usize..f.child_off[i + 1] as usize];
        let is_dir = f.flags[i] & 1 != 0;
        assert!(is_dir || kids.is_empty());
        let (mut a, mut l, mut nf) = (0u64, 0u64, 0u32);
        for (j, &k) in kids.iter().enumerate() {
            let k = k as usize;
            assert_eq!(f.parents[k] as usize, i, "child's parent");
            assert!(!seen[k], "child listed twice");
            seen[k] = true;
            assert!(
                j == 0 || f.alloc[kids[j - 1] as usize] >= f.alloc[k],
                "children sorted by alloc desc"
            );
            a += f.alloc[k];
            l += f.logical[k];
            nf += if f.flags[k] & 1 != 0 { f.n_files[k] } else { 1 };
        }
        if is_dir {
            assert_eq!(
                (f.alloc[i], f.logical[i], f.n_files[i]),
                (a, l, nf),
                "dir totals"
            );
        }
    }
    // Children always come after their parent, so paths hash in one pass.
    let mut ph = vec![0u64; n];
    for i in 0..n {
        let p = f.parents[i];
        ph[i] = if p == u32::MAX {
            fnv(FNV, name(i))
        } else {
            assert!((p as usize) < i, "parent before child");
            fnv(fnv(ph[p as usize], b"/"), name(i))
        };
    }
    // Child order by name: ties in size keep the directory's listing order.
    let order = |i: usize| {
        let kids = &f.children[f.child_off[i] as usize..f.child_off[i + 1] as usize];
        kids.iter()
            .fold(FNV, |h, &k| fnv(fnv(h, name(k as usize)), &[0xff]))
    };
    let mut rows: Vec<_> = (0..n)
        .map(|i| {
            (
                ph[i],
                f.alloc[i],
                f.logical[i],
                f.n_files[i],
                f.flags[i],
                order(i),
            )
        })
        .collect();
    rows.sort_unstable();
    // `shape` leaves out sizes and order.
    let (mut h, mut shape) = (FNV, FNV);
    for r in &rows {
        shape = fnv(shape, &r.0.to_le_bytes());
        shape = fnv(shape, &r.3.to_le_bytes());
        shape = fnv(shape, &[r.4]);
        h = fnv(h, &r.0.to_le_bytes());
        h = fnv(h, &r.1.to_le_bytes());
        h = fnv(h, &r.2.to_le_bytes());
        h = fnv(h, &r.3.to_le_bytes());
        h = fnv(h, &[r.4]);
        h = fnv(h, &r.5.to_le_bytes());
    }
    let mut cleanup = FNV;
    for (node, label) in &f.cleanup {
        cleanup = fnv(
            fnv(cleanup, &ph[*node as usize].to_le_bytes()),
            label.as_bytes(),
        );
    }
    println!(
        "digest {h:016x}  shape {shape:016x}  cleanup {cleanup:016x} ({})  nodes {n}  alloc {}  logical {}  files {}  errors {}  (invariants ok)",
        f.cleanup.len(), f.alloc[0], f.logical[0], f.n_files[0], f.errors
    );
    if let Some(out) = std::env::var_os("BZ_DUMP") {
        let mut paths: Vec<String> = Vec::with_capacity(n);
        let mut lines: Vec<String> = Vec::with_capacity(n);
        for i in 0..n {
            let nm = String::from_utf8_lossy(name(i));
            let p = f.parents[i];
            let path = if p == u32::MAX {
                nm.into_owned()
            } else {
                format!("{}/{}", paths[p as usize], nm)
            };
            let kids = &f.children[f.child_off[i] as usize..f.child_off[i + 1] as usize];
            let kids: Vec<_> = kids
                .iter()
                .map(|&k| String::from_utf8_lossy(name(k as usize)))
                .collect();
            let row = (f.alloc[i], f.logical[i], f.n_files[i], f.flags[i]);
            lines.push(format!(
                "{path}\t{}\t{}\t{}\t{}\t{}",
                row.0,
                row.1,
                row.2,
                row.3,
                kids.join("\x1f")
            ));
            paths.push(path);
        }
        lines.sort_unstable();
        std::fs::write(out, lines.join("\n")).unwrap();
    }
}
