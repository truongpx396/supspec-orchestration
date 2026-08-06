# Changelog

All notable changes to this repository's skills are documented here. Versioning follows
[Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`, pre-1.0 (`0.x`) while the skill
contracts are still stabilizing — matching the convention used by
[SpecKit](https://github.com/github/spec-kit) and [Superpowers](https://github.com/obra/superpowers).

Each skill's `SKILL.md` frontmatter carries its own `version` field; this file tracks the
whole-repo release that ships them together.

## [0.4.0] - 2026-08-07

Installer cleanup: `speckit` was vendored as a full repo clone, and a dual-surface install wrote the
orchestration skills twice. Both were installer defects reported from a real consuming-repo install,
not the skills' own pipeline logic.

- **`install.sh`**:
  - **`speckit` is installed via its own `specify` CLI, not a `git clone` of the whole repo.**
    `fetch_dep` used to clone all of `github/spec-kit` (562 files, ~16MB — docs, tests, CI workflows,
    media, `pyproject.toml`) into `.claude/skills/speckit/`, which had no root `SKILL.md` of its own
    and was never actually discoverable as a skill. Now runs `specify integration install claude` or
    `copilot`, pinned and run ephemerally via `uvx --from specify-cli==<ver>` (no persistent `specify`
    install left behind) — producing the ~9 narrow `speckit-*/SKILL.md` bundles spec-kit ships for
    exactly this, plus its `.specify/` shared infra (~130KB total, vs. the old 16MB). Requires the
    target repo to already be an initialized Spec Kit project (see Prerequisites); falls back with an
    actionable warning if `uvx` or `.specify/` is missing. `--no-deps` still skips the fetch entirely.
  - **A `--both` install now writes the 3 orchestration skills once, not twice.** GitHub Copilot
    (Dec 2025+) discovers project skills from `.claude/skills/` as well as `.github/skills/`, so
    duplicating into both on every dual-surface install was pure drift risk — edit one copy, forget
    the other. `--both` now writes a single copy under `.claude/skills/`; a Copilot-only install
    (no `--claude-code`) still uses `.github/skills/` on its own, unaffected.
  - `skill-deps.json`'s `speckit` probe checked `speckit --version`, a binary that has never existed
    (the CLI is `specify`) — it silently reported "missing" every run, masked only because the
    dependency is `required:false`. Fixed to `specify --version`; the pinned version bumped
    `0.15.2` → `0.16.0` (current release).

- **`single-branch-development`** (0.2.0 → 0.2.1): every PR body now ends with a fixed
  `🌱 Powered by Supspec Orchestration 🤖` footer linking the catalog repo — the one section in
  `templates/pr-body.md` exempted from "delete what doesn't apply."

- **CI** — `agent-pr-audit.yml`'s meta-work exemption now also covers `install.sh`. Same
  unsatisfiable-rule shape the CHANGELOG.md exemption fixed in v0.3.0: `install.sh` is this repo's
  own installer, not product code, and this release's own PR (agent-authored, no run record) is what
  hit the gap. The waiver still fires only when every changed file is tooling, still waives presence
  and never integrity, and a release PR touching the gates still gets the `GATE_PATHS_RE` warning.

## [0.3.0] - 2026-08-06

Evidence-integrity release. A real scaffold run produced a green PR whose required-evidence pack had
been satisfied without running a single test, and the discipline audit reported convergence that had
not happened. Both were tooling defects, not worker misbehavior. This release closes them and corrects
two places where the tooling described itself as stronger than it was.

- **`single-branch-development`** (0.1.0 → 0.2.0):
  - **Evidence capture matches what a command RUNS, not what it contains** (`track-evidence.sh`).
    Patterns are now matched against the command with heredoc bodies and quoted literals stripped.
    Writing the PR body — which embeds the evidence table quoting `go test ./...` — used to register
    as a passing `go-test` capture, so the report certified itself; echoing a payload into the hook
    while debugging did the same. On the observed run all three required kinds were satisfied this
    way. Real invocations, including prefixed (`npx tsc --noEmit`) and quoted-argument forms, are
    unaffected.
  - **Pass/fail is settled once, at capture, and recorded** as `verdict` + `verdict_by`. It reads an
    explicit exit code where the surface reports one, then a non-zero-exit marker
    (`returnCodeInterpretation`), and only then scans output text — which now also catches the
    `exit: N` idiom. `track-evidence-gate.sh` and `track-report.sh` read that verdict instead of each
    re-deriving one; they previously shipped *different* default fail-patterns and could grade the
    same capture differently. Captures printing `exit: 1` were being rendered ✅ pass.
  - **The fingerprint follows the run branch's worktree**, resolved from the breadcrumb via
    `git worktree list`, instead of the hook's working directory — which is the main checkout even
    while the agent edits a linked worktree. Fingerprinting the wrong tree made every capture agree
    trivially: the gate's staleness check was inert, and the audit's `E1` reported "converged" for
    exactly that reason. Both sides of the comparison were changed together.
  - **Token accounting uses the provider's own numbers** (`track-tokens.sh`). The transcript filter
    recognized only one surface's schema, so on Claude Code it counted 0 characters — which silently
    disabled the ceiling, since 0 never exceeds it. Both schemas are now read, and `message.usage` is
    preferred when present: authoritative, and inclusive of the system prompt and tool schemas the
    heuristic cannot see. Adds a `token_usage` breakdown. **`TRACK_MAX_TOKEN_ESTIMATE` default raised
    200000 → 800000; re-tune any inherited value**, as the real counts run several times the old
    estimate.
  - **`SubagentStart` and `PreCompact` wired for Claude Code** (`templates/claude-settings.json`).
    Both are real events; the template omitted them on the documented-but-mistaken belief that Claude
    Code had only `SubagentStop`. `agent_description` — the subagent's one-line reason for being
    spawned — is carried on start only, so traces read as anonymous stop events with no "why".
  - **The guard leaves a compliant path to the PR** (`track-guard.sh`). `gh pr create` cannot open a
    PR for a branch the remote has never seen, so denying every push made the skill's own terminal
    step unreachable and pressured a worker into self-granting `TRACK_ALLOW_FF_PUSH`, a flag meant for
    something else. A worker may now publish its own branch **once**. The base branch, another branch,
    refspec redirects, `--force`/`--delete`/`--all`/`--tags`, and any second push of the same branch
    remain denied — so the rework flag keeps its documented meaning.
  - **`G3` states its provenance** (`track-audit.sh`). It compares a model-written timestamp against
    hook-written `trace[]`, so lowering that stamp satisfies it — and a run did edit it and then cite
    G3 as confirmation. The verdict now says whether a hook-observed bundle read corroborated the
    ordering. `governance_reads[]` entries additionally record `via`, the matched path or command.
  - **Corrected two self-descriptions that overstated the audit.** The PR-body footnote listed
    `G1`–`G4` among checks "derived from artifacts the model does not author"; `G1` and `G3` both read
    `governance_bundle`, a model-written field, and are now listed as mixed with the specific weakness
    of each named. The README carried the same claim about the audit as a whole.
  - **Discipline audit promoted to a peer section** in the PR body (`###`, matching the `Asserted`
    zone) and moved to the end of the machine-rendered block — out of the middle of the raw data, but
    still ahead of the model's narrative, which it exists to help a reviewer calibrate.
  - Per-track breadcrumb (`runs/<RUN_ID>.dispatch`) is written pretty-printed, matching the run record
    and wave dispatch; it was the only artifact still emitted as a single compact line.
  - Tests: 226 → 251, including the two forgery vectors, verdict-from-exit-code, worktree-relative
    fingerprinting, both transcript schemas, provider-usage preference, the nine first-publish guard
    boundaries, and `G4` in both directions. Fixed a pre-existing isolation bug that made the audit
    suite depend on the contributor's ambient working diff.

- **CI** — `agent-pr-audit.yml`'s meta-work exemption now covers `CHANGELOG.md`. Every release PR must
  edit the changelog and, like all maintenance-on-the-pipeline work, produces no run record — so
  release PRs could satisfy neither the exemption nor the Auto-block requirement. Caught by the gate
  on this very release. The waiver is unchanged otherwise: it still requires *every* file to be
  tooling, still waives presence and never integrity, and still raises the 🔴 "this PR modifies the
  enforcement itself" warning.

## [0.2.0] - 2026-08-06

Installer version selection: `install.sh` can now install a specific release, defaulting to latest.

- **`install.sh`** — new `--ref <tag>` flag pins an exact release, and installs the **latest published
  release by default** (resolves the newest `vX.Y.Z` tag from the catalog remote, clones the catalog at
  that tag, and re-executes *that tag's own* `install.sh` so the installer logic always matches the
  version it installs — no bootstrap skew). New `--local` / `--no-fetch` installs the current checkout
  as-is; running from inside the catalog repo is always treated as `--local`. Offline or unresolved-tag
  cases fall back to the local checkout with a warning. The resolved version is shown on the plan
  header's `version:` line. Mirrors SpecKit's default-latest-with-`@vX.Y.Z`-pin model. No skill
  behavior changed.

## [0.1.1] - 2026-08-06

Hotfix: keep `SKILL.md` bodies within the 500-line hard maximum enforced by CI.

- **`executing-parallel-tracks`** (0.1.0 → 0.1.1) — the `SKILL.md` body had grown to 501 lines,
  one over the hard cap. Moved the detailed wave-dispatch and run-record JSON schemas out of the
  "Traceability" section into `references/traceability.md` (progressive disclosure), leaving a
  concise summary and a link in the body. No behavioral change to the skill; content preserved.

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

[0.3.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.3.0
[0.2.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.2.0
[0.1.1]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.1.1
[0.1.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.1.0
