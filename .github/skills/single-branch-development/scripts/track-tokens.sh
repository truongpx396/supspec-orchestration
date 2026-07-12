#!/usr/bin/env bash
# track-tokens.sh — Stop hook: estimate token usage from the session transcript
#                   and enforce a per-worker token ceiling (MAX_TOKEN_ESTIMATE).
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
#   Use it as a "roughly how heavy was this run" signal; for billing use the
#   model provider's actual usage API.
#
# Text sources extracted from the transcript JSONL:
#   user.message        → data.content
#   assistant.message   → data.content + data.reasoningText + data.toolRequests[]
#   tool.execution_start → data.arguments (tool call parameters)
#   tool.execution_complete — only has a success flag, no output text in this format
#
# CEILING ENFORCEMENT (MAX_TOKEN_ESTIMATE):
#   MAX_TOKEN_ESTIMATE sets a hard ceiling on estimated tokens. When the estimate
#   first exceeds the ceiling the hook:
#     1. Writes `status: "budget-exceeded"` to the run record.
#     2. Prints a clear message with the estimate and ceiling.
#     3. Exits non-zero to block the stop — the agent sees the message and knows
#        NOT to open a PR. On the NEXT stop attempt the hook sees `status:
#        "budget-exceeded"` already set and exits 0, allowing the run to end
#        cleanly with the terminal state recorded.
#   This mirrors how track-evidence-gate.sh blocks on a first miss and allows
#   a second stop after the required action (there: capturing evidence; here:
#   the agent acknowledges the budget state and does not open a PR).
#
#   IMPORTANT: the enforcement fires at Stop, not PostToolUse — the agent CANNOT
#   be halted truly mid-turn by this hook. The ceiling is not a billing firewall;
#   it is a "runaway-run" signal. For intra-turn protection set TRACK_MAX_TOOL_CALLS
#   (PostToolUse hook, enforced by track-meter.sh) and configure provider-side
#   budget controls.
#
# CONFIG (set in track-env.base.sh):
#   MAX_TOKEN_ESTIMATE   integer ceiling (e.g. 200000). Hook is a no-op when unset
#                        or 0. Set high enough that normal feature work never hits
#                        it — only runaway agents should reach it.
#   RUN_ID               stable run-id for this worker (set by preflight --persist)
#   RUNS_DIR             where run records live (default: runs)
#
# Wire this in track-hooks.json under "stop" (already done in the template).
# It is safe to deploy even without MAX_TOKEN_ESTIMATE — the hook is fully no-op.
set -eufo pipefail

# Bootstrap: load hook presets sitting beside this script, if present:
#   1. track-env.sh       per-worktree LOCAL overrides (gitignored, optional)
#   2. track-env.base.sh  repo-wide COMMITTED defaults (travels into every worktree)
__env_dir="${BASH_SOURCE[0]%/*}"
if [ -f "$__env_dir/track-env.sh" ]; then . "$__env_dir/track-env.sh"; fi
if [ -f "$__env_dir/track-env.base.sh" ]; then . "$__env_dir/track-env.base.sh"; fi
unset __env_dir

[ "${MAX_TOKEN_ESTIMATE:-0}" -gt 0 ] || exit 0
[ -n "${RUN_ID:-}" ] || exit 0

input="$(cat)"
# Read transcript_path — both VS Code snake_case and camelCase spellings.
tp="$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$input")"
[ -n "$tp" ] || exit 0
[ -f "$tp" ] || exit 0

RUNS_DIR="${RUNS_DIR:-runs}"
rec="$RUNS_DIR/$RUN_ID.json"
[ -f "$rec" ] || exit 0  # run record must already exist (preflight --persist creates it)

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

# --- ceiling check (first exceedance: block stop; second: allow clean exit) --
ceiling="${MAX_TOKEN_ESTIMATE:-0}"
if [ "$ceiling" -gt 0 ] && [ "$estimate" -gt "$ceiling" ]; then
  current_status="$(jq -r '.status // empty' "$rec" 2>/dev/null || true)"
  if [ "$current_status" = "budget-exceeded" ]; then
    # Second stop attempt after budget-exceeded was written — record and exit 0.
    jq --argjson e "$estimate" --argjson c "$chars" --arg t "$ts" \
       --arg m "chars/4 heuristic — undercounts system prompt + injected schemas + cached tokens" \
      '.token_estimate = $e | .token_estimate_chars = $c | .token_estimate_method = $m | .last_ts = $t' \
      "$rec" >"$tmp" && mv "$tmp" "$rec"
    exit 0
  fi
  # First exceedance: write terminal state and block this stop.
  jq --argjson e "$estimate" --argjson c "$chars" --arg t "$ts" \
     --arg m "chars/4 heuristic — undercounts system prompt + injected schemas + cached tokens" \
    '.token_estimate = $e | .token_estimate_chars = $c | .token_estimate_method = $m | .last_ts = $t | .status = "budget-exceeded"' \
    "$rec" >"$tmp" && mv "$tmp" "$rec"
  printf '%s\n' \
    "TRACK_TOKENS: TOKEN BUDGET EXCEEDED — estimated ~${estimate} tokens (ceiling: ${ceiling})." \
    "  Run record status set to 'budget-exceeded'." \
    "  DO NOT open a draft PR. Report status to orchestrator and stop cleanly." \
    "  (On the next stop attempt the hook will allow the clean exit.)" >&2
  exit 1
fi

# --- normal recording (under budget or no ceiling) ---------------------------
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
