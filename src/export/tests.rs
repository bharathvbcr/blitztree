use super::*;
use crate::{finish, scan, Progress};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::Arc;

// ---- an allocator that measures one thread's live heap ----

/// Counts the bytes the *calling thread* has allocated and not yet freed, and
/// the most it ever held at once, so a test can state how much memory an
/// export used without other tests' threads disturbing the figure.
struct Tracking;

thread_local! {
    static LIVE: Cell<usize> = const { Cell::new(0) };
    static PEAK: Cell<usize> = const { Cell::new(0) };
}

unsafe impl GlobalAlloc for Tracking {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(layout) };
        if !p.is_null() {
            let live = LIVE.with(|l| {
                l.set(l.get() + layout.size());
                l.get()
            });
            PEAK.with(|p| p.set(p.get().max(live)));
        }
        p
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.with(|l| l.set(l.get().saturating_sub(layout.size())));
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let p = unsafe { System.realloc(ptr, layout, new_size) };
        if !p.is_null() {
            let live = LIVE.with(|l| {
                l.set(l.get().saturating_sub(layout.size()) + new_size);
                l.get()
            });
            PEAK.with(|p| p.set(p.get().max(live)));
        }
        p
    }
}

#[global_allocator]
static ALLOCATOR: Tracking = Tracking;

/// Peak extra heap the calling thread held while `work` ran.
fn heap_peak_during<T>(work: impl FnOnce() -> T) -> (T, usize) {
    let base = LIVE.with(Cell::get);
    PEAK.with(|p| p.set(base));
    let out = work();
    (out, PEAK.with(Cell::get).saturating_sub(base))
}

// ---- a strict RFC 4180 reader: the oracle the writer is checked against ----

fn parse(csv: &[u8]) -> Vec<Vec<Vec<u8>>> {
    let (mut rows, mut row, mut field) = (Vec::new(), Vec::new(), Vec::new());
    let (mut quoted, mut i) = (false, 0);
    while i < csv.len() {
        let b = csv[i];
        if quoted {
            if b == b'"' {
                if csv.get(i + 1) == Some(&b'"') {
                    field.push(b'"');
                    i += 1;
                } else {
                    quoted = false;
                    assert!(
                        matches!(csv.get(i + 1), Some(b',' | b'\r') | None),
                        "text after a closing quote at byte {i}"
                    );
                }
            } else {
                field.push(b);
            }
        } else {
            match b {
                b'"' => {
                    assert!(
                        field.is_empty(),
                        "a quote inside an unquoted field at byte {i}"
                    );
                    quoted = true;
                }
                b',' => row.push(std::mem::take(&mut field)),
                b'\r' => {
                    assert_eq!(
                        csv.get(i + 1),
                        Some(&b'\n'),
                        "a bare CR outside quotes at byte {i}"
                    );
                    row.push(std::mem::take(&mut field));
                    rows.push(std::mem::take(&mut row));
                    i += 1;
                }
                b'\n' => panic!("a bare LF outside quotes at byte {i}"),
                _ => field.push(b),
            }
        }
        i += 1;
    }
    assert!(!quoted, "a quote was never closed");
    assert!(
        field.is_empty() && row.is_empty(),
        "the file does not end with CRLF"
    );
    rows
}

fn text(field: &[u8]) -> &str {
    std::str::from_utf8(field).unwrap()
}

fn csv_of(tree: &Tree, root: usize) -> Vec<u8> {
    let mut out = Vec::new();
    write_csv(tree, root, &mut out, &Control::new()).unwrap();
    out
}

fn field_of(raw: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    write_field(&mut out, raw).unwrap();
    out
}

// ---- trees ----

/// /r (dir) with: big/ (dir: a.bin 700, b.txt 300), small.txt 5, empty/ (dir)
fn sample() -> Tree {
    let mut t = Tree::with_root("/r");
    let big = t.push("big", 0, 0, 0, true);
    t.push("small.txt", 0, 5, 8, false);
    t.push("empty", 0, 0, 0, true);
    t.push("a.bin", big, 700, 700, false);
    t.push("b.txt", big, 300, 304, false);
    finish(&mut t);
    t
}

/// Every character a name can hold that a CSV reader could trip on.
const SPECIAL_NAMES: &[&str] = &[
    "plain",
    "with,comma",
    "with\"quote",
    "\"",
    "\"\"",
    ",",
    "line\nfeed",
    "carriage\rreturn",
    "crlf\r\nname",
    " leading space",
    "trailing space ",
    "  ",
    "in ner",
    "tab\tinside",
    "\ttab-first",
    "=1+1",
    "+cmd",
    "-2+3",
    "@SUM(A1)",
    "=HYPERLINK(\"http://x\",\"y\")",
    "emoji 😀🎉",
    "e\u{301} combining",
    "日本語 ñ ü",
    "ctl\u{1}\u{7}\u{1f}\u{7f}",
    "line\u{2028}sep",
    "'apostrophe'",
    "back\\slash",
    "semi;colon|pipe",
    ".hidden",
    "-",
];

fn special_tree() -> Tree {
    let mut t = Tree::with_root("/root with, \"specials\"");
    let dir = t.push("dir,with\"both\n", 0, 0, 0, true);
    // Each folder's children are one run, as the scan lays them out.
    for name in SPECIAL_NAMES {
        t.push(name, 0, 1, 1, false);
    }
    for (i, name) in SPECIAL_NAMES.iter().enumerate() {
        t.push(name, dir, 10 + i as u64, 16 + i as u64, false);
    }
    finish(&mut t);
    t
}

// ---- the quoting rules ----

#[test]
fn a_field_is_quoted_exactly_when_rfc_4180_needs_it() {
    let cases: &[(&str, &str)] = &[
        ("plain", "plain"),
        ("", ""),
        ("in ner space", "in ner space"),
        ("a,b", "\"a,b\""),
        ("say \"hi\"", "\"say \"\"hi\"\"\""),
        ("\"", "\"\"\"\""),
        ("a\nb", "\"a\nb\""),
        ("a\rb", "\"a\rb\""),
        ("a\r\nb", "\"a\r\nb\""),
        (" lead", "\" lead\""),
        ("trail ", "\"trail \""),
        (" ", "\" \""),
        ("emoji 😀", "emoji 😀"),
        ("tab\tinside", "tab\tinside"),
        ("ctl\u{1}", "ctl\u{1}"),
        ("/abs/=cmd", "/abs/=cmd"),
        ("/etc", "/etc"),
        // Neutralised only at the start of the cell.
        ("=1+1", "\"'=1+1\""),
        ("+1", "\"'+1\""),
        ("-1", "\"'-1\""),
        ("@x", "\"'@x\""),
        ("\tx", "\"'\tx\""),
        ("\rx", "\"'\rx\""),
        ("=a,\"b\"", "\"'=a,\"\"b\"\"\""),
    ];
    for (raw, want) in cases {
        assert_eq!(text(&field_of(raw.as_bytes())), *want, "field {raw:?}");
    }
}

#[test]
fn every_special_name_round_trips_through_a_strict_reader() {
    let tree = special_tree();
    let rows = parse(&csv_of(&tree, 0));
    assert_eq!(rows.len(), tree.len() + 1, "a header and one row per node");
    assert_eq!(
        rows[0].iter().map(|f| text(f)).collect::<Vec<_>>(),
        HEADER.trim_end().split(',').collect::<Vec<_>>()
    );
    // Pre-order: walk the tree the same way and compare field by field.
    let mut order = Vec::new();
    let mut stack = vec![0usize];
    while let Some(n) = stack.pop() {
        order.push(n);
        stack.extend(tree.kids(n).iter().rev().map(|&k| k as usize));
    }
    assert_eq!(order.len(), tree.len());
    for (row, &node) in rows[1..].iter().zip(&order) {
        assert_eq!(row.len(), 6, "{row:?}");
        assert_eq!(row[0], tree.path_bytes(node), "path of node {node}");
        assert_eq!(text(&row[1]), tree.alloc[node].to_string());
        assert_eq!(text(&row[2]), tree.logical[node].to_string());
        let files = if tree.is_dir(node) {
            tree.n_files[node]
        } else {
            1
        };
        assert_eq!(text(&row[3]), files.to_string());
        assert_eq!(text(&row[4]), tree.is_dir(node).to_string());
        assert_eq!(text(&row[5]), tree.complete[node].to_string());
    }
}

#[test]
fn rows_come_in_pre_order_largest_first_with_the_ui_counts() {
    let t = sample();
    let rows = parse(&csv_of(&t, 0));
    let got: Vec<Vec<&str>> = rows
        .iter()
        .map(|r| r.iter().map(|f| text(f)).collect())
        .collect();
    assert_eq!(
        got,
        [
            vec![
                "path",
                "allocated_bytes",
                "logical_bytes",
                "file_count",
                "is_folder",
                "complete"
            ],
            vec!["/r", "1012", "1005", "3", "true", "true"],
            vec!["/r/big", "1004", "1000", "2", "true", "true"],
            vec!["/r/big/a.bin", "700", "700", "1", "false", "true"],
            vec!["/r/big/b.txt", "304", "300", "1", "false", "true"],
            vec!["/r/small.txt", "8", "5", "1", "false", "true"],
            vec!["/r/empty", "0", "0", "0", "true", "true"],
        ]
    );
    assert_eq!(t.n_files[0], 3, "the root's count is the status bar's");
}

#[test]
fn the_file_is_crlf_terminated_utf8_without_a_bom() {
    let out = csv_of(&sample(), 0);
    assert!(out.starts_with(b"path,"), "no byte-order mark");
    assert!(out.ends_with(b"\r\n"));
    assert_eq!(
        out.iter().filter(|&&b| b == b'\n').count(),
        out.iter().filter(|&&b| b == b'\r').count()
    );
    assert!(std::str::from_utf8(&out).is_ok());
}

#[test]
fn a_folder_exports_its_own_subtree_under_its_full_path() {
    let t = sample();
    let rows = parse(&csv_of(&t, 1));
    let paths: Vec<&str> = rows[1..].iter().map(|r| text(&r[0])).collect();
    assert_eq!(paths, ["/r/big", "/r/big/a.bin", "/r/big/b.txt"]);
    // A file is a subtree of one.
    let rows = parse(&csv_of(&t, 5));
    assert_eq!(rows.len(), 2);
    assert_eq!(text(&rows[1][0]), "/r/big/b.txt");
    assert_eq!(text(&rows[1][4]), "false");
    // An empty folder: itself only.
    assert_eq!(parse(&csv_of(&t, 3)).len(), 2);
}

#[test]
fn a_root_alone_is_a_header_and_one_row_and_no_tree_is_refused() {
    let t = Tree::with_root("/only");
    let mut t = t;
    finish(&mut t);
    let rows = parse(&csv_of(&t, 0));
    assert_eq!(rows.len(), 2);
    assert_eq!(text(&rows[1][0]), "/only");
    assert_eq!(text(&rows[1][3]), "0");

    let empty = Tree::default();
    let mut out = Vec::new();
    assert!(matches!(
        write_csv(&empty, 0, &mut out, &Control::new()),
        Err(Error::Invalid(_))
    ));
    assert!(
        out.is_empty(),
        "nothing is written for a request that is refused"
    );
    assert!(matches!(
        write_csv(&t, 1, &mut out, &Control::new()),
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        write_csv(&t, usize::MAX, &mut out, &Control::new()),
        Err(Error::Invalid(_))
    ));
    assert!(out.is_empty());
    // Not yet `finish`ed: no child lists to walk.
    let mut raw = Tree::with_root("/raw");
    raw.push("a", 0, 1, 1, false);
    assert!(matches!(
        write_csv(&raw, 0, &mut out, &Control::new()),
        Err(Error::Invalid(_))
    ));
    assert!(out.is_empty());
}

#[test]
fn a_path_of_over_4096_bytes_survives() {
    let mut t = Tree::with_root("/deep");
    let name = "n".repeat(255);
    let mut parent = 0;
    for _ in 0..17 {
        parent = t.push(&name, parent, 0, 0, true);
    }
    t.push("leaf", parent, 1, 1, false);
    finish(&mut t);
    let leaf = t.len() - 1;
    let want = t.path_bytes(leaf);
    assert!(want.len() > 4096, "{} bytes", want.len());
    let rows = parse(&csv_of(&t, 0));
    assert_eq!(rows.len(), t.len() + 1);
    assert_eq!(rows.last().unwrap()[0], want);
    // The same through the shared path builder.
    assert_eq!(t.path(leaf).as_os_str().as_bytes(), &want[..]);
}

#[test]
fn name_bytes_that_are_not_utf8_are_written_unchanged_and_no_row_is_dropped() {
    // The scan never produces these (it drops such an entry and counts it in
    // `invalid_names`), but a tree built another way must not lose rows.
    let mut t = Tree::with_root("/raw");
    for bytes in [
        &b"ok"[..],
        b"bad\xff\xfe",
        b"\xc3(",
        b"\xed\xa0\x80",
        b"\xf0\x28\x8c\xbc",
    ] {
        t.parents.push(0);
        t.logical.push(1);
        t.alloc.push(1);
        t.flags.push(0);
        t.complete.push(true);
        t.name_blob.extend_from_slice(bytes);
        t.name_off.push(t.name_blob.len() as u32);
    }
    finish(&mut t);
    let out = csv_of(&t, 0);
    let rows = parse(&out);
    assert_eq!(rows.len(), t.len() + 1, "every node has its row");
    let mut seen: Vec<Vec<u8>> = rows[2..].iter().map(|r| r[0].clone()).collect();
    seen.sort();
    let mut want: Vec<Vec<u8>> = vec![
        b"/raw/ok".to_vec(),
        b"/raw/bad\xff\xfe".to_vec(),
        b"/raw/\xc3(".to_vec(),
        b"/raw/\xed\xa0\x80".to_vec(),
        b"/raw/\xf0\x28\x8c\xbc".to_vec(),
    ];
    want.sort();
    assert_eq!(seen, want, "the bytes are the tree's, not replacements");
    assert!(
        !out.windows(3).any(|w| w == "\u{fffd}".as_bytes()),
        "no replacement character"
    );
}

#[test]
fn a_relative_root_that_looks_like_a_formula_is_neutralised_and_names_cannot_be() {
    let mut t = Tree::with_root("=cmd|' /C calc'!A0");
    t.push("=child", 0, 1, 1, false);
    finish(&mut t);
    let rows = parse(&csv_of(&t, 0));
    assert_eq!(text(&rows[1][0]), "'=cmd|' /C calc'!A0");
    assert_eq!(
        text(&rows[2][0]),
        "'=cmd|' /C calc'!A0/=child",
        "the child's cell starts with the root too"
    );
    let mut t = Tree::with_root("rel");
    t.push("=child", 0, 1, 1, false);
    finish(&mut t);
    assert_eq!(
        text(&parse(&csv_of(&t, 0))[2][0]),
        "rel/=child",
        "only a cell's first byte matters"
    );

    // With the absolute root every scan has, no row's cell can begin with a trigger.
    let tree = special_tree();
    for row in &parse(&csv_of(&tree, 0))[1..] {
        assert!(row[0].starts_with(b"/"), "{:?}", text(&row[0]));
    }
}

#[test]
fn path_bytes_matches_the_path_buffer_for_every_node() {
    let tree = special_tree();
    let out = csv_of(&tree, 0);
    let rows = parse(&out);
    let mut paths: Vec<_> = rows[1..].iter().map(|r| r[0].clone()).collect();
    let mut want: Vec<_> = (0..tree.len())
        .map(|i| tree.path(i).as_os_str().as_bytes().to_vec())
        .collect();
    paths.sort();
    want.sort();
    assert_eq!(paths, want);
    // The slash handling of `PathBuf::push`, which `join_name` copies.
    for root in ["/", "/a/", "a", "", "/a//"] {
        let mut t = Tree::with_root(root);
        t.push("x", 0, 0, 0, false);
        finish(&mut t);
        let want = {
            let mut p = PathBuf::from(root);
            p.push("x");
            p
        };
        assert_eq!(t.path(1), want, "root {root:?}");
        assert_eq!(
            t.path_bytes(1),
            want.as_os_str().as_bytes(),
            "root {root:?}"
        );
    }
}

// ---- the real scan: links, hard links, symlinks ----

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("bz-export-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn leftovers(dir: &Path) -> Vec<String> {
    std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with(".blitztree-export-"))
        .collect()
}

#[test]
fn a_scan_of_links_and_odd_names_exports_what_the_window_shows() {
    let root = scratch("scan");
    let data = root.join("data");
    std::fs::create_dir_all(data.join("sub dir")).unwrap();
    std::fs::write(data.join("a,\"b\".txt"), vec![1u8; 10_000]).unwrap();
    std::fs::write(data.join("multi\nline\r\nname"), vec![2u8; 5_000]).unwrap();
    std::fs::write(data.join(" padded "), b"x").unwrap();
    std::fs::write(data.join("sub dir/inner"), vec![3u8; 4_000]).unwrap();
    std::fs::hard_link(data.join("sub dir/inner"), data.join("link-to-inner")).unwrap();
    std::os::unix::fs::symlink(data.join("sub dir"), data.join("dir-link")).unwrap();
    std::os::unix::fs::symlink("/nonexistent", data.join("broken")).unwrap();

    let tree = scan(&data, &Progress::default());
    let rows = parse(&csv_of(&tree, 0));
    assert_eq!(rows.len(), tree.len() + 1);
    let by_path: std::collections::HashMap<Vec<u8>, &Vec<Vec<u8>>> =
        rows[1..].iter().map(|r| (r[0].clone(), r)).collect();
    let row = |rel: &str| -> &Vec<Vec<u8>> {
        let mut p = data.as_os_str().as_bytes().to_vec();
        p.push(b'/');
        p.extend_from_slice(rel.as_bytes());
        by_path
            .get(&p)
            .unwrap_or_else(|| panic!("no row for {rel:?}"))
    };
    assert_eq!(text(&rows[1][0]), data.to_str().unwrap());
    for name in ["a,\"b\".txt", "multi\nline\r\nname", " padded "] {
        assert_eq!(text(&row(name)[4]), "false", "{name:?}");
    }
    assert_eq!(text(&row("multi\nline\r\nname")[2]), "5000");
    // A link to a folder is a file-like row of its own, not a second copy of the folder.
    assert_eq!(text(&row("dir-link")[4]), "false");
    assert!(
        !by_path.keys().any(|p| p.ends_with(b"dir-link/inner")),
        "a symlink is not followed"
    );
    assert_eq!(text(&row("broken")[4]), "false");
    // The inode's data counts once, on the first path; both names count as files.
    let (a, b) = (row("link-to-inner"), row("sub dir/inner"));
    assert_eq!(
        text(&a[2]),
        "4000",
        "link-to-inner sorts first and owns the bytes"
    );
    assert_eq!((text(&b[1]), text(&b[2])), ("0", "0"));
    assert_eq!((text(&a[3]), text(&b[3])), ("1", "1"));
    assert_eq!(text(&row("sub dir")[3]), "1");
    let files: u32 = tree.n_files[0];
    assert_eq!(text(&rows[1][3]), files.to_string());
    assert_eq!(files, 7, "3 plain + 2 hard-link names + 2 symlinks");
    let _ = std::fs::remove_dir_all(&root);
}

// ---- memory ----

#[test]
fn a_million_row_export_holds_constant_memory() {
    // 1,001,001 nodes: a root, 1,000 folders of 1,000 files.
    let mut t = Tree::with_root("/synthetic/volume");
    let mut dirs = Vec::new();
    for d in 0..1000 {
        dirs.push(t.push(&format!("folder-{d:04}"), 0, 0, 0, true));
    }
    for &d in &dirs {
        for f in 0..1000u64 {
            t.push(&format!("file-{f:04}.dat"), d, 1000 + f, 4096, false);
        }
    }
    finish(&mut t);
    assert_eq!(t.len(), 1_001_001);

    // The meter itself: it sees a megabyte, and sees a CSV built in memory.
    assert!(heap_peak_during(|| vec![1u8; 1 << 20].len()).1 >= 1 << 20);
    let (whole, in_memory) = heap_peak_during(|| csv_of(&t, dirs[0] as usize).len());
    assert!(in_memory >= whole, "{in_memory} < {whole}");

    let mut sink = Counting {
        inner: BufWriter::with_capacity(BUFFER, io::sink()),
        bytes: 0,
    };
    let (rows, peak) = heap_peak_during(|| write_csv(&t, 0, &mut sink, &Control::new()).unwrap());
    assert_eq!(rows, 1_001_001);
    // The file is 60+ MB; the walk may hold only the write buffer, the path
    // buffer and the (shallow) frame stack, not anything that grows with rows.
    assert!(sink.bytes > 60_000_000, "{} bytes of CSV", sink.bytes);
    assert!(
        peak < 64 * 1024,
        "peak heap {peak} bytes for {} bytes of CSV",
        sink.bytes
    );
    eprintln!(
        "1,001,001 rows, {} CSV bytes, peak extra heap {} bytes",
        sink.bytes, peak
    );
}

// ---- stopping ----

fn stop_after(ctl: &Control, rows: u64) {
    *ctl.row_hook.lock().unwrap() = Some(Box::new(move |done, ctl| {
        if done == rows {
            ctl.cancel();
        }
    }));
}

#[test]
fn a_cancel_at_start_middle_and_end_leaves_no_file_and_no_temporary() {
    let root = scratch("cancel");
    let tree = special_tree();
    let total = tree.len() as u64;
    let dest = root.join("out.csv");
    for (label, after) in [
        ("0%", 0),
        ("1 row", 1),
        ("50%", total / 2),
        ("last row", total),
    ] {
        let ctl = Control::new();
        if after == 0 {
            ctl.cancel();
        } else {
            stop_after(&ctl, after);
        }
        let err = export_file(&tree, 0, &dest, &ctl).unwrap_err();
        assert!(matches!(err, Error::Cancelled), "{label}: {err}");
        assert!(!dest.exists(), "{label}: a cancelled export leaves no file");
        assert!(
            leftovers(&root).is_empty(),
            "{label}: {:?}",
            leftovers(&root)
        );
    }
    // Too late to cancel once the file is in place.
    let ctl = Control::new();
    let summary = export_file(&tree, 0, &dest, &ctl).unwrap();
    ctl.cancel();
    assert_eq!(summary.rows, total);
    assert_eq!(
        parse(&std::fs::read(&dest).unwrap()).len() as u64,
        total + 1
    );
    assert_eq!(summary.bytes, std::fs::metadata(&dest).unwrap().len());
    assert_eq!((ctl.rows_done(), ctl.rows_total()), (total, total));
    assert!(leftovers(&root).is_empty());
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_cancelled_replacement_keeps_the_file_that_was_there() {
    let root = scratch("keep");
    let dest = root.join("out.csv");
    std::fs::write(&dest, b"precious").unwrap();
    let tree = sample();
    let ctl = Control::new();
    stop_after(&ctl, 2);
    assert!(matches!(
        export_file(&tree, 0, &dest, &ctl),
        Err(Error::Cancelled)
    ));
    assert_eq!(std::fs::read(&dest).unwrap(), b"precious");
    assert!(leftovers(&root).is_empty());
    // And an export that completes replaces it.
    export_file(&tree, 0, &dest, &Control::new()).unwrap();
    assert!(std::fs::read(&dest).unwrap().starts_with(b"path,"));
    let _ = std::fs::remove_dir_all(&root);
}

// ---- failing ----

#[test]
fn errors_are_reported_and_leave_nothing_behind() {
    let root = scratch("errors");
    let tree = sample();

    // The destination is a folder.
    let folder = root.join("folder.csv");
    std::fs::create_dir(&folder).unwrap();
    let err = export_file(&tree, 0, &folder, &Control::new()).unwrap_err();
    assert!(
        matches!(err, Error::Invalid(_)) && err.to_string().contains("is a folder"),
        "{err}"
    );
    assert!(folder.is_dir());

    // No name, trailing slash.
    for bad in [Path::new("/"), Path::new(""), &root.join("sub/")] {
        assert!(
            matches!(
                export_file(&tree, 0, bad, &Control::new()),
                Err(Error::Invalid(_))
            ),
            "{bad:?}"
        );
    }

    // The folder is not there.
    let err = export_file(&tree, 0, &root.join("missing/out.csv"), &Control::new()).unwrap_err();
    match &err {
        Error::Io { source, .. } => assert_eq!(source.kind(), io::ErrorKind::NotFound),
        other => panic!("{other}"),
    }
    assert!(!err.to_string().is_empty());

    // The folder is read-only (skipped for root, which may write anywhere).
    if unsafe { libc::geteuid() } != 0 {
        use std::os::unix::fs::PermissionsExt;
        let locked = root.join("locked");
        std::fs::create_dir(&locked).unwrap();
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o555)).unwrap();
        let err = export_file(&tree, 0, &locked.join("out.csv"), &Control::new()).unwrap_err();
        match &err {
            Error::Io { source, .. } => assert_eq!(source.kind(), io::ErrorKind::PermissionDenied),
            other => panic!("{other}"),
        }
        assert!(err.to_string().contains("Permission denied"), "{err}");
        assert!(leftovers(&locked).is_empty());
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    // The folder disappears while the file is being written: the rename fails.
    let doomed = root.join("doomed");
    std::fs::create_dir(&doomed).unwrap();
    let ctl = Control::new();
    let doomed_path = doomed.clone();
    *ctl.row_hook.lock().unwrap() = Some(Box::new(move |done, _| {
        if done == 2 {
            std::fs::remove_dir_all(&doomed_path).unwrap();
        }
    }));
    let err = export_file(&tree, 0, &doomed.join("out.csv"), &ctl).unwrap_err();
    assert!(matches!(&err, Error::Io { .. }), "{err}");
    assert!(err.to_string().contains("Could not save"), "{err}");
    assert!(!doomed.exists());
    let _ = std::fs::remove_dir_all(&root);
}

/// Accepts `limit` bytes, then fails like a full disk.
struct Full {
    limit: usize,
    taken: usize,
}

impl Write for Full {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.taken >= self.limit {
            return Err(io::Error::from_raw_os_error(libc::ENOSPC));
        }
        let n = buf.len().min(self.limit - self.taken);
        self.taken += n;
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn a_full_disk_is_an_error_not_a_short_file() {
    let tree = special_tree();
    for limit in [0, 10, 200, 1000] {
        let mut out = BufWriter::with_capacity(64, Full { limit, taken: 0 });
        let err = write_csv(&tree, 0, &mut out, &Control::new()).and_then(|rows| {
            out.flush().map_err(|e| Error::Io {
                what: "flush".into(),
                source: e,
            })?;
            Ok(rows)
        });
        match err {
            Err(Error::Io { source, .. }) => {
                assert_eq!(source.raw_os_error(), Some(libc::ENOSPC), "limit {limit}")
            }
            other => panic!("limit {limit}: {other:?}"),
        }
    }
}

// ---- several at once ----

#[test]
fn exports_running_together_each_write_a_whole_file() {
    let root = scratch("together");
    let tree = Arc::new(special_tree());
    let want = csv_of(&tree, 0);
    let to_same = root.join("shared.csv");
    let handles: Vec<_> = (0..8)
        .map(|k| {
            let (tree, root, to_same) = (tree.clone(), root.clone(), to_same.clone());
            std::thread::spawn(move || {
                // Half to their own file, half racing for one name.
                let dest = if k % 2 == 0 {
                    root.join(format!("own-{k}.csv"))
                } else {
                    to_same
                };
                for _ in 0..10 {
                    export_file(&tree, 0, &dest, &Control::new()).unwrap();
                }
            })
        })
        .collect();
    for h in handles {
        h.join().unwrap();
    }
    for name in [
        "own-0.csv",
        "own-2.csv",
        "own-4.csv",
        "own-6.csv",
        "shared.csv",
    ] {
        assert_eq!(std::fs::read(root.join(name)).unwrap(), want, "{name}");
    }
    assert!(leftovers(&root).is_empty(), "{:?}", leftovers(&root));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn exporting_over_a_file_the_scan_listed_replaces_it() {
    let root = scratch("overwrite");
    std::fs::write(root.join("victim.csv"), vec![0u8; 100]).unwrap();
    std::fs::write(root.join("other"), b"x").unwrap();
    let tree = scan(&root, &Progress::default());
    export_file(&tree, 0, &root.join("victim.csv"), &Control::new()).unwrap();
    let rows = parse(&std::fs::read(root.join("victim.csv")).unwrap());
    assert_eq!(rows.len(), tree.len() + 1);
    assert!(
        rows.iter().any(|r| r[0].ends_with(b"/victim.csv")),
        "the old listing, with the old size"
    );
    // A link at the destination is replaced, not written through.
    let target = root.join("target-of-link");
    std::fs::write(&target, b"untouched").unwrap();
    let link = root.join("link.csv");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    export_file(&tree, 0, &link, &Control::new()).unwrap();
    assert_eq!(std::fs::read(&target).unwrap(), b"untouched");
    assert!(std::fs::read(&link).unwrap().starts_with(b"path,"));
    assert!(!std::fs::symlink_metadata(&link)
        .unwrap()
        .file_type()
        .is_symlink());
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn progress_counts_the_rows_of_the_chosen_folder() {
    let t = sample();
    let ctl = Control::new();
    write_csv(&t, 1, &mut Vec::new(), &ctl).unwrap();
    assert_eq!((ctl.rows_done(), ctl.rows_total()), (3, 3));
    write_csv(&t, 0, &mut Vec::new(), &ctl).unwrap();
    assert_eq!((ctl.rows_done(), ctl.rows_total()), (6, 6));
}

#[test]
fn a_tree_that_lists_a_node_twice_is_refused_not_looped_over() {
    let mut t = sample();
    // Point a child list back at the root: a cycle the engine cannot build.
    t.children[0] = 0;
    let mut out = Vec::new();
    let err = write_csv(&t, 0, &mut out, &Control::new()).unwrap_err();
    assert!(matches!(err, Error::Invalid(_)), "{err}");
}

#[test]
fn replacing_a_file_keeps_its_permissions_and_a_new_file_gets_the_umask_mode() {
    use std::os::unix::fs::PermissionsExt;
    let root = scratch("mode");
    let tree = sample();
    let mode_of = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    for mode in [0o600, 0o640, 0o444, 0o755] {
        let dest = root.join(format!("m{mode:o}.csv"));
        std::fs::write(&dest, b"old").unwrap();
        std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(mode)).unwrap();
        export_file(&tree, 0, &dest, &Control::new()).unwrap();
        assert_eq!(mode_of(&dest), mode, "a {mode:o} file stays {mode:o}");
        assert!(std::fs::read(&dest).unwrap().starts_with(b"path,"));
    }
    // A cancelled replacement leaves both content and mode.
    let kept = root.join("kept.csv");
    std::fs::write(&kept, b"old").unwrap();
    std::fs::set_permissions(&kept, std::fs::Permissions::from_mode(0o600)).unwrap();
    let ctl = Control::new();
    stop_after(&ctl, 2);
    assert!(export_file(&tree, 0, &kept, &ctl).is_err());
    assert_eq!(
        (std::fs::read(&kept).unwrap(), mode_of(&kept)),
        (b"old".to_vec(), 0o600)
    );
    // Nothing there: the mode a plain new file gets. A link is replaced by a file, not followed.
    let fresh = root.join("fresh.csv");
    let plain = root.join("plain");
    std::fs::write(&plain, b"").unwrap();
    export_file(&tree, 0, &fresh, &Control::new()).unwrap();
    assert_eq!(mode_of(&fresh), mode_of(&plain));
    let target = root.join("target");
    std::fs::write(&target, b"t").unwrap();
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600)).unwrap();
    let link = root.join("link.csv");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    export_file(&tree, 0, &link, &Control::new()).unwrap();
    assert_eq!(
        mode_of(&link),
        mode_of(&plain),
        "the link's target does not lend its mode"
    );
    assert_eq!(mode_of(&target), 0o600);
    let _ = std::fs::remove_dir_all(&root);
}
