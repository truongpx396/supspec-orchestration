#!/usr/bin/env bash
# track-report.sh — render the DETERMINISTIC half of a stage/PR completion report.
#
# NOT a hook. Run by the skill at Step 8 (draft-PR handoff). It emits the "Auto" block
# of the PR body ENTIRELY from machine state that already exists — never from the
# model's recollection — so the factual half of the report cannot drift from reality:
#
#   - Files changed + change size   ← git diff --name-status / --stat vs TRACK_BASE_REF
#   - Evidence (kind, cmd, fingerprint, pass/fail) ← runs/<RUN_ID>.json .evidence[]
#   - Tool calls / subagent order   ← runs/<RUN_ID>.json .tool_calls / .trace[]
#   - Self-reported skills / loops  ← runs/<RUN_ID>.json .skills[] / .iterations
#                                     (rendered UNDER a "self-reported" heading so a
#                                      reader can never mistake a model claim for a
#                                      hook-observed fact — same discipline as the record)
#   - Duration / timestamps         ← runs/<RUN_ID>.dispatch breadcrumb + heartbeat
#
# The NARRATIVE half (constitution/OWASP compliance, "After merge", caveats) is a model
# ASSERTION and is NOT produced here — it lives in templates/pr-body.md, which the skill
# fills in and appends. Keeping the two halves in separate producers is the whole point:
# machine-rendered facts vs. clearly-labelled model claims.
#
# Usage (writes the Auto block to stdout):
#   track-report.sh                 # uses $RUN_ID (or recovers it from a runs/*.dispatch)
#   track-report.sh <RUN_ID>        # explicit run id
#   track-report.sh --json          # emit the same facts as a JSON object (for tooling)
#
# Opt-in via env (same contract as the rest of the bundle):
#   RUN_ID          run id (else recovered from the newest runs/*.dispatch breadcrumb)
#   RUNS_DIR        where run records live (default: runs)
#   TRACK_BASE_REF  diff base for the files/size block (default: origin/main, then HEAD)
#
# Requires: jq, git. Read-only: never mutates the record, the tree, or git state.
set -eufo pipefail

# Bootstrap the same presets every bundle script sources (exported > worktree > base).
__env_dir="${BASH_SOURCE[0]%/*}"
if [ -f "$__env_dir/track-env.sh" ]; then . "$__env_dir/track-env.sh"; fi
if [ -f "$__env_dir/track-env.base.sh" ]; then . "$__env_dir/track-env.base.sh"; fi
unset __env_dir

RUNS_DIR="${RUNS_DIR:-runs}"
emit_json=0
run_id="${RUN_ID:-}"
for arg in "$@"; do
  case "$arg" in
    --json) emit_json=1 ;;
    -*)     printf 'track-report: unknown flag %s\n' "$arg" >&2; exit 2 ;;
    *)      run_id="$arg" ;;
  esac
done

# Recover RUN_ID from the newest breadcrumb when none was supplied — a solo run that
# never exported it can still be reported at handoff.
if [ -z "$run_id" ]; then
  # RUN_IDs are `<UTC-timestamp>_<track>`, so the lexically-greatest .dispatch is the
  # newest — a deterministic pick that also survives `set -f` (no glob) via find, and
  # doesn't depend on mtime. `|| true` keeps an empty runs/ from tripping pipefail.
  newest="$(find "$RUNS_DIR" -maxdepth 1 -name '*.dispatch' -type f 2>/dev/null | sort | tail -1 || true)"
  if [ -n "$newest" ]; then
    run_id="$(jq -r '.run_id // empty' "$newest" 2>/dev/null || true)"
    [ -n "$run_id" ] || run_id="$(basename "$newest" .dispatch)"
  fi
fi
[ -n "$run_id" ] || { printf 'track-report: no RUN_ID and no runs/*.dispatch to recover from.\n' >&2; exit 2; }

rec="$RUNS_DIR/$run_id.json"
dispatch="$RUNS_DIR/$run_id.dispatch"

# --- gather facts (missing sources degrade to empty, never abort) --------------------
base="${TRACK_BASE_REF:-origin/main}"
git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || base="HEAD"

files_ns="$(git diff --name-status "$base"...HEAD 2>/dev/null || true)"
stat_line="$(git diff --shortstat "$base"...HEAD 2>/dev/null | sed 's/^ *//' || true)"
[ -n "$stat_line" ] || stat_line="no committed changes vs ${base}"
files_count="$(printf '%s\n' "$files_ns" | grep -c . 2>/dev/null || true)"
[ -n "$files_count" ] || files_count=0

# record-derived (all optional — absent record = empty sections, not an error)
if [ -f "$rec" ]; then
  tool_calls="$(jq -r '.tool_calls // 0' "$rec" 2>/dev/null || echo 0)"
  started_ts="$(jq -r '.started_ts // empty' "$rec" 2>/dev/null || true)"
  last_ts="$(jq -r '.last_ts // empty' "$rec" 2>/dev/null || true)"
  iterations="$(jq -r '.iterations // 0' "$rec" 2>/dev/null || echo 0)"
  ev_count="$(jq -r '.evidence | length' "$rec" 2>/dev/null || echo 0)"
  review_seen="$(jq -r '[.skills[]? | select((.skill // "") | ascii_downcase | test("requesting-code-review|code-review"))] | length' "$rec" 2>/dev/null || echo 0)"
else
  tool_calls=0; started_ts=""; last_ts=""; iterations=0; ev_count=0; review_seen=0
fi

if [ -f "$dispatch" ]; then
  d_branch="$(jq -r '.branch // empty' "$dispatch" 2>/dev/null || true)"
  d_tasks="$(jq -r '.tasks // empty' "$dispatch" 2>/dev/null || true)"
  d_created="$(jq -r '.created_utc // empty' "$dispatch" 2>/dev/null || true)"
  d_completed="$(jq -r '.completed_utc // empty' "$dispatch" 2>/dev/null || true)"
  d_duration="$(jq -r '.duration_secs // empty' "$dispatch" 2>/dev/null || true)"
else
  d_branch=""; d_tasks=""; d_created=""; d_completed=""; d_duration=""
fi

# --- compliance warnings: silent-omission tripwires a reviewer MUST see --------------
# A hook cannot observe review quality or judge a pasted capture, but it CAN flag the two
# gaps that otherwise slip through unnoticed: an empty evidence pack and a missing code-
# review activation. Absence is reported LOUDLY here so a skipped Step-5 review or an
# un-captured verification surfaces in the PR body itself, not in a later audit.
warnings=()
[ "${ev_count:-0}" -gt 0 ] || warnings+=("No evidence rows recorded — the evidence gate ran on an empty pack. Paste the real verification output in the Asserted zone and confirm every required kind passed, or wire a matching TRACK_EVIDENCE_RULES entry so it is captured mechanically.")
[ "${review_seen:-0}" -gt 0 ] || warnings+=("No \`requesting-code-review\` activation on record — Step 5 review may have been skipped (or not logged via \`track-note.sh skill requesting-code-review\`). Confirm the maker/checker review happened before merge.")

if [ "${#warnings[@]}" -gt 0 ]; then
  warn_json="$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)"
else
  warn_json='[]'
fi

# --- JSON mode: same facts, machine-consumable --------------------------------------
if [ "$emit_json" -eq 1 ]; then
  jq -nc \
    --arg run_id "$run_id" --arg base "$base" \
    --arg stat "$stat_line" --arg files "$files_ns" \
    --argjson tool_calls "${tool_calls:-0}" --argjson iterations "${iterations:-0}" \
    --arg started_ts "$started_ts" --arg last_ts "$last_ts" \
    --arg branch "$d_branch" --arg tasks "$d_tasks" \
    --arg created "$d_created" --arg completed "$d_completed" --arg duration "$d_duration" \
    --argjson warnings "$warn_json" \
    --slurpfile r "${rec:-/dev/null}" \
    '{run_id:$run_id, base:$base, branch:$branch, tasks:$tasks,
      change_shortstat:$stat,
      files:($files | split("\n") | map(select(length>0))),
      tool_calls:$tool_calls, iterations:$iterations,
      started_ts:$started_ts, last_ts:$last_ts,
      created_utc:$created, completed_utc:$completed, duration_secs:$duration,
      warnings:$warnings,
      evidence:(($r[0].evidence) // []),
      trace:(($r[0].trace) // []),
      skills:(($r[0].skills) // [])}' 2>/dev/null \
  || printf '{"run_id":"%s","error":"record unreadable"}\n' "$run_id"
  exit 0
fi

# --- markdown mode: the "Auto" block ------------------------------------------------
md_row_files() {
  # git name-status → a markdown table (status letter → word)
  printf '%s\n' "$files_ns" | while IFS=$'\t' read -r st path rest; do
    [ -n "${st:-}" ] || continue
    case "$st" in
      A*) w="added" ;; M*) w="modified" ;; D*) w="deleted" ;;
      R*) w="renamed"; path="$rest" ;; C*) w="copied"; path="$rest" ;;
      *)  w="$st" ;;
    esac
    printf '| `%s` | %s |\n' "$path" "$w"
  done
}

md_group_by_area() {
  # git name-status → a compact table grouped by top-level path segment, so a
  # 100-file scaffold reads as a handful of area rows instead of a file-by-file wall.
  # Area = first path component (`backend-go/`), or the whole name if it has no slash
  # (`Makefile`). Emitted in first-seen order with a per-area add/modify/delete tally.
  printf '%s\n' "$files_ns" | awk -F'\t' '
    NF>=2 {
      st=$1; p=$2;
      if (st ~ /^R/ || st ~ /^C/) p=$3;              # renamed/copied → destination
      slash=index(p, "/");
      area=(slash>0) ? substr(p,1,slash) : p;
      if (!(area in seen)) { seen[area]=1; order[++n]=area; }
      cnt[area]++;
      c=substr(st,1,1);
      if (c=="A") add[area]++; else if (c=="M") mod[area]++;
      else if (c=="D") del[area]++; else oth[area]++;
    }
    END {
      print "| Area | Files | Changes |";
      print "|---|---|---|";
      for (i=1;i<=n;i++) {
        a=order[i]; chg="";
        if (add[a]) chg=chg (chg?", ":"") add[a] " added";
        if (mod[a]) chg=chg (chg?", ":"") mod[a] " modified";
        if (del[a]) chg=chg (chg?", ":"") del[a] " deleted";
        if (oth[a]) chg=chg (chg?", ":"") oth[a] " other";
        printf "| `%s` | %d | %s |\n", a, cnt[a], chg;
      }
    }
  '
}

printf '<!-- BEGIN track-report auto block — machine-rendered, do not hand-edit -->\n'
printf '### Run `%s`\n\n' "$run_id"
[ -n "$d_branch" ] && printf -- '- **Branch:** `%s`\n' "$d_branch"
[ -n "$d_tasks" ]  && printf -- '- **Tasks:** %s\n' "$d_tasks"
printf -- '- **Base:** `%s`\n' "$base"
if [ -n "$d_duration" ] && [ "$d_duration" != "null" ]; then
  printf -- '- **Duration:** %ss' "$d_duration"
  [ -n "$d_completed" ] && printf ' (completed %s)' "$d_completed"
  printf '\n'
elif [ -n "$started_ts" ]; then
  printf -- '- **Activity window:** %s → %s (heartbeat)\n' "$started_ts" "${last_ts:-$started_ts}"
fi
printf '\n#### Files changed\n\n'
if [ -n "$files_ns" ]; then
  # Many files → group by area + tuck the full list into a <details> so the PR body
  # stays scannable; few files → a plain per-file table is clearer. Threshold tunable.
  if [ "${files_count:-0}" -gt "${TRACK_REPORT_FILE_TABLE_MAX:-12}" ]; then
    md_group_by_area
    printf '\n<details><summary>All %s files</summary>\n\n' "$files_count"
    printf '| File | Change |\n|---|---|\n'
    md_row_files
    printf '\n</details>\n'
  else
    printf '| File | Change |\n|---|---|\n'
    md_row_files
  fi
else
  printf '_No committed changes vs `%s`._\n' "$base"
fi
printf '\n_%s_\n' "$stat_line"

# Evidence — pass/fail derived from the recorded response text, fingerprint shown.
printf '\n#### Evidence\n\n'
if [ -f "$rec" ] && [ "$(jq -r '.evidence | length' "$rec" 2>/dev/null || echo 0)" -gt 0 ]; then
  printf '| Kind | Command | Result | Fingerprint |\n|---|---|---|---|\n'
  fail_pat="${TRACK_FAIL_PATTERN:-FAIL|--- FAIL|Error:|panic:|Traceback|AssertionError|✗|npm ERR!}"
  jq -r --arg fp "$fail_pat" '
    .evidence[] |
    ((.response // "") | test($fp)) as $failed |
    "| \(.kind // "?") | `\((.cmd // "?") | gsub("\\|";"\\|"))` | \(if $failed then "❌ FAIL" else "✅ pass" end) | `\((.fingerprint // "?")[0:12])` |"
  ' "$rec" 2>/dev/null || printf '| _(evidence unreadable)_ | | | |\n'
else
  printf '_No evidence rows recorded (evidence hooks not enabled, or none captured)._\n'
fi

# Compliance warnings — silent-omission tripwires (empty evidence / no review on record).
printf '\n#### Compliance warnings\n\n'
if [ "${#warnings[@]}" -gt 0 ]; then
  for _w in "${warnings[@]}"; do printf -- '- ⚠️ %s\n' "$_w"; done
else
  printf -- '- ✅ A code-review activation and at least one evidence row are on record.\n'
fi

# Mechanical run stats.
printf '\n#### Run stats (hook-observed)\n\n'
printf -- '- **Tool calls:** %s\n' "${tool_calls:-0}"
te="$(jq -r '.token_estimate // empty' "$rec" 2>/dev/null || true)"
if [ -n "$te" ]; then
  tm="$(jq -r '.token_estimate_method // ""' "$rec" 2>/dev/null || true)"
  printf -- '- **Token estimate (rough):** ~%s  *(method: %s)*\n' "$te" "$tm"
fi
if [ -f "$rec" ] && [ "$(jq -r '.trace | length' "$rec" 2>/dev/null || echo 0)" -gt 0 ]; then
  printf -- '- **Subagent trace (in order):**\n'
  jq -r '.trace[] | "  - \(.t): \(.event) \(.agent_type // .agent_display_name // "") \((.agent_id // "") | if . == "" then "" else "(\(.))" end)\((.reason // "") | if . == "" then "" else " — why: \(.)" end)"' \
    "$rec" 2>/dev/null || true
fi

# Self-reported — clearly fenced off from the mechanical facts above.
if [ -f "$rec" ] && { [ "$(jq -r '.skills | length' "$rec" 2>/dev/null || echo 0)" -gt 0 ] || [ "${iterations:-0}" -gt 0 ]; }; then
  printf '\n#### Trace (self-reported — model claim, not hook-observed)\n\n'
  if [ "$(jq -r '.skills | length' "$rec" 2>/dev/null || echo 0)" -gt 0 ]; then
    printf -- '- **Skill activations (in order):**\n'
    jq -r '.skills[] | "  - \(.t): \(.skill)\((.step // "") | if . == "" then "" else " — \(.)" end)"' \
      "$rec" 2>/dev/null || true
  fi
  [ "${iterations:-0}" -gt 0 ] && printf -- '- **Iterations (RED→GREEN→review cycles):** %s\n' "$iterations"
fi
printf '<!-- END track-report auto block -->\n'
exit 0
