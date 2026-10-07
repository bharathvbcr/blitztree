//! Seeded random-tree property test for `cleanup::find`. Deterministic: set
//! BZ_STRESS_SEED / BZ_STRESS_CASES to replay or widen; every failure message
//! names the seed that produced it.
use super::tests::{build_with, rel};
use super::*;

/// splitmix64: tiny, seedable, no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }
    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[self.below(items.len())]
    }
    fn shuffle<T>(&mut self, v: &mut [T]) {
        for i in (1..v.len()).rev() {
            v.swap(i, self.below(i + 1));
        }
    }
}

/// Every rule name, marker and container name, plus filler.
const NAMES: &[&str] = &[
    "a", "b", "src", "p", "node_modules", "package.json", ".venv", "venv", "pyvenv.cfg", "target",
    "Cargo.toml", ".next", "DerivedData", "Xcode", "Archives", "UserData", "Previews", "Developer",
    "XCTestDevices", "iOS DeviceSupport", "Caches", "Library", "CoreSimulator", ".cache", ".npm",
    ".gradle", "gradle.properties", "init.d", "caches", "wrapper", "native", "install", ".bun",
    "cache", ".cargo", "registry", "git", "bin", ".m2", "repository", ".ollama", "models", ".rustup",
    "toolchains", "downloads", ".claude", "projects", "file-history", "debug", ".codex", "sessions",
    "2025", "archived_sessions", "worktrees", ".git", "CACHEDIR.TAG", "huggingface", "hub",
    "models--m", "torch", ".build", "Package.swift", "build", "build.gradle", ".dart_tool",
    "pubspec.yaml", ".turbo", "Pods", "Podfile", ".tox", "zig-out", "build.zig", "_build", "deps",
    "mix.exs", ".stack-work", "dist-newstyle", "Application Support", "Cache", "GPUCache",
    "com.apple.x", ".Trash", "lib", "Users", "u",
];

/// Home-relative starts that reach every container and home rule.
const HOME_STARTS: &[&str] = &[
    ".cache", ".cache/huggingface", ".cache/huggingface/hub", "Library/Caches", "Library",
    "Library/Developer/Xcode", "Library/Developer/Xcode/UserData", "Library/Application Support/App", ".cargo", ".m2", ".ollama",
    ".rustup", ".rustup/toolchains", ".claude", ".claude/projects", ".codex", ".codex/sessions",
    ".codex/worktrees", ".gradle", "project", "Library/Containers/c/Data/Library",
];

/// I2: user config and credentials, home-relative. Never inside a candidate.
const PROTECTED: &[&str] = &[
    ".cargo/bin/cargo", ".cargo/config.toml", ".cargo/credentials.toml", ".cargo/env",
    ".cargo/.crates.toml", ".cargo/.crates2.json", ".gradle/gradle.properties", ".gradle/init.d/a.gradle",
    ".gradle/init.gradle", ".gradle/init.gradle.kts", ".m2/settings.xml", ".claude/settings.json",
    ".claude/.credentials.json", ".claude/local/package.json", ".codex/auth.json", ".codex/config.toml",
    ".cache/huggingface/token", ".cache/huggingface/stored_tokens",
];

/// Folders the Swift guard always refuses (CleanupSafety.broadRelative), home-relative.
const BROAD: &[&str] = &[
    "Library", "Library/Caches", "Library/Application Support", "Library/Containers",
    "Library/Group Containers", "Library/Developer", "Library/Preferences", ".config", ".cache",
    "Library/Developer/CoreSimulator", "Library/Developer/CoreSimulator/Devices", ".local",
    ".local/share", "Downloads",
];

/// (scan root, home, home's path relative to the root when the home is in the tree).
/// Roots in the middle of a rule's ancestry exercise ancestor-name rules at the root.
const ROOTS: &[(&str, Option<&str>, Option<&str>)] = &[
    ("/Users/u", Some("/Users/u"), Some("")),
    ("/System/Volumes/Data", Some("/Users/u"), Some("Users/u")),
    ("/", Some("/Users/u"), Some("Users/u")),
    ("/System/Volumes/Data/Users/u", Some("/Users/u"), Some("")),
    ("/Users/u", Some("/System/Volumes/Data/Users/u"), Some("")),
    ("/Volumes/X", Some("/Users/u"), None),
    ("/Users/u", None, None),
    ("/Users/u/Library", Some("/Users/u"), None),
    ("/Users/u/Library/Caches", Some("/Users/u"), None),
    ("/Users/u/.cache", Some("/Users/u"), None),
    ("/Users/u/.cache/huggingface", Some("/Users/u"), None),
    ("/Users/u/.claude", Some("/Users/u"), None),
    ("/Users/u/.codex/worktrees", Some("/Users/u"), None),
    ("/Users/u/.gradle", Some("/Users/u"), None),
    ("/Users/u/Library/Developer/Xcode", Some("/Users/u"), None),
    ("/Users/u/Library/Developer/CoreSimulator", None, None),
    ("/Users/u/Library/Application Support", Some("/Users/u"), None),
    ("/x/.bun", None, None),
    ("/x/.bun/install", None, None),
    ("/r/.claude/worktrees", None, None),
];

fn random_paths(rng: &mut Rng, home_rel: Option<&str>) -> (Vec<String>, Vec<String>) {
    let mut paths = Vec::new();
    let mut protected = Vec::new();
    let prefix = home_rel.map(|h| if h.is_empty() { String::new() } else { format!("{h}/") });
    for _ in 0..1 + rng.below(40) {
        let mut parts: Vec<String> = Vec::new();
        if let Some(prefix) = prefix.as_ref().filter(|_| rng.chance(50)) {
            parts.push(format!("{prefix}{}", rng.pick(HOME_STARTS)));
        }
        for _ in 0..rng.below(7) {
            parts.push(rng.pick(NAMES).to_string());
        }
        if parts.is_empty() {
            parts.push(rng.pick(NAMES).to_string());
        }
        let mut path = parts.join("/");
        if rng.chance(15) {
            path.push('/');
        }
        paths.push(path);
    }
    if let Some(prefix) = &prefix {
        for p in PROTECTED {
            if rng.chance(60) {
                protected.push(format!("{prefix}{p}"));
            }
        }
    }
    // The same entries at non-home depths: only their direct rules protect them.
    for p in [".gradle/gradle.properties", "lib/node_modules/npm/index.js"] {
        if rng.chance(50) {
            paths.push(format!("{}/{p}", rng.pick(NAMES)));
        }
    }
    paths.extend(protected.iter().cloned());
    (paths, protected)
}

fn check(seed: u64) -> Vec<Kind> {
    let mut rng = Rng(seed);
    let (root, home, home_rel) = ROOTS[rng.below(ROOTS.len())];
    let (paths, protected) = random_paths(&mut rng, home_rel);
    let paths: Vec<&str> = paths.iter().map(String::as_str).collect();
    let min_bytes = [0, 1, MIN_BYTES, MIN_BYTES * 2][rng.below(4)];
    let anchors = Anchors::new(home.map(Path::new));
    let t = build_with(root, &paths, &mut |v| v);
    let found = find(&t, min_bytes, &anchors);
    let ctx = format!("seed {seed} root {root} home {home:?} min {min_bytes}");
    let enclosing = enclosing(&t, &found);
    let rels: Vec<String> = found.iter().map(|c| rel(&t, c.node)).collect();

    for (k, c) in found.iter().enumerate() {
        let n = c.node as usize;
        let path = &rels[k];
        assert!(n != 0, "{ctx}: root is a candidate");
        assert!(t.is_dir(n), "{ctx}: {path} is not a directory");
        assert!(t.alloc[n] >= min_bytes, "{ctx}: {path} below threshold");
        assert!(!path.split('/').any(|p| p == ".Trash"), "{ctx}: {path} under .Trash");
        if let Some(e) = enclosing[k] {
            assert!(found[e].kind.descends(), "{ctx}: {path} nested in {:?}", found[e].kind);
        }
        if c.kind == Kind::NodeModules {
            let parent = t.parents[n] as usize;
            assert!(contains(&t, parent, &["package.json"]), "{ctx}: {path} without package.json");
        }
        if !c.kind.descends() {
            assert!(!contains(&t, n, GRADLE_CONFIG), "{ctx}: Gradle home {path} is a candidate");
        }
        for p in &protected {
            assert!(
                p != path && !p.starts_with(&format!("{path}/")),
                "{ctx}: protected {p} inside candidate {path} ({:?})",
                c.kind
            );
        }
        if let Some(h) = home_rel {
            let home_path = h.to_string();
            assert!(
                home_path != *path && !home_path.starts_with(&format!("{path}/")),
                "{ctx}: home or its ancestor {path} is a candidate"
            );
            let inside = if h.is_empty() { Some(path.as_str()) } else { path.strip_prefix(&format!("{h}/")) };
            if let Some(inside) = inside {
                assert!(!BROAD.contains(&inside), "{ctx}: broad home folder {path} is a candidate");
                assert!(
                    inside.contains('/') || inside.starts_with('.'),
                    "{ctx}: direct home child {path} is a candidate"
                );
            }
        }
        if k > 0 {
            let (a, b) = (found[k - 1].node as usize, n);
            assert!(
                t.alloc[a] > t.alloc[b]
                    || (t.alloc[a] == t.alloc[b] && t.compare_paths(a, b) == std::cmp::Ordering::Less),
                "{ctx}: order {} before {path}",
                rels[k - 1]
            );
        }
    }

    // Deterministic under any sibling order the scanner might produce.
    let shuffled = build_with(root, &paths, &mut |mut v| {
        rng.shuffle(&mut v);
        v
    });
    let again: Vec<(String, Kind)> = find(&shuffled, min_bytes, &anchors)
        .iter()
        .map(|c| (rel(&shuffled, c.node), c.kind))
        .collect();
    let first: Vec<(String, Kind)> = rels.into_iter().zip(found.iter().map(|c| c.kind)).collect();
    assert_eq!(first, again, "{ctx}: sibling order changed the result");
    first.into_iter().map(|(_, kind)| kind).collect()
}

#[test]
fn random_trees_hold_the_cleanup_invariants() {
    let base: u64 = std::env::var("BZ_STRESS_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or(0xB117_7EE5);
    let cases: u64 = std::env::var("BZ_STRESS_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(4000);
    let mut seen = std::collections::HashSet::new();
    for k in 0..cases {
        seen.extend(check(base.wrapping_add(k)));
    }
    // The generator must reach every rule, or the invariants prove little.
    let missed: Vec<_> = Kind::ALL.iter().filter(|k| !seen.contains(k)).collect();
    assert!(missed.is_empty(), "base seed {base}: no case produced {missed:?}");
}

#[test]
fn degenerate_trees_do_not_panic() {
    let none = Anchors::default();
    let home = Anchors::new(Some(Path::new("/Users/u")));
    assert!(find(&Tree::default(), 0, &home).is_empty());
    // Root only, as a directory and as a file (scan of a file path).
    for root in ["/", "/Users/u", "", "relative", "/Users/u/.cache"] {
        let mut t = Tree::with_root(root);
        t.link_children();
        assert!(find(&t, 0, &home).is_empty(), "{root}");
        t.flags[0] = 0;
        assert!(find(&t, 0, &home).is_empty(), "{root}");
    }
    // A 64-deep chain of nested linked worktrees (each emitted and descended)
    // and a 64-deep chain of ordinary folders ending in a candidate.
    let nested: String = (0..32).map(|_| "worktrees/wt/").collect();
    let nested_git = format!("{nested}.git");
    let deep: String = (0..64).map(|_| "a/").collect();
    let deep_marker = format!("{deep}package.json");
    let deep_modules = format!("{deep}node_modules/x");
    let mut paths = vec![deep_marker.as_str(), deep_modules.as_str(), nested_git.as_str()];
    let worktree_gits: Vec<String> = (1..32).map(|d| format!("{}.git", "worktrees/wt/".repeat(d))).collect();
    paths.extend(worktree_gits.iter().map(String::as_str));
    paths.push("worktrees/wt/x");
    let t = build_with("/w", &paths, &mut |v| v);
    let found = find(&t, 0, &none);
    assert_eq!(found.iter().filter(|c| c.kind == Kind::GitWorktree).count(), 32);
    assert_eq!(found.iter().filter(|c| c.kind == Kind::NodeModules).count(), 1);
    let enc = enclosing(&t, &found);
    assert!(enc.iter().flatten().all(|&e| found[e].kind.descends()));
    // 10k siblings, each a project with a node_modules.
    let projects: Vec<String> = (0..10_000)
        .flat_map(|i| [format!("p{i:05}/package.json"), format!("p{i:05}/node_modules/x")])
        .collect();
    let projects: Vec<&str> = projects.iter().map(String::as_str).collect();
    let t = build_with("/Users/u", &projects, &mut |v| v);
    let found = find(&t, MIN_BYTES, &home);
    assert_eq!(found.len(), 10_000);
    assert_eq!(rel(&t, found[0].node), "p00000/node_modules");
}
