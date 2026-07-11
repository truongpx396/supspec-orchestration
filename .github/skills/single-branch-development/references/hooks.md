# Hooks Bundle (Optional, Composable)

This skill **ships the canonical hooks bundle** ([`../scripts/track-*.sh`](../scripts/) +
[`../templates/track-hooks.json`](../templates/track-hooks.json)). The quality gates in `SKILL.md`
are only as strong as the worker's compliance — unless you make them **mechanical**. Hooks turn the
*mechanical* gates (paths, forbidden commands, counters) into enforced ones; *judgement* gates (TDD
ordering, the maker/checker split, review quality) stay as prompt instructions because a hook cannot
tell which subagent reasoned about something.

Orchestrators that compose this skill reuse the same files and only layer extra env on top.

## How Copilot Hooks Work

Copilot's native [agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks) run shell
commands at lifecycle points (`PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop`, `Stop`,
…) and can **block a tool call before it happens**. Config lives in `.github/hooks/*.json`
(repo-scoped, so it travels with each worktree) and is read by VS Code Agent Mode, the Copilot CLI,
and the cloud agent. A `PreToolUse` hook receives the tool call as JSON on stdin and denies it via
exit code `2` (stderr → model) or `hookSpecificOutput.permissionDecision: "deny"`.

## Portability (No Matchers; Event Names Differ)

- **No `matcher` field.** Unlike Claude Code, Copilot hooks cannot scope to specific tools in
  config. A `PreToolUse` hook fires on **every** tool call, so the script must branch on `tool_name`
  from stdin and early-exit (allow) for tools it doesn't care about — which `track-guard.sh` already
  does.
- **Event names differ by surface.** The bundled `track-hooks.json` uses the VS Code keys
  (`preToolUse`, `postToolUse`, `subagentStart`, `subagentStop`, `stop`); the Copilot CLI /
  cloud-agent docs name the same events `agentStop` / `subagentStop` / `userPromptSubmitted` /
  `sessionEnd`. The *scripts* are surface-agnostic (they read stdin JSON); only the registration keys
  change if you run them under the CLI instead of VS Code.
- **Bash + `jq` only.** The bundle ships no PowerShell port; on non-bash surfaces run the scripts
  under a bash-compatible shell.

## Bundled Scripts

| Pipeline gate | Bundled script (event) | What it does |
|---|---|---|
| Start gate / mint-or-recover RUN_ID | `track-preflight.sh` (manual / skill Step 1) | **Start gate.** `inspect` mints a stable `RUN_ID` = `<UTC>_<track>` on a fresh start, or **recovers** it from an existing `runs/<id>.dispatch` breadcrumb (resume), then checks prerequisites (git tree, `runs/` writable, opt. `gh` auth + `PREFLIGHT_REQUIRE_TOOLCHAIN` bins). Prints a confirm summary + JSON; **hard-fails non-zero** on any unmet prereq (both interactive and `auto_confirm`). `--commit` persists the breadcrumb (track, tasks, branch, base ref, plus the confirmed writable scope, frozen paths, required toolchain, and evidence floor with their `*_set` flags) so resume is self-recovering and the artifact records exactly what the human confirmed. `--commit` also persists `RUN_ID` as a managed block in the installed `.github/hooks/track-env.sh` (gated on the `track-env.base.sh` marker, so it never touches the skill's `scripts/` source mirror) — this **activates the recorder hooks for a solo run** with no manual export; `--complete` retires that block. `--complete` (at draft-PR handoff) stamps `completed_utc` + `duration_secs` (now − `created_utc`) onto the breadcrumb — write-once, the honest home for the run's total wall-clock. Run by the skill, not a hook, since it precedes RUN_ID. |
| Resume / reconcile after interruption | `track-reconcile.sh` (`SessionStart`/`agentStart`) | **Read-only** preflight: from committed history + `runs/<RUN_ID>.json` only, emit `{head, dirty_worktree, evidence:{fresh,stale,missing,failed}, resumable}` at the current fingerprint — so a crashed/credit-out run resumes at the first not-done task and stashes untrusted uncommitted work, instead of the model guessing where it left off. Self-recovers `RUN_ID` from the `runs/<id>.dispatch` breadcrumb when none is exported. No-op unless a `RUN_ID` is set or recoverable. Mirrors `track-evidence-gate.sh`'s fingerprint logic exactly. |
| Scope / never edit frozen entrypoints | `track-guard.sh` (`PreToolUse`) | **Deny** an edit whose target path is outside `TRACK_ALLOWED_PREFIXES` or hits a `TRACK_FROZEN_PATHS` entrypoint (deny-by-default, per worktree). |
| Never hand-edit generated or applied artifacts | `track-guard.sh` (`PreToolUse`) | **Deny** edits to any file carrying a `GENERATED — DO NOT EDIT` banner (re-run the generator), and to already-committed files under `TRACK_IMMUTABLE_PREFIXES` (e.g. applied migrations — add a NEW file instead). A brand-new file under the prefix is allowed. |
| No auto-merge from a worker | `track-guard.sh` (`PreToolUse`) | **Deny** `git push`, `gh pr merge`, `--force`, `--no-verify`, `git reset --hard` on terminal calls. Workers physically stop at `gh pr create --draft`. Opt-in `TRACK_ALLOW_FF_PUSH=1` permits a plain fast-forward `git push` (for a PR-rework flow) while still denying `--force`/merge/`--no-verify`/`reset --hard`. |
| No irreversible data/infra ops *(opt-in)* | `track-guard.sh` (`PreToolUse`) | When `TRACK_GUARD_DESTRUCTIVE` is set, **deny** `DROP`/`TRUNCATE`, unbounded `DELETE FROM` (no `WHERE`), Redis `FLUSHALL`/`FLUSHDB`, NATS stream/consumer teardown, and `rm -rf` on absolute/home paths. Stack-specific — tune the patterns. |
| Evidence gate (recorded test output) | `track-evidence.sh` (`PostToolUse`) | Append `{kind, cmd, response, fingerprint}` for test commands into the run record — captured by the tool, not claimed by the model. `fingerprint` (HEAD + tracked diff + untracked non-ignored content hashes) ties each entry to the exact code it tested. **`tool_response` is textual, not a numeric exit code** (CI stays the pass/fail authority). |
| Evidence pack complete + fresh *(opt-in)* | `track-evidence-gate.sh` (`Stop`) | The closing “missing rows = not done” assertion. The required-kind set is **diff-conditional**: `TRACK_EVIDENCE_RULES` (`glob:kind` pairs) selects kinds by the paths the branch touched — so a frontend-only diff needs `ts`, a migration diff needs `pg-explain` — unioned with the optional always-on floor `TRACK_REQUIRED_EVIDENCE`. **`decision:block`** unless every selected kind has an entry whose `fingerprint` matches the **current** tree and whose response shows no failure marker — reporting exactly which are MISSING / STALE / FAILING. Selection is mechanical glob-matching (no model call); no-ops when both vars are unset or the diff selects nothing. Honors `stop_hook_active`; failure markers extend via `TRACK_FAIL_PATTERN`. Mechanizes verification-before-completion; CI stays authoritative. |
| Tool-call counter + ceiling | `track-meter.sh` (`PostToolUse`) | Count tool calls into `tool_calls` and stamp the heartbeat on **every** call whenever `RUN_ID` is set (no ceiling required). When `TRACK_MAX_TOOL_CALLS` is *also* set, emit `continue:false` + set `status:no-progress` on trip. **Hook I/O carries no token/cost data**, so token/$ ceilings stay orchestrator-side. |
| Activation trace | `track-trace.sh` (`SubagentStart`/`SubagentStop`) | Append a `trace` entry per subagent spawn/stop, capturing the agent name and — on `SubagentStart` — its one-line `agent_description` (the **reason** it was spawned) as `reason`; `SubagentStop` records a `stop_reason` instead. Field names are read across surfaces (`agent_type`/`agentName`, `agent_description`/`agentDescription`). The `Run-Id:` *commit trailer* is NOT set here — add it in the worker's commit command or a git `prepare-commit-msg` hook. |
| Pre-handoff secret/leftover scan *(opt-in)* | `track-sentinel.sh` (`Stop`) | When `TRACK_SENTINEL` is set, scan the **staged diff** and `decision:block` if it finds a likely secret or debug leftover (`console.log`, `debugger`, `TODO(claude)`, `FIXME`). Honors `stop_hook_active` so it can't loop; patterns override via `TRACK_SECRET_PATTERN`/`TRACK_LEFTOVER_PATTERN`. Defense-in-depth — CI/secret-scanning stays authoritative. |
| Token usage estimate *(on by default)* | `track-tokens.sh` (`Stop`) | When `TRACK_TOKEN_ESTIMATE` is set (default: `1` via `track-env.base.sh`), parse the `transcript_path` from the Stop payload, extract all text (user/assistant/tool-request fields), count chars, and write `token_estimate` (chars÷4) + `token_estimate_chars` + `token_estimate_method` into the run record. OVERWRITES on each Stop (transcript is cumulative; adding would double-count). The estimate **undercounts** — it cannot see the hidden system prompt, injected tool-schema definitions, or cached-token discounts. Disable by unsetting `TRACK_TOKEN_ESTIMATE`. |

## Install

**Recommended — the installer** ([`../scripts/install-hooks.sh`](../scripts/install-hooks.sh)).
Idempotent, consent-gated, drift-aware. It fixes the "install once, silently drift" footgun that
manual `cp` invites (a stale bundle runs the *old* hooks; a forgotten gitignore self-stales the
evidence fingerprint; a missing base preset runs the resume ungated):

```bash
install-hooks.sh --check   # exit 3 if installed bundle is missing/stale (drift probe)
install-hooks.sh           # DRY-RUN: print the plan, write nothing
install-hooks.sh --apply   # sync bundle + gitignore runs/ + seed stack-aware track-env.base.sh
```

It (1) syncs `scripts/track-*.sh` + `templates/track-hooks.json` into `.github/hooks/`, (2) ensures
`runs/` is gitignored, and (3) seeds `.github/hooks/track-env.base.sh` **only if absent**, pre-filled
from detected repo signals (`go.mod`→go-test, `pyproject.toml`→py, `package.json`→ts, `migrations/`,
default branch) — REPO-POLICY vars filled, TASK-DERIVED scope/floor left EMPTY so an unedited copy
fails loud. An existing base preset is never clobbered. `--apply` writes into shared repo config, so
the skill's Step 0 runs the dry-run, gets consent, then applies.

### Manual install (equivalent)

Copy every [`../scripts/track-*.sh`](../scripts/) into the repo's `.github/hooks/` directory and
place [`../templates/track-hooks.json`](../templates/track-hooks.json) there too. Each script is
**opt-in and no-ops unless its env is set**, so dropping them in is safe before configuring anything.

### Bootstrap (recommended): commit one repo preset, override per-worktree as needed

Hand-exporting a dozen `TRACK_*` vars every run is the #1 footgun — a resume that forgets them runs
**silently ungated** (guard off, evidence gate trivially passes). Instead, bind the config to a file
the hooks auto-source. There are two layers, both living in `.github/hooks/` next to the scripts:

```bash
# 1. Repo-wide base — commit it once; it travels into every worktree automatically.
cp .github/hooks/track-env.sh.example .github/hooks/track-env.base.sh   # from templates/track-env.sh.example
$EDITOR .github/hooks/track-env.base.sh                                 # values common to the whole repo
git add .github/hooks/track-env.base.sh && git commit                   # committed, shared across all tracks

# 2. (Optional) per-worktree override — only when a branch must deviate from the base.
cp .github/hooks/track-env.sh.example .github/hooks/track-env.sh        # gitignored, local to this worktree
$EDITOR .github/hooks/track-env.sh                                      # just the vars that differ
```

Every `track-*.sh` **auto-sources both files sitting next to it** (right after `set -eufo pipefail`) —
`track-env.sh` first, then `track-env.base.sh`. Because `track-env.base.sh` is committed, a fresh
worktree (single-branch **or** a parallel track) already has it; nothing is copied at start. Every
line uses `export VAR="${VAR:-default}"`, so precedence is **exported env > worktree `track-env.sh` >
repo `track-env.base.sh` > script default**: a worktree override beats the repo base, and an
orchestrator (`executing-parallel-tracks`) can still set per-track overrides on top of everything
without editing a file, keeping the composition contract intact. `RUN_ID` is deliberately **not** in
either *static* preset — it's minted per run by `track-preflight.sh`, recovered from the breadcrumb on
resume, and (at `--commit`) persisted as a managed block in the gitignored `.github/hooks/track-env.sh`
so the recorder hooks activate automatically; `--complete` retires that block.

### The vars (also settable manually)

The preset just wraps these — export them directly instead if you prefer, or to override the preset
for one run:

```bash
export TRACK_ALLOWED_PREFIXES="src/feature:test/feature"   # guard: this branch's writable scope
export RUN_ID="2026-06-27T14-03_feat"                       # <UTC-timestamp>_<track> — usually MINTED by track-preflight.sh (SKILL Step 1), not hand-set; STABLE across restarts so reconcile resumes the same record
export TRACK_FROZEN_PATHS="cmd/main.go:internal/app/app.go" # guard: frozen entrypoints (see caveat)
export RUNS_DIR="runs"                                       # RUN_ID keys the record + runs/<id>.dispatch breadcrumb. GITIGNORE THIS DIR: it's local run state, and if tracked, evidence writes shift the fingerprint (gate sees its own capture as STALE) and reconcile reads the tree as dirty (see Gotchas).
# OPTIONAL — each stays off until set
export TRACK_ID="setup"                                     # preflight: track slug for breadcrumb resume-matching
export TRACK_BRANCH="feat/setup-foundation"                # preflight: target branch name to work to (empty = derive from the track slug); validated with git check-ref-format
export PREFLIGHT_REQUIRE_GH=1                               # preflight: require authenticated gh (0 to waive for early setup runs)
export PREFLIGHT_REQUIRE_TOOLCHAIN="go,uv"                  # preflight: extra bins that must be on PATH
export TRACK_IMMUTABLE_PREFIXES="migrations/"               # guard: committed files here are append-only
export TRACK_GUARD_DESTRUCTIVE=1                            # guard: deny DROP/TRUNCATE/FLUSHALL/etc.
export TRACK_SENTINEL=1                                     # Stop: scan staged diff for secrets/leftovers
export TRACK_TEST_CMD_PATTERN="go test|uv run pytest|npm (run )?test"  # evidence: SIMPLE mode — tag every matching test call as a single "test" kind. Use this OR TRACK_EVIDENCE_KINDS, not both: KINDS supersedes it with per-pack labels.
export TRACK_EVIDENCE_KINDS="go-test:go test -race;py:uv run pytest;ts:tsc --noEmit"  # evidence: MULTI-KIND mode — tag by pack row (label:pattern). Labels here MUST match the kinds used in TRACK_EVIDENCE_RULES / TRACK_REQUIRED_EVIDENCE (preflight warns on any mismatch).
export TRACK_EVIDENCE_RULES="*.go:go-test;*.py:py;*.tsx:ts;*.ts:ts;migrations/*:pg-explain"  # Stop gate: diff path → required kind
export TRACK_REQUIRED_EVIDENCE=""             # Stop gate: kinds required on EVERY diff (floor); empty = rules-only
export TRACK_BASE_REF="main"                  # Stop gate / reconcile: diff base. STRONGLY RECOMMENDED — without it, once work is COMMITTED the diff-vs-HEAD is empty so the gate requires nothing and silently passes (see Gotchas). Falls back to branch upstream, then HEAD-only.
export TRACK_MAX_TOOL_CALLS=200                                       # tool-call ceiling (hard stop). NOTE: counting/heartbeat are always-on when RUN_ID is set — this var only ADDS the halt.
export TRACK_NOTIFY_WEBHOOK="https://hooks.slack.com/services/..."     # notify
export TRACK_ALLOW_FF_PUSH=1                   # guard: permit a plain (fast-forward) git push — for a PR-rework flow updating an existing PR branch. --force/merge/--no-verify/reset --hard STAY denied. Leave unset for the default push lockout (worker stops at the draft PR).
```

**Hooks are defense-in-depth, not the final gate.** They are local and bypassable. Layer them:
hooks (fast, in-session) → git `pre-push` (local backstop) → **CI (the unbypassable merge gate)**.

For foundation/bootstrap runs, avoid freezing paths too early. If entrypoints do not exist yet,
leave `TRACK_FROZEN_PATHS` unset for the bootstrap branch, then enable strict frozen entrypoints for
subsequent parallel tracks.

## What the Run Record Captures (and What It Deliberately Doesn't)

The run record `runs/<RUN_ID>.json` is written **per hook event, not per loop iteration**, and only
holds what hooks can actually observe. It is **opt-in**: every field below stays empty unless the
hook *and* its env are set — launch without them and the run still works but records nothing. The
one convenience: `track-preflight.sh --commit` persists `RUN_ID` into the installed `track-env.sh`, so
the **mechanical** fields (`tool_calls`, `trace[]`, heartbeat) record automatically even in a solo run;
the **self-reported** fields (`skills[]`, `iterations`) still require the model to call `track-note.sh`.

| Recorded | Field | Written on | Source |
|---|---|---|---|
| Schema version | `v` (integer, currently `1`) | first hook to touch the record | any writer — all seed the **same** canonical skeleton `{run_id, v, trace, evidence, tool_calls}` |
| Heartbeat | `started_ts` (first event) / `last_ts` (latest event) | **every** hook write (`track-meter.sh` / `track-trace.sh` / `track-evidence.sh`) | orchestrator derives **idle/staleness** = `now − last_ts` (a hung/crashed worker stops advancing it — the count-based caps can't see that) and **run wall-clock** = `last_ts − started_ts`. Resolution = frequency of whichever hooks are enabled: `track-trace.sh` (RUN_ID-only) stamps on subagent boundaries; `track-meter.sh` (also RUN_ID-only now) stamps on **every** tool call for finer granularity. |
| Tool-call count | `tool_calls` (running integer) | **every** `PostToolUse` | `track-meter.sh` — `+1` per call whenever `RUN_ID` is set; halts only if `TRACK_MAX_TOOL_CALLS` is also set |
| Subagent spawn/stop timeline | `trace[]` (`{t, kind, event, agent_id, agent_type, reason?, stop_reason?}`) | `SubagentStart` / `SubagentStop` | `track-trace.sh` — `reason` (the agent's `agent_description`) is present on **start** only; `stop_reason` on **stop** only. |
| **Self-reported** skill order | `skills[]` (`{t, skill, step, self_reported:true}`) | skill calls `track-note.sh skill …` at each core step | `track-note.sh` — the model's **own claim**, not hook-observed (no hook can see a skill name). Provenance-tagged so it can't be mistaken for verified truth. |
| **Self-reported** loop count | `iterations` (integer) + `iterations_self_reported:true` (+ optional `iteration_log[]`) | skill calls `track-note.sh loop …` once per RED→GREEN→review cycle | `track-note.sh` — asserted by the model; hooks never see a reasoning loop. `tool_calls` remains the only mechanical turns-proxy. |
| Test evidence | `evidence[]` (`{t, kind, cmd, response, fingerprint}`) | `PostToolUse` matching a **test** command only | `track-evidence.sh` |
| Terminal state | `status` (`no-progress` only) | when the tool-call ceiling trips | `track-meter.sh` — the **only** hook that writes `status` |
| Token estimate *(opt-in)* | `token_estimate` (integer) + `token_estimate_chars` + `token_estimate_method` | once per `Stop`, **overwritten** each time | `track-tokens.sh` (enabled by `TRACK_TOKEN_ESTIMATE=1`) — chars÷4 heuristic off the transcript; undercounts system prompt + cached tokens; labelled as estimate so it can't be mistaken for billing data |

**Deliberately NOT recorded** (don't expect these in the file):

- **No loop / review-iteration count.** The TDD + 2-stage-review loop and the `self_heal_attempts`
  cap live inside SDD's in-context reasoning; hooks never see review rounds. `tool_calls` is the only
  (approximate) "turns" proxy. *(A skill may **self-report** a loop count via `track-note.sh loop` —
  stored as `iterations` + `iterations_self_reported:true` — but that is the model's claim, not a
  hook-observed fact.)*
- **No token or cost data.** Hook I/O carries none, so only a **tool-call** ceiling is enforceable
  here; token/$ ceilings stay orchestrator-side.
- **No per-tool `duration_ms`.** A `PostToolUse` hook fires only *after* a call and gets no start
  time, so a single call's duration isn't measurable here. Use `last_ts − started_ts` for run
  wall-clock and the gaps between consecutive `trace[]` timestamps to approximate per-step duration.
- **No per-tool argument log.** `tool_calls` is a bare counter; non-test tool calls (reads, `ls`,
  edits) tick it but are not itemized. Only **test** commands land in `evidence[]`.
- **`response` is textual, not an exit code.** `PostToolUse` exposes a (possibly truncated) text
  result, so CI — not the recorded string — remains the authoritative pass/fail.
- **No `blocked`/`passed` status.** `track-evidence-gate.sh` enforces the Stop gate by **returning a
  block decision + message**, not by stamping a field — so a blocked run leaves no `status` in the
  record, and a passing gate is **silent** (no positive marker). Only `track-meter.sh` writes
  `status:"no-progress"`. Treat "block" as a prompt/CI concern, not a recorded terminal state.

## Rendering a Completion / PR Report

`track-report.sh` (Step 8, run by the skill — not a hook) renders the **deterministic half** of a
PR/stage report straight from state that already exists, so the factual part cannot drift from reality:

```bash
bash .github/hooks/track-report.sh            # uses $RUN_ID, or recovers it from the newest runs/*.dispatch
bash .github/hooks/track-report.sh --json     # same facts as a JSON object, for tooling
```

It emits an **Auto block** (files changed + `--shortstat` from the `TRACK_BASE_REF` diff; `evidence[]`
as a fingerprint + pass/fail table; `tool_calls`; the `trace[]` subagent order; and — under a clearly
separate *self-reported* heading — `skills[]` / `iterations`). It also emits a **Compliance warnings**
section: if the record shows an *empty evidence pack* or *no `requesting-code-review` activation*, it
prints a ⚠️ for each (also surfaced as a `warnings[]` array in `--json`) so a skipped Step-5 review or
an un-captured verification is visible in the PR body itself rather than in a later audit — the one
mechanical backstop for the two gaps a hook cannot otherwise observe. It is **read-only**: it never
mutates the record, the tree, or git. The **narrative half** (constitution/OWASP compliance, caveats,
"after merge") is a model *assertion* and is authored by hand into [`templates/pr-body.md`](../templates/pr-body.md),
whose `{{AUTO_BLOCK}}` placeholder is where the script's output goes. Keeping machine-rendered facts
and model claims in two visibly separate zones is the same discipline the record applies with
`self_reported:true`.

