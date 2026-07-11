#!/usr/bin/env bash
# track-trace.sh — SubagentStart / SubagentStop: append to the run's activation trace.
#
# Builds the "skill → subagent → skill …" activation trace mechanically, so the run
# record shows which step a worker was in without reading the full transcript.
#
# NOTE: this records SUBAGENT spawn/stop events (the data hooks actually expose).
# The richest field is `agent_description` (the subagent's one-line "why") — it is
# present on SubagentStart ONLY; SubagentStop carries a `stop_reason` instead. Field
# NAMES differ across surfaces (VS Code: snake_case agent_id/agent_type; CLI/cloud:
# camelCase agentName/agentDisplayName/agentDescription — see references/hooks.md), so
# every known spelling is read below and the trace is populated on any surface.
#
# The `Run-Id:` COMMIT trailer is NOT added here — a Copilot hook can't cleanly
# rewrite an already-made commit. Add that trailer in the worker's commit command
# (prompt-enforced) or via a git `prepare-commit-msg` hook.
#
# Opt-in via env (no-op unless RUN_ID is set):
#   RUN_ID    stable run-id for this worker
#   RUNS_DIR  where run records live (default: runs)
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

[ -n "${RUN_ID:-}" ] || exit 0

input="$(cat)"
ev="$(jq -r '.hook_event_name // empty' <<<"$input")"
aid="$(jq -r '.agent_id // .agentId // empty' <<<"$input")"
atype="$(jq -r '.agent_type // .agentName // .agent_name // empty' <<<"$input")"
adisp="$(jq -r '.agent_display_name // .agentDisplayName // empty' <<<"$input")"
# The reason the agent was spawned (SubagentStart only); stop_reason (SubagentStop only).
reason="$(jq -r '.agent_description // .agentDescription // empty' <<<"$input")"
sreason="$(jq -r '.stop_reason // .stopReason // empty' <<<"$input")"

RUNS_DIR="${RUNS_DIR:-runs}"
rec="$RUNS_DIR/$RUN_ID.json"
mkdir -p "$RUNS_DIR"
# Canonical skeleton — identical across track-evidence/-meter/-trace so whichever hook
# fires first writes the same shape (v = run-record schema version).
[ -f "$rec" ] || printf '{"run_id":"%s","v":1,"trace":[],"evidence":[],"tool_calls":0}\n' "$RUN_ID" >"$rec"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"
# Append the event AND refresh the heartbeat (started_ts once, last_ts every event) so
# now - last_ts stays a usable idle signal even between tool calls. The base entry keeps
# agent_id/agent_type (back-compat with track-report.sh); the display name, reason, and
# stop_reason keys are added ONLY when non-empty, so records stay clean on surfaces that
# don't supply them.
jq --arg t "$ts" --arg e "$ev" --arg id "$aid" --arg ty "$atype" \
   --arg disp "$adisp" --arg reason "$reason" --arg sr "$sreason" \
  '.trace = ((.trace // []) + [
     ({t:$t, kind:"subagent", event:$e, agent_id:$id, agent_type:$ty})
     + (if $disp   != "" then {agent_display_name:$disp} else {} end)
     + (if $reason != "" then {reason:$reason} else {} end)
     + (if $sr     != "" then {stop_reason:$sr} else {} end)
   ]) | .started_ts = (.started_ts // $t) | .last_ts = $t' \
  "$rec" >"$tmp" && mv "$tmp" "$rec"
exit 0
