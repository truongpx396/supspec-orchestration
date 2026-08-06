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
# NOTE: Copilot/VS Code ignores hook "matchers", so under that surface this script
# fires on EVERY tool call and branches on tool_name itself. Claude Code DOES scope
# by matcher (see the .claude/settings.json wiring), but the branching stays so a
# single script serves both surfaces. Tool names / input keys differ across
# surfaces — VS Code: create_file / replace_string_in_file + run_in_terminal,
# camelCase tool_input.filePath; Claude Code: Write / Edit / MultiEdit + Bash,
# snake_case file_path / command. All are handled below.
set -eufo pipefail   # -f: no globbing (path prefixes are literal, never patterns)

# Bootstrap: load hook presets sitting beside this script, if present:
#   1. track-env.sh       per-worktree LOCAL overrides (gitignored, optional)
#   2. track-env.base.sh  repo-wide COMMITTED defaults (travels into every worktree)
# Local is sourced first so a worktree value wins over the repo base; every line
# uses ${VAR:-default}, so an already-exported value (e.g. an executing-parallel-
# tracks per-track override) still wins over both. No-op when a file is absent.
__env_dir="${BASH_SOURCE[0]%/*}"
# Prefer the MAIN checkout's .github/hooks (canonical) when installed, so a hook
# firing from a linked worktree sources the SAME per-run env + RUN_ID block the
# main-checkout preflight wrote — not an absent worktree-local copy (which would
# leave the guard with empty scope and deny every worktree write). git-common-dir
# resolves to the main repo's .git from any worktree; its parent is the main root.
__gcd="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$__gcd" ]; then
  case "$__gcd" in /*) ;; *) __gcd="$PWD/$__gcd" ;; esac
  __main_root="$(cd "$__gcd/.." 2>/dev/null && pwd || true)"
  if [ -n "$__main_root" ] && [ -d "$__main_root/.github/hooks" ]; then __env_dir="$__main_root/.github/hooks"; fi
  unset __main_root
fi
unset __gcd
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
  create_file | replace_string_in_file | multi_replace_string_in_file | edit_notebook_file | Write | Edit | MultiEdit | NotebookEdit)
    # Collect every target path this edit touches, across surface variants.
    # NotebookEdit (Claude Code) carries its target as tool_input.notebook_path.
    paths="$(jq -r '
      [ .tool_input.filePath?,
        .tool_input.file_path?,
        .tool_input.notebook_path?,
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

  run_in_terminal | bash | shell | Bash)
    cmd="$(jq -r '.tool_input.command // .tool_input.bash // empty' <<<"$input")"
    # History rewrites, merges, and gate bypass are ALWAYS denied — even when
    # fast-forward push is opted in below (this catches `git push --force`).
    case "$cmd" in
      *"gh pr merge"* | *"git merge "* | *"--force"* | *"--no-verify"* | *"git reset --hard"*)
        deny "blocked by autonomy boundary: merging/rewriting history is the merge gate's job (human or merge queue), not the worker's." ;;
    esac
    # `git push` lockout — workers normally stop at `gh pr create --draft`. Two
    # carve-outs, and nothing else gets through:
    #
    #   1. TRACK_ALLOW_FF_PUSH — explicit opt-in for a PR-rework flow that updates an
    #      already-published branch. The always-deny block above still bars --force.
    #
    #   2. The FIRST publish of the worker's own branch. `gh pr create` cannot open a PR
    #      for a branch the remote has never seen; non-interactively it fails outright
    #      rather than offering to push. Denying this made the skill's OWN documented
    #      terminal step unreachable, leaving a worker no in-bounds move — on a real run
    #      that pressure produced exactly the predictable outcome: the worker self-granted
    #      TRACK_ALLOW_FF_PUSH, a flag documented for a different purpose, to get unstuck.
    #      A rule with no compliant path does not produce compliance, it produces
    #      workarounds, so the compliant path is now explicit and narrow.
    #
    # The carve-out is deliberately the narrowest thing that reaches `gh pr create`: it
    # publishes ONE branch ONCE. A second push of the same branch is an update and still
    # requires the opt-in, so the rework flag keeps its documented meaning.
    is_first_publish() { # is_first_publish <cmd> — 0 only for a branch-publishing push
      _c="$1"
      # Bulk/destructive push modes are never a publish (--force is denied above).
      case "$_c" in
        *--delete*|*--mirror*|*--all*|*--tags*|*--prune*|*" -d "*) return 1 ;;
      esac
      _wt="${GIT_WT_ROOT:-$PWD}"
      _cur="$(git -C "$_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
      { [ -n "$_cur" ] && [ "$_cur" != "HEAD" ]; } || return 1
      # Never publish the base/default branch — that is the merge gate's ref, not ours.
      _def="${TRACK_DEFAULT_BRANCH:-}"
      [ -n "$_def" ] || { _b="${TRACK_BASE_REF:-}"; _def="${_b##*/}"; }
      [ -n "$_def" ] || _def="main"
      [ "$_cur" != "$_def" ] || return 1
      _rem="$(git -C "$_wt" config --get "branch.$_cur.remote" 2>/dev/null || echo origin)"
      [ -n "$_rem" ] || _rem=origin
      # Already on the remote → this is an update, not a first publish. Needs the opt-in.
      ! git -C "$_wt" rev-parse --verify --quiet "refs/remotes/$_rem/$_cur" >/dev/null 2>&1 || return 1
      # A refspec, if present, must name THIS branch — no `HEAD:main` style redirection.
      _spec="$(printf '%s' "$_c" | sed -n 's/.*git push//p' | tr ' \t' '\n\n' \
               | grep -v '^-' | grep -v "^${_rem}$" | grep -v '^$' | tail -1 || true)"
      case "$_spec" in
        ""|HEAD|"$_cur"|"HEAD:$_cur"|"$_cur:$_cur") return 0 ;;
        *) return 1 ;;
      esac
    }
    case "$cmd" in
      *"git push"*)
        if [ -n "${TRACK_ALLOW_FF_PUSH:-}" ]; then
          :   # explicit opt-in (PR-rework); --force et al. still denied above
        elif is_first_publish "$cmd"; then
          :   # first publish of this worker's own branch — the path to `gh pr create`
        else
          deny "blocked by autonomy boundary: workers stop at 'gh pr create --draft'. Pushing is the merge gate's job. (Publishing your own branch for the first time is allowed so 'gh pr create' can reach the remote; this push is an update, a different branch, or a bulk/destructive mode. Set TRACK_ALLOW_FF_PUSH=1 for a PR-rework flow that updates an already-published branch.)"
        fi ;;
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
