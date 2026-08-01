# Prompt-Level Invariant Checklist (manual audit)

`test-skill.sh` covers the **mechanical** half of this skill: 148 assertions over the hooks bundle
and the structural contracts in the skill bodies. It cannot cover the other half.

The skill says so itself: *"Leave judgement gates (TDD ordering, maker/checker split, review quality)
as prompt instructions — a hook can't tell which subagent reasoned about something."* That is an
honest statement of a hook's limits, but it leaves the highest-risk invariants **unmeasured** — and
unmeasured is where regressions live. This checklist makes them auditable against a real run's
transcript + run record, so the gap is a known, checkable one rather than a silent one.

**When to run it:** after any change to a SKILL.md or mode reference, and spot-check on real runs.
**Inputs:** the session transcript, `runs/<RUN_ID>.json`, `runs/<RUN_ID>.governance.md`, the diff.

---

## A. Governance (the round-trip that ships credentials)

- [ ] **A1** — Governance discovery ran **before** the first subagent dispatch, not after the first
      review. Check transcript ordering, not intent.
- [ ] **A2** — `.specify/memory/constitution.md` was read, **or** its absence is explicitly stated.
      A missing line is indistinguishable from a skipped check.
- [ ] **A3** — Every `applyTo`-matching instruction file was read for the actual diff surface —
      `code-review-generic` always; `security-and-owasp` on any trust boundary.
- [ ] **A4** — `runs/<RUN_ID>.governance.md` exists, and `governance_bundle.sha` in the run record
      matches the file on disk.
- [ ] **A5** — Maker briefs embed governance **content**, not filenames. Open an actual dispatch and
      look. *"Follow `go.instructions.md`"* is the failure this whole gate exists to prevent.
- [ ] **A6** — Frontend clusters carry the design artefacts (`.stitch/designs/…`, `design-system/…`)
      when they exist.

## B. Compaction resilience (the invariant that silently degrades)

- [ ] **B1** — `phase` was stamped at **every** gate boundary, not just the first. Compare
      `phase_log[]` against the mode's gate list.
- [ ] **B2** — If the session was compacted: the governance bundle was **re-read from disk** before
      the next dispatch. This is the one that decays invisibly — briefs after a compaction get
      thinner while the model reports full compliance.
- [ ] **B3** — After any resume, `track-reconcile.sh` ran and its `resume_action` was **acted on**,
      not merely printed.
- [ ] **B4** — Position was never rebuilt by reading the worktree ("let me look at what's there and
      figure out where I was"). That is forbidden after a compaction exactly as after a crash.

## C. Maker/checker separation

- [ ] **C1** — The reviewer subagent is **distinct** from the implementer. Check `trace[]` for two
      different `agent_id`s per increment, not one agent doing both.
- [ ] **C2** — The controller never authored what it applied. In scaffold mode especially: file
      bodies came back **from subagents**, not from the controller's own reasoning. A converged tree
      the controller wrote itself is a violation even though it looks identical.
- [ ] **C3** — Review actually applied the governance rubric, rather than generic "looks good".

## D. Test discipline

- [ ] **D1** — *(story)* The RED batch was **run** and failed for the **right reason** — a real unmet
      expectation, not a typo or missing import. "Red for the wrong reason" is a silent hole.
- [ ] **D2** — *(story)* No frozen test was weakened to green: no deleted assertion, loosened
      matcher, or `skip`. Diff the test files across the green phase.
- [ ] **D3** — *(refactor)* Characterization tests passed **immediately** at baseline. One that
      failed is a wrong test, not a discovered bug.
- [ ] **D4** — *(refactor)* The suite was green after **every** transform step, not only at the end.
- [ ] **D5** — *(refactor)* The public contract diff is empty.
- [ ] **D6** — *(scaffold)* The guard genuinely cleared the batch — no task in it carried a test
      obligation or trust boundary.

## E. Evidence honesty

- [ ] **E1** — Every required evidence kind was captured against **one** fingerprint (the convergence
      gate), with no edit after it.
- [ ] **E2** — The pasted output was **read**, not just present. A green gate is not proof: the hook
      checks for the absence of a failure marker in a possibly-truncated text response.
- [ ] **E3** — No completion was claimed before the creating command returned. "Draft PR opened"
      requires a printed PR URL.

## F. Terminal states

- [ ] **F1** — A run that could not finish wrote `status` + `blocker` + `next_step` — it did not open
      a PR "with a caveat".
- [ ] **F2** — Self-heal retries stayed within `TRACK_SELF_HEAL_ATTEMPTS` per **distinct** failure.
- [ ] **F3** — Infra failures (timeouts, image pulls) were retried at the orchestrator layer, not
      charged to the self-heal budget.

---

## Scoring

Any unchecked box in **A**, **B**, or **C** is a defect in the run, not a stylistic note — those are
the three that fail *silently* and produce plausible-looking output. **D**–**F** failures usually
surface later as a red CI or a reverted PR; **A**–**C** failures ship.
