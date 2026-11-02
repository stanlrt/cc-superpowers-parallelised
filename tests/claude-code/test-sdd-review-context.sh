#!/usr/bin/env bash
# Tests for SDD review context: scripts/instruction-files collects the
# AGENTS.md / CLAUDE.md files that govern a set of paths, review-package
# inlines them and widens each hunk to its enclosing function, and
# task-brief appends them to a task brief.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SDD_SCRIPTS="$REPO_ROOT/skills/subagent-driven-development/scripts"

FAILURES=0
TEST_ROOT=""
REPO=""
GIT_ID=(-c user.email=t@example.com -c user.name=t -c commit.gpgsign=false)

pass() { echo "  [PASS] $1"; }
fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

# assert_contains FILE NEEDLE DESCRIPTION — NEEDLE appears anywhere in FILE.
assert_contains() {
    if grep -qF -- "$2" "$1"; then pass "$3"; else fail "$3"; echo "    missing: $2"; fi
}

# assert_not_contains FILE NEEDLE DESCRIPTION
assert_not_contains() {
    if grep -qF -- "$2" "$1"; then fail "$3"; echo "    unexpected: $2"; else pass "$3"; fi
}

# assert_has_line FILE LINE DESCRIPTION — LINE is a whole line of FILE.
assert_has_line() {
    if grep -qxF -- "$2" "$1"; then pass "$3"; else fail "$3"; echo "    missing line: $2"; fi
}

cleanup() {
    if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
        rm -rf "$TEST_ROOT"
    fi
}

# filler N PREFIX — print N indented, unique filler lines.
filler() {
    local i
    for ((i = 1; i <= $1; i++)); do
        printf '  const %s%d = %d;\n' "$2" "$i" "$i"
    done
}

# make_fixture — a repo with instruction files at several depths and two
# source files. No .gitattributes: function context comes from git's
# default funcname rule.
make_fixture() {
    git init -q -b main "$TEST_ROOT/repo"
    REPO="$(cd "$TEST_ROOT/repo" && git rev-parse --show-toplevel)"
    mkdir -p "$REPO/pkg/sub/deep" "$REPO/pkg/other"
    printf '# Root rules\nROOT_RULE: keep functions small.\n' > "$REPO/AGENTS.md"
    printf '# Sub rules\nNESTED_RULE: never read a whole collection in one call.\n' > "$REPO/pkg/sub/AGENTS.md"
    cp "$REPO/pkg/sub/AGENTS.md" "$REPO/pkg/sub/CLAUDE.md"
    printf 'DEEP_RULE: deep only.\n' > "$REPO/pkg/sub/deep/AGENTS.md"
    printf 'SIBLING_RULE: other only.\n' > "$REPO/pkg/other/AGENTS.md"
    printf 'readme\n' > "$REPO/README.md"
    printf 'export const other = 1;\n' > "$REPO/pkg/other/thing.js"
    {
        echo 'function renderPanel(items) {'
        filler 12 before
        echo '  wrapWithKey(items, () => {'
        echo '    let count = 0;'
        echo '  });'
        filler 12 after
        echo '} // end renderPanel'
        echo ''
        echo 'function trailing() {'
        echo '  return 1;'
        echo '}'
    } > "$REPO/pkg/sub/widget.js"
    {
        echo 'function longTail() {'
        echo '  let seed = 0;'
        filler 60 tail
        echo '  const farMarker = 1;'
        echo '} // end longTail'
    } > "$REPO/pkg/sub/long.js"
    ( cd "$REPO" && git add -A && git "${GIT_ID[@]}" commit -qm c1 )
}

test_instruction_files() {
    echo "--- instruction-files ---"
    local out="$TEST_ROOT/if-widget.txt"
    ( cd "$REPO" && "$SDD_SCRIPTS/instruction-files" pkg/sub/widget.js ) > "$out"
    assert_has_line "$out" "## Instruction files (binding)" "section heading printed"
    assert_has_line "$out" "- AGENTS.md" "root file listed"
    assert_has_line "$out" "- pkg/sub/AGENTS.md" "nested file listed"
    assert_has_line "$out" "     2  ROOT_RULE: keep functions small." "root content with line numbers"
    assert_has_line "$out" "     2  NESTED_RULE: never read a whole collection in one call." "nested content with line numbers"
    assert_has_line "$out" "### pkg/sub/CLAUDE.md — identical to pkg/sub/AGENTS.md" "identical CLAUDE.md deduped"
    if [[ "$(grep -cF NESTED_RULE "$out")" -eq 1 ]]; then
        pass "duplicate content printed once"
    else
        fail "duplicate content printed once"
    fi
    assert_not_contains "$out" "SIBLING_RULE" "sibling directory excluded"
    assert_not_contains "$out" "DEEP_RULE" "child directory excluded"
    local root_line nested_line
    root_line="$(grep -nxF -- "- AGENTS.md" "$out" | cut -d: -f1)"
    nested_line="$(grep -nxF -- "- pkg/sub/AGENTS.md" "$out" | cut -d: -f1)"
    if [[ -n "$root_line" && -n "$nested_line" && "$root_line" -lt "$nested_line" ]]; then
        pass "root listed before nested"
    else
        fail "root listed before nested"
    fi

    out="$TEST_ROOT/if-new.txt"
    ( cd "$REPO" && "$SDD_SCRIPTS/instruction-files" pkg/sub/newdir/new.js ) > "$out"
    assert_contains "$out" "NESTED_RULE" "path in a missing directory still gets ancestor files"

    out="$TEST_ROOT/if-subdir.txt"
    ( cd "$REPO/pkg/sub" && "$SDD_SCRIPTS/instruction-files" pkg/sub/widget.js ) > "$out"
    assert_contains "$out" "NESTED_RULE" "root-relative paths work from a subdirectory"

    out="$TEST_ROOT/if-none.txt"
    ( cd "$REPO" && "$SDD_SCRIPTS/instruction-files" ) > "$out"
    if [[ ! -s "$out" ]]; then pass "no paths, no output"; else fail "no paths, no output"; fi

    printf 'UNCOMMITTED_RULE: working tree only.\n' >> "$REPO/pkg/sub/AGENTS.md"
    out="$TEST_ROOT/if-tree.txt"
    ( cd "$REPO" && "$SDD_SCRIPTS/instruction-files" --tree HEAD pkg/sub/widget.js ) > "$out"
    assert_not_contains "$out" "UNCOMMITTED_RULE" "--tree reads the tree, not the working tree"
    out="$TEST_ROOT/if-wt.txt"
    ( cd "$REPO" && "$SDD_SCRIPTS/instruction-files" pkg/sub/widget.js ) > "$out"
    assert_contains "$out" "     3  UNCOMMITTED_RULE: working tree only." "default mode reads the working tree"
    ( cd "$REPO" && git checkout -q -- pkg/sub/AGENTS.md )

    if ( cd "$REPO" && "$SDD_SCRIPTS/instruction-files" --tree nosuchref x.js ) >/dev/null 2>&1; then
        fail "bad TREEISH exits non-zero"
    else
        pass "bad TREEISH exits non-zero"
    fi
}

main() {
    echo "=== Test: sdd review context ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT

    make_fixture
    test_instruction_files

    echo ""
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "FAILED: $FAILURES assertion(s)."
        exit 1
    fi
    echo "PASS"
}

main "$@"
