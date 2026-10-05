# superpowers-parallelised

A fork of **[obra/superpowers](https://github.com/obra/superpowers)** (v6.0.3 base),
packaged as a standalone plugin for Claude Code, Codex, Gemini CLI, and Kimi Code. It is a
**drop-in replacement** for the official `superpowers` plugin — you install this and disable the official one, so there is
never a duplicate or a conflicting copy of any skill.

## What's different from upstream

- **DAG-based parallel subagents:** orchestrator crafts plan with parallelisation in mind, using a DAG to track task collisions and dependencies, and prevent inter-subagent file write race conditions.
- **Subagents do not commit**, the **orhestrator agent** commits each task after its review passes and a
  file-collision check. Per-task review uses git **tree snapshots** (`scripts/snapshot` +
  `review-package` reworked to diff tree-ish, with `-- <paths>` to scope one task of a
  parallel batch).
- **Whole-branch refactor review:** in parallel with the final correctness review (one shared
  branch package), a separate design-lens pass steps back over the assembled branch for refactor needs the per-task
  reviews cannot see — dead code (every new symbol grepped for a real consumer), cross-task
  duplication, messy hardcodes, missing abstractions. Hybrid by severity: mechanical,
  evidence-backed findings (dead code, exact duplication) auto-fix through the normal fix
  loop, and so do design-opinion findings whose fix stays inside files the branch changed;
  bigger design changes (exported interfaces, cross-module moves, untouched files) are written
  to a report for you to triage (fix now / ticket / accept) at branch finish.
  If a correctness fix risks duplication, dead code, a shared shape, or touches a region the
  refactor pass cited, the refactor review re-runs on the corrected branch.
- **Reduced token usage:** Sonnet implementers for step-based plans; escalate to the
  most-capable **plan consultant** model (renamed from "advisor" to avoid clashing with
  Claude Code's built-in `advisor` feature) only when the **plan itself** is defective.
- **GitHub centric PR workflow:** PR body built from the repo's PR template and passed
  via `--body-file`; CI monitoring + Copilot comments + Code-Quality comments resolution.
- **GitHub centric issue and branching workflow:** Use GH issues to store specs and manage branches.

Everything else tracks upstream. Skills are namespaced `superpowers-custom:` (e.g.
`superpowers-custom:subagent-driven-development`).

## Install

Pick the column for your agent and run each row top to bottom. If you use more than one
agent, install the fork separately in each.

| Step | Claude Code | Codex CLI | Gemini CLI | Kimi Code |
|---|---|---|---|---|
| 1. Add the fork as a source | `/plugin marketplace add stanlrt/cc-superpowers-parallelised` | `codex plugin marketplace add stanlrt/cc-superpowers-parallelised` | — (step 2 installs from the repo URL) | — (step 2 installs from the repo URL) |
| 2. Install | `/plugin install superpowers-custom@superpowers-custom` | `codex plugin add superpowers-custom@superpowers-custom` | `gemini extensions install https://github.com/stanlrt/cc-superpowers-parallelised` | `/plugins install https://github.com/stanlrt/cc-superpowers-parallelised` |
| 3. Disable the official `superpowers` (if installed) | `/plugin` → Manage → `superpowers@claude-plugins-official` → Disable | `/plugins` → select Superpowers → Space to turn it off | `gemini extensions disable superpowers` | `/plugins` → Superpowers → disable |
| 4. Load it | `/reload-plugins` | Start a new session | Restart Gemini CLI | `/new` |
| 5. Check | Skills show as `superpowers-custom:…` | `codex plugin list` shows `superpowers-custom@superpowers-custom  installed, enabled` | `gemini extensions list` shows `superpowers-custom` | Plugin manager shows `superpowers-custom` |
| Update later | `/plugin marketplace update superpowers-custom`, then `/reload-plugins` | `codex plugin marketplace upgrade superpowers-custom`, then a new session | `gemini extensions update superpowers-custom` | Re-run step 2, then `/new` |

> The official plugin and the fork cannot both be enabled: they ship the same skills under
> different names. Pick one. To go back, re-enable the official plugin and disable this one.

The Claude Code and Codex CLI columns are tested. Gemini CLI and Kimi Code follow those
agents' documented install commands but are untested. Cursor, OpenCode, Copilot CLI, Factory
Droid, and Antigravity are not set up for the fork; use upstream's instructions with this
repo's URL at your own risk.

## Updating the fork from upstream

```bash
git remote add upstream https://github.com/obra/superpowers   # once
git fetch upstream --tags
git merge upstream/main        # or a specific tag, e.g. v6.1.0
# resolve conflicts (custom skills + manifests only), then:
bash scripts/bump-version.sh <new-version>   # e.g. 6.1.0-fork.1, bumps every manifest
bash scripts/check-release.sh origin/main    # same checks CI runs
```

## Release checks (CI)

`.github/workflows/release-checks.yml` runs `scripts/check-release.sh` on every PR and
push to `main`. It fails when:

- the manifests listed in `.version-bump.json` carry different versions;
- shipped content (`skills/`, `hooks/`, `assets/`, any plugin manifest, `GEMINI.md`) changed
  but the version is not greater than the base branch's;
- a platform manifest is not named `superpowers-custom` or still points at `github.com/obra`;
- a skill or hook references the upstream `superpowers:` namespace;
- a hook or script has CRLF line endings.

See [AGENTS.md](AGENTS.md) for conflict-resolution rules.

## Credit

Methodology and skills © Jesse Vincent / the superpowers authors, MIT-licensed. This is a
personal fork and is not affiliated with or supported by the upstream project.
