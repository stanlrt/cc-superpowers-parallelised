# superpowers-parallelised

A fork of **[obra/superpowers](https://github.com/obra/superpowers)** (v6.0.3 base),
packaged as a standalone Claude Code plugin. It is a **drop-in replacement** for the
official `superpowers` plugin — you install this and disable the official one, so there is
never a duplicate or a conflicting copy of any skill.

## What's different from upstream

- **DAG-based parallel subagents:** orchestrator crafts plan with parallelisation in mind, using a DAG to track task collisions and dependencies, and prevent inter-subagent file write race conditions.
- **Subagents do not commit**, the **orhestrator agent** commits each task after its review passes and a
  file-collision check. Per-task review uses git **tree snapshots** (`scripts/snapshot` +
  `review-package` reworked to diff tree-ish, with `-- <paths>` to scope one task of a
  parallel batch).
- **Whole-branch refactor review:** after the final correctness review passes, a separate
  design-lens pass steps back over the assembled branch for refactor needs the per-task
  reviews cannot see — dead code (every new symbol grepped for a real consumer), cross-task
  duplication, messy hardcodes, missing abstractions. Hybrid by severity: mechanical,
  evidence-backed findings (dead code, exact duplication) auto-fix through the normal fix
  loop; design-opinion findings are written to a report for you to triage (fix now / ticket
  / accept) at branch finish — working, tested code is never auto-rewritten on an opinion.
- **Reduced token usage:** Sonnet implementers for step-based plans; escalate to the
  most-capable "advisor" model only when the **plan itself** is defective.
- **GitHub centric PR workflow:** PR body built from the repo's PR template and passed
  via `--body-file`; CI monitoring + Copilot comments + Code-Quality comments resolution.
- **GitHub centric issue and branching workflow:** Use GH issues to store specs and manage branches.

Everything else tracks upstream. Skills are namespaced `superpowers-custom:` (e.g.
`superpowers-custom:subagent-driven-development`).

## Install (Claude Code)

```text
/plugin marketplace add stanlrt/cc-superpowers-parallelised
```
```text
/plugin install superpowers-custom@superpowers-custom
```

Then **disable the official superpowers plugin** if you had installed it before, so only the custom one is active (otherwise
both load and the model sees two copies of every skill):

- `/plugin` → manage → disable `superpowers@claude-plugins-official`

Verify: open a new session and check the skill listing shows
`superpowers-custom:subagent-driven-development` and **not** `superpowers:…`.

> The official and the fork cannot both be enabled — they provide the same skill set under
> different namespaces. Pick one. To go back, re-enable the official plugin and disable this.

## Updating the fork from upstream

```bash
git remote add upstream https://github.com/obra/superpowers   # once
git fetch upstream --tags
git merge upstream/main        # or a specific tag, e.g. v6.1.0
# resolve conflicts (only in the 3 custom skills), then bump version in
# .claude-plugin/plugin.json + marketplace.json, commit, push
```

See [CLAUDE.md](CLAUDE.md) for conflict-resolution rules.

## Credit

Methodology and skills © Jesse Vincent / the superpowers authors, MIT-licensed. This is a
personal fork and is not affiliated with or supported by the upstream project.
