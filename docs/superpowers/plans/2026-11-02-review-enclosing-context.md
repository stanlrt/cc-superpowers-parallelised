# Review Enclosing Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-custom:subagent-driven-development (recommended) or superpowers-custom:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Review packages and task briefs carry every governing AGENTS.md / CLAUDE.md (gathered by script) and each hunk's whole enclosing function, and the reviewer/implementer templates treat both as binding inputs.

**Architecture:** A new shared helper `scripts/instruction-files` walks root → each path's directory and prints the governing instruction files with line numbers. `review-package` calls it against the HEAD tree-ish and widens hunks with `git diff --function-context`, falling back per file to `-U10` over a line cap. `task-brief` calls it on the paths in the brief's `**Files:**` block. Templates gain a binding-instructions rule and one generic checklist item.

**Tech Stack:** bash (3.2-compatible: no `mapfile`, no associative arrays), git, POSIX awk (mawk-compatible), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-02-review-enclosing-context-design.md`

## Global Constraints

- Stack-agnostic: no framework, language, product, or company names in any shipped file (scripts, templates, skill docs, tests). The test fixture uses neutral JavaScript-looking text with no framework identifiers.
- Section heading printed by `instruction-files`: `## Instruction files (binding)` — exact.
- Instruction-file content lines are formatted with awk `printf "%6d  %s\n", NR, $0` (6-wide right-aligned number, two spaces, the line).
- Duplicate heading format: `### <path> — identical to <first path>` (em dash U+2014).
- Capped-file marker, directly above that file's `diff --git` line: `# context capped: <path> (function context over <cap> lines; -U10 shown)`.
- Cap: env `SDD_CONTEXT_CAP`, default `400`, positive integer, else exit 2.
- Checklist sentence, verbatim in every reviewer template and (adapted to first person only where noted) the implementer self-review: "For each piece of new state, effect, resource or side effect, check the unchanged code that encloses or calls it: lifecycle and remount behaviour, reactivity/keying, transaction or request scope, loops and limits. A bug can come from new code placed inside old code."
- A broken instruction-file rule is Important by default; findings cite the rule as `path:line`.
- All scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, LF line endings, executable bit.
- Version: `6.0.4-fork.11`.
- Agent-facing docs state current behaviour only (no "previously", no rename history).

---

### Task 1: `instruction-files` helper

**Files:**
- Create: `skills/subagent-driven-development/scripts/instruction-files`
- Create: `tests/claude-code/test-sdd-review-context.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `instruction-files [--tree TREEISH] PATH...` — PATHs repo-root-relative; works from any cwd inside the repo; prints nothing (exit 0) when no file governs any PATH or no PATH is given; exit 2 on usage error or a bad TREEISH. Test file `tests/claude-code/test-sdd-review-context.sh` with helpers `pass`, `fail`, `assert_contains FILE NEEDLE DESC`, `assert_not_contains FILE NEEDLE DESC`, `assert_has_line FILE LINE DESC`, `filler N PREFIX`, `make_fixture`, globals `REPO`, `TEST_ROOT`, `SDD_SCRIPTS`, `GIT_ID`, and a `main` that later tasks extend.

- [ ] **Step 1: Write the failing test**

Create `tests/claude-code/test-sdd-review-context.sh` (then `chmod +x`):

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-sdd-review-context.sh`
Expected: FAIL lines (instruction-files does not exist: "No such file or directory"), final `FAILED: N assertion(s).`

- [ ] **Step 3: Write the implementation**

Create `skills/subagent-driven-development/scripts/instruction-files` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Print the instruction files (AGENTS.md, CLAUDE.md) that govern a set of
# paths, as one markdown section a reviewer or implementer reads with the
# change. A file governs a path when it sits in the repo root or in any
# directory on the way down to that path's directory.
#
# A nested instruction file holds rules no brief repeats, and a harness loads
# it only when an agent happens to read a file in that directory. Gathering
# the files by script, not by memory, puts every governing rule in front of
# the subagent.
#
# Usage: instruction-files [--tree TREEISH] PATH...
#   PATH            repo-root-relative path. It need not exist: a file a task
#                   will create still gets the files of its existing ancestors.
#   --tree TREEISH  read the instruction files from this tree (a commit, or a
#                   `snapshot` tree SHA) instead of the working tree.
#
# Output: nothing when no instruction file governs any PATH. Otherwise a
# "## Instruction files (binding)" section: the file paths (root first, then
# by depth), then each file's content with line numbers, so a finding can
# cite path:line. A file byte-identical to one already printed gets a heading
# that names the first file instead of its content. `@file` imports are not
# resolved.
set -euo pipefail

usage() {
  echo "usage: instruction-files [--tree TREEISH] PATH..." >&2
  exit 2
}

tree=""
if [ "${1:-}" = "--tree" ]; then
  [ $# -ge 2 ] || usage
  tree=$2
  shift 2
  git rev-parse --verify --quiet "${tree}^{tree}" >/dev/null || { echo "bad TREEISH: $tree" >&2; exit 2; }
fi

cd "$(git rev-parse --show-toplevel)"

# is_file PATH — true when PATH is a regular file in the source.
is_file() {
  if [ -n "$tree" ]; then
    [ "$(git cat-file -t "${tree}:$1" 2>/dev/null)" = blob ]
  else
    [ -f "$1" ]
  fi
}

# show PATH — print PATH's content from the source.
show() {
  if [ -n "$tree" ]; then
    git cat-file blob "${tree}:$1"
  else
    cat -- "$1"
  fi
}

# blob_id PATH — git blob SHA of PATH's content; equal SHAs mean equal bytes.
blob_id() {
  if [ -n "$tree" ]; then
    git rev-parse "${tree}:$1"
  else
    git hash-object -- "$1"
  fi
}

# candidates PATH... — AGENTS.md and CLAUDE.md in the root and in every
# directory on the way down to each PATH's directory, one per line.
candidates() {
  local p d acc part
  local parts
  for p in "$@"; do
    p=${p#./}
    printf '%s\n' AGENTS.md CLAUDE.md
    d=$(dirname -- "$p")
    [ "$d" = . ] && continue
    acc=""
    IFS=/ read -r -a parts <<< "$d"
    for part in "${parts[@]}"; do
      acc=${acc:+$acc/}$part
      printf '%s\n' "$acc/AGENTS.md" "$acc/CLAUDE.md"
    done
  done
}

tab=$(printf '\t')
found=()
while IFS= read -r f; do
  if is_file "$f"; then
    found+=("$f")
  fi
done < <(candidates "$@" | awk -F/ '{ print NF "\t" $0 }' | LC_ALL=C sort -t "$tab" -k1,1n -k2 -u | cut -f2-)

if [ ${#found[@]} -eq 0 ]; then
  exit 0
fi

echo "## Instruction files (binding)"
echo
echo "These files govern the files in scope. Their rules are binding constraints."
echo "Cite a rule as path:line."
echo
for f in "${found[@]}"; do
  echo "- $f"
done

seen_ids=()
seen_paths=()
for f in "${found[@]}"; do
  id=$(blob_id "$f")
  dup=""
  i=0
  while [ "$i" -lt "${#seen_ids[@]}" ]; do
    if [ "${seen_ids[$i]}" = "$id" ]; then
      dup=${seen_paths[$i]}
      break
    fi
    i=$((i + 1))
  done
  echo
  if [ -n "$dup" ]; then
    echo "### $f — identical to $dup"
  else
    echo "### $f"
    show "$f" | awk '{ printf "%6d  %s\n", NR, $0 }'
    seen_ids+=("$id")
    seen_paths+=("$f")
  fi
done
```

Note: `[ "$d" = . ] && continue` inside the `for` is safe under `set -e` (a non-final `&&` operand). If shellcheck or a bash 3.2 run complains about `"${#seen_ids[@]}"` on an empty array under `set -u`, initialise with `seen_ids=()` (already done) — `${#arr[@]}` is valid on an empty declared array.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/claude-code/test-sdd-review-context.sh`
Expected: every line `[PASS]`, final line `PASS`.
Also run: `bash tests/claude-code/test-sdd-workspace.sh` → `PASS` (unchanged scripts, sanity).

- [ ] **Step 5: Hand back for review (no commit — the controller commits).**

---

### Task 2: `review-package` — instruction files and enclosing context

**Files:**
- Modify: `skills/subagent-driven-development/scripts/review-package` (whole file)
- Modify: `tests/claude-code/test-sdd-review-context.sh` (add `make_change`, `package_path`, `test_review_package`; call it from `main`)

**Interfaces:**
- Consumes: `instruction-files [--tree TREEISH] PATH...` (Task 1); test helpers from Task 1.
- Produces: package layout — header lines, `## Files changed`, optional `## Instruction files (binding)` section, `## Diff`. Header always contains `# Context: each hunk shows its whole enclosing function (cap: <cap> lines per file)`; when any file is capped, also `# Context capped (-U10 shown): <path> <path>...`. The `wrote <path>: N file(s) changed, B bytes` stdout line is unchanged.

- [ ] **Step 1: Write the failing test**

In `tests/claude-code/test-sdd-review-context.sh`, add these functions after `test_instruction_files`:

```bash
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
```

In `main`, add `test_review_package` on the line after `test_instruction_files`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-sdd-review-context.sh`
Expected: `--- review-package ---` assertions FAIL (no instruction section, no `# Context:` header, `farMarker` absent at default `-U10`), final `FAILED: N assertion(s).`

- [ ] **Step 3: Write the implementation**

Replace `skills/subagent-driven-development/scripts/review-package` with:

```bash
#!/usr/bin/env bash
# Generate a review package: a stat summary, the instruction files that
# govern the changed files, and the net diff with each hunk widened to its
# enclosing function, written to a file the reviewer reads in one call.
#
# This fork runs the no-commit model: implementer subagents leave their work
# in the working tree and the controller commits after review. BASE and HEAD
# are therefore tree-ish (tree SHAs from `scripts/snapshot` or `HEAD^{tree}`),
# not commits — though plain commits still work, since `git diff A B` accepts
# either. There is no commit list to show because the task is not yet
# committed.
#
# Instruction files: every AGENTS.md / CLAUDE.md from the repo root down to
# each changed file's directory, read from HEAD (the tree under review, not
# the working tree, which in a parallel batch holds other tasks' edits), via
# the sibling `instruction-files` helper.
#
# Context: each file's diff uses `git diff --function-context`, so a hunk
# shows its whole enclosing function as git's funcname rule (or the repo's
# .gitattributes diff driver) finds it. When a file's function-context diff
# is over the cap and its -U10 diff is smaller, the package shows the -U10
# diff for that file, marked with a "# context capped:" line.
# Cap: SDD_CONTEXT_CAP lines per file (default 400).
#
# Usage: review-package BASE HEAD [-- PATHSPEC...]
#   BASE        tree-ish before the task (e.g. HEAD^{tree}, or a snapshot SHA)
#   HEAD        tree-ish after the task  (e.g. `scripts/snapshot` output)
#   -- PATHSPEC limit the diff to these paths — use for one task inside a
#               parallel disjoint-file batch, so each reviewer sees only its
#               task's files even though all batch work sits in one tree.
#
# OUTFILE is auto-named under the SDD workspace (<repo-root>/.superpowers/sdd/,
# resolved via the sibling `sdd-workspace` helper so every SDD script agrees on
# one location) — unique per range (and per pathspec), so concurrent sessions
# and parallel per-task reviews never collide and a re-review after fixes
# always gets a distinctly named file.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: review-package BASE HEAD [-- PATHSPEC...]" >&2
  exit 2
fi

base=$1
head=$2
shift 2

paths=()
if [ $# -gt 0 ]; then
  if [ "$1" = "--" ]; then
    shift
    paths=("$@")
  else
    echo "usage: review-package BASE HEAD [-- PATHSPEC...]" >&2
    exit 2
  fi
fi

cap=${SDD_CONTEXT_CAP:-400}
case $cap in
  ''|*[!0-9]*|0) echo "SDD_CONTEXT_CAP must be a positive integer: $cap" >&2; exit 2 ;;
esac

git rev-parse --verify --quiet "$base^{tree}" >/dev/null 2>&1 || git rev-parse --verify --quiet "$base" >/dev/null || { echo "bad BASE: $base" >&2; exit 2; }
git rev-parse --verify --quiet "$head^{tree}" >/dev/null 2>&1 || git rev-parse --verify --quiet "$head" >/dev/null || { echo "bad HEAD: $head" >&2; exit 2; }

scripts=$(cd "$(dirname "$0")" && pwd)
dir=$("$scripts/sdd-workspace")
name="review-$(git rev-parse --short "$base")..$(git rev-parse --short "$head")"
if [ ${#paths[@]} -gt 0 ]; then
  # Keep the file unique when several per-task reviews share one BASE..HEAD
  # range but cover different files (a parallel batch).
  suffix=$(printf '%s\n' "${paths[@]}" | cksum | cut -d' ' -f1)
  name="${name}-${suffix}"
fi
out="$dir/${name}.diff"

tmp=$(mktemp -d "$dir/review-package.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

changed=()
while IFS= read -r f; do
  changed+=("$f")
done < <(git diff --name-only "$base" "$head" ${paths[@]:+-- "${paths[@]}"})

"$scripts/instruction-files" --tree "$head" ${changed[@]+"${changed[@]}"} > "$tmp/instr"

git diff --function-context -U10 "$base" "$head" ${paths[@]:+-- "${paths[@]}"} > "$tmp/wide"
git diff -U10 "$base" "$head" ${paths[@]:+-- "${paths[@]}"} > "$tmp/plain"

# Both diffs cover the same range and pathspec, so they list the same files
# in the same order. Pair them file by file and keep the function-context
# chunk unless it is over the cap and the -U10 chunk is smaller (a new or
# fully rewritten file has equal chunks and keeps its full text).
: > "$tmp/capped"
awk -v cap="$cap" -v capped="$tmp/capped" '
  FNR == 1 { src++ }
  /^diff --git / { n[src]++ }
  n[src] { text[src, n[src]] = text[src, n[src]] $0 "\n"; len[src, n[src]]++ }
  END {
    for (i = 1; i <= n[1]; i++) {
      if (len[1, i] > cap && len[2, i] < len[1, i]) {
        hdr = text[2, i]
        sub(/\n.*/, "", hdr)
        path = hdr
        sub(/^diff --git a\/.* b\//, "", path)
        printf "# context capped: %s (function context over %d lines; -U10 shown)\n", path, cap
        printf "%s", text[2, i]
        print path > capped
      } else {
        printf "%s", text[1, i]
      }
    }
  }
' "$tmp/wide" "$tmp/plain" > "$tmp/diff"

{
  echo "# Review package: ${base}..${head}"
  if [ ${#paths[@]} -gt 0 ]; then
    echo "# Scoped to: ${paths[*]}"
  fi
  echo "# (no-commit model: changes are uncommitted in the working tree)"
  echo "# Context: each hunk shows its whole enclosing function (cap: ${cap} lines per file)"
  if [ -s "$tmp/capped" ]; then
    echo "# Context capped (-U10 shown): $(paste -sd' ' "$tmp/capped")"
  fi
  echo
  echo "## Files changed"
  git diff --stat "$base" "$head" ${paths[@]:+-- "${paths[@]}"}
  echo
  if [ -s "$tmp/instr" ]; then
    cat "$tmp/instr"
    echo
  fi
  echo "## Diff"
  cat "$tmp/diff"
} > "$out"

echo "wrote ${out}: ${#changed[@]} file(s) changed, $(wc -c < "$out" | tr -d ' ') bytes"
```

Note on the awk: when `$tmp/wide` is empty (no changes) the first line read is from `$tmp/plain`, but then `plain` is empty too, so `n[1]` is unset and nothing prints. If the implementer finds `paste -sd' '` unavailable on a target, `tr '\n' ' '` plus trailing-space trim is equivalent.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/claude-code/test-sdd-review-context.sh` → final `PASS`.
Run: `bash tests/claude-code/test-sdd-workspace.sh` → final `PASS` (its `wrote ... : [0-9]` parse still matches).

- [ ] **Step 5: Hand back for review (no commit — the controller commits).**

---

### Task 3: `task-brief` — instruction files of the task's files

**Files:**
- Modify: `skills/subagent-driven-development/scripts/task-brief` (whole file)
- Modify: `tests/claude-code/test-sdd-review-context.sh` (add `brief_path`, `test_task_brief`; call it from `main` after `test_review_package`)

**Interfaces:**
- Consumes: `instruction-files PATH...` (Task 1); test helpers (Tasks 1–2).
- Produces: briefs end with the `## Instruction files (binding)` section when the task's `**Files:**` block names a governed path. The `wrote <path>: N lines` stdout line is unchanged.

- [ ] **Step 1: Write the failing test**

Add after `test_review_package`:

```bash
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
```

In `main`, add `test_task_brief` on the line after `test_review_package`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-sdd-review-context.sh`
Expected: `--- task-brief ---` rule assertions FAIL, final `FAILED: N assertion(s).`

- [ ] **Step 3: Write the implementation**

Replace `skills/subagent-driven-development/scripts/task-brief` with:

```bash
#!/usr/bin/env bash
# Extract one task's full text from an implementation plan into a file the
# implementer reads in one call, so the task text never has to be pasted
# through the controller's context.
#
# The brief ends with the instruction files (AGENTS.md / CLAUDE.md) that
# govern the task's files: every backticked path on a list line of the
# task's **Files:** block (a trailing :N or :N-M line range is stripped),
# resolved by the sibling `instruction-files` helper against the working
# tree. No Files block, no governing file, or no git repo: no section.
#
# Usage: task-brief PLAN_FILE TASK_NUMBER [OUTFILE]
# Default OUTFILE: <repo-root>/.superpowers/sdd/task-<N>-brief.md
# (per worktree; concurrent runs in the same working tree share it).
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: task-brief PLAN_FILE TASK_NUMBER [OUTFILE]" >&2
  exit 2
fi

plan=$1
n=$2
[ -f "$plan" ] || { echo "no such plan file: $plan" >&2; exit 2; }

scripts=$(cd "$(dirname "$0")" && pwd)

if [ $# -eq 3 ]; then
  out=$3
else
  dir=$("$scripts/sdd-workspace")
  out="$dir/task-${n}-brief.md"
fi

awk -v n="$n" '
  /^```/ { infence = !infence }
  !infence && /^#+[ \t]+Task[ \t]+[0-9]+/ {
    intask = ($0 ~ ("^#+[ \t]+Task[ \t]+" n "([^0-9]|$)"))
  }
  intask { print }
' "$plan" > "$out"

if [ ! -s "$out" ]; then
  echo "task ${n} not found in ${plan} (no heading matching 'Task ${n}')" >&2
  exit 3
fi

files=()
while IFS= read -r f; do
  files+=("$f")
done < <(awk '
  /^\*\*Files:\*\*/ { inblock = 1; next }
  inblock && /^[ \t]*[-*][ \t]/ {
    line = $0
    while (match(line, /`[^`]+`/)) {
      tok = substr(line, RSTART + 1, RLENGTH - 2)
      sub(/:[0-9]+(-[0-9]+)?$/, "", tok)
      print tok
      line = substr(line, RSTART + RLENGTH)
    }
    next
  }
  inblock && /^[ \t]*$/ { next }
  { inblock = 0 }
' "$out")

if [ ${#files[@]} -gt 0 ] && git rev-parse --show-toplevel >/dev/null 2>&1; then
  section=$("$scripts/instruction-files" "${files[@]}")
  if [ -n "$section" ]; then
    printf '\n%s\n' "$section" >> "$out"
  fi
fi

echo "wrote ${out}: $(wc -l < "$out" | tr -d ' ') lines"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/claude-code/test-sdd-review-context.sh` → final `PASS`.
Run: `bash tests/claude-code/test-sdd-workspace.sh` → final `PASS`.

- [ ] **Step 5: Hand back for review (no commit — the controller commits).**

---

### Task 4: Templates and skill docs

**Files:**
- Modify: `skills/subagent-driven-development/task-reviewer-prompt.md`
- Modify: `skills/subagent-driven-development/implementer-prompt.md`
- Modify: `skills/subagent-driven-development/refactor-reviewer-prompt.md`
- Modify: `skills/requesting-code-review/code-reviewer.md`
- Modify: `skills/requesting-code-review/SKILL.md`
- Modify: `skills/subagent-driven-development/SKILL.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: the package/brief formats from the Global Constraints (`## Instruction files (binding)`, `# context capped:`, `SDD_CONTEXT_CAP`). No code dependency on Tasks 1–3.
- Produces: nothing other tasks use.

Verification for this task is textual: after the edits, run the greps in Step 8.

- [ ] **Step 1: `task-reviewer-prompt.md`**

(a) In `## Diff Under Review`, replace

```
    commit list. The diff's context lines ARE the changed files: do not Read a
    changed file separately unless a hunk you must judge is cut off
    mid-function — and say so in your report. Do not re-run git commands.
```

with

```
    commit list. Each hunk shows its whole enclosing function; a file marked
    `# context capped` shows 10 lines of context instead. Do not Read a
    changed file separately unless a hunk you must judge is cut off — and
    say so in your report. Do not re-run git commands.
```

(b) Directly after the line `    checking the call sites is the right method.` insert:

```
    New code inside unchanged code is a named risk by default: when new
    state, an effect, a resource, or a side effect sits inside or is called
    from code the diff does not show (a capped file, a caller), one focused
    read of that code is expected.
```

(c) Insert a new section directly before `    ## Do Not Trust the Report`:

```
    ## Binding Instructions

    The diff file's "Instruction files (binding)" section holds every
    AGENTS.md / CLAUDE.md that governs the changed files, with line numbers.
    Their rules bind this task like the spec does. A change that breaks one
    is an Important finding by default: cite the rule as path:line next to
    the code's file:line.

```

(d) In `## Part 2: Code Quality`, under `**Code quality:**`, after `    - Edge cases handled?` add:

```
    - For each piece of new state, effect, resource or side effect, check the
      unchanged code that encloses or calls it: lifecycle and remount
      behaviour, reactivity/keying, transaction or request scope, loops and
      limits. A bug can come from new code placed inside old code.
```

(e) In the `**Placeholders:**` list, replace the `[DIFF_FILE]` bullet's text `wrote; the package never enters the controller's context)` with `wrote; the package never enters the controller's context). It carries the governing instruction files and each hunk's enclosing function.`

- [ ] **Step 2: `implementer-prompt.md`**

(a) Replace

```
    Read your task brief first: [BRIEF_FILE]
    It contains the full task text from the plan.
```

with

```
    Read your task brief first: [BRIEF_FILE]
    It contains the full task text from the plan. Its "Instruction files
    (binding)" section, when present, holds the AGENTS.md / CLAUDE.md rules
    that govern your files. Follow them like the task text. When a rule
    shaped a decision or ruled out an approach, cite it (path:line) in your
    report.
```

(b) In `## Before Reporting Back: Self-Review`, under `**Quality:**`, after `    - Is the code clean and maintainable?` add:

```
    - For each piece of new state, effect, resource or side effect, did I
      check the unchanged code that encloses or calls it: lifecycle and
      remount behaviour, reactivity/keying, transaction or request scope,
      loops and limits? A bug can come from new code placed inside old code.
```

- [ ] **Step 3: `refactor-reviewer-prompt.md`**

(a) In `## The Branch Under Review`, after the paragraph ending ``and `git diff [BASE_SHA]..[HEAD_SHA]`.`` add a blank line and:

```
    The diff file's "Instruction files (binding)" section holds every
    AGENTS.md / CLAUDE.md that governs the changed files, with line numbers.
    A branch change that breaks one of their rules is Refactor-Critical: the
    cited rule (path:line) is the evidence.
```

(b) In `## Design lens (Advisory findings)`, after the bullet `    - Naming drift — the same concept named differently across tasks` add:

```
    - For each piece of new state, effect, resource or side effect, check the
      unchanged code that encloses or calls it: lifecycle and remount
      behaviour, reactivity/keying, transaction or request scope, loops and
      limits. A bug can come from new code placed inside old code.
```

- [ ] **Step 4: `requesting-code-review/code-reviewer.md`**

(a) Replace the block

```
    ## Git Range to Review

    **Base:** [BASE_SHA]
    **Head:** [HEAD_SHA]

    ```bash
    git diff --stat [BASE_SHA]..[HEAD_SHA]
    git diff [BASE_SHA]..[HEAD_SHA]
    ```
```

with

```
    ## Git Range to Review

    **Base:** [BASE_SHA]
    **Head:** [HEAD_SHA]
    **Diff file:** [DIFF_FILE]

    Read the diff file once: a stat summary, the instruction files that
    govern the changed files, and the diff with each hunk's whole enclosing
    function (a file marked `# context capped` shows 10 lines instead). If
    no diff file was given, fetch the diff yourself:

    ```bash
    git diff --stat [BASE_SHA]..[HEAD_SHA]
    git diff --function-context [BASE_SHA]..[HEAD_SHA]
    ```

    and read every AGENTS.md / CLAUDE.md from the repo root down to each
    changed file's directory.

    ## Binding Instructions

    The rules in those instruction files bind this change like the plan
    does. A change that breaks one is an Important finding by default: cite
    the rule as path:line next to the code's file:line.
```

(b) Under `**Code quality:**`, after `    - Edge cases handled?` add:

```
    - For each piece of new state, effect, resource or side effect, check the
      unchanged code that encloses or calls it: lifecycle and remount
      behaviour, reactivity/keying, transaction or request scope, loops and
      limits. A bug can come from new code placed inside old code. This is a
      named risk by default: one focused read of enclosing code the diff
      does not show is expected.
```

(c) In the `**Placeholders:**` list after the template, add:

```
- `[DIFF_FILE]` — the review package path (`../subagent-driven-development/scripts/review-package BASE_SHA HEAD_SHA` prints it). Omit only when the script cannot run; the template's fallback then applies.
```

- [ ] **Step 5: `requesting-code-review/SKILL.md`**

(a) In `## How to Request`, after the step-1 code block (ends with `HEAD_SHA=$(git rev-parse HEAD)` and the closing fence) insert:

````
**2. Build the review package:**
```bash
../subagent-driven-development/scripts/review-package "$BASE_SHA" "$HEAD_SHA"
```
(Path relative to this skill's directory.) It prints the package path:
the stat summary, the AGENTS.md / CLAUDE.md files that govern the changed
files, and the diff with each hunk's whole enclosing function. It writes
under the self-ignored `<repo-root>/.superpowers/sdd/`.
````

(b) Renumber the following steps: `**2. Dispatch code reviewer subagent:**` → `**3. ...**`, `**3. Act on feedback:**` → `**4. ...**`.

(c) In that section's `**Placeholders:**` list, after the `{HEAD_SHA}` bullet add:

```
- `{DIFF_FILE}` - Review package path from step 2
```

(d) In `## Example`, after the line `HEAD_SHA=$(git rev-parse HEAD)` insert a line `DIFF_FILE=$(../subagent-driven-development/scripts/review-package "$BASE_SHA" "$HEAD_SHA" | sed -n 's/^wrote \(.*\): .*/\1/p')`, and under `[Dispatch code reviewer subagent]` after `  HEAD_SHA: 3df7661` add `  DIFF_FILE: .superpowers/sdd/review-a7981ec..3df7661.diff`.

- [ ] **Step 6: `subagent-driven-development/SKILL.md`**

(a) Replace

```
3. `scripts/review-package "$BASE" "$AFTER"` (add `-- <this task's files>` when the task is one of a parallel batch) — it prints the unique diff path.
```

with

```
3. `scripts/review-package "$BASE" "$AFTER"` (add `-- <this task's files>` when the task is one of a parallel batch) — it prints the unique diff path. The package carries the AGENTS.md / CLAUDE.md files that govern the changed files (read from `$AFTER`) and widens each hunk to its enclosing function; a file whose function context exceeds `SDD_CONTEXT_CAP` lines (default 400) falls back to `-U10` and is marked `# context capped`.
```

(b) Replace

```
  uncommitted) — that is expected. Without bash: `git diff --stat BASE AFTER`
  and `git diff -U10 BASE AFTER` redirected to one uniquely named file.
```

with

```
  uncommitted) — that is expected. Without bash: `git diff --stat BASE AFTER`
  and `git diff --function-context BASE AFTER` redirected to one uniquely
  named file, plus every AGENTS.md / CLAUDE.md from the repo root down to
  each changed file's directory appended to it.
```

(c) Replace

```
  `scripts/task-brief PLAN_FILE N` — it extracts the task's full text to a
  uniquely named file and prints the path. Every dispatch is the implementer
```

with

```
  `scripts/task-brief PLAN_FILE N` — it extracts the task's full text to a
  uniquely named file and prints the path. The brief ends with the
  AGENTS.md / CLAUDE.md files that govern the paths in the task's
  **Files:** block; they bind the implementer. Every dispatch is the implementer
```

- [ ] **Step 7: `AGENTS.md` (fork notes)**

In the `subagent-driven-development` bullet, after the sentence ending `so controllers stop over-serializing "related" tasks.` add (same indentation, two leading spaces):

```
  Review packages and task briefs carry the AGENTS.md / CLAUDE.md files on
  the path from the repo root to each changed (or brief-listed) file,
  gathered by `scripts/instruction-files`; review packages also widen each
  hunk to its enclosing function (`git diff --function-context`, capped per
  file by `SDD_CONTEXT_CAP`). Reviewer and implementer templates treat those
  files as binding and check new code against the unchanged code that
  encloses it. `tests/claude-code/test-sdd-review-context.sh` covers the
  scripts and runs in CI.
```

In the `requesting-code-review / verification-before-completion` bullet, append the sentence: `The code reviewer reads a review package built by the SDD `review-package` script.`

- [ ] **Step 8: Verify**

Run:
```bash
grep -c "A bug can come from new code placed inside old code" \
  skills/subagent-driven-development/task-reviewer-prompt.md \
  skills/subagent-driven-development/implementer-prompt.md \
  skills/subagent-driven-development/refactor-reviewer-prompt.md \
  skills/requesting-code-review/code-reviewer.md
grep -rn "Instruction files (binding)" skills | wc -l
grep -rniE "solid|convex|react|vue|svelte|angular" skills/subagent-driven-development/*.md skills/requesting-code-review/*.md || echo "no stack names"
grep -rIoE 'superpowers:[a-z-]+' skills hooks || echo "namespace clean"
```
Expected: each of the 4 files prints `1`; the instruction-section count is ≥ 4; `no stack names`; `namespace clean`. (If the stack-name grep hits pre-existing upstream text, confirm the hit is not from this task's edits.)

- [ ] **Step 9: Hand back for review (no commit — the controller commits).**

---

### Task 5: CI step and version bump

**Files:**
- Modify: `.github/workflows/release-checks.yml`
- Modify (via script): `package.json`, `.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, `.kimi-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `gemini-extension.json`

**Interfaces:**
- Consumes: `tests/claude-code/test-sdd-review-context.sh` (Task 1 creates it).
- Produces: nothing.

- [ ] **Step 1: Add the CI step**

In `.github/workflows/release-checks.yml`, after the `Check versions, manifests, namespace, and line endings` step (end of file), append:

```yaml

      - name: SDD script tests
        run: |
          bash tests/claude-code/test-sdd-workspace.sh
          bash tests/claude-code/test-sdd-review-context.sh
```

(Same indentation as the existing `- name:` step: six spaces before `-`.)

- [ ] **Step 2: Bump the version**

Run: `bash scripts/bump-version.sh 6.0.4-fork.11`
Then: `bash scripts/bump-version.sh --check` → no drift reported.

- [ ] **Step 3: Verify**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release-checks.yml'))" && echo yaml-ok` (skip if PyYAML is missing; then eyeball the indentation).
Run: `jq -r .version .claude-plugin/plugin.json` → `6.0.4-fork.11`.

- [ ] **Step 4: Hand back for review (no commit — the controller commits).**
