#!/usr/bin/env bash
# track-meter.sh — PostToolUse: enforce a per-worker tool-call ceiling (hard stop).
#
# Counts tool calls in runs/<RUN_ID>.json and halts the session via `continue:false`
# when the ceiling trips — the mechanical backstop for the skill's "max iterations"
# hard stop.
#
# LIMITATION: hook I/O carries NO token/cost data, so this enforces a TOOL-CALL
# ceiling only. Token/$ ceilings (per-worker and the global fleet ceiling) must stay
# orchestrator-side. A tool-call count approximates "turns"; it is not identical.
#
# Opt-in via env (no-op unless the ceiling is set):
#   TRACK_MAX_TOOL_CALLS  integer ceiling; halt the worker once exceeded
#   RUN_ID                stable run-id for this worker
#   RUNS_DIR              where run records live (default: runs)
set -eufo pipefail

# Bootstrap: load hook presets sitting beside this script, if present:
#   1. track-env.sh       per-worktree LOCAL overrides (gitignored, optional)
#   2. track-env.base.sh  repo-wide COMMITTED defaults (travels into every worktree)
# Local is sourced first so a worktree value wins over the repo base; every line
# uses ${VAR:-default}, so an already-exported value (e.g. an executing-parallel-
# tracks per-track override) still wins over both. No-op when a file is absent.
__env_dir="${BASH_SOURCE[0]%/*}"
if [ -f "$__env_dir/track-env.sh" ]; then . "$__env_dir/track-env.sh"; fi
if [ -f "$__env_dir/track-env.base.sh" ]; then . "$__env_dir/track-env.base.sh"; fi
unset __env_dir

# Need a run record to write into. The tool-call COUNTER + heartbeat below are always
# on when RUN_ID is set — so even a SOLO run with no ceiling still captures tool_calls
# and last_ts. The ceiling only ADDS the hard-stop enforcement when it is configured.
[ -n "${RUN_ID:-}" ] || exit 0

RUNS_DIR="${RUNS_DIR:-runs}"
rec="$RUNS_DIR/$RUN_ID.json"
mkdir -p "$RUNS_DIR"
# Canonical skeleton — identical across track-evidence/-meter/-trace so whichever hook
# fires first writes the same shape (v = run-record schema version).
[ -f "$rec" ] || printf '{"run_id":"%s","v":1,"trace":[],"evidence":[],"tool_calls":0}\n' "$RUN_ID" >"$rec"

count="$(jq -r '(.tool_calls // 0) + 1' "$rec")"
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"
# Also stamp the heartbeat: started_ts once, last_ts on every call. now - last_ts is
# the orchestrator's idle/staleness signal (a hung worker stops advancing last_ts);
# last_ts - started_ts is the run's wall-clock duration.
jq --argjson n "$count" --arg t "$now_ts" \
  '.tool_calls = $n | .started_ts = (.started_ts // $t) | .last_ts = $t' "$rec" >"$tmp" && mv "$tmp" "$rec"

if [ -n "${TRACK_MAX_TOOL_CALLS:-}" ] && [ "$count" -gt "$TRACK_MAX_TOOL_CALLS" ]; then
  # Also record the terminal state for the orchestrator's summary.
  tmp2="$(mktemp)"
  jq '.status = "no-progress"' "$rec" >"$tmp2" && mv "$tmp2" "$rec"
  jq -nc --arg r "tool-call ceiling ($TRACK_MAX_TOOL_CALLS) exceeded for run $RUN_ID; halting per hard-stop policy (status: no-progress)" \
    '{continue:false, stopReason:$r}'
fi
exit 0
