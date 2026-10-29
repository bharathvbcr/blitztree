---
name: "cli-anything-blitztree"
description: "Read a macOS folder's disk usage and Clean Up candidates through the BlitzTree engine. Use for scan, quick-wins, and CSV export. The CLI does not delete files."
---

# cli-anything-blitztree

Agent CLI for BlitzTree, a macOS disk-space treemap. `scan` and `cleanup list` only read filesystem metadata. `export csv` writes the one file named by `--output`. Nothing here deletes files or reads regular file contents.

The Swift CLI is a command-group front. Every scan, candidate list and CSV file is produced by the real `blitztree` engine (the same rules as the Clean Up panel). `./build.sh` installs both at `BlitzTree.app/Contents/MacOS/`. The bundled engine is `blitztree-engine` (the name `blitztree` would replace the GUI executable `BlitzTree` on a case-insensitive volume). The front uses `BLITZTREE_BIN` when that is set, then `blitztree-engine` beside itself, then an absolute `PATH` entry named `blitztree`. A relative `PATH` entry is ignored.

A development build:

```sh
cargo install --locked --path . --features cli --bin blitztree
zsh cli/build.sh
./build/cli-anything-blitztree --help
```

## Commands

Global flags, accepted before or after the command: `--json`, `--session FILE`, `--timeout SECONDS` (1…86400, default 21600).

| Command | Engine command | Effect |
|---|---|---|
| `scan [--root PATH] [--min-bytes N] [--limit N]` | `blitztree scan` | Largest children, directories and files. Read-only. |
| `cleanup list [--root PATH] [--min-bytes N] [--limit N]` | `blitztree quick-wins` | Clean Up panel candidates plus that inventory. Read-only. Not permission to delete. |
| `export csv --output FILE [--root PATH]` | `blitztree export-csv` | RFC 4180 CSV of the scan. Writes only `FILE`. |
| `status`, `session status` | — | Last successful root, from the session file. |
| `session clear` | — | Remove the session file. |
| `repl` | — | Interactive default when no command is given. `exit` leaves. |

`--limit` is 1…1000 (engine default 20). `--min-bytes` is an unsigned integer (engine default 50000000). Default `--root` is `$HOME`.

## JSON

`--json` copies the engine's stdout through, one JSON object and a newline. It does not parse and re-encode a successful report. A newline is added only when the engine omitted one. The contract is schema version 1, documented in `docs/AGENT_API.md`. Read `coverage.complete` before trusting totals. `reclaimable_bytes` is null. A non-null `verify` is a check this report did not run. A value that starts with `-` is rejected. `--limit`, `--min-bytes` and `--timeout` accept only ASCII digits.

Harness errors (bad arguments, missing engine, timeout) are a different object, on stdout when `--json` is set, and the process exits with `error.exit_code`:

```json
{"schema_version":1,"tool":"cli-anything-blitztree","error":{"message":"...","exit_code":2}}
```

Exit codes follow the engine: 0 report, 1 I/O or a harness failure to start the engine, 2 bad arguments.

Without `--json`, the same object is printed as a short table. Do not parse the table. Use `--json`.

## Session

A successful engine command records `root`, `command`, `read_only` and `generated_at_unix` in the session file (default `$HOME/.blitztree/cli-anything-session.json`, mode 0600). The file is locked while it is written. A symlink at that path, or at the directory that contains it, is refused. The session is a bookmark of the last root, not a scan you can undo. The Clean Up planner inside the app does not call this CLI. It is given the scan the window already finished.

## Examples

```sh
cli-anything-blitztree --json scan --root "$HOME/Downloads" --min-bytes 104857600 --limit 20
cli-anything-blitztree --json cleanup list --root "$HOME" --limit 30
cli-anything-blitztree --json export csv --root "$HOME/Downloads" --output downloads.csv
cli-anything-blitztree --json status
```

There is no preview command. BlitzTree's picture of a folder is the app window, and this CLI does not screen-scrape it. There is no delete, trash, or clean command on purpose.
