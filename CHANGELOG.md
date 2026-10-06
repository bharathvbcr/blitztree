# Changelog

## 0.6.0 — 2026-10-06

This release adds search, custom model providers, a translated interface, and per-item cleanup advice.

- Search the scan by name with ⌘F. `*` and `?` work as wildcards, results are listed largest first, and picking one opens the list and reveals it on the maps. Matching runs in the Rust engine and takes under 12 ms on a 3.6-million-entry tree, so typing stays responsive during whole-disk scans.
- Custom model providers: in Settings → Model Providers, connect any OpenAI- or Anthropic-compatible endpoint (Chat Completions, Responses or Anthropic Messages) by its base URL, API key (kept in the Keychain) and model. The plan streams in as the model writes it. The endpoint never runs tools, and BlitzTree's guards and two-step delete still apply. Choose the Clean Up planner in Settings → General.
- BlitzTree is available in German, Spanish, French, Japanese, Turkish and Simplified Chinese as well as English. Pick a language in Settings → General; it applies when you relaunch. The agent's live step lines and the reasons BlitzTree won't remove something are translated too, while what BlitzTree sends to the agent stays in English.
- Right-click any file or folder in the treemap, rings, list or Clean Up panel and choose **Ask Claude Code If It's Safe to Clean** (or your planner) to plan for that item alone. Every suggestion stays inside the item you asked about.
- Right-click menus offer **Copy Path** (⌥⌘C) and **Move to Trash** (⌘⌫), which also work as shortcuts on the selection in the list and treemap. Moving something to the Trash rescans. The path in the status bar can be selected and copied.
- Settings → General: choose what to scan at launch (Macintosh HD, your Home folder, or a folder you pick each time), and turn on **Auto-analyse suggestions** to plan cleanup as soon as the launch scan finishes. It is off by default, so nothing leaves your Mac until you click.
- Claude Code is the suggested agent when none is installed. The Clean Up menu offers to sign in to or set up whichever agent isn't ready. A project Claude Code worked in during the last 2 days counts as recently used, so its build output is kept.
- Safety: the cleanup guards run again right before each Trash or command and refuse if anything changed; paths that pass through a symlink are refused; `~/Library/LaunchAgents` and similar folders are never cleaned; commands must match the allowlist exactly; and the Codex installer is pinned to a version and checks its SHA-256.
- Live sizes no longer jitter while counting: the scan counter keeps two decimals and sizes that update in place use fixed-width digits (contributed by @kingwhiiitee).
- Scan results reach the window before the volume's capacity is read, and ranking and hard-link accounting no longer allocate temporary paths (contributed by @512banque).

Custom model providers, the translations and the safety hardening were contributed by @emircanerkul.

## 0.5.6 — 2026-09-27

- BlitzTree updates itself. It checks GitHub for a new release once a day, downloads it in the background and installs it when you quit. Check for Updates… is in the BlitzTree menu. Updates are signed, and Full Disk Access carries over.
- Coming from 0.5.5 or earlier: download this version once by hand; from here on it updates itself.

## 0.5.5 — 2026-09-27

- AI cleanup only runs when you click "Clean up with Claude Code" (or Codex). Before, the first scan after launch started your agent on its own, which sent folder paths and sizes to Anthropic or OpenAI without asking. Now the panel opens on the button and nothing leaves your Mac until you click it.

## 0.5.4 — 2026-09-27

- AI cleanup: while "Delete for good" runs, the size counts down as each item finishes. Since deletes started running in parallel (0.4.1) the number disappeared until the whole delete was done.

## 0.5.3 — 2026-09-27

BlitzTree is now signed with a Developer ID and notarized by Apple: it opens with a normal double-click, with no Open Anyway step.

- AI cleanup can plan Xcode simulator runtimes and device data (through `xcrun simctl`) and the Codex app's chat folders in `~/Documents/Codex`. Chats used in the last 2 days are kept.
- Plan items and list selections light up on the treemap and rings even when their folder is drawn inside a combined "A ▸ B" box, and files light up too.
- Clicking a plan card or Reclaimable row outside the zoomed folder zooms out to it.

Updating from 0.5.2 or earlier: the new signature means macOS asks for Full Disk Access once more. Remove the old BlitzTree row in System Settings → Privacy & Security → Full Disk Access, add the new app, and relaunch.

## 0.5.2 — 2026-09-27

This release halves scan memory, doubles treemap render speed, and adds a read-only JSON CLI.

- Build the scan's flat tree during the walk: about half the peak memory, and the tree reaches the UI 3–4x sooner after the last directory is read.
- Treemap renders about 2x faster (each pixel shaded once) and hover redraws only what changed, with identical pixels.
- Selecting a file inside a very large folder in the list is about 2x faster.
- Optional read-only JSON CLI (`blitztree scan`, `blitztree quick-wins`) built from source with `--features cli`, sharing the Clean Up rules with the app (contributed by @512banque).
- Hard-linked files are credited to the same path on every scan, and incomplete subtrees are tracked.

Rust tests, CLI tests, rendering comparisons against 0.5.1 (identical pixels) and full-tree dumps against the previous engine (identical) passed. Scan wall time is unchanged: it is bound by the kernel. Measurements are in [PERFORMANCE_AUDIT.md](PERFORMANCE_AUDIT.md).

## 0.5.1 — 2026-09-27

This release improves scan memory use, rendering, post-scan responsiveness, and cleanup plan processing.

- Reduce scanner allocations and store sibling nodes as compact ranges. The measured applications scan used about 16% less peak memory with identical file, directory, and byte totals.
- Draw treemaps and complex Retina rings faster, and make pointer lookup much cheaper for large trees.
- Shorten post-scan UI stalls by isolating progress/status updates, reading volume metadata in the background, and reusing unchanged collapsed outline rows.
- Process streamed cleanup plans incrementally and skip small subtrees during cleanup and prompt preparation.
- Run manual Trash batches off the main thread, prevent duplicate batches and late agent launches after cancellation, and retain cleanup errors until dismissed.

Release builds, rendering comparisons, Rust tests, offline agent/cleanup tests, and native UI checks passed. Reproducible measurements and limitations are in [PERFORMANCE_AUDIT.md](PERFORMANCE_AUDIT.md). Scan-throughput measurements were inconclusive. Complex Retina ring strokes have small bounded antialiasing differences; geometry and hit behavior are unchanged.

Requires Apple Silicon and macOS 14 or later. This release is signed with the existing Apple Development identity but is **not notarized**. First-time installations may require **System Settings → Privacy & Security → Open Anyway**, followed by granting Full Disk Access and relaunching.
