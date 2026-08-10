---
name: finishing-a-development-branch
description: Use when implementation is complete, all tests pass, and you need to decide how to integrate the work - guides completion of development work by presenting structured options for merge, PR, or cleanup
---

# Finishing a Development Branch

## Overview

Guide completion of development work by presenting clear options and handling chosen workflow.

**Core principle:** Verify tests → Detect environment → Present options → Execute choice → Clean up.

**Announce at start:** "I'm using the finishing-a-development-branch skill to complete this work."

## The Process

### Step 1: Verify Tests

**Before presenting options, verify tests pass:**

```bash
# Run project's test suite
npm test / cargo test / pytest / go test ./...
```

**If tests fail:**
```
Tests failing (<N> failures). Must fix before completing:

[Show failures]

Cannot proceed with merge/PR until tests pass.
```

Stop. Don't proceed to Step 2.

**If tests pass:** Continue to Step 1b.

### Step 1b: Surface Deferred Refactor Items

If subagent-driven-development ran, its whole-branch refactor reviewer may
have left design-opinion findings for triage:

```bash
cat "$(git rev-parse --show-toplevel)/.superpowers/sdd/refactor-report.md" 2>/dev/null
```

If the file exists and is non-empty, present each Refactor-Advisory item to
your human partner before presenting the completion options, and get a
decision per item — **fix now** (do it, re-run tests, then continue),
**ticket** (record it — e.g. a TODO or issue — and note where), or **accept**
(leave as-is, on the record). Do not merge or open a PR while unaddressed
advisory items sit unseen; a report nobody reads is a silent discard. If the
file is absent, this skill was reached by another path — continue.

### Step 2: Detect Environment

**Determine workspace state before presenting options:**

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
```

This determines which menu to show and how cleanup works:

| State | Menu | Cleanup |
|-------|------|---------|
| `GIT_DIR == GIT_COMMON` (normal repo) | Standard 4 options | No worktree to clean up |
| `GIT_DIR != GIT_COMMON`, named branch | Standard 4 options | Provenance-based (see Step 6) |
| `GIT_DIR != GIT_COMMON`, detached HEAD | Reduced 3 options (no merge) | No cleanup (externally managed) |

### Step 3: Determine Base Branch

```bash
# Try common base branches
git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null
```

Or ask: "This branch split from main - is that correct?"

### Step 4: Present Options

**Normal repo and named-branch worktree — present exactly these 4 options:**

```
Implementation complete. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (I'll handle it later)
4. Discard this work

Which option?
```

**Detached HEAD — present exactly these 3 options:**

```
Implementation complete. You're on a detached HEAD (externally managed workspace).

1. Push as new branch and create a Pull Request
2. Keep as-is (I'll handle it later)
3. Discard this work

Which option?
```

**Don't add explanation** - keep options concise.

### Step 5: Execute Choice

#### Option 1: Merge Locally

```bash
# Get main repo root for CWD safety
MAIN_ROOT=$(git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel)
cd "$MAIN_ROOT"

# Merge first — verify success before removing anything
git checkout <base-branch>
git pull
git merge <feature-branch>

# Verify tests on merged result
<test command>

# Only after merge succeeds: cleanup worktree (Step 6), then delete branch
```

Then: Cleanup worktree (Step 6), then delete branch:

```bash
git branch -d <feature-branch>
```

#### Option 2: Push and Create PR

**Rebase onto the latest base before pushing.** A branch cut earlier falls
behind while you work — and any PR that merges in the meantime moves the base.
CI diffs your branch against the *current* base, so pushing a stale branch
makes the PR show unrelated files as changed (reverts, phantom scope). Fetch
and rebase first:

```bash
git fetch origin
git rebase origin/<base-branch>          # usually main
# resolve any conflicts, then push
git push -u origin <feature-branch>
```

If the PR then sits open while `<base-branch>` moves again, repeat
`git fetch origin && git rebase origin/<base-branch>` and re-push with
`--force-with-lease` before it can merge.

**Build the PR body from the repo's template, then create with `--body-file`.**

1. If `.github/pull_request_template.md` (or `.github/PULL_REQUEST_TEMPLATE.md`,
   or `docs/pull_request_template.md`) exists, base the body on it. Fill every
   section and **tick every required checklist item** (`- [ ]` → `- [x]`).
   Required-checklist CI jobs fail an un-ticked box, so leaving the template
   default unchecked will block the PR. Leave items tagged `(optional)`
   unchecked only when they genuinely don't apply. Delete any template callout
   that instructs the author to delete it (e.g. a title-format warning).
   If no template exists, fall back to a `## Summary` + `## Test Plan` body.

2. Write the finished body to a file, then pass it with `--body-file` — never
   inline via `--body "..."` or a heredoc. Inline bodies break on apostrophes,
   backticks, and `$()` in shell, and silently drop the template's checklist.

```bash
# Write the filled-in body to a scratch file (use the Write tool, not echo)
gh pr create --title "<title>" --body-file <path-to-body-file>
```

The title must satisfy the repo's PR-title rule (Conventional Commits where
enforced). After creating, delete the scratch body file.

Then monitor CI to completion. **Do not guess a flat wait** — CI duration
varies, so a fixed 3-minute sleep either races the run or wastes time. Poll
the PR's checks on a **30-second interval**, and when they settle, print any
failures in the same pass — don't re-poll by hand to hunt them down:

```bash
PR=<pr-number>
while :; do
  # One gh call per iteration. gh exits non-zero both when checks are pending and
  # when none exist yet, so judge by the output, not the exit code. A real error
  # (auth/network/rate-limit) yields no counts and prints to stderr — surface it
  # and keep looping, rather than silently spinning on "0 checks".
  err=$(mktemp)   # private temp; avoids a predictable /tmp path and concurrent clobber
  counts=$(gh pr checks "$PR" --json bucket \
    -q '"\(length) \([.[] | select(.bucket == "pending")] | length)"' 2>"$err")
  if [ -z "$counts" ]; then
    grep -qiE 'no checks|no commit statuses' "$err" \
      && echo "No checks registered yet — re-checking in 30s" \
      || { echo "gh pr checks failed — re-checking in 30s:" >&2; cat "$err" >&2; }
    rm -f "$err"; sleep 30; continue
  fi
  rm -f "$err"
  total=${counts%% *}; pending=${counts##* }   # portable split (works in bash and zsh)
  [ "$total" -gt 0 ] && [ "$pending" -eq 0 ] && break
  echo "CI not settled yet ($total checks, $pending pending) — re-checking in 30s"
  sleep 30
done

# Settled. If anything failed, dump its logs right here — no second poll.
if gh pr checks "$PR"; then
  echo "CI GREEN"
else
  gh pr checks "$PR" --json bucket,link -q '.[] | select(.bucket=="fail") | .link' \
    | grep -oE '/runs/[0-9]+' | grep -oE '[0-9]+' | sort -u \
    | while read -r run; do echo "=== failed run $run ==="; gh run view "$run" --log-failed; done
fi
```

(If your shell blocks a foreground `sleep`, run the whole block as one
background command and read its output. Never pipe the status command through
`tail`/`head` — `$?` then reports the pipe's last stage, masking `gh`'s
non-zero exit, and you misread a red run as green.) If the block prints
failures, fix the cause, push, and re-enter it — do not proceed until it
prints `CI GREEN`.

Once CI is green, assess the Copilot + Code Quality comments. Fix+resolve
them, or answer why they aren't relevant+resolve them. To resolve Copilot
comments: gh cli. To resolve Code Quality comments: GH GraphQL API via CLI.

**Do NOT clean up worktree** — user needs it alive to iterate on PR feedback.

#### Option 3: Keep As-Is

Report: "Keeping branch <name>. Worktree preserved at <path>."

**Don't cleanup worktree.**

#### Option 4: Discard

**Confirm first:**
```
This will permanently delete:
- Branch <name>
- All commits: <commit-list>
- Worktree at <path>

Type 'discard' to confirm.
```

Wait for exact confirmation.

If confirmed:
```bash
MAIN_ROOT=$(git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel)
cd "$MAIN_ROOT"
```

Then: Cleanup worktree (Step 6), then force-delete branch:
```bash
git branch -D <feature-branch>
```

### Step 6: Cleanup Workspace

**Only runs for Options 1 and 4.** Options 2 and 3 always preserve the worktree.

```bash
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
WORKTREE_PATH=$(git rev-parse --show-toplevel)
```

**If `GIT_DIR == GIT_COMMON`:** Normal repo, no worktree to clean up. Done.

**If worktree path is under `.worktrees/` or `worktrees/`:** Superpowers created this worktree — we own cleanup.

```bash
MAIN_ROOT=$(git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel)
cd "$MAIN_ROOT"
git worktree remove "$WORKTREE_PATH"
git worktree prune  # Self-healing: clean up any stale registrations
```

**Otherwise:** The host environment (harness) owns this workspace. Do NOT remove it. If your platform provides a workspace-exit tool, use it. Otherwise, leave the workspace in place.

## Quick Reference

| Option | Merge | Push | Keep Worktree | Cleanup Branch |
|--------|-------|------|---------------|----------------|
| 1. Merge locally | yes | - | - | yes |
| 2. Create PR | - | yes | yes | - |
| 3. Keep as-is | - | - | yes | - |
| 4. Discard | - | - | - | yes (force) |

## Common Mistakes

**Skipping test verification**
- **Problem:** Merge broken code, create failing PR
- **Fix:** Always verify tests before offering options

**Open-ended questions**
- **Problem:** "What should I do next?" is ambiguous
- **Fix:** Present exactly 4 structured options (or 3 for detached HEAD)

**Cleaning up worktree for Option 2**
- **Problem:** Remove worktree user needs for PR iteration
- **Fix:** Only cleanup for Options 1 and 4

**Deleting branch before removing worktree**
- **Problem:** `git branch -d` fails because worktree still references the branch
- **Fix:** Merge first, remove worktree, then delete branch

**Running git worktree remove from inside the worktree**
- **Problem:** Command fails silently when CWD is inside the worktree being removed
- **Fix:** Always `cd` to main repo root before `git worktree remove`

**Cleaning up harness-owned worktrees**
- **Problem:** Removing a worktree the harness created causes phantom state
- **Fix:** Only clean up worktrees under `.worktrees/` or `worktrees/`

**No confirmation for discard**
- **Problem:** Accidentally delete work
- **Fix:** Require typed "discard" confirmation

## Red Flags

**Never:**
- Create a PR with an inline `--body`/heredoc, or ignore the repo's PR template (breaks on shell metacharacters; drops the required checklist → CI fails)
- Proceed with failing tests
- Merge without verifying tests on result
- Delete work without confirmation
- Force-push without explicit request
- Remove a worktree before confirming merge success
- Clean up worktrees you didn't create (provenance check)
- Run `git worktree remove` from inside the worktree

**Always:**
- Verify tests before offering options
- Detect environment before presenting menu
- Present exactly 4 options (or 3 for detached HEAD)
- Get typed confirmation for Option 4
- Clean up worktree for Options 1 & 4 only
- `cd` to main repo root before worktree removal
- Run `git worktree prune` after removal
