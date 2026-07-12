# 🌱 Supspec Orchestration 🤖

> ⚠️ **This repo is under active development.** Test it thoroughly in your own context before using in production.

**Autonomous agent workflows that turn a SpecKit `tasks.md` into 1 or N evidenced draft PRs —**  
gated by mechanical hooks, composed from Superpowers. No self-merge. Ever.

This is an **orchestration layer** sitting on top of SpecKit artifacts (spec/plan/tasks) and Superpowers skills, automating the gap from "I have a task list" to "I have a reviewed, fingerprint-evidenced draft PR waiting for a human."

1. **Feed it a `tasks.md`** — or a spec, or just a list of stories.
2. **It analyzes** whether tasks are independent, produces a wave plan, and asks for your confirmation before touching any branch.
3. **Autonomous agents run** in isolated worktrees — scaffold, story, or refactor modes, or a mix.
4. **Mechanical hooks enforce** scope boundaries, evidence freshness, token ceilings, and a secrets scan. Every run is observable and resumable.
5. **Each agent stops at a draft PR** — fingerprinted evidence, deterministic Auto block, ready for a reviewer.
6. **A human owns the merge.** Always.

Built on **[SpecKit](https://github.com/github/spec-kit)** (spec → plan → tasks upstream) + the **[Superpowers](https://github.com/obra/superpowers)** catalog (skills + dispatched subagents downstream).

---

## Table of Contents

- [Where these skills fit in the pipeline](#️-where-these-skills-fit-in-the-full-pipeline)
- [Prerequisites](#-prerequisites)
- [Main flows](#-main-flows)
- [The three skills](#️-the-three-skills)
- [Anatomy of a skill](#-anatomy-of-a-skill)
- [The hooks bundle](#️-the-hooks-bundle)
- [Evidence](#-evidence)
- [Run artifacts](#-run-artifacts-run-record--pr-body)
- [Tracing and observability](#-tracing-and-observability)
- [Repository layout](#-repository-layout)
- [Getting started](#-getting-started)
- [Design principles](#-design-principles)
- [Key files](#-key-files)
- [License](#license)

---

## 🗺️ Where these skills fit in the full pipeline

```
┌─────────────── SpecKit (upstream) ─────────────────┐
│  speckit.specify → speckit.clarify → speckit.plan   │
│  → speckit.tasks → speckit.analyze                  │
└──────────────────────────┬─────────────────────────┘
                           │  tasks.md
                           ▼
┌──────── supspec-orchestration (this repo) ──────────┐
│  single-branch-development   (one branch / track)   │
│  executing-parallel-tracks   (N tracks, conductor)  │
│  pr-review-feedback          (rework existing PR)   │
└──────────────────────────┬─────────────────────────┘
                           │  draft PR(s) + evidence
                           ▼
              human reviews → merge queue
```

---

## 📋 Prerequisites

Before using these skills in your repo:

1. **[SpecKit](https://github.com/github/spec-kit)** installed and a `tasks.md` generated (or equivalent task list).
2. **[Superpowers](https://github.com/obra/superpowers)** skills catalog installed and discoverable under `.github/skills/`.
3. A `track-manifest.md` for parallel tracks (or let `executing-parallel-tracks` derive one from `tasks.md` and confirm with you at Step 0).
4. `git` with worktree support; `gh` CLI authenticated; `jq` available.
5. Docker available if any track runs integration suites.
6. Copilot [agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks) enabled in your workspace (optional but recommended — makes scope/evidence gates mechanical rather than prompt-trusted).

---

## 🔄 Main flows

### Flow 1 — Scaffold (non-behavioral bootstrap)
```
Step 1: track-preflight.sh --persist  🎫 mint RUN_ID, confirm scope
Step 2: using-git-worktrees           🌿 isolate on a branch
Step 3: dispatching-parallel-agents   🤖 parallel scaffold batches (no TDD)
Step 4: requesting-code-review        🔎 self-review quality + governance
Step 5: track-evidence-gate.sh        🚦 evidence gate (fingerprint match)
Step 8: gh pr create --draft          📬 stop here — human reviews
```

### Flow 2 — Single feature/bugfix (story mode, TDD)
```
Step 1: track-preflight.sh --persist  🎫 mint RUN_ID, confirm scope
Step 2: using-git-worktrees           🌿 isolate on a branch
Step 3: dispatching-parallel-agents   🤖 RED batch — write failing tests
Step 4: requesting-code-review        🔎 freeze test API (maker/checker)
Step 5: subagent-driven-development   🤖 GREEN — make tests pass
Step 6: verification-before-completion 🚦 evidence gate (fingerprint match)
Step 7: requesting-code-review        🔎 full self-review
Step 8: gh pr create --draft          📬 stop here — human reviews
```

### Flow 3 — Refactor (behavior-preserving, keep-green)
```
Step 1: track-preflight.sh --persist  🎫 mint RUN_ID, confirm scope
Step 2: using-git-worktrees           🌿 isolate on a branch
Step 3: dispatching-parallel-agents   🤖 pin-green (snapshot passing suite)
Step 4: requesting-code-review        🔎 freeze baseline
Step 5: subagent-driven-development   🤖 refactor; systematic-debugging on red
Step 6: verification-before-completion 🚦 evidence gate
Step 7: requesting-code-review        🔎 full self-review
Step 8: gh pr create --draft          📬 stop here — human reviews
```

### Flow 4 — Parallel tracks (N stories at once)
```
Step 0: Analyze & plan waves          📊 derive dependencies, wave plan, CONFIRM
Step 1: track-precheck.sh             🔎 validate manifest + ownership overlap
Step 2: using-git-worktrees (×N)      🌿 one isolated worktree per track
Step 3: dispatching-parallel-agents   🪢 fan out N worker agents
  Each agent runs single-branch-development  🔄 full pipeline per track
Step N+1: observe run records         📊 triage by RUN_ID
Step N+2: integration sequencing      🔀 PRs ordered by dependency
       ↓
human reviews N draft PRs → merge queue
```

---

## 🛠️ The three skills

| Skill | Role | Use when |
|---|---|---|
| 🌿 **[single-branch-development](.github/skills/single-branch-development/SKILL.md)** | Per-branch worker | One feature, bugfix, refactor, or scaffold — end-to-end on a single branch |
| 🪢 **[executing-parallel-tracks](.github/skills/executing-parallel-tracks/SKILL.md)** | Conductor | N independent tracks concurrently, each in its own worktree |
| 🔁 **[pr-review-feedback](.github/skills/pr-review-feedback/SKILL.md)** | Rework stage | Address review comments on an **existing** PR branch |

### 🌿 single-branch-development
A thin **per-branch bracket** (isolation before, evidence gate + draft-PR boundary after) around an execution core with **three modes**:

| Mode | What it does | Key superpower used |
|---|---|---|
| **scaffold** | Non-behavioral bootstrap batches (config, wiring, structure) | 🤖 `dispatching-parallel-agents` → `requesting-code-review` |
| **story** | Add or change behavior under phased TDD | 🤖 `dispatching-parallel-agents` (RED batch) → `requesting-code-review` (freeze) → 🤖 `subagent-driven-development` (GREEN) |
| **refactor** | Behavior-preserving keep-green change | 🤖 `dispatching-parallel-agents` (pin-green) → `requesting-code-review` → 🤖 `subagent-driven-development` + `systematic-debugging` |

All modes share: `using-git-worktrees` (isolation), `verification-before-completion` (evidence gate), `requesting-code-review` (self-review), and the full hooks bundle.

### 🪢 executing-parallel-tracks
The **conductor**: owns isolation, gates, traceability, and integration sequencing; delegates each track's implement/review/verify to `single-branch-development`. Starts with a dependency-aware wave analysis (Step 0) that derives a wave plan and requires your confirmation before spawning any worker.

Superpowers used: `using-git-worktrees` (per track) → `dispatching-parallel-agents` → `single-branch-development` (×N).

### 🔁 pr-review-feedback
Turns a batch of PR review comments into applied, evidenced changes on the **existing** PR branch — no preflight-mint, no fresh RED, no new isolate. Reuses the hooks bundle in **resume mode** and closes with a PR update.

Superpowers used: `receiving-code-review` (triage) → 🤖 `dispatching-parallel-agents` (optional, independent fixes) → `requesting-code-review` (re-review fix delta) → `verification-before-completion` (re-evidence).

---

## 🧬 Anatomy of a skill

Every top-level skill file (`SKILL.md`) follows a consistent section spine, so you always know where to look:

| Section | What it contains |
|---|---|
| `## When to Use` | Trigger phrases; when NOT to use |
| `## Prerequisites` | Required tools, skills, artifacts |
| `## Pipeline` | Numbered steps, exactly what happens in order |
| `## Skill-Per-Step Map` | Table: step → what fires → kind (skill / subagent / script) |
| `## Quality Gates` | What this skill owns — precheck, verifier, merge, evidence gates |
| `## Gotchas` | Known footguns with mitigations |
| `## References` | Links to deep-dive docs and related skills |

Deep-dive docs (scaffold/story/refactor modes, hooks reference) live under `references/` inside each skill directory.

---

## ⚙️ The hooks bundle

The skills are only as strong as the worker's compliance — unless the gates are **mechanical**. Copilot [agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks) run shell commands at lifecycle points (`PreToolUse`, `PostToolUse`, `SubagentStart/Stop`, `Stop`, …) and can block a tool call before it happens. Each script **no-ops unless its env is set**, so dropping the bundle in is safe before configuring anything.

| Script | 🔗 Event | Scope | What it enforces / records |
|---|---|---|---|
| `track-preflight.sh` | manual (Step 1) | per-track | 🎫 Mint or recover stable `RUN_ID`; check prerequisites; persist resume breadcrumb |
| `track-guard.sh` | `PreToolUse` | repo-policy | 🛡️ Deny edits outside writable scope, frozen paths, artifacts, or destructive ops |
| `track-evidence.sh` | `PostToolUse` | per-track | 📸 Capture test output + code fingerprint — what the tool saw, not a model claim |
| `track-evidence-gate.sh` | `Stop` | repo-policy | 🚦 Block stop unless evidence is present, **fresh** (fingerprint matches tree), and passing |
| `track-meter.sh` | `PostToolUse` | repo-policy | 🔢 Count tool calls + heartbeat; hard-stop at `TRACK_MAX_TOOL_CALLS` |
| `track-trace.sh` | `SubagentStart/Stop` | per-track | 🔍 Record **why** each subagent was spawned (`agent_description`) + stop reason |
| `track-tokens.sh` | `Stop` | repo-policy | 🪙 Estimate token usage from transcript (chars÷4; clearly labelled as estimate) |
| `track-note.sh` | manual | per-track | 📝 Self-report ordered skill activations + loop counts (model-claim provenance tag) |
| `track-sentinel.sh` | `Stop` | repo-policy | 🔒 Scan staged diff for likely secrets / debug leftovers before handoff |
| `track-notify.sh` | `Stop` | repo-policy | 📣 Best-effort completion webhook |
| `track-reconcile.sh` | `SessionStart` | per-track | ♻️ Recover state from committed history + run record; stash untrusted work |
| `track-report.sh` | manual (Step 8) | per-track | 📄 Render deterministic PR-body Auto block (diff, evidence, tool calls, trace) |
| `install-hooks.sh` | manual | repo-wide | 📦 Idempotent, consent-gated, drift-aware installer for the whole bundle |

**Scope column:**
- **repo-policy** — set once in `track-env.base.sh` (committed, same value for every track)
- **per-track** — derived from the task set; different value per worktree
- **repo-wide** — runs once during setup, not per-run

**Token / $ budgets are orchestrator-side, not hook-enforced.** Hooks receive no token or cost data from the Copilot API, so `TRACK_TOKEN_ESTIMATE` is a measurement toggle (records a chars÷4 estimate), not a kill switch. The only hook-enforceable ceiling is `TRACK_MAX_TOOL_CALLS`. Set $ budgets in the model/orchestrator settings where they can actually halt a run.

Everything a run records lands in `runs/<RUN_ID>.json` (gitignored). Full documentation: **[references/hooks.md](.github/skills/single-branch-development/references/hooks.md)**.

---

## 📸 Evidence

Evidence is what separates "the agent claimed it worked" from "the agent proved it worked." Every run must pass the evidence gate before it can open a PR.

**How it works:**
1. `track-evidence.sh` captures test command output + a SHA fingerprint of the working tree at capture time.
2. `track-evidence-gate.sh` at `Stop` checks: evidence present? fingerprint matches the current tree? all kinds passing?
3. If the tree changed after capture (stale fingerprint) or evidence is missing → the gate blocks the agent from stopping.

**Stack-aware defaults.** `install-hooks.sh --apply` detects repo signals and seeds `track-env.base.sh` with opinionated starting points:

| Signal | Default evidence kinds |
|---|---|
| `go.mod` present | `go-test: go test -race ./...` |
| `pyproject.toml` present | `py: uv run pytest` |
| `package.json` present | `ts: tsc --noEmit && npm test` |
| `migrations/` present | `pg-explain: psql explain plan` |

These are **additive and fully modifiable** — edit `TRACK_EVIDENCE_KINDS` and `TRACK_EVIDENCE_RULES` in `track-env.base.sh` to add, replace, or remove kinds for your stack. No rewrite needed; the installer just saves the first-run ceremony.

---

## 📦 Run artifacts: run record + PR body

**Run record** (`runs/<RUN_ID>.json`, gitignored). One per track. Populated by hooks — never re-typed by the model. Example:

```json
{
  "run_id": "2026-06-26T14-03_us1",
  "track": "us1",
  "status": "success",
  "evidence": { "go-test": "42 passed", "ts": "0 errors" },
  "tool_calls": 137,
  "token_estimate": 48000,
  "trace": [
    { "t": "…", "kind": "subagent", "event": "start", "agent_id": "sub-01", "agent_type": "implementer", "reason": "green T038 impl" },
    { "t": "…", "kind": "subagent", "event": "stop",  "agent_id": "sub-01", "agent_type": "implementer", "stop_reason": "done" }
  ],
  "skills": [
    { "t": "…", "skill": "subagent-driven-development", "step": "4-green", "self_reported": true }
  ]
}
```

`trace[]` = hook-observed subagent events (mechanical facts). `skills[]` = model's self-reported activations (provenance-tagged). Never mix them.

**PR body** (`templates/pr-body.md`). Two-zone template:

```
## Auto (generated — do not edit)
<!-- track-report.sh renders this block from runs/<RUN_ID>.json:
     files changed, evidence fingerprints + pass/fail, tool_calls, trace[] -->

## Asserted (author-written)
<!-- Human-readable context: what changed, why, any known gaps -->
```

`track-report.sh` fills the Auto block deterministically from the run record. The Asserted zone is the only place the model writes prose.

---

## 🔍 Tracing and observability

Every run is independently traceable through one `RUN_ID` threaded across four surfaces:

| Surface | Where the RUN_ID lives |
|---|---|
| Branch name | `track/us1` (run-id in run record if branch name is fixed) |
| Draft PR title | `track/us1 [run 2026-06-26T14-03_us1]` |
| Commit trailer | `Run-Id: 2026-06-26T14-03_us1` |
| Run record file | `runs/2026-06-26T14-03_us1.json` |

Grep any one surface → reconstruct the whole run. `runs/summary.md` aggregates all tracks for a wave.

**What the run record captures automatically** (no model involvement):
- `tool_calls` + heartbeat (`track-meter.sh`, every `PostToolUse`)
- `trace[]` subagent start/stop events (`track-trace.sh`, every `SubagentStart/Stop`)
- Evidence fingerprints + pass/fail (`track-evidence.sh`, on test tool calls)
- Token estimate + PR-body Auto block (`track-tokens.sh` + `track-report.sh`, at `Stop`)

**What is self-reported** (model's claim, `self_reported:true`):
- `skills[]` — which skill was active at each step (`track-note.sh skill <name>`)
- `iterations` — RED→GREEN loop count (`track-note.sh loop <phase>`)

---

## 📂 Repository layout

```
.github/
  hooks/                              # installed bundle (travels with each worktree)
    track-*.sh
    track-hooks.json                  # event -> script wiring
    track-env.base.sh                 # committed repo-wide config defaults
  instructions/                       # governance gate — applied by every review step
    security-and-owasp.instructions.md
    go.instructions.md
    python.instructions.md
    reactjs.instructions.md
    state-management.instructions.md
    code-review-generic.instructions.md
  skills/
    single-branch-development/
      SKILL.md
      references/                     # hooks.md, scaffold/story/refactor-mode.md
      scripts/                        # canonical source for track-*.sh + install-hooks.sh
      templates/                      # track-hooks.json, track-env.sh.example, pr-body.md
      tests/                          # test-skill.sh self-test harness
    executing-parallel-tracks/
      SKILL.md
      scripts/                        # track-precheck.sh
      tests/
      track-manifest.template.md      # copy per repo; fill in task/ownership facts
    pr-review-feedback/
      SKILL.md
README.md
.gitignore                            # runs/ and per-worktree track-env.sh
```

> The canonical `track-*.sh` sources live under `single-branch-development/scripts/`; the copies in `.github/hooks/` are what actually run. `install-hooks.sh --check` detects drift.

---

## 🚀 Getting started

### 1️⃣ Copy skills into your repo
Copilot discovers skills under `.github/skills/**/SKILL.md`. Copy the `.github/skills/` directories into the target repo, then install the hooks:

```bash
# dry-run: print what would change
bash .github/skills/single-branch-development/scripts/install-hooks.sh

# probe for drift between sources and installed copies
bash .github/skills/single-branch-development/scripts/install-hooks.sh --check

# sync bundle + gitignore runs/ + seed track-env.base.sh
bash .github/skills/single-branch-development/scripts/install-hooks.sh --apply
```

The installer auto-detects repo signals (`go.mod`, `pyproject.toml`, `package.json`, `migrations/`) and seeds `track-env.base.sh` — repo-policy vars filled in, task-derived scope left empty so an unedited copy **fails loud**.

### 2️⃣ Configure

Edit `.github/hooks/track-env.base.sh` (committed, repo-wide policy defaults).  
Optionally add a gitignored `.github/hooks/track-env.sh` per worktree for overrides.

Precedence: `exported env` > `worktree track-env.sh` > `repo track-env.base.sh` > `script default`

Key env vars (set in `track-env.base.sh` unless noted):

**Scope & guard** *(repo-policy — set once, same for every track)*

| Variable | Default | Purpose |
|---|---|---|
| `TRACK_ALLOWED_PREFIXES` | *(required — empty = deny all edits)* | Colon-separated path prefixes the worker may write |
| `TRACK_FROZEN_PATHS` | `""` | Space-separated exact files no worker may edit |
| `TRACK_IMMUTABLE_PREFIXES` | `migrations/` | Committed files here are append-only |
| `TRACK_GUARD_DESTRUCTIVE` | `1` | Deny irreversible shell/DB ops (rm -rf, data-wipe commands) |
| `TRACK_ALLOW_FF_PUSH` | `""` | Set to `1` only for `pr-review-feedback` (update existing PR branch) |

**Evidence & quality** *(repo-policy; EVIDENCE_RULES/KINDS are additive — edit, don't replace)*

| Variable | Default | Purpose |
|---|---|---|
| `TRACK_EVIDENCE_KINDS` | `go-test:…;py:…;ts:…` | `label:command` pack — what commands produce evidence |
| `TRACK_EVIDENCE_RULES` | path-glob:kind pairs | Auto-require evidence kinds based on which files changed |
| `TRACK_REQUIRED_EVIDENCE` | `""` *(task-derived)* | Extra kinds required on every diff regardless of rules |
| `TRACK_BASE_REF` | `origin/main` | Base ref for the diff — wrong value silently passes an empty diff |

**Run lifecycle** *(mix of repo-policy and per-track)*

| Variable | Default | Purpose |
|---|---|---|
| `RUN_ID` | minted by preflight | Stable identifier threading branch ↔ PR ↔ commit trailer ↔ run record |
| `RUNS_DIR` | `runs` | Directory for run records — must be gitignored |
| `TRACK_MAX_TOOL_CALLS` | `200` | Hard ceiling on tool calls; run halts when reached |
| `TRACK_TOKEN_ESTIMATE` | `1` | Toggle: estimate token usage at Stop (chars÷4 heuristic). NOT a kill-switch — see hooks bundle note above. |
| `TRACK_SENTINEL` | `1` | Scan staged diff for likely secrets/debug leftovers at Stop |
| `TRACK_NOTIFY_WEBHOOK` | `""` | URL for best-effort completion webhook; empty = no notify |
| `PREFLIGHT_REQUIRE_GH` | `1` | Require authenticated `gh` CLI at preflight (set `0` on bootstraps without a remote) |

### 3️⃣ Invoke a skill
Point Copilot at the task and let the skill drive:

- *"bootstrap a new project foundation"* → Flow 1
- *"implement this story using single-branch-development"* → Flow 2
- *"refactor this module using single-branch-development"* → Flow 3
- *"run tracks 1, 2, 3 in parallel using executing-parallel-tracks"* → Flow 4

The worker stops at `gh pr create --draft`. **A human owns the merge.**

### 4️⃣ Self-test the bundle

```bash
bash .github/skills/single-branch-development/tests/test-skill.sh
bash .github/skills/executing-parallel-tracks/tests/test-skill.sh
```

The test harnesses are a **documentation-contract fence + functional regression suite** in one:
- **121 SBD tests** cover: preflight flag behavior (`--persist`, `--complete`, breadcrumb stamping), guard allow/deny decisions (scope, frozen paths, destructive ops, FF-push gating), evidence capture + gate (fingerprint freshness, stale detection, multi-kind), meter counting + hard-stop, trace schema, sentinel pattern matching, report Auto-block rendering, run-record field completeness, and structural checks on SKILL.md / hooks.md / templates.
- **195 EPT tests** cover: SKILL.md structural integrity (Steps 0–7, gates, wave planner), manifest template completeness, run-record schema (trace[]/ skills[] separation), precheck ownership-overlap detection (disjoint / overlapping / shared-prefix / boundary / migration-range cases), and the full test suite from SBD re-run against the EPT context.

A passing run means the published docs and the scripts are consistent — no dead references, no missing fields.

---

## 🧠 Design principles

| Principle | Meaning |
|---|---|
| 📸 **Evidence before assertions** | A run cannot *claim* done — the evidence gate reads fingerprinted test output |
| 🛡️ **Fail-secure gates** | Scope, frozen paths, and destructive ops denied by default; you opt into looser behavior explicitly |
| 🚫 **No self-merge** | Every worker stops at a draft PR — integration is a human/merge-queue decision |
| 🧵 **Independently traceable** | One `RUN_ID` threads branch ↔ PR ↔ commit trailer ↔ run record |
| ♻️ **Self-recovering** | State lives in committed history + `runs/<RUN_ID>.json`, not model memory |
| 🔩 **Mechanical where possible** | Hooks enforce paths/commands/counters; judgement gates stay as instructions |
| 🌊 **Wave-aware parallelism** | Tasks are analyzed for dependencies first; fan-out only after human confirms the wave plan |

---

## 🔗 Key files

| File | Purpose |
|---|---|
| [`.github/skills/single-branch-development/SKILL.md`](https://github.com/truongpx396/supspec-orchestration/blob/main/.github/skills/single-branch-development/SKILL.md) | Per-branch worker — full pipeline spec, skill-per-step map, all three modes |
| [`.github/skills/executing-parallel-tracks/SKILL.md`](https://github.com/truongpx396/supspec-orchestration/blob/main/.github/skills/executing-parallel-tracks/SKILL.md) | Parallel-tracks conductor — wave planner, fan-out, isolation, integration sequencing |
| [`.github/skills/pr-review-feedback/SKILL.md`](https://github.com/truongpx396/supspec-orchestration/blob/main/.github/skills/pr-review-feedback/SKILL.md) | PR rework stage — triage, fix, re-evidence, PR update |
| [`.github/skills/single-branch-development/references/hooks.md`](https://github.com/truongpx396/supspec-orchestration/blob/main/.github/skills/single-branch-development/references/hooks.md) | Hooks bundle reference — every script, every env var, run-record schema |
| [`.github/skills/executing-parallel-tracks/track-manifest.template.md`](https://github.com/truongpx396/supspec-orchestration/blob/main/.github/skills/executing-parallel-tracks/track-manifest.template.md) | Track manifest template — copy into your repo, fill in task/ownership facts |
| [`.github/instructions/security-and-owasp.instructions.md`](https://github.com/truongpx396/supspec-orchestration/blob/main/.github/instructions/security-and-owasp.instructions.md) | Security governance — applied at every trust-boundary review |
| [`.github/instructions/code-review-generic.instructions.md`](https://github.com/truongpx396/supspec-orchestration/blob/main/.github/instructions/code-review-generic.instructions.md) | Generic review rubric — applied to all reviews |
| [`.github/hooks/track-env.base.sh`](https://github.com/truongpx396/supspec-orchestration/blob/main/.github/hooks/track-env.base.sh) | Committed repo-wide config — all env vars with defaults and comments |
| [`.github/hooks/track-hooks.json`](https://github.com/truongpx396/supspec-orchestration/blob/main/.github/hooks/track-hooks.json) | Hook wiring — event → script mapping |

---

## License

MIT — see [LICENSE](LICENSE). These skills are provided as-is for orchestrating Copilot agent workflows.
