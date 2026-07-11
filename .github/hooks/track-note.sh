#!/usr/bin/env bash
# track-note.sh — SELF-REPORTED run annotations. NOT a hook, NOT mechanically observed.
#
# The meter/trace/evidence hooks only record what a PostToolUse/Subagent hook can
# actually see (tool-call count, subagent spawns, test output). Two things the model
# knows but no hook can observe are (1) which skill it is currently executing and
# (2) how many implement→review loops it has run. This CLI lets the skill *assert*
# those into the run record — so they are the model's own claim, not a verified fact.
#
# To keep that honest, everything written here is provenance-tagged:
#   - skills[] entries carry  self_reported:true
#   - the loop counter lives in  iterations  and a mirror  iterations_self_reported:true
#     flag is set the first time it is touched, so a reader can never mistake either
#     array/scalar for hook-observed truth.
#
# Wire it from the SKILL prompt (not track-hooks.json): call `note skill …` at the top
# of each core step, and `note loop …` once per RED→GREEN→review cycle.
#
# Usage (no-op unless RUN_ID is set):
#   track-note.sh skill <name> [step]   append {t, skill, step, self_reported:true} to skills[]
#   track-note.sh loop  [phase]         iterations += 1  (+ optional phase label on the mark)
#
# Opt-in via env:
#   RUN_ID    stable run-id for this worker  (REQUIRED — no-op when unset)
#   RUNS_DIR  where run records live (default: runs)
set -eufo pipefail

# Bootstrap: load hook presets sitting beside this script, if present (same contract as
# the hooks: local worktree overrides win over repo base, and an exported value wins
# over both via ${VAR:-default}). No-op when a file is absent.
__env_dir="${BASH_SOURCE[0]%/*}"
if [ -f "$__env_dir/track-env.sh" ]; then . "$__env_dir/track-env.sh"; fi
if [ -f "$__env_dir/track-env.base.sh" ]; then . "$__env_dir/track-env.base.sh"; fi
unset __env_dir

[ -n "${RUN_ID:-}" ] || exit 0

sub="${1:-}"
RUNS_DIR="${RUNS_DIR:-runs}"
rec="$RUNS_DIR/$RUN_ID.json"
mkdir -p "$RUNS_DIR"
# Canonical skeleton — identical across track-evidence/-meter/-trace/-note so whichever
# writer fires first stamps the same shape (v = run-record schema version). skills[] /
# iterations are added by the mutation below, never by the skeleton, to preserve that
# byte-for-byte invariant.
[ -f "$rec" ] || printf '{"run_id":"%s","v":1,"trace":[],"evidence":[],"tool_calls":0}\n' "$RUN_ID" >"$rec"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"

case "$sub" in
  skill)
    name="${2:-}"
    [ -n "$name" ] || { printf '%s\n' "track-note: 'skill' needs a name." >&2; exit 2; }
    step="${3:-}"
    # Append the activation + refresh the heartbeat (started_ts once, last_ts every event).
    jq --arg t "$ts" --arg s "$name" --arg st "$step" \
      '.skills = ((.skills // []) + [{t:$t, skill:$s, step:$st, self_reported:true}])
       | .started_ts = (.started_ts // $t) | .last_ts = $t' \
      "$rec" >"$tmp" && mv "$tmp" "$rec"
    ;;
  loop)
    phase="${2:-}"
    # Increment the loop counter, tag its provenance once, and (if a phase was given)
    # drop a timestamped mark so the loop timeline is reconstructable, not just a total.
    jq --arg t "$ts" --arg p "$phase" \
      '.iterations = ((.iterations // 0) + 1)
       | .iterations_self_reported = true
       | (if $p != "" then .iteration_log = ((.iteration_log // []) + [{t:$t, phase:$p}]) else . end)
       | .started_ts = (.started_ts // $t) | .last_ts = $t' \
      "$rec" >"$tmp" && mv "$tmp" "$rec"
    ;;
  *)
    rm -f "$tmp"
    printf '%s\n' "track-note: unknown subcommand '${sub:-<none>}' (want: skill | loop)." >&2
    exit 2
    ;;
esac
exit 0
