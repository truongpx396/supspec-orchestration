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
#   .claude/skills/*            the 3 orchestration skills + fetched dependency skills
#                               (superpowers, speckit)              (Claude Code surface; ALSO the
#                                                                     Copilot surface when --both is
#                                                                     requested — Copilot discovers
#                                                                     .claude/skills/ too, so a --both
#                                                                     install writes ONE copy here
#                                                                     rather than duplicating into
#                                                                     .github/skills/)
#   .github/skills/*            the 3 orchestration skills + speckit (Copilot-ONLY installs — i.e.
#                                                                     --github-copilot without --claude-code)
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
# SAFETY MODEL — writes into shared repo config AND fetches from GitHub/PyPI for whichever
# surface(s) are selected, so it is DRY-RUN BY DEFAULT: it prints a plan and touches nothing.
# Pass --apply to execute. This mirrors install-hooks.sh's consent-gated convention.
#
# VERSION SELECTION — by DEFAULT this installs the LATEST published release. It resolves the newest
# vX.Y.Z tag from the catalog remote, clones the catalog at that tag, and re-executes THAT tag's own
# install.sh (so the installer logic always matches the version it installs — no bootstrap skew).
# Pass --ref <tag> to pin an exact release, or --local to skip fetching and install this checkout as-is
# (offline / development). Running the script from inside the catalog repo itself is always treated as
# --local. If the latest tag cannot be resolved (offline, no releases), it falls back to this checkout.
#
# Usage:
#   ./install.sh --github-copilot                 # dry-run plan: Copilot surface (latest release)
#   ./install.sh --claude-code                    # dry-run plan: Claude Code surface (latest release)
#   ./install.sh --github-copilot --claude-code   # dry-run plan: both surfaces
#   ./install.sh --claude-code --apply            # execute (latest release)
#   ./install.sh --both --apply --ref v0.1.1      # execute, pinned to an exact release tag
#   ./install.sh --both --apply --local           # execute from this checkout, no GitHub fetch
#   ./install.sh --claude-code --apply --no-deps  # execute, skip the GitHub dep-skill fetch
#   ./install.sh --both --apply --target ../my-project   # install into an explicit destination
#
# Flags:
#   --github-copilot | --copilot     install the Copilot surface
#   --claude-code    | --claude      install the Claude Code surface
#   --both                           shorthand for both surfaces
#   --apply                          execute the plan (default is dry-run)
#   --ref TAG                        install this exact release tag (default: latest release)
#   --local | --no-fetch             install this checkout as-is; do not fetch a release from GitHub
#   --no-deps                        skip fetching the superpowers/speckit dependency skills
#   --target DIR                     destination repo (default: the git repo containing $PWD)
#   -h | --help                      print this header
#
# Requires: bash, git, jq. git also fetches superpowers at its pinned tag. speckit is installed
# via its own `specify` CLI, run ephemerally through `uvx` (https://docs.astral.sh/uv/) pinned to
# the version in skill-deps.json — no persistent `specify` install needed. Without uvx on PATH,
# the speckit skill fetch is skipped with instructions to install it manually.
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
ref_override=""
expect_ref=0
use_local=0
passthru=()   # args forwarded verbatim on a version re-exec (excludes --ref/--local)
for arg in "$@"; do
  if [ "$expect_target" -eq 1 ]; then target_override="$arg"; expect_target=0; passthru+=(--target "$arg"); continue; fi
  if [ "$expect_ref" -eq 1 ]; then ref_override="$arg"; expect_ref=0; continue; fi
  case "$arg" in
    --github-copilot|--copilot) want_copilot=1; passthru+=("$arg") ;;
    --claude-code|--claude)     want_claude=1; passthru+=("$arg") ;;
    --both)                     want_copilot=1; want_claude=1; passthru+=("$arg") ;;
    --apply)                    mode="apply"; passthru+=("$arg") ;;
    --no-deps)                  fetch_deps=0; passthru+=("$arg") ;;
    --target)                   expect_target=1 ;;
    --target=*)                 target_override="${arg#--target=}"; passthru+=("$arg") ;;
    --ref)                      expect_ref=1 ;;
    --ref=*)                    ref_override="${arg#--ref=}" ;;
    --local|--no-fetch)         use_local=1 ;;
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

say() { printf '%s\n' "$1"; }   # defined early so version selection can report

# ── version selection (default = latest release; --ref pins; --local forces checkout) ──
# Resolves the requested catalog version, clones it, and re-execs ITS OWN install.sh so the
# installer always matches the version being installed. Guarded against loops, self-install,
# and offline/failed fetches (loud fallback to the local checkout).
CATALOG_URL="${SUPSPEC_CATALOG_URL:-$(git -C "$SRC" remote get-url origin 2>/dev/null || true)}"
[ -n "$CATALOG_URL" ] || CATALOG_URL="https://github.com/truongpx396/supspec-orchestration.git"
current_version() { git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown; }
latest_release_tag() {
  git ls-remote --tags --refs "$CATALOG_URL" 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -1 || true
}

install_version="$(current_version)"
if [ -n "${SUPSPEC_INSTALL_REEXECED:-}" ]; then
  install_version="$(current_version) (fetched release)"
elif [ "$use_local" -eq 1 ]; then
  install_version="$install_version (local checkout, --local)"
elif [ "$self_install" -eq 1 ]; then
  install_version="$install_version (local checkout; self-install)"
else
  want_ref="$ref_override"
  if [ -z "$want_ref" ] || [ "$want_ref" = latest ]; then
    want_ref="$(latest_release_tag)"
    if [ -z "$want_ref" ]; then
      say "install: could not resolve the latest release tag from $CATALOG_URL"
      say "         (offline, or no releases?) — falling back to this checkout ($(current_version))."
      say ""
      install_version="$(current_version) (local fallback)"
    fi
  fi
  if [ -n "$want_ref" ]; then
    if [ "$want_ref" = "$(current_version)" ]; then
      install_version="$want_ref (this checkout already matches)"
    else
      say "supspec-orchestration install: fetching $want_ref (this checkout: $(current_version))"
      reexec_tmp="$(mktemp -d)"
      if git clone --depth 1 --branch "$want_ref" "$CATALOG_URL" "$reexec_tmp/catalog" >/dev/null 2>&1; then
        say "  → re-executing $want_ref's own installer for a skew-free install"
        say ""
        export SUPSPEC_INSTALL_REEXECED=1
        exec bash "$reexec_tmp/catalog/install.sh" "${passthru[@]}"
      fi
      rm -rf "$reexec_tmp"
      say "install: could not fetch $want_ref from $CATALOG_URL — falling back to this checkout ($(current_version))."
      say ""
      install_version="$(current_version) (local fallback)"
    fi
  fi
fi

surface_label() {
  if [ "$want_copilot" -eq 1 ] && [ "$want_claude" -eq 1 ]; then printf 'github-copilot + claude-code'
  elif [ "$want_copilot" -eq 1 ]; then printf 'github-copilot'
  else printf 'claude-code'; fi
}

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
say "  version:  $install_version"
say "  source:   $SRC_REAL"
say "  target:   $TGT_REAL"
[ "$self_install" -eq 1 ] && say "  note:     source == target (self-install; identical copies are skipped)"
say ""

skills_src="$SRC/.github/skills"
SKILL_DIRS=()
while IFS= read -r d; do SKILL_DIRS+=("$d"); done < <(find "$skills_src" -maxdepth 1 -mindepth 1 -type d | sort)

# ── 1. orchestration skills ──────────────────────────────────────────────────
# GitHub Copilot (Dec 2025+) discovers project skills from .claude/skills/ as well as
# .github/skills/. So when BOTH surfaces are requested we write ONE copy — under
# .claude/skills/, the path Claude Code requires — instead of duplicating into
# .github/skills/ too: one source of truth, no drift between two copies. A Copilot-only
# install (no --claude-code) still uses .github/skills/, its own surface-specific path,
# so it does not depend on that cross-directory discovery being available/enabled.
if [ "$want_claude" -eq 1 ]; then
  if [ "$want_copilot" -eq 1 ]; then
    say "1. Orchestration skills → .claude/skills/ (Claude Code + Copilot discovery):"
  else
    say "1. Orchestration skills → .claude/skills/ (Claude Code discovery):"
  fi
  for d in "${SKILL_DIRS[@]}"; do
    say "     $(basename "$d")"
    copy_dir "$d" "$TARGET/.claude/skills/$(basename "$d")"
  done
  say ""
elif [ "$want_copilot" -eq 1 ]; then
  say "1. Orchestration skills → .github/skills/ (Copilot discovery):"
  for d in "${SKILL_DIRS[@]}"; do
    say "     $(basename "$d")"
    copy_dir "$d" "$TARGET/.github/skills/$(basename "$d")"
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

# ── 4. dependency skills ──────────────────────────────────────────────────────
# superpowers is a Claude Code skills/plugin catalog — vendored narrowly (its own skills/
# subtree only) for the Claude surface, at the version pinned in skill-deps.json.
#
# speckit is NOT vendored (no git clone of github/spec-kit): it is installed via its OWN
# `specify` CLI (`specify integration install <key>`), which scaffolds the narrow
# speckit-*/SKILL.md bundle + shared .specify/ infra itself — the purpose-built mechanism
# spec-kit ships for exactly this, instead of a ~500-file/16MB raw checkout with no SKILL.md
# of its own. See fetch_speckit_skills below. Best-effort + loud throughout.
dep_version() { jq -r --arg k "$1" '.dependencies[$k].range // ""' "$DEPS_MANIFEST" | sed 's/[^0-9.]//g'; }

fetch_dep() {
  # fetch_dep NAME REPO_URL SUBPATH DEST_UNDER_CLAUDE_SKILLS
  #   SUBPATH = subtree inside the clone to copy ("" = whole repo). DEST = target dir name.
  local name="$1" url="$2" subpath="$3" dest="$4" ver tmp got_tag=""
  ver="$(dep_version "$name")"
  say "4a. Dependency skill '$name' (pinned $ver) → .claude/skills/$dest:"
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

fetch_speckit_skills() {
  # Installs the speckit-* skills by shelling out to the `specify` CLI itself, pinned to
  # the version in skill-deps.json via `uvx --from specify-cli==<ver>` (astral-sh/uv) — an
  # ephemeral run, no persistent `specify` install left behind. Targets whichever surface(s)
  # were selected, applying the same single-copy rule as step 1: when both --claude-code and
  # --github-copilot are requested, install only the `claude` integration (→ .claude/skills/,
  # which Copilot also discovers) rather than duplicating a second `copilot` integration into
  # .github/skills/. A Copilot-only install uses the `copilot` integration directly, in
  # explicit --skills mode (its default has changed across spec-kit releases; pin it).
  local ver key label opts=()
  ver="$(dep_version speckit)"
  say "4b. Dependency skill 'speckit' (pinned $ver) via the specify CLI:"
  if [ -z "$ver" ]; then say "     no version pinned in skill-deps.json — skipping."; say ""; return 0; fi
  if [ "$want_claude" -eq 1 ]; then
    key=claude; label=".claude/skills/speckit-*"
  else
    key=copilot; opts=(--integration-options="--skills"); label=".github/skills/speckit-*"
  fi
  if ! command -v uvx >/dev/null 2>&1; then
    say "     ⚠ 'uvx' (astral-sh/uv — https://docs.astral.sh/uv/) not found on PATH — cannot run a"
    say "       pinned specify CLI. Install uv, or install specify-cli yourself, then run:"
    say "         specify integration install $key${opts:+ --integration-options=\"--skills\"}"
    say ""
    return 0
  fi
  if ! act; then
    say "     would run: specify integration install $key${opts:+ --integration-options=\"--skills\"} → $label"
    [ "$want_claude" -eq 1 ] && [ "$want_copilot" -eq 1 ] && \
      say "     (skip a separate copilot install: Copilot also discovers .claude/skills/)"
    say ""
    return 0
  fi
  if [ ! -d "$TARGET/.specify" ]; then
    say "     ⚠ $TARGET has no .specify/ — not an initialized Spec Kit project (see Prerequisites)."
    say "       Run 'specify init --here' in the target repo yourself first, then re-run this installer."
    say ""
    return 0
  fi
  local out status
  out="$(cd "$TARGET" && uvx --from "specify-cli==$ver" specify integration install "$key" --script sh --force "${opts[@]+"${opts[@]}"}" 2>&1)"; status=$?
  # `specify integration install` is IDEMPOTENT, and --force does not change that: on a repo
  # that already has the integration it prints "Integration '<key>' is already installed …
  # No files were changed" and exits 0. Exit status alone therefore cannot tell "installed at
  # the pinned version" from "left whatever was already on disk" — so a re-run of this
  # installer reported the pin as applied while an older speckit bundle stayed put. `upgrade`
  # is the command that actually re-writes the files (same flags, diff-aware).
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -qiE "already installed|no files were changed"; then
    say "     · '$key' integration already present — install is a no-op; upgrading in place."
    out="$(cd "$TARGET" && uvx --from "specify-cli==$ver" specify integration upgrade "$key" --script sh --force "${opts[@]+"${opts[@]}"}" 2>&1)"; status=$?
  fi
  if [ "$status" -ne 0 ]; then
    say "     ✗ specify integration install/upgrade $key failed:"
    say "$out" | sed 's/^/       /'
    say ""
    return 0
  fi
  # VERIFY instead of trusting the exit code: read back what the integration recorded about
  # itself. A pin nobody checks is a pin that can silently not apply — which is the bug this
  # block exists for. Best-effort: an unreadable/absent file is reported, never fatal.
  local state="$TARGET/.specify/integration.json" got="" have_key=""
  if [ -f "$state" ]; then
    got="$(jq -r '.version // empty' "$state" 2>/dev/null || true)"
    have_key="$(jq -r --arg k "$key" '((.installed_integrations // []) | index($k)) // empty' "$state" 2>/dev/null || true)"
  fi
  if [ -n "$got" ] && [ "$got" != "$ver" ]; then
    say "     ⚠ '$key' installed, but .specify/integration.json reports version $got (pinned $ver)."
    say "       Reconcile manually: specify integration upgrade $key --force"
    say ""
    return 0
  fi
  if [ -f "$state" ] && [ -z "$have_key" ]; then
    say "     ⚠ '$key' reported success but is absent from .specify/integration.json installed_integrations."
    say "       Check manually: specify integration status"
    say ""
    return 0
  fi
  say "     ✓ installed speckit skills for '$key' → $label${got:+ (integration.json: $got)}"
  [ "$want_claude" -eq 1 ] && [ "$want_copilot" -eq 1 ] && \
    say "     (skipped a separate copilot install: Copilot also discovers .claude/skills/)"
  say ""
}

if [ "$fetch_deps" -eq 1 ]; then
  [ "$want_claude" -eq 1 ] && fetch_dep superpowers https://github.com/obra/superpowers.git skills superpowers
  { [ "$want_claude" -eq 1 ] || [ "$want_copilot" -eq 1 ]; } && fetch_speckit_skills
elif [ "$want_claude" -eq 1 ] || [ "$want_copilot" -eq 1 ]; then
  say "4. Dependency skills: --no-deps set — skipping superpowers/speckit fetch."
  say "     Ensure they are installed some other way (plugin / manual clone / 'specify integration"
  say "     install') so the referenced skills resolve: subagent-driven-development,"
  say "     dispatching-parallel-agents, requesting-code-review, using-git-worktrees,"
  say "     verification-before-completion, test-driven-development, systematic-debugging, speckit-*."
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
