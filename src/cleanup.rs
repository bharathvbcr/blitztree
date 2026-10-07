//! The Clean Up panel's folder recognition, shared with the JSON CLI and the
//! C bridge. This module is the single owner of recognition; callers only
//! format its output. These are name/structure heuristics, not authorization
//! to delete anything: the Swift guards and verifiers (`Kind::verify`) decide.
use crate::Tree;
use std::ffi::CStr;
use std::path::{Component, Path};

pub const MIN_BYTES: u64 = 50_000_000;

/// `s` must end in one NUL; ids are stored that way so the C bridge can hand
/// out `'static` C strings without allocating.
fn trim_nul(s: &'static str) -> &'static str {
    &s[..s.len() - 1]
}

fn c_str(s: &'static str) -> &'static CStr {
    CStr::from_bytes_with_nul(s.as_bytes()).expect("ids are NUL-terminated without interior NUL")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Group {
    /// Rebuilt or re-downloaded without user data loss.
    Safe = 0,
    /// Recreatable at a cost, or holding history the user may want.
    Review = 1,
}

impl Group {
    pub fn id(self) -> &'static str {
        match self {
            Self::Safe => "safe",
            Self::Review => "review",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Section {
    Build,
    Packages,
    Apps,
    DevTools,
    Models,
    Agents,
    Worktrees,
}

impl Section {
    pub const ALL: &'static [Section] = &[
        Self::Build,
        Self::Packages,
        Self::Apps,
        Self::DevTools,
        Self::Models,
        Self::Agents,
        Self::Worktrees,
    ];

    fn id_nul(self) -> &'static str {
        match self {
            Self::Build => "build\0",
            Self::Packages => "packages\0",
            Self::Apps => "apps\0",
            Self::DevTools => "devtools\0",
            Self::Models => "models\0",
            Self::Agents => "agents\0",
            Self::Worktrees => "worktrees\0",
        }
    }

    pub fn id(self) -> &'static str {
        trim_nul(self.id_nul())
    }

    pub fn c_id(self) -> &'static CStr {
        c_str(self.id_nul())
    }
}

const CACHEDIR_TAG: &str = "cachedir_tag\0";
const GIT_WORKTREE: &str = "git_worktree\0";
const RECENT_ACTIVITY: &str = "recent_activity\0";

macro_rules! kinds {
    ($($kind:ident => $id:literal, $group:ident, $section:ident, $verify:expr, $description:literal;)*) => {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum Kind { $($kind),* }

        impl Kind {
            pub const ALL: &'static [Kind] = &[$(Self::$kind),*];

            fn id_nul(self) -> &'static str {
                match self { $(Self::$kind => concat!($id, "\0")),* }
            }

            /// English panel label; Swift localizes by `id()` and falls back to this.
            pub fn description(self) -> &'static str {
                match self { $(Self::$kind => $description),* }
            }

            pub fn group(self) -> Group {
                match self { $(Self::$kind => Group::$group),* }
            }

            pub fn section(self) -> Section {
                match self { $(Self::$kind => Section::$section),* }
            }

            fn verify_nul(self) -> Option<&'static str> {
                match self { $(Self::$kind => $verify),* }
            }
        }
    };
}

kinds! {
    // The original nine; ids and labels unchanged.
    NodeModules => "node_modules", Safe, Build, None, "npm packages, reinstallable";
    PythonEnvironment => "python_environment", Safe, Build, None, "Python environment, reinstallable";
    RustBuild => "rust_build", Safe, Build, None, "Rust build output";
    NextBuild => "next_build", Safe, Build, None, "Next.js build output";
    XcodeDerivedData => "xcode_derived_data", Safe, DevTools, None, "Xcode build data";
    DeviceSupport => "device_support", Safe, DevTools, None, "Device symbols, re-downloaded when needed";
    AppCaches => "app_caches", Safe, Apps, None, "App caches, rebuilt automatically";
    ToolCaches => "tool_caches", Safe, Packages, None, "Caches, rebuilt or re-downloaded when needed";
    BunCache => "bun_cache", Safe, Packages, None, "Bun package cache, re-downloaded when needed";
    // Project build output, gated on the project's manifest.
    SwiftBuild => "swift_build", Safe, Build, None, "Swift package build output";
    GradleBuild => "gradle_build", Safe, Build, None, "Gradle build output";
    DartBuild => "dart_build", Safe, Build, None, "Dart and Flutter tool output";
    JsBuildCache => "js_build_cache", Safe, Build, None, "JavaScript build cache";
    CocoaPods => "cocoapods", Safe, Build, None, "CocoaPods dependencies, reinstallable";
    PythonTestEnvironments => "python_test_environments", Safe, Build, None, "tox/nox test environments, recreated by the next run";
    ZigBuild => "zig_build", Safe, Build, None, "Zig build output and cache";
    ElixirBuild => "elixir_build", Safe, Build, None, "Elixir build output and dependencies";
    HaskellBuild => "haskell_build", Safe, Build, None, "Haskell build output";
    // Package-manager caches.
    CargoCache => "cargo_cache", Safe, Packages, None, "Cargo download cache, re-downloaded when needed";
    GradleCache => "gradle_cache", Safe, Packages, None, "Gradle caches and distributions, re-downloaded when needed";
    MavenRepository => "maven_repository", Review, Packages, None, "Maven local repository; locally installed artifacts are not re-downloadable";
    TaggedCache => "tagged_cache", Safe, Packages, Some(CACHEDIR_TAG), "Folder marked as a cache (CACHEDIR.TAG)";
    // Developer tools.
    XcodeArchives => "xcode_archives", Review, DevTools, None, "Xcode archives, needed to symbolicate shipped builds";
    XcodePreviews => "xcode_previews", Safe, DevTools, None, "Xcode preview simulators, recreated when needed";
    XcodeTestDevices => "xcode_test_devices", Safe, DevTools, None, "XCTest device clones, recreated by test runs";
    RustToolchain => "rust_toolchain", Review, DevTools, None, "Rust toolchain, reinstallable with rustup";
    // Models.
    MlModel => "ml_model", Review, Models, None, "Downloaded ML model, re-downloaded on next use";
    OllamaModels => "ollama_models", Review, Models, None, "Ollama models, re-pulled on next use";
    // Coding agents.
    AgentTranscripts => "agent_transcripts", Review, Agents, Some(RECENT_ACTIVITY), "Claude Code session history for one project";
    AgentCheckpoints => "agent_checkpoints", Review, Agents, Some(RECENT_ACTIVITY), "Claude Code file checkpoints (rewind history)";
    AgentLogs => "agent_logs", Safe, Agents, None, "Claude Code debug logs";
    CodexSessions => "codex_sessions", Review, Agents, Some(RECENT_ACTIVITY), "Codex session history";
    AgentWorktreeLeftover => "agent_worktree_leftover", Review, Agents, Some(RECENT_ACTIVITY), "Leftover Codex worktree folder (not a Git worktree)";
    // Emitted and descended (I3): its own build output is listed separately.
    GitWorktree => "git_worktree", Review, Worktrees, Some(GIT_WORKTREE), "Linked Git worktree";
}

impl Kind {
    /// Stable id, also the CLI's `category`.
    pub fn id(self) -> &'static str {
        trim_nul(self.id_nul())
    }

    pub fn c_id(self) -> &'static CStr {
        c_str(self.id_nul())
    }

    /// A container kind: emitted AND descended, so candidates may nest inside it.
    pub fn descends(self) -> bool {
        matches!(self, Self::GitWorktree)
    }

    /// The check Swift must pass before acting: "cachedir_tag" (the CLI and
    /// this module match the tag by name only), "git_worktree" or
    /// "recent_activity". `None` when the rule needs no extra check.
    pub fn verify(self) -> Option<&'static str> {
        self.verify_nul().map(trim_nul)
    }

    /// `verify()` as a C string, "" when there is none.
    pub fn c_verify(self) -> &'static CStr {
        c_str(self.verify_nul().unwrap_or("\0"))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub node: u32,
    pub kind: Kind,
}

/// The user's home directory, the only anchor home rules (`~/.cache`,
/// `~/Library/Caches`, `~/.cargo`, ...) compare against. A whole-disk scan is
/// rooted at /System/Volumes/Data, where /Users/x appears as
/// /System/Volumes/Data/Users/x, so both spellings are kept. Without a home,
/// home rules never match.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Anchors {
    /// Each spelling's normal components, e.g. ["Users", "x"].
    homes: Vec<Vec<String>>,
}

const DATA_VOLUME: [&str; 3] = ["System", "Volumes", "Data"];

impl Anchors {
    /// `home` must be absolute, UTF-8, free of `..` and not `/`; anything else
    /// yields no anchors (fail closed: no home rule matches).
    pub fn new(home: Option<&Path>) -> Self {
        let mut anchors = Self::default();
        if let Some(home) = home {
            anchors.add(home);
        }
        anchors
    }

    /// `$HOME`, plus its symlink-resolved spelling when that differs.
    pub fn from_env() -> Self {
        let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
        let mut anchors = Self::new(home.as_deref());
        if let Some(real) = home.filter(|h| h.is_absolute()).and_then(|h| std::fs::canonicalize(h).ok()) {
            anchors.add(&real);
        }
        anchors
    }

    fn add(&mut self, home: &Path) {
        if !home.is_absolute() {
            return;
        }
        let mut parts = Vec::new();
        for component in home.components() {
            match component {
                Component::RootDir | Component::CurDir => {}
                Component::Normal(part) => match part.to_str() {
                    Some(part) => parts.push(part.to_owned()),
                    None => return,
                },
                Component::ParentDir | Component::Prefix(_) => return,
            }
        }
        if parts.is_empty() {
            return;
        }
        let alias: Vec<String> = if parts.len() > DATA_VOLUME.len() && parts[..3] == DATA_VOLUME {
            parts[3..].to_vec()
        } else {
            DATA_VOLUME.iter().map(|s| s.to_string()).chain(parts.iter().cloned()).collect()
        };
        for spelling in [parts, alias] {
            if !self.homes.contains(&spelling) {
                self.homes.push(spelling);
            }
        }
    }
}

/// Path components of node `i` from itself upward: tree names until the root,
/// then the root's own path components (node 0's name is its full path).
/// Every ancestor-name rule reads names through this, so a rule still matches
/// when the ancestor it inspects is the scan root (e.g. a scan rooted at
/// .../Xcode still recognizes DerivedData).
fn upward(t: &Tree, i: usize) -> impl Iterator<Item = &str> {
    let mut n = i;
    std::iter::from_fn(move || {
        (n != 0).then(|| {
            let name = t.name(n);
            n = t.parents[n] as usize;
            name
        })
    })
    .chain(t.name(0).rsplit('/').filter(|part| !part.is_empty() && *part != "."))
}

/// Name of the `k`-th ancestor (0 = the node itself), "" above `/`.
fn up(t: &Tree, i: usize, k: usize) -> &str {
    upward(t, i).nth(k).unwrap_or("")
}

impl Anchors {
    /// Whether the `skip`-th ancestor of `i` is exactly `home/<rel>`.
    fn at(&self, t: &Tree, i: usize, skip: usize, rel: &[&str]) -> bool {
        self.homes.iter().any(|home| {
            let mut path = upward(t, i).skip(skip);
            rel.iter().rev().all(|part| path.next() == Some(*part))
                && home.iter().rev().all(|part| path.next() == Some(part.as_str()))
                && path.next().is_none()
        })
    }

    /// Whether `i` is strictly inside the home.
    fn inside(&self, t: &Tree, i: usize) -> bool {
        let depth = upward(t, i).count();
        self.homes
            .iter()
            .any(|home| depth > home.len() && self.at(t, i, depth - home.len(), &[]))
    }

    /// Sorted tree nodes that are never listed because the Swift guard always
    /// refuses them (I1): the home and its ancestors, `home/<NEVER_LISTED>`,
    /// and the home's direct children not starting with "." (a dotfiles
    /// `.git` file or a stray CACHEDIR.TAG must not list ~/Library or the
    /// home). Computed once per `find` by walking down from the root.
    fn never_listed(&self, t: &Tree) -> Vec<usize> {
        let mut root: Vec<&str> = upward(t, 0).collect();
        root.reverse();
        // The node at an absolute path, when that path is in the tree.
        let locate = |target: &[&str]| -> Option<usize> {
            if target.len() < root.len() || target[..root.len()] != root[..] {
                return None;
            }
            let mut at = 0usize;
            for part in &target[root.len()..] {
                at = *t.kids(at).iter().find(|&&k| t.name(k as usize) == *part)? as usize;
            }
            Some(at)
        };
        let mut never = Vec::new();
        for home in &self.homes {
            let home: Vec<&str> = home.iter().map(String::as_str).collect();
            never.extend((0..=home.len()).filter_map(|depth| locate(&home[..depth])));
            if let Some(h) = locate(&home) {
                never.extend(
                    t.kids(h).iter().map(|&k| k as usize).filter(|&k| !t.name(k).starts_with('.')),
                );
            }
            for rel in NEVER_LISTED {
                let target: Vec<&str> = home.iter().copied().chain(rel.iter().copied()).collect();
                never.extend(locate(&target));
            }
        }
        never.sort_unstable();
        never.dedup();
        never
    }
}

/// Home-relative folders the Swift guard always refuses as too broad
/// (CleanupSafety.broadRelative). Containers among them are still descended.
const NEVER_LISTED: &[&[&str]] = &[
    &["Library"],
    &["Library", "Caches"],
    &["Library", "Application Support"],
    &["Library", "Containers"],
    &["Library", "Group Containers"],
    &["Library", "Developer"],
    &["Library", "Preferences"],
    &[".config"],
    &[".cache"],
    &["Library", "Developer", "CoreSimulator"],
    &["Library", "Developer", "CoreSimulator", "Devices"],
    &[".local"],
    &[".local", "share"],
    &["Downloads"],
];

/// A directory whose children are classified by its own rules. Every
/// container except `Plain` is restricted: children its rules do not name
/// are skipped without descent ("nothing else in ~/.cargo").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Container {
    Plain,
    DotCache,
    LibraryCaches,
    HuggingFace,
    HfHub,
    Cargo,
    Maven,
    Ollama,
    Rustup,
    RustupToolchains,
    Claude,
    ClaudeProjects,
    Codex,
    CodexSessions,
    CodexWorktrees,
    GradleHome,
}

/// Home-relative containers. The walk reaches nested ones through their
/// parent container; this table seeds a scan rooted at any of them.
const HOME_CONTAINERS: &[(&[&str], Container)] = &[
    (&[".cache"], Container::DotCache),
    (&[".cache", "huggingface"], Container::HuggingFace),
    (&[".cache", "huggingface", "hub"], Container::HfHub),
    (&["Library", "Caches"], Container::LibraryCaches),
    (&[".cargo"], Container::Cargo),
    (&[".m2"], Container::Maven),
    (&[".ollama"], Container::Ollama),
    (&[".rustup"], Container::Rustup),
    (&[".rustup", "toolchains"], Container::RustupToolchains),
    (&[".claude"], Container::Claude),
    (&[".claude", "projects"], Container::ClaudeProjects),
    (&[".codex"], Container::Codex),
    (&[".codex", "sessions"], Container::CodexSessions),
    (&[".codex", "worktrees"], Container::CodexWorktrees),
    (&[".gradle"], Container::GradleHome),
];

const GRADLE_CONFIG: &[&str] = &["gradle.properties", "init.d", "init.gradle", "init.gradle.kts"];
/// Documented as recreated by Gradle; `native` and `.tmp` deliberately excluded.
const GRADLE_CACHES: &[&str] =
    &["caches", "wrapper", "daemon", "jdks", "workers", "kotlin-profile", "build-scan-data"];
const ELECTRON_CACHES: &[&str] = &[
    "Cache",
    "Code Cache",
    "GPUCache",
    "CachedData",
    "CachedExtensionVSIXs",
    "DawnGraphiteCache",
    "DawnWebGPUCache",
    "ShaderCache",
];

enum Outcome {
    /// A candidate; descended too when `kind.descends()`.
    Emit(Kind),
    /// A container: not emitted, children classified by its rules.
    Descend(Container),
    /// Neither emitted nor descended.
    Skip,
    /// No rule: an ordinary folder, descended. `git` = it has a `.git` entry.
    Pass { git: bool },
}

/// Name-only marker checks, as the panel has always done: any entry type.
fn contains(t: &Tree, directory: usize, names: &[&str]) -> bool {
    t.kids(directory)
        .iter()
        .any(|&i| names.contains(&t.name(i as usize)))
}

#[derive(Default)]
struct Markers {
    /// Any `.git` entry: this directory is (part of) a repository.
    git: bool,
    /// `.git` is not a directory: a linked worktree or a submodule.
    git_file: bool,
    /// A non-directory `CACHEDIR.TAG` (contents are verified in Swift).
    cachedir_tag: bool,
}

fn markers(t: &Tree, directory: usize) -> Markers {
    let mut m = Markers::default();
    for &kid in t.kids(directory) {
        let kid = kid as usize;
        match t.name(kid) {
            ".git" => {
                m.git = true;
                m.git_file |= !t.is_dir(kid);
            }
            "CACHEDIR.TAG" => m.cachedir_tag |= !t.is_dir(kid),
            _ => {}
        }
    }
    m
}

fn is_year(name: &str) -> bool {
    name.len() == 4 && name.bytes().all(|b| b.is_ascii_digit())
}

/// Rules for a child `i` of a container, or `None` for a plain parent.
fn container_rule(t: &Tree, i: usize, ctx: Container) -> Option<Outcome> {
    use Container as C;
    use Outcome::{Descend, Emit, Skip};
    let name = t.name(i);
    Some(match ctx {
        C::Plain => return None,
        C::DotCache => match name {
            "huggingface" => Descend(C::HuggingFace),
            "torch" => Emit(Kind::MlModel),
            _ => Emit(Kind::ToolCaches),
        },
        C::LibraryCaches => {
            // macOS-managed caches; the Swift guard refuses them too.
            if name.len() >= 10 && name.as_bytes()[..10].eq_ignore_ascii_case(b"com.apple.") {
                Skip
            } else {
                Emit(Kind::AppCaches)
            }
        }
        // Only the hub: `token`, `stored_tokens` and config live beside it.
        C::HuggingFace if name == "hub" => Descend(C::HfHub),
        C::HfHub
            if ["models--", "datasets--", "spaces--"].iter().any(|p| name.starts_with(p)) =>
        {
            Emit(Kind::MlModel)
        }
        C::Cargo if name == "registry" || name == "git" => Emit(Kind::CargoCache),
        C::Maven if name == "repository" => Emit(Kind::MavenRepository),
        C::Ollama if name == "models" => Emit(Kind::OllamaModels),
        C::Rustup if name == "toolchains" => Descend(C::RustupToolchains),
        C::Rustup if name == "downloads" || name == "tmp" => Emit(Kind::ToolCaches),
        C::RustupToolchains => Emit(Kind::RustToolchain),
        C::Claude => match name {
            "projects" => Descend(C::ClaudeProjects),
            "file-history" => Emit(Kind::AgentCheckpoints),
            "debug" => Emit(Kind::AgentLogs),
            _ => Skip,
        },
        C::ClaudeProjects => Emit(Kind::AgentTranscripts),
        C::Codex => match name {
            "sessions" => Descend(C::CodexSessions),
            "archived_sessions" => Emit(Kind::CodexSessions),
            "worktrees" => Descend(C::CodexWorktrees),
            _ => Skip,
        },
        C::CodexSessions if is_year(name) => Emit(Kind::CodexSessions),
        C::CodexWorktrees if markers(t, i).git_file => Emit(Kind::GitWorktree),
        C::CodexWorktrees => Emit(Kind::AgentWorktreeLeftover),
        C::GradleHome if GRADLE_CACHES.contains(&name) => Emit(Kind::GradleCache),
        _ => Skip,
    })
}

/// Rules for a directory `i` whose parent is a plain folder.
fn plain_rule(t: &Tree, i: usize, in_repo: bool, anchors: &Anchors) -> Outcome {
    use Container as C;
    use Outcome::{Descend, Emit, Skip};
    let parent = t.parents[i] as usize;
    let parent_name = || up(t, i, 1);
    let sibling = |names: &[&str]| contains(t, parent, names);
    let home_child = |container| {
        if anchors.at(t, i, 0, &[t.name(i)]) {
            Some(Descend(container))
        } else {
            None
        }
    };
    // Marker lookups happen only for the named artifact, not every sibling.
    let named = match t.name(i) {
        ".cache" => Some(home_child(C::DotCache).unwrap_or(Emit(Kind::ToolCaches))),
        "Caches" if parent_name() == "Library" => Some(if anchors.at(t, i, 0, &["Library", "Caches"]) {
            Descend(C::LibraryCaches)
        } else if anchors.inside(t, parent) {
            // Containers/<app>/Data/Library/Caches and the like.
            Emit(Kind::AppCaches)
        } else {
            // System /Library/Caches, other users' and other volumes' caches.
            Skip
        }),
        "Caches" if parent_name() == "CoreSimulator" => Some(Emit(Kind::AppCaches)),
        ".cargo" => home_child(C::Cargo),
        ".m2" => home_child(C::Maven),
        ".ollama" => home_child(C::Ollama),
        ".rustup" => home_child(C::Rustup),
        ".claude" => home_child(C::Claude),
        ".codex" => home_child(C::Codex),
        ".gradle" => Some(if contains(t, i, GRADLE_CONFIG) {
            Descend(C::GradleHome)
        } else {
            home_child(C::GradleHome).unwrap_or(Emit(Kind::ToolCaches))
        }),
        // A node_modules without package.json is a global prefix (installed CLIs).
        "node_modules" => Some(if sibling(&["package.json"]) { Emit(Kind::NodeModules) } else { Skip }),
        ".venv" => Some(Emit(Kind::PythonEnvironment)),
        "venv" if contains(t, i, &["pyvenv.cfg"]) => Some(Emit(Kind::PythonEnvironment)),
        "target" if sibling(&["Cargo.toml"]) => Some(Emit(Kind::RustBuild)),
        ".next" if sibling(&["package.json"]) => Some(Emit(Kind::NextBuild)),
        "DerivedData" if parent_name() == "Xcode" => Some(Emit(Kind::XcodeDerivedData)),
        "Archives" if parent_name() == "Xcode" => Some(Emit(Kind::XcodeArchives)),
        "Previews" if parent_name() == "UserData" && up(t, i, 2) == "Xcode" => {
            Some(Emit(Kind::XcodePreviews))
        }
        "XCTestDevices" if parent_name() == "Developer" => Some(Emit(Kind::XcodeTestDevices)),
        "iOS DeviceSupport" | "macOS DeviceSupport" | "watchOS DeviceSupport" => {
            Some(Emit(Kind::DeviceSupport))
        }
        ".npm" => Some(Emit(Kind::ToolCaches)),
        "cache" if parent_name() == "install" && up(t, i, 2) == ".bun" => Some(Emit(Kind::BunCache)),
        ".build" if sibling(&["Package.swift"]) => Some(Emit(Kind::SwiftBuild)),
        "build"
            if sibling(&["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]) =>
        {
            Some(Emit(Kind::GradleBuild))
        }
        ".dart_tool" if sibling(&["pubspec.yaml"]) => Some(Emit(Kind::DartBuild)),
        ".turbo" | ".parcel-cache" | ".nuxt" | ".svelte-kit" | ".expo" | ".angular"
            if sibling(&["package.json"]) =>
        {
            Some(Emit(Kind::JsBuildCache))
        }
        "Pods" if sibling(&["Podfile"]) => Some(Emit(Kind::CocoaPods)),
        ".tox" | ".nox" => Some(Emit(Kind::PythonTestEnvironments)),
        ".zig-cache" | "zig-cache" | "zig-out" if sibling(&["build.zig"]) => Some(Emit(Kind::ZigBuild)),
        "_build" | "deps" if sibling(&["mix.exs"]) => Some(Emit(Kind::ElixirBuild)),
        ".stack-work" | "dist-newstyle" => Some(Emit(Kind::HaskellBuild)),
        name if ELECTRON_CACHES.contains(&name)
            && up(t, i, 2) == "Application Support"
            && anchors.at(t, i, 2, &["Library", "Application Support"]) =>
        {
            Some(Emit(Kind::AppCaches))
        }
        _ => None,
    };
    if let Some(outcome) = named {
        return outcome;
    }
    // Structure rules, after every named rule.
    let m = markers(t, i);
    if m.git_file && (parent_name() == "worktrees" || !in_repo) {
        // A submodule always has an ancestor with `.git`; a worktree under
        // `worktrees` (e.g. <repo>/.claude/worktrees/x) may too.
        Emit(Kind::GitWorktree)
    } else if m.cachedir_tag {
        Emit(Kind::TaggedCache)
    } else {
        Outcome::Pass { git: m.git }
    }
}

/// The scan root's own container, from its absolute path.
fn root_container(t: &Tree, anchors: &Anchors) -> Container {
    HOME_CONTAINERS
        .iter()
        .find(|(rel, _)| anchors.at(t, 0, 0, rel))
        .map(|&(_, container)| container)
        .unwrap_or(if up(t, 0, 0) == ".gradle" && contains(t, 0, GRADLE_CONFIG) {
            Container::GradleHome
        } else {
            Container::Plain
        })
}

/// Panel semantics: visit descendants (not the scan root), skip `.Trash` and
/// anything below `min_bytes` (with its subtree), and never descend into a
/// candidate except a container kind (`Kind::descends`, I3). O(n) over the
/// visited directories plus O(depth) path checks for name-matched ones.
/// Size ties use paths so parallel scan scheduling cannot reorder the report.
pub fn find(t: &Tree, min_bytes: u64, anchors: &Anchors) -> Vec<Candidate> {
    let mut found = Vec::new();
    if t.is_empty() {
        return found;
    }
    let never = anchors.never_listed(t);
    // (directory, its container, whether it or an ancestor in the scan has `.git`)
    let mut stack = vec![(0usize, root_container(t, anchors), markers(t, 0).git)];
    while let Some((i, ctx, in_repo)) = stack.pop() {
        for &child in t.kids(i) {
            let c = child as usize;
            // Skip this subtree, not later siblings (the final sort decides order).
            if t.alloc[c] < min_bytes || !t.is_dir(c) || t.name(c) == ".Trash" {
                continue;
            }
            let outcome = match container_rule(t, c, ctx).unwrap_or_else(|| plain_rule(t, c, in_repo, anchors)) {
                Outcome::Emit(kind) if never.binary_search(&c).is_ok() => {
                    if matches!(kind, Kind::GitWorktree | Kind::TaggedCache) {
                        // A user folder that merely carries a marker: look inside.
                        Outcome::Pass { git: markers(t, c).git }
                    } else {
                        Outcome::Skip
                    }
                }
                // A Gradle user home anywhere (GRADLE_USER_HOME=~/.cache/gradle)
                // holds credentials in gradle.properties: never emit it whole.
                Outcome::Emit(kind) if !kind.descends() && contains(t, c, GRADLE_CONFIG) => {
                    Outcome::Descend(Container::GradleHome)
                }
                outcome => outcome,
            };
            match outcome {
                Outcome::Emit(kind) => {
                    found.push(Candidate { node: child, kind });
                    if kind.descends() {
                        stack.push((c, Container::Plain, true));
                    }
                }
                Outcome::Descend(container) => stack.push((c, container, in_repo)),
                Outcome::Skip => {}
                Outcome::Pass { git } => {
                    if ctx == Container::Plain {
                        stack.push((c, Container::Plain, in_repo || git));
                    }
                }
            }
        }
    }
    found.sort_by(|a, b| {
        t.alloc[b.node as usize]
            .cmp(&t.alloc[a.node as usize])
            .then_with(|| t.compare_paths(a.node as usize, b.node as usize))
    });
    found
}

/// For each candidate, the index (into `found`) of its nearest enclosing
/// candidate, if any. Only container kinds enclose others (I3); totals must
/// sum candidates with `None` here, never all of them.
pub fn enclosing(t: &Tree, found: &[Candidate]) -> Vec<Option<usize>> {
    let index: std::collections::HashMap<u32, usize> =
        found.iter().enumerate().map(|(k, c)| (c.node, k)).collect();
    found
        .iter()
        .map(|c| {
            let mut n = c.node as usize;
            while n != 0 {
                n = t.parents[n] as usize;
                if let Some(&k) = index.get(&(n as u32)) {
                    return Some(k);
                }
            }
            None
        })
        .collect()
}

#[cfg(test)]
#[path = "cleanup_stress_tests.rs"]
mod stress_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NO_PARENT;

    /// Sizes are set per node as given (not aggregated). Siblings must be
    /// added consecutively, as a scan appends them; `link` then lists them.
    fn add(scan: &mut Tree, parent: u32, name: &str, is_dir: bool, bytes: u64) -> u32 {
        if parent == NO_PARENT {
            *scan = Tree::with_root(name);
            scan.alloc[0] = bytes;
            scan.logical[0] = bytes;
            return 0;
        }
        assert!(
            scan.parents.last() == Some(&parent) || !scan.parents.contains(&parent),
            "siblings are contiguous"
        );
        scan.push(name, parent, bytes, bytes, is_dir)
    }

    fn link(mut scan: Tree) -> Tree {
        scan.link_children();
        scan
    }

    /// Build a tree from root-relative paths. `a/b/` is an empty directory,
    /// `a/b` a file of MIN_BYTES (so every non-empty directory passes the
    /// threshold); directory sizes are subtree sums. Siblings are appended in
    /// the order `order` gives (identity when it returns the input).
    pub(super) fn build_with(
        root: &str,
        paths: &[&str],
        order: &mut dyn FnMut(Vec<usize>) -> Vec<usize>,
    ) -> Tree {
        struct N {
            name: String,
            dir: bool,
            size: u64,
            kids: std::collections::BTreeMap<String, usize>,
        }
        let mut nodes = vec![N { name: root.into(), dir: true, size: 0, kids: Default::default() }];
        for path in paths {
            let (path, dir_leaf) = match path.strip_suffix('/') {
                Some(p) => (p, true),
                None => (*path, false),
            };
            let parts: Vec<&str> = path.split('/').collect();
            let mut at = 0;
            for (k, part) in parts.iter().enumerate() {
                let leaf = k + 1 == parts.len();
                let dir = !leaf || dir_leaf;
                at = match nodes[at].kids.get(*part) {
                    Some(&next) => {
                        nodes[next].dir |= dir;
                        next
                    }
                    None => {
                        nodes.push(N { name: part.to_string(), dir, size: 0, kids: Default::default() });
                        let next = nodes.len() - 1;
                        nodes[at].kids.insert(part.to_string(), next);
                        next
                    }
                };
            }
        }
        fn total(nodes: &mut Vec<N>, i: usize) -> u64 {
            let kids: Vec<usize> = nodes[i].kids.values().copied().collect();
            let sum: u64 = if nodes[i].dir {
                kids.into_iter().map(|k| total(nodes, k)).sum()
            } else {
                MIN_BYTES
            };
            nodes[i].size = sum;
            sum
        }
        total(&mut nodes, 0);
        let mut t = Tree::with_root(root);
        (t.alloc[0], t.logical[0]) = (nodes[0].size, nodes[0].size);
        let mut queue = std::collections::VecDeque::from([(0usize, 0u32)]);
        while let Some((at, index)) = queue.pop_front() {
            let kids = order(nodes[at].kids.values().copied().collect());
            for k in kids {
                let n = &nodes[k];
                let pushed = t.push(&n.name, index, n.size, n.size, n.dir);
                queue.push_back((k, pushed));
            }
        }
        t.link_children();
        t
    }

    pub(super) fn build(root: &str, paths: &[&str]) -> Tree {
        build_with(root, paths, &mut |v| v)
    }

    /// Root-relative path of a node.
    pub(super) fn rel(t: &Tree, i: u32) -> String {
        let mut parts = Vec::new();
        let mut i = i as usize;
        while i != 0 {
            parts.push(t.name(i));
            i = t.parents[i] as usize;
        }
        parts.reverse();
        parts.join("/")
    }

    /// Candidates as sorted (relative path, kind id) pairs.
    fn found(t: &Tree, home: Option<&str>) -> Vec<(String, &'static str)> {
        let mut v: Vec<_> = find(t, MIN_BYTES, &Anchors::new(home.map(Path::new)))
            .iter()
            .map(|c| (rel(t, c.node), c.kind.id()))
            .collect();
        v.sort();
        v
    }

    fn expect(rows: &[(&str, &'static str)]) -> Vec<(String, &'static str)> {
        let mut v: Vec<_> = rows.iter().map(|(p, k)| (p.to_string(), *k)).collect();
        v.sort();
        v
    }

    #[test]
    fn node_modules_requires_a_sibling_package_json() {
        let t = build("/w", &["global/lib/node_modules/npm/x", "app/package.json", "app/node_modules/x"]);
        assert_eq!(found(&t, None), expect(&[("app/node_modules", "node_modules")]));
    }

    #[test]
    fn home_cache_roots_are_containers_and_their_children_are_candidates() {
        let t = build(
            "/Users/u",
            &[
                ".cache/pip/x",
                "Library/Caches/com.example.app/x",
                "Library/Caches/com.apple.Safari/x",
            ],
        );
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[(".cache/pip", "tool_caches"), ("Library/Caches/com.example.app", "app_caches")])
        );
    }

    #[test]
    fn gradle_home_with_config_is_never_a_candidate_but_its_caches_are() {
        let t = build(
            "/Users/u",
            &[".gradle/gradle.properties", ".gradle/caches/x", ".gradle/init.d/x", ".gradle/wrapper/x"],
        );
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[(".gradle/caches", "gradle_cache"), (".gradle/wrapper", "gradle_cache")])
        );
    }

    #[test]
    fn cargo_home_is_never_a_candidate_but_registry_and_git_are() {
        let t = build(
            "/Users/u",
            &[".cargo/registry/x", ".cargo/git/x", ".cargo/bin/x", ".cargo/credentials.toml", ".cargo/env"],
        );
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[(".cargo/git", "cargo_cache"), (".cargo/registry", "cargo_cache")])
        );
    }

    #[test]
    fn cachedir_tag_marks_a_tagged_cache() {
        let t = build("/w", &["tool/state/CACHEDIR.TAG", "tool/state/blob"]);
        assert_eq!(found(&t, None), expect(&[("tool/state", "tagged_cache")]));
    }

    #[test]
    fn git_worktrees_are_emitted_and_descended_but_submodules_are_not() {
        let t = build(
            "/w",
            &[
                "repo/.git/HEAD",
                "repo/src/x",
                "repo/sub/.git",
                "repo/sub/x",
                "repo/.claude/worktrees/feature/.git",
                "repo/.claude/worktrees/feature/package.json",
                "repo/.claude/worktrees/feature/node_modules/x",
                "loose/.git",
                "loose/x",
            ],
        );
        assert_eq!(
            found(&t, None),
            expect(&[
                ("loose", "git_worktree"),
                ("repo/.claude/worktrees/feature", "git_worktree"),
                ("repo/.claude/worktrees/feature/node_modules", "node_modules"),
            ])
        );
    }

    #[test]
    fn home_rules_follow_the_data_volume_alias_and_roots_inside_home() {
        let paths = ["Users/u/.cache/pip/x", "Users/u/.cargo/registry/x", "Users/u/.cargo/bin/x"];
        let expected = expect(&[
            ("Users/u/.cache/pip", "tool_caches"),
            ("Users/u/.cargo/registry", "cargo_cache"),
        ]);
        let t = build("/System/Volumes/Data", &paths);
        assert_eq!(found(&t, Some("/Users/u")), expected);
        let t = build("/", &paths);
        assert_eq!(found(&t, Some("/Users/u")), expected);
        // A scan rooted inside the home anchors by the root's own path.
        let t = build("/Users/u/.cache", &["pip/x", "uv/x"]);
        assert_eq!(found(&t, Some("/Users/u")), expect(&[("pip", "tool_caches"), ("uv", "tool_caches")]));
        let t = build("/Users/u/Library/", &["Caches/com.example/x"]);
        assert_eq!(found(&t, Some("/Users/u")), expect(&[("Caches/com.example", "app_caches")]));
        // Outside the home, home rules never match: a project .cache stays whole.
        let t = build("/Volumes/X", &[".cache/pip/x", ".cargo/registry/x"]);
        assert_eq!(found(&t, Some("/Users/u")), expect(&[(".cache", "tool_caches")]));
    }

    /// The complete rule set. Every row of the old nine-rule table whose
    /// behavior is unchanged is kept; changed rows say what changed. Each row
    /// is an independent tree: (root, home, entries, expected candidates).
    #[test]
    fn recognizes_the_cleanup_category_rules_and_no_others() {
        const H: Option<&str> = Some("/Users/u");
        #[rustfmt::skip]
        let cases: &[(&str, Option<&str>, &[&str], &[(&str, &str)])] = &[
            // Unchanged rows of the original table.
            ("/root", None, &[".venv/x"], &[(".venv", "python_environment")]),
            ("/root", None, &["p/venv/pyvenv.cfg"], &[("p/venv", "python_environment")]),
            ("/root", None, &["p/venv/x"], &[]),
            ("/root", None, &["p/target/x", "p/Cargo.toml"], &[("p/target", "rust_build")]),
            ("/root", None, &["p/target/x"], &[]),
            ("/root", None, &["p/.next/x", "p/package.json"], &[("p/.next", "next_build")]),
            ("/root", None, &["p/.next/x"], &[]),
            ("/root", None, &["Xcode/DerivedData/x"], &[("Xcode/DerivedData", "xcode_derived_data")]),
            ("/root", None, &["other/DerivedData/x"], &[]),
            ("/root", None, &["a/iOS DeviceSupport/x"], &[("a/iOS DeviceSupport", "device_support")]),
            ("/root", None, &["a/macOS DeviceSupport/x"], &[("a/macOS DeviceSupport", "device_support")]),
            ("/root", None, &["a/watchOS DeviceSupport/x"], &[("a/watchOS DeviceSupport", "device_support")]),
            ("/root", None, &["CoreSimulator/Caches/x"], &[("CoreSimulator/Caches", "app_caches")]),
            ("/root", None, &["other/Caches/x"], &[]),
            ("/root", None, &["a/.cache/x"], &[("a/.cache", "tool_caches")]),
            ("/root", None, &["a/.npm/x"], &[("a/.npm", "tool_caches")]),
            ("/root", None, &["a/.gradle/x"], &[("a/.gradle", "tool_caches")]),
            ("/root", None, &[".bun/install/cache/x"], &[(".bun/install/cache", "bun_cache")]),
            ("/root", None, &["other/install/cache/x"], &[]),
            ("/root", None, &[".bun/other/cache/x"], &[]),
            ("/Users/u", H, &["Downloads/x"], &[]),
            // Changed: node_modules needs package.json (global npm prefixes are installed CLIs).
            ("/root", None, &["p/node_modules/x", "p/package.json"], &[("p/node_modules", "node_modules")]),
            ("/root", None, &["lib/node_modules/npm/package.json", "lib/node_modules/npm/node_modules/x"], &[]),
            // Changed: Library/Caches is a container at home, whole when deeper in
            // the home, skipped elsewhere (system /Library/Caches, other users).
            ("/Users/u", H, &["Library/Caches/a/x", "Library/Caches/com.apple.b/x"], &[("Library/Caches/a", "app_caches")]),
            ("/Users/u", H, &["Library/Containers/c/Data/Library/Caches/x"], &[("Library/Containers/c/Data/Library/Caches", "app_caches")]),
            ("/", H, &["Library/Caches/x", "Users/v/Library/Caches/x"], &[]),
            ("/root", None, &["a/Library/Caches/x"], &[]),
            // Changed: ~/.cache is a container; elsewhere .cache stays whole.
            ("/Users/u", H, &[".cache/pip/x", ".cache/torch/x", ".cache/huggingface/token",
                ".cache/huggingface/xet/x", ".cache/huggingface/hub/models--a/x",
                ".cache/huggingface/hub/datasets--b/x", ".cache/huggingface/hub/spaces--c/x",
                ".cache/huggingface/hub/.locks/x"],
                &[(".cache/pip", "tool_caches"), (".cache/torch", "ml_model"),
                  (".cache/huggingface/hub/models--a", "ml_model"),
                  (".cache/huggingface/hub/datasets--b", "ml_model"),
                  (".cache/huggingface/hub/spaces--c", "ml_model")]),
            // Changed: a Gradle user home (config inside, or at home) is a container.
            ("/Users/u", H, &[".gradle/caches/x", ".gradle/wrapper/x", ".gradle/daemon/x", ".gradle/jdks/x",
                ".gradle/native/x", ".gradle/.tmp/x", ".gradle/init.d/x", ".gradle/workers/x"],
                &[(".gradle/caches", "gradle_cache"), (".gradle/wrapper", "gradle_cache"),
                  (".gradle/daemon", "gradle_cache"), (".gradle/jdks", "gradle_cache"),
                  (".gradle/workers", "gradle_cache")]),
            ("/root", None, &["g/.gradle/gradle.properties", "g/.gradle/caches/x"], &[("g/.gradle/caches", "gradle_cache")]),
            ("/Users/u", H, &[".cache/gradle/gradle.properties", ".cache/gradle/caches/x", ".cache/pip/x"],
                &[(".cache/gradle/caches", "gradle_cache"), (".cache/pip", "tool_caches")]),
            // New home rules.
            ("/Users/u", H, &[".cargo/registry/x", ".cargo/git/x", ".cargo/bin/x", ".cargo/config.toml", ".cargo/env/x"],
                &[(".cargo/git", "cargo_cache"), (".cargo/registry", "cargo_cache")]),
            ("/root", None, &["p/.cargo/registry/x"], &[]),
            ("/Users/u", H, &[".m2/repository/x", ".m2/settings.xml", ".m2/wrapper/x"], &[(".m2/repository", "maven_repository")]),
            ("/Users/u", H, &[".ollama/models/x", ".ollama/id_ed25519"], &[(".ollama/models", "ollama_models")]),
            ("/Users/u", H, &[".rustup/toolchains/stable/x", ".rustup/downloads/x", ".rustup/tmp/x", ".rustup/update-hashes/x"],
                &[(".rustup/downloads", "tool_caches"), (".rustup/tmp", "tool_caches"),
                  (".rustup/toolchains/stable", "rust_toolchain")]),
            ("/Users/u", H, &[".claude/projects/p1/x", ".claude/file-history/x", ".claude/debug/x",
                ".claude/settings.json", ".claude/local/package.json", ".claude/local/node_modules/x"],
                &[(".claude/debug", "agent_logs"), (".claude/file-history", "agent_checkpoints"),
                  (".claude/projects/p1", "agent_transcripts")]),
            ("/Users/u", H, &[".codex/sessions/2025/x", ".codex/sessions/misc/x", ".codex/archived_sessions/x",
                ".codex/worktrees/a/.git", ".codex/worktrees/a/package.json", ".codex/worktrees/a/node_modules/x",
                ".codex/worktrees/b/x", ".codex/auth.json", ".codex/config.toml"],
                &[(".codex/archived_sessions", "codex_sessions"), (".codex/sessions/2025", "codex_sessions"),
                  (".codex/worktrees/a", "git_worktree"), (".codex/worktrees/a/node_modules", "node_modules"),
                  (".codex/worktrees/b", "agent_worktree_leftover")]),
            ("/Users/u", H, &["Library/Application Support/Code/Cache/x", "Library/Application Support/Code/User/x",
                "Library/Application Support/Slack/GPUCache/x"],
                &[("Library/Application Support/Code/Cache", "app_caches"),
                  ("Library/Application Support/Slack/GPUCache", "app_caches")]),
            ("/root", None, &["Application Support/Code/Cache/x"], &[]),
            // Xcode.
            ("/root", None, &["Xcode/Archives/x", "Xcode/UserData/Previews/x", "Developer/XCTestDevices/x"],
                &[("Developer/XCTestDevices", "xcode_test_devices"), ("Xcode/Archives", "xcode_archives"),
                  ("Xcode/UserData/Previews", "xcode_previews")]),
            // Changed: marker-gated project build output (was not recognized).
            ("/root", None, &["s/.build/x", "s/Package.swift"], &[("s/.build", "swift_build")]),
            ("/root", None, &["s/.build/x"], &[]),
            ("/root", None, &["g/build/x", "g/build.gradle.kts"], &[("g/build", "gradle_build")]),
            ("/root", None, &["g/build/x"], &[]),
            ("/root", None, &["d/.dart_tool/x", "d/pubspec.yaml"], &[("d/.dart_tool", "dart_build")]),
            ("/root", None, &["j/.turbo/x", "j/.angular/x", "j/package.json"], &[("j/.angular", "js_build_cache"), ("j/.turbo", "js_build_cache")]),
            ("/root", None, &["j/.turbo/x"], &[]),
            ("/root", None, &["i/Pods/x", "i/Podfile"], &[("i/Pods", "cocoapods")]),
            ("/root", None, &["py/.tox/x", "py/.nox/x"], &[("py/.nox", "python_test_environments"), ("py/.tox", "python_test_environments")]),
            ("/root", None, &["z/zig-out/x", "z/.zig-cache/x", "z/build.zig"], &[("z/.zig-cache", "zig_build"), ("z/zig-out", "zig_build")]),
            ("/root", None, &["e/_build/x", "e/deps/x", "e/mix.exs"], &[("e/_build", "elixir_build"), ("e/deps", "elixir_build")]),
            ("/root", None, &["e/deps/x"], &[]),
            ("/root", None, &["h/.stack-work/x", "h/dist-newstyle/x"], &[("h/.stack-work", "haskell_build"), ("h/dist-newstyle", "haskell_build")]),
            // Structure rules come after every named rule.
            ("/root", None, &["r/target/CACHEDIR.TAG", "r/target/x", "r/Cargo.toml"], &[("r/target", "rust_build")]),
            ("/root", None, &["c/CACHEDIR.TAG/x"], &[]),
            ("/root", None, &["w/.git/x"], &[]),
            ("/root", None, &["Downloads/x"], &[]),
        ];
        for (root, home, paths, expected) in cases {
            assert_eq!(found(&build(root, paths), *home), expect(expected), "{root} {paths:?}");
        }
    }

    /// Every ancestor-name rule must match when that ancestor is the scan
    /// root, whose node name is a full path.
    #[test]
    fn ancestor_name_rules_match_when_the_ancestor_is_the_scan_root() {
        const H: Option<&str> = Some("/Users/u");
        #[rustfmt::skip]
        let cases: &[(&str, Option<&str>, &[&str], &[(&str, &str)])] = &[
            ("/Users/u/Library/Developer/Xcode", None, &["DerivedData/x", "Archives/x"],
                &[("Archives", "xcode_archives"), ("DerivedData", "xcode_derived_data")]),
            ("/Users/u/Library/Developer/Xcode/UserData", None, &["Previews/x"], &[("Previews", "xcode_previews")]),
            ("/Users/u/Library/Developer", None, &["XCTestDevices/x", "CoreSimulator/Caches/x"],
                &[("CoreSimulator/Caches", "app_caches"), ("XCTestDevices", "xcode_test_devices")]),
            ("/Users/u/Library/Developer/CoreSimulator", None, &["Caches/x"], &[("Caches", "app_caches")]),
            ("/x/.bun", None, &["install/cache/x"], &[("install/cache", "bun_cache")]),
            ("/x/.bun/install", None, &["cache/x"], &[("cache", "bun_cache")]),
            ("/Users/u/Library", H, &["Caches/a/x"], &[("Caches/a", "app_caches")]),
            ("/Users/u/Library/Caches", H, &["a/x", "com.apple.b/x"], &[("a", "app_caches")]),
            ("/Users/u/Library/Containers/c/Data/Library", H, &["Caches/x"], &[("Caches", "app_caches")]),
            ("/Library", H, &["Caches/x"], &[]),
            ("/Users/u/Library/Application Support", H, &["Code/Cache/x"], &[("Code/Cache", "app_caches")]),
            ("/Users/u/Library/Application Support/Code", H, &["Cache/x"], &[("Cache", "app_caches")]),
            ("/repo/.claude/worktrees", None, &["a/.git", "a/x"], &[("a", "git_worktree")]),
            ("/root/p", None, &["node_modules/x", "package.json"], &[("node_modules", "node_modules")]),
            ("/Users/u/.gradle", H, &["caches/x", "native/x"], &[("caches", "gradle_cache")]),
            ("/elsewhere/.gradle", None, &["caches/x", "gradle.properties"], &[("caches", "gradle_cache")]),
            ("/Users/u/.cargo", H, &["registry/x", "bin/x"], &[("registry", "cargo_cache")]),
            ("/Users/u/.claude/projects", H, &["p/x"], &[("p", "agent_transcripts")]),
            ("/Users/u/.codex/sessions", H, &["2024/x", "misc/x"], &[("2024", "codex_sessions")]),
            ("/Users/u/.codex/worktrees", H, &["a/.git", "a/x", "b/x"], &[("a", "git_worktree"), ("b", "agent_worktree_leftover")]),
            ("/Users/u/.cache/huggingface", H, &["hub/models--a/x", "token", "xet/x"], &[("hub/models--a", "ml_model")]),
            ("/Users/u/.cache/huggingface/hub", H, &["models--a/x", ".locks/x"], &[("models--a", "ml_model")]),
            ("/Users/u/.rustup/toolchains", H, &["stable/x"], &[("stable", "rust_toolchain")]),
            ("/System/Volumes/Data/Users/u", H, &[".cache/pip/x"], &[(".cache/pip", "tool_caches")]),
            ("/Users/u/", H, &[".cache/pip/x"], &[(".cache/pip", "tool_caches")]),
        ];
        for (root, home, paths, expected) in cases {
            assert_eq!(found(&build(root, paths), *home), expect(expected), "{root} {paths:?}");
        }
    }

    /// The root-seeding table and the walk must agree for every container.
    #[test]
    fn every_home_container_is_the_same_as_a_root_and_inside_the_walk() {
        for (rel, _) in HOME_CONTAINERS {
            let prefix = rel.join("/");
            let children = ["models--m/x", "registry/x", "caches/x", "projects/x", "2025/x", "a/x", "hub/x", "toolchains/x"];
            let nested: Vec<String> = children.iter().map(|c| format!("{prefix}/{c}")).collect();
            let nested: Vec<&str> = nested.iter().map(String::as_str).collect();
            let from_home = found(&build("/Users/u", &nested), Some("/Users/u"));
            let from_root = found(&build(&format!("/Users/u/{prefix}"), &children), Some("/Users/u"));
            let rebased: Vec<_> = from_root.into_iter().map(|(p, k)| (format!("{prefix}/{p}"), k)).collect();
            assert_eq!(from_home, rebased, "{prefix}");
        }
    }

    #[test]
    fn the_home_and_its_ancestors_are_never_candidates() {
        // A dotfiles `.git` file or a stray CACHEDIR.TAG must not make the home one.
        let t = build("/", &["Users/CACHEDIR.TAG", "Users/u/.git", "Users/u/p/package.json", "Users/u/p/node_modules/x"]);
        assert_eq!(found(&t, Some("/Users/u")), expect(&[("Users/u/p/node_modules", "node_modules")]));
        // Without a home anchor the same tree reports the tagged folder (review in Swift).
        assert_eq!(found(&t, None), expect(&[("Users", "tagged_cache")]));
        // Nor folders the Swift guard always refuses: broad home folders and the
        // home's direct non-dot children. Marked ones are still looked into.
        let t = build(
            "/Users/u",
            &[
                "Library/CACHEDIR.TAG", "Library/Developer/.git", "Library/Developer/x",
                "Downloads/CACHEDIR.TAG", "Downloads/x",
                "wt/.git", "wt/package.json", "wt/node_modules/x",
                "node_modules/x", "package.json", "Pods/x", "Podfile",
                ".hidden/CACHEDIR.TAG", ".hidden/x",
            ],
        );
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[(".hidden", "tagged_cache"), ("wt/node_modules", "node_modules")])
        );
    }

    #[test]
    fn anchors_reject_unusable_homes_and_add_the_data_volume_spelling() {
        for bad in ["relative", "/", "/Users/../etc", ""] {
            assert_eq!(Anchors::new(Some(Path::new(bad))), Anchors::default(), "{bad}");
        }
        assert_eq!(Anchors::new(None), Anchors::default());
        let a = Anchors::new(Some(Path::new("/Users/u/")));
        let b = Anchors::new(Some(Path::new("/System/Volumes/Data/Users/u")));
        assert_eq!(a.homes.len(), 2);
        assert_eq!(a.homes[0], b.homes[1]);
        assert_eq!(a.homes[1], b.homes[0]);
    }

    #[test]
    fn kind_metadata_is_complete_and_consistent() {
        let mut ids = std::collections::HashSet::new();
        for &kind in Kind::ALL {
            assert!(ids.insert(kind.id()), "duplicate id {}", kind.id());
            assert_eq!(kind.c_id().to_str().unwrap(), kind.id());
            assert!(!kind.id().is_empty() && !kind.description().is_empty());
            assert_eq!(kind.descends(), kind == Kind::GitWorktree);
            assert!(matches!(kind.verify(), None | Some("cachedir_tag" | "git_worktree" | "recent_activity")));
            assert_eq!(kind.c_verify().to_str().unwrap(), kind.verify().unwrap_or(""));
            assert!(Section::ALL.contains(&kind.section()));
        }
        assert_eq!(Kind::ALL.len(), 34);
        for (kind, id) in [
            (Kind::NodeModules, "node_modules"), (Kind::PythonEnvironment, "python_environment"),
            (Kind::RustBuild, "rust_build"), (Kind::NextBuild, "next_build"),
            (Kind::XcodeDerivedData, "xcode_derived_data"), (Kind::DeviceSupport, "device_support"),
            (Kind::AppCaches, "app_caches"), (Kind::ToolCaches, "tool_caches"), (Kind::BunCache, "bun_cache"),
        ] {
            assert_eq!(kind.id(), id, "existing ids are stable");
        }
        let sections: Vec<_> = Section::ALL.iter().map(|s| s.id()).collect();
        assert_eq!(sections, ["build", "packages", "apps", "devtools", "models", "agents", "worktrees"]);
        assert_eq!(Section::Build.c_id().to_str().unwrap(), "build");
        assert_eq!((Group::Safe.id(), Group::Review.id()), ("safe", "review"));
        assert_eq!((Group::Safe as u8, Group::Review as u8), (0, 1));
        for review in [Kind::MavenRepository, Kind::MlModel, Kind::GitWorktree, Kind::AgentTranscripts] {
            assert_eq!(review.group(), Group::Review);
        }
    }

    #[test]
    fn enclosing_reports_only_container_parents() {
        let t = build("/w", &["wt/.git", "wt/package.json", "wt/node_modules/x", "p/package.json", "p/node_modules/x"]);
        let f = find(&t, MIN_BYTES, &Anchors::default());
        let enc = enclosing(&t, &f);
        for (k, c) in f.iter().enumerate() {
            match rel(&t, c.node).as_str() {
                "wt/node_modules" => assert_eq!(enc[k].map(|e| f[e].kind), Some(Kind::GitWorktree)),
                _ => assert_eq!(enc[k], None),
            }
        }
        assert_eq!(f.len(), 3);
    }

    #[test]
    fn preserves_panel_traversal_threshold_and_partial_candidates() {
        let mut scan = Tree::default();
        add(
            &mut scan,
            NO_PARENT,
            "/root/node_modules",
            true,
            MIN_BYTES * 10,
        );
        let trash = add(&mut scan, 0, ".Trash", true, MIN_BYTES * 2);
        add(&mut scan, 0, ".cache", false, MIN_BYTES * 2);
        let matched = add(&mut scan, 0, "node_modules", true, MIN_BYTES);
        let small = add(&mut scan, 0, ".gradle", true, MIN_BYTES - 1);
        add(&mut scan, 0, "package.json", false, 0);
        add(&mut scan, trash, "node_modules", true, MIN_BYTES * 2);
        add(&mut scan, matched, ".venv", true, MIN_BYTES);
        // Deliberately inconsistent size catches descent under a small match.
        add(&mut scan, small, ".venv", true, MIN_BYTES);
        let mut scan = link(scan);
        scan.complete[matched as usize] = false;
        assert_eq!(
            find(&scan, MIN_BYTES, &Anchors::default()),
            vec![Candidate {
                node: matched,
                kind: Kind::NodeModules
            }]
        );
    }

    #[test]
    fn size_ties_are_lexical_independent_of_discovery_order() {
        for names in [["z", "a"], ["a", "z"]] {
            let mut scan = Tree::default();
            add(&mut scan, NO_PARENT, "/root", true, 0);
            let first = add(&mut scan, 0, names[0], true, MIN_BYTES);
            let second = add(&mut scan, 0, names[1], true, MIN_BYTES);
            let large = add(&mut scan, 0, ".npm", true, MIN_BYTES * 2);
            let first_cache = add(&mut scan, first, ".cache", true, MIN_BYTES);
            let second_cache = add(&mut scan, second, ".cache", true, MIN_BYTES);
            let scan = link(scan);
            let expected = if names[0] == "a" {
                vec![large, first_cache, second_cache]
            } else {
                vec![large, second_cache, first_cache]
            };
            assert_eq!(
                find(&scan, MIN_BYTES, &Anchors::default())
                    .iter()
                    .map(|c| c.node)
                    .collect::<Vec<_>>(),
                expected
            );
        }
    }
}
