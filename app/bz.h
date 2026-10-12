// C bridge to the blitztree Rust scan engine.
#ifndef BZ_H
#define BZ_H

#include <stdbool.h>
#include <stdint.h>
#include <removefile.h>

typedef struct BzScan BzScan;

// NULL for a NULL or empty path, or when the scan thread cannot start: that is
// a failed scan, there is no handle to poll. The path bytes are used exactly
// (not necessarily UTF-8); a symlink in them is followed, and the root node
// keeps the name it was given.
BzScan *bz_scan_start(const char *path);
// `done` is set once the scan has ended, with or without a tree: finished,
// cancelled or failed (a NULL handle also reports done). Any output pointer
// may be NULL.
void bz_progress(BzScan *h, uint64_t *files, uint64_t *dirs, uint64_t *bytes, int *done);

// How a scan stands, from bz_scan_status.
enum {
    BZ_SCAN_RUNNING = 0,   // the scan thread is still working
    BZ_SCAN_DONE = 1,      // a tree was built; bz_take_tree returns its nodes
    BZ_SCAN_CANCELLED = 2, // bz_cancel cut the walk short; there is no tree
    BZ_SCAN_FAILED = 3,    // an internal error (logged to stderr); no tree
};
// One of the BZ_SCAN_* values. Anything but BZ_SCAN_RUNNING matches done=1
// in bz_progress. A NULL handle is BZ_SCAN_FAILED. Read it after done to tell
// a stopped scan from a failed one: both have no tree.
int bz_scan_status(BzScan *h);
// Ask a running scan to stop. It reads no further folder and ends promptly
// (the folders being read at that moment finish) with BZ_SCAN_CANCELLED and
// no tree: a partial tree is never handed over as the scan. Poll bz_progress
// for done as usual, then free the handle. Does nothing for a NULL handle, for
// a scan that already ended (whole or cancelled: the result stays as it was)
// and when repeated. A stop that arrives after the last folder was read
// leaves a whole tree, BZ_SCAN_DONE. Callable from any thread, but not
// concurrently with bz_free of the same handle.
void bz_cancel(BzScan *h);

// Node count of the finished tree. 0 means there is none: a scan that failed
// (an internal error, logged to stderr), was cancelled, a NULL handle, or one
// not done yet. A handle with 0 nodes is only for bz_free.
uint64_t bz_take_tree(BzScan *h);

const uint32_t *bz_parents(BzScan *h);
const uint64_t *bz_alloc(BzScan *h);
const uint64_t *bz_logical(BzScan *h);
const uint32_t *bz_nfiles(BzScan *h);
const uint8_t *bz_flags(BzScan *h); // bit0 = is_dir; bit1 = own listing incomplete (engine-internal)
// One bool per node (length N): false when anything in the node's subtree
// was not fully read (an unreadable folder or entry, a cloud-only or mounted
// folder skipped, a name that is not UTF-8 dropped, a size limit). Its sizes
// are then a lower bound. True means everything below was read. A folder
// whose own listing was partial has flags bit1 set as well; one that is only
// false through a child does not. NULL before bz_take_tree.
const bool *bz_complete(BzScan *h);
const uint32_t *bz_child_off(BzScan *h); // length N+1
const uint32_t *bz_children(BzScan *h);
const uint32_t *bz_name_off(BzScan *h); // length N+1
const uint8_t *bz_name_blob(BzScan *h);
uint64_t bz_errors(BzScan *h);

// What a finished scan could not read: the same account the CLI prints as
// `coverage` in its JSON (the engine builds both from one function).
typedef struct {
    uint64_t errors;                 // failed reads of every kind (bz_errors)
    uint64_t entry_errors;           // entries unreadable or malformed
    uint64_t invalid_names;          // entries dropped for a non-UTF-8 name; they and what is below them are missing
    uint64_t skipped_cloud_directories; // cloud-only folders left unread (reading would download them)
    uint64_t skipped_mount_points;   // mount points left unread (a scan measures one volume)
    uint64_t shared_allocated_bytes; // bytes not counted again: hard links, whole APFS clones
    uint64_t clone_ids_unavailable_directories; // folders whose volume reported no clone ids
    bool complete;                   // every folder was read in full (bz_complete of the root)
} BzCoverage;
// Fill `out` and return true. Returns false and leaves `out` untouched for a
// NULL handle, a NULL `out`, or a handle without a tree (before
// bz_take_tree, or a cancelled or failed scan). A tree from bz_remove keeps
// the scan's counters; `complete` and `errors` follow the smaller tree.
bool bz_coverage(BzScan *h, BzCoverage *out);

// Shared Clean Up results, sorted by size. Buffers/labels live until bz_free.
// Only read cleanup_nodes[0..cleanup_count]; an empty list has count zero.
uint64_t bz_cleanup_count(BzScan *h);
const uint32_t *bz_cleanup_nodes(BzScan *h);
// index is a candidate-list index, not a tree node index. NULL out of range.
// Candidates do not nest, except inside a container kind ("git_worktree"),
// which is listed AND descended: sum only outermost candidates for totals.
// Rules are anchored to $HOME (and its /System/Volumes/Data spelling).
const char *bz_cleanup_description(BzScan *h, uint64_t index); // English label
// Stable rule id, e.g. "node_modules", "git_worktree" (static string).
const char *bz_cleanup_kind_id(BzScan *h, uint64_t index);
// "build", "packages", "apps", "devtools", "models", "agents" or "worktrees".
const char *bz_cleanup_section_id(BzScan *h, uint64_t index);
// 0 safe, 1 review, 255 out of range.
uint8_t bz_cleanup_group(BzScan *h, uint64_t index);
// Check required before acting: "" none, else "cachedir_tag", "git_worktree",
// "recent_activity" or "agent_session". Rust matches CACHEDIR.TAG and .git by
// name only.
const char *bz_cleanup_verify(BzScan *h, uint64_t index);

void bz_free(BzScan *h);

// A new handle, already holding its tree, for the scan without `count` nodes
// and everything under them (ancestor sizes and file counts drop to match;
// the root, repeats and out-of-range nodes are ignored). `h` is left
// untouched and must still be freed: a tree is never edited once handed over.
// NULL without a tree. Node numbers are reassigned: an index into `h` means
// nothing in the result. bz_progress on the result reports done with every
// counter 0 (no walk ran); read totals from the tree (alloc[0], nfiles[0]).
// Hard links and whole clones count once, on the first path scanned. Removing
// that path takes their bytes off, and they are not moved to a surviving
// link or clone (the tree does not record which paths share data), so the
// result under-reports until the next scan.
BzScan *bz_remove(BzScan *h, const uint32_t *nodes, uint32_t count);

// Largest files anywhere in the scan (directories excluded), selected in the
// engine without copying the tree: the same function behind the CLI's
// `largest_files`. Nodes are tree indices, largest first, valid until
// bz_largest_free. NULL before a finished scan.
typedef struct BzLargest BzLargest;
BzLargest *bz_largest_files(BzScan *h, uint32_t limit, uint64_t min_bytes);
uint32_t bz_largest_count(BzLargest *l);
const uint32_t *bz_largest_nodes(BzLargest *l);
void bz_largest_free(BzLargest *l);

typedef struct BzSearch BzSearch;

// Interactive search over all nodes in the tree, off main thread.
// query: UTF-8 search pattern (substring or wildcard with * and ?).
// limit: max results to return (sorted largest size first).
BzSearch *bz_search(BzScan *h, const char *query, uint32_t limit);
uint64_t bz_search_total_matches(BzSearch *s);
uint32_t bz_search_result_count(BzSearch *s);
const uint32_t *bz_search_result_nodes(BzSearch *s);
void bz_search_free(BzSearch *s);

typedef struct BzTypes BzTypes;

// Allocated bytes and file counts per extension under node `root`, largest
// first. Row i's extension is ext_blob[ext_off[i]..ext_off[i+1]], ASCII
// lowercase, empty for files without one. NULL without a tree or for a node
// outside it. Buffers live until bz_types_free.
BzTypes *bz_types(BzScan *h, uint32_t root);
uint32_t bz_types_count(BzTypes *t);
const uint32_t *bz_types_ext_off(BzTypes *t); // length count+1
const uint8_t *bz_types_ext_blob(BzTypes *t);
const uint64_t *bz_types_alloc(BzTypes *t);
const uint64_t *bz_types_files(BzTypes *t);
void bz_types_free(BzTypes *t);

#endif
