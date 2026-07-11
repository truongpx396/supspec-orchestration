#!/usr/bin/env bash
# track-notify.sh — Stop: notify a webhook when a worker session ends.
#
# Sends the run's terminal state (read from the run record) to a webhook so a human
# learns a worker finished or is blocked without watching it. NEVER blocks the agent
# and NEVER fails the session — best-effort fire-and-forget.
#
# Opt-in via env (no-op unless the webhook is set):
#   TRACK_NOTIFY_WEBHOOK  URL accepting a JSON {text:...} POST (Slack/Discord/generic)
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

cat >/dev/null   # drain stdin (Stop payload unused)

[ -n "${TRACK_NOTIFY_WEBHOOK:-}" ] || exit 0

RUNS_DIR="${RUNS_DIR:-runs}"
rec="$RUNS_DIR/${RUN_ID:-__none__}.json"
status="unknown"
pr="n/a"
if [ -n "${RUN_ID:-}" ] && [ -f "$rec" ]; then
  status="$(jq -r '.status // "unknown"' "$rec")"
  pr="$(jq -r '.pr_url // "n/a"' "$rec")"
fi

payload="$(jq -nc --arg r "${RUN_ID:-n/a}" --arg s "$status" --arg p "$pr" \
  '{text: ("track run " + $r + " finished — status: " + $s + " · PR: " + $p)}')"

# Best-effort: short timeout, swallow all errors, never surface secrets.
curl -fsS -m 5 -H 'Content-Type: application/json' -d "$payload" "$TRACK_NOTIFY_WEBHOOK" >/dev/null 2>&1 || true
exit 0
