"""Black-box contract tests; only write/delete isolated temporary fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = Path(os.environ.get("BLITZTREE_BIN", Path(__file__).resolve().parents[1] / "target/release/blitztree"))


class AgentCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="blitztree-api-")
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home))

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, *args, code=0):
        result = subprocess.run([str(BIN), *args], env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, code, result.stderr + result.stdout)
        data = json.loads(result.stdout)
        self.assertEqual(data["schema_version"], 1)
        return data

    def file(self, relative, size=8192):
        p = self.home / relative
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x" * size)
        return p

    def wins(self, *args):
        return self.run_cli("quick-wins", "--min-bytes", "1", *args)["report"]

    def test_sizes_hardlinks_and_no_mutations(self):
        data = self.file("file")
        os.link(data, self.home / "second-name")
        before = data.stat()
        result = self.run_cli("scan", "--root", str(self.home), "--min-bytes", "1")
        self.assertEqual(result["summary"]["logical_bytes"], 8192)
        self.assertEqual(result["summary"]["file_count"], 2)
        self.assertEqual(result["summary"]["allocated_bytes"], before.st_blocks * 512)
        self.assertTrue(result["read_only"])
        self.assertEqual(data.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(data.read_bytes(), b"x" * 8192)

    def test_apfs_clones_count_once(self):
        # Chrome's code_sign_clone pattern: one bundle cloned many times.
        bundle = self.home / "Applications/App.app"
        for name in ("binary", "Frameworks/lib"):
            self.file(f"Applications/App.app/{name}", size=1 << 20)
        copies = 12
        for i in range(copies):
            target = self.home / f"tmp/code_sign_clone.{i:02d}"
            target.mkdir(parents=True)
            cloned = subprocess.run(["cp", "-c", "-R", str(bundle), str(target / "App.app")],
                                    capture_output=True, text=True)
            self.assertEqual(cloned.returncode, 0, f"cp -c needs an APFS temp directory: {cloned.stderr}")
        one = sum(p.stat().st_blocks * 512 for p in bundle.rglob("*") if p.is_file())
        result = self.run_cli("scan", "--root", str(self.home), "--min-bytes", "1", "--limit", "1000")
        self.assertEqual(result["summary"]["file_count"], 2 * (copies + 1))
        self.assertEqual(result["summary"]["allocated_bytes"], one)
        self.assertEqual(result["summary"]["logical_bytes"], 2 << 20)
        self.assertEqual(result["coverage"]["shared_allocated_bytes"], copies * one)
        self.assertEqual(result["coverage"]["clone_ids_unavailable_directories"], 0)
        sizes = {Path(d["path"]).name: d["allocated_bytes"] for d in result["report"]["largest_directories"]}
        self.assertEqual(sizes.get("App.app"), one, "the first path, Applications/App.app, owns the bytes")
        self.assertNotIn("tmp", sizes, "clones whose source is scanned add nothing")

    def test_no_symlink_traversal(self):
        outside = self.root / "outside"
        (outside / "node_modules").mkdir(parents=True)
        (outside / "package.json").write_text("{}")
        (outside / "node_modules/file").write_bytes(b"x" * 8192)
        (self.home / "shortcut").symlink_to(outside, target_is_directory=True)
        result = self.run_cli("scan", "--min-bytes", "0")
        self.assertEqual(result["summary"]["file_count"], 1)
        self.assertEqual(self.wins()["candidates"], [])

    def relative_kinds(self, candidates):
        return {Path(c["path"]).relative_to(self.home).as_posix(): c["category"] for c in candidates}

    def test_candidates_use_the_shared_cleanup_rules(self):
        # Changed deliberately with the cleanup categories: a node_modules needs a
        # package.json, ~/.cache and ~/Library/Caches list their children (never
        # com.apple.*), and a Gradle home lists only its caches.
        for path in [
            ".gradle/gradle.properties", ".gradle/caches/file", ".npm/npmrc", ".cache/unknown/content",
            "no-manifest/node_modules/file", "no-manifest/.venv/file",
            "python/venv/pyvenv.cfg", "rust/Cargo.toml", "rust/target/file",
            "web/package.json", "web/node_modules/file", "web/.next/file",
            "Library/Developer/Xcode/DerivedData/file",
            "Library/Caches/com.apple.example/file", "Library/Caches/org.example.app/file",
            "Library/Developer/CoreSimulator/Caches/file",
            "Library/Developer/Xcode/iOS DeviceSupport/file", "Library/Developer/Xcode/macOS DeviceSupport/file",
            "Library/Developer/Xcode/watchOS DeviceSupport/file",
            ".bun/install/cache/file", "swift/Package.swift", "swift/.build/file",
        ]:
            self.file(path)
        candidates = self.wins("--limit", "100")["candidates"]
        self.assertEqual(self.relative_kinds(candidates), {
            ".gradle/caches": "gradle_cache", ".npm": "tool_caches", ".cache/unknown": "tool_caches",
            "no-manifest/.venv": "python_environment", "web/node_modules": "node_modules",
            "python/venv": "python_environment", "rust/target": "rust_build", "web/.next": "next_build",
            "Library/Developer/Xcode/DerivedData": "xcode_derived_data",
            "Library/Caches/org.example.app": "app_caches",
            "Library/Developer/CoreSimulator/Caches": "app_caches",
            "Library/Developer/Xcode/iOS DeviceSupport": "device_support",
            "Library/Developer/Xcode/macOS DeviceSupport": "device_support",
            "Library/Developer/Xcode/watchOS DeviceSupport": "device_support",
            ".bun/install/cache": "bun_cache", "swift/.build": "swift_build",
        })
        self.assertTrue(all(c["requires_review"] for c in candidates))
        self.assertTrue(all(c["reason"] for c in candidates))
        self.assertEqual(self.run_cli("quick-wins")["options"]["min_bytes"], 50_000_000)
        self.assertEqual(self.run_cli("quick-wins")["report"]["candidates"], [])

    def test_candidates_carry_group_section_and_verify(self):
        for path in ["web/package.json", "web/node_modules/file", "tool/state/CACHEDIR.TAG", "tool/state/blob",
                     ".m2/repository/file", ".claude/projects/p/session.jsonl"]:
            self.file(path)
        candidates = self.wins("--limit", "100")["candidates"]
        fields = {Path(c["path"]).relative_to(self.home).as_posix(): (c["category"], c["group"], c["section"], c["verify"])
                  for c in candidates}
        self.assertEqual(fields, {
            "web/node_modules": ("node_modules", "safe", "build", None),
            "tool/state": ("tagged_cache", "safe", "packages", "cachedir_tag"),
            ".m2/repository": ("maven_repository", "review", "packages", None),
            ".claude/projects/p": ("agent_transcripts", "review", "agents", "recent_activity"),
        })
        self.assertTrue(all(c["contained_in"] is None for c in candidates))

    def test_home_anchored_rules_follow_HOME(self):
        layout = [".cache/pip/file", ".cargo/registry/file", ".cargo/bin/cargo", ".rustup/toolchains/stable/file",
                  ".ollama/models/file", ".codex/sessions/2025/file", ".codex/auth.json",
                  ".cache/huggingface/hub/models--org--name/file", ".cache/huggingface/token"]
        for path in layout:
            self.file(path)
        expected = {
            ".cache/pip": "tool_caches", ".cargo/registry": "cargo_cache",
            ".rustup/toolchains/stable": "rust_toolchain", ".ollama/models": "ollama_models",
            ".codex/sessions/2025": "codex_sessions", ".cache/huggingface/hub/models--org--name": "ml_model",
        }
        self.assertEqual(self.relative_kinds(self.wins("--limit", "100")["candidates"]), expected)
        # The same folders under another HOME are ordinary folders: only the
        # unanchored .cache rule applies, to the whole folder.
        self.env["HOME"] = str(self.root)
        self.assertEqual(self.relative_kinds(self.wins("--root", str(self.home), "--limit", "100")["candidates"]),
                         {".cache": "tool_caches"})

    def protected_entries(self):
        return [".cargo/bin/cargo", ".cargo/config.toml", ".cargo/credentials.toml", ".cargo/env",
                ".cargo/.crates.toml", ".cargo/.crates2.json",
                ".gradle/gradle.properties", ".gradle/init.d/repos.gradle", ".gradle/init.gradle",
                ".gradle/init.gradle.kts", ".m2/settings.xml", ".claude/settings.json", ".claude/.credentials.json",
                ".claude/local/package.json", ".codex/auth.json", ".codex/config.toml",
                ".cache/huggingface/token", ".cache/huggingface/stored_tokens"]

    def assert_none_inside(self, candidates, protected):
        for c in candidates:
            for p in protected:
                self.assertFalse(p == Path(c["path"]) or Path(c["path"]) in p.parents,
                                 f"{p} is inside candidate {c['path']} ({c['category']})")

    def test_gradle_properties_is_never_inside_a_candidate(self):
        for path in [".gradle/gradle.properties", ".gradle/caches/file", ".gradle/native/file",
                     "app/.gradle/gradle.properties", "app/.gradle/caches/file",
                     ".cache/gradle/gradle.properties", ".cache/gradle/caches/file"]:
            self.file(path)
        candidates = self.wins("--limit", "100")["candidates"]
        self.assertEqual(self.relative_kinds(candidates), {
            ".gradle/caches": "gradle_cache", "app/.gradle/caches": "gradle_cache",
            ".cache/gradle/caches": "gradle_cache"})
        self.assert_none_inside(candidates, [p for p in self.home.rglob("gradle.properties")])

    def test_credentials_are_never_inside_any_candidate(self):
        for path in self.protected_entries():
            self.file(path)
        for path in [".cargo/registry/file", ".cargo/git/file", ".gradle/caches/file", ".m2/repository/file",
                     ".claude/projects/p/file", ".claude/debug/file", ".claude/local/node_modules/file",
                     ".codex/archived_sessions/file", ".cache/huggingface/hub/models--m/file", ".cache/pip/file",
                     "lib/node_modules/npm/index.js"]:
            self.file(path)
        for root in [self.home, Path("/System/Volumes/Data") / self.home.relative_to("/")]:
            if not root.exists():
                continue
            candidates = self.wins("--root", str(root), "--limit", "1000")["candidates"]
            self.assertGreaterEqual(len(candidates), 9)
            protected = [root / p for p in self.protected_entries()]
            self.assert_none_inside(candidates, protected)
            self.assertNotIn("lib/node_modules", {Path(c["path"]).relative_to(root).as_posix() for c in candidates})

    def test_worktree_contents_are_listed_and_counted_once(self):
        self.file("repo/.git/HEAD")
        self.file("repo/.claude/worktrees/feature/.git", size=64)
        self.file("repo/.claude/worktrees/feature/package.json")
        self.file("repo/.claude/worktrees/feature/node_modules/file")
        self.file("repo/sub/.git", size=64)
        self.file("repo/sub/file")
        report = self.wins("--limit", "100")
        worktree = self.home / "repo/.claude/worktrees/feature"
        by_path = {c["path"]: c for c in report["candidates"]}
        self.assertEqual(set(by_path), {str(worktree), str(worktree / "node_modules")})
        self.assertEqual(by_path[str(worktree)]["category"], "git_worktree")
        self.assertEqual(by_path[str(worktree)]["verify"], "git_worktree")
        self.assertIsNone(by_path[str(worktree)]["contained_in"])
        self.assertEqual(by_path[str(worktree / "node_modules")]["contained_in"], str(worktree))
        self.assertEqual(report["candidate_allocated_bytes"], by_path[str(worktree)]["allocated_bytes"])
        self.assertEqual(report["displayed_allocated_bytes"], report["candidate_allocated_bytes"])
        nested_only = self.wins("--limit", "1")
        self.assertEqual(nested_only["displayed_allocated_bytes"], by_path[str(worktree)]["allocated_bytes"])

    def test_unrecognized_folders_and_trash_are_not_candidates(self):
        for path in ["unrelated/target/file", "unrelated/venv/file", "unrelated/.next/file",
                     "unrelated/Caches/file", "unrelated/DerivedData/file", "unrelated/install/cache/file",
                     "swift/.build/file", "global/lib/node_modules/npm/file", ".Trash/node_modules/file",
                     ".Trash/package.json"]:
            self.file(path)
        self.assertEqual(self.wins()["candidates"], [])

    def test_no_nested_candidates_or_overlapping_totals(self):
        self.file("project/package.json")
        self.file("project/node_modules/inner/package.json")
        self.file("project/node_modules/inner/node_modules/file")
        self.file(".cache/pip/file")
        report = self.wins()
        self.assertEqual(len(report["candidates"]), 2)
        self.assertEqual(report["candidate_allocated_bytes"], sum(c["allocated_bytes"] for c in report["candidates"]))
        limited = self.wins("--limit", "1")
        self.assertTrue(limited["truncated"])
        self.assertEqual(limited["candidate_count"], 2)
        self.assertLess(limited["displayed_allocated_bytes"], limited["candidate_allocated_bytes"])
        self.assertIsNone(limited["reclaimable_bytes"])

    def test_json_escapes_untrusted_names(self):
        name = 'space " quote\n$(touch NEVER_EXECUTE)/node_modules'
        self.file(name + "/file")
        self.file('space " quote\n$(touch NEVER_EXECUTE)/package.json')
        report = self.wins()
        self.assertEqual(report["candidates"][0]["path"], str(self.home / name))
        self.assertFalse((self.home / "NEVER_EXECUTE").exists())

    def test_invalid_root_and_arguments_return_json_errors(self):
        for args in [("destroy",), ("scan", "--limit", "0"), ("scan", "--limit", "1001"),
                     ("scan", "--min-bytes", "-1"), ("scan", "--root"), ("scan", "--include-recent"), ("quick-wins", "--include-recent"),
                     ("scan", "--limit", "1", "--limit", "2")]:
            self.assertIn("error", self.run_cli(*args, code=2))
        self.assertIn("error", self.run_cli("scan", "--root", str(self.home / "missing"), code=1))
        file = self.file("a-file")
        self.assertIn("error", self.run_cli("scan", "--root", str(file), code=1))

    def test_partial_scan_reports_errors(self):
        if os.geteuid() == 0:
            self.skipTest("root bypasses fixture permission bits")
        denied = self.home / "denied"
        denied.mkdir()
        denied.chmod(0)
        try:
            report = self.run_cli("scan")
            self.assertFalse(report["coverage"]["complete"])
            self.assertGreater(report["coverage"]["errors"], 0)
            self.run_cli("scan", "--root", str(denied), code=1)
        finally:
            denied.chmod(0o700)

    def test_explicit_root_candidates_do_not_depend_on_home_or_activity(self):
        outside = self.root / "external"
        (outside / "node_modules").mkdir(parents=True)
        (outside / "node_modules/file").write_bytes(b"x" * 8192)
        (outside / "package.json").write_text("{}")
        self.env.pop("HOME")
        report = self.run_cli("quick-wins", "--root", str(outside), "--min-bytes", "1")
        self.assertEqual([c["path"] for c in report["report"]["candidates"]], [str(outside / "node_modules")])

    def test_data_volume_firmlink_home(self):
        alias = Path("/System/Volumes/Data") / self.home.relative_to("/")
        if not alias.exists() or not alias.samefile(self.home):
            self.skipTest("Data volume alias unavailable on this Mac")
        self.file(".npm/_cacache/file")
        report = self.run_cli("quick-wins", "--root", str(alias), "--min-bytes", "1")
        self.assertEqual(len(report["report"]["candidates"]), 1)
        self.assertEqual(report["report"]["candidates"][0]["path"], str(alias / ".npm"))

    def test_explicit_symlink_root_is_resolved(self):
        self.file(".cache/pip/file")
        link = self.root / "home-link"
        link.symlink_to(self.home, target_is_directory=True)
        report = self.run_cli("quick-wins", "--root", str(link), "--min-bytes", "1")
        self.assertEqual(report["root"], str(self.home))
        self.assertEqual(len(report["report"]["candidates"]), 1)

    def test_inventory_top_k_is_sorted_and_bounded(self):
        for i in range(200):
            self.file(f"many/{i:03d}", size=8192 * ((i % 5) + 1))
        result = self.run_cli("scan", "--min-bytes", "0", "--limit", "7")
        files = result["report"]["largest_files"]
        expected = sorted((p for p in (self.home / "many").iterdir()),
                          key=lambda p: (-p.stat().st_blocks, str(p)))[:7]
        self.assertEqual([p["path"] for p in files], [str(p) for p in expected])

    def test_scan_root_is_not_itself_a_candidate_like_the_panel(self):
        self.file("project/node_modules/file")
        report = self.wins("--root", str(self.home / "project/node_modules"))
        self.assertEqual(report["candidates"], [])
        self.assertEqual(len(report["inventory"]["largest_files"]), 1)

    def test_markers_retain_the_panels_name_only_semantics(self):
        self.file("directory-marker/Cargo.toml/content")
        self.file("directory-marker/target/file")
        self.file("actual-package.json")
        self.file("symlink-marker/.next/file")
        (self.home / "symlink-marker/package.json").symlink_to(self.home / "actual-package.json")
        self.assertEqual({c["category"] for c in self.wins()["candidates"]}, {"rust_build", "next_build"})

    def test_explicit_scan_root_does_not_require_home(self):
        self.env.pop("HOME")
        self.file("content")
        result = self.run_cli("scan", "--root", str(self.home))
        self.assertEqual(result["summary"]["file_count"], 1)

    def test_invalid_path_and_home(self):
        file = self.file("file")
        self.run_cli("scan", "--root", str(file) + "/..", code=1)
        self.run_cli("scan", "--root", "", code=2)
        self.env["HOME"] = "relative"
        self.run_cli("quick-wins", code=2)
        self.run_cli("scan", "--limit", "0", code=2)

    def test_partial_candidates_are_labeled_without_changing_panel_selection(self):
        if os.geteuid() == 0:
            self.skipTest("root bypasses fixture permission bits")
        self.file(".cache/pip/visible")
        denied = self.home / ".cache/pip/denied"
        denied.mkdir()
        denied.chmod(0)
        try:
            result = self.run_cli("quick-wins", "--min-bytes", "1")
            self.assertFalse(result["coverage"]["complete"])
            self.assertEqual(result["report"]["candidates"][0]["path"], str(self.home / ".cache/pip"))
            self.assertFalse(result["report"]["candidates"][0]["complete"])
            self.assertTrue(result["report"]["candidates"][0]["requires_review"])
            directory = next(d for d in result["report"]["inventory"]["largest_directories"] if d["path"] == str(self.home / ".cache/pip"))
            self.assertFalse(directory["complete"])
        finally:
            denied.chmod(0o700)

    def test_inventory_includes_large_unclassified_and_sensitive_directories(self):
        self.file("Documents/archives/big-file", size=65536)
        self.file(".cache/pip/file")
        scan = self.run_cli("scan", "--min-bytes", "1")["report"]
        self.assertEqual(scan["largest_directories"][0]["path"], str(self.home / "Documents"))
        self.assertIn(str(self.home / "Documents/archives"), [d["path"] for d in scan["largest_directories"]])
        wins = self.wins()
        self.assertEqual(wins["inventory"], scan)
        self.assertEqual([c["path"] for c in wins["candidates"]], [str(self.home / ".cache/pip")])

    def test_inventory_is_returned_even_outside_home(self):
        outside = self.root / "outside"
        (outside / "large").mkdir(parents=True)
        (outside / "large/file").write_bytes(b"x" * 8192)
        report = self.wins("--root", str(outside))
        self.assertEqual(report["candidates"], [])
        self.assertEqual(report["inventory"]["largest_directories"][0]["path"], str(outside / "large"))

    def test_hardlink_path_allocation_and_report_order_are_stable(self):
        source = self.file("z/node_modules/file")
        destination = self.home / "a/node_modules/file"
        destination.parent.mkdir(parents=True)
        os.link(source, destination)
        for project in ["z", "a"]:
            (self.home / project / "package.json").write_text("{}")
        reports = [self.wins() for _ in range(6)]
        self.assertTrue(all(r == reports[0] for r in reports))
        self.assertEqual([c["path"] for c in reports[0]["candidates"]], [str(destination.parent)])
        self.assertEqual(reports[0]["candidate_allocated_bytes"], source.stat().st_blocks * 512)


if __name__ == "__main__":
    unittest.main()
