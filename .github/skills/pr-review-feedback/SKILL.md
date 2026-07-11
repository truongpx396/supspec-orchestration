---
name: pr-review-feedback
description: 'Rework an existing pull request in response to review feedback: triage comments, apply
fixes on the PR branch under TDD/regression discipline, re-capture evidence at the new fingerprint,
and update the PR (fast-forward push) or hand back to the reviewer. Use when asked to "address PR
comments", "respond to review feedback", "fix review findings", or "push review changes". Reuses the
single-branch-development hooks bundle in resume mode — this is post-implementation maintenance, not a
fresh feature build.'
---

# PR Review Feedback

Turn a batch of PR review comments into applied, evidenced changes on the **existing** PR branch. This
is **not** an execution core of `single-branch-development` — it starts mid-stream on already-merged-to-
branch work, so there is no preflight-mint, no isolate, no RED authoring from scratch. It is a distinct
lifecycle stage that **reuses that skill's hooks bundle in resume mode** and closes with a PR update
instead of a fresh draft PR.

## When to Use This Skill

- User asks to address, respond to, or resolve pull-request review comments.
- A reviewer left change requests and you must apply fixes on the same PR branch.
- CI or a human flagged findings on an open PR that need rework + re-verification.
- **Not** for building a feature/bugfix from scratch — use `single-branch-development` (story mode / N=1).
- **Not** for evaluating *incoming* review feedback quality — that decision lives in `receiving-code-review`.

## Prerequisites

- An **existing** PR branch checked out (or its name known); `git` + `gh` authenticated.
- The review comments available (PR thread, `gh pr view --comments`, or pasted).
- Project test commands known (lint/unit/integration/e2e as applicable).
- The `single-branch-development` hooks bundle installed in `.github/hooks/` (this skill ships **no**
  hooks of its own — see [Hooks](#hooks-reused-not-owned)).

## Pipeline

The bracket is the **resume half** of `single-branch-development`: no fresh mint, no isolate. The core
is triage → fix-under-test → re-evidence → update.

1. **Triage the feedback** (`receiving-code-review`) — classify each comment: *accept*, *reject with
   rationale*, or *needs clarification*. Do **not** blindly implement — a technically wrong suggestion
   gets a reasoned pushback, not a change. Group accepted items into fix batches.
2. **Reconcile / resume** — run [`track-reconcile.sh`](../single-branch-development/scripts/track-reconcile.sh)
   against the PR branch to rebuild position from committed history + `runs/<run-id>.json`. Stash any
   untrusted `dirty_worktree`; set `TRACK_BASE_REF` to the **PR base** so the evidence gate recomputes
   exactly which kinds the rework touches.
3. **Fix under test discipline:**
   - **Behavioral fix** → `test-driven-development`: add/adjust a failing test that encodes the
     reviewer's concern *first*, then green it. A regression fix is `systematic-debugging` →
     failing-repro-test → green.
   - **Independent fixes** → optionally fan out generation with `dispatching-parallel-agents` (each
     subagent returns a file body; controller lands them serially).
   - **Non-behavioral fix** (rename, comment, config) → apply directly; no test.
4. **Re-review the delta** (`requesting-code-review`) — a fresh two-stage pass over the fix diff
   (stage-1 spec/comment-resolution, stage-2 quality); apply `security-and-owasp.instructions.md` for
   any trust-boundary change. A review fix **invalidates prior green** — earlier evidence is now stale.
5. **Converge & re-capture evidence** (`verification-before-completion`) — make no further edits, then
   re-run **every** required evidence kind so all captures share the new post-fix fingerprint. The
   evidence gate blocks on stale/missing lanes; paste real output.
6. **Update the PR** — commit the fixes, then either:
   - **push a fast-forward update** to the existing PR branch (requires `TRACK_ALLOW_FF_PUSH=1`; the
     guard still denies `--force`, `git merge`, `gh pr merge`, `--no-verify`, `reset --hard`), and
     reply to each resolved thread; **or**
   - **stop and hand back** — commit locally, pass the evidence pack, and let a human/merge queue push
     (the default when `TRACK_ALLOW_FF_PUSH` is unset). Merge itself is never the worker's job.

## Skill-Per-Step Map

| Step | Superpower skill / script |
|------|---------------------------|
| 1 Triage feedback | `receiving-code-review` |
| 2 Reconcile / resume | `track-reconcile.sh` (single-branch-development bundle) |
| 3 Behavioral fix | `test-driven-development` (+ `systematic-debugging` for regressions) |
| 3 Independent fixes | `dispatching-parallel-agents` (generate-only) |
| 4 Re-review delta | `requesting-code-review` + `security-and-owasp` (trust-boundary) |
| 5 Converge & re-evidence | `verification-before-completion` |
| 6 Update PR | fast-forward `git push` (opt-in) **or** hand back — never `gh pr merge` |

## Hooks (Reused, Not Owned)

This skill ships **no hooks**. It reuses the `single-branch-development` bundle
([`../single-branch-development/scripts/`](../single-branch-development/scripts/)) unchanged, because
hooks key on git/tool operations and env vars — **not** on which skill is driving. The evidence
capture/gate (`track-evidence.sh`, `track-evidence-gate.sh`) is the highest-value reuse here: it forces
a fresh capture at the post-fix fingerprint so an "already reviewed" PR can't ship stale green.

The **only** configuration difference from a fresh build:

- Set `TRACK_BASE_REF=<pr-base>` (e.g. `origin/main`) so the diff-conditional gate selects the right
  evidence kinds for the rework.
- Set `TRACK_ALLOW_FF_PUSH=1` **only if** this flow should push the PR-branch update itself. Leave it
  unset to keep the default push lockout (commit + hand back).

See [`../single-branch-development/references/hooks.md`](../single-branch-development/references/hooks.md)
for the full bundle, env reference, and what the run record captures.

## Gotchas

- **Don't blindly implement review comments.** `receiving-code-review` exists precisely so a wrong or
  unclear suggestion gets a reasoned response, not a reflexive change. Triage before you touch code.
- **A review fix invalidates prior evidence.** The fingerprint is whole-tree, so any post-review edit
  makes earlier "all green" stale. You **must** re-run every required kind (Step 5), not just the
  lane you touched — the gate will bounce you otherwise.
- **`TRACK_ALLOW_FF_PUSH` permits *only* a fast-forward push.** `--force`, `git merge`, `gh pr merge`,
  `--no-verify`, and `reset --hard` stay denied. If you need a rebase/force-push to tidy history, that
  is a human/merge-queue decision, not the worker's.
- **Never resolve a review thread by weakening a test.** If a reviewer's concern is a real test gap,
  add the test; don't `skip` or loosen an existing assertion to make CI green.
- **Set `TRACK_BASE_REF` or the gate under-selects.** Without it the diff-vs-HEAD on a committed rework
  is empty, so the gate requires nothing and silently passes (same trap as the base skill).

## References

- **Triage owned by** `receiving-code-review` (accept/reject/clarify each comment before implementing).
- **Fix discipline** delegates to `test-driven-development` (+ `systematic-debugging` for regressions)
  and, for independent items, `dispatching-parallel-agents` (generate-only).
- **Re-review + re-evidence** reuse `requesting-code-review` (+ `security-and-owasp`) and
  `verification-before-completion`.
- **Hooks + run record** are single-sourced in
  [`../single-branch-development/references/hooks.md`](../single-branch-development/references/hooks.md);
  this skill only sets `TRACK_BASE_REF` and (optionally) `TRACK_ALLOW_FF_PUSH`.
- Related builder: [`../single-branch-development/SKILL.md`](../single-branch-development/SKILL.md) —
  the from-scratch implement pipeline this flow resumes from.
