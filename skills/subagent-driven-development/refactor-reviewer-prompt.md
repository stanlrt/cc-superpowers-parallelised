# Refactor Reviewer Prompt Template

Use this template when dispatching the whole-branch **refactor reviewer**
subagent — the last review before finishing the branch, dispatched right
after the final correctness code review (../requesting-code-review/code-reviewer.md)
comes back clean.

**Purpose:** Step back from the assembled branch and judge whether the code
is *well-shaped*, not whether it works. The correctness reviewer already
judged "does it work / match spec." This reviewer judges "now that it works,
should it be refactored before merge" — design smells, cross-task
duplication, messy hardcodes, dead code, missing or leaky abstractions.

**Why this is a separate, whole-branch pass.** These are properties of the
*assembled* code across every task, not of any one task's diff. A symbol
added in Task 1 and consumed in Task 5 looks dead in Task 1's scoped review;
duplication between Task 2 and Task 4 is invisible until both have landed; a
hardcode is only "messy" relative to a constant some other task defined. The
per-task reviewer is structurally blind to all of it — it sees one scoped
diff. So this reviewer sees the whole branch AND may read the whole
codebase, which the per-task reviewer may not.

**Two buckets, two fates (hybrid by severity).** The reviewer splits findings:

- **Refactor-Critical (mechanical, auto-fix).** Objectively verifiable, low
  judgment. The controller dispatches a fix subagent for these and re-reviews,
  same loop as a task review. Each MUST carry the evidence that makes it
  mechanical:
  - **Dead code** — a symbol this branch added whose only references are its
    own definition (and tests of only itself). Evidence: the grep across the
    whole repo showing zero real consumers.
  - **Exact / near-exact duplication** — the same logic block emitted in two
    places (typically by two independent task subagents that never saw each
    other's code). Evidence: both file:line ranges.
  - **Hardcode that duplicates an existing named thing** — a literal that
    re-states a constant / config value / enum already defined elsewhere in
    the branch or codebase. Evidence: the literal's location and the existing
    definition's location.
- **Refactor-Advisory (design opinion, human triage).** Judgment calls where
  reasonable engineers differ — "could extract," "this function is becoming a
  God object," "an abstraction would pay off here," primitive obsession,
  naming drift, a shape that will bite later. These are NOT auto-fixed. They
  go into the advisory report file for the human to triage at
  finishing-a-development-branch — fix now, ticket, or accept.

Putting a design opinion in the Critical bucket triggers an unwanted rewrite
of working, tested code; putting real dead code in the Advisory bucket lets it
merge. Bucket by whether the fix is mechanical and evidence-backed, not by how
much it bothers you.

```
Subagent (general-purpose):
  description: "Refactor review (whole branch)"
  model: [MODEL — REQUIRED: most capable available model; this is a design-
         judgment pass, the same tier as the final whole-branch review]
  prompt: |
    You are reviewing an assembled feature branch for refactor needs and
    opportunities. The branch has already passed correctness review — every
    task works and matches its spec. Do NOT re-litigate correctness, spec
    compliance, or test behavior. Your single question is: now that this
    works, is it well-shaped, or should something be refactored before it
    merges?

    ## What Was Built

    [DESCRIPTION]

    ## Plan / Requirements (context, not a checklist)

    [PLAN_OR_REQUIREMENTS]

    Read this only to understand intent and spot where independent tasks
    likely reinvented each other's work. You are not checking spec compliance.

    ## The Branch Under Review

    **Merge base:** [BASE_SHA]
    **Head:** [HEAD_SHA]
    **Diff file:** [DIFF_FILE]

    Read the diff file once — it is a stat summary plus the full branch diff
    with context, and it is the set of changes you are judging. If it is
    missing, regenerate it yourself:
    `git diff --stat [BASE_SHA]..[HEAD_SHA]` and `git diff [BASE_SHA]..[HEAD_SHA]`.

    ## You MAY read the whole codebase — that is the point

    Unlike a per-task reviewer, you are expected to reach outside the diff.
    This is how you tell a real smell from a false one:

    - **Consumer reachability (run this for every symbol the branch adds).**
      For each new function, class, constant, export, type, route, or config
      key, grep the whole repo for real consumers — call sites, imports,
      references — that are NOT its own definition and NOT a test of only
      itself. Zero real consumers → Refactor-Critical dead code, and paste
      the grep result as evidence. A symbol wired only to a test that exists
      to cover that symbol is still dead product code.
    - **Cross-task duplication.** Independent task subagents cannot see each
      other's code, so they reinvent helpers, validators, constants, and
      parsing. Compare the branch's new code against itself and against
      existing utilities. Exact/near-exact logic blocks in two places →
      Refactor-Critical, cite both ranges.
    - **Hardcode audit.** For each literal the branch introduced (magic
      number, string, path, URL, threshold, timeout), check whether a named
      constant / config / enum for it already exists. If yes → Refactor-
      Critical (duplicates an existing name). If no and the literal is
      policy-ish or repeated → Refactor-Advisory (should be named).

    Your review is read-only on this checkout. Do not mutate the working
    tree, index, HEAD, or branch state. If you need another revision, use a
    separate `git worktree add` in a temp dir — never move HEAD here.

    ## Design lens (Advisory findings)

    Beyond the mechanical checks, step back and look at shape:
    - Duplication and near-duplication that is not exact enough to auto-fix
      but signals a missing abstraction
    - Functions / files that grew too large or took on multiple
      responsibilities as tasks piled on (judge what THIS branch contributed,
      not pre-existing size)
    - Leaky or premature abstractions; the wrong seam
    - Primitive obsession — bare strings/ints/maps where a small type would
      remove a class of mistakes
    - Naming drift — the same concept named differently across tasks
    - Structure that works now but will force a painful change on the next
      feature that touches it

    Do NOT invent refactors for their own sake. YAGNI cuts both ways: a
    speculative abstraction is a smell, not a fix. If the code is already
    well-shaped, say so and return few or no findings — a clean branch is a
    valid, expected result, not a reason to manufacture work.

    ## Every finding cites evidence

    file:line for the smell. For Refactor-Critical: also the proof that makes
    it mechanical — the grep output (dead code), both ranges (duplication), or
    both locations (hardcode vs existing name). A Critical finding without its
    evidence is downgraded to Advisory by the controller, so include it.

    ## Output Format

    Begin directly with the first section — no preamble, no process narration.

    ### Well-shaped
    [What is already clean and should NOT be touched. Be specific — this
    stops the controller from "fixing" good code.]

    ### Refactor-Critical (mechanical — will be auto-fixed)
    For each: file:line, what it is (dead code | duplication | hardcode),
    the evidence (grep output / both ranges / both locations), and the fix.

    ### Refactor-Advisory (design opinion — human triage)
    For each: file:line, the smell, why it will bite, and the refactor you
    would suggest. Rank most-valuable first.

    ### Assessment
    **Refactor before merge?** [Clean — nothing to do | Critical fixes only |
    Critical fixes + advisory items worth doing now]
    **Reasoning:** [1-2 sentences]
```

**Placeholders:**
- `[MODEL]` — REQUIRED: the most capable available model (design judgment;
  same tier as the final whole-branch correctness review)
- `[DESCRIPTION]` — one-line summary of what the branch built
- `[PLAN_OR_REQUIREMENTS]` — the plan file path or requirements, for intent
  only (this reviewer does not check spec compliance)
- `[BASE_SHA]` — the commit the branch started from (`git merge-base main HEAD`)
- `[HEAD_SHA]` — branch head (`git rev-parse HEAD`)
- `[DIFF_FILE]` — REQUIRED: the branch package path
  (`scripts/review-package MERGE_BASE HEAD` prints it; same package the final
  correctness review used — reuse it, do not regenerate)

**Reviewer returns:** Well-shaped notes, Refactor-Critical findings (with
evidence), Refactor-Advisory findings, and a refactor verdict.

## How the controller handles the result

1. **Refactor-Critical → fix loop.** For each Critical finding that carries
   its evidence, dispatch ONE fix subagent with the complete Critical list
   (not one fixer per finding — see SKILL.md). The fix subagent carries the
   implementer contract: re-run the tests covering the touched code and report
   the results. Then re-run the refactor package and re-review the Critical
   bucket. A Critical finding missing its evidence is treated as Advisory.
2. **Refactor-Advisory → report file, no auto-fix.** Write the advisory
   findings to `.superpowers/sdd/refactor-report.md` and carry them into
   superpowers-custom:finishing-a-development-branch, where the human triages
   each: fix now, file a ticket, or accept. Do not silently drop them.
3. **Commit** any auto-fixes yourself (subagents never commit), same as any
   other task commit, before moving to finishing the branch.
