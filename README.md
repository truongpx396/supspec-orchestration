# supspec-orchestration

**Spec-driven implementation orchestration for GitHub Copilot agents.**

A portable bundle of three composable [Copilot Agent Skills](https://docs.github.com/en/copilot/how-tos/provide-context/use-agent-skills) plus a mechanical hooks bundle that turns a spec + task list into reviewed, evidenced, draft-PR-ready code — on one branch or across many parallel tracks.

The skills share one contract: **plan upstream, implement under discipline, prove it with machine-captured evidence, hand off at a draft PR.** No skill can merge its own work.

---

## Why this exists

Autonomous agents are cheap to run and easy to *trust too much*. The recurring failure modes are always the same:

- claims of "tests pass" with no captured proof,
- edits that silently escape the intended scope,
- an agent that auto-integrates its own unreviewed work,
- parallel workers that can't be traced or reverted independently,
- a run that dies halfway and resumes by *guessing* where it left off.

This bundle answers each with a **mechanical control**, not a prompt suggestion. The judgement stays with the model; the *gates* are enforced by hooks that read tool I/O and can block a tool call, halt a run, or fail a stop.

---

## The three skills

| Skill | Role | Use when |
|---|---|---|
| **[single-branch-development](.github/skills/single-branch-development/SKILL.md)** | The per-branch worker | Implement one feature, fix one bug, refactor existing code, or bootstrap a foundation — end to end on a single branch. |
| **[executing-parallel-tracks](.github/skills/executing-parallel-tracks/SKILL.md)** | The conductor | Run N independent tracks concurrently, each in its own worktree, each independently traceable and revertible. |
| **[pr-review-feedback](.github/skills/pr-review-feedback/SKILL.md)** | The rework stage | Address review comments on an **existing** PR branch — post-implementation maintenance, not a fresh build. |

### single-branch-development
A thin **per-branch bracket** (isolation before, an evidence gate + draft-PR boundary after) around an execution core that always runs in **one of three modes**:

- **scaffold mode** — non-behavioral bootstrap batches (config, wiring, project structure) fanned out to read-only subagents.
- **story mode** — behavioral work that adds or changes behavior, under phased TDD. A lone feature or bugfix is story mode with N=1.
- **refactor mode** — behavior-preserving change to existing code, keep-green (no new behavior).

It does **not** re-implement the implement/review loop — the green phase delegates to `subagent-driven-development`, and the draft-PR boundary **replaces** any merge-capable finish.

### executing-parallel-tracks
The **conductor**: it owns isolation, gates, traceability, and integration sequencing, and delegates each track's implement/review/verify work to `single-branch-development`. A **fan-out to isolate to verify to PR to observe** pipeline where *you are the ceiling* — parallelism is cheap, review bandwidth is the bottleneck. Project-specific facts (which tasks belong to which track, file ownership, build commands, concurrency cap) live in a per-repo `track-manifest.md`, never hardcoded in the skill.

### pr-review-feedback
Turns a batch of PR review comments into applied, evidenced changes on the **existing** PR branch. It starts mid-stream (no preflight-mint, no isolate, no RED authoring from scratch), **reuses the hooks bundle in resume mode**, and closes with a PR update instead of a fresh draft PR.

---

## The hooks bundle

The skills are only as strong as the worker's compliance — unless the gates are **mechanical**. Copilot [agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks) run shell commands at lifecycle points (`PreToolUse`, `PostToolUse`, `SubagentStart/Stop`, `Stop`, …) and can block a tool call before it happens. Each script is **opt-in and no-ops unless its env is set**, so dropping the bundle in is safe before configuring anything.

| Script | Event | What it enforces / records |
|---|---|---|
| `track-preflight.sh` | manual (skill Step 1) | Start gate: mint or recover a stable `RUN_ID`, check prerequisites, persist a resume breadcrumb. |
| `track-guard.sh` | `PreToolUse` | Deny edits outside the writable scope, to frozen entrypoints, to generated/applied artifacts, or destructive terminal ops (push, integrate, `--force`, hard resets, opt-in DROP/rm -rf). |
| `track-evidence.sh` | `PostToolUse` | Capture recorded test output (with a code fingerprint) — evidence the tool saw, not a model claim. |
| `track-evidence-gate.sh` | `Stop` | Block stop unless every required evidence kind is present, **fresh** (fingerprint matches the current tree), and passing. |
| `track-meter.sh` | `PostToolUse` | Count tool calls + heartbeat; hard-stop at `TRACK_MAX_TOOL_CALLS`. |
| `track-trace.sh` | `SubagentStart/Stop` | Append a subagent timeline, capturing **why** each was spawned (`agent_description`) + stop reason. |
| `track-tokens.sh` | `Stop` | Estimate token usage from the transcript (chars÷4 heuristic; clearly labelled — undercounts hidden prompt + cached tokens). |
| `track-note.sh` | manual | Let the skill self-report ordered skill activations + loop counts (provenance-tagged as model claims). |
| `track-sentinel.sh` | `Stop` | Scan the staged diff for likely secrets / debug leftovers before handoff. |
| `track-notify.sh` | `Stop` | Best-effort completion webhook. |
| `track-reconcile.sh` | `SessionStart` | Read-only resume: recover state from committed history + run record, stash untrusted work. |
| `track-report.sh` | manual (skill Step 8) | Render a deterministic PR-body Auto block from machine state only (diff, evidence, tool calls, trace, token estimate). |
| `install-hooks.sh` | manual | Idempotent, consent-gated, drift-aware installer for the whole bundle. |

Everything a run records lands in `runs/<RUN_ID>.json` (gitignored). Full documentation: **[references/hooks.md](.github/skills/single-branch-development/references/hooks.md)**.

---

## Repository layout

```
.github/
  hooks/                         # installed bundle (travels with each worktree)
    track-*.sh
    track-hooks.json             # event -> script wiring
    track-env.base.sh            # committed repo-wide config (RUN_ID minted per run, not here)
  skills/
    single-branch-development/
      SKILL.md
      references/                # hooks.md, scaffold-mode.md, story-mode.md, refactor-mode.md
      scripts/                   # source of truth for track-*.sh + install-hooks.sh
      templates/                 # track-hooks.json, track-env.sh.example, pr-body.md
      tests/                     # test-skill.sh (self-test harness)
    executing-parallel-tracks/
      SKILL.md
      scripts/                   # track-precheck.sh
      tests/
      track-manifest.template.md # copy per repo, fill in track/task/file-ownership facts
    pr-review-feedback/
      SKILL.md
README.md
.gitignore                       # runs/ and the per-worktree track-env.sh
```

The canonical `track-*.sh` sources live under `single-branch-development/scripts/`; the copies in `.github/hooks/` are what actually run. `install-hooks.sh --check` detects drift between the two.

---

## Getting started

### 1. Use the skills in another repo
Copy the `.github/skills/` directories into the target repo (Copilot discovers skills under `.github/skills/**/SKILL.md`), then install the hooks:

```bash
# from the skill's scripts dir, run against your repo root
bash .github/skills/single-branch-development/scripts/install-hooks.sh --check   # drift probe (exit 3 if stale)
bash .github/skills/single-branch-development/scripts/install-hooks.sh           # dry-run: print the plan
bash .github/skills/single-branch-development/scripts/install-hooks.sh --apply   # sync bundle + gitignore runs/ + seed track-env.base.sh
```

The installer seeds `.github/hooks/track-env.base.sh` from detected repo signals (`go.mod`->go-test, `pyproject.toml`->py, `package.json`->ts, `migrations/`, default branch) — repo-policy vars filled, task-derived scope left empty so an unedited copy fails loud.

### 2. Configure a run
Edit `.github/hooks/track-env.base.sh` (committed, repo-wide) for policy defaults, and optionally a gitignored `.github/hooks/track-env.sh` per worktree for overrides. Precedence: **exported env > worktree `track-env.sh` > repo `track-env.base.sh` > script default.**

### 3. Invoke a skill
Point Copilot at the task and let the skill drive — e.g. *"implement this story on a branch using single-branch-development"* or *"run tracks 1, 2, 3 in parallel"*. The worker stops at `gh pr create --draft`; a human owns the merge.

### 4. Run the self-tests
```bash
bash .github/skills/single-branch-development/tests/test-skill.sh
bash .github/skills/executing-parallel-tracks/tests/test-skill.sh
```

---

## Design principles

- **Evidence before assertions.** A run cannot claim done; the evidence gate reads captured, fingerprinted test output.
- **Fail-secure gates.** Scope, frozen paths, and destructive ops are denied by default; you opt into looser behavior explicitly.
- **No self-merge.** Every worker physically stops at a draft PR. Integration is a human/merge-queue decision.
- **Independently traceable & revertible.** One `RUN_ID` threads branch, PR, commit trailer, and run record; one worktree = one revert.
- **Self-recovering resume.** State lives in committed history + `runs/<RUN_ID>.json`, not in the model's memory of the session.
- **Mechanical where possible, prompt where not.** Hooks enforce paths/commands/counters; judgement gates (TDD ordering, maker/checker split, review quality) stay as instructions because a hook can't see reasoning.

---

## License

See repository settings. These skills are provided as-is for orchestrating Copilot agent workflows.
