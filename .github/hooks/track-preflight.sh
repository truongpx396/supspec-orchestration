#!/usr/bin/env bash
# track-preflight.sh — Start gate: mint (or recover) a stable RUN_ID, verify the run can
# actually proceed, and disambiguate START vs RESUME from a durable breadcrumb. Solves the
# "humans can't reproduce a RUN_ID from memory" footgun: the id is generated once and
# persisted to runs/<RUN_ID>.dispatch, so a later resume reads it back instead of guessing.
#
# Two phases (so the skill can show a summary, get confirmation, THEN persist):
#   inspect (default)  — detect resume-vs-fresh, check prerequisites, print a summary +
#                        emit JSON to stdout. READ-ONLY: writes nothing. Exit non-zero only
#                        on a HARD prerequisite failure (missing gh/git/toolchain) — a
#                        missing dep is not a preference, it blocks in every mode.
#   --commit           — persist runs/<RUN_ID>.dispatch (the breadcrumb) after the caller
#                        has confirmed. Idempotent: re-committing the same id is a no-op.
#   --complete         — stamp completed_utc + duration_secs (now − created_utc) onto the
#                        breadcrumb at draft-PR handoff. Write-once; the honest home for
#                        "total run time" (a per-event hook never sees PR handoff).
#
# Inputs (env or args):
#   TRACK_ID     short track slug (e.g. setup, us1). REQUIRED.
#   TASKS        human task range for the summary/breadcrumb (e.g. "T001-T009"). Optional.
#   RUN_ID       override the minted id (rare). If a breadcrumb for this TRACK_ID already
#                exists, its id WINS (resume) unless RUN_ID is set explicitly.
#   RUNS_DIR     default "runs".
#   TRACK_BRANCH target branch name to work to. Optional — empty derives it from the track
#                slug. Validated with `git check-ref-format` so a bad name fails here.
#   TRACK_BASE_REF / default_branch  base for the new branch (summary only; default main).
#   PREFLIGHT_REQUIRE_TOOLCHAIN  comma list of extra bins to require (e.g. "go,uv,node").
#   PREFLIGHT_REQUIRE_GH         "1" (default) to require an authenticated gh; "0" to skip
#                                (e.g. a setup run that won't open a PR until later).
#
# Resume detection: the NEWEST runs/*.dispatch whose track==TRACK_ID. Its run_id is the
# resume key; the caller then hands that RUN_ID to track-reconcile.sh.
#
# Requires: jq, git. gh only when PREFLIGHT_REQUIRE_GH=1. Keep runtime < 5s.
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

mode="inspect"
for a in "$@"; do
  case "$a" in
    --commit) mode="commit" ;;
    --inspect) mode="inspect" ;;
    --complete) mode="complete" ;;
  esac
done

RUNS_DIR="${RUNS_DIR:-runs}"
track="${TRACK_ID:-}"
tasks="${TASKS:-}"
base="${TRACK_BASE_REF:-${default_branch:-main}}"
branch_override="${TRACK_BRANCH:-}"          # arbitrary target branch name; empty = derive from the track slug
require_gh="${PREFLIGHT_REQUIRE_GH:-1}"
allowed_prefixes="${TRACK_ALLOWED_PREFIXES:-}"   # writable scope the guard enforces; derived from the task file set upstream
frozen_paths="${TRACK_FROZEN_PATHS:-}"           # exact entrypoints no task may edit
require_toolchain="${PREFLIGHT_REQUIRE_TOOLCHAIN:-}"  # bins this task needs on PATH; derive from the task's languages so a missing tool fails HERE, not mid-run
required_evidence="${TRACK_REQUIRED_EVIDENCE:-}"      # evidence floor required on EVERY diff; empty = rules-only (weaker gate)

err() { printf '%s\n' "preflight: $1" >&2; }
die() { err "$1"; exit 1; }

[ -n "$track" ] || die "TRACK_ID is required (the track slug, e.g. setup / us1)."
command -v jq  >/dev/null 2>&1 || die "jq not found."
command -v git >/dev/null 2>&1 || die "git not found."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree."

mkdir -p "$RUNS_DIR" 2>/dev/null || true
[ -w "$RUNS_DIR" ] || die "$RUNS_DIR is not writable."

# --- resume detection: newest breadcrumb for this track ----------------------------
# NOTE: `set -f` (noglob) is active, so shell globbing of *.dispatch is disabled — use
# `find` (which does its own matching) rather than an `ls runs/*.dispatch` shell glob.
existing_id=""
existing_file=""
# Build a mtime-sorted (newest first) list, then scan with a here-string so the matched
# filename survives in this shell (a pipe-to-while would set it inside a lost subshell).
sorted=""
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
  sorted="$sorted$mt	$f
"
done <<<"$(find "$RUNS_DIR" -maxdepth 1 -type f -name '*.dispatch' 2>/dev/null || true)"
sorted="$(printf '%s' "$sorted" | sort -rn)"
while IFS="$(printf '\t')" read -r _ f; do
  [ -n "${f:-}" ] || continue
  t="$(jq -r '.track // empty' "$f" 2>/dev/null || true)"
  if [ "$t" = "$track" ]; then
    existing_file="$f"; existing_id="$(jq -r '.run_id // empty' "$f" 2>/dev/null)"; break
  fi
done <<<"$sorted"

# --- pick RUN_ID: explicit override > existing breadcrumb (resume) > mint fresh -----
resume=false
if [ -n "${RUN_ID:-}" ]; then
  run_id="$RUN_ID"
  [ -n "$existing_id" ] && [ "$existing_id" = "$run_id" ] && resume=true
elif [ -n "$existing_id" ]; then
  run_id="$existing_id"; resume=true
else
  run_id="$(date -u +%Y-%m-%dT%H-%M)_${track}"
fi
rec_dispatch="$RUNS_DIR/$run_id.dispatch"

# --- prerequisite checks (hard) ----------------------------------------------------
missing=""
if [ "$require_gh" = "1" ]; then
  if command -v gh >/dev/null 2>&1; then
    gh auth status >/dev/null 2>&1 || missing="$missing gh(not-authed)"
  else
    missing="$missing gh(absent)"
  fi
fi
if [ -n "${PREFLIGHT_REQUIRE_TOOLCHAIN:-}" ]; then
  saved_ifs="$IFS"; IFS=,
  for bin in $PREFLIGHT_REQUIRE_TOOLCHAIN; do
    [ -n "$bin" ] || continue
    command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin(absent)"
  done
  IFS="$saved_ifs"
fi
missing="$(printf '%s' "$missing" | sed 's/^ *//')"

# --- evidence-kind consistency (soft config check) ---------------------------------
# The gate requires kinds (TRACK_EVIDENCE_RULES glob:kind, TRACK_REQUIRED_EVIDENCE) that
# capture must be able to TAG (TRACK_EVIDENCE_KINDS label:pattern, plus implicit "test"
# when TRACK_TEST_CMD_PATTERN is set). A required kind with no matching capture label can
# NEVER be captured, so the gate would block forever — a silent config typo. Surface it as
# a warning (non-fatal: kinds may legitimately be supplied outside this script's view).
config_warn=""
labels=""
if [ -n "${TRACK_EVIDENCE_KINDS:-}" ]; then
  saved_ifs="$IFS"; IFS=';'
  for pair in $TRACK_EVIDENCE_KINDS; do
    label="${pair%%:*}"
    [ -n "$label" ] && [ "$label" != "$pair" ] && labels="$labels $label"
  done
  IFS="$saved_ifs"
fi
[ -n "${TRACK_TEST_CMD_PATTERN:-}" ] && labels="$labels test"
# Only validate when SOME capture label exists — otherwise the evidence system is simply
# not configured here and there is nothing to cross-check.
if [ -n "${labels// /}" ]; then
  req_kinds=""
  if [ -n "${TRACK_REQUIRED_EVIDENCE:-}" ]; then
    saved_ifs="$IFS"; IFS=,
    for k in $TRACK_REQUIRED_EVIDENCE; do [ -n "$k" ] && req_kinds="$req_kinds $k"; done
    IFS="$saved_ifs"
  fi
  if [ -n "${TRACK_EVIDENCE_RULES:-}" ]; then
    saved_ifs="$IFS"; IFS=';'
    for rule in $TRACK_EVIDENCE_RULES; do
      kind="${rule#*:}"
      [ -n "$kind" ] && [ "$kind" != "$rule" ] && req_kinds="$req_kinds $kind"
    done
    IFS="$saved_ifs"
  fi
  for rk in $(printf '%s\n' $req_kinds | sed '/^$/d' | sort -u); do
    found=0
    for lb in $labels; do [ "$rk" = "$lb" ] && found=1 && break; done
    [ "$found" -eq 1 ] || config_warn="$config_warn ${rk}(no-capture-label)"
  done
fi
config_warn="$(printf '%s' "$config_warn" | sed 's/^ *//')"

# Target branch: an explicit TRACK_BRANCH wins; otherwise derive from the track slug.
# Validate an explicit name with git's own ref rules so a bad name fails HERE (at the
# start gate), not mid-run when the worktree step tries to create it.
branch="${branch_override:-$track}"
if [ -n "$branch_override" ]; then
  git check-ref-format --branch "$branch_override" >/dev/null 2>&1 \
    || die "TRACK_BRANCH '$branch_override' is not a valid git branch name."
fi
prereq_ok=true; [ -n "$missing" ] && prereq_ok=false

# --- commit phase: persist the breadcrumb, then exit -------------------------------
if [ "$mode" = "commit" ]; then
  [ "$prereq_ok" = true ] || die "refusing to commit breadcrumb — unmet prerequisites:$missing"
  if [ -f "$rec_dispatch" ]; then
    printf '%s\n' "preflight: breadcrumb already present ($rec_dispatch) — no-op." >&2
  else
    jq -nc \
      --arg run_id "$run_id" --arg track "$track" --arg tasks "$tasks" \
      --arg branch "$branch" --arg base "$base" \
      --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg allowed "$allowed_prefixes" --arg frozen "$frozen_paths" \
      --arg toolchain "$require_toolchain" --arg required_evidence "$required_evidence" \
      '{run_id:$run_id, track:$track, tasks:$tasks, branch:$branch, base_ref:$base, created_utc:$created,
        allowed_prefixes:($allowed | if . == "" then [] else split(":") end),
        frozen_paths:($frozen | if . == "" then [] else split(":") end),
        scope_set:($allowed != ""),
        require_toolchain:($toolchain | if . == "" then [] else split(",") end),
        toolchain_set:($toolchain != ""),
        required_evidence:($required_evidence | if . == "" then [] else split(",") end),
        evidence_floor_set:($required_evidence != "")}' \
      > "$rec_dispatch"
  fi
  # --- activate the run record for SOLO runs -------------------------------------
  # The per-call recorder hooks (meter/trace/evidence/note) require RUN_ID in their
  # env and otherwise no-op. In a solo run no orchestrator exports it, so the run
  # record (tool_calls / trace[] / skills[] / heartbeat) would stay empty. Persist
  # RUN_ID into the per-worktree track-env.sh that every hook sources, as an
  # idempotent managed block that never touches operator scope lines. The
  # ${RUN_ID:-...} form means an already-exported RUN_ID (e.g. an
  # executing-parallel-tracks per-worker value) still wins. Guarded by the
  # track-env.base.sh marker so this only ever fires inside a real INSTALLED hooks
  # dir — never in the skill's scripts/ source mirror that unit tests run in-place.
  _env_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
  if [ -f "$_env_dir/track-env.base.sh" ]; then
    env_file="$_env_dir/track-env.sh"
    _blk_begin="# >>> track-preflight RUN_ID (managed - do not edit) >>>"
    _blk_end="# <<< track-preflight RUN_ID (managed - do not edit) <<<"
    if [ -f "$env_file" ]; then
      awk -v b="$_blk_begin" -v e="$_blk_end" '
        $0==b {skip=1; next} skip && $0==e {skip=0; next} !skip {print}
      ' "$env_file" > "$env_file.tmp" && mv "$env_file.tmp" "$env_file"
    fi
    {
      printf '%s\n' "$_blk_begin"
      printf 'export RUN_ID="${RUN_ID:-%s}"\n' "$run_id"
      printf '%s\n' "$_blk_end"
    } >> "$env_file"
  fi
  printf '%s\n' "$run_id"
  exit 0
fi

# --- complete phase: stamp the terminal breadcrumb, then exit ----------------------
# Called ONCE at draft-PR handoff — the one deliberate step that knows the run is done.
# Writes completed_utc + duration_secs (now − created_utc) into the existing breadcrumb.
# Write-once: re-completing a stamped run is a no-op, so a resume can't overwrite the
# original finish time. This is the honest home for "total run time" — a single stamp at
# a real boundary, not a per-event hook (a PostToolUse hook never sees PR handoff).
if [ "$mode" = "complete" ]; then
  [ -f "$rec_dispatch" ] || die "cannot complete — no breadcrumb at $rec_dispatch (run --commit first)."
  if [ "$(jq -r '.completed_utc // empty' "$rec_dispatch" 2>/dev/null)" != "" ]; then
    printf '%s\n' "preflight: breadcrumb already completed ($rec_dispatch) — no-op." >&2
    printf '%s\n' "$run_id"
    exit 0
  fi
  now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  created="$(jq -r '.created_utc // empty' "$rec_dispatch" 2>/dev/null)"
  # Portable ISO-8601-UTC → epoch (BSD/macOS `date -j -f`; GNU `date -d`). Either failing
  # leaves duration null rather than aborting the handoff over a clock-parse quirk.
  to_epoch() { date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo ""; }
  dur="null"
  if [ -n "$created" ]; then
    c_epoch="$(to_epoch "$created")"; n_epoch="$(to_epoch "$now_utc")"
    if [ -n "$c_epoch" ] && [ -n "$n_epoch" ] && [ "$n_epoch" -ge "$c_epoch" ]; then
      dur="$(( n_epoch - c_epoch ))"
    fi
  fi
  tmp="$(mktemp)"
  jq --arg done "$now_utc" --argjson dur "$dur" \
    '.completed_utc = $done | .duration_secs = $dur' "$rec_dispatch" >"$tmp" && mv "$tmp" "$rec_dispatch"
  # Retire the persisted RUN_ID activation block (written at --commit) so a finished
  # run stops steering the recorder hooks and can't bleed into an unrelated later run.
  # Same installed-hooks guard as --commit (skip the scripts/ source mirror).
  _env_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
  if [ -f "$_env_dir/track-env.base.sh" ]; then
    env_file="$_env_dir/track-env.sh"
    _blk_begin="# >>> track-preflight RUN_ID (managed - do not edit) >>>"
    _blk_end="# <<< track-preflight RUN_ID (managed - do not edit) <<<"
    if [ -f "$env_file" ]; then
      awk -v b="$_blk_begin" -v e="$_blk_end" '
        $0==b {skip=1; next} skip && $0==e {skip=0; next} !skip {print}
      ' "$env_file" > "$env_file.tmp" && mv "$env_file.tmp" "$env_file"
    fi
  fi
  printf '%s\n' "$run_id"
  exit 0
fi

{
  echo "PREFLIGHT — single-branch-development"
  echo "  Mode:         $([ "$resume" = true ] && echo 'RESUME (breadcrumb found)' || echo 'START (fresh)')"
  echo "  Track:        $track"
  echo "  Tasks:        ${tasks:-<unspecified>}"
  echo "  RUN_ID:       $run_id $([ "$resume" = true ] && echo '(recovered)' || echo '(generated)')"
  [ -n "$existing_file" ] && echo "  Breadcrumb:   $existing_file"
  echo "  Branch:       $branch  $([ -n "$branch_override" ] && echo '(TRACK_BRANCH — custom)' || echo '(derived from track slug)')"
  echo "  Base ref:     $base"
  if [ -n "$allowed_prefixes" ]; then
    echo "  Scope:        $allowed_prefixes  (guard denies edits outside this)"
  else
    echo "  Scope:        ⚠ TRACK_ALLOWED_PREFIXES UNSET — guard fails closed (denies ALL edits). Derive + set the writable scope from the task file set before dispatch."
  fi
  [ -n "$frozen_paths" ] && echo "  Frozen:       $frozen_paths  (no task may edit)"
  if [ -n "$require_toolchain" ]; then
    echo "  Toolchain:    $require_toolchain  (required on PATH — a missing bin blocks here)"
  else
    echo "  Toolchain:    (none required) — derive from the task's languages so a missing tool fails here, not mid-run"
  fi
  if [ -n "$required_evidence" ]; then
    echo "  Evid. floor:  $required_evidence  (required on every diff regardless of rules)"
  else
    echo "  Evid. floor:  ⚠ TRACK_REQUIRED_EVIDENCE UNSET — gate is rules-only (no floor). Derive the mandatory kinds from the task's languages if any must run on every diff."
  fi
  if [ "$prereq_ok" = true ]; then
    echo "  Prereqs:      OK (git ✓ · runs/ ✓ writable$([ "$require_gh" = 1 ] && echo ' · gh ✓ authed')${PREFLIGHT_REQUIRE_TOOLCHAIN:+ · $PREFLIGHT_REQUIRE_TOOLCHAIN ✓})"
    echo "  → Proceed?    confirm to dispatch (then re-run with --commit to persist the breadcrumb)"
  else
    echo "  Prereqs:      BLOCKED — missing:$missing"
    echo "  → Fix the missing prerequisite before dispatching."
  fi
  [ -n "$config_warn" ] && echo "  Config:       ⚠ evidence kinds required but not capturable:$config_warn (check TRACK_EVIDENCE_KINDS labels vs TRACK_EVIDENCE_RULES/TRACK_REQUIRED_EVIDENCE)"
} >&2

jq -nc \
  --arg run_id "$run_id" --arg track "$track" --arg tasks "$tasks" \
  --arg branch "$branch" --arg base "$base" \
  --argjson resume "$resume" --argjson prereq_ok "$prereq_ok" \
  --arg missing "$missing" --arg breadcrumb "$existing_file" \
  --arg config_warn "$config_warn" \
  --arg allowed "$allowed_prefixes" --arg frozen "$frozen_paths" \
  --arg toolchain "$require_toolchain" --arg required_evidence "$required_evidence" \
  '{run_id:$run_id, track:$track, tasks:$tasks, branch:$branch, base_ref:$base,
    mode:(if $resume then "resume" else "start" end),
    prereq_ok:$prereq_ok,
    allowed_prefixes:($allowed | if . == "" then [] else split(":") end),
    frozen_paths:($frozen | if . == "" then [] else split(":") end),
    scope_set:($allowed != ""),
    require_toolchain:($toolchain | if . == "" then [] else split(",") end),
    toolchain_set:($toolchain != ""),
    required_evidence:($required_evidence | if . == "" then [] else split(",") end),
    evidence_floor_set:($required_evidence != ""),
    missing:($missing | if . == "" then [] else split(" ") end),
    config_warnings:($config_warn | if . == "" then [] else split(" ") end),
    breadcrumb:($breadcrumb | if . == "" then null else . end)}'

[ "$prereq_ok" = true ] || exit 3
exit 0
