#!/usr/bin/env bash
# track-evidence-gate.sh — Stop: the closing evidence assertion ("missing rows = not
# done"). Mechanizes verification-before-completion so a done-claim cannot land with
# stale, failed, or missing evidence.
#
# Blocks the stop unless EVERY required pack kind has, in runs/<RUN_ID>.json:
#   1. an evidence entry of that kind (recorded by track-evidence.sh), AND
#   2. whose fingerprint equals the CURRENT worktree fingerprint (not a stale green
#      run captured before later edits), AND
#   3. whose recorded response shows no failure marker.
# Any missing / stale / failed kind -> {decision:"block", reason} listing exactly which.
#
# Opt-in (no-op unless a required source is declared); honors stop_hook_active so it
# can't loop. The required-kind set is the UNION of:
#   TRACK_REQUIRED_EVIDENCE  comma-separated kinds ALWAYS required (the floor), e.g.
#                            "go-test". Labels must match TRACK_EVIDENCE_KINDS.
#   TRACK_EVIDENCE_RULES     ';'-separated glob:kind pairs that make a kind required
#                            ONLY when the branch's diff touches a matching path, e.g.
#                            "migrations/*:pg-explain;*.tsx:ts;*.go:go-test;*.py:py".
#                            This is how different tasks demand different evidence: a
#                            frontend-only change requires `ts`, never `pg-explain`.
#                            Globs are shell patterns where `*` spans `/` (a leading
#                            "**/" is tolerated). Rules are repo-supplied, not baked in.
#   TRACK_BASE_REF           (optional) base to diff against for "what changed" (e.g.
#                            main / origin/main). Falls back to the branch upstream,
#                            then to working-tree changes vs HEAD only.
#   RUN_ID / RUNS_DIR        locate the run record (default RUNS_DIR: runs)
#   TRACK_FAIL_PATTERN       (optional) ERE marking a failed response. Default is
#                            generic; repos add stack-specific markers (Seq Scan on a
#                            big table, TTL of -1, AckPolicy: None) via this override.
#
# If the resulting required set is empty (e.g. a docs-only diff under rule-only mode),
# the gate is a no-op. NOTE: requirement selection is mechanical glob-matching on
# touched paths against pre-authored rules — there is no model call in the gate.
#
# ACCURACY: tool_response is textual, not an exit code, so pass-detection is heuristic.
# CI stays the authoritative gate; this only stops a self-evidently bad claim.
# Requires: jq, git. Keep runtime < 5s — hooks block the agent synchronously.
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

input="$(cat)"
[ -n "${TRACK_REQUIRED_EVIDENCE:-}${TRACK_EVIDENCE_RULES:-}" ] || exit 0
[ -n "${RUN_ID:-}" ] || exit 0

# Already blocked once this turn -> don't trap the agent in a stop loop.
active="$(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null || echo false)"
[ "$active" = "true" ] && exit 0

RUNS_DIR="${RUNS_DIR:-runs}"
rec="$RUNS_DIR/$RUN_ID.json"

block() {
  jq -nc --arg r "$1" '{decision:"block", reason:$r}'
  exit 0
}

# --- Build the required-kind set: static floor UNION diff-derived rules -------------

# Paths this branch changed: committed-since-base (if a base resolves) + working tree.
base="${TRACK_BASE_REF:-}"
[ -n "$base" ] || base="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
committed=""
if [ -n "$base" ] && git rev-parse --verify -q "$base" >/dev/null 2>&1; then
  committed="$(git diff --name-only "$base"...HEAD 2>/dev/null || true)"
fi
worktree="$(git diff --name-only HEAD 2>/dev/null || true)"
# New files are untracked and invisible to `git diff`; include them so a brand-new
# .tsx/.sql still selects the right evidence kind (freshness still uses git diff).
untracked="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
touched="$(printf '%s\n%s\n%s\n' "$committed" "$worktree" "$untracked" | sed '/^$/d' | sort -u)"

# Start from the static floor.
required=""
if [ -n "${TRACK_REQUIRED_EVIDENCE:-}" ]; then
  saved_ifs="$IFS"; IFS=,
  for k in $TRACK_REQUIRED_EVIDENCE; do [ -n "$k" ] && required="$required $k"; done
  IFS="$saved_ifs"
fi

# Add kinds whose glob matches at least one touched path.
if [ -n "${TRACK_EVIDENCE_RULES:-}" ] && [ -n "$touched" ]; then
  saved_ifs="$IFS"; IFS=';'
  for rule in $TRACK_EVIDENCE_RULES; do
    glob="${rule%%:*}"; kind="${rule#*:}"
    [ -n "$glob" ] && [ -n "$kind" ] && [ "$glob" != "$rule" ] || continue
    glob="${glob#\*\*/}"   # tolerate a leading **/
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # shellcheck disable=SC2254  # $glob is intentionally a pattern
      case "$p" in
        $glob) required="$required $kind"; break ;;
      esac
    done <<<"$touched"
    IFS=';'
  done
  IFS="$saved_ifs"
fi

# Dedupe; empty required set -> nothing to assert.
required="$(printf '%s\n' $required | sed '/^$/d' | sort -u | tr '\n' ' ')"
[ -n "${required// /}" ] || exit 0

[ -f "$rec" ] ||
  block "Evidence gate: no run record at $rec yet. The diff requires evidence for:${required%% }. Run those checks and let them be captured before finishing."

# Current code fingerprint — must match track-evidence.sh's computation exactly
# (HEAD + tracked diff + untracked non-ignored file names & content hashes).
hash_cmd() { if command -v shasum >/dev/null 2>&1; then shasum; else sha1sum; fi; }
current_fp="$({
  git rev-parse HEAD 2>/dev/null || echo no-head
  git diff HEAD 2>/dev/null || true
  u="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
  if [ -n "$u" ]; then
    printf '%s\n' "$u"
    printf '%s\n' "$u" | git hash-object --stdin-paths 2>/dev/null || true
  fi
} | hash_cmd | cut -d' ' -f1)"

# Generic failure markers; repos extend via TRACK_FAIL_PATTERN for stack specifics.
fail_re="${TRACK_FAIL_PATTERN:-}"
[ -n "$fail_re" ] || fail_re='\bFAIL\b|FAILED|panic:|Traceback|error TS[0-9]|\bERROR\b|✖|exit code [1-9]|[1-9][0-9]* (failed|error)'

missing=""; stale=""; failed=""
for kind in $required; do
  [ -n "$kind" ] || continue
  # Latest entry of this kind.
  entry="$(jq -c --arg k "$kind" '[.evidence[]? | select(.kind == $k)] | last // empty' "$rec")"
  if [ -z "$entry" ] || [ "$entry" = "null" ]; then
    missing="$missing $kind"; continue
  fi
  fp="$(jq -r '.fingerprint // empty' <<<"$entry")"
  resp="$(jq -r '.response // empty' <<<"$entry")"
  if [ "$fp" != "$current_fp" ]; then
    stale="$stale $kind"; continue
  fi
  if printf '%s' "$resp" | grep -Eq "$fail_re"; then
    failed="$failed $kind"; continue
  fi
done

if [ -n "$missing" ] || [ -n "$stale" ] || [ -n "$failed" ]; then
  reason="Evidence gate: the work is not done — the evidence the diff requires is incomplete for the current code."
  [ -n "$missing" ] && reason="$reason MISSING (never captured):$missing."
  [ -n "$stale" ]   && reason="$reason STALE (captured before later edits — re-run against the current tree):$stale."
  [ -n "$failed" ]  && reason="$reason FAILING (latest run shows a failure marker):$failed."
  reason="$reason Produce fresh, passing output for each before finishing."
  block "$reason"
fi

exit 0
