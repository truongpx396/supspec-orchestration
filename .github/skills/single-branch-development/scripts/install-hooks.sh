#!/usr/bin/env bash
# install-hooks.sh — Idempotent, consent-gated installer for the single-branch-development
# hooks bundle. Solves the "install once, silently drift" footgun: manual `cp` copies rot
# (a repo can run a months-stale bundle without noticing), forgets to gitignore runs/, and
# skips the committed track-env.base.sh preset — so a resume runs SILENTLY UNGATED.
#
# What it does (all idempotent, all non-destructive to your edits):
#   1. Sync scripts/track-*.sh + templates/track-hooks.json into .github/hooks/ (fixes drift).
#   2. Ensure runs/ is gitignored (the fingerprint self-stales otherwise — see hooks.md).
#   3. Seed .github/hooks/track-env.base.sh from the template ONLY IF ABSENT, pre-filled with
#      a STACK-AWARE, repo-relevant starting point (never clobbers an existing one).
#
# SAFETY MODEL — this writes into shared repo config (.github/hooks/, .gitignore), so it is
# DRY-RUN BY DEFAULT: it prints a plan and touches nothing. Pass --apply to execute. The
# skill's Step 0 runs the dry-run, shows you the plan, asks for consent, THEN runs --apply.
#
# Usage:
#   install-hooks.sh                 # dry-run: print the plan, write nothing
#   install-hooks.sh --apply         # execute the plan
#   install-hooks.sh --check         # drift-only: exit 3 if the installed bundle != source
#
# Idempotent: re-running is safe; already-synced files and an existing base preset are left
# alone. Requires: bash, git (for repo root + gitignore). Keep runtime < 5s.
set -eufo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_SCRIPTS="$SKILL_DIR/scripts"
SRC_TEMPLATES="$SKILL_DIR/templates"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOOKS_DIR="$REPO_ROOT/.github/hooks"
RUNS_DIR_NAME="${RUNS_DIR:-runs}"

mode="dry-run"
for arg in "$@"; do
  case "$arg" in
    --apply) mode="apply" ;;
    --check) mode="check" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'install-hooks: unknown arg: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# Everything the bundle ships: every hook script (excluding this installer + the preflight-only
# helper naming) plus the wiring manifest. Copied verbatim into .github/hooks/.
bundle_scripts() {
  find "$SRC_SCRIPTS" -maxdepth 1 -name 'track-*.sh' -type f -exec basename {} \; | sort
}

files_differ() { ! cmp -s "$1" "$2" 2>/dev/null; }

# --- drift detection ---------------------------------------------------------
# A file is "drifted" if the installed copy is missing OR differs byte-for-byte from source.
drift_list() {
  local name src dst
  for name in $(bundle_scripts); do
    src="$SRC_SCRIPTS/$name"; dst="$HOOKS_DIR/$name"
    files_differ "$src" "$dst" && printf '%s\n' "$name"
  done
  src="$SRC_TEMPLATES/track-hooks.json"; dst="$HOOKS_DIR/track-hooks.json"
  files_differ "$src" "$dst" && printf 'track-hooks.json\n'
}

# --check: report drift and exit non-zero if any exists (for CI / the skill's Step 0 probe).
if [ "$mode" = "check" ]; then
  drift="$(drift_list || true)"
  if [ -n "$drift" ]; then
    printf 'DRIFT: %d bundle file(s) missing or stale in %s:\n' \
      "$(printf '%s\n' "$drift" | grep -c .)" "$HOOKS_DIR"
    printf '  - %s\n' $drift
    exit 3
  fi
  printf 'OK: installed hooks match source bundle.\n'
  exit 0
fi

# --- stack-aware base preset -------------------------------------------------
# Only the REPO-POLICY vars (repo-wide constants) get concrete values here. The TASK-DERIVED
# vars (writable scope, per-task toolchain, evidence floor) stay EMPTY on purpose so an
# unedited copy fails LOUD (guard denies all edits) instead of inheriting a wrong scope.
# The evidence CATALOG (kinds/rules) is populated from detected languages so the repo's
# how-to-test map is ready without hand-authoring.
detect_base_env() {
  local kinds="" rules="" toolchain="" base_ref="origin/main"
  # default branch, if resolvable
  local db
  db="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')" || true
  [ -n "${db:-}" ] && base_ref="origin/$db"

  if [ -n "$(find "$REPO_ROOT" -maxdepth 3 -name 'go.mod' -type f -print -quit 2>/dev/null)" ]; then
    kinds="${kinds}go-test:go test -race ./...;"
    rules="${rules}*.go:go-test;"
    toolchain="${toolchain}go,"
  fi
  if [ -n "$(find "$REPO_ROOT" -maxdepth 3 \( -name 'pyproject.toml' -o -name 'uv.lock' \) -type f -print -quit 2>/dev/null)" ]; then
    kinds="${kinds}py:uv run pytest;"
    rules="${rules}*.py:py;"
    toolchain="${toolchain}uv,"
  fi
  if [ -n "$(find "$REPO_ROOT" -maxdepth 3 -name 'package.json' -type f -print -quit 2>/dev/null)" ]; then
    kinds="${kinds}ts:tsc --noEmit;"
    rules="${rules}*.tsx:ts;*.ts:ts;"
    toolchain="${toolchain}node,"
  fi
  # migrations convention (present in this repo's data-model / partitioned tables plan)
  if [ -n "$(find "$REPO_ROOT" -maxdepth 3 -type d -name 'migrations' -print -quit 2>/dev/null)" ]; then
    rules="${rules}migrations/*:pg-explain;"
  fi
  printf '%s\t%s\t%s\t%s' \
    "${kinds%;}" "${rules%;}" "${toolchain%,}" "$base_ref"
}

# short one-line repo descriptor for the header comment (architecture/spec awareness)
repo_descriptor() {
  local spec desc="repo"
  spec="$(find "$REPO_ROOT/specs" -maxdepth 2 -name 'plan.md' -type f -print -quit 2>/dev/null || true)"
  if [ -n "${spec:-}" ]; then
    desc="spec-driven repo — active plan: ${spec#$REPO_ROOT/}"
  fi
  # constitution, if the project uses one
  if [ -f "$REPO_ROOT/.specify/memory/constitution.md" ] || [ -f "$REPO_ROOT/CONSTITUTION.md" ]; then
    desc="$desc (governed by a project constitution)"
  fi
  printf '%s' "$desc"
}

render_base_env() {
  local fields kinds rules toolchain base_ref descriptor
  fields="$(detect_base_env)"
  kinds="$(printf '%s' "$fields" | cut -f1)"
  rules="$(printf '%s' "$fields" | cut -f2)"
  toolchain="$(printf '%s' "$fields" | cut -f3)"
  base_ref="$(printf '%s' "$fields" | cut -f4)"
  descriptor="$(repo_descriptor)"
  cat <<EOF
# track-env.base.sh — repo-wide COMMITTED hook preset (single-branch-development bundle).
# Auto-seeded by install-hooks.sh from the detected repo stack. SAFE TO EDIT + COMMIT.
#
# Context this was generated for: $descriptor
# Detected toolchain: ${toolchain:-<none detected>}
#
# TWO CATEGORIES (the tag is documentation, not part of the name):
#   [TASK-DERIVED] preflight proposes per run; confirm at Step 1. Left EMPTY here so an
#                  unedited copy fails LOUD (guard denies all edits) — never silently wrong.
#   [REPO-POLICY]  repo-wide constant; set once, do not regenerate per run.
# Precedence: exported env > worktree track-env.sh > this file > script default.

# --- guard: writable scope + frozen entrypoints [TASK-DERIVED — set per run] -
export TRACK_ALLOWED_PREFIXES="\${TRACK_ALLOWED_PREFIXES:-}"          # colon-separated path prefixes this branch may edit. EMPTY ⇒ guard fails closed.
export TRACK_FROZEN_PATHS="\${TRACK_FROZEN_PATHS:-}"                  # exact files no branch may edit (leave empty on bootstrap).
export TRACK_IMMUTABLE_PREFIXES="\${TRACK_IMMUTABLE_PREFIXES:-migrations/}"  # [REPO-POLICY] committed files here are append-only.
export TRACK_GUARD_DESTRUCTIVE="\${TRACK_GUARD_DESTRUCTIVE:-1}"       # [REPO-POLICY] deny DROP/TRUNCATE/FLUSHALL/rm -rf.
export TRACK_ALLOW_FF_PUSH="\${TRACK_ALLOW_FF_PUSH:-}"               # [REPO-POLICY] 1 ONLY for a PR-rework flow.

# --- run state ---------------------------------------------------------------
export RUNS_DIR="\${RUNS_DIR:-$RUNS_DIR_NAME}"                        # [REPO-POLICY] run record dir — MUST be gitignored.

# --- preflight ---------------------------------------------------------------
export PREFLIGHT_REQUIRE_GH="\${PREFLIGHT_REQUIRE_GH:-1}"            # [REPO-POLICY] require authenticated gh (0 to waive on setup runs).
export PREFLIGHT_REQUIRE_TOOLCHAIN="\${PREFLIGHT_REQUIRE_TOOLCHAIN:-}" # [TASK-DERIVED] per-task bins on PATH (detected repo-wide: ${toolchain:-none}).

# --- evidence gate (CATALOG seeded from detected stack — [REPO-POLICY]) -------
export TRACK_EVIDENCE_KINDS="\${TRACK_EVIDENCE_KINDS:-${kinds}}"      # label:pattern pack.
export TRACK_EVIDENCE_RULES="\${TRACK_EVIDENCE_RULES:-${rules}}"      # diff-path glob → required kind.
export TRACK_REQUIRED_EVIDENCE="\${TRACK_REQUIRED_EVIDENCE:-}"        # [TASK-DERIVED] kinds required on EVERY diff (floor); empty = rules-only.
export TRACK_BASE_REF="\${TRACK_BASE_REF:-$base_ref}"                 # [REPO-POLICY] real base or a committed diff looks empty and passes silently.

# --- ceilings / hardening ----------------------------------------------------
export TRACK_MAX_TOOL_CALLS="\${TRACK_MAX_TOOL_CALLS:-200}"          # [REPO-POLICY] tool-call hard stop.
export TRACK_SENTINEL="\${TRACK_SENTINEL:-1}"                        # [REPO-POLICY] scan staged diff for secrets/leftovers.

# --- notify (optional) -------------------------------------------------------
export TRACK_NOTIFY_WEBHOOK="\${TRACK_NOTIFY_WEBHOOK:-}"             # [REPO-POLICY] terminal-state webhook; empty = no notify.
EOF
}

# --- plan + execute ----------------------------------------------------------
say() { printf '%s\n' "$1"; }
act() { [ "$mode" = "apply" ] && return 0 || return 1; }

drift="$(drift_list || true)"
base_exists=0; [ -f "$HOOKS_DIR/track-env.base.sh" ] && base_exists=1
gitignore="$REPO_ROOT/.gitignore"
runs_ignored=0
git -C "$REPO_ROOT" check-ignore "$RUNS_DIR_NAME/" >/dev/null 2>&1 && runs_ignored=1

say "install-hooks: $(printf '%s' "$mode" | tr '[:lower:]' '[:upper:]')"
say "  repo:       $REPO_ROOT"
say "  hooks dir:  ${HOOKS_DIR#$REPO_ROOT/}"
say ""

# 1. sync bundle
if [ -n "$drift" ]; then
  say "1. Sync bundle → .github/hooks/ ($(printf '%s\n' "$drift" | grep -c .) file(s) to copy):"
  printf '     %s\n' $drift
  if act; then
    mkdir -p "$HOOKS_DIR"
    for name in $(bundle_scripts); do
      cp "$SRC_SCRIPTS/$name" "$HOOKS_DIR/$name"; chmod +x "$HOOKS_DIR/$name"
    done
    cp "$SRC_TEMPLATES/track-hooks.json" "$HOOKS_DIR/track-hooks.json"
    say "   ✓ synced"
  fi
else
  say "1. Sync bundle → .github/hooks/: already up to date (no drift)."
fi
say ""

# 2. gitignore runs/
if [ "$runs_ignored" -eq 0 ]; then
  say "2. Gitignore '$RUNS_DIR_NAME/': not ignored (fingerprint will self-stale)."
  if act; then
    printf '\n# single-branch-development run records (self-stale the evidence fingerprint if tracked)\n%s/\n' \
      "$RUNS_DIR_NAME" >> "$gitignore"
    say "   ✓ appended '$RUNS_DIR_NAME/' to .gitignore"
  fi
else
  say "2. Gitignore '$RUNS_DIR_NAME/': already ignored."
fi
say ""

# 3. seed stack-aware base preset (never clobber)
if [ "$base_exists" -eq 1 ]; then
  say "3. Base preset track-env.base.sh: already present — left untouched (never clobbered)."
else
  say "3. Seed .github/hooks/track-env.base.sh (stack-aware, from detected repo signals):"
  say "     REPO-POLICY vars pre-filled; TASK-DERIVED scope/floor left EMPTY (fail-loud)."
  if act; then
    mkdir -p "$HOOKS_DIR"
    render_base_env > "$HOOKS_DIR/track-env.base.sh"
    say "   ✓ seeded (review + commit it)"
  fi
fi
say ""

if act; then
  say "Done. Review changes, then: git add .github/hooks .gitignore && git commit"
else
  say "Dry-run only — nothing written. Re-run with --apply to execute (after you consent)."
fi
