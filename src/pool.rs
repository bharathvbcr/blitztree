//! The one worker pool behind every parallel pass: the scan walk, name search
//! and the file-type breakdown.
//!
//! Its workers run at USER_INITIATED QoS. Inside a GUI app that keeps them on
//! the performance cores (at the app's default QoS they land on the efficiency
//! cores and run about twice as slowly), yet they do not outrank the UI and the
//! system compositor the way USER_INTERACTIVE does: with a USER_INTERACTIVE
//! worker on every core the window (and screen recordings) skipped frames for
//! a quarter second mid-scan. The scan coordinator thread uses the same class,
//! through the same helper.
//!
//! The pool is built once, on first use, and lives for the process. The worker
//! count is rayon's default, so `RAYON_NUM_THREADS` still sets it (the bench
//! harness's thread argument relies on that, and sets it before first use).
//!
//! Entry points call `run` once, at the top. A call made from a worker of this
//! pool runs inline, so the nested parallel passes inside (the type breakdown
//! recurses into big folders) never wait on a worker they are occupying.
//! Nothing run on the pool may block on another job that needs a free worker.
//! One consequence: rayon serves a worker's own spawned jobs before work
//! injected from outside, so a search or breakdown issued while a scan is
//! walking waits for the walk to run low on work.

use std::ffi::c_int;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError};

use rayon::{ThreadPool, ThreadPoolBuildError, ThreadPoolBuilder};

extern "C" {
    fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: c_int) -> c_int;
}

const QOS_CLASS_USER_INITIATED: u32 = 0x19;

/// Put the calling thread in the USER_INITIATED class. Only its scheduling
/// class changes; a failure leaves the thread at the class it had.
pub(crate) fn set_thread_qos_user_initiated() {
    // SAFETY: the call touches nothing but the calling thread's QoS class.
    unsafe { pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) };
}

static POOL: OnceLock<ThreadPool> = OnceLock::new();

fn build() -> Result<ThreadPool, ThreadPoolBuildError> {
    let pool = ThreadPoolBuilder::new()
        .thread_name(|i| format!("bz-worker-{i}"))
        .start_handler(|_| set_thread_qos_user_initiated())
        .build()?;
    #[cfg(test)]
    probe::BUILT.fetch_add(1, Ordering::Relaxed);
    Ok(pool)
}

/// The pool in `cell`, built by `build` on first use. If it cannot be built
/// (the system refused the threads) the answer is None, a message is written
/// to stderr, and the next call tries again: callers then run on rayon's
/// global pool, which is correct but may land on the efficiency cores.
fn get_or_build(
    cell: &OnceLock<ThreadPool>,
    build: impl FnOnce() -> Result<ThreadPool, ThreadPoolBuildError>,
) -> Option<&ThreadPool> {
    if let Some(pool) = cell.get() {
        return Some(pool);
    }
    // One build at a time, so racing first callers never make two pools.
    static BUILDING: Mutex<()> = Mutex::new(());
    let _building = BUILDING.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(pool) = cell.get() {
        return Some(pool);
    }
    match build() {
        Ok(pool) => Some(cell.get_or_init(|| pool)),
        Err(error) => {
            static WARNED: AtomicBool = AtomicBool::new(false);
            if !WARNED.swap(true, Ordering::Relaxed) {
                // Not eprintln!: it panics when stderr is closed.
                let _ = writeln!(
                    std::io::stderr(),
                    "[bz] cannot start the USER_INITIATED worker pool ({error}); \
                     running on rayon's global pool, which may use the efficiency cores"
                );
            }
            None
        }
    }
}

fn run_on<R: Send>(pool: Option<&ThreadPool>, work: impl FnOnce() -> R + Send) -> R {
    match pool {
        Some(pool) => pool.install(work),
        None => work(),
    }
}

/// Run `work` on the shared pool, so every rayon call inside it does too, and
/// return its result. A panic inside is re-raised here and the pool survives.
pub(crate) fn run<R: Send>(work: impl FnOnce() -> R + Send) -> R {
    #[cfg(test)]
    probe::RUNS.with(|n| n.set(n.get() + 1));
    run_on(get_or_build(&POOL, build), work)
}

/// How many workers `run` uses (rayon's global pool's count if the shared
/// pool cannot be built).
pub(crate) fn threads() -> usize {
    run(rayon::current_num_threads)
}

#[cfg(test)]
pub(crate) mod probe {
    //! What the tests observe about the pool and the threads around it.
    use std::cell::Cell;
    use std::collections::HashMap;
    use std::ffi::c_int;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::AtomicUsize;
    use std::sync::Mutex;

    /// Pools built in this process.
    pub(crate) static BUILT: AtomicUsize = AtomicUsize::new(0);

    thread_local! {
        /// `run` calls made from this thread.
        pub(crate) static RUNS: Cell<usize> = const { Cell::new(0) };
    }

    /// Scan coordinator threads' QoS class by scan root; see `record_coordinator`.
    static COORDINATORS: Mutex<Option<HashMap<PathBuf, u32>>> = Mutex::new(None);

    extern "C" {
        fn pthread_get_qos_class_np(
            thread: libc::pthread_t,
            qos_class: *mut u32,
            relative_priority: *mut c_int,
        ) -> c_int;
    }

    /// The calling thread's QoS class (0x19 is USER_INITIATED), 0 if unreadable.
    pub(crate) fn current_qos() -> u32 {
        let mut class = 0u32;
        let mut relative = 0 as c_int;
        // SAFETY: both out-pointers are live locals; the thread is the caller itself.
        let rc =
            unsafe { pthread_get_qos_class_np(libc::pthread_self(), &mut class, &mut relative) };
        if rc == 0 {
            class
        } else {
            0
        }
    }

    /// Called by the scan thread: remembers its QoS class under the scan root.
    pub(crate) fn record_coordinator(root: &Path) {
        COORDINATORS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_or_insert_with(HashMap::new)
            .insert(root.to_path_buf(), current_qos());
    }

    pub(crate) fn coordinator_qos(root: &Path) -> Option<u32> {
        COORDINATORS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()?
            .get(root)
            .copied()
    }
}

#[cfg(test)]
mod tests {
    use super::probe::*;
    use super::*;

    use crate::{ffi, Progress, Tree};
    use rayon::prelude::*;
    use std::path::PathBuf;
    use std::sync::atomic::AtomicUsize;
    use std::sync::mpsc;
    use std::time::Duration;

    /// Where `work` ran: thread, its name, its QoS class.
    fn where_am_i() -> (std::thread::ThreadId, Option<String>, u32) {
        let t = std::thread::current();
        (t.id(), t.name().map(str::to_owned), current_qos())
    }

    /// A scratch tree on disk: `dirs` folders of `files` files each, `/r/d<i>/f<j>.txt`.
    fn fixture(tag: &str, dirs: usize, files: usize) -> PathBuf {
        let root = std::env::temp_dir().join(format!("bz-pool-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for d in 0..dirs {
            let dir = root.join(format!("d{d}"));
            std::fs::create_dir_all(&dir).unwrap();
            for f in 0..files {
                std::fs::write(dir.join(format!("f{f}.txt")), b"x").unwrap();
            }
        }
        root
    }

    /// A finished in-memory tree of `n` files under the root, names `file<i>.<ext>`.
    fn flat_tree(n: usize) -> Tree {
        let mut t = Tree::with_root("/r");
        for i in 0..n {
            let ext = ["rs", "txt", "png"][i % 3];
            t.push(&format!("file{i}.{ext}"), 0, 1, (i % 101) as u64, false);
        }
        crate::finish(&mut t);
        t
    }

    fn within<T: Send + 'static>(
        secs: u64,
        what: &str,
        work: impl FnOnce() -> T + Send + 'static,
    ) -> T {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(work());
        });
        rx.recv_timeout(Duration::from_secs(secs))
            .unwrap_or_else(|_| panic!("{what}: no answer in {secs} s"))
    }

    #[test]
    fn work_runs_on_a_named_user_initiated_worker_not_the_caller() {
        let caller = std::thread::current().id();
        let (id, name, qos) = run(where_am_i);
        assert_ne!(id, caller, "the caller waits; a worker does the work");
        assert!(
            name.as_deref().is_some_and(|n| n.starts_with("bz-worker-")),
            "ran on {name:?}"
        );
        assert_eq!(
            qos, QOS_CLASS_USER_INITIATED,
            "workers run at USER_INITIATED"
        );
        // Also what rayon calls the current pool from inside, for every parallel iterator.
        let all_on_workers = run(|| {
            (0..4096).into_par_iter().all(|_| {
                std::thread::current()
                    .name()
                    .is_some_and(|n| n.starts_with("bz-worker-"))
            })
        });
        assert!(
            all_on_workers,
            "a parallel iterator started inside stays on the shared pool"
        );
    }

    #[test]
    fn the_scan_thread_and_the_workers_share_one_helper_and_class() {
        let class = std::thread::spawn(|| {
            set_thread_qos_user_initiated();
            current_qos()
        })
        .join()
        .unwrap();
        assert_eq!(class, QOS_CLASS_USER_INITIATED);
        assert_ne!(class, 0x21, "not USER_INTERACTIVE");
    }

    #[test]
    fn the_scan_coordinator_thread_is_user_initiated() {
        let root = fixture("coordinator", 3, 3);
        let progress = std::sync::Arc::new(Progress::default());
        let h = ffi::start_scan(root.clone(), progress);
        while unsafe { ffi::bz_scan_status(h) } == 0 {
            std::thread::sleep(Duration::from_millis(1));
        }
        ffi::bz_free(h);
        let qos = coordinator_qos(&root).expect("the scan thread recorded its class");
        assert_eq!(
            qos, QOS_CLASS_USER_INITIATED,
            "0x21 would be USER_INTERACTIVE"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_nested_run_is_inline_and_never_waits_for_a_free_worker() {
        let inline: usize = within(60, "nested run", || {
            run(|| {
                (0..2000usize)
                    .into_par_iter()
                    .map(|_| {
                        // Every worker may be inside this closure at once.
                        let (inner, _, _) = run(where_am_i);
                        usize::from(inner == std::thread::current().id())
                    })
                    .sum()
            })
        });
        assert_eq!(
            inline, 2000,
            "each nested run executed on the worker that made it"
        );
    }

    #[test]
    fn a_run_from_another_pools_worker_completes() {
        let other = rayon::ThreadPoolBuilder::new()
            .num_threads(2)
            .build()
            .unwrap();
        let total: u64 = within(60, "run from a foreign pool", move || {
            other.install(|| {
                (0..64u64)
                    .into_par_iter()
                    .map(|i| run(|| (0..100u64).into_par_iter().sum::<u64>() + i))
                    .sum()
            })
        });
        assert_eq!(total, 64 * 4950 + (0..64u64).sum::<u64>());
    }

    #[test]
    fn a_panic_inside_work_reaches_the_caller_and_the_pool_keeps_working() {
        let result = std::panic::catch_unwind(|| run(|| -> u32 { panic!("inside the pool") }));
        assert!(result.is_err());
        assert_eq!(run(|| (0..1000u32).into_par_iter().sum::<u32>()), 499_500);
    }

    #[test]
    fn a_pool_that_cannot_be_built_falls_back_to_the_caller_and_is_retried() {
        let cell = OnceLock::new();
        let refused = || {
            ThreadPoolBuilder::new()
                .spawn_handler(|_| Err(std::io::Error::other("injected: no threads")))
                .build()
        };
        assert!(
            get_or_build(&cell, refused).is_none(),
            "the failure is not hidden as a pool"
        );
        assert!(cell.get().is_none(), "a failed build is not remembered");
        let caller = std::thread::current().id();
        assert_eq!(
            run_on(None, || std::thread::current().id()),
            caller,
            "the fallback runs the work"
        );
        let pool = get_or_build(&cell, build).expect("the retry builds the pool");
        let again = get_or_build(&cell, || panic!("a built pool is not rebuilt")).unwrap();
        assert!(std::ptr::eq(pool, again));
    }

    #[test]
    fn scans_searches_and_breakdowns_reuse_the_one_pool() {
        run(|| ());
        let built = BUILT.load(Ordering::Relaxed);
        let tree = flat_tree(100_000);
        let root = fixture("reuse", 4, 5);
        let runs = || RUNS.with(|n| n.get());

        let before = runs();
        let (total, top) = tree.search("file9", 5);
        assert!(total > 0 && top.len() == 5);
        assert_eq!(runs(), before + 1, "search enters the shared pool");
        let before = runs();
        assert!(!tree.types(0).is_empty());
        assert_eq!(
            runs(),
            before + 1,
            "the type breakdown enters the shared pool"
        );
        for _ in 0..5 {
            let before = runs();
            let scanned = crate::scan(&root, &Progress::default());
            assert_eq!(scanned.n_files[0], 20);
            assert_eq!(runs(), before + 1, "a scan enters the shared pool");
        }
        assert_eq!(
            BUILT.load(Ordering::Relaxed),
            built,
            "no scan, search or breakdown built another pool"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_empty_tree_has_nothing_to_search_or_total() {
        let mut only_root = Tree::with_root("/r");
        crate::finish(&mut only_root);
        assert_eq!(only_root.search("a", 10), (0, Vec::new()));
        assert!(only_root.types(0).is_empty());
        assert_eq!(Tree::default().search("a", 10), (0, Vec::new()));
        assert!(Tree::default().types(0).is_empty());
    }

    #[test]
    fn many_threads_scanning_searching_and_totalling_at_once_agree_with_one_thread() {
        let tree = std::sync::Arc::new(flat_tree(150_000));
        let expected_search = tree.search("file1", 20);
        let expected_types = tree.types(0);
        let root = fixture("concurrent", 12, 25);
        let passes = within(180, "concurrent passes", {
            let (tree, root) = (tree.clone(), root.clone());
            move || {
                let ok = AtomicUsize::new(0);
                std::thread::scope(|s| {
                    for t in 0..12 {
                        let (tree, root, ok) = (&tree, &root, &ok);
                        let (expected_search, expected_types) = (&expected_search, &expected_types);
                        s.spawn(move || {
                            for round in 0..4 {
                                match (t + round) % 3 {
                                    0 => assert_eq!(&tree.search("file1", 20), expected_search),
                                    1 => assert_eq!(&tree.types(0), expected_types),
                                    _ => {
                                        let scanned = crate::scan(root, &Progress::default());
                                        assert_eq!(scanned.n_files[0], 300);
                                    }
                                }
                                ok.fetch_add(1, Ordering::Relaxed);
                            }
                        });
                    }
                });
                ok.load(Ordering::Relaxed)
            }
        });
        assert_eq!(passes, 12 * 4, "every pass on every thread finished");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_search_issued_while_a_scan_runs_still_finishes_with_the_right_answer() {
        let tree = std::sync::Arc::new(flat_tree(120_000));
        let expected = tree.search("file7", 10);
        let root = fixture("during-scan", 150, 40);
        let progress = std::sync::Arc::new(Progress::default());
        let h = ffi::start_scan(root.clone(), progress);
        let searched = within(120, "search during a scan", {
            let tree = tree.clone();
            move || {
                (0..20)
                    .map(|_| tree.search("file7", 10))
                    .collect::<Vec<_>>()
            }
        });
        assert!(searched.iter().all(|r| *r == expected));
        while unsafe { ffi::bz_scan_status(h) } == 0 {
            std::thread::sleep(Duration::from_millis(1));
        }
        ffi::bz_free(h);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cancelling_a_scan_while_searches_run_ends_both_without_a_wedge() {
        let tree = std::sync::Arc::new(flat_tree(120_000));
        let expected = tree.search("file3", 10);
        let root = fixture("cancel-search", 100, 40);
        within(120, "cancel during search", move || {
            for round in 0..10u64 {
                let progress = std::sync::Arc::new(Progress::default());
                let h = ffi::start_scan(root.clone(), progress.clone());
                let searcher = {
                    let tree = tree.clone();
                    std::thread::spawn(move || {
                        (0..5).map(|_| tree.search("file3", 10)).collect::<Vec<_>>()
                    })
                };
                std::thread::sleep(Duration::from_micros(200 * round));
                progress.cancel();
                for r in searcher.join().unwrap() {
                    assert_eq!(r, expected);
                }
                while unsafe { ffi::bz_scan_status(h) } == 0 {
                    std::thread::sleep(Duration::from_millis(1));
                }
                ffi::bz_free(h);
            }
            let _ = std::fs::remove_dir_all(&root);
        });
    }
}
