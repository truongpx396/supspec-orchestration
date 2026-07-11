#!/usr/bin/env bash
# track-guard.sh — PreToolUse guard for the executing-parallel-tracks skill.
#
# Makes two of the skill's gates MECHANICAL instead of prompt-trusted:
#   1. Deny-by-default file ownership (per worktree) + frozen entrypoints.
#   2. Worker push/merge lockout — workers stop at `gh pr create --draft`.
#
# Wiring: copy this file + the bundled track-hooks.json into the repo's
# .github/hooks/ directory (the JSON points VS Code / Copilot CLI / cloud agent
# at this script).
# Requires: jq. Keep runtime < 5s — hooks block the agent synchronously.
#
# Per-worktree scope (export BEFORE launching each worker):
#   TRACK_ALLOWED_PREFIXES  colon-separated workspace-relative path prefixes this
#                           track may edit, e.g.
#                           "internal/ingest:migrations/0007_:test/ingest"
#   TRACK_FROZEN_PATHS      colon-separated exact files no track may edit, e.g.
#                           "cmd/main.go:internal/app/app.go"
#   TRACK_IMMUTABLE_PREFIXES  (optional) colon-separated prefixes whose
#                           already-committed files are append-only, e.g.
#                           "migrations/:backend-go/migrations/". A NEW file under
#                           the prefix is fine; editing one with git history is denied.
#
# Always-on (no env needed): any file whose first 3 lines carry a
# "GENERATED — DO NOT EDIT" banner is denied — re-run its generator instead.
#
# Opt-in destructive-infra guard (off unless set):
#   TRACK_GUARD_DESTRUCTIVE  set to any value to also deny irreversible data/infra
#                            shell commands (DROP/TRUNCATE, unbounded DELETE, Redis
#                            FLUSHALL/FLUSHDB, NATS stream/consumer teardown,
#                            rm -rf on an absolute/home path). Tune per stack.
#
# Opt-in fast-forward push (off unless set):
#   TRACK_ALLOW_FF_PUSH      set to any value to permit a plain `git push` (e.g. a
#                            PR-rework flow updating an existing PR branch). --force,
#                            --no-verify, gh pr merge, git merge, and reset --hard
#                            stay denied, so only a fast-forward push is allowed.
#
# NOTE: VS Code ignores hook "matchers", so this script fires on EVERY tool call
# and branches on tool_name itself. Tool names / input keys differ across
# surfaces — VS Code: create_file / replace_string_in_file, camelCase
# tool_input.filePath; Claude/CLI: Write / Edit, snake_case file_path. Both are
# handled below.
set -eufo pipefail   # -f: no globbing (path prefixes are literal, never patterns)

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
tool="$(jq -r '.tool_name // empty' <<<"$input")"

deny() {
  jq -nc --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Normalize a tool-supplied path to a path relative to the git worktree ROOT it
# belongs to. Paths UNDER $PWD keep the fast legacy strip (the agent's own
# checkout — the common case). Only paths OUTSIDE $PWD get git-toplevel
# resolution: that is the case this fix exists for — the isolated work lives in a
# SIBLING git worktree while the agent (and $PWD) stay rooted in the main
# checkout, so a plain $PWD-strip would leave an absolute path that never matches
# TRACK_ALLOWED_PREFIXES and every scoped write would be denied (fail-closed),
# forcing ungoverned terminal-heredoc writes. create_file targets may not exist
# yet, so we resolve via the deepest existing ancestor's toplevel; falls back to
# the $PWD-strip when the path is outside any git worktree. Side effect: sets
# GIT_WT_ROOT to the discovered root so the banner and immutable-history checks
# target the right tree.
GIT_WT_ROOT=""
_git_relpath() {
  p_in="$1"
  GIT_WT_ROOT=""
  case "$p_in" in
    /*) ;;                                   # absolute → normalize below
    *)  printf '%s' "$p_in"; return ;;       # already relative → no-op
  esac
  case "$p_in" in
    "$PWD"/*)                                # under the agent's checkout → legacy strip
      GIT_WT_ROOT="$PWD"; printf '%s' "${p_in#"$PWD"/}"; return ;;
  esac
  d="$p_in"                                  # outside $PWD → likely a sibling worktree
  while [ ! -e "$d" ] && [ "$d" != "/" ] && [ -n "$d" ]; do d="${d%/*}"; done
  [ -z "$d" ] && d="/"
  root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$root" ]; then
    GIT_WT_ROOT="$root"
    printf '%s' "${p_in#"$root"/}"
  else
    printf '%s' "${p_in#"$PWD"/}"            # fallback: legacy behavior
  fi
}

case "$tool" in
  create_file | replace_string_in_file | multi_replace_string_in_file | edit_notebook_file | Write | Edit | MultiEdit)
    # Collect every target path this edit touches, across surface variants.
    paths="$(jq -r '
      [ .tool_input.filePath?,
        .tool_input.file_path?,
        (.tool_input.replacements[]?.filePath),
        (.tool_input.edits[]?.file_path) ]
      | map(select(. != null and . != "")) | .[]' <<<"$input")"
    [ -z "$paths" ] && exit 0

    while IFS= read -r p; do
      [ -z "$p" ] && continue
      rel="$(_git_relpath "$p")"   # relative to the path's git worktree root (handles sibling worktrees)

      # Frozen entrypoints: never editable by any track (tracks self-register).
      saved_ifs="$IFS"; IFS=:
      for f in ${TRACK_FROZEN_PATHS:-}; do
        [ "$rel" = "$f" ] && { IFS="$saved_ifs";
          deny "frozen entrypoint '$rel' — self-register via your track's own file instead of editing the shared entrypoint"; }
      done
      IFS="$saved_ifs"

      # Deny-by-default: the path MUST match an allowed prefix.
      ok=0
      saved_ifs="$IFS"; IFS=:
      for a in ${TRACK_ALLOWED_PREFIXES:-}; do
        case "$rel" in "$a"*) ok=1 ;; esac
      done
      IFS="$saved_ifs"
      [ "$ok" -eq 1 ] ||
        deny "'$rel' is outside this track's ownership scope (set TRACK_ALLOWED_PREFIXES); editing it would become a merge conflict at integration"

      # Generated files are never hand-edited — re-run the generator (always-on).
      # Test the ORIGINAL path ($p), which resolves regardless of $PWD vs worktree.
      if [ -f "$p" ] && head -3 "$p" 2>/dev/null | grep -q "GENERATED — DO NOT EDIT"; then
        deny "'$rel' is generated (carries a 'GENERATED — DO NOT EDIT' banner) — re-run its generator instead of editing it by hand"
      fi

      # Immutable prefixes: an already-committed file (e.g. an applied migration)
      # is append-only. A brand-new file under the prefix is allowed. Query the
      # worktree the path lives in (GIT_WT_ROOT), not $PWD, so a sibling-worktree
      # branch's history is checked — falling back to $PWD when root is unknown.
      saved_ifs="$IFS"; IFS=:
      for m in ${TRACK_IMMUTABLE_PREFIXES:-}; do
        case "$rel" in
          "$m"*)
            if git -C "${GIT_WT_ROOT:-$PWD}" log --oneline -1 -- "$rel" 2>/dev/null | grep -q .; then
              IFS="$saved_ifs"
              deny "'$rel' is an already-committed artifact under an immutable prefix ($m) — create a NEW file instead of editing it"
            fi ;;
        esac
      done
      IFS="$saved_ifs"
    done <<<"$paths"
    ;;

  run_in_terminal | bash | shell)
    cmd="$(jq -r '.tool_input.command // .tool_input.bash // empty' <<<"$input")"
    # History rewrites, merges, and gate bypass are ALWAYS denied — even when
    # fast-forward push is opted in below (this catches `git push --force`).
    case "$cmd" in
      *"gh pr merge"* | *"git merge "* | *"--force"* | *"--no-verify"* | *"git reset --hard"*)
        deny "blocked by autonomy boundary: merging/rewriting history is the merge gate's job (human or merge queue), not the worker's." ;;
    esac
    # `git push` lockout — workers normally stop at `gh pr create --draft`. A
    # PR-rework flow that must update an existing PR branch opts in via
    # TRACK_ALLOW_FF_PUSH; the always-deny block above still bars --force, so
    # only a plain fast-forward push reaches here.
    case "$cmd" in
      *"git push"*)
        [ -n "${TRACK_ALLOW_FF_PUSH:-}" ] ||
          deny "blocked by autonomy boundary: workers stop at 'gh pr create --draft'. Pushing is the merge gate's job. (Set TRACK_ALLOW_FF_PUSH=1 for a PR-rework flow that updates an existing branch with a fast-forward push.)" ;;
    esac

    # OPTIONAL destructive-infra guard — irreversible data/infra ops. Off unless
    # TRACK_GUARD_DESTRUCTIVE is set; case-insensitive; tune patterns per stack.
    if [ -n "${TRACK_GUARD_DESTRUCTIVE:-}" ]; then
      shopt -s nocasematch
      case "$cmd" in
        *"drop table"* | *"drop database"* | *"drop schema"* | *truncate*)
          deny "blocked: irreversible schema op in '$cmd'. Express it as a reversible migration, not an ad-hoc DROP/TRUNCATE." ;;
        *flushall* | *flushdb*)
          deny "blocked: Redis FLUSHALL/FLUSHDB wipes shared state. Scope deletions to your own keys instead." ;;
        *"nats stream rm"* | *"nats stream delete"* | *"nats stream purge"* | *"nats consumer rm"* | *"nats consumer delete"*)
          deny "blocked: NATS stream/consumer teardown touches shared infra. Leave topology changes to the platform owner." ;;
        *"rm -rf /"* | *"rm -fr /"* | *"rm -rf ~"* | *"rm -fr ~"*)
          deny "blocked: 'rm -rf' on an absolute or home path. Delete only within the repo/worktree." ;;
      esac
      # Unbounded DELETE (no WHERE) wipes a whole table.
      case "$cmd" in
        *"delete from"*)
          case "$cmd" in
            *where*) : ;;
            *) deny "blocked: 'DELETE FROM' with no WHERE clause wipes the whole table. Add a WHERE filter." ;;
          esac ;;
      esac
      shopt -u nocasematch
    fi
    ;;
esac

exit 0
