# cli-anything-blitztree tests

## Plan

Unit tests in `tests/CLIAnythingChecks.swift` call `Harness.prepare`, `Harness.split` and `Harness.render` in process. They cover unknown commands, duplicate and misplaced flags, empty values, a value that starts with `-`, non-ASCII digits, limit and timeout bounds, quote splitting, and the engine argument vector for `scan`, `cleanup list` and `export csv`.

Subprocess tests launch the built `cli-anything-blitztree` binary:

- `--help` and a `--json` usage error
- a missing engine, including `BLITZTREE_BIN` set to a path that is not executable (no PATH fallback)
- a relative `PATH` entry that contains `blitztree`, which must be ignored
- an absolute `PATH` entry, which is used when nothing sits beside the front
- `blitztree-engine` beside the front, which wins over an absolute `PATH` entry
- a fake engine whose stdout is copied through unchanged, including a non-zero exit
- an engine that sleeps past `--timeout`
- session record, `session status` and `session clear`, including a refusal to follow a symlink file or a symlink session directory, and a session created under an ancestor symlink
- human-readable output containing the reported path
- a scripted REPL (`status`, then `exit`)

End to end, against the real `blitztree` binary built with `--features cli`:

- `scan` of a temporary directory that holds one file, with stdout compared byte for byte to that same engine invocation and the engine's argument vector checked
- `cleanup list` of a `node_modules` next to a `package.json`
- `export csv`, checking the CSV header and that the JSON names the same file

A harness failure must be a non-zero exit. A missing engine is not reported as an empty successful scan.

## Results

`zsh tests/run-cli-anything.sh` on 2026-10-28 exited 0. The release engine was already built (`Finished release profile` in 0.02s). The script printed:

```
scan: /var/folders/wl/qc_0nnp91cd5kfy179krkjxr0000gn/T/cli-anything-8A4C0C89-5BA2-499E-8E5B-06EF1A57A24F/real-home
csv: /var/folders/wl/qc_0nnp91cd5kfy179krkjxr0000gn/T/cli-anything-8A4C0C89-5BA2-499E-8E5B-06EF1A57A24F/out.csv (1326 bytes)
CLIAnythingChecks passed
```

The process exits on the first failed check, so that pass covers the plan above. The real `scan` stdout matched the engine's own stdout for the same invocation, and the engine's argument vector was `scan`, `--root`, the fixture path, `--min-bytes`, `1`, `--limit`, `20`. The CSV header check is `path,allocated_bytes,logical_bytes,file_count,is_folder,complete` followed by CR LF.
