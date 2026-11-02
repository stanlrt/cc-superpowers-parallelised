# Review and implementer context: nested instructions and enclosing code

## Problem

Reviewer and implementer subagents look at hunks, not at the code the hunks
land in. Two real misses on a downstream project, both caught by an external
bot and missed by eight reviewer passes:

1. A new scheduled mutation read a whole table into memory. The rule against
   that lived only in a nested instruction file (`<subdir>/AGENTS.md`). No
   brief or reviewer read it.
2. A task moved component-local state into a child component. The child sat
   inside an existing keyed wrapper (an unchanged line) that remounts on every
   data refetch, so the state was lost. The diff-scoped reviewer saw the
   wrapper only as context and praised it.

Both bugs come from new code meeting unchanged code. The fix gives
subagents (a) every instruction file that governs the files they touch,
gathered by script, and (b) the enclosing function or component of every
hunk, not just ten lines around it.

## Constraint: stack-agnostic

The skills ship to every stack. Templates, scripts, and tests carry no
framework, language, or product names. The two misses above motivate the
change; they do not appear in shipped text.

## Design

### 1. `scripts/instruction-files` (new shared helper)

Location: `skills/subagent-driven-development/scripts/instruction-files`,
sibling of `sdd-workspace`. Bash + git only, `set -euo pipefail`, LF.

- **Usage:** `instruction-files [--tree TREEISH] PATH...`
- **Collection:** for each path, walk directories from the repo root down to
  the path's directory. In each directory, collect `AGENTS.md` and
  `CLAUDE.md` if present. A directory that does not exist (a file the task
  will create in a new directory) is skipped; the walk continues so ancestor
  files still apply.
- **Source:** with `--tree TREEISH`, existence and content come from that
  tree (`git cat-file -e` / `git show TREEISH:path`). Without it, from the
  working tree.
- **Order:** unique paths, root first, then by depth, then by name.
- **Output** (stdout; nothing at all when no file is found):

  ```
  ## Instruction files (binding)

  These files govern the changed files. Their rules are binding constraints.
  Cite a rule as path:line.

  - AGENTS.md
  - pkg/sub/AGENTS.md
  - pkg/sub/CLAUDE.md

  ### AGENTS.md
       1  <line>
       2  <line>

  ### pkg/sub/AGENTS.md
       1  <line>

  ### pkg/sub/CLAUDE.md — identical to pkg/sub/AGENTS.md
  ```

  Contents carry original line numbers, so a reviewer cites `file:line`
  without a separate read. Byte-identical files (same blob SHA in tree mode,
  same checksum in working-tree mode) print once; later duplicates print the
  "identical to" heading only.
- **Out of scope:** resolving `@file` imports. A one-line `@AGENTS.md`
  `CLAUDE.md` is inlined as-is.

### 2. `scripts/review-package`

- **Instruction files:** call `instruction-files --tree HEAD` with the
  changed paths (honouring `-- PATHSPEC`). Read from the HEAD tree-ish, not
  the working tree: in a parallel batch the working tree holds other tasks'
  edits, and a task that edits an instruction file is reviewed against the
  new text.
- **Section order:** header, `## Files changed`, `## Instruction files
  (binding)`, `## Diff`.
- **Enclosing context:** run `git diff --function-context -U10` once and
  `git diff -U10` once over the same range and pathspec. Split both on
  `^diff --git ` into per-file chunks (rename pairing preserved). Per file,
  use the function-context chunk, except when it exceeds the cap **and** the
  plain chunk is smaller; then use the plain chunk. A new or fully rewritten
  file has equal chunks and is never marked capped.
- **Cap:** default 400 lines per file chunk; env `SDD_CONTEXT_CAP`
  overrides.
- **Capped marking:** a line `# context capped: <path> (function context
  over N lines; -U10 shown)` directly above that file's `diff --git` line,
  and a header line listing every capped file.
- **No language assumptions:** function context comes from git's default
  funcname rule (enclosing column-0 declaration) or the repo's own
  `.gitattributes` diff drivers. Indented declarations (class methods) can
  widen to a whole class; the cap bounds that.

### 3. `scripts/task-brief`

After extracting the task, parse its `**Files:**` block: every backticked
token on a list line, with a trailing `:N` or `:N-M` stripped. Append the
`instruction-files` output (working-tree mode) to the brief. No `Files:`
block or no instruction file found: no section, exit 0.

### 4. Templates (generic wording only)

`task-reviewer-prompt.md`, `requesting-code-review/code-reviewer.md`,
`refactor-reviewer-prompt.md`:

- The package's Instruction files section is binding. A violation is
  Important by default. Cite the rule as `path:line` next to the code
  `file:line`.
- Checklist item, verbatim: "For each piece of new state, effect, resource
  or side effect, check the unchanged code that encloses or calls it:
  lifecycle and remount behaviour, reactivity/keying, transaction or request
  scope, loops and limits. A bug can come from new code placed inside old
  code."
- The enclosing-code check is a named risk by default (one sentence added to
  the existing "one focused check per named risk" allowance). A file marked
  `context capped` is the expected case for that one focused read.

`implementer-prompt.md`:

- The brief's instruction files are binding. When a rule shaped a decision
  or ruled out an approach, cite it (`path:line`) in the report.
- Self-review adds the same new-code-inside-old-code check.

`requesting-code-review/SKILL.md`: before dispatch, run
`../subagent-driven-development/scripts/review-package BASE HEAD` and pass
the printed path as `[DIFF_FILE]`. Running it outside SDD creates the
self-ignored `<repo-root>/.superpowers/sdd/`. `code-reviewer.md` keeps the
raw `git diff` commands as fallback when no package is given.

### 5. Docs

- `subagent-driven-development/SKILL.md`: describe the package contents
  (instruction files, enclosing context, cap) and the brief's instruction
  section where review packages and briefs are described.
- `AGENTS.md` (fork notes): add the divergence, present tense.

### 6. Tests and CI

New `tests/claude-code/test-sdd-review-context.sh`, modelled on
`test-sdd-workspace.sh` (mktemp, physical-path resolution,
`-c commit.gpgsign=false`). Fixture repo, no `.gitattributes`:

- root `AGENTS.md`; nested `pkg/sub/AGENTS.md` with a distinctive rule;
  sibling `pkg/other/AGENTS.md`; `pkg/sub/CLAUDE.md` byte-identical to
  `pkg/sub/AGENTS.md`.
- `pkg/sub/widget.js`: a column-0 function whose changed line sits more than
  10 lines below its opening line and above its closing line, inside an
  unchanged wrapping block; a second, long function.

Assertions:

- package contains root and nested rule text with line numbers;
  sibling text absent; CLAUDE.md shown as identical, not repeated.
- package contains the first function's opening and closing lines.
- with a small `SDD_CONTEXT_CAP`, the long function's file is marked capped
  and its far lines are absent.
- `-- pathspec` run collects only scoped files' instruction files.
- an uncommitted edit to `pkg/sub/AGENTS.md`, captured by `snapshot`,
  appears in the package.
- `task-brief` with ``Modify: `pkg/sub/widget.js:10-20` `` and a `Create:`
  path in a new directory under `pkg/sub/` includes the nested rule text.

`.github/workflows/release-checks.yml`: a step runs
`test-sdd-workspace.sh` and `test-sdd-review-context.sh` directly (not
`run-skill-tests.sh`, which needs a live `claude`).

### 7. Release

Version `6.0.4-fork.11` via `bash scripts/bump-version.sh`;
`bash scripts/check-release.sh origin/main` passes; PR to `main`.
