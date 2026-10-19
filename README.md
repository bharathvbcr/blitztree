<img src="assets/icon.png" width="128" alt="BlitzTree icon">

# BlitzTree

A fast, native disk-space treemap for macOS, in the spirit of WizTree. It scans a whole Mac (3.6M files) in about 14 seconds.

<p>
  <img src="assets/screenshot.png" width="49%" alt="BlitzTree treemap view of /Applications">
  <img src="assets/screenshot-rings.png" width="49%" alt="BlitzTree rings view of /Applications">
</p>

## Install

**[Download BlitzTree.dmg](https://github.com/ahmedkhaleel2004/blitztree/releases/latest/download/BlitzTree.dmg)** and drag the app into Applications. Requires Apple Silicon and macOS 14 or later.

Signed with a Developer ID and notarized by Apple, so it opens like any other app. Grant Full Disk Access when prompted, then relaunch.

## Features

- Cushion-shaded treemap colored by file type, with a synced Finder-style outline list
- Prefer DaisyDisk? Switch to rings in the toolbar: click a folder to zoom in, the middle to go back
- Zoom into folders, or use the right-click menu across the outline list, treemap, and rings to reveal in Finder, copy path (⌥⌘C), move to Trash (⌘⌫, with confirmation), or choose "Ask Claude Code If It's Safe to Clean" (or your planner) to plan for that item alone
- Clean Up panel: finds folders that are safe to delete (caches, `node_modules`, Rust `target`, Xcode DerivedData and more) so you can trash them in one go
- AI cleanup: click "Clean up with Claude Code" (or Codex) and your own agent plans what can go, live in the panel, while the treemap lights up those folders. BlitzTree does the cleanup itself, in two steps you approve: move to Trash, then delete for good. No agent installed? One click sets up Claude Code (or Codex, free with a ChatGPT account)
- Or plan with [MANVI](https://github.com/bharathvbcr/Manvi) on the cloud (Claude through MANVI's `anthropic-account` launcher, which picks the Console account and its Keychain key so BlitzTree never holds it, with Claude models listed live; or a Gemini or xAI key your shell exports) or a local model (Ollama, LM Studio, vLLM…), or local first with the cloud as fallback: Settings → Model Providers. BlitzTree starts it read-only, in its strict posture
- Or clean up with any model: Settings → Model Providers connects any OpenAI- or Anthropic-compatible endpoint — a relay, a self-hosted server (Ollama, LM Studio) or a gateway — by its base URL, protocol and key
- English, Türkçe, Deutsch, Français, Español, 简体中文 and 日本語, picked in Settings; the agent prompt stays English while the UI follows you
- File → Export as CSV…: writes the folder on screen and everything in it (the whole scan, when you are at the top) as a CSV file: path, allocated size, logical size, file count, folder or not, and whether it was read in full. It streams to disk from the engine, shows progress with a Cancel button on a big export, and replaces the file only once it is whole; a cancel or an error leaves nothing behind. Replacing a file keeps its permissions (a 0600 file stays 0600) but, being a rename, not its ACLs, extended attributes or other hard links. The same writer is the CLI's `export-csv` command
- Live progress while scanning, and an optional free-space block
- Native AppKit/SwiftUI, with the Liquid Glass design on macOS 26 and later
- No telemetry. BlitzTree itself only goes online to check GitHub for updates once a day (installed when you quit); the AI cleanup only runs when you click it, using your own agent, which sends folder paths and sizes from the scan (never file contents) to Anthropic or OpenAI

## Performance

| Home folder, 3.1M entries (M4) | Time |
|---|---|
| **BlitzTree** | **10.2 s** |
| Parallel `readdir` + `lstat` | 14.4 s |
| `du -skx` | 65.3 s |

- `getattrlistbulk(2)` reads a whole directory's metadata in one syscall instead of one `stat` per file.
- A Rust worker pool keeps many directories in flight, and scan threads run at user-initiated QoS: they stay on performance cores without starving the UI.
- The treemap is laid out once and painted on every core in parallel, so zooming redraws in a couple of frames.

Method, full results and a comparison with other tools: [BENCHMARKS.md](BENCHMARKS.md).

## Accuracy

Sizes are allocated bytes, as `du` counts them, except that shared data counts once: hard links and whole APFS clones (`cp -c`, Chrome's code-signing clones) are charged to their first path and show 0 bytes elsewhere, where `du` would count every copy. A clone edited after copying still counts in full; if that makes the scan larger than the disk's used space, the status bar says by how much. The scan stays on one volume, and cloud-only iCloud folders are never downloaded. Root-only system data that no app can read is reported in the status bar instead of hidden.

## AI cleanup

The agent runs headless and read-only: it only writes a plan from the scan BlitzTree already has. BlitzTree then acts on it behind its own checks, whatever the plan says:

- Only paths inside your home folder, never Documents, Desktop, Photos, iCloud Drive, Mail, keychains or `~/.ssh` (build output such as `node_modules` inside them is allowed, and so are the Codex app's chat folders in `~/Documents/Codex`), never a git repository or a whole folder like `~/Library/Caches`. The one place outside the home: build output BlitzTree recognised inside a Claude Code session's temp scratchpad (`/private/tmp/claude-<uid>/…/scratchpad/…`), once that session has stopped
- Only each tool's own cache cleanup commands (`uv cache clean`, `brew cleanup`, `npm cache clean` and similar, plus `xcrun simctl` for Xcode simulator runtimes and device data), with no shell syntax
- Asking about a single item limits suggestions to that item: plan cards and commands outside the asked item are blocked
- Codex chats and projects you used in the last 2 days (including ones Claude Code worked in) are left alone
- Caches of apps that are open are skipped until you quit them
- "Delete for good" removes only what this cleanup moved to the Trash
- Every folder is checked by the rule that recognised it (a valid `CACHEDIR.TAG`, no recent activity, a clean unused git worktree…) at the moment it moves to the Trash, whoever asked for it: the panel, an agent's plan or any later caller. A folder inside a recognised one answers to that folder's check. A worktree with ignored files a build would not recreate (a `.env`, a local database) stays; an ignored folder counts as build output only where the engine would call it that (`node_modules` beside a `package.json`, `target` beside a `Cargo.toml`, `Pods` beside a `Podfile`, a `.venv` holding its `pyvenv.cfg`; never `.gradle`); so does a folder when the agents' session logs cannot be read, or another volume is mounted inside it
- Hidden folders in your home are not blanket-allowed: `~/.aws`, `~/.kube`, `~/.docker`, `~/.zshrc` and similar are never touched, and from `~/.claude`, `~/.codex`, `~/.gradle`, `~/.cargo`, `~/.m2`, `~/.ollama` and `~/.rustup` only the cache folders the scan recognises can go. Globally installed Node tools (`/opt/homebrew/lib/node_modules`, `/usr/local/lib/node_modules`, `~/.nvm/versions/node/*/lib/node_modules`) are never offered

Move to Trash in the treemap, outline and list menus is your own choice and works like Finder: it does not apply these checks. The confirmation does say so when Clean Up would have refused the item (a protected folder, a `.git` repository) and why, so the choice is informed.

## Trust & permissions

BlitzTree asks for Full Disk Access so the scan can read every folder on the
disk, including the system-protected ones that normally stay out of reach.
Everything it launches — the agent CLIs and each allowlisted cleanup command —
inherits that same grant while it runs. The agent CLIs' own sandbox settings
are a CLI-level policy, not an OS guarantee for anything they spawn.

Cleanup commands (`uv cache clean`, `brew cleanup` and so on) are resolved
through the shell's PATH, by design: these tools live in Homebrew, `~/.local/bin`,
nvm and other tool-manager locations, and BlitzTree does not guess where they
are installed. Only commands matching a small allowlist of tool-specific
cleanup invocations are ever run, but what runs is whatever the PATH resolves —
the trust in your own PATH is residual.

## Build from source

Requires Xcode 26 or later and Rust.

```sh
./build.sh              # build/BlitzTree.app
./deploy.sh             # build and install to /Applications
cargo test --release    # engine tests
```

The Rust engine hands the finished tree to the Swift UI as flat arrays over a C interface, with no copying. `BlitzTree <path>` scans a specific folder.

## JSON CLI for agents and scripts

An optional CLI uses the same scan engine without opening the GUI
or launching an AI agent:

```sh
cargo build --locked --release --features cli --bin blitztree
./target/release/blitztree scan --root "$HOME/Downloads"
./target/release/blitztree quick-wins --root "$HOME" --limit 20
./target/release/blitztree export-csv --root "$HOME/Downloads" --output downloads.csv
```

`scan` lists the largest directories and files as JSON. `quick-wins` includes
that inventory plus the Clean Up panel's existing candidates and labels. The
panel and CLI share one Rust implementation of the rules, with no new heuristics.
`export-csv` writes every scanned item to a CSV file, with the writer behind the
app's File → Export as CSV…, and reports what it wrote as JSON.
All report incomplete scans; allocated bytes are not
a promise of reclaimable space. None of them modifies the scanned files;
`export-csv` writes only the file named by `--output`.

The CLI is built from source separately from the app. Its JSON dependency is
only compiled with the `cli` feature. See [the CLI contract and tests](docs/AGENT_API.md).

## License

MIT
