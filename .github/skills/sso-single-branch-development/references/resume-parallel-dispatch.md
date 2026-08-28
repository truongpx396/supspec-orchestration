# Resuming a Parallel Dispatch — recovering from a wave that died mid-flight

Every execution core's fan-out step (story mode's RED BATCH, scaffold mode's GENERATE,
refactor mode's PIN-GREEN) dispatches N read-only `dispatching-parallel-agents` subagents
that **return text; the controller is the sole writer** (see each mode's own doc). That design
is what keeps parallel generation safe — no shared mutable worktree during generation, no
`.git/index.lock` race. It has one cost this doc exists to cover: a generator that dies
**before** returning (an account-level session limit, a transient outage) leaves nothing on
disk. Its work exists only inside its own transcript, in a location this repo does not own.

This is not hypothetical. A real run dispatched 9 clusters, hit a mid-batch governance-content
finding, corrected and re-dispatched all 9, then the account hit its session limit and **all
18** dispatches failed within the same few seconds — because nothing capped how many were
in flight together. Recovering meant hand-extracting text from harness-internal transcript
files after the fact. The two things below exist so that recovery is routine instead of
forensic.

## 1. Cap the wave, so a shared failure is small

Dispatch in waves of at most `TRACK_MAX_PARALLEL_AGENTS` (default 5, `track-env.base.sh`), and
let a wave **fully resolve** — every dispatch returned or failed, every result recorded (§2) —
before starting the next wave. This does not prevent an account-level outage; it bounds its
blast radius to one wave instead of the whole batch, and keeps the recovery in §3 small enough
to actually do.

This is prompt-enforced, not hook-enforced: no hook can reliably count in-flight background
dispatches across every surface. Assert the wave size out loud before dispatching it, the same
way scaffold mode asserts dispatch counts at the GENERATE boundary.

## 2. Record each result as it lands — the recovery anchor

The moment a dispatched subagent's own notification arrives (it returned, or it failed —
either is a result), call:

```
track-note.sh dispatch-result "<desc>" <status> <output_file> ["<summary>"]
```

using exactly the notification's own fields — `<desc>` is the same description the dispatch
used (so it correlates back to `briefs[]`), `<status>` and `<output_file>` come straight from
the notification, `<summary>` is optional and may be truncated. This is cheap (one CLI call,
no new file) and it is the ONLY place this information can be captured: the notification, and
the transcript path inside it, are visible to the model on its own turn — no `PostToolUse` or
`SubagentStop` hook payload is guaranteed to carry it. That is why this lives in
`track-note.sh` (self-reported, tagged `self_reported:true`) rather than a mechanical hook —
same reasoning as `phase`/`governance_bundle`/`status`.

Do this for every result, success included. A successful generator's `output_file` is
harmless to have on record and costs nothing; a failed one is exactly what §3 needs.

## 3. On resume — recover before you redispatch

A fresh session (or the same session after a reset) picking this run back up should, in order:

1. **`track-reconcile.sh`**, as always — re-anchor `phase`/`governance_bundle`/evidence from
   durable state before touching anything else.
2. **Read `dispatch_results[]`** from `runs/<RUN_ID>.json` for the phase reconcile just
   reported. Entries with `status` other than a success (or clusters with a dispatch in
   `trace[]`/`briefs[]` but no matching `dispatch_results[]` entry at all — died before
   returning anything) are the candidates worth checking.
3. **For each candidate, check the `output_file` still exists** (`[ -f "$output_file" ]`)
   before assuming anything is recoverable. It is OS-managed scratch space this repo does not
   own — no persistence guarantee, may already be gone. That is expected, not an error:
   redispatch that cluster fresh, exactly as before.
4. **If it exists, extract text — never read the file raw.** It is a full JSONL transcript
   (every tool call, thinking block, and turn); loading it wholesale can overflow context the
   same way `cat`-ing it would. Pull only the assistant text blocks:
   ```
   jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' \
     "$output_file"
   ```
   Redirect that to a small scratch file and read *that* — never the raw JSONL. What you get
   back may be the generator's complete returned artifact (usable close to as-is), a partial
   draft (state what's missing before reusing it), or nothing beyond what the notification's
   own `<summary>` already showed (some generators die before producing recoverable text at
   all — that is the actual floor, not a bug in the extraction).
5. **Triage per cluster, then redispatch only what's needed.** A cluster with a complete,
   recoverable artifact can skip regeneration entirely (apply it, subject to the same review
   this mode already requires). A cluster with a genuine partial can be redispatched with the
   partial included in the brief ("a prior attempt got this far before an account-level outage
   — finish it, don't restart" — quote the recovered text). A cluster with nothing recoverable
   redispatches fresh, same as it would have anyway. Never assume completeness from a partial
   — a maker/reviewer pass still applies.
6. **Redispatch under the same wave cap** (§1), recording each new result the same way (§2) —
   so a second interruption is no worse than the first.

This procedure is what a resume instruction like *"continue the remaining work in worktree
`<name>`; recover from `dispatch_results[]` and any transcripts still on disk before
redispatching; cap concurrency at N"* should trigger. It is a best-effort recovery on top of
ephemeral, unowned storage — not a guarantee. When nothing is recoverable, the fallback is
exactly what this skill already does: redispatch the cluster from scratch.
