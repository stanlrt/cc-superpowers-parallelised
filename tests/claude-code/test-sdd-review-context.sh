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

# make_change — commit c2: one-line edits deep inside widget.js and long.js,
# an edit in pkg/other, and a new 60-line file.
make_change() {
    ( cd "$REPO" \
        && sed -i.bak 's/    let count = 0;/    let count = items.length;/' pkg/sub/widget.js \
        && sed -i.bak 's/  let seed = 0;/  let seed = 1;/' pkg/sub/long.js \
        && rm -f pkg/sub/*.bak \
        && printf 'export const other = 2;\n' > pkg/other/thing.js \
        && { echo 'function fresh() {'; filler 60 fresh; echo '}'; } > pkg/sub/fresh.js \
        && git add -A && git "${GIT_ID[@]}" commit -qm c2 )
}

# package_path OUTPUT — the package path from review-package's "wrote" line.
package_path() {
    printf '%s\n' "$1" | sed -n 's/^wrote \(.*\): [0-9].*$/\1/p'
}

test_review_package() {
    echo "--- review-package ---"
    make_change
    local out pkg

    out="$(cd "$REPO" && "$SDD_SCRIPTS/review-package" HEAD~1 HEAD)"
    pkg="$(package_path "$out")"
    assert_has_line "$pkg" "## Instruction files (binding)" "package has the instruction section"
    assert_has_line "$pkg" "     2  ROOT_RULE: keep functions small." "root rule inlined"
    assert_has_line "$pkg" "     2  NESTED_RULE: never read a whole collection in one call." "nested rule inlined"
    assert_contains "$pkg" "SIBLING_RULE" "rules of every changed file's directories (pkg/other changed)"
    assert_not_contains "$pkg" "DEEP_RULE" "directory below a changed file excluded"
    local files_line instr_line diff_line
    files_line="$(grep -nxF '## Files changed' "$pkg" | cut -d: -f1)"
    instr_line="$(grep -nxF '## Instruction files (binding)' "$pkg" | cut -d: -f1)"
    diff_line="$(grep -nxF '## Diff' "$pkg" | cut -d: -f1)"
    if [[ -n "$files_line" && -n "$instr_line" && -n "$diff_line" \
          && "$files_line" -lt "$instr_line" && "$instr_line" -lt "$diff_line" ]]; then
        pass "section order: files changed, instruction files, diff"
    else
        fail "section order: files changed, instruction files, diff"
    fi
    assert_has_line "$pkg" " function renderPanel(items) {" "enclosing function opening line"
    assert_has_line "$pkg" " } // end renderPanel" "enclosing function closing line"
    assert_has_line "$pkg" "   const farMarker = 1;" "default cap keeps the whole long function"
    assert_contains "$pkg" "# Context: each hunk shows its whole enclosing function (cap: 400 lines per file)" "header names the context rule"
    assert_not_contains "$pkg" "# context capped:" "nothing capped at the default cap"

    out="$(cd "$REPO" && SDD_CONTEXT_CAP=45 "$SDD_SCRIPTS/review-package" HEAD~1 HEAD)"
    pkg="$(package_path "$out")"
    assert_has_line "$pkg" "# context capped: pkg/sub/long.js (function context over 45 lines; -U10 shown)" "over-cap file marked"
    assert_contains "$pkg" "# Context capped (-U10 shown): pkg/sub/long.js" "header lists capped files"
    assert_not_contains "$pkg" "farMarker" "capped file falls back to -U10"
    assert_not_contains "$pkg" "# context capped: pkg/sub/widget.js" "under-cap file not marked"
    assert_has_line "$pkg" " } // end renderPanel" "under-cap file keeps function context"
    assert_not_contains "$pkg" "# context capped: pkg/sub/fresh.js" "new file never marked capped"

    if ( cd "$REPO" && SDD_CONTEXT_CAP=abc "$SDD_SCRIPTS/review-package" HEAD~1 HEAD ) >/dev/null 2>&1; then
        fail "non-numeric SDD_CONTEXT_CAP rejected"
    else
        pass "non-numeric SDD_CONTEXT_CAP rejected"
    fi

    out="$(cd "$REPO" && "$SDD_SCRIPTS/review-package" HEAD~1 HEAD -- pkg/sub/widget.js)"
    pkg="$(package_path "$out")"
    assert_contains "$pkg" "NESTED_RULE" "pathspec run keeps the scoped file's rules"
    assert_not_contains "$pkg" "SIBLING_RULE" "pathspec run drops out-of-scope rules"
    assert_not_contains "$pkg" "pkg/sub/long.js" "pathspec run drops out-of-scope diffs"

    printf 'SNAPSHOT_RULE: from the working tree.\n' >> "$REPO/pkg/sub/AGENTS.md"
    local before after
    before="$(cd "$REPO" && git rev-parse 'HEAD^{tree}')"
    after="$(cd "$REPO" && "$SDD_SCRIPTS/snapshot")"
    out="$(cd "$REPO" && "$SDD_SCRIPTS/review-package" "$before" "$after")"
    pkg="$(package_path "$out")"
    assert_has_line "$pkg" "     3  SNAPSHOT_RULE: from the working tree." "instruction files read from the HEAD tree-ish (snapshot)"
    ( cd "$REPO" && git checkout -q -- pkg/sub/AGENTS.md )
}

# brief_path OUTPUT — the brief path from task-brief's "wrote" line.
brief_path() {
    printf '%s\n' "$1" | sed -n 's/^wrote \(.*\): [0-9][0-9]* lines$/\1/p'
}

test_task_brief() {
    echo "--- task-brief ---"
    cat > "$REPO/plan.md" <<'PLAN'
# Plan

### Task 1: Sub change

**Files:**
- Modify: `pkg/sub/widget.js:10-20`
- Test: `pkg/sub/widget.test.js`

Do the sub change.

### Task 2: Root change

**Files:**
- Modify: `README.md`

Do the root change.

### Task 3: No files

Do something without a Files block.

### Task 4: New directory

**Files:**
- Create: `pkg/sub/newdir/new.js`

Create it.
PLAN
    local out brief

    out="$(cd "$REPO" && "$SDD_SCRIPTS/task-brief" plan.md 1)"
    brief="$(brief_path "$out")"
    assert_contains "$brief" "Do the sub change." "brief keeps the task text"
    assert_has_line "$brief" "     2  NESTED_RULE: never read a whole collection in one call." "Modify path with a line range gets nested rules"
    assert_has_line "$brief" "     2  ROOT_RULE: keep functions small." "brief gets root rules"
    assert_not_contains "$brief" "SIBLING_RULE" "brief excludes unrelated directories"
    assert_not_contains "$brief" "Do the root change." "brief stops at the next task"

    out="$(cd "$REPO" && "$SDD_SCRIPTS/task-brief" plan.md 2)"
    brief="$(brief_path "$out")"
    assert_contains "$brief" "ROOT_RULE" "root-level file gets root rules"
    assert_not_contains "$brief" "NESTED_RULE" "root-level file excludes nested rules"

    out="$(cd "$REPO" && "$SDD_SCRIPTS/task-brief" plan.md 3)"
    brief="$(brief_path "$out")"
    assert_not_contains "$brief" "## Instruction files" "no Files block, no section"

    out="$(cd "$REPO" && "$SDD_SCRIPTS/task-brief" plan.md 4)"
    brief="$(brief_path "$out")"
    assert_contains "$brief" "NESTED_RULE" "Create path in a new directory gets ancestor rules"

    mkdir -p "$TEST_ROOT/nogit"
    cp "$REPO/plan.md" "$TEST_ROOT/nogit/plan.md"
    if ( cd "$TEST_ROOT/nogit" && GIT_CEILING_DIRECTORIES="$TEST_ROOT" \
            "$SDD_SCRIPTS/task-brief" plan.md 1 brief.md ) >/dev/null 2>&1 \
        && ! grep -qF "## Instruction files" "$TEST_ROOT/nogit/brief.md"; then
        pass "outside a git repo: brief written, no section"
    else
        fail "outside a git repo: brief written, no section"
    fi
}

main() {
    echo "=== Test: sdd review context ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT

    make_fixture
    test_instruction_files
    test_review_package
    test_task_brief

    echo ""
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "FAILED: $FAILURES assertion(s)."
        exit 1
    fi
    echo "PASS"
}

main "$@"
