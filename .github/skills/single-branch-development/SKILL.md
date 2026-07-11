---
name: single-branch-development
description: 'Run a full end-to-end implementation pipeline on one branch/worktree in one of three execution cores — scaffold (non-behavioral bootstrap batch), story (TDD for new/changed behavior), or refactor (behavior-preserving keep-green) — with two-stage spec-compliance + code-quality verification, evidence capture, optional Copilot hooks, and draft-PR handoff. Use when asked to implement one feature, fix one bug, refactor existing code, or do foundation/scaffold setup with strong quality gates but without multi-track parallel orchestration.'
---

# Single-Branch Development

Run one autonomous branch from implement → review → evidence → draft PR. This skill is a thin
**per-branch bracket** (isolation before, an evidence gate + draft-PR boundary after) around an
**execution core that always runs in one of three modes**: **scaffold mode** for non-behavioral
bootstrap batches, **story mode** for behavioral work that adds or changes behavior (a lone feature or
bugfix is story mode with N=1), or **refactor mode** for behavior-preserving change to existing code
(keep-green, no new behavior). There is no free-form per-task path. It does **not** re-implement the
implement/review loop — story and refactor modes' green phase delegates to `subagent-driven-development`
(SDD), and the draft-PR boundary **replaces** SDD's merge-capable finish. Use it standalone or composed
by an orchestrator.

## When to Use This Skill

- User asks to implement one feature end-to-end on a single branch.
- User asks for foundation/bootstrap work with strict gates before parallel tracks exist.
- You want TDD + verifier + evidence + draft PR without parallel fan-out complexity.
- You need a reusable per-branch worker contract that another skill can compose.
- A bugfix counts — it runs as story mode N=1 (see [Story Mode](#story-mode-optional--story-scoped-phased-tdd)).
- A refactor counts — behavior-preserving change runs as refactor mode, keep-green (see
  [Refactor Mode](#refactor-mode-optional--behavior-preserving-keep-green)).
- **Not** for reworking PR-review feedback on already-implemented work — that has no preflight/isolate/
  RED-authoring to run; it's owned by `receiving-code-review` (then `verification-before-completion`).

## Prerequisites

- `git` and `gh` CLI authenticated for PR creation.
- One or more tasks defined (a single task or a small plan that SDD can execute).
- Planning is already done upstream: this skill starts post-planning and does **not** reopen
  brainstorming, spec-writing, or task breakdown mid-run.
- Project test commands are known (lint/unit/integration/e2e as applicable).
- Optional: Copilot agent hooks enabled with a hook file in `.github/hooks/*.json`.

### Step 0 — First-run bootstrap (offer, then install on consent)

Before Step 1, probe whether this repo has the hooks wired and current:
run [`scripts/install-hooks.sh --check`](scripts/install-hooks.sh). It exits `0` if the installed
bundle matches source, or `3` if hooks are **missing or drifted** (a repo can silently run a
months-stale bundle — the #1 reason a run executes ungated). If it reports drift or absence:

1. Run `install-hooks.sh` (no args) to print the **dry-run plan** — it writes nothing.
2. **Surface the plan and ask the user for consent.** Installing touches shared repo config
   (`.github/hooks/`, `.gitignore`), so never auto-apply — this is a confirmation-worthy action.
3. On "yes", run `install-hooks.sh --apply`. It is idempotent and non-destructive: it syncs the
   bundle, gitignores `runs/`, and seeds a **stack-aware** `track-env.base.sh` (evidence catalog +
   toolchain + base ref detected from the repo's `go.mod`/`pyproject.toml`/`package.json`/spec dirs;
   TASK-DERIVED scope/floor left EMPTY so an unedited copy fails loud). An existing base preset is
   **never clobbered**. Then have the user review + commit the changes.
4. On "no", proceed — the hooks stay no-ops until their env is set, so skipping install is safe.

Skip Step 0 entirely if `--check` already exits `0`.

## Pipeline (One Branch)

Steps 1–3 (before) and 5–8 (after) are the **universal bracket** — identical no matter which mode
runs: preflight, reconcile, isolation, and the evidence-gate + draft-PR boundary are reused unchanged
by every core. Step 4 is the **execution core**: always scaffold, story, or refactor mode, never a
free-form per-task loop. See the [skill-per-step map](#skill-per-step-map) for which superpower skill
owns each step.

1. **Preflight & confirm** — run [`scripts/track-preflight.sh`](scripts/track-preflight.sh)
   (`inspect` mode) before touching the repo. Supply only the **track slug** (`TRACK_ID=a`); the
   script settles identity off one durable fact — whether a `runs/*.dispatch` breadcrumb for this
   `TRACK_ID` exists. No breadcrumb → **START**: mint `RUN_ID` = `<UTC-timestamp>_<track>`, check
   prerequisites, and on approval persist `runs/<RUN_ID>.dispatch`. Breadcrumb exists → **RESUME**
   that run automatically (there is no `--resume` flag). It prints a one-screen summary (Mode · Track
   · Tasks · RUN_ID · Branch · Base ref · Prereqs) and the same as JSON. **Present that emitted summary
   verbatim for approval — never re-type it into a hand-built table.** A re-rendered summary can drift
   silently from what `--commit` actually stamps into the breadcrumb; the script's own output is the
   single source of truth. **The interactive confirm is
   mandatory: STOP and get explicit human approval of this summary before Step 3 creates anything.**
   The only waiver is an explicitly-set `auto_confirm`/`--yes` (orchestrator runs only) — absent that
   flag, treat confirm as required, never skippable by default. A prerequisite failure hard-fails
   regardless. Re-run with `--commit` to persist. See [references/hooks.md](references/hooks.md) for
   `RUN_ID` mechanics.
   **Derive the task-shaped config here.** From the task set's file/language surface, set — *before*
   inspect — the values whose correct value depends on *this* task (not repo-wide policy):
   `TRACK_ALLOWED_PREFIXES` (writable scope) and any `TRACK_FROZEN_PATHS`; `PREFLIGHT_REQUIRE_TOOLCHAIN`
   (the bins the task's languages need, so a missing tool fails here not mid-run); and
   `TRACK_REQUIRED_EVIDENCE` (the evidence *floor* for the task's languages). Preflight echoes each in
   its summary/JSON with an unset flag — `scope_set:false` means the guard fails closed and denies
   **all** edits; `evidence_floor_set:false` means the gate is rules-only. Repo-wide catalog/policy
   (`TRACK_EVIDENCE_KINDS`/`RULES`, sentinel, ceilings, `RUNS_DIR`) stays in the committed
   `track-env.base.sh` — do not regenerate it per run. Confirm the derived values as part of the same
   proceed-confirm, then `--commit` — which stamps the confirmed scope, frozen paths, toolchain, and
   evidence floor into `runs/<RUN_ID>.dispatch`, so the artifact is a faithful record of what was
   approved. Do not hand-widen scope mid-run.
2. **Reconcile / resume** — run [`scripts/track-reconcile.sh`](scripts/track-reconcile.sh) to rebuild
   position from **persisted state only** (committed history + `runs/<run-id>.json`), never the
   model's reading of the worktree. It marks each evidence kind `fresh|stale|missing|failed` at the
   current fingerprint. Then: stash any `dirty_worktree` (untrusted, reversible — never `reset
   --hard`), skip every `fresh` kind, and resume at the first `missing`/`stale`/`failed` task.
   Doneness is mechanical (fingerprint match), never a judgement call. No-op on a clean, complete tree.
   Running it by hand does **not** hang — it skips the stdin read on an interactive TTY (`[ -t 0 ]`),
   so a `< /dev/null` redirect is optional.
3. **Isolate** — run `using-git-worktrees` to place the work in an **isolated worktree**, using the
   **Branch** name from preflight's summary (an explicit `TRACK_BRANCH` if you set one, otherwise the
   track slug). **A dedicated worktree is the default and expected form of isolation** — the whole
   point of this step is that a failed or abandoned run's files live in a *separate directory you can
   delete wholesale*, never in your primary checkout. Follow `using-git-worktrees` exactly: detect
   existing isolation first (if `git rev-parse --git-dir` ≠ `--git-common-dir` and you are not in a
   submodule, you are already in a linked worktree — reuse it), then prefer a native worktree tool,
   then fall back to `git worktree add`. **A bare branch in the primary checkout is NOT sufficient
   isolation** and is permitted *only* when `using-git-worktrees` explicitly routes there — i.e. the
   user has declined worktree consent, or the harness cannot create one. In that fallback you MUST (a)
   surface the decline/limitation to the user, and (b) proceed branch-in-place only after explicit
   acknowledgement. Never silently downgrade worktree → branch-in-place, and never start on main.
4. **Run the execution core — pick the mode with the guard.** Behavioral work that **adds or changes**
   behavior (a test obligation, a trust boundary, or a correctness/security criterion) →
   **[Story Mode](#story-mode-optional--story-scoped-phased-tdd)**. Behavior-**preserving** change to
   existing behavioral code (rename/extract/restructure, no contract change) →
   **[Refactor Mode](#refactor-mode-optional--behavior-preserving-keep-green)**. Pure non-behavioral
   bootstrap → **[Scaffold Mode](#scaffold-mode-optional--batch-in-session-fan-out)**. Story and
   refactor modes delegate their green phase to `subagent-driven-development`; this skill never re-runs
   SDD, it only closes SDD's two gaps: (a) SDD's test-first is opt-in, so story mode supplies the
   failing tests up front via the RED batch (refactor mode instead pins the existing suite green up
   front); (b) SDD's stage-2 review is quality-only, so every review also applies the standing
   **governance** — the project constitution (`.specify/memory/constitution.md`, if present) and the
   `.github/instructions/*` whose `applyTo` globs match the changed files — and any trust-boundary
   change additionally applies `security-and-owasp.instructions.md`.

   **Governance is a *maker* obligation, not just a checker backstop.** Before **any** fan-out (scaffold
   generation, story RED authoring, refactor characterization), discover the applicable governance set
   **once** and **embed it into every parallel subagent's brief**: (a) the project constitution's
   relevant principles (`.specify/memory/constitution.md`, if present); (b) the `.github/instructions/*`
   whose `applyTo` globs match the files that cluster will produce (e.g. `go` for a Go cluster,
   `reactjs`/`state-management` for a frontend cluster, `python` for a Python cluster); and (c)
   `security-and-owasp.instructions.md` for any cluster touching a trust boundary (deploy/secrets/
   network/persistence). State in-brief that these are **binding**, so each maker satisfies them *while
   generating* (pinned image tags, no committed default credentials, secure headers, strict type/lint,
   parameterized queries) rather than discovering them at review. Applying governance at **both** ends
   is deliberate defense-in-depth: the maker brief prevents the violation, the review catches whatever
   slips through. Dispatching a fan-out subagent **without** its governance brief is a defect even if
   the later review happens to catch the gap — that round-trip is exactly how a bootstrap PR ships
   hardcoded credentials. All of this **no-ops only when those files genuinely don't exist.**

   *Self-reported trace (optional):* call [`scripts/track-note.sh`](scripts/track-note.sh)` skill
   <name>` at each core step and `track-note.sh loop <phase>` once per RED→GREEN→review cycle to append
   an ordered, provenance-tagged `skills[]` / `iterations` record. These are the model's **own claim**
   (`self_reported:true`), never hook-observed; skip them if you don't want a self-attested trace. The
   **mechanical** fields (`tool_calls`, `trace[]`, heartbeat) record automatically — preflight `--commit`
   persists `RUN_ID` into the installed `track-env.sh`, so even a solo run populates the record with no
   extra setup. See [references/hooks.md](references/hooks.md) for the full mechanics.
5. **Freeze & verify-all** — once the last task's review passes, make **no further edits**, then run
   every required evidence kind (`go-test`, `pg`, `redis`, …) back-to-back so all captures share the
   **same** fingerprint. Any change after this — including a review-driven fix — invalidates the
   convergence and requires re-running all kinds.
6. **Evidence gate** (`verification-before-completion`) — paste real command output; "all green"
   without pasted output is not done.
7. **Update the run artifact** if your workflow tracks one (`runs/<run-id>.json`, handoff notes). If
   you logged the self-reported trace in Step 4, `skills[]` (ordered skill activations) and
   `iterations` (loop count) now live in the record alongside the hook-observed `tool_calls` / `trace[]`
   / `evidence[]` — read them together, but never conflate the self-reported fields with the mechanical
   ones.
8. **Draft-PR finish** — open a **draft** PR and stop. This **replaces** SDD's call to
   `finishing-a-development-branch`; the worker never reaches its merge menu. Integration/merge is
   owned by repo process/CI. **Build the PR body from [`templates/pr-body.md`](templates/pr-body.md):**
   generate its **Auto** block with [`scripts/track-report.sh`](scripts/track-report.sh) (files changed +
   size from the diff, evidence with fingerprints + pass/fail, `tool_calls` / `trace[]`, and any
   self-reported `skills[]` / `iterations` — all rendered from `runs/<RUN_ID>.json` + the breadcrumb,
   never re-typed), then author only the **Asserted** zone (compliance narrative, caveats, "after merge").
   Keep the two zones visibly separate so a reviewer can tell a hook-verified fact from a model claim.
   The Auto block ends with a **Compliance warnings** section: if `track-report.sh` flags a *missing
   `requesting-code-review` activation* or an *empty evidence pack*, that gap is real — resolve it (run
   the Step-5 review / capture the evidence) or explicitly acknowledge the waiver in the Asserted zone.
   **Never open a draft PR with an unaddressed ⚠️.** Once the PR is open, run `track-preflight.sh --complete` to stamp
   `completed_utc` + `duration_secs` (now − `created_utc`) onto the breadcrumb — write-once, the one
   deliberate boundary that knows the run's total wall-clock (a per-event hook never sees PR handoff).

## Skill-Per-Step Map

| Step | Superpower skill / script |
|------|---------------------------|
| 1 Preflight | `track-preflight.sh` (bundled) |
| 2 Reconcile | `track-reconcile.sh` (bundled) |
| 3 Isolate | `using-git-worktrees` |
| 4 Core — **story** RED author | `dispatching-parallel-agents` (+ governance brief in each maker) |
| 4 Core — **story** RED review + freeze | `requesting-code-review` + governance (constitution + matched `.github/instructions/*`) + `security-and-owasp` |
| 4 Core — **story** incremental green | `subagent-driven-development` (→ `test-driven-development`, `requesting-code-review`) |
| 4 Core — **refactor** pin-green + characterize | `dispatching-parallel-agents` (+ governance brief in each maker) + `requesting-code-review` |
| 4 Core — **refactor** incremental transform (keep green) | `subagent-driven-development` (+ governance + `security-and-owasp` on trust boundaries) |
| 4 Core — **scaffold** generate | `dispatching-parallel-agents` (+ governance brief in each maker) |
| 4 Core — **scaffold** review | `requesting-code-review` + governance (constitution — hard gate) |
| 5–6 Converge & gate | `verification-before-completion` |
| 8 Finish | draft PR — **overrides** `finishing-a-development-branch` |

## Quality Gates (Owned Here)

Invariants this skill asserts; most are *realized by* SDD's loop, not re-run here.

- **TDD required** for behavioral changes — realized at story scope: story mode authors the failing
  RED suite before any implementation (N=1 for a lone task). It's a prompt-level invariant (hooks
  can't see test-first ordering), backstopped by the RED gate (tests must fail first) and the evidence
  gate (they must end green). Scaffold mode is the sole exemption — its guard proved nothing is
  behavioral.
- **Behavior-preserving work is keep-green, not red-first**: refactor mode is the third core — it
  never authors a failing RED suite. It pins the existing suite green up front (adding characterization
  tests that must pass *immediately* where coverage of the touched surface is thin), then holds it
  green through every transform step. A red test mid-refactor signals a behavior change and must route
  to story mode; greening it by editing a behavioral/contract test is a false green.
- **Governance gate — hard, in every mode (incl. scaffold)**: each mode's review must apply the repo's
  standing governance on top of the quality rubric — (a) the **project constitution**
  (`.specify/memory/constitution.md`, if the repo has one) as a *hard* gate: a diff that violates a
  stated principle fails review in **every** mode; (b) whichever **`.github/instructions/*`** files'
  `applyTo` globs match the changed files (e.g. `go` for `**/*.go`, `reactjs`/`state-management` for
  `**/*.tsx`), applied to the diff even when the reviewer didn't author the file. This is a
  prompt-level review invariant (no hook can read principle compliance) and **no-ops only when those
  files genuinely don't exist**, never by omission. The **same governance set is pushed upstream into
  every fan-out maker subagent's brief** (scaffold Step 2 / story RED-author / refactor characterize),
  so parallel generators follow the constitution + matched instructions *while authoring* — governance
  therefore gates **both** the maker and the checker (defense-in-depth), and review is the backstop for
  anything a maker missed, not the first place governance is consulted.
- **Security review required** at stage 2 for trust-boundary changes: the `requesting-code-review`
  rubric is quality-only, so the reviewer must also apply `security-and-owasp.instructions.md` (the
  security leg of the governance gate above).
- **Maker/checker required**: the stage-1/stage-2 reviewer must be a subagent distinct from the
  implementer (SDD's two-stage review).
- **Resume from durable state, not memory**: an interrupted run reconciles from committed history +
  the fingerprint-matched run record; uncommitted changes at startup are stashed, not built upon. The
  `RUN_ID` is durable too — minted once, persisted to a breadcrumb, recovered automatically on resume.
- **Evidence, not assertion**: completion requires command output. The fingerprint is whole-tree, so
  every required kind must pass against **one common final tree** (Step 5 converges the lanes).
- **Self-heal cap**: SDD loops "until approved" unbounded; this skill's controller caps retries at
  `self_heal_attempts` (default 2) per distinct failure, then escalates `blocked` rather than thrashing.

## Gotchas

- **Resume keys on the *track slug*, not a remembered id.** Reuse the exact same slug — "track `a`"
  then "track `auth`" reads as two different tracks and starts fresh. To force a clean restart, delete
  that track's `runs/*_<track>.*` files. There is no `--resume` flag.
- **Never hand-set `RUN_ID`.** It is minted once by `track-preflight.sh` and must stay stable across
  restarts so `track-reconcile.sh` reopens the same record. Typing your own breaks resume.
- **A dirty worktree at startup is untrusted.** Reconcile stashes it (reversible) — never `git reset
  --hard` unfamiliar work and never build on it.
- **Isolation means a *worktree*, not just a branch.** Step 3 defaults to a dedicated worktree so an
  abandoned run's files sit in a separate directory you can delete wholesale. Creating a branch in the
  **primary** checkout and working there is the failure this step exists to prevent: an abandoned
  scaffold then pollutes your main tree and must be hand-cleaned (`git clean`). Branch-in-place is
  allowed **only** when `using-git-worktrees` routes there (user declined worktree consent, or no
  worktree mechanism exists), and only after that decline is surfaced and acknowledged. Never silently
  downgrade worktree → branch-in-place because it "feels lighter." Verify with `git worktree list`:
  more than the primary entry means you isolated; a single entry means you did **not**.
- **The guard scopes writes by the *worktree root*, and env lives where the agent runs.** `track-guard.sh`
  resolves each write path against the git worktree it belongs to (`git rev-parse --show-toplevel`), not
  `$PWD`, so `create_file`/`replace_string_in_file` into a **sibling** worktree are scope-checked normally
  even when the agent stays rooted in the main checkout — no terminal-heredoc workaround needed. But the
  hook still **sources `track-env.sh` from the checkout the agent process runs in**: set per-run overrides
  (`TRACK_ALLOWED_PREFIXES`, and `TRACK_ALLOW_FF_PUSH=1` for a PR-rework push) in *that* checkout's
  `.github/hooks/track-env.sh`, not the worktree's, or the guard won't see them. Simplest robust option:
  re-root the workspace **into** the worktree so `$PWD`, file tools, and env all agree.
- **Doneness is mechanical.** A task is done only when its evidence `fingerprint` matches the current
  tree. "All green" without pasted output is not done.
- **Set `TRACK_BASE_REF` — it's required, not optional.** The gate derives "what changed" from the
  diff; with no base ref a *committed* change shows an empty diff-vs-HEAD, so the gate requires nothing
  and silently passes. The worker commits before handoff, so set it (e.g. `origin/main`).
- **Gitignore `runs/` before the first run.** The fingerprint hashes untracked non-ignored files, so a
  tracked or unignored `runs/*` file self-stales the gate (evidence writes shift the fingerprint) and
  reads the tree as dirty. Only when `runs/` is ignored does it drop out of the fingerprint.
- **Each `track-*.sh` no-ops until its env is set.** Dropping the bundle in is safe; the scripts
  enforce nothing until you export the matching vars (e.g. `TRACK_ALLOWED_PREFIXES`). To avoid
  re-exporting them each run (a resume that forgets them runs **ungated**), commit a repo-wide
  preset — copy `templates/track-env.sh.example` → `.github/hooks/track-env.base.sh` — which
  travels into every worktree; add a gitignored `.github/hooks/track-env.sh` only to override a
  single worktree. Every hook auto-sources both. See [references/hooks.md](references/hooks.md#install).
- **The run record self-activates in a solo run.** Preflight `--commit` persists `RUN_ID` as a managed
  block in the installed `.github/hooks/track-env.sh` (retired at `--complete`), so `tool_calls` /
  `trace[]` / heartbeat accrue with no ceiling and no manual export; `TRACK_MAX_TOOL_CALLS` only *adds*
  the hard-stop. The write is gated on the installed-hooks marker (`track-env.base.sh`), so it never
  touches the skill's `scripts/` source mirror. For **parallel tracks**, each worker must export its own
  `RUN_ID` (the `${RUN_ID:-…}` form makes that exported value win over the persisted default) so writes
  don't cross-attribute. Populate `skills[]` / `iterations` yourself via `track-note.sh` (Step 4).
- **Don't freeze entrypoints on a bootstrap branch.** Leave `TRACK_FROZEN_PATHS` unset until parallel
  tracks begin and the entrypoints exist.
- **The worker physically stops at `gh pr create --draft`.** Push/merge/force are denied by the guard.
- **Hook scripts are bash + `jq` only** — no PowerShell port; run under a bash-compatible shell.
- **`[P]` is *not* the scaffold trigger.** `[P]` marks file-disjointness, not non-behavioral-ness — it
  sits on security-critical tasks too. Scaffold mode keys on an explicit `scaffold_only` batch + the
  guard; any test obligation or trust boundary refuses the whole batch to story mode.
- **In scaffold mode the controller *applies* file bodies — it never *authors* them.** Step 2
  generation is **delegated** to N read-only subagents that return each body as text; Step 3 the
  controller applies them as sole writer. Writing the files yourself with `create_file` — because
  they're "just trivial config" and a subagent-per-file feels like overkill — silently collapses the
  two roles and **skips the fan-out entirely** (the exact failure mode this mode exists to prevent).
  "Same converged tree" is not the point: the *delegation* is the discipline. Step 3's "controller is
  the only writer" means it is **only** a writer, never the generator. Read
  [`references/scaffold-mode.md`](references/scaffold-mode.md) **before** executing Step 4 — the SKILL
  body is only a summary; the mode reference is the binding spec.
- **Scaffold generates only the task-declared surface — no speculative structure.** A scaffold task
  names specific directories (e.g. `backend-go/{cmd/api,kernel,internal,migrations,tests}`); it does
  **not** license pre-building the whole future architecture that *later* tasks introduce (every
  `internal/<domain>/{dto,errors,infra,model,service}`, every kernel port, every `cmd/<x>`). The
  tell-tale failure is a blast of one `.gitkeep` per anticipated leaf — dozens of empty dirs for
  unreached tasks flooding a bootstrap PR. Subagents return only the files their task names; for an
  empty dir a task *does* name, use **one** `.gitkeep` in that dir only; the controller trims any
  returned path outside the batch's declared surface before committing. (Full rule:
  [`references/scaffold-mode.md`](references/scaffold-mode.md) Step 3a.)
- **Report state from command output, not intent.** Never announce that a commit, push, or PR
  "exists" / "is opened" until the command that creates it has *returned successfully* — run `git push`
  then `gh pr create --draft`, and read the branch/PR URL from **their** output. Saying "draft PR
  opened" right after a bare `git push` (trusting a remote auto-link) is the exact
  `verification-before-completion` failure this pipeline exists to prevent: the artifact you claimed may
  not exist. Step 8 is not done until `gh pr create --draft` prints a PR URL.
- **Never green a frozen test by weakening it (story) or editing behavior (refactor).** A deleted
  assertion, loosened matcher, `skip`-ped case, or a behavioral/contract test rewritten to pass is a
  false green in every mode. A genuinely wrong test routes back through its review gate; characterization
  tests must pass at baseline and are never edited to green. (Full rules in the story/refactor sections.)

## Hooks (Optional, Composable) — Bundle Owned Here

The quality gates are only as strong as the worker's compliance — unless you make the **mechanical**
ones (paths, forbidden commands, counters) enforced. This skill ships the canonical hooks bundle
([`scripts/track-*.sh`](scripts/) + [`templates/track-hooks.json`](templates/track-hooks.json)),
wiring Copilot agent hooks to deny out-of-scope edits, lock workers out of push/merge, record test
evidence, and block completion on an incomplete evidence pack. Each script is opt-in and no-ops until
its env is set, so dropping the bundle into `.github/hooks/` is safe. Leave *judgement* gates (TDD
ordering, maker/checker split, review quality) as prompt instructions — a hook can't tell which
subagent reasoned about something.

**Hooks are defense-in-depth, not the final gate.** Layer them: hooks → git `pre-push` → **CI**.

See [`references/hooks.md`](references/hooks.md) for the full bundle: every script and its event, the
install/env reference, portability notes, and what `runs/<RUN_ID>.json` does and doesn't capture.

## Scaffold Mode (Optional) — Batch In-Session Fan-Out

For a **narrow, explicitly-declared** class of work — *mechanical, non-behavioral bootstrap files with
no test obligation and no trust-boundary surface* (skeletons, manifests, lint/compose/`Makefile`
configs, test-harness scaffolding) — swap the SDD per-task loop for a batch core that exploits `[P]`
disjointness for parallel-generation latency:

1. **Guard** — assert every batched task is non-behavioral; **refuse the whole batch** (→ story mode)
   if any task has a test obligation, touches a trust boundary, or carries a security/correctness
   criterion.
2. **Fan out generation** (`dispatching-parallel-agents`) — one **read-only** subagent per
   **independent domain / disjoint-file cluster** (not one-per-file, not one-per-task) returns its
   file bodies as text; none writes to disk, runs tests, or commits. A single file written by two
   tasks (e.g. a `pyproject.toml` holding both deps and lint config) stays in **one** agent; two
   agents must never share a target file.
3. **Apply** all bodies at once (controller = single writer) → one converged tree.
4. **One `verification-before-completion` capture** — build + lint + bring-up health check; paste
   output. This proves the scaffold *works*.
5. **One `requesting-code-review`** over the whole diff (quality-only — the guard cleared trust
   boundaries), then the same **draft-PR finish**.

Steps 4 and 5 are orthogonal and both mandatory: verification proves it *works*, review proves it is
*correct*. TDD and two-stage review are dropped only because the guard proved the batch is
non-behavioral — scaffold mode swaps only the core.

See [`references/scaffold-mode.md`](references/scaffold-mode.md) for the full flow, the eligibility
guard, and the drop-vs-keep table.

## Story Mode (Optional) — Story-Scoped Phased TDD

For **behavioral user-story stages** that a spec-driven plan lays out as two task groups — a
write-first `### Tests` group (contract/integration/**security** tests, all `[P]`) and a separate
`### Implementation` group — swap the SDD per-task loop for a story core that authors the tests as a
batch, then greens implementation incrementally. This is the **inverse of scaffold mode**: scaffold
refuses anything behavioral; story mode requires it. Per-task TDD can't run here — a test task and its
implementing task are distinct IDs in different files/runtimes.

1. **Guard** — confirm the batch is behavioral. A `### Tests` + `### Implementation` split runs here; a
   lone behavioral task runs here as **N=1**. Only pure non-behavioral bootstrap routes away → scaffold.
2. **RED batch** (`dispatching-parallel-agents`) — fan out generation of the `### Tests` group, apply
   serially, **run**, and assert the whole group fails for the right reason (real red, not a typo).
3. **RED review + freeze** (`requesting-code-review` **+** `security-and-owasp`) — review the failing
   suite, then **freeze** it: green may add production code only. Greening by weakening a test is
   forbidden.
4. **Incremental green** (`subagent-driven-development`) — implement the `### Implementation` group in
   dependency order; each task/cluster flips an identifiable subset green, with per-increment
   stage-1/stage-2 (+ security) review. Not big-bang — a story-long red period discards TDD's feedback
   loop.
5. **Converge & verify-all** (`verification-before-completion`) — freeze, run the whole story suite +
   every evidence kind on one fingerprint; the story's **Checkpoint** line is the Definition of Done.

**Bugfix?** Same core at **N=1**, prefixed with `systematic-debugging`: reproduce and root-cause
*first*, encode the diagnosis as the failing regression test (that's the RED batch), then green it. It
is not a separate mode — diagnose before writing the fix so you green the cause, not a symptom.

TDD is kept at story scope (via the RED batch); the two-stage review is kept (RED review up front +
per-increment green review).

See [`references/story-mode.md`](references/story-mode.md) for the full flow, the skill-per-step map,
the freeze rule, and the incremental-vs-big-bang rationale.

## Refactor Mode (Optional) — Behavior-Preserving Keep-Green

For **behavior-preserving change to existing behavioral code** — rename, extract, inline, de-duplicate,
restructure, move, or retype with **no change to observable behavior or public contract** — swap the
SDD per-task loop for a keep-green core. This is the **third sibling** of scaffold and story mode and
the **inverse of story mode**: story mode starts RED (new failing tests) and drives to green; refactor
mode starts GREEN and **stays green** the whole way. Scaffold mode refuses anything behavioral; story
mode *adds* behavior; refactor mode *touches* behavioral code but adds none.

1. **Guard** — confirm the change is behavior-preserving: no new/changed behavior, no altered
   request/response or persistence contract, no new trust-boundary surface. New or changed behavior →
   **story mode**. A bugfix is **not** a refactor (it changes wrong behavior) → story mode N=1. Pure
   non-behavioral bootstrap → **scaffold mode**.
2. **Pin green + characterize** (`dispatching-parallel-agents` + `requesting-code-review`) — run the
   existing suite over the surface and confirm it is green *before touching anything*. Where coverage
   of the code you're about to move is thin, author **characterization tests first** — the mirror of
   the RED batch: they must **pass immediately** (they pin current behavior). A characterization test
   that fails at baseline is a wrong test, not a found bug — route it back; never change behavior to
   green it. Review, then **freeze** this safety net.
3. **Transform incrementally** (`subagent-driven-development`, + `security-and-owasp` on trust
   boundaries) — apply the refactor in small reviewable steps; after **every** step the whole suite
   stays green. No long red period — a refactor that goes red has changed behavior (it is wrong, or it
   was story work in disguise). Behavioral/contract tests are frozen; only implementation-coupled unit
   tests may move in lockstep with the code, and that move goes through maker/checker review to prove
   it is coupling, not a silent behavior edit.
4. **Converge & verify-all** (`verification-before-completion`) — freeze, run the whole suite + every
   evidence kind on one fingerprint, and confirm the public contract is unchanged. Definition of Done:
   **same behavior, clearer structure** — the suite that passed at pin-green still passes, untouched.

TDD's red→green is replaced by keep-green (characterization + never-red transform); the two-stage
review is kept (characterization review up front + per-step transform review, + security on trust
boundaries).

See [`references/refactor-mode.md`](references/refactor-mode.md) for the full flow, the
behavior-preserving guard, the freeze/keep-green rule, and the characterization-vs-RED contrast.

## Composition Contract

When composed by a parallel orchestrator, this skill's gates may be **tightened** by overlays such
as: distinct adversarial verifier subagent, draft-only/no-merge worker boundary, and stricter
run-id/trace requirements.

## References

- **Story mode's green phase delegates the per-task implement → two-stage review loop to**
  `subagent-driven-development`, which **transitively** uses `test-driven-development` (implementation)
  and `requesting-code-review` (stage-2 rubric). Do **not** list those as separate steps — they are
  nested inside SDD, which is itself nested inside story mode.
- **Brackets both cores with** `using-git-worktrees` (isolation, before) and
  `verification-before-completion` (evidence gate, after).
- **Overrides** SDD's terminal `finishing-a-development-branch`: this skill stops at a **draft PR**
  (no local-merge menu); integration/merge is owned by repo process/CI.
- [`references/hooks.md`](references/hooks.md) — full hooks bundle: every script + event, install/env
  reference, portability notes, and what the run record does and doesn't capture.
- [`references/scaffold-mode.md`](references/scaffold-mode.md) — optional batch fan-out core for
  non-behavioral bootstrap: the eligibility guard, the generate→apply→batch-verify→review→PR flow,
  and the drop-vs-keep table.
- [`references/story-mode.md`](references/story-mode.md) — optional story-scoped phased-TDD core for
  behavioral user-story stages (Spec Kit `### Tests` + `### Implementation` split): the RED-batch →
  freeze → incremental-green flow, the skill-per-step map, and the incremental-vs-big-bang rationale.
- [`references/refactor-mode.md`](references/refactor-mode.md) — optional behavior-preserving
  keep-green core for refactors (rename/extract/restructure with no behavior change): the guard, the
  characterization safety-net, the never-go-red transform rule, and the keep-green-vs-RED-first contrast.
- Related orchestrator: `../executing-parallel-tracks/SKILL.md` (dispatches one run of this skill
  per track and layers parallel-only overlays).
