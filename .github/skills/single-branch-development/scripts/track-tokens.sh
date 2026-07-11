#!/usr/bin/env bash
# track-tokens.sh — Stop hook: estimate token usage from the session transcript.
#
# Fires ONCE when the agent ends a turn (Stop / agentStop). Reads the transcript
# file supplied in the hook payload, extracts every text field the model sent or
# received, counts characters, and writes a `token_estimate` (chars / 4) into the
# run record. The estimate is OVERWRITTEN on every turn because the transcript is
# cumulative — re-reading it always gives the grand total for the whole session so
# far; appending would double-count.
#
# WHY chars/4 and not tiktoken:
#   - tiktoken / the Claude tokenizer are not always available in a hook shell.
#   - 1 token ≈ 4 characters is the standard rough heuristic for English/code.
#   - The estimate UNDERCOUNTS because it cannot see:
#       • The hidden system prompt (never in the transcript)
#       • Injected tool-schema definitions
#       • Server-side cached-token discounts
#   Use it as a "roughly how heavy was this run" signal, NOT for billing.
#
# Text sources extracted from the transcript JSONL:
#   user.message        → data.content
#   assistant.message   → data.content + data.reasoningText + data.toolRequests[]
#   tool.execution_start → data.arguments (tool call parameters)
#   tool.execution_complete — only has a success flag, no output text in this format
#
# OPT-OUT via env — active by default (track-env.base.sh sets TRACK_TOKEN_ESTIMATE=1);
# unset or set to empty to disable:
#   TRACK_TOKEN_ESTIMATE  any non-empty value enables the hook (default: 1)
#   RUN_ID                stable run-id for this worker (set by preflight --commit)
#   RUNS_DIR              where run records live (default: runs)
#
# Wire this in track-hooks.json under "stop" (already done in the template).
# It is safe to deploy even without TRACK_TOKEN_ESTIMATE — the hook is fully no-op.
set -eufo pipefail

# Bootstrap: load hook presets sitting beside this script, if present:
#   1. track-env.sh       per-worktree LOCAL overrides (gitignored, optional)
#   2. track-env.base.sh  repo-wide COMMITTED defaults (travels into every worktree)
__env_dir="${BASH_SOURCE[0]%/*}"
if [ -f "$__env_dir/track-env.sh" ]; then . "$__env_dir/track-env.sh"; fi
if [ -f "$__env_dir/track-env.base.sh" ]; then . "$__env_dir/track-env.base.sh"; fi
unset __env_dir

[ -n "${TRACK_TOKEN_ESTIMATE:-}" ] || exit 0
[ -n "${RUN_ID:-}" ] || exit 0

input="$(cat)"
# Read transcript_path — both VS Code snake_case and camelCase spellings.
tp="$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$input")"
[ -n "$tp" ] || exit 0
[ -f "$tp" ] || exit 0

RUNS_DIR="${RUNS_DIR:-runs}"
rec="$RUNS_DIR/$RUN_ID.json"
[ -f "$rec" ] || exit 0  # run record must already exist (preflight --commit creates it)

# Extract all text the model sent or received. jq outputs one string per match;
# wc -c counts the raw byte count (close enough to chars for UTF-8 English/code).
chars="$(jq -r '
  if   .type == "user.message"         then (.data.content // "")
  elif .type == "assistant.message"    then (
    (.data.content // ""),
    (.data.reasoningText // ""),
    (.data.toolRequests[]? | tojson)
  )
  elif .type == "tool.execution_start" then (.data.arguments | tojson)
  else empty
  end
' "$tp" 2>/dev/null | wc -c)"

# 1 token ≈ 4 chars. Integer division is intentional — the result is approximate.
estimate=$(( chars / 4 ))

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"
# OVERWRITE (not add) — transcript is cumulative so each Stop already gives the
# running grand total. Adding would double-count earlier turns.
jq --argjson e "$estimate" --argjson c "$chars" --arg t "$ts" \
   --arg m "chars/4 heuristic — undercounts system prompt + injected schemas + cached tokens" \
  '.token_estimate = $e
   | .token_estimate_chars = $c
   | .token_estimate_method = $m
   | .last_ts = $t' \
  "$rec" >"$tmp" && mv "$tmp" "$rec"
exit 0
