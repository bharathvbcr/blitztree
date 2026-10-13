#!/bin/zsh
# Freeze production Swift and exercise agent data algorithms entirely offline.
set -euo pipefail
cd "$(dirname "$0")/.."
AGENT_BENCH_TMP=$(mktemp -d /tmp/blitztree-agent-bench.XXXXXX)
trap 'rm -rf "$AGENT_BENCH_TMP"' EXIT
mkdir "$AGENT_BENCH_TMP/app"
cp app/*.swift "$AGENT_BENCH_TMP/app/"
shasum -a 256 "$AGENT_BENCH_TMP/app/Agent.swift" "$AGENT_BENCH_TMP/app/Cleanup.swift" "$AGENT_BENCH_TMP/app/CleanupCommand.swift" "$AGENT_BENCH_TMP/app/CleanupSafety.swift" "$AGENT_BENCH_TMP/app/CleanupOperations.swift" "$AGENT_BENCH_TMP/app/Model.swift"
python3 - "$AGENT_BENCH_TMP/app/Agent.swift" "$AGENT_BENCH_TMP/app/Cleanup.swift" "$AGENT_BENCH_TMP/app/Model.swift" <<'PY'
from pathlib import Path
import sys

def hook(source, old, new, path, what):
    # The hooks anchor on exact production text, so a refactor of that text
    # must fail here, by name, rather than silently skip a hook.
    if source.count(old) != 1:
        sys.exit(f'benchmarks/run-agent.sh: cannot hook "{what}": expected exactly one occurrence of this anchor '
                 f'in {Path(path).name}, found {source.count(old)}:\n--- anchor ---\n{old}\n--- end ---\n'
                 f'The production code changed; update the anchor in benchmarks/run-agent.sh.')
    return source.replace(old, new)

p=Path(sys.argv[1]); source=p.read_text()
changes={
    'private var preparationTask: Task<Void, Never>?': 'var preparationTask: Task<Void, Never>?',
    '            step(asking)\n            start()\n': '            step(asking)\n            AgentBenchmarkLaunch.record(input)\n',
    'AgentPrompt.build(tree: tree, scanRoot: scanRoot, known: known, running: running, focus: focus)': 'AgentBenchmarkGate.shared.waitIfArmed(); return AgentPrompt.build(tree: tree, scanRoot: scanRoot, known: known, running: running, focus: focus)',
    '+ AgentPrompt.appData(tree: tree, focus: focus?.path)': '',  # Keep simulator/session lookups out of the offline fixture.
}
for old,new in changes.items():
    source=hook(source, old, new, p, 'AgentRun launch / prompt preparation')
p.write_text(source)
p=Path(sys.argv[2]); source=p.read_text()
old='''                        guard let target = item.target else {
                            throw CleanupOperations.failure(String(localized: "This folder could not be validated; rescan before cleaning"))
                        }
                        // Revalidating at the boundary checks the folder again
                        // (it may have been used since the scan), rule check included.
                        _ = try CleanupOperations.trash(target)'''
p.write_text(hook(source, old, '                        try AgentBenchmarkTrash.move(item)', p, 'manual Trash operation'))
p=Path(sys.argv[3]); source=p.read_text()
old='''    func startAgent(_ agent: InstalledAgent, focus: AgentFocus? = nil, routes: [Manvi.Route]? = nil) {
'''
new=old+'        AgentBenchmarkLaunch.agentStarts += 1\n'
p.write_text(hook(source, old, new, p, 'ScanModel.startAgent'))
PY
clang -O2 -mmacosx-version-min=14.0 -c benchmarks/ui_fixture.c -o "$AGENT_BENCH_TMP/fixture.o"
# Every app source but the entry point (and its Sparkle import), as the
# regression checks build them, so a new file can't leave this behind.
AGENT_BENCH_SOURCES=("$AGENT_BENCH_TMP"/app/*.swift)
AGENT_BENCH_SOURCES=(${AGENT_BENCH_SOURCES:#*/Main.swift})
swiftc "${AGENT_BENCH_SOURCES[@]}" \
  benchmarks/AgentReference.swift benchmarks/AgentPerformance.swift "$AGENT_BENCH_TMP/fixture.o" \
  -import-objc-header benchmarks/ui_fixture.h \
  -O -parse-as-library -swift-version 6 -default-isolation MainActor \
  -target arm64-apple-macos14.0 -framework AppKit -framework SwiftUI \
  -o "$AGENT_BENCH_TMP/agent-bench"
"$AGENT_BENCH_TMP/agent-bench" "$@"
