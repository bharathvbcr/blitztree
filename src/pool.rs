//! The worker pools behind every parallel pass, one per role: the scan walk
//! runs on the `Scan` pool, name search and the file-type breakdown on the
//! `Query` pool.
//!
//! Workers run at USER_INITIATED QoS. Inside a GUI app that keeps them on the
//! performance cores (at the app's default QoS they land on the efficiency
//! cores and run about twice as slowly), yet they do not outrank the UI and the
//! system compositor the way USER_INTERACTIVE does: with a USER_INTERACTIVE
//! worker on every core the window (and screen recordings) skipped frames for
//! a quarter second mid-scan. The scan coordinator thread uses the same class,
//! through the same helper.
//!
//! Each pool is built once, on first use, and lives for the process, so a scan
//! no longer builds a pool of its own. Both have rayon's default worker count,
//! so `RAYON_NUM_THREADS` sets both (the bench harness's thread argument
//! relies on that, and sets it before first use).
//!
//! Why two. rayon serves a worker's own spawned jobs before work injected from
//! outside, so a search or breakdown injected into a pool that is walking a
//! tree waits until the walk has little left: measured with `bench
//! search-during-scan` on one shared pool, a search waited about as long as the
//! scan (~1.2 s) where it took 30-60 ms on rayon's global pool. Queries get
//! their own pool so they are never queued behind a scan; the operating system
//! shares the cores between the two.
//!
//! Entry points call `run` once, at the top. A call made from a worker of
//! either pool runs inline on that worker, whatever role it asks for. A hop
//! to the other pool would not deadlock (rayon's cross-pool `install` lets the
//! waiting worker steal work from its own pool meanwhile), but it adds a
//! handoff and leaves that worker running unrelated stolen jobs while its
//! caller waits; and the type breakdown, which recurses into big folders from
//! inside the pool, must stay on the worker already running it. Nothing run on
//! a pool may block on a job that needs a free worker of the same pool.
//!
//! If a pool cannot be built (the system refused the threads), callers run on
//! rayon's global pool: correct, but possibly on the efficiency cores. That is
//! reported once per outage on stderr. A scan's `Coverage` reads only the scan
//! pool, through `workers_degraded_for_scan`: a query-pool outage does not
//! change what the scan read. A GUI never sees stderr. A failed build is
//! retried no sooner than a doubling delay (2 s, 4 s, ... capped at 60 s)
//! later, so an outage costs one thread-spawn attempt per interval and not one
//! per call.

use std::cell::Cell;
use std::ffi::c_int;
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

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

/// What a pool is for: the walk of a scan, or the queries on a finished tree.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Role {
    Scan,
    Query,
}

static SCAN_POOL: OnceLock<ThreadPool> = OnceLock::new();
static QUERY_POOL: OnceLock<ThreadPool> = OnceLock::new();
static SCAN_OUTAGE: Outage = Outage::new();
static QUERY_OUTAGE: Outage = Outage::new();

/// How long to wait before trying to build a pool again.
#[derive(Clone, Copy)]
struct Backoff {
    first: Duration,
    cap: Duration,
}

const BACKOFF: Backoff = Backoff {
    first: Duration::from_secs(2),
    cap: Duration::from_secs(60),
};

impl Backoff {
    /// The wait after the `failures`-th failure in a row (1-based): `first`,
    /// doubling each time, never more than `cap`.
    fn delay(self, failures: u32) -> Duration {
        let doublings = failures.saturating_sub(1).min(31);
        self.first.saturating_mul(1u32 << doublings).min(self.cap)
    }
}

/// A role's record of failing to build its pool.
struct Outage {
    /// A build failed and none has succeeded since. Cheap to read.
    degraded: AtomicBool,
    /// Messages written to stderr, for the life of the process.
    reports: AtomicUsize,
    state: Mutex<OutageState>,
}

struct OutageState {
    /// Failed builds in a row.
    failures: u32,
    /// No attempt before this.
    retry_at: Option<Instant>,
}

impl Outage {
    const fn new() -> Outage {
        Outage {
            degraded: AtomicBool::new(false),
            reports: AtomicUsize::new(0),
            state: Mutex::new(OutageState {
                failures: 0,
                retry_at: None,
            }),
        }
    }
}

/// Whether `role`'s pool is unavailable right now.
pub(crate) fn role_outage(role: Role) -> bool {
    role.outage().degraded.load(Ordering::Relaxed)
}

/// `workers_degraded` on a scan's coverage. A query-pool outage is ignored:
/// search and the type breakdown run on their own pool and do not change
/// what the scan read. The query flag is an argument so the two cannot be
/// combined again without a test noticing.
pub(crate) fn workers_degraded_for_scan(scan_outage: bool, query_outage: bool) -> bool {
    let _ = query_outage;
    scan_outage
}

/// Whether the scan pool is unavailable. A query-pool outage is not included.
pub(crate) fn degraded() -> bool {
    workers_degraded_for_scan(role_outage(Role::Scan), role_outage(Role::Query))
}

impl Role {
    fn cell(self) -> &'static OnceLock<ThreadPool> {
        match self {
            Role::Scan => &SCAN_POOL,
            Role::Query => &QUERY_POOL,
        }
    }

    fn outage(self) -> &'static Outage {
        match self {
            Role::Scan => &SCAN_OUTAGE,
            Role::Query => &QUERY_OUTAGE,
        }
    }

    /// Worker thread names are `<prefix>-<index>`.
    fn prefix(self) -> &'static str {
        match self {
            Role::Scan => "bz-scan",
            Role::Query => "bz-query",
        }
    }
}

thread_local! {
    /// Set on the workers of our own pools, whichever role.
    static ON_OUR_WORKER: Cell<bool> = const { Cell::new(false) };
}

fn build(role: Role) -> Result<ThreadPool, ThreadPoolBuildError> {
    let pool = ThreadPoolBuilder::new()
        .thread_name(move |i| format!("{}-{i}", role.prefix()))
        .start_handler(|_| {
            ON_OUR_WORKER.with(|on| on.set(true));
            set_thread_qos_user_initiated();
        })
        .build()?;
    Ok(pool)
}

/// The pool in `cell`, built by `build` on first use. One build at a time (the
/// outage's lock), so racing first callers never make two pools.
///
/// If it cannot be built the answer is None and the outage is recorded: a
/// message goes to stderr for the first failure of an outage only, and no new
/// attempt is made before `backoff` has passed (by `now`, which tests supply).
/// A later success ends the outage, so the next one is reported again.
fn get_or_build<'a>(
    cell: &'a OnceLock<ThreadPool>,
    outage: &Outage,
    backoff: Backoff,
    now: Instant,
    build: impl FnOnce() -> Result<ThreadPool, ThreadPoolBuildError>,
) -> Option<&'a ThreadPool> {
    if let Some(pool) = cell.get() {
        return Some(pool);
    }
    let mut state = outage.state.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(pool) = cell.get() {
        return Some(pool);
    }
    if state.retry_at.is_some_and(|at| now < at) {
        return None;
    }
    match build() {
        Ok(pool) => {
            *state = OutageState {
                failures: 0,
                retry_at: None,
            };
            outage.degraded.store(false, Ordering::Relaxed);
            Some(cell.get_or_init(|| pool))
        }
        Err(error) => {
            state.failures = state.failures.saturating_add(1);
            state.retry_at = Some(now + backoff.delay(state.failures));
            if !outage.degraded.swap(true, Ordering::Relaxed) {
                outage.reports.fetch_add(1, Ordering::Relaxed);
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

/// Run `work` on the pool for `role`, so every rayon call inside it does too,
/// and return its result. Called from a worker of either of our pools it runs
/// inline instead. A panic inside is re-raised here and the pool survives.
pub(crate) fn run<R: Send>(role: Role, work: impl FnOnce() -> R + Send) -> R {
    #[cfg(test)]
    {
        probe::RUNS.with(|n| n.set(n.get() + 1));
        probe::LAST_ROLE.with(|r| r.set(Some(role)));
    }
    if ON_OUR_WORKER.with(Cell::get) {
        return work();
    }
    let pool = get_or_build(role.cell(), role.outage(), BACKOFF, Instant::now(), || {
        let pool = build(role);
        // Only the process's own pools count; tests build others on the side.
        #[cfg(test)]
        probe::BUILT.fetch_add(usize::from(pool.is_ok()), Ordering::Relaxed);
        pool
    });
    run_on(pool, work)
}

/// How many workers the scan pool has (rayon's global pool's count if it
/// cannot be built).
pub(crate) fn threads() -> usize {
    run(Role::Scan, rayon::current_num_threads)
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

    use super::Role;

    /// Pools built in this process.
    pub(crate) static BUILT: AtomicUsize = AtomicUsize::new(0);

    thread_local! {
        /// `run` calls made from this thread, and the role of the latest.
        pub(crate) static RUNS: Cell<usize> = const { Cell::new(0) };
        pub(crate) static LAST_ROLE: Cell<Option<Role>> = const { Cell::new(None) };
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
    fn work_runs_on_a_named_user_initiated_worker_of_its_role_not_the_caller() {
        for (role, prefix) in [(Role::Scan, "bz-scan-"), (Role::Query, "bz-query-")] {
            let caller = std::thread::current().id();
            let (id, name, qos) = run(role, where_am_i);
            assert_ne!(id, caller, "the caller waits; a worker does the work");
            assert!(
                name.as_deref().is_some_and(|n| n.starts_with(prefix)),
                "{role:?} ran on {name:?}"
            );
            assert_eq!(
                qos, QOS_CLASS_USER_INITIATED,
                "workers run at USER_INITIATED"
            );
            // Also what rayon calls the current pool from inside, for every parallel iterator.
            let all_on_workers = run(role, || {
                (0..4096).into_par_iter().all(|_| {
                    std::thread::current()
                        .name()
                        .is_some_and(|n| n.starts_with(prefix))
                })
            });
            assert!(
                all_on_workers,
                "a parallel iterator started inside stays on the {role:?} pool"
            );
        }
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
        for (outer, inner_role) in [
            (Role::Scan, Role::Scan),
            (Role::Query, Role::Query),
            (Role::Scan, Role::Query),
            (Role::Query, Role::Scan),
        ] {
            let inline: usize = within(60, "nested run", move || {
                run(outer, || {
                    (0..2000usize)
                        .into_par_iter()
                        .map(|_| {
                            // Every worker may be inside this closure at once.
                            let (inner, _, _) = run(inner_role, where_am_i);
                            usize::from(inner == std::thread::current().id())
                        })
                        .sum()
                })
            });
            assert_eq!(
                inline, 2000,
                "{inner_role:?} inside {outer:?} ran on the worker that made the call"
            );
        }
    }

    #[test]
    fn a_search_and_a_breakdown_issued_from_scan_workers_run_there_and_finish() {
        let tree = std::sync::Arc::new(flat_tree(60_000));
        let (expected_search, expected_types) = (tree.search("file1", 10), tree.types(0));
        let (ok, jobs) = within(120, "queries from scan workers", move || {
            run(Role::Scan, || {
                let jobs = 4 * rayon::current_num_threads();
                let ok: usize = (0..jobs)
                    .into_par_iter()
                    .map(|_| {
                        let here = std::thread::current().id();
                        let found = tree.search("file1", 10) == expected_search
                            && tree.types(0) == expected_types;
                        // Inline: no hop to the query pool, which would park this worker.
                        usize::from(found && run(Role::Query, where_am_i).0 == here)
                    })
                    .sum();
                (ok, jobs)
            })
        });
        assert_eq!(
            ok, jobs,
            "every nested query was answered inline, and correctly"
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
                    .map(|i| {
                        let role = if i % 2 == 0 { Role::Scan } else { Role::Query };
                        run(role, || (0..100u64).into_par_iter().sum::<u64>() + i)
                    })
                    .sum()
            })
        });
        assert_eq!(total, 64 * 4950 + (0..64u64).sum::<u64>());
    }

    #[test]
    fn a_panic_inside_work_reaches_the_caller_and_the_pool_keeps_working() {
        for role in [Role::Scan, Role::Query] {
            let result =
                std::panic::catch_unwind(|| run(role, || -> u32 { panic!("inside the pool") }));
            assert!(result.is_err());
            assert_eq!(
                run(role, || (0..1000u32).into_par_iter().sum::<u32>()),
                499_500
            );
        }
    }

    #[test]
    fn a_pool_that_cannot_be_built_falls_back_to_the_caller_and_is_retried() {
        let (cell, outage) = (OnceLock::new(), Outage::new());
        let t0 = Instant::now();
        assert!(
            get_or_build(&cell, &outage, BACKOFF, t0, refused).is_none(),
            "the failure is not hidden as a pool"
        );
        assert!(
            outage.degraded.load(Ordering::Relaxed),
            "the failure is readable"
        );
        assert!(cell.get().is_none(), "a failed build is not remembered");
        let caller = std::thread::current().id();
        assert_eq!(
            run_on(None, || std::thread::current().id()),
            caller,
            "the fallback runs the work"
        );
        let later = t0 + BACKOFF.first;
        let pool = get_or_build(&cell, &outage, BACKOFF, later, || build(Role::Query))
            .expect("the retry builds the pool");
        assert!(
            !outage.degraded.load(Ordering::Relaxed),
            "a build ends the outage"
        );
        let again = get_or_build(&cell, &outage, BACKOFF, later, || {
            panic!("a built pool is not rebuilt")
        })
        .unwrap();
        assert!(std::ptr::eq(pool, again));
    }

    fn refused() -> Result<ThreadPool, ThreadPoolBuildError> {
        ThreadPoolBuilder::new()
            .spawn_handler(|_| Err(std::io::Error::other("injected: no threads")))
            .build()
    }

    #[test]
    fn an_outage_is_reported_once_and_retried_no_faster_than_the_backoff() {
        let (cell, outage) = (OnceLock::new(), Outage::new());
        let attempts = AtomicUsize::new(0);
        let attempt = || {
            attempts.fetch_add(1, Ordering::SeqCst);
            refused()
        };
        let backoff = Backoff {
            first: Duration::from_secs(2),
            cap: Duration::from_secs(10),
        };
        let t0 = Instant::now();
        let at = |secs: u64| t0 + Duration::from_secs(secs);

        // A burst of calls (a search per keystroke): one attempt, one report.
        for _ in 0..500 {
            assert!(get_or_build(&cell, &outage, backoff, at(0), attempt).is_none());
        }
        assert_eq!(
            attempts.load(Ordering::SeqCst),
            1,
            "one attempt for the whole burst"
        );
        assert_eq!(outage.reports.load(Ordering::SeqCst), 1);
        // Still inside the 2 s window.
        for _ in 0..500 {
            assert!(get_or_build(&cell, &outage, backoff, at(1), attempt).is_none());
        }
        assert_eq!(
            attempts.load(Ordering::SeqCst),
            1,
            "no retry before the backoff"
        );
        // The window passes: exactly one more attempt, and the next wait doubles to 4 s.
        for _ in 0..500 {
            assert!(get_or_build(&cell, &outage, backoff, at(2), attempt).is_none());
        }
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
        get_or_build(&cell, &outage, backoff, at(5), attempt);
        assert_eq!(
            attempts.load(Ordering::SeqCst),
            2,
            "4 s after the second failure, not 3"
        );
        get_or_build(&cell, &outage, backoff, at(6), attempt);
        assert_eq!(attempts.load(Ordering::SeqCst), 3);
        assert_eq!(
            outage.reports.load(Ordering::SeqCst),
            1,
            "the same outage is not reported again"
        );
        assert!(outage.degraded.load(Ordering::Relaxed));

        // The pool comes back: the outage is over, and the next one is reported anew.
        let pool = get_or_build(&cell, &outage, backoff, at(14), || build(Role::Query));
        assert!(pool.is_some());
        assert!(!outage.degraded.load(Ordering::Relaxed));
        let (next_cell, mut now) = (OnceLock::new(), at(100));
        assert!(get_or_build(&next_cell, &outage, backoff, now, refused).is_none());
        assert_eq!(
            outage.reports.load(Ordering::SeqCst),
            2,
            "a new outage is reported once"
        );
        now += Duration::from_secs(1);
        assert!(get_or_build(&next_cell, &outage, backoff, now, refused).is_none());
        assert_eq!(outage.reports.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn the_backoff_doubles_to_its_cap() {
        let secs = |failures| BACKOFF.delay(failures).as_secs();
        assert_eq!(
            (1..=8).map(secs).collect::<Vec<_>>(),
            [2, 4, 8, 16, 32, 60, 60, 60]
        );
        assert_eq!(secs(0), 2, "no failures yet waits the first interval");
        assert_eq!(secs(u32::MAX), 60, "a huge count does not overflow");
    }

    #[test]
    fn the_process_pools_are_not_degraded_when_they_build() {
        run(Role::Scan, || ());
        run(Role::Query, || ());
        assert!(!degraded());
    }

    #[test]
    fn scan_coverage_ignores_a_query_pool_outage() {
        assert!(!workers_degraded_for_scan(false, false));
        assert!(!workers_degraded_for_scan(false, true));
        assert!(workers_degraded_for_scan(true, false));
        assert!(workers_degraded_for_scan(true, true));
    }

    #[test]
    fn each_role_reuses_its_own_pool_across_scans_searches_and_breakdowns() {
        run(Role::Scan, || ());
        run(Role::Query, || ());
        let (scan_pool, query_pool) = (SCAN_POOL.get().unwrap(), QUERY_POOL.get().unwrap());
        assert!(
            !std::ptr::eq(scan_pool, query_pool),
            "the roles have separate pools"
        );
        let built = BUILT.load(Ordering::Relaxed);
        let tree = flat_tree(100_000);
        let root = fixture("reuse", 4, 5);
        let runs = || RUNS.with(|n| n.get());

        let before = runs();
        let (total, top) = tree.search("file9", 5);
        assert!(total > 0 && top.len() == 5);
        assert_eq!(runs(), before + 1, "search enters a pool");
        assert_eq!(
            LAST_ROLE.with(Cell::get),
            Some(Role::Query),
            "search uses the query pool"
        );
        let before = runs();
        assert!(!tree.types(0).is_empty());
        assert_eq!(runs(), before + 1, "the type breakdown enters a pool");
        assert_eq!(
            LAST_ROLE.with(Cell::get),
            Some(Role::Query),
            "types uses the query pool"
        );
        for _ in 0..5 {
            let before = runs();
            let scanned = crate::scan(&root, &Progress::default());
            assert_eq!(scanned.n_files[0], 20);
            assert_eq!(runs(), before + 1, "a scan enters a pool");
            assert_eq!(
                LAST_ROLE.with(Cell::get),
                Some(Role::Scan),
                "a scan uses the scan pool"
            );
        }
        assert_eq!(
            BUILT.load(Ordering::Relaxed),
            built,
            "no scan, search or breakdown built another pool"
        );
        assert!(std::ptr::eq(scan_pool, SCAN_POOL.get().unwrap()));
        assert!(std::ptr::eq(query_pool, QUERY_POOL.get().unwrap()));
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

    /// A latch the blocked scan jobs wait on; dropping it opens it, so a test
    /// that fails halfway never leaves the scan pool jammed for the others.
    struct Gate(std::sync::Arc<(Mutex<bool>, std::sync::Condvar)>);

    impl Gate {
        fn new() -> Gate {
            Gate(std::sync::Arc::new((
                Mutex::new(false),
                std::sync::Condvar::new(),
            )))
        }
        fn open(&self) {
            *self.0 .0.lock().unwrap_or_else(PoisonError::into_inner) = true;
            self.0 .1.notify_all();
        }
    }

    impl Drop for Gate {
        fn drop(&mut self) {
            self.open();
        }
    }

    /// Runs the jam test in a process of its own: it parks every scan worker,
    /// and in this binary's shared pool that would stall the scans of the tests
    /// running beside it (and be a flake source for their timing checks).
    #[test]
    fn queries_finish_while_every_scan_worker_is_blocked() {
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "pool::tests::jam_the_scan_pool_and_query",
                "--test-threads=1",
            ])
            .output()
            .expect("start the child test process");
        let text = String::from_utf8_lossy(&out.stdout).into_owned()
            + &String::from_utf8_lossy(&out.stderr);
        assert!(
            out.status.success() && text.contains("1 passed"),
            "the child process did not pass:\n{text}"
        );
    }

    /// Every scan worker parked on a latch; a search and a type breakdown must
    /// still finish. No timing threshold: the watchdog only turns a hang into
    /// a failure. Ignored so that only the parent test above runs it, alone in
    /// its own process.
    #[test]
    #[ignore = "jams the scan pool; run by queries_finish_while_every_scan_worker_is_blocked in a child process"]
    fn jam_the_scan_pool_and_query() {
        let tree = std::sync::Arc::new(flat_tree(50_000));
        let (expected_search, expected_types) = (tree.search("file4", 10), tree.types(0));
        let workers = threads();
        let entered = std::sync::Arc::new(AtomicUsize::new(0));
        let gate = Gate::new();

        // One job per scan worker, each parked until the gate opens.
        let blockers = {
            let (entered, latch) = (entered.clone(), gate.0.clone());
            std::thread::spawn(move || {
                run(Role::Scan, || {
                    rayon::scope(|s| {
                        for _ in 0..workers {
                            s.spawn(|_| {
                                entered.fetch_add(1, Ordering::SeqCst);
                                let mut open =
                                    latch.0.lock().unwrap_or_else(PoisonError::into_inner);
                                while !*open {
                                    open =
                                        latch.1.wait(open).unwrap_or_else(PoisonError::into_inner);
                                }
                            });
                        }
                    })
                })
            })
        };
        let patience = std::time::Instant::now() + Duration::from_secs(120);
        while entered.load(Ordering::SeqCst) < workers {
            assert!(
                std::time::Instant::now() < patience,
                "the scan workers never all parked"
            );
            std::thread::sleep(Duration::from_millis(1));
        }

        // Every scan worker is occupied. The queries must not need one.
        let (tx, rx) = mpsc::channel();
        let asker = {
            let tree = tree.clone();
            std::thread::spawn(move || {
                let _ = tx.send((tree.search("file4", 10), tree.types(0)));
            })
        };
        let answer = rx.recv_timeout(Duration::from_secs(120));
        gate.open();
        blockers.join().unwrap();
        let (found, types) =
            answer.expect("a search and a breakdown queued behind the blocked scan pool");
        asker.join().unwrap();
        assert_eq!(found, expected_search);
        assert_eq!(types, expected_types);
    }

    #[test]
    fn a_search_issued_while_a_scan_runs_still_finishes_with_the_right_answer() {
        use crate::tests::{HOLD, HOLD_MARKER};
        /// Lets the held walk go even if an assertion fails first.
        struct Release;
        impl Drop for Release {
            fn drop(&mut self) {
                HOLD.release();
            }
        }

        let tree = std::sync::Arc::new(flat_tree(120_000));
        let expected = tree.search("file7", 10);
        let root = fixture("during-scan", 20, 10);
        std::fs::create_dir(root.join(format!("{HOLD_MARKER}-dir"))).unwrap();
        HOLD.arm();
        let _release = Release;
        let progress = std::sync::Arc::new(Progress::default());
        let h = ffi::start_scan(root.clone(), progress);
        // The walk has reached the held folder and stays there: the scan is
        // running, by construction, for every search below.
        assert!(
            HOLD.wait_arrival(Duration::from_secs(120)),
            "the scan never reached the held folder"
        );
        let searched = within(120, "search during a scan", {
            let tree = tree.clone();
            move || {
                (0..20)
                    .map(|_| tree.search("file7", 10))
                    .collect::<Vec<_>>()
            }
        });
        assert!(searched.iter().all(|r| *r == expected));
        assert_eq!(
            unsafe { ffi::bz_scan_status(h) },
            0,
            "the scan was still running when the searches finished"
        );
        HOLD.release();
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
