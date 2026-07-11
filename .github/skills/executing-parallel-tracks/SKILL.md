---
name: executing-parallel-tracks
description: 'Orchestrate multiple independent implementation tracks in parallel, each in its own
git worktree, fully autonomously from implement through review, verification, and pull request.
Use when asked to "run tracks in parallel", "execute track 1, 2, 3", "spawn parallel agents",
"fan out user stories", or to run several isolated work-streams concurrently with TDD, evidence
gates, and merge-queue integration. Reads a per-repo track-manifest.md for project specifics and
composes the using-git-worktrees, dispatching-parallel-agents, and
single-branch-development skills with strict parallel-only overlays.'
---

# Executing Parallel Tracks

Portable orchestration for running N independent implementation tracks concurrently. This skill is
the **conductor**: it owns isolation, gates, traceability, and integration sequencing, and delegates
the per-track implement/review/verify work to `single-branch-development`. All project-specific facts
(which tasks belong to which track, file ownership, build commands, concurrency cap) live in a
per-repo `track-manifest.md` that this skill reads — never hardcode them here.

**Core mental model:** a **fan-out → isolate → verify → PR → observe** pipeline. *You are the
ceiling.* Parallelism is cheap; your review bandwidth and your ability to trace a failure is the
bottleneck. So the whole design exists to make each parallel worker **independently traceable**
(one run-id across branch, PR, commit trailer, and run record) and **independently revertible** (one
worktree, one branch, one draft PR).

**This skill is the asset; the orchestrator is a runtime role.** Any session can play orchestrator by
invoking this skill — the durable logic lives here, the live state (which worktrees are running,
budget remaining, run registry) lives in the session executing it.

## When to Use This Skill

- User says "execute track 1, track 2, track 3" / "run these tracks in parallel" / "fan out the stories".
- Several work-streams are mutually independent (disjoint files, non-overlapping migrations) and can progress at once.
- You want each track to run autonomously: implement → review → verify → open PR, with no human between tasks.
- A repo has a `track-manifest.md` (or an equivalent dispatch/tasks document) defining the tracks.

Do **not** use this for tightly-coupled tasks that share mutable files — run those serially with
`single-branch-development` instead.

## Prerequisites

- `git` with worktree support; a remote configured for PRs (`gh` CLI authenticated for `gh pr create`).
- Docker available if tracks run integration suites (Testcontainers).
- A repo `track-manifest.md` resolved (see [Manifest contract](#manifest-contract)). If absent, generate one from the repo's tasks/dispatch doc and confirm with the user before proceeding.
- These skills installed and composable: `using-git-worktrees`, `dispatching-parallel-agents`, `single-branch-development`.
- *(Optional but recommended)* `jq` available and Copilot [agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks) enabled, to make the gates mechanical rather than prompt-trusted (see [Deterministic enforcement via Copilot agent hooks](#deterministic-enforcement-via-copilot-agent-hooks)). Hooks may be disabled by enterprise policy — fall back to prompt-enforced gates if so.

## Autonomy boundary (read first)

Autonomous up to and including **opening a DRAFT PR**. The worker's job ends at `gh pr create
--draft`; **GitHub Actions CI is the mechanical gate** (evidence, not claims). Merging is NOT the
worker's job — climb the [maturity ladder](#maturity-ladder-dont-start-at-the-top) deliberately. A
green draft PR proves a track in isolation; only the post-merge tree proves the default branch.
Force-merging several PRs back-to-back is exactly the "never-tested main" failure this skill avoids.

Three gates are mandatory:
1. **Precheck gate** — validate before spawning; ask the human back ONLY if a check fails.
2. **Verifier gate (maker/checker split)** — a DISTINCT adversarial subagent verifies; a failed verifier writes a run record and does NOT open a PR.
3. **Merge gate** — workers stop at "draft PR + evidence + rebased if bounced"; CI gates it; a human or merge queue merges per the maturity rung.

Where a gate is a *mechanical* property (a path, a forbidden command, a counter), enforce it with a [Copilot agent hook](#deterministic-enforcement-via-copilot-agent-hooks) so the worker physically cannot cross it — don't rely on the model obeying a prompt.

## Manifest contract

The skill reads a `track-manifest.md` providing, per repo:

- **tracks**: id → { branch name, worktree path, task IDs, migration/number range it owns }.
- **ownership map**: shared files and who may touch them (append-only hotspots, frozen entrypoints).
- **commands**: lint, unit test, integration test, e2e, dep-lock regen (e.g. `go mod tidy`, `uv lock`).
- **isolation**: per-track Docker project-name / DB namespace convention.
- **caps**: max concurrent tracks running integration suites on this host.
- **invariants**: project release-blockers to assert in review (e.g. access-control deny-by-default).

If a needed field is missing, ask the user once for that specific value; do not guess.

## Traceability: run-id + run records (the spine)

With N workers in flight, durable state is non-negotiable — the model forgets, the file doesn't.

**One run-id, four surfaces.** Mint a stable run-id per track at dispatch
(`<UTC-timestamp>_<track_id>`, e.g. `2026-06-26T14-03_us1`) and stamp it into ALL of:
- the branch name (`track/us1` … keep the run-id in the record if the branch name is fixed),
- the draft PR title (`track/us1 [run 2026-06-26T14-03_us1]`),
- a commit trailer (`Run-Id: 2026-06-26T14-03_us1`),
- the run record filename.

Grep any one surface → reconstruct the whole run.

**Write each track's `goal` as a contract, not a wish.** The `goal` field below is the acceptance
test the worker must pass before it may claim `success` — spell out four things so "done" means
something gradable: the **end state** ("US1 ingest pipeline green per contracts", not "improve
ingest"), the **evidence** required ("integration suite exits 0, output pasted"), the **constraints**
that must hold ("do not edit frozen entrypoints; do not delete existing tests"), and the **budget**
(the hard stops below). A goal with no evidence to fail against will always think it succeeded.

**Run record (one per track, git-ignored `runs/` dir).** Each worker writes/updates
`runs/<run-id>.json` — this is the trace anchor and the orchestrator's memory between ticks:
```json
{
  "run_id": "2026-06-26T14-03_us1",
  "track": "us1",
  "branch": "track/us1",
  "goal": "US1 ingest pipeline green per contracts",
  "status": "blocked",          // success | blocked | no-progress | budget-exceeded
  "evidence": { "lint": "clean", "unit": "42 passed", "integration": "exit 1", "e2e": "n/a" },
  "iterations": 12,
  "tokens": 48000,
  "cost_usd": 0.91,
  "started_ts": "2026-06-26T14-03-11Z",  // first hook event — run wall-clock start
  "last_ts": "2026-06-26T14-11-05Z",     // last hook event — now - last_ts = idle/staleness
  "blocker": "flaky Testcontainers Postgres startup",
  "next_step": "pin image tag; retry integration",
  "pr_url": null,
  "trace": [
    { "t": "2026-06-26T14-03-11Z", "kind": "skill",    "name": "using-git-worktrees" },
    { "t": "2026-06-26T14-03-40Z", "kind": "skill",    "name": "test-driven-development" },
    { "t": "2026-06-26T14-05-02Z", "kind": "subagent", "name": "implementer",  "task": "T038" },
    { "t": "2026-06-26T14-09-18Z", "kind": "subagent", "name": "spec-reviewer", "task": "T038" },
    { "t": "2026-06-26T14-11-05Z", "kind": "subagent", "name": "verifier",      "task": "T038", "result": "fail" }
  ]
}
```
Add `runs/` to `.gitignore`. The orchestrator aggregates all records into `runs/summary.md` for review.

**Activation trace.** `trace` is an append-only event log the worker writes one line to **every time**
it invokes a skill or spawns a subagent — giving a readable `skill A → skill B → subagent X → …`
flow for that run. Keep each entry tiny (timestamp, `kind` = skill|subagent, `name`, optional `task`
and `result`). This is the cheap middle layer between the one-line `blocker` and the full session
transcript: enough to see *which step* the worker was in when it failed, without reading every turn.

## Hard stops (enforced by the orchestrator)

The #1 protection against runaway cost with N workers in flight. Enforce all five:
- **Max iterations** per worker (default 25 turns) → halt, `status: no-progress` if exceeded.
- **No-progress detection** — if the verifier result hasn't moved in N passes (default 3), halt that worker `no-progress`. (Distinct from the self-heal cap, which counts *fix attempts*; this counts *stalled passes*.)
- **Max idle** (heartbeat) — if `now − last_ts` exceeds a wall-clock threshold (default 15 min), halt that worker `no-progress`. This is the signal the other four MISS: a worker hung on a network call, deadlocked in a container, or silently crashed stops advancing `last_ts` while its iteration/pass/token counters also freeze — so it looks identical to a slow-but-working one to every *count-based* cap. Every hook stamps `last_ts` (see the run record), so the orchestrator computes staleness per tick with no extra plumbing. **Enforce this orchestrator-side, not in a hook** — a truly hung worker isn't firing hooks to self-halt.
- **Per-worker token/\$ ceiling** → halt, `status: budget-exceeded`.
- **Global token/\$ ceiling across ALL workers** → at N>1 this matters more than any single cap; halt the fleet when hit.

### Failure taxonomy — route by class, don't feed everything to self-heal

A worker's self-heal budget is for *task* failures only. Conflating the three classes below wastes
fix attempts re-reasoning about a network blip, or lets a silent-but-wrong change through:

- **Infra failure** (registry timeout, image-pull failure, worktree lock, OOM) → **bounded retry with
  backoff at the orchestrator layer**, NOT the agent. The worker shouldn't reason about "npm timed
  out"; the orchestrator retries the step and only escalates to the worker if retries exhaust. Do not
  spend the self-heal budget on these.
- **Task failure** (tests fail, build breaks, lint errors) → what the worker **should** see and
  self-correct on, capped by the self-heal / no-progress limits above.
- **Divergence failure** (technically green but wrong — out-of-scope refactor, deleted a file it
  shouldn't) → the dangerous class because tests can still pass. Caught by the guard path-allowlist +
  frozen paths (mechanical, pre-emptive) and the distinct adversarial verifier — never by retrying.

## Terminal states (name them explicitly)

Blocked/exhausted runs are NOT successes — workers love to dress them up as done. Every run ends in
exactly one of:
- **success** — verifier passed, evidence pasted, draft PR opened.
- **blocked** — a dependency/bug the worker can't resolve within the self-heal cap.
- **no-progress** — max-iterations or no-progress detector tripped.
- **budget-exceeded** — per-worker or global ceiling hit.

Only `success` opens a PR. The other three write a run record and route to the orchestrator.

## Deterministic enforcement via Copilot agent hooks

The per-branch gates become **mechanical** through Copilot
[agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks) — shell commands that run
at lifecycle points (`PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop`, `Stop`) and can
**block a tool call before it happens**. The hook bundle —
[`scripts/track-*.sh`](../single-branch-development/scripts/) and
[`track-hooks.json`](../single-branch-development/templates/track-hooks.json) — is **owned and
documented by `single-branch-development`** (see its *Hooks* section for what each script enforces,
the per-event wiring, and the install steps). This orchestrator reuses that *identical* bundle and
adds only the **parallel-only configuration**: a *different* `TRACK_ALLOWED_PREFIXES` per worktree,
shared frozen entrypoints, and a fleet-wide tool-call ceiling.

Wire a gate to a hook only when it is a *mechanical* property (a path, a forbidden command, a
counter). Leave *judgement* gates — TDD ordering, the maker/checker split, review quality — as
prompt instructions; a hook cannot tell which subagent reasoned about something, nor whether the
*right* suite ran.

Resolve each worker's env **two-tier** before launch — **per-track** vars (`TRACK_ALLOWED_PREFIXES`,
`RUN_ID`) from the track's `Tracks` row, **global** vars from the manifest
Defaults/Commands/Hard-stops sections. Every value is **derived from a `track-manifest.md` field**
(see its *Hook environment* table), not invented:
```bash
# PER-TRACK (a DIFFERENT value in each worktree — export inside each worker's launch)
export TRACK_ALLOWED_PREFIXES="internal/ingest:migrations/0007_:test/ingest"  # this track's owns_paths + owns_migrations
export RUN_ID="2026-06-27T14-03_us1"                                          # <UTC-timestamp>_<track_id>
# GLOBAL (identical for every worker in the wave)
export TRACK_FROZEN_PATHS="cmd/main.go:internal/app/app.go"  # guard: frozen entrypoints
export RUNS_DIR="runs"                                       # one shared dir; RUN_ID keys the file
# OPTIONAL — global; each stays off until set
export TRACK_TEST_CMD_PATTERN="go test|uv run pytest|npm (run )?test"  # evidence
export TRACK_MAX_TOOL_CALLS=200                                       # hard stop
export TRACK_MAX_IDLE_SECS=900                                        # hard stop: heartbeat staleness (orchestrator-side)
export TRACK_NOTIFY_WEBHOOK="https://hooks.slack.com/services/..."     # notify
```
Per-track `TRACK_ALLOWED_PREFIXES` values must be **non-overlapping** across tracks — the
precheck gate already asserts this (overlap → STOP, it would only become a merge conflict).

**Hooks are defense-in-depth, not the final gate.** They are local and bypassable — the
agent can edit a hook script during its own run, and enterprise policy can disable hooks
entirely. Layer them: hooks (fast, in-session) → git `pre-push` (local backstop) →
**GitHub Actions (the unbypassable merge gate)**. CI stays the authority, exactly as the
[autonomy boundary](#autonomy-boundary-read-first) states.

## Step-by-Step Workflow

### 1. Precheck gate (ask-back only on failure)

Run all checks; proceed silently if all pass, else stop and ask the human with the specific failure:

- Working tree clean (`git status --porcelain` empty) and on the intended base branch.
- `track-manifest.md` resolved and every requested track id exists in it.
- Requested tracks have **non-overlapping** file ownership and migration ranges (cross-check the ownership map). Overlap → STOP, report the collision (it would only become a merge conflict later anyway). Make this mechanical with the bundled [`scripts/track-precheck.sh`](scripts/track-precheck.sh): pipe it a JSON array of `{id, prefixes}` (each track's `TRACK_ALLOWED_PREFIXES`) and it exits non-zero with the exact colliding prefix pair — the same string-prefix rule the guard enforces, so the precheck asserts on precisely what the workers will run.
- Docker/host headroom ≥ requested concurrent tracks vs. the manifest cap. Over cap → propose reducing concurrency.
- `gh` authenticated; remote reachable. `runs/` exists and is git-ignored.
- Mint a run-id per requested track now (`<UTC-timestamp>_<track_id>`).
- **Smoke ONE track end-to-end before fanning out the rest.** Run the first track through the full
  pipeline (implement → verify → draft PR) as a single worker and watch it. The first real run
  almost always exposes a missing check, a fuzzy ownership boundary, or a stop condition that needs
  sharpening — far cheaper to catch on one track than to discover it replicated across N runaway
  workers. Fan out the remaining tracks only after the smoke track reaches a clean `success`.

### 2. Create isolation (one per track)

Use `using-git-worktrees`. For each track from the manifest:
```bash
git worktree add <worktree_path> -b <branch>     # e.g. ../repo-us1 -b track/us1
```
Export the manifest's per-track Docker/DB namespace before any integration run (e.g.
`export COMPOSE_PROJECT_NAME=<repo>_us1`). Never point two tracks at one shared dev DB.

### 3. Fan out (one autonomous worker per track)

Use `dispatching-parallel-agents` to launch one worker per track. Each worker executes
`single-branch-development` **inside its own worktree only** for the per-branch pipeline (TDD,
two-stage review, evidence, and draft PR handoff).

Pass each worker: run-id, task IDs, file-ownership scope, manifest commands, and project invariants.
If bundled hooks are enabled, resolve each worker's env two-tier before launch (per-track +
global) exactly as [Deterministic enforcement](#deterministic-enforcement-via-copilot-agent-hooks)
describes.

This orchestrator then applies the stricter parallel-only overlays:

- **Distinct adversarial verifier required** — maker/checker must be a different subagent from the authoring worker; failed verifier -> run record + no PR.
- **Draft-only, no-merge worker boundary** — workers may open draft PRs only; merge remains the merge gate's job.
- **Run-id spine required** — run record + PR title/body + commit trailer stay trace-linked.
- **Fleet controls required** — enforce concurrency cap, no-progress detector, idle/heartbeat detector (`now − last_ts`), and global budget ceiling across workers.

### 4. Per-track finish → DRAFT PR (autonomous, success only)

Only a `success` run reaches this step. The worker opens a **draft** PR as the final step of
`single-branch-development`:
```bash
gh pr create --draft \
  --title "track/<id> [run <run-id>]" \
  --body "$(cat runs/<run-id>/handoff.md)" \
  --label agent-generated
```
The PR body carries the run-id, the goal contract, and the pasted evidence (test output, cost) — the
trace anchor linking PR ↔ run record. The worker stops here; **CI is the real gate**.

### 5. Integration (merge gate — per the maturity rung, NOT the worker)

Workers never merge. Integration is serialized and chosen by your current
[maturity rung](#maturity-ladder-dont-start-at-the-top):
- **Default (start here):** a human reviews each green draft PR and merges; CI must be green first.
- **Graduated:** a merge queue integrates one at a time — rebase on default branch → **regenerate**
  lockfiles (`go mod tidy` / `uv lock`, never hand-merge) → full suite on the rebased tree → merge
  only if green. Never merge stacked PRs back-to-back without re-running the suite on each rebased tree.

After a track's PR merges, tear down its isolation (`git worktree remove <path>` + delete the merged
branch) so worktrees and per-track Docker namespaces don't accumulate across waves.
### 6. Stale-PR bounce (autonomous, to the owning worker)

When merging one PR makes another stale, do NOT hand-fix. Re-dispatch the owning worker:
```
Rebase track/<id> on origin/<default>; regenerate lockfiles (do NOT hand-merge); rerun the FULL
suite and paste output; force-push. If a SOURCE (non-lockfile) conflict remains, resolve preserving
both behaviors and explain it in the PR.
```

### 7. Report

Aggregate every `runs/<run-id>.json` into `runs/summary.md`. Per track report: terminal state
(success / blocked / no-progress / budget-exceeded), evidence pointer, draft-PR URL, iterations, and
cost. Do not claim success without the evidence having been produced. Blocked/exhausted runs are
reported as such — never dressed up as done.

## Maturity ladder (don't start at the top)

Start low; graduate only after weeks of clean runs.

| Rung | Setup | Your job |
|---|---|---|
| **Start here** | Workers open **draft** PRs in worktrees; CI gates them | Review + merge every PR |
| **Next** | A verifier subagent pre-screens before you see it | Approve the pre-filtered ones |
| **Only after sustained clean runs** | Auto-merge **low-risk classes only** (lint, dep bumps) on green CI; merge queue serializes | Audit the run log, not each diff |

## Gotchas

- **Never auto-merge from a worker.** Workers stop at draft PR; merging follows the maturity rung. Violating this reintroduces the never-tested-main risk.
- **A failed verifier never opens a PR.** It writes `status: blocked` (or no-progress/budget-exceeded) + the blocker to the run record; the orchestrator re-dispatches with the blocker as new context or escalates.
- **Lockfiles are derived** — regenerate, never hand-merge. The most common "conflict" is a no-op script, not a real merge.
- **Frozen entrypoints** (`main.go` / `app.py`) must iterate a module registry; tracks self-register via their own files. Editing the entrypoint per track guarantees merge conflicts.
- **Global budget > per-agent budget at N>1** — one runaway worker is cheap; ten are not. Enforce the fleet ceiling.
- **A silent worker beats every count-based cap** — iteration, no-progress, and token caps only advance when the worker is *acting*; a hung/crashed/deadlocked worker freezes all three and looks identical to a slow-but-working one. Track **staleness** (`now − last_ts` from the run record's heartbeat), not just pass/fail, and enforce `TRACK_MAX_IDLE_SECS` orchestrator-side — a truly hung worker won't fire a hook to self-halt.
- **Human review of MERGED code never leaves the loop** — no matter how good the adversarial verifier gets, "done" is still a claim, not a proof, and comprehension debt grows faster the more the fleet ships code you didn't write. The verifier gate lets you approve faster; it does not let you stop reading what landed on the default branch.
- **Prefer CLIs over heavy MCP servers inside workers** — a single broad MCP can burn ~20k+ tokens of a worker's context before it does any work, and context bloat is a top cause of quality decay and cost blowups over a long run. Give workers named CLIs (self-documenting via `--help`, ~zero context) and reserve MCP for tools with no CLI equivalent.
- **Cap concurrency to the manifest value** — Docker resource exhaustion shows up as flaky timeouts, misread as logic bugs.
- **Overlapping ownership is a precheck failure, not a runtime surprise** — catch it in Step 1.
- **Evidence, not assertion** — "all green" without pasted output is `NEEDS_CONTEXT`. The single most important gate.
- **The run-id is the trace** — if it isn't in the branch/PR/commit/record, the run is untraceable. Stamp all four.
- **VS Code ignores hook matchers** — a `PreToolUse` hook fires on EVERY tool call; branch on `tool_name` inside the script, never rely on a `"Edit|Write"` matcher to scope it.
- **Tool names and input keys differ across surfaces** — VS Code uses `create_file`/`replace_string_in_file` with camelCase `tool_input.filePath`; Claude/CLI use `Write`/`Edit` with snake_case `file_path`. A portable guard script checks both ([`track-guard.sh`](../single-branch-development/scripts/track-guard.sh) does).
- **The agent can edit hook scripts** — set `chat.tools.edits.autoApprove` to disallow editing hook scripts, or a worker can neutralize its own guard mid-run. Keep hooks < 5s; they block the agent synchronously.

## Troubleshooting

- *Two tracks edited the same file* → ownership map was wrong; treat as a merge conflict at integration, bounce to the owning worker, and tighten the manifest so the shared file becomes append-only or frozen.
- *Integration suite flaky under parallel load* → reduce concurrent tracks below the cap; confirm per-track Docker namespaces are distinct.
- *Worker loops on a failing test* → self-heal cap exceeded; escalate `BLOCKED` with root-cause, do not keep retrying.
- *PR green but post-merge main red* → a cross-track interaction the merge queue should have caught; ensure the queue runs the FULL suite on the rebased tree, not just the PR's own subset.

## References

- `track-manifest.template.md` (bundled) — copy into a repo and fill per project.
- [`scripts/track-precheck.sh`](scripts/track-precheck.sh) (bundled, parallel-only) — the mechanical Precheck overlap gate: reads a JSON array of `{id, prefixes}` on stdin, exits 0 when all tracks' ownership prefixes are mutually disjoint, or exit 2 with the exact colliding pair / config error (empty ownership, duplicate id). Run it in Step 1 before fan-out.
- The Copilot agent-hook bundle is **owned by `single-branch-development`** ([`track-hooks.json`](../single-branch-development/templates/track-hooks.json) + [`scripts/track-*.sh`](../single-branch-development/scripts/)): `track-guard.sh` (PreToolUse ownership + push lockout), `track-evidence.sh` / `track-meter.sh` (PostToolUse evidence + tool-call ceiling), `track-trace.sh` (Subagent trace), `track-notify.sh` (Stop webhook). This orchestrator reuses it and layers per-track/global env on top.
- [Copilot agent hooks (GitHub Docs)](https://docs.github.com/en/copilot/concepts/agents/hooks) · [Agent hooks in VS Code](https://code.visualstudio.com/docs/copilot/customization/hooks) · [Hooks reference (per-event I/O schema)](https://code.visualstudio.com/docs/agents/reference/hooks-reference) — events, JSON I/O, exit codes, Claude/CLI cross-compatibility.
- Composes: `using-git-worktrees`, `dispatching-parallel-agents`, `single-branch-development`.
