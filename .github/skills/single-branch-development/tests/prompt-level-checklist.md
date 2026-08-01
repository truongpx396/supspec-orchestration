# Prompt-Level Invariant Checklist

*10 items automated · 3 partly automated · 12 human-only*

**Most of this list is now automated — run [`../scripts/track-audit.sh`](../scripts/track-audit.sh)
first.** It re-derives every ⚙️-marked item below from durable artifacts (the run record, the
governance bundle, the diff) in about a second, and blocks on failure. Only the ✋ items need a human.

```bash
bash .github/hooks/track-audit.sh          # report; exit 2 on any FAIL
bash .github/hooks/track-audit.sh --json   # same verdicts for tooling
```

Wire it as a blocking Stop gate with `TRACK_AUDIT=1` (opt-in — see
[hooks.md](../references/hooks.md)), and run it at the draft-PR boundary regardless.

**Why a ✋ half still exists.** A hook sees one event; the audit sees artifacts. Neither can read
*reasoning* — whether a brief truly carried the constraints, whether a reviewer engaged or rubber-
stamped, whether a RED test failed for the right reason rather than a typo. Those are checked by a
person reading the transcript, and pretending otherwise would manufacture exactly the false
confidence this pipeline exists to prevent.

**When:** after any change to a SKILL.md or mode reference, and spot-check on real runs.
**Inputs:** the session transcript, `runs/<RUN_ID>.json`, `runs/<RUN_ID>.governance.md`, the diff.

Legend: ⚙️ = checked by `track-audit.sh` (id in brackets) · ✋ = human only.

---

## A. Governance (the round-trip that ships credentials)

- [ ] ⚙️ **A1** `[G3]` — Governance discovery ran **before** the first subagent dispatch. Derived by
      comparing the governance stamp against the earliest `trace[]` entry.
- [ ] ✋ **A2** — `.specify/memory/constitution.md` was read, **or** its absence is explicitly stated
      in the bundle. A missing line is indistinguishable from a skipped check.
- [ ] ⚙️ **A3** `[G2, G4]` — Every `applyTo`-matching instruction file appears in the bundle for the
      actual diff surface; `security-and-owasp` whenever a trust-boundary path is touched.
- [ ] ⚙️ **A4** `[G1]` — `runs/<RUN_ID>.governance.md` exists and its sha still matches the record.
- [ ] ✋ **A5** — Maker briefs embed governance **content**, not filenames. Open an actual dispatch
      and look. *"Follow `go.instructions.md`"* is the failure this whole gate exists to prevent.
- [ ] ✋ **A6** — Frontend clusters carry the design artefacts (`.stitch/designs/…`,
      `design-system/…`) when they exist.

## B. Compaction resilience (the invariant that silently degrades)

- [ ] ⚙️ **B1** `[P1, P2]` — `phase` was stamped, and `phase_log[]` covers the canonical gate
      sequence for the recorded core.
- [ ] ✋ **B2** — If the session was compacted: the bundle was **re-read from disk** before the next
      dispatch. The one that decays invisibly — post-compaction briefs get thinner while the model
      reports full compliance. **The highest-value manual check on this list.**
- [ ] ✋ **B3** — After any resume, `track-reconcile.sh` ran and its `resume_action` was **acted on**,
      not merely printed.
- [ ] ✋ **B4** — Position was never rebuilt by reading the worktree ("let me look at what's there and
      figure out where I was"). Forbidden after a compaction exactly as after a crash.

## C. Maker/checker separation

- [ ] ⚙️ **C1** `[M1]` — At least two distinct `agent_id`s in `trace[]`. Note the audit can only
      prove separation was *possible*; Claude Code's `SubagentStop` omits ids entirely, and it says
      so rather than passing silently.
- [ ] ✋ **C2** — The controller never authored what it applied. In scaffold mode especially: bodies
      came back **from subagents**, not the controller's own reasoning. A converged tree the
      controller wrote itself is a violation even though it looks identical.
- [ ] ✋ **C3** — Review actually applied the governance rubric, rather than generic "looks good".

## D. Test discipline

- [ ] ⚙️✋ **D1** `[T1]` — *(story)* The audit proves a failing capture exists **before** the passing
      one, so the suite genuinely ran red. Whether it failed for the **right reason** — a real unmet
      expectation, not a typo or missing import — is still yours to read.
- [ ] ⚙️ **D2** `[T2]` — No frozen test weakened to green: the audit flags added `skip`/`only`
      markers and removed assertion lines in test files.
- [ ] ✋ **D3** — *(refactor)* Characterization tests passed **immediately** at baseline. One that
      failed is a wrong test, not a discovered bug.
- [ ] ✋ **D4** — *(refactor)* The suite was green after **every** transform step, not only at the end.
- [ ] ✋ **D5** — *(refactor)* The public contract diff is empty.
- [ ] ⚙️✋ **D6** `[G4]` — *(scaffold)* The audit fails a diff touching a trust boundary without
      security governance; whether each *task* carried a test obligation is a judgement call.

## E. Evidence honesty

- [ ] ⚙️ **E1** `[E1]` — Every kind's latest capture shares **one** fingerprint (the convergence
      gate), with no edit after it.
- [ ] ⚙️✋ **E2** `[E2]` — The audit warns on suspiciously short *passing* captures, since a
      truncated pass-looking response satisfies the gate trivially. Whether the output was actually
      **read** is yours.
- [ ] ✋ **E3** — No completion claimed before the creating command returned. "Draft PR opened"
      requires a printed PR URL.

## F. Terminal states

- [ ] ⚙️ **F1** `[F1]` — A run that could not finish wrote `status` + `blocker` — it did not open a
      PR "with a caveat".
- [ ] ✋ **F2** — Self-heal retries stayed within `TRACK_SELF_HEAL_ATTEMPTS` per **distinct** failure.
- [ ] ✋ **F3** — Infra failures (timeouts, image pulls) were retried at the orchestrator layer, not
      charged to the self-heal budget.

---

## Scoring

Any unchecked box in **A**, **B**, or **C** is a defect in the run, not a stylistic note — those are
the three that fail *silently* and produce plausible-looking output. **D**–**F** failures usually
surface later as a red CI or a reverted PR; **A**–**C** failures ship.

A clean `track-audit.sh` clears the ⚙️ items and nothing more. The ✋ items are where the residual
risk now lives — concentrated, small enough to actually check, and no longer hiding among two dozen
things a script could have told you.
