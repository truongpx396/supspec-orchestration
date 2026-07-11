# Track Manifest — <PROJECT NAME>

Per-repo configuration consumed by the `executing-parallel-tracks` skill. Fill every field; the
skill asks the user only for values missing here. Keep project-specific facts in THIS file, never in
the skill.

## Defaults

- **default_branch**: `main`
- **worktree_root**: `..` (worktrees created as siblings of the repo, e.g. `../<repo>-<track>`)
- **docker_namespace_pattern**: `<repo>_<track_id>` (exported as `COMPOSE_PROJECT_NAME`)
- **max_concurrent_tracks**: `2`  <!-- raise only if the Docker host has headroom -->
- **runs_dir**: `runs/` (git-ignored; run records + summary.md live here)
- **notify_webhook**: `<optional Slack/Discord/generic URL, or leave blank to disable>`

## Hard stops (orchestrator-enforced)

- **self_heal_attempts**: `2`        <!-- fix attempts per failure, then `blocked` -->
- **max_iterations**: `25`           <!-- turns per worker, then `no-progress` -->
- **no_progress_passes**: `3`         <!-- stalled verifier passes, then `no-progress` -->
- **per_worker_budget_usd**: `<e.g. 5>`   <!-- then `budget-exceeded` -->
- **global_budget_usd**: `<e.g. 20>`      <!-- fleet ceiling across ALL workers -->

## Commands

| Purpose | Command |
|---|---|
| lint | `<e.g. make lint>` |
| unit test | `<e.g. make test>` |
| integration test | `<e.g. go test -tags=integration ./... ; pytest -m integration>` |
| e2e | `<e.g. npx playwright test>` |
| regenerate Go lockfile | `go mod tidy` |
| regenerate Python lockfile | `uv lock` |
| open PR | `gh pr create --fill --base <default_branch>` |

## Evidence pack (required to claim done)

The rows a worker MUST produce fresh, passing output for before finishing — the
mechanical form of “missing rows = not done.” The skill ships the *gate*; this table
supplies the stack-specific *content*. Each row is a `kind` label + the command
pattern that satisfies it. `track-evidence.sh` tags matching runs with the label;
`track-evidence-gate.sh` blocks the stop until every **required** kind has a fresh
(current-tree) passing entry.

| kind | command pattern (ERE) | required when… | path glob (selects this kind) |
|---|---|---|---|
| `go-test` | `<e.g. go test -race .*\./\.\.\.>` | any `.go` change | `*.go` |
| `py` | `<e.g. uv run pytest>` | any `.py` change | `*.py` |
| `ts` | `<e.g. tsc --noEmit>` | any `.ts/.tsx` change | `*.ts` ; `*.tsx` |
| `pg-explain` | `<e.g. EXPLAIN \(ANALYZE>` | query/migration changes | `migrations/*` ; `*/queries/*.sql` |
| `nats` | `<e.g. nats consumer info>` | producer/consumer changes | `*/events/*` ; `*/nats/*` |
| `redis` | `<e.g. redis-cli TTL>` | new Redis interactions | `*/cache/*` ; `*/redis/*` |

Requirements are **diff-conditional**: a kind becomes required only when the branch's
diff touches a path its glob matches — so a frontend-only task demands `ts`, never
`pg-explain`, and a migration task demands `pg-explain`. The selection is mechanical
glob-matching on touched paths (no model call). Globs are shell patterns where `*`
spans `/` (a leading `**/` is tolerated); `;`-separate multiple globs for one kind.

- **TRACK_EVIDENCE_KINDS** = the `kind:pattern` (command-ERE) pairs above, `;`-joined.
- **TRACK_EVIDENCE_RULES** = the `glob:kind` pairs above, `;`-joined — the
  path→kind selector, e.g. `*.go:go-test;*.py:py;*.tsx:ts;*.ts:ts;migrations/*:pg-explain`.
- **TRACK_REQUIRED_EVIDENCE** (optional floor) = kinds required on **every** diff
  regardless of paths, comma-joined. Leave empty to rely purely on the rules; the
  gate enforces the UNION of this floor and the diff-selected kinds.
- **TRACK_FAIL_PATTERN** (optional) = stack-specific failure markers the generic
  default misses, e.g. `Seq Scan on (users|events|messages)|TTL .* -1|AckPolicy: *None|MaxDeliver: *-1`.

## Frozen entrypoints (self-registration required)

List files that must NOT be edited per track; tracks register via their own module/router file.

- `<e.g. backend-go/cmd/api/main.go — iterates module registry>`
- `<e.g. backend-python/src/app.py — iterates APIRouter list>`

## Ownership map (shared resources)

| Shared resource | Owner | Rule for everyone else |
|---|---|---|
| dependency manifest (`go.mod` / `pyproject.toml`) | one track per language this wave | others request via owner; never edit another language's manifest |
| lockfiles (`go.sum` / `uv.lock`) | the PR being merged | NEVER hand-merge — regenerate after rebase |
| `<shared types/enums file>` | append-only | add symbols; never edit the middle |

## Invariants to assert in review

Project release-blockers the code-quality reviewer must confirm on every relevant diff.

- `<e.g. access control deny-by-default + zero-above-clearance (SC-001)>`
- `<e.g. kernel/ must never import internal/>`

## Hook environment (derived — do not invent values)

The optional [Copilot agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks)
bundled with the skill read these env vars. **Every value is derived from a field above** —
this table is the mapping, not a new source of truth. Export them per-worktree *before*
launching each worker; each hook no-ops until its var is set.

**Scope matters:** *per-track* vars take a DIFFERENT value in each worktree; *global* vars
are identical across all workers in a wave. Export the per-track ones inside each worker's
launch, not once for the fleet.

| Env var | Scope | Hook | Derived from |
|---|---|---|---|
| `TRACK_ALLOWED_PREFIXES` | **per-track** | `track-guard.sh` | this track's `owns_paths` + `owns_migrations` range in the **Tracks** YAML (colon-separated) |
| `TRACK_FROZEN_PATHS` | global | `track-guard.sh` | **Frozen entrypoints** list (colon-separated) — same deny-set for every track |
| `RUN_ID` | **per-track** | evidence/meter/trace/notify | the run-id minted at dispatch (`<UTC-timestamp>_<track_id>`) |
| `RUNS_DIR` | global | evidence/meter/trace/notify | **Defaults → runs_dir** (one shared dir; the per-track `RUN_ID` keys the file) |
| `TRACK_TEST_CMD_PATTERN` | global | `track-evidence.sh` | an ERE OR-ing the **Commands** unit + integration entries |
| `TRACK_EVIDENCE_KINDS` | global | `track-evidence.sh` | the **Evidence pack** `kind:pattern` (command-ERE) pairs, `;`-joined |
| `TRACK_EVIDENCE_RULES` | global | `track-evidence-gate.sh` | the **Evidence pack** `glob:kind` (path→kind) pairs, `;`-joined — diff-conditional selector |
| `TRACK_REQUIRED_EVIDENCE` | global | `track-evidence-gate.sh` | the **Evidence pack** kinds required on every diff (the always-on floor), comma-joined — may be empty |
| `TRACK_FAIL_PATTERN` | global | `track-evidence-gate.sh` | **Evidence pack** stack-specific failure markers (optional) |
| `TRACK_MAX_TOOL_CALLS` | global | `track-meter.sh` | **Hard stops → max_iterations** (tool-call proxy; token/\$ ceilings stay orchestrator-side) |
| `TRACK_NOTIFY_WEBHOOK` | global | `track-notify.sh` | **Defaults → notify_webhook** (the only value not already implied elsewhere) |

> Resolution is two-tier: **per-track** vars come from the track's own row in **Tracks**
> below; **global** vars come from the sections above and are identical for every worker.
> There is no per-track override of a global value. If two worktrees need different prefixes,
> that difference lives in their distinct `owns_paths` — never overlapping (overlap is a
> precheck failure, since it would become a merge conflict).

## Tracks

```yaml
tracks:
  - id: <track_id>            # e.g. us1
    branch: track/<track_id>
    worktree: ../<repo>-<track_id>
    tasks: [<Txxx>, <Txxx>]   # task IDs from tasks.md / dispatch doc
    owns_paths:               # source paths this track may edit -> TRACK_ALLOWED_PREFIXES
      - <e.g. internal/ingest>
      - <e.g. test/ingest>
    owns_migrations: ["<range, e.g. 0010>"]
    depends_on: []            # other track ids that must merge first, if any
```
