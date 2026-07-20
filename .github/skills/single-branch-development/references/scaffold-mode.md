# Scaffold Mode (Optional) — Batch In-Session Fan-Out

Scaffold mode is **one of the skill's three execution cores** (the others are
[story mode](story-mode.md) and [refactor mode](refactor-mode.md)).
Story mode handles behavioral work that adds or changes behavior — it authors a failing RED test batch,
then greens implementation via `subagent-driven-development` (SDD); refactor mode handles
behavior-preserving change to existing code (keep-green). Scaffold mode is the **non-behavioral
counterpart**, for a narrow, explicitly-declared class of work: *mechanical, non-behavioral bootstrap
files with no test obligation and no trust-boundary surface.*

Everything **around** the core is unchanged — the same preflight, isolation, run-log/`RUN_ID`,
hooks bundle, evidence gate, and draft-PR finish. Only steps 2–5 of the pipeline swap out.

## Why it exists

Bootstrap stages (project skeleton, dependency manifests, lint/format configs, compose/proxy files,
`Makefile` targets, test-harness scaffolding) are:

- **`[P]`-heavy** — many disjoint one-file tasks with no interdependencies, *and*
- **non-behavioral** — there is nothing to test-first; a `docker-compose.yml` or `.golangci.yml` has
  no red/green cycle. Forcing them through SDD's per-task TDD + two-stage review loop is pure
  overhead for zero quality gain.

Scaffold mode exploits the `[P]` disjointness for **parallel generation latency** while keeping the
one guarantee that still matters for bootstrap: *the scaffold actually builds and comes up.*

## The hard boundary — why `[P]` is NOT the trigger

`[P]` means "different files, no incomplete-task dependency." It says **nothing** about whether a
task is behavioral. In a real plan, `[P]` sits on both:

- **Non-behavioral scaffolds** — e.g. compose files, lint configs, manifests. ✅ eligible.
- **Behavior-bearing, security-critical code** — e.g. an access-control filter (often a release
  blocker), hybrid retrieval, auth middleware. These **must** go through story mode's RED-batch TDD +
  spec review + security review. ❌ never eligible.

If scaffold mode ever keys on `[P]`, it will eventually eat a security-critical task and **silently
skip test-first + the two-stage review** on exactly the path you can least afford. So the trigger is
an **explicit allowlist / `scaffold_only` flag on the batch**, plus a refusal guard (below) — never
the `[P]` marker itself.

### Eligibility guard (refuse the whole batch on any hit)

Before generating anything, assert **every** task in the batch is non-behavioral. Refuse and route
the batch to **story mode** if **any** task:

1. has a contract/integration/unit **test obligation**, or
2. touches a **trust boundary** — input handling, auth/authz, secrets, DB/persistence, or network, or
3. carries a requirement/spec ID tied to a security or correctness success-criterion.

The guard is all-or-nothing: one behavioral task in the set disqualifies the *batch*, not just that
task. When in doubt, treat a task as behavioral and refuse — the cost of a wrong refusal is one
story-mode run; the cost of a wrong acceptance is unreviewed security code.

## Pipeline (scaffold core)

Steps 0/1 (preflight + isolate) and 6 (draft PR) are identical to the universal bracket. Only the
core differs:

```
0.  Preflight & isolate branch                                   [reuse: track-preflight.sh]
1.  GUARD: assert every batched task is non-behavioral            [refuse → story mode]
2.  FAN-OUT generate — N read-only subagents, one per INDEPENDENT
    DOMAIN / DISJOINT-FILE CLUSTER (not one-per-file, not
    one-per-task), each RETURNS its file bodies as strings
    (no disk writes)                                             [parallel ✅  dispatching-parallel-agents]
3.  APPLY all returned bodies to the worktree at once             [serial, single writer, instant]
4.  ONE batch verify against the converged tree:
    build (all runtimes) + lint + bring-up health check           [serial → verification-before-completion]
5.  ONE code review over the whole scaffold diff                  [serial → requesting-code-review]
6.  Draft-PR finish                                              [reuse: overrides finishing-a-development-branch]
```

### Which superpowers skill runs at which step

Every step's owning skill is **explicit** — nothing is implied by a `[P]` marker or inferred at
runtime. The two SDD-core skills (`test-driven-development`, `subagent-driven-development`) are
**deliberately absent**: the Step-1 guard proved the batch is non-behavioral, so there is no
test-first cycle and no per-task implement↔review loop to run.

| Step | Action | Skill ("—" = no skill) | Why this skill / why none |
|---|---|---|---|
| 0 | Preflight & mint `RUN_ID` | `track-preflight.sh` (this skill's bundle) | Durable run identity + prereq gate — a script, not a superpowers skill |
| 0 | Isolate branch/worktree | `using-git-worktrees` | Never start on main; one branch, one worktree |
| 1 | Eligibility guard | — (local refusal guard) | All-or-nothing non-behavioral assertion; routes to story mode on any hit |
| 2 | Fan-out generation | `dispatching-parallel-agents` | One subagent per independent domain / disjoint-file cluster returns its file bodies in parallel — safe because nothing writes |
| 3 | Apply bodies | — (controller = single writer) | Collapses N proposals into one tree; serial application, no skill |
| 4 | Batch evidence | `verification-before-completion` | "Does it work" proof — real build/lint/bring-up output, not assertion |
| 5 | Whole-diff review | `requesting-code-review` | "Is it correct" proof — quality + governance rubric (constitution hard gate + matched `.github/instructions/*`; no security add-on — guard cleared trust boundaries) |
| 6 | Draft-PR finish | **overrides** `finishing-a-development-branch` | Worker stops at a draft PR; merge is owned by repo/CI |

**Steps 4 and 5 are orthogonal and both mandatory.** `verification-before-completion` (Step 4)
answers *does the scaffold actually build and come up*; `requesting-code-review` (Step 5) answers *is
the diff correct and well-formed*. Neither substitutes for the other — a scaffold can build cleanly
yet be wrong, or read well yet never come up. Scaffold mode drops TDD and the two-stage loop, but it
**never** drops either of these two.

### Step 2 — parallel generation is safe because nothing writes

The fan-out subagents are **read-only**: each receives its cluster's task text + the relevant
design-doc context and **returns the file body (or bodies) as text**. They do not touch the git index,
do not run tests, do not commit. That is why in-session parallelism is safe here and *not* in story
mode's serial green phase — there is no shared mutable worktree during generation, so none of the
single-index / whole-tree-fingerprint hazards apply. (See the SKILL Gotcha on in-session fan-out.)

**Each subagent's brief must also carry the governance set** (see the SKILL Step-4 "governance is a
maker obligation" rule). Along with the cluster's task text and design-doc context, embed: (a) the
relevant **constitution** principles (`.specify/memory/constitution.md`, if present) — e.g. the
kernel-cannot-import-product rule for a Go cluster; (b) the `.github/instructions/*` that match the
files the cluster will produce — `go` for a Go cluster, `reactjs`/`state-management` for a frontend
cluster, `python` for a Python cluster; and (c) `security-and-owasp.instructions.md` for any cluster
touching a deploy/secrets/network surface (`docker-compose.yml`, a proxy config, a `.env` template).
(d) **For frontend clusters** (any cluster producing `.tsx`/`.ts`/`.jsx`/`.css` files): also embed the
relevant design artefacts collected during the SKILL Step-4 discovery — the matching
`.stitch/designs/<page>.html` mock and/or the `design-system/` page spec — if those files exist.
Pass silently if absent. Without these, the subagent generates UI from inference rather than the
approved design, requiring a separate alignment pass.
Tell the maker in-brief that these are **binding**: the config it returns must *already* satisfy them
— pinned image tags (no `:latest`), no committed default credentials (env placeholders with a dev
fallback), security headers on public-facing proxies, strict type/lint settings, coverage floors that
match the constitution. Governance discovered only at Step 5 review is a bug you paid a round-trip for
— it is the exact failure mode that ships hardcoded `POSTGRES_PASSWORD` in a bootstrap PR.

**The fan-out unit is an independent domain (a disjoint-file cluster) — NOT one-per-file, and NOT
one-per-task.** This is the same rule `dispatching-parallel-agents` states: *one agent per independent
problem domain*, not per file. Two facts force this:

- **A file may be written by more than one task.** In a real Setup batch, one manifest often satisfies
  two `[P]` tasks — e.g. a Python `pyproject.toml` holds both the *dependencies* task and the
  *ruff/black lint config* task. "One agent per file" is undefined here (two tasks, one file) and
  "one agent per task" is a race (two agents writing the same path). Both tasks belong to **one**
  agent that owns that file, so the file stays internally consistent.
- **A task may span several files.** A test-harness task can create Go, Python, and Playwright fixtures
  at once; the frontend cluster owns `package.json` + `eslint`/`prettier` + `tsconfig` + `vite.config`
  together. Splitting these across agents fragments a coherent config.

So group the batch into **disjoint-file clusters** (natural seams: per-runtime, per-tool-surface,
per-deploy-area), give each cluster to one subagent, and guarantee **no two agents share a target
file**. `[P]` tells you tasks *can* run concurrently; the clustering tells you *how to slice the
agents* without two of them racing the same path. If you cannot cleanly partition the files, the tasks
are not disjoint and must not fan out.

### Step 3 — the controller is the only writer

The controller applies every returned body in one pass. Single writer ⇒ no `.git/index.lock` race,
deterministic tree. This is the moment the N parallel proposals collapse into **one** tree state.

"The only writer" also means the controller is **only** a writer, never the generator. If you find
yourself composing file contents from your own reasoning and saving them directly — skipping Step 2's
read-only subagents because the files are "trivial config" or a subagent-per-file feels heavyweight —
you have collapsed generate and apply into one role and **dropped the fan-out**. The delegation is the
discipline, not an optimization to trade away: generation is delegated to the subagents, application
is the controller's sole job. A converged tree that the controller authored itself is a scaffold-mode
violation even though it "looks the same."

### Step 3a — generate ONLY the task-declared surface (no speculative structure)

Both the subagents (Step 2) and the controller (Step 3) are bounded by the **files and directories the
batched tasks explicitly name** — nothing more. A scaffold task that says *"create
`backend-go/{cmd/api,kernel,internal,migrations,tests}`"* declares **those** directories; it does **not**
license pre-creating the entire downstream architecture (every future `internal/<domain>/{dto,errors,
infra,model,service}`, every kernel port, every `cmd/<x>`) that later stages' tasks will introduce.
Materializing that speculative tree — typically as a blast of one `.gitkeep` per anticipated leaf —
is a scope breach: it drags dozens of empty directories for **unreached tasks** into a bootstrap PR,
front-runs design decisions that belong to those later tasks, and buries the real scaffold in noise.

Two rules keep the batch contained:

- **Subagents (Step 2):** return only the files each batched task's text names. Do not invent directories
  for tasks outside the batch, and do not "round up" a named parent (`internal/`) to its imagined
  children. If a task genuinely needs an *empty* directory to exist (Git cannot track an empty dir),
  represent it with **exactly one** `.gitkeep` **in that task-named directory only** — never a recursive
  spray across a tree the task did not enumerate.
- **Controller (Step 3):** before applying, diff the returned path set against the batch's declared
  surface. **Reject or trim any path outside it** — an out-of-scope path is a generation error, not a
  head start. A `.gitkeep` count that dwarfs the number of directories the tasks actually name is the
  tell-tale sign the fan-out over-reached; trim back to the declared surface before committing.

Rule of thumb: the scaffold PR should contain the batch's real files plus the *minimum* set of empty
directories those tasks name — not a materialized map of the whole future codebase.

### Step 4 — batch evidence via `verification-before-completion` (do NOT skip)

Scaffold mode drops per-task TDD and per-task review, but it **keeps one `verification-before-completion`
capture**. Evidence here is not a TDD artifact — it is the "does this actually work" proof, and it is
cheap. Without it you can open a PR where a manifest won't resolve, a compose file won't parse, or the
stack won't come up, and **nobody noticed** because the only check was an LLM reading its own output.
This step is orthogonal to Step 5's review — see [the skill-per-step map](#which-superpowers-skill-runs-at-which-step):
verification proves the scaffold *works*, review proves it is *correct*, and neither is optional.

The scaffold's Definition of Done is the plan's own **bootstrap checkpoint** — typically some form of
*"all runtimes build; the infra stack comes up."* Realize it as one command set against the converged
tree, then paste real output:

```
build all runtimes  +  lint  +  bring the stack up (health check)  →  paste output  →  then PR
```

Mechanically this reuses the existing evidence gate exactly once over the whole batch — the
whole-tree fingerprint is *happy* here because there is a single converged tree, one evidence pack,
one commit. (Contrast story mode, where per-increment captures must each converge on the final tree
at freeze & verify-all.)

### Step 5 — one review, not two-stage

A single `requesting-code-review` pass over the entire scaffold diff replaces SDD's per-task
stage-1 (spec) + stage-2 (quality) loop. The rubric is **quality + governance** (project
constitution as a hard gate; matched `.github/instructions/*` applied to the diff). The security
add-on that story mode requires does **not** apply — the guard already established there is no
trust-boundary surface in the batch. (If a task *did* touch a trust boundary, the guard would have
refused the batch.)

## What scaffold mode drops vs. keeps

| Aspect | Story core | Scaffold core |
|---|---|---|
| Execution | Serial: RED batch → incremental green | **Parallel generate (one agent per disjoint-file cluster)** → serial apply/land |
| TDD (test-first) | Required — story-scoped RED batch | **Dropped** — nothing behavioral to test |
| Review | RED review + per-increment spec/quality (+ security) | **One** whole-diff `requesting-code-review` (quality + governance; no security add-on) |
| Evidence | Whole story suite, converged at freeze & verify-all | **One** batch build/lint/bring-up capture — **kept** |
| Commit | One per increment | One (or few) for the batch |
| Preflight / isolation / run-log / hooks / draft-PR | — | **Identical (reused)** |

## When to use / when to refuse

**Use** for: project skeletons, dependency manifests, lint/format configs, compose/proxy/`Makefile`
files, CI wiring, test-harness bootstrap — the pure-config slices of a "Setup" stage and nothing
else.

**Refuse** (route to **story mode**) the moment a batch contains: any test obligation, any migration
with RLS/policy logic, any auth/secrets/DB/network handling, any access-control or correctness
success-criterion. Foundational and user-story stages are almost entirely behavioral — treat them as
**story mode** by default.

## Composition

Scaffold mode is still **one branch, one worktree**. It is *not* a substitute for
`executing-parallel-tracks` (worktree-per-track) — its parallelism is confined to the read-only
generation phase and its landing is serial. A parallel orchestrator may still dispatch one
scaffold-mode run as a track's bootstrap step, then fan out behavioral tracks via story mode.
