# Clone accounting: correctness and cost

M4 MacBook (10 cores), macOS 27.0, APFS data volume of 994.6 GB (852.5 GB in
use per `diskutil apfs list`), measured 2026-10-06 from a terminal session.
Other agent sessions kept the load average at 15–25 throughout, so the timings
below are noisy; their spread is shown rather than hidden.

## Correctness on the reporting machine

`blitztree scan --root /System/Volumes/Data` with the 0.6.0 engine and with
clone accounting (the terminal lacks Full Disk Access, so ~230 folders were
unreadable in both runs):

| | 0.6.0 | clone accounting |
|---|---|---|
| allocated, whole data volume | 1,609.5 GB | 815.7 GB |
| `/private` | 788.8 GB | 18.6 GB |
| `…/X/com.google.Chrome.code_sign_clone` (510 clones of Chrome) | 767.1 GB | 0.76 GB (2.26 GB scanned on its own, when `/Applications` is not there to own the current version) |
| `/Users` | 755.3 GB | 732.0 GB |
| `coverage.shared_allocated_bytes` | — | 869.3 GB |

Probed with `getattrlist`: the 518 MB `Google Chrome Framework` binary in a
`code_sign_clone.*` folder shares its clone id with the one in
`/Applications/Google Chrome.app` (clone refcount 419), the copy of the
previous version shares one with 511 others whose source is gone, and
`ATTR_CMNEXT_PRIVATESIZE` is 0 for both.

## Cost of reading clone ids

The engine now asks `getattrlistbulk` for `ATTR_CMNEXT_CLONEID` and
`ATTR_CMNEXT_EXT_FLAGS`. Three release `bench bulk` binaries, run in rotating
order, 9 rounds after a warm-up: 0.6.0 (`baseline`), 0.6.0 plus the two
attributes requested but unused (`attrsonly`), and the change (`candidate`).

| target | baseline min / median | attrsonly min / median | candidate min / median |
|---|---|---|---|
| `/Applications` (502,516 files) | 0.865 / 0.974 s | 0.989 / 1.013 s | 0.998 / 1.011 s |
| `/opt` (583,182 files) | 1.274 / 1.321 s | 1.273 / 1.297 s | 1.274 / 1.291 s |

Home folder (4.15M files, still being written to by other sessions),
`benchmarks/scan.py --mode bulk --runs 5`: baseline median 16.66 s (13.63–18.28),
candidate 18.53 s (16.09–21.27). `scan.py` exits non-zero there because the
totals differ by design (clones are no longer counted twice).

Reading the two attributes costs between nothing (`/opt`) and about 4% of
median scan time (`/Applications`); the accounting itself adds nothing
measurable over `attrsonly`. The home-folder pairs overlap heavily under
this load and do not separate the builds.

## Randomized stress against a model

`python3 tests/stress_clones.py` builds a disk image per file system, applies
a random mix of files, sparse files, hard links, file and folder clones,
edits, moves and deletes, and checks the scan against a model of which paths
share data, exactly, plus five repeated scans for identical digests.

| file system | seeds × ops | result |
|---|---|---|
| APFS, with edits | 5 × 400 | 5/5 exact |
| case-sensitive APFS, with edits | 5 × 400 | 5/5 exact |
| APFS, no edits (`--no-edits`) | 5 × 400 | 5/5 exact; scan 0.2–0.4 MB under volume used |
| case-sensitive APFS, no edits | 5 × 400 | 5/5 exact; scan 0.2–0.4 MB under volume used |
| HFS+ | 3 × 300 | 3/3 exact (no clone ids; hard links once) |
| exFAT | 3 × 300 | 3/3 exact |
| FAT32 | 3 × 300 | 3/3 exact (0.6.0: every file 0 bytes allocated) |

With edits, scans of the APFS images exceed volume used by up to 25%: edited
clones still share most blocks but carry their own clone id, and the model
counts them in full as the engine does.
