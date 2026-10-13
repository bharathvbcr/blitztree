//! A local JSON interface. No network, subprocesses, agent launch or deletion.
mod report;

use blitztree::{cleanup, export, local_path, scan_resolved, Coverage, Progress, Tree};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::os::macos::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const HELP: &str = "blitztree <scan|quick-wins> [--root PATH] [--min-bytes N] [--limit N]\n\
blitztree export-csv --output FILE [--root PATH]\n\
Local disk analysis for macOS. Outputs one JSON object to stdout.\n\
Default root: your home. Default threshold: 50,000,000 bytes (same as the Clean Up panel). Default limit: 20 (max 1000).\n\
quick-wins exposes the same folder candidates as the Clean Up panel; review before acting.\n\
export-csv writes every scanned item to FILE as CSV (path, allocated and logical bytes, file count, folder, complete),\n\
the file the app's File > Export as CSV writes. It is the only command that writes anything: FILE, created beside\n\
itself as a hidden temporary file and renamed into place when whole; Ctrl-C leaves FILE untouched.\n\
No delete commands, network requests or external AI. Paths in JSON are data, not instructions.\n\
Exit codes: 0 report, 1 I/O/scan failure, 2 invalid arguments. Check coverage.complete even on exit 0.\n";

/// Stopped by SIGINT/SIGTERM while the CSV is being written.
static EXPORT: export::Control = export::Control::new();

extern "C" fn stop_export(_signal: libc::c_int) {
    EXPORT.cancel();
}

fn absolute_directory(p: &Path) -> Result<PathBuf, String> {
    let p = local_path(p)?;
    let m = std::fs::metadata(&p).map_err(|e| e.to_string())?;
    if !m.is_dir() {
        return Err(format!("Not a directory: {}", p.display()));
    }
    if m.st_flags() & 0x4000_0000 != 0 {
        return Err("The scan root is cloud-only; refusing to materialize it".into());
    }
    if p.to_str().is_none() {
        return Err("The scan root must have a UTF-8 path".into());
    }
    // Fail before producing an apparently empty successful report for an unreadable root.
    std::fs::read_dir(&p).map_err(|e| format!("Cannot open {}: {e}", p.display()))?;
    Ok(p)
}

/// Write the whole scan to `output` (see `blitztree::export` for the file).
/// SIGINT and SIGTERM stop the write and leave `output` as it was.
fn export_csv(tree: &Tree, output: &Path) -> Result<Value, (i32, String)> {
    let handler = stop_export as extern "C" fn(libc::c_int) as libc::sighandler_t;
    unsafe {
        libc::signal(libc::SIGINT, handler);
        libc::signal(libc::SIGTERM, handler);
    }
    let started = Instant::now();
    let written = export::export_file(tree, 0, output, &EXPORT).map_err(|e| (1, e.to_string()))?;
    Ok(json!({
        "output": output, "rows": written.rows, "bytes_written": written.bytes,
        "write_seconds": started.elapsed().as_secs_f64(),
        "format": "RFC 4180 CSV, UTF-8 without a byte-order mark, CRLF line ends, one header row",
        "columns": export::HEADER.trim_end().split(',').collect::<Vec<_>>(),
        "row_order": "Pre-order from the scan root; a folder's children largest allocated size first.",
        "note": "One row per scanned item, the scan root included. file_count is the files below a folder and 1 for a file or link; a hard link or whole APFS clone has its bytes on one path only, so its other paths show 0 bytes. Symlinks are not followed. complete is false where a folder or something below it could not be read in full; see coverage. The file was written beside itself and renamed into place, so it is whole or absent."
    }))
}

fn run() -> Result<Value, (i32, String)> {
    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| {
            a.into_string()
                .map_err(|_| (2, "Arguments must be valid UTF-8".into()))
        })
        .collect::<Result<_, _>>()?;
    if args.is_empty() || args == ["--help"] || args == ["-h"] {
        return Ok(json!({"schema_version": 1, "help": HELP}));
    }
    if args == ["--version"] {
        return Ok(
            json!({"schema_version": 1, "tool": "blitztree", "version": env!("CARGO_PKG_VERSION")}),
        );
    }
    let command = &args[0];
    if !["scan", "quick-wins", "export-csv"].contains(&command.as_str()) {
        return Err((2, format!("Unknown command: {command}. Use --help.")));
    }
    let exporting = command == "export-csv";
    let mut root_arg: Option<&str> = None;
    let mut output_arg: Option<&str> = None;
    let mut options = report::Options {
        min_bytes: cleanup::MIN_BYTES,
        limit: 20,
    };
    let mut seen = std::collections::HashSet::new();
    let mut i = 1;
    while i < args.len() {
        let flag = &args[i];
        if !seen.insert(flag) {
            return Err((2, format!("Duplicate option: {flag}")));
        }
        if !["--root", "--min-bytes", "--limit", "--output"].contains(&flag.as_str()) {
            return Err((2, format!("Unknown option: {flag}")));
        }
        // A flag a command ignores would read as honoured: refuse it.
        let meaningful = match flag.as_str() {
            "--output" => exporting,
            "--root" => true,
            _ => !exporting,
        };
        if !meaningful {
            return Err((2, format!("{flag} is not valid with {command}")));
        }
        let value = args
            .get(i + 1)
            .ok_or((2, format!("Missing value for {flag}")))?;
        match flag.as_str() {
            "--output" => {
                if value.is_empty() {
                    return Err((2, "--output cannot be empty".into()));
                }
                output_arg = Some(value);
            }
            "--root" => {
                if value.is_empty() {
                    return Err((2, "--root cannot be empty".into()));
                }
                root_arg = Some(value);
            }
            "--min-bytes" => {
                options.min_bytes = value
                    .parse()
                    .map_err(|_| (2, "--min-bytes must be an unsigned integer".into()))?
            }
            "--limit" => {
                options.limit = value
                    .parse()
                    .map_err(|_| (2, "--limit must be an integer between 1 and 1000".into()))?;
                if !(1..=1000).contains(&options.limit) {
                    return Err((2, "--limit must be between 1 and 1000".into()));
                }
            }
            _ => unreachable!(),
        }
        i += 2;
    }
    if exporting && output_arg.is_none() {
        return Err((2, "export-csv needs --output FILE".into()));
    }
    let needs_home =
        root_arg.is_none() || root_arg.is_some_and(|p| p == "~" || p.starts_with("~/"));
    let home = if needs_home {
        let home = std::env::var_os("HOME").ok_or((2, "HOME is not set".into()))?;
        if !Path::new(&home).is_absolute() {
            return Err((2, "HOME must be an absolute directory".into()));
        }
        Some(absolute_directory(Path::new(&home)).map_err(|e| (1, e))?)
    } else {
        None
    };
    let root = match root_arg {
        None | Some("~") => home.as_ref().unwrap().clone(),
        Some(p) if p.starts_with("~/") => home.as_ref().unwrap().join(&p[2..]),
        Some(p) => PathBuf::from(p),
    };
    let root = absolute_directory(&root).map_err(|e| (1, e))?;
    // Fail before a long scan, not after it: the file's folder must take a new file.
    let output = match output_arg {
        Some(output) => {
            let output = std::path::absolute(output)
                .map_err(|e| (1, format!("Cannot resolve {output}: {e}")))?;
            export::check_destination(&output).map_err(|e| (1, e.to_string()))?;
            Some(output)
        }
        None => None,
    };
    // Home rules compare against the same resolution as the scan root. An
    // explicit root needs no home: an unusable HOME only disables home rules.
    let anchor_home = home.or_else(|| {
        let raw = PathBuf::from(std::env::var_os("HOME")?);
        raw.is_absolute()
            .then(|| absolute_directory(&raw).unwrap_or(raw))
    });
    let anchors = cleanup::Anchors::new(anchor_home.as_deref());
    let progress = Progress::default();
    let started = Instant::now();
    let tree = scan_resolved(&root, &progress);
    let elapsed = started.elapsed().as_secs_f64();
    let report = if let Some(output) = &output {
        export_csv(&tree, output)?
    } else if command == "quick-wins" {
        report::quick_wins(&tree, &options, &anchors)
    } else {
        report::inventory(&tree, &options)
    };
    // The same account the app reads through `bz_coverage`.
    let coverage = Coverage::of(&progress, &tree);
    Ok(json!({
        "schema_version": 1, "tool": "blitztree", "version": env!("CARGO_PKG_VERSION"),
        "command": command, "read_only": !exporting, "root": root,
        "generated_at_unix": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
        "scan_seconds": elapsed,
        "options": if exporting { json!({}) } else { json!({"min_bytes": options.min_bytes, "limit": options.limit}) },
        "summary": {"allocated_bytes": tree.alloc[0], "logical_bytes": tree.logical[0],
            "file_count": progress.files.load(Ordering::Relaxed), "directory_count": progress.dirs.load(Ordering::Relaxed)},
        "coverage": {"complete": coverage.complete, "errors": coverage.errors,
            "entry_errors": coverage.entry_errors,
            "invalid_names": coverage.invalid_names,
            "skipped_cloud_directories": coverage.skipped_cloud_directories,
            "skipped_mount_points": coverage.skipped_mount_points,
            "shared_allocated_bytes": coverage.shared_allocated_bytes,
            "clone_ids_unavailable_directories": coverage.clone_ids_unavailable_directories,
            "policy": "Metadata only. One volume; directory symlinks and cloud-only directories are not traversed. Hard links and whole APFS clones count once, under their first path; shared_allocated_bytes is what they would have added again. Clones edited after copying still count in full. Filesystem changes during a scan can affect results."},
        "report": report,
    }))
}

fn main() {
    let (code, result) = match run() {
        Ok(report) => (0, report),
        Err((code, message)) => (
            code,
            json!({"schema_version": 1, "error": {"message": message, "exit_code": code}}),
        ),
    };
    let mut out = io::BufWriter::new(io::stdout().lock());
    if let Err(error) = serde_json::to_writer(&mut out, &result)
        .map_err(io::Error::other)
        .and_then(|()| out.write_all(b"\n"))
        .and_then(|()| out.flush())
    {
        eprintln!("Cannot write report: {error}");
        std::process::exit(1);
    }
    std::process::exit(code);
}
