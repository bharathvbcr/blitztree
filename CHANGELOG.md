# Changelog

## Unreleased

- MANVI can plan cleanups, alongside Claude Code, Codex and custom providers: the whole scan, or one item from the right-click menu. Pick a local model (Ollama, LM Studio, vLLM and others) or a hosted provider for it in Settings → Model Providers, and choose it as the Clean Up planner in Settings → General or from the Clean Up menu. BlitzTree starts MANVI headless in its strict posture, where its own gate refuses every file write and shell command; a run that does not report that posture is stopped. Run it on the cloud, on a local model, or local first with the cloud taking over when the local model gives no plan (server not running, too slow, no answer); the panel says which side is answering and when it switches, and the Clean Up menu can force either side for one run. Pick the cloud provider (Anthropic, Gemini, xAI) and, for Claude, the model from Anthropic's live list for your key. A cloud key comes from your login shell's export or from a Keychain item (`anthropic-api-key` by default, as `security add-generic-password -s anthropic-api-key` stores it), read only when a cloud run starts or models are listed; a workspace ID can be set for keys not scoped to one. MANVI only plans; BlitzTree's guards and two-step delete apply as for every planner. BlitzTree does not install MANVI.
- Build output in Claude Code's temp scratchpads (`/private/tmp/claude-<uid>/<project>/<session>/scratchpad/…`, typically Cargo `target` folders) is recognised as its own kind and can be cleaned by the panel and by every planner once the session that made it has stopped. Whether a session still runs comes from Claude Code's own registry of live sessions, plus any write in its temp folder in the last 15 minutes; if that can't be read, nothing in the folder is touched. Before this, the panel offered these folders with no session check, and planners could not clean them at all. Nothing else in a session's temp folder is ever offered.
- After a Move to Trash, search results, Clean Up's list, the Largest Files list and the maps could briefly read the updated scan with the old item numbers. That showed the wrong items, and could crash. Clean Up's checkboxes could also end up on different folders than the ones picked. Everything tied to the old scan is now cleared the moment the map updates, and Clean Up remembers picks by path.
- An item moved to the Trash while a rescan was running could reappear when that scan finished. It now stays off the map.
- A folder no longer stays marked incomplete after its only unreadable part goes to the Trash.
- Known limitation: a hard-linked or cloned file's bytes count once, under the first path scanned. If you trash that path while another link or clone remains, the map drops those bytes until the next scan rather than moving them to the copy that is left.

## 0.6.1 — 2026-10-07

This release adds a Largest Files list, counts APFS clones once, puts every mounted volume in the Scan menu, and teaches Clean Up many more kinds of reclaimable space.

- The directory list takes multiple selections (⌘- and ⇧-click), sorts by name, size or file count, and has a Files column with each folder's file count. Right-click, Copy Path and Move to Trash act on the whole selection, with one confirmation.
- Moving items to the Trash takes them off the map right away instead of rescanning the disk. Sizes and file counts of the folders above drop to match; anything that couldn't be moved stays shown.
- Clean Up recognizes much more: Swift, Gradle, Dart, CocoaPods, Zig, Elixir, Haskell and front-end build folders next to their project files; Cargo, Gradle and Maven caches; Electron app caches; Xcode archives and previews; Rust toolchains; Hugging Face, PyTorch and Ollama models; Claude Code and Codex session history; leftover git worktrees; and any folder marked with a `CACHEDIR.TAG`.
- Before anything is removed, Clean Up re-checks items that need it: a git worktree must be clean, unlocked, unused for 2 days and have nothing running inside it; a `CACHEDIR.TAG` must carry the real signature; agent history must be untouched for 2 days. A check that can't run blocks the item. A `node_modules` without a `package.json` beside it (such as a global npm folder of installed tools) is no longer offered.
- The CLI's candidates carry `group` (safe or review), `section` (build, packages, apps, devtools, models, agents, worktrees), `verify` and `contained_in`, and totals no longer count a candidate inside another one twice.
- Signing in to Claude Code or Codex from the Clean Up menu opens the sign-in page in your browser. Before, the CLI waited for a browser that never opened, because it only opens one when run in a terminal. If sign-in fails, the error says why.
- A Largest Files list above the directory list shows the biggest files anywhere in the scan, so a 20 GB file buried deep in the tree is one click away. Picking one reveals it on the map; right-click gives the same menu as the map. The Rust engine picks the files and the CLI's `largest_files` uses the same code, so the two always agree.
- APFS clones count once. Copies made with `cp -c` or Chrome's code-signing clones in `/private/var/folders/…/X/com.google.Chrome.code_sign_clone` share one set of blocks but each reported the full size, so a 1 TB disk could show 1.7 TB used. Whole clones now count once, under their first path, like hard links. On the machine that reported it, the data volume went from 1.61 TB scanned to 816 GB (852 GB in use), and the Chrome folder from 767 GB to 0.76 GB.
- A clone edited after copying gets its own identity on APFS and still counts in full, so a scan can still exceed what the disk holds. When it does, the status bar says by how much instead of saying nothing.
- FAT32 drives (through FSKit) listed every file at 0 bytes allocated, because the volume leaves that size out of directory listings. BlitzTree now reads it per file there.
- A malformed directory entry from a file system is counted as an unreadable item instead of crashing the scan.
- The CLI reports `coverage.shared_allocated_bytes` (what hard links and clones would have added again) and `coverage.clone_ids_unavailable_directories` (folders on volumes without clone tracking).
- The "root-only" note in the status bar is translated.
- The Scan menu lists every mounted local volume with its used and total space, so an external drive is one click instead of browsing to `/Volumes`. The list follows drives as they mount, unmount or are renamed. Network shares are left out: each folder read is a round trip to the server, so a large share scans slowly and loads the server, and the capacity it reports may be a quota. Choose Folder… still opens them.
- Free space on exFAT, FAT and NTFS drives showed as zero, so the free-space tile was missing after scanning one. Those volumes now report their plain free space.

## 0.6.0 — 2026-10-06

This release adds search, custom model providers, a translated interface, and per-item cleanup advice.

- Search the scan by name with ⌘F. `*` and `?` work as wildcards, results are listed largest first, and picking one opens the list and reveals it on the maps. Matching runs in the Rust engine and takes under 12 ms on a 3.6-million-entry tree, so typing stays responsive during whole-disk scans.
- Custom model providers: in Settings → Model Providers, connect any OpenAI- or Anthropic-compatible endpoint (Chat Completions, Responses or Anthropic Messages) by its base URL, API key (kept in the Keychain) and model. The plan streams in as the model writes it. The endpoint never runs tools, and BlitzTree's guards and two-step delete still apply. Choose the Clean Up planner in Settings → General.
- BlitzTree is available in German, Spanish, French, Japanese, Turkish and Simplified Chinese as well as English. Pick a language in Settings → General; it applies when you relaunch. The agent's live step lines and the reasons BlitzTree won't remove something are translated too, while what BlitzTree sends to the agent stays in English.
- Right-click any file or folder in the treemap, rings, list or Clean Up panel and choose **Ask Claude Code If It's Safe to Clean** (or your planner) to plan for that item alone. Every suggestion stays inside the item you asked about.
- Right-click menus offer **Copy Path** (⌥⌘C) and **Move to Trash** (⌘⌫), which also work as shortcuts on the selection in the list and treemap ([#9](https://github.com/ahmedkhaleel2004/blitztree/issues/9)). Moving something to the Trash rescans. The path in the status bar can be selected and copied.
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
