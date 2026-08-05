#!/usr/bin/env bash
# install.sh — one-command installer for the supspec-orchestration skills.
#
# Places every artifact a consuming project needs, for GitHub Copilot and/or Claude Code,
# then delegates the hook bundle to the canonical single-branch-development installer. It is
# the top-level orchestrator; the per-bundle mechanics live in
#   .github/skills/single-branch-development/scripts/install-hooks.sh
# which this script calls so there is exactly one source of truth for the hooks/env/deps wiring.
#
# WHAT LANDS WHERE (in the TARGET repo):
#   .github/skills/*            the 3 orchestration skills          (Copilot discovery surface)
#   .claude/skills/*            the 3 orchestration skills + fetched dependency skills
#                               (superpowers, speckit)              (Claude Code discovery surface)
#   .github/instructions/*      governance instruction files        (both surfaces — see note below)
#   .github/workflows/agent-pr-audit.yml   agent-PR audit CI        (both surfaces)
#   .github/hooks/*             track-*.sh bundle + track-env.base.sh + skill-deps.json (via install-hooks.sh)
#   .claude/settings.json       Claude hook wiring                  (Claude surface, via install-hooks.sh)
#   .gitignore                  ensures runs/ is ignored            (via install-hooks.sh)
#
# CLAUDE + INSTRUCTIONS: Claude Code does NOT auto-load .github/instructions/* by their applyTo
# globs the way VS Code Copilot does. That is a no-op for correctness because the skills' governance
# gate (references/governance.md, Step 4) mandates reading the matched instruction files IN-SESSION
# on either surface. The files still live under .github/instructions/ for both; nothing extra to wire.
#
# SAFETY MODEL — writes into shared repo config AND (for Claude) fetches from GitHub, so it is
# DRY-RUN BY DEFAULT: it prints a plan and touches nothing. Pass --apply to execute. This mirrors
# install-hooks.sh's consent-gated convention.
#
# Usage:
#   ./install.sh --github-copilot                 # dry-run plan: Copilot surface
#   ./install.sh --claude-code                    # dry-run plan: Claude Code surface
#   ./install.sh --github-copilot --claude-code   # dry-run plan: both surfaces
#   ./install.sh --claude-code --apply            # execute
#   ./install.sh --claude-code --apply --no-deps  # execute, skip the GitHub dep-skill fetch
#   ./install.sh --both --apply --target ../my-project   # install into an explicit destination
#
# Flags:
#   --github-copilot | --copilot     install the Copilot surface
#   --claude-code    | --claude      install the Claude Code surface
#   --both                           shorthand for both surfaces
#   --apply                          execute the plan (default is dry-run)
#   --no-deps                        skip fetching superpowers/speckit from GitHub (Claude only)
#   --target DIR                     destination repo (default: the git repo containing $PWD)
#   -h | --help                      print this header
#
# Requires: bash, git, jq. (git is also used to fetch dependency skills at their pinned tags.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR"                      # this catalog repo = the source of truth
INSTALL_HOOKS="$SRC/.github/skills/single-branch-development/scripts/install-hooks.sh"
DEPS_MANIFEST="$SRC/.github/skills/single-branch-development/templates/skill-deps.json"

# ── argument parsing ─────────────────────────────────────────────────────────
want_copilot=0
want_claude=0
mode="dry-run"
fetch_deps=1
target_override=""
expect_target=0
for arg in "$@"; do
  if [ "$expect_target" -eq 1 ]; then target_override="$arg"; expect_target=0; continue; fi
  case "$arg" in
    --github-copilot|--copilot) want_copilot=1 ;;
    --claude-code|--claude)     want_claude=1 ;;
    --both)                     want_copilot=1; want_claude=1 ;;
    --apply)                    mode="apply" ;;
    --no-deps)                  fetch_deps=0 ;;
    --target)                   expect_target=1 ;;
    --target=*)                 target_override="${arg#--target=}" ;;
    -h|--help)                  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'install: unknown arg: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ "$want_copilot" -eq 0 ] && [ "$want_claude" -eq 0 ]; then
  printf 'install: choose at least one surface: --github-copilot and/or --claude-code (or --both)\n' >&2
  exit 2
fi
command -v git >/dev/null 2>&1 || { printf 'install: git is required\n' >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { printf 'install: jq is required\n' >&2; exit 2; }
[ -f "$INSTALL_HOOKS" ] || { printf 'install: cannot find install-hooks.sh at %s\n' "$INSTALL_HOOKS" >&2; exit 2; }

# ── resolve TARGET ───────────────────────────────────────────────────────────
if [ -n "$target_override" ]; then
  mkdir -p "$target_override" 2>/dev/null || true
  TARGET="$(cd "$target_override" && { git rev-parse --show-toplevel 2>/dev/null || pwd; })"
else
  TARGET="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# resolve to physical paths for a reliable identity check (self-install guard)
SRC_REAL="$(cd "$SRC" && pwd -P)"
TGT_REAL="$(cd "$TARGET" && pwd -P)"
self_install=0
[ "$SRC_REAL" = "$TGT_REAL" ] && self_install=1

surface_label() {
  if [ "$want_copilot" -eq 1 ] && [ "$want_claude" -eq 1 ]; then printf 'github-copilot + claude-code'
  elif [ "$want_copilot" -eq 1 ]; then printf 'github-copilot'
  else printf 'claude-code'; fi
}

say()  { printf '%s\n' "$1"; }
act()  { [ "$mode" = "apply" ]; }
# same_tree SRC DST — true when both exist and point at the same inode (never copy onto self)
same_tree() { [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ]; }

# copy_dir SRC DST — mirror a directory (create parent, preserve tree). Dry-run prints only.
copy_dir() {
  local src="$1" dst="$2"
  same_tree "$src" "$dst" && { say "     (skip: source == destination)"; return 0; }
  if act; then mkdir -p "$(dirname "$dst")"; rm -rf "$dst"; cp -R "$src" "$dst"; fi
}

# copy_file SRC DST
copy_file() {
  local src="$1" dst="$2"
  same_tree "$src" "$dst" && { say "     (skip: source == destination)"; return 0; }
  if act; then mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; fi
}

# ── header ───────────────────────────────────────────────────────────────────
say "supspec-orchestration install: $(printf '%s' "$mode" | tr '[:lower:]' '[:upper:]')"
say "  surface:  $(surface_label)"
say "  source:   $SRC_REAL"
say "  target:   $TGT_REAL"
[ "$self_install" -eq 1 ] && say "  note:     source == target (self-install; identical copies are skipped)"
say ""

skills_src="$SRC/.github/skills"
SKILL_DIRS=()
while IFS= read -r d; do SKILL_DIRS+=("$d"); done < <(find "$skills_src" -maxdepth 1 -mindepth 1 -type d | sort)

# ── 1. orchestration skills ──────────────────────────────────────────────────
if [ "$want_copilot" -eq 1 ]; then
  say "1a. Orchestration skills → .github/skills/ (Copilot discovery):"
  for d in "${SKILL_DIRS[@]}"; do
    say "     $(basename "$d")"
    copy_dir "$d" "$TARGET/.github/skills/$(basename "$d")"
  done
  say ""
fi
if [ "$want_claude" -eq 1 ]; then
  say "1b. Orchestration skills → .claude/skills/ (Claude Code discovery):"
  for d in "${SKILL_DIRS[@]}"; do
    say "     $(basename "$d")"
    copy_dir "$d" "$TARGET/.claude/skills/$(basename "$d")"
  done
  say ""
fi

# ── 2. instructions (both surfaces) ──────────────────────────────────────────
say "2. Governance instructions → .github/instructions/ (both surfaces):"
say "     Copilot auto-injects by applyTo; Claude reads them in-session at the skills' governance gate."
if act; then
  mkdir -p "$TARGET/.github/instructions"
  find "$SRC/.github/instructions" -maxdepth 1 -type f -name '*.md' -exec cp {} "$TARGET/.github/instructions/" \; 2>/dev/null || true
fi
[ "$self_install" -eq 1 ] && say "     (skip: source == destination)"
say ""

# ── 3. agent-pr-audit workflow ───────────────────────────────────────────────
say "3. CI workflow → .github/workflows/agent-pr-audit.yml:"
copy_file "$SRC/.github/workflows/agent-pr-audit.yml" "$TARGET/.github/workflows/agent-pr-audit.yml"
say ""

# ── 4. dependency skills (Claude surface only) ───────────────────────────────
# superpowers + speckit are NOT vendored here — fetch each from GitHub at the version pinned in
# skill-deps.json. Best-effort + loud: tag-format fallbacks, default-branch fallback with a warning.
dep_version() { jq -r --arg k "$1" '.dependencies[$k].range // ""' "$DEPS_MANIFEST" | sed 's/[^0-9.]//g'; }

fetch_dep() {
  # fetch_dep NAME REPO_URL SUBPATH DEST_UNDER_CLAUDE_SKILLS
  #   SUBPATH = subtree inside the clone to copy ("" = whole repo). DEST = target dir name.
  local name="$1" url="$2" subpath="$3" dest="$4" ver tmp got_tag=""
  ver="$(dep_version "$name")"
  say "4. Dependency skill '$name' (pinned $ver) → .claude/skills/$dest:"
  if [ -z "$ver" ]; then say "     no version pinned in skill-deps.json — skipping."; return 0; fi
  if ! act; then say "     would clone $url @ v$ver (or $ver), copy ${subpath:-<repo root>}"; say ""; return 0; fi
  tmp="$(mktemp -d)"
  for tag in "v$ver" "$ver"; do
    if git clone --depth 1 --branch "$tag" "$url" "$tmp/clone" >/dev/null 2>&1; then got_tag="$tag"; break; fi
  done
  if [ -z "$got_tag" ]; then
    say "     ⚠ could not clone $url at tag v$ver/$ver — falling back to the default branch (UNPINNED)."
    if ! git clone --depth 1 "$url" "$tmp/clone" >/dev/null 2>&1; then
      say "     ✗ clone failed entirely (offline? repo moved?) — skipping '$name'. Install it manually."
      rm -rf "$tmp"; say ""; return 0
    fi
  fi
  local from="$tmp/clone"
  [ -n "$subpath" ] && from="$tmp/clone/$subpath"
  if [ ! -e "$from" ]; then
    say "     ⚠ expected subpath '$subpath' not found in $name@${got_tag:-default} — layout may have changed."
    say "       Copying the whole checkout instead; verify .claude/skills/$dest afterwards."
    from="$tmp/clone"
  fi
  mkdir -p "$TARGET/.claude/skills/$dest"
  # copy the CONTENTS of $from into the destination
  cp -R "$from/." "$TARGET/.claude/skills/$dest/" 2>/dev/null || cp -R "$from" "$TARGET/.claude/skills/$dest"
  rm -rf "$TARGET/.claude/skills/$dest/.git" 2>/dev/null || true
  rm -rf "$tmp"
  say "     ✓ vendored $name@${got_tag:-default-branch}"
  say ""
}

if [ "$want_claude" -eq 1 ] && [ "$fetch_deps" -eq 1 ]; then
  # superpowers ships its skills under skills/ ; speckit has no skills/ tree, vendor the checkout.
  fetch_dep superpowers https://github.com/obra/superpowers.git skills superpowers
  fetch_dep speckit     https://github.com/github/spec-kit.git   ""     speckit
elif [ "$want_claude" -eq 1 ]; then
  say "4. Dependency skills: --no-deps set — skipping superpowers/speckit fetch."
  say "     Ensure they are installed some other way (plugin / manual clone) so the referenced"
  say "     skills resolve: subagent-driven-development, dispatching-parallel-agents, requesting-code-review,"
  say "     using-git-worktrees, verification-before-completion, test-driven-development, systematic-debugging."
  say ""
fi

# ── 5. hook bundle (delegated to the canonical installer) ────────────────────
hooksurface="both"
if [ "$want_copilot" -eq 1 ] && [ "$want_claude" -eq 0 ]; then hooksurface="copilot"; fi
if [ "$want_claude" -eq 1 ] && [ "$want_copilot" -eq 0 ]; then hooksurface="claude"; fi

say "5. Hook bundle → .github/hooks/ (delegated to install-hooks.sh --surface $hooksurface):"
say ""
if act; then
  ( cd "$TARGET" && bash "$INSTALL_HOOKS" --surface "$hooksurface" --apply )
else
  ( cd "$TARGET" && bash "$INSTALL_HOOKS" --surface "$hooksurface" )
fi
say ""

# ── footer ───────────────────────────────────────────────────────────────────
if act; then
  say "Done. Review the changes, then commit them in the target repo:"
  say "  cd $TGT_REAL && git add .github .claude .gitignore && git status"
  if [ "$want_claude" -eq 1 ]; then
    say ""
    say "Claude Code reminder: instructions are NOT auto-injected. The skills read .github/instructions/*"
    say "in-session at their governance gate — no extra wiring, but do not delete that directory."
  fi
else
  say "Dry-run only — nothing written and nothing fetched."
  say "Re-run with --apply to execute:"
  say "  ./install.sh $(surface_label | sed 's/ + / --/; s/^/--/') --apply"
fi
