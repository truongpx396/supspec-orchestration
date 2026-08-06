# Changelog

All notable changes to this repository's skills are documented here. Versioning follows
[Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`, pre-1.0 (`0.x`) while the skill
contracts are still stabilizing — matching the convention used by
[SpecKit](https://github.com/github/spec-kit) and [Superpowers](https://github.com/obra/superpowers).

Each skill's `SKILL.md` frontmatter carries its own `version` field; this file tracks the
whole-repo release that ships them together.

## [0.1.0] - 2026-08-06

Initial tagged release. Three composable skills plus their shared mechanical-hooks bundle:

- **`single-branch-development`** — per-branch pipeline (scaffold / story / refactor modes) with
  two-stage spec-compliance + code-quality verification, evidence capture, and draft-PR handoff.
- **`executing-parallel-tracks`** — multi-track conductor: isolated worktrees per track, wave
  planning, and a merge-queue handoff.
- **`pr-review-feedback`** — reworks an existing PR against review feedback under the same
  TDD/regression discipline.
- Shared `.github/hooks/` mechanical gate bundle (scope/evidence/token-ceiling enforcement,
  dependency version-lock via `skill-deps.json`, discipline audit) installable via
  `scripts/install-hooks.sh` for both Copilot and Claude Code surfaces.
- One-command repo bootstrap via `install.sh`.

[0.1.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.1.0
