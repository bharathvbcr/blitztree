#!/bin/zsh
# Fails when app/bz.h declares a function that a benchmark fixture
# (benchmarks/*_fixture.c) does not define, so a new engine entry point can't
# leave the benchmark runners unlinkable. Declared names come from bz.h with
# comments stripped; defined names come from the compiled fixture object.
# Usage: benchmarks/check-fixtures.sh [header.h fixture.c ...]  (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."
HEADER=app/bz.h
FIXTURES=(benchmarks/*_fixture.c)
if (( $# > 0 )); then
    HEADER=$1
    shift
    FIXTURES=("$@")
fi
(( ${#FIXTURES[@]} > 0 )) || { print -u2 'check-fixtures: no fixtures found'; exit 2; }
TMP=$(mktemp -d /tmp/blitztree-fixture-check.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Function declarations only: strip // comments (the header has no block
# comments), then take every `bz_name(`.
sed 's,//.*,,' "$HEADER" | grep -Eo '\bbz_[a-z0-9_]+ *\(' | tr -d ' (' | sort -u > "$TMP/declared"
if [[ ! -s "$TMP/declared" ]]; then
    print -u2 "check-fixtures: found no bz_* declarations in $HEADER; refusing to pass"
    exit 2
fi

STATUS=0
for FIXTURE in "${FIXTURES[@]}"; do
    clang -O0 -mmacosx-version-min=14.0 -I "$(dirname "$HEADER")" -c "$FIXTURE" -o "$TMP/fixture.o"
    # Defined global text symbols; nm prints a leading underscore on Mach-O.
    nm -g -U -j "$TMP/fixture.o" | sed 's/^_//' | sort -u > "$TMP/defined"
    MISSING=$(comm -23 "$TMP/declared" "$TMP/defined")
    if [[ -n "$MISSING" ]]; then
        print -u2 "check-fixtures: $FIXTURE does not define:"
        print -- "$MISSING" | sed 's/^/  /' >&2
        STATUS=1
    else
        print "check-fixtures: $FIXTURE defines all $(wc -l < "$TMP/declared" | tr -d ' ') functions declared in $HEADER"
    fi
done
exit $STATUS
