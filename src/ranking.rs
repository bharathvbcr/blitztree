//! "Largest first" selection over a finished scan, shared by the JSON CLI and
//! the app's Largest Files list. Ties break by path, then node index, so every
//! caller sees the same order.
use crate::Tree;
use std::cmp::{Ordering, Reverse};
use std::collections::BinaryHeap;

// Every entry in a heap refers to the same immutable scan.
struct Ranked<'a> {
    tree: &'a Tree,
    node: usize,
    // `tree.alloc[node]`, kept here so ordering does not chase it per compare.
    alloc: u64,
}

impl Ord for Ranked<'_> {
    fn cmp(&self, other: &Self) -> Ordering {
        self.alloc
            .cmp(&other.alloc)
            .then_with(|| self.tree.compare_paths(other.node, self.node))
            .then_with(|| self.node.cmp(&other.node))
    }
}

impl PartialOrd for Ranked<'_> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for Ranked<'_> {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

impl Eq for Ranked<'_> {}

/// The `limit` best nodes by (allocated bytes, path, node index) seen so far.
/// The order is total, so the survivors do not depend on the order nodes are
/// pushed or on how `merge` splits the work: parallel callers get exactly the
/// set a serial pass would.
pub(crate) struct TopK<'a> {
    scan: &'a Tree,
    limit: usize,
    // A min-heap: the root is the weakest survivor.
    heap: BinaryHeap<Reverse<Ranked<'a>>>,
    // Allocated bytes of the weakest survivor once the heap is full, else 0:
    // anything smaller cannot qualify, so it is rejected without a heap probe.
    floor: u64,
}

impl<'a> TopK<'a> {
    pub(crate) fn new(scan: &'a Tree, limit: usize) -> Self {
        Self {
            scan,
            limit,
            heap: BinaryHeap::new(),
            floor: 0,
        }
    }

    pub(crate) fn push(&mut self, node: usize) {
        if self.limit == 0 {
            return;
        }
        // Keep only the requested top K, even for millions of equally sized files.
        let alloc = self.scan.alloc[node];
        if alloc < self.floor {
            return;
        }
        let candidate = Ranked {
            tree: self.scan,
            node,
            alloc,
        };
        if self.heap.len() < self.limit {
            self.heap.push(Reverse(candidate));
        } else if self
            .heap
            .peek()
            .is_some_and(|Reverse(minimum)| candidate > *minimum)
        {
            self.heap.pop();
            self.heap.push(Reverse(candidate));
        } else {
            return;
        }
        if self.heap.len() == self.limit {
            self.floor = self.heap.peek().map_or(0, |Reverse(minimum)| minimum.alloc);
        }
    }

    /// Fold another selection over the same scan into this one.
    pub(crate) fn merge(mut self, other: Self) -> Self {
        for Reverse(ranked) in other.heap {
            self.push(ranked.node);
        }
        self
    }

    /// The survivors, best first.
    pub(crate) fn into_sorted(self) -> Vec<usize> {
        let mut best: Vec<_> = self.heap.into_iter().map(|item| item.0).collect();
        best.sort_unstable_by(|a, b| b.cmp(a));
        best.into_iter().map(|item| item.node).collect()
    }
}

/// The `limit` largest of `indices` by allocated bytes, largest first.
pub fn top_by_alloc(scan: &Tree, indices: impl Iterator<Item = usize>, limit: usize) -> Vec<usize> {
    let mut top = TopK::new(scan, limit);
    for i in indices {
        top.push(i);
    }
    top.into_sorted()
}

/// The `limit` largest files (anything that is not a directory) of at least
/// `min_bytes` allocated, anywhere under the scan root.
pub fn largest_files(scan: &Tree, min_bytes: u64, limit: usize) -> Vec<usize> {
    top_by_alloc(
        scan,
        (1..scan.len()).filter(|&i| !scan.is_dir(i) && scan.alloc[i] >= min_bytes),
        limit,
    )
}

/// The `limit` largest directories of at least `min_bytes`, root excluded.
pub fn largest_directories(scan: &Tree, min_bytes: u64, limit: usize) -> Vec<usize> {
    top_by_alloc(
        scan,
        (1..scan.len()).filter(|&i| scan.is_dir(i) && scan.alloc[i] >= min_bytes),
        limit,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NO_PARENT;
    use std::hint::black_box;
    use std::path::PathBuf;
    use std::time::Instant;

    fn fixture(directories: usize, files: usize, ties: bool) -> Tree {
        let mut t = Tree { name_off: vec![0], ..Tree::default() };
        let mut push = |parent, name: &str, is_dir: bool, bytes| {
            t.parents.push(parent);
            t.flags.push(u8::from(is_dir));
            t.alloc.push(bytes);
            t.name_blob.extend_from_slice(name.as_bytes());
            t.name_off.push(t.name_blob.len() as u32);
        };
        push(NO_PARENT, "/fixture", true, 0);
        for d in 0..directories {
            push(0, &format!("project-{d:06}-é"), true, 0);
        }
        for d in 0..directories {
            for f in 0..files {
                let bytes = if ties { 4096 } else { ((f * 7919 + d * 104729) % 100_000) as u64 * 4096 };
                push(d as u32 + 1, &format!("file-{f:06}-日本語"), false, bytes);
            }
        }
        t
    }

    // Exact pre-change bounded heap, retained only as a benchmark reference.
    fn reference(t: &Tree, indices: impl Iterator<Item = usize>, limit: usize) -> Vec<usize> {
        if limit == 0 { return Vec::new(); }
        let mut heap: BinaryHeap<Reverse<(u64, Reverse<PathBuf>, usize)>> = BinaryHeap::new();
        for i in indices {
            let alloc = t.alloc[i];
            if heap.len() == limit && heap.peek().is_some_and(|Reverse((minimum, _, _))| alloc < *minimum) {
                continue;
            }
            let candidate = (alloc, Reverse(t.path(i)), i);
            if heap.len() < limit {
                heap.push(Reverse(candidate));
            } else if candidate > heap.peek().unwrap().0 {
                heap.pop();
                heap.push(Reverse(candidate));
            }
        }
        let mut best: Vec<_> = heap.into_iter().map(|item| item.0).collect();
        best.sort_unstable_by(|a, b| b.cmp(a));
        best.into_iter().map(|item| item.2).collect()
    }

    #[test]
    fn bounded_order_matches_full_sort_in_both_visit_orders() {
        for ties in [true, false] {
            let t = fixture(13, 29, ties);
            for limit in [0, 1, 20, 1000] {
                let mut expected: Vec<_> = (1..t.len()).collect();
                expected.sort_unstable_by_key(|&i| (Reverse(t.alloc[i]), t.path(i), Reverse(i)));
                expected.truncate(limit);
                assert_eq!(top_by_alloc(&t, 1..t.len(), limit), expected);
                assert_eq!(top_by_alloc(&t, (1..t.len()).rev(), limit), expected);
            }
        }
    }

    #[test]
    fn largest_files_skips_directories_and_small_files_at_any_depth() {
        let mut t = Tree::with_root("/root");
        t.push("huge-dir", 0, 9000, 9000, true); // 1
        t.push("deep.bin", 1, 800, 800, false); // 2
        t.push("small.txt", 1, 10, 10, false); // 3
        t.push("top.bin", 0, 500, 500, false); // 4
        t.link_children();
        assert_eq!(largest_files(&t, 0, 10), [2, 4, 3]);
        assert_eq!(largest_files(&t, 100, 10), [2, 4]);
        assert_eq!(largest_files(&t, 0, 1), [2]);
        assert_eq!(largest_directories(&t, 0, 10), [1]);
    }

    #[test]
    #[ignore = "opt-in timing benchmark; run alone with --nocapture"]
    fn report_order_benchmark() {
        for (name, dirs, files, ties) in [
            ("wide-equal", 1, 250_000, true),
            ("projects-equal", 1000, 250, true),
            ("projects-varied", 1000, 250, false),
        ] {
            let t = fixture(dirs, files, ties);
            let expected = reference(&t, dirs + 1..t.len(), 20);
            assert_eq!(top_by_alloc(&t, dirs + 1..t.len(), 20), expected);
            let mut samples = [Vec::new(), Vec::new()];
            for round in 0..10 {
                for which in if round % 2 == 0 { [0, 1] } else { [1, 0] } {
                    let start = Instant::now();
                    let found = if which == 0 {
                        reference(black_box(&t), dirs + 1..t.len(), black_box(20))
                    } else {
                        top_by_alloc(black_box(&t), dirs + 1..t.len(), black_box(20))
                    };
                    let elapsed = start.elapsed().as_secs_f64() * 1000.0;
                    assert_eq!(found, expected);
                    if round > 0 { samples[which].push(elapsed); }
                }
            }
            println!("{name} nodes={} baseline_ms={:?} candidate_ms={:?}", t.len(), samples[0], samples[1]);
        }
    }
}

