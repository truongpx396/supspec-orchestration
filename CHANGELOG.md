# Changelog

All notable changes to this repository's skills are documented here. Versioning follows
[Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`, pre-1.0 (`0.x`) while the skill
contracts are still stabilizing — matching the convention used by
[SpecKit](https://github.com/github/spec-kit) and [Superpowers](https://github.com/obra/superpowers).

Each skill's `SKILL.md` frontmatter carries its own `version` field; this file tracks the
whole-repo release that ships them together.

## [0.10.0] - 2026-08-15

`sso-single-branch-development` 0.7.0 → 0.8.0. Six findings from one client scaffold run built on the
0.9.0 bundle: three failures the run hit head-on, a token gauge that was reading a quarter of the
spend while it happened, a context-discipline rule the skill never had, and one hole caught by
reviewing this release's own first draft before it shipped. Suite: 379 → **424** SBD tests, 205
parallel-tracks (unchanged, all passing).

Every fix was reproduced against a throwaway repo with the real installed bundle **from a linked
worktree** — the configuration these bugs need in order to appear at all — and the token findings were
replayed from the client record's own numbers, byte-for-byte. Two suspicions were measured and then
*not* acted on: `jq -s` over a 41MB transcript (0.27s, no latency problem) and a first-draft elision
guard that turned out to deny this skill's own documentation.

## Part 1 — three failures from the run itself

### The governance bundle's `Write` hard-failed, with nothing written

The bundle's home is `runs/`, which is gitignored — so it exists only where something created it: the
main checkout, where preflight minted the breadcrumb, and **never** a freshly added linked worktree.
The agent surface's `Write` tool does not reliably create missing parent directories, so the skill's
own mandatory step died on a missing dir and the repair was a hand-rolled `mkdir` the skill never
mentions. The second half is worse and quieter: re-deriving the path later in the run reliably
produces a bare `runs/<id>.governance.md`, which from a worktree resolves to that worktree's *private*
copy the main checkout cannot see — the audit then reports the bundle MISSING and the usual repair is
to keep both and `cp` between them until they diverge. Both were visible in the client's record, which
holds two pins with different shas and a `cp` between two directories.

- **New `track-note.sh govpath`** prints the one correct absolute path and `mkdir -p`s the anchored
  records dir before printing it. `references/governance.md` Step 2 and the SKILL body now route
  through it instead of asking the model to compose the path, and the `governance` subcommand's
  out-of-records-dir warning names it as the fix.

### A documented governance probe was refused by the harness, not answered

`references/governance.md` shipped its `applyTo` enumeration as a `for` loop over
`.github/instructions/`. Under this skill's own default isolation that is unrunnable: a
worktree-isolated session's Bash guard refuses any command it cannot statically prove stays inside the
worktree, and answered that one with *"too complex to verify that it stays inside the worktree; break
it into plain, separate commands."* A refused probe does not fail loudly — it pressures the run into
working from a remembered list of instruction files, which is the exact failure the enumeration exists
to prevent, and which `track-audit.sh`'s `G2` then fails the run for.

- The step is now two **plain single commands** (`ls` + `grep -H '^applyTo:'`), with the rule stated
  once for anything improvised alongside them, and a checklist line saying that a *refused* probe did
  not run and must be re-issued rather than replaced with memory.

### Scaffold mode skipped its fan-out entirely — and nothing could see it

The client's run never invoked the dispatch tool at GENERATE. It ran `go mod init`, `uv init`,
`npm create vite` itself, made the batch's live authorial decisions (which ruff rules, which
LLM-as-judge dependencies) directly, and wrote `(real, controller-run)` into its own governance bundle
as though that were sanctioned terminology. Its TODO list said *"fan out 5 disjoint-file cluster
subagents"* the whole time. This is the anti-pattern the mode reference already named in bold — and
naming it was all the enforcement there was, because a converged tree the controller authored looks
byte-identical to one it applied.

Three root causes, each addressed where it actually sat:

- **A genuine ambiguity the skill never resolved.** A read-only subagent returns text, but `go.sum`,
  `uv.lock` and `package-lock.json` carry hashes no model can author, and `tasks.md` says to commit
  them "as generated, never hand-edited". With no rule to point at, the controller generalized
  "lockfiles must come from the real tool" into "so I'll do all of it myself". `scaffold-mode.md` now
  draws the line explicitly — **judgement is delegated, tool-determined output is not** — with a
  table, and two named Bash-only controller steps: **BASELINE** (a pinned tree-generator, run inside
  RESOLVE, whose output is *input* to the fan-out) and **MATERIALIZE** (the resolvers, run after
  APPLY, over maker-authored manifests). "Only a tool can produce it" is stated as never a reason to
  also *decide* it.
- **The RESOLVE table read as an instruction to execute.** Its column header was `Generator (pinned)`
  with `npm create vite@7.1.2` in the cell; the surrounding text says to *probe*. Renamed and made
  explicit that RESOLVE decides versions and does not author files.
- **The mode switch at the GENERATE boundary is not automatic.** The step immediately before it — the
  governance gate — is explicitly non-delegable, and the controller carried "I do this myself"
  straight through. GENERATE now opens with a reset callout and a stated precondition (*N briefs
  dispatched, N sets of bodies returned*), and APPLY gains a rule against narrating a deviation into
  the bundle as if it were policy.

And it is now mechanical at both ends:

- **`track-guard.sh` denies it live.** While a run's record says `phase.mode=="scaffold"` and `trace[]`
  holds zero subagent dispatches, a `Write`/`Edit` to a **deliverable** path is denied, with a message
  naming the fan-out. `RUNS_DIR` writes stay allowed (the bundle is controller work product by design)
  and **Bash is untouched**, so pinned generators and resolvers work normally — the guard draws exactly
  the line the reference draws. It **fails open** on every unknown: no `RUN_ID`, no run record, a
  non-scaffold mode, or an unwired `track-trace.sh` (with no trace hook a compliant run has an empty
  `trace[]` too). `TRACK_SCAFFOLD_FANOUT_GUARD=0` disables it.
- **`track-audit.sh` gains `C2`**, promoted out of the MANUAL list: a scaffold run that produced a
  deliverable diff with no generating dispatch is a **FAIL**. The half that genuinely cannot be
  mechanized — whether *each* applied body came from its own maker — stays manual as `C2b`, reworded
  so the split is explicit rather than implied.

### RESOLVE now says which half of itself is delegable

Raised by the same review: RESOLVE probes the environment and, when a pin is missing, installs a
toolchain (`nvm install 22`, `uv python install`, a `GOTOOLCHAIN=auto` fetch). All of that output
landed in the main session — on the client run, alongside governance, the largest avoidable context
sink in a 1.68M-token estimate. `scaffold-mode.md` now splits the step in the pipeline diagram and the
gate map, because the two halves have opposite rules and the boundary between them is the same
momentum trap as the GENERATE one a step later:

- **PROBE delegates.** Read-only, no judgement, bulk-noise-in / one-table-out — one subagent per
  surface via `dispatching-parallel-agents`. Probes return the **command and its verbatim output**,
  never a summarized version number, because a pin built on an assertion is the deviation RESOLVE
  exists to prevent.
- **PIN does not.** Which version wins when `plan.md` pins a Python patch that does not exist, what
  each pin costs, the `## Conflicts` lines that travel into every brief — non-delegable for the same
  reason the governance gate is.
- **A probe never installs.** Installs mutate the developer's machine outside the repo and belong
  *after* the human confirm, run by the controller. A probe that finds a version missing reports it
  as a required action and stops. Two mechanical reasons, not just etiquette: shell activation does
  not cross a process boundary (`nvm use 22` inside a subagent is inert for the caller — the binary
  persists, the activation does not, so *whether later commands need the prefix* is itself a probe
  finding to report), and an install taken before the confirm has front-run the gate authorizing it.

**And the fan-out gate was tightened so this does not open a hole in it.** A probe dispatch is a real
dispatch, so as first written both the guard and `C2` would have been satisfied by one — clearing the
run out of the gate exactly one dispatch before GENERATE, the same skip one step later. Both now count
only **generating** dispatches, using the `declared_na` flag `track-brief.sh` already records for a
brief that declares `GOVERNANCE: n/a`, and fall back to `trace[]` when `briefs[]` is empty.

## Part 2 — found while auditing that run's own numbers

### The token ceiling was blind to 96% of the tokens

A client run reported `input 418 · output 188,142 · cache_write 1,492,020 · cache_read 38,860,060`
with `token_estimate: 1,680,580`. The arithmetic was right — that is exactly
`input + cache_write + output`, the documented formula. The formula was wrong. `cache_read` was
excluded on the stated reasoning that *"re-reading an already-cached context is the cheap part, and
counting it makes the figure grow with run length rather than with work actually done"* — which is
backwards for a runaway-run detector, since **growing with run length is the signal it exists to
catch**, and cheap-per-token is not cheap at 38.9M of them. Weighted by the published Claude price
ratios the real spend was ~**6,692,159** input-token-equivalents: `cache_read` alone was 95.9% of
tokens processed and ~58% of cost. The gauge read 25% of the bill and ignored the unbounded part, so a
ceiling tuned on it cannot fire until a long run is several times over budget.

- **`token_estimate` is now cost-weighted**: `input×1 + cache_write×1.25 + cache_read×0.1 + output×5`,
  in input-token-equivalents. Weights are env-tunable (`TRACK_TOKEN_W_CACHE_READ` / `_CACHE_WRITE` /
  `_OUTPUT`) and read as strings coerced in `jq`, so a typo'd override falls back to its default
  rather than aborting the Stop hook — an aborted hook writes no estimate, which silently disables the
  ceiling. Setting them to `0`/`1`/`1` restores the old flat formula exactly, for a repo mid-project
  with a ceiling calibrated against it.
- **Seeded ceiling raised `1500000` → `6000000`** to match the ~4× change in what the number means.
  Existing installs keep their own value; the template comment says to re-tune.
- **`token_ceiling` is now recorded** beside the estimate. The client record showed a high estimate
  and no `budget-exceeded` status, and nothing in the artifact could say whether the run was under
  budget or the ceiling had been raised — exactly the question the record exists to answer.
- **`token_estimate_chars` is `null`, not `0`, on the usage path.** A literal `0` is the signature of
  the transcript parser matching nothing — a real failure mode this hook warns about, which silently
  disables the ceiling — and the record must not conflate the two.
- Not changed after measuring: `jq -s` slurping the transcript was suspected as a Stop-hook latency
  risk and benchmarked at **0.27s on a 41MB transcript**. Left alone.

### Context discipline is now a standing rule, not three asides

Raised by review of the same run: nothing in the skill told an agent how to use tools economically.
What existed was *"budget the read"* (governance gate only), *"keep build noise out of the context"*
(one step of scaffold mode), and the token ceiling — which fires at `Stop`, i.e. after the tokens are
spent. **Story and refactor mode, the two longest-running cores, said nothing at all**, despite being
where per-increment test output re-enters context N times.

New [`references/context-budget.md`](.github/skills/sso-single-branch-development/references/context-budget.md),
reachable from every core and the governance gate:

- **Why it is a correctness control, not thrift.** Context pressure is what triggers the compaction
  that drops the governance bundle and starts the silent degradation `I4` exists to catch. And a token
  held in context is paid repeatedly, not once — the same client run read **38.9M cached tokens
  against 1.5M written**, i.e. every token placed in that context was re-read about **26 times**. That
  multiplier is what turns "paste the whole file" into a number.
- **A per-tool table**: `Grep` before `Read`, `offset`/`limit` over whole files, `files_with_matches`
  before content, redirect installs/builds and read only the verdict, ask narrow git questions.
- **The `RETURN:` contract.** Delegation is the skill's biggest context lever and the saving is in the
  *return*, not the dispatch — a maker that wraps its file bodies in 2,000 lines of narration costs
  more than writing them inline. Every brief now states what comes back, in one line. `G6` checks what
  went **out** in a brief; nothing checks what comes **back**, and that is now said explicitly rather
  than left as an assumption.
- **The exception that is never traded**: full output stays for anything that *is* evidence. `npm
  install` is setup and gets redirected; `npm run build` is the artifact and gets kept. Truncating to
  save tokens is how `E2`'s 40-char floor gets satisfied by a string that proves nothing.

### …and the hole the first draft of that left

Caught on review of the change itself, before it shipped. The first `RETURN:` contract read *"the file
bodies only. No commentary, no rationale, no summary of what you did."* Two defects, and the second is
a correctness bug rather than a style one:

- **"No commentary" silences a blocker.** A maker that finds a pin that does not exist, or a
  constraint it cannot satisfy, had just been told not to mention it. The contract now opens with a
  bounded `NOTES` slot (max 5 bullets, `"NOTES: none"` when there are none) so brevity cannot suppress
  the one thing the controller most needs to hear.
- **Nothing forbade eliding the bodies.** "Bodies only" plus a brevity framing is the single most
  reliable way to produce `// ... rest of file unchanged ...` — and the controller **applies a returned
  body verbatim**, so that writes a truncated file which still parses, still diffs cleanly, and reads
  as complete to a reviewer. A token-saving instruction had been placed directly upstream of an unread
  verbatim write. The contract now states that it bounds **packaging, never content**: bodies come back
  COMPLETE and VERBATIM, and the fix for a long file is a narrower cluster, never a shorter body.

Enforced, not just written down — `track-guard.sh` denies a `Write`/`Edit` whose new content carries an
elision marker, since the controller cannot spot one by eye in 400 lines it did not author.
**Deliberately narrow, five conditions**: the line must be short (≤72 chars), carry no quote or
backtick, open as a comment or bracketed/leading-dots placeholder, contain an ellipsis, *and* name the
elision in words. Short-and-unquoted is what separates a marker from a line *about* markers — an
earlier form of the check denied writing this skill's own `context-budget.md` and `track-guard.sh`,
both of which quote elisions in prose, and that regression is now pinned by a test that writes those
files through the guard. Python's `Ellipsis`, a YAML document end, `{...x}`, `func f(n ...int)`, a
markdown bullet mentioning elision, and `// wait for it... then retry` all pass. `TRACK_ALLOW_ELISION=1`
opts out. 16 assertions cover both directions.

## [0.9.0] - 2026-08-14

`sso-single-branch-development` 0.6.0 → 0.7.0. Six bugs found and fixed in a single client PR that
had already merged the 0.8.0 hooks bundle — three in `track-guard.sh` denying legitimate work, two
found by auditing the run's own artifacts, and one in the CI gate that let a hand-fabricated PR body
through as genuine. Every fix below was reproduced from the client's real transcript, then verified
against a throwaway repo or (for the CI gate) by extracting and executing the workflow's actual `run:`
scripts — never reasoned about from the diff alone. Suite: 355 → **379** SBD tests, 205
parallel-tracks tests (unchanged, all passing).

### Three guard false-positives that left the worker no in-bounds move (`sso-single-branch-development`)

Follow-on from the same client scaffold run. All three are `track-guard.sh` denying something
legitimate, and all three end the same way — the model reaches for a Bash heredoc to route around the
guard, which the *harness's* own worktree-isolation check then refuses as "too complex to verify".
Replayed against throwaway repos; suite 355 → **366** SBD assertions.

- **First publish was denied whenever the hook fired from the main checkout.** `is_first_publish()`
  read `HEAD` at the hook's CWD to decide which branch a push would publish. Under the skill's own
  default isolation the work is in a sibling worktree while hooks fire from the main checkout, where
  `HEAD` is `main` — so `git push -u origin feat/x` was classified as an attempt to publish the *base*
  branch and denied. That made `gh pr create` unreachable and reproduced, exactly, the pressure the
  carve-out was added to remove: the worker self-granted `TRACK_ALLOW_FF_PUSH`. The **refspec** is now
  authoritative (`git push origin feat/x` names its own branch); `HEAD` is consulted only when no
  refspec does. Redirects (`feat/x:main`), the base branch, branches with no local ref, bulk modes and
  `--force` stay denied, and a second push of a published branch is still an update needing the opt-in.
- **The destructive-infra guard matched heredoc *data* as if it were code.** `*truncate*` matched
  anywhere in the command, so writing a PR body containing the word "truncated" was denied as an
  "irreversible schema op" — uncompliable, since the only way to satisfy it was to not write the PR
  body. Heredoc bodies are now stripped before scanning, and `truncate` needs the SQL spelling
  (`TRUNCATE TABLE`) or a SQL client on the same line, so coreutils `truncate -s 0` passes. Code
  *after* a heredoc is still code: `cat <<EOF … EOF; psql -c 'drop table t'` still denies.
- **Writes outside every worktree got a denial that named no alternative.** Scope is repo-relative, so
  a path in a scratch/temp dir can never match a prefix — but the message said "editing it would
  become a merge conflict at integration", which is meaningless for `/tmp`. An agent staging
  generated output in a scratch dir therefore had *every* `Write` denied with no stated remedy. The
  denial now says the work belongs inside the worktree under an owned prefix, notes that anything
  written outside the repo reaches neither the diff nor the evidence gate nor the PR, and points at
  absolute-path prefixes for the rare genuine case.
- **Test-harness integrity:** `mk_term()` built its JSON with `printf`, so any multi-line fixture
  emitted raw control characters, the hook died in `jq -r`, and the assertion *passed* for the wrong
  reason. It now builds with `jq`.

### Two more found by auditing the same run's artifacts (`sso-single-branch-development`)

- **`runs/` was governed as if it were a deliverable.** The skill requires the model to write the
  governance bundle, the PR body and the run record into `RUNS_DIR` — gitignored bookkeeping that
  never enters the reviewed diff — but the guard applied `TRACK_ALLOWED_PREFIXES` to it like any
  other path. With `runs/` absent from the approved scope the model composed the bundle into
  `backend-go/.gov.tmp2.md`, an in-scope **deliverable** path, and shell-`cp`'d it into place: the
  guard pushed a bookkeeping file into the very tree it exists to protect. `RUNS_DIR` is now always
  writable, resolved as an absolute path against the repo root (and the linked worktree), so a
  `runs/` directory sitting under some other subtree cannot name itself into scope.
- **A green that verified nothing was recorded as proof.** `go build ./...` on a module with no `.go`
  files prints `matched no packages` and exits 0; graded on failure signals alone that is
  indistinguishable from a full compile, and it is exactly how the observed run satisfied its
  `go-build` evidence floor while building zero packages — the PR then reported 3/3 required kinds
  passing. Captures matching a vacuity pattern (`TRACK_VACUOUS_PATTERN`, overridable) are now flagged
  `vacuous: true` with `verdict_by: vacuous-pass:nothing-verified`. Deliberately **not** downgraded to
  a failure: during a scaffold an empty build is the honest state of the world, and failing it invites
  the "edit the deliverable to make the gate green" trap. Failure still outranks vacuity.

### The CI gate accepted a hand-fabricated "Auto block" (`agent-pr-audit.yml`)

Found while auditing the same client run's own open PR against a fresh render of its own
`runs/*.json`. The PR's "auto block" was never produced by `track-report.sh` — the real script's
literal opening comment is
`<!-- BEGIN track-report auto block — machine-rendered, do not hand-edit -->`; the PR's version
dropped everything after `block`. The whole **Run stats**, **Subagent lifecycle trace**, and
**Compliance warnings** sections were absent, the full per-file table collapsed to one prose
sentence, and the discipline-audit table (`### Discipline audit — mechanical invariants…`, real
summary `**16 passed · 2 warning(s) · 0 failure(s)**`) was replaced by a paraphrase
(`#### Discipline audit: 16 passed, 2 warnings, 0 failures`) — same numbers, invented shape. Verified
directly: re-running `track-report.sh` against that run's own still-intact record reproduces the real
block byte-for-byte different from what shipped.

It passed CI anyway. `agent-pr-audit.yml`'s presence check only grepped for the END marker (public in
the docs, easy to copy correctly) — never the BEGIN one. Its audit-format check had exactly one
fallback for "no summary line found": a soft `::warning::` written for repos whose install predates
`track-audit.sh`. A paraphrased summary landed in that same branch, indistinguishable from a
legitimately old install, and the gate exited 0.

Two independent checks now close this, verified behaviorally (the real `run:` scripts extracted from
the YAML and executed against the actual fabricated body, a genuine render, and a true legacy body
with no audit section at all — 375 → 379 SBD assertions, none of them log-scraped):
- The presence check now requires the full BEGIN marker, not just the END one.
- The audit-format check now distinguishes "no audit mention at all" (unchanged: soft warning, the
  legitimate legacy-install case) from "an audit-shaped section that isn't the literal heading +
  summary `track-report.sh` emits atomically from one `printf`" (new: hard failure) — including the
  narrower case of the real heading present with the summary line stripped out from under it.

## [0.8.0] - 2026-08-14

All four sections below ship in `sso-single-branch-development` 0.5.0 → 0.6.0 (the concurrency,
scope-propagation, and cost/legibility fixes) and `sso-executing-parallel-tracks` 0.2.0 → 0.2.1 (the
per-track config docs correction). Found and fixed across one real client scaffold run, replayed and
verified in throwaway repos rather than reasoned about from the diff. Suite: 284 → **355** SBD tests,
205 parallel-tracks tests (unchanged, all passing).

### Four silent-failure bugs in the hooks bundle, all found in one client scaffold run (`sso-single-branch-development`)

A real run in a client repo produced a PR whose own audit reported an empty evidence pack, missing
phase stamps, and a governance bundle written twice — while the model reported the work as done.
None of it was model misbehavior: four mechanical defects switched the bundle off without saying so,
and every workaround visible in that run was the only in-bounds move left. Each fix below is bracketed
by regression tests (suite: 284 → 335 assertions).

- **The confirmed scope never reached the guard.** `--persist` stamped `TRACK_ALLOWED_PREFIXES` into
  the breadcrumb — a *record* — and nothing else, while `track-guard.sh` reads the env files. Hooks
  are spawned by the agent surface, so the `export` the docs told the model to make could never
  arrive. Net effect: a human approved a writable scope at the start gate and the guard denied every
  path in it for the whole run, with the only fix (`.github/hooks/`) itself outside the empty scope —
  no compliant path left. `--persist` now writes the confirmed scope, frozen paths, toolchain and
  evidence floor into the managed block alongside `RUN_ID`, read back out of the breadcrumb so a
  resume recovers them without re-typing. An exported value still outranks the file, and a worker
  carrying another run's id does not inherit this run's scope.
- **Worktree isolation switched the recorders off.** The managed block asked "is `HEAD` *here* the
  run's branch?", but Step 3 puts the work in a *sibling* worktree while the session — and every
  hook's CWD — stays in the main checkout on the base branch. `RUN_ID` was therefore de-adopted for
  every hook firing from there, and each recorder no-ops silently without it. The documented default
  form of isolation disabled recording *and* the Stop-time evidence gate. Adoption now asks whether
  the branch is checked out in **some worktree of this repo**. `track-audit.sh` had the same blind
  spot with sharper teeth — `I1`/`I2` read HEAD in the audit's own CWD and so FAILED a correctly
  isolated run (blocking, under `TRACK_AUDIT=1`) for doing the right thing; both now resolve the
  run's branch to the worktree holding it, and still FAIL a run that genuinely never isolated.
- **A ceiling trip disarmed the whole bundle for the rest of the session.** Any terminal `status`
  retired the block, but `budget-exceeded`/`no-progress` are written *mid-session* by
  `track-tokens.sh`/`track-meter.sh` — and everything that matters after one is the report-out:
  the status stamp, the evidence capture, the handoff. Adoption now survives them (`success`/
  `blocked`, the deliberate states, still retire), so a tripped run stays recorded and gated.
  `track-meter.sh`'s halt becomes the counterweight: it fires **once**, at the crossing, matching
  `track-tokens.sh`'s existing contract, because a cumulative count makes a repeating halt one that
  never ends.
- **The governance bundle split in two.** `RUNS_DIR` is anchored to the main checkout but the pinned
  bundle path was CWD-relative, so a bundle written from a worktree landed in that worktree's own
  gitignored `runs/` while the record pointing at it lived in the main checkout's — audit `G1` then
  reported it MISSING, and the natural repair is to write it twice and let the copies drift.
  `track-note.sh governance` now resolves and records an **absolute** path, retries a relative one
  against the anchored `RUNS_DIR`, and warns when the bundle sits outside the run's records dir.
  `track-audit.sh`/`track-reconcile.sh` retry legacy relative pins the same way; `track-compact.sh`
  also matches a re-read by basename, so a relatively-typed `cat` still counts for `I4`.
- **`.github/hooks/track-env.sh` is now actually gitignored** by `install-hooks.sh`. Every doc
  called it the gitignored local layer; nothing ever ignored it. It holds `RUN_ID` and (as of this
  release) the confirmed scope, so committing it ships one checkout's run state to everyone — and
  while untracked-and-unignored its *content* is hashed into the evidence fingerprint
  (`git ls-files --others --exclude-standard` → `git hash-object`), so under the branch-in-place
  fallback a `--persist` rewrite silently staled every capture taken before it.
- **`track-note.sh` no longer no-ops in silence.** It is a CLI the skill calls deliberately, and its
  two mandatory subcommands are the resume anchors — so an unset `RUN_ID` now says so on stderr
  (still exit 0) instead of letting the caller believe a phase stamp landed.
- **Docs corrected where they taught the broken model:** `hooks.md`'s "re-root the workspace into the
  worktree" advice (stale — everything single-homes on the main checkout via `git-common-dir`), its
  "export the correct ones for the new task" triage row, `SKILL.md` Step 1 and the governance gate,
  `references/governance.md`'s persist snippet, and `README`'s `RUN_ID` row.

### Per-track ownership is now mechanically enforced in a parallel wave (`sso-single-branch-development` + `sso-executing-parallel-tracks`)

The fix above single-homed every hook on the main checkout, which is right for a solo run but
collapsed a layer a **wave** needs. `track-env.sh` was documented from the start as the
"per-worktree LOCAL override" — the layer that gives N concurrent tracks N different writable
scopes — and the bootstrap read the main checkout's copy unconditionally, so a worktree-local file
was never read. That made the override dead.

The deeper cause: Step 3 fans out with `dispatching-parallel-agents`, i.e. **in-session subagents**,
so all N workers share one process environment and one CWD. The orchestrator's documented
`export TRACK_ALLOWED_PREFIXES=... # inside each worker's launch` could not reach a hook under its
own prescribed launch mechanism, and `track-precheck.sh` was asserting a disjoint ownership
partition that the guard never actually enforced per worker — cross-track ownership was
prompt-enforced.

- **`track-guard.sh` now resolves scope per write target.** For each path it already computes the
  worktree that path belongs to; it now prefers a `track-env.sh` found in *that* worktree, reading it
  in a subshell with the scope vars unset (the file's `${VAR:-}` idioms are no-ops against an
  already-set value, and an in-loop `source` would leak one path's override onto the next). Non-empty
  `TRACK_ALLOWED_PREFIXES`/`TRACK_FROZEN_PATHS`/`TRACK_IMMUTABLE_PREFIXES` win for that path; a
  worktree declaring nothing inherits the session's, so solo runs are unaffected. The deny message
  names which worktree's file decided, so a wave failure is attributable. The tool call's target path
  is the *only* signal that distinguishes in-session workers, which is why the guard can do this and
  the recorders cannot.
- **Orchestrator docs corrected to match what the mechanism can deliver.** Per-track config travels
  in each track's worktree file (written after `git worktree add`, before fan-out), not in the
  environment. A new **Known limit** states plainly that per-track `RUN_ID` does *not* reach the
  recorders under in-session fan-out — a wave produces one run record, not N — and that launching
  each worker as its own process is what would restore it. `RUN_ID` stays documented as per-track by
  design, since `track-wave-preflight.sh` still derives `<wave-id>_<track-id>` and it works when
  workers are separate processes.

### Two features in two editor windows no longer corrupt each other (`sso-single-branch-development`)

The everyday workflow — start a feature, leave it running, open a second VS Code window on the same
repo, start another — silently cross-wired both runs. The managed block was a single slot, so the
second `--persist` overwrote the first. Reproduced end to end: after starting run B, run A's own
worktree resolved `RUN_ID=…_feat-b` and `SCOPE=src/b/`, so A's tool calls incremented B's record,
A's evidence landed in B's pack, and A's guard **denied A's own approved files** while permitting
B's. Nothing failed loudly; both runs simply became each other.

- **The block is now a registry, not a slot**: one row per live run (`<run-id>|<branch>`), resolved
  at source time to **the row whose branch is checked out where the hook is running**. That is the
  only signal that separates two sessions sharing one process-independent config file.
- **The single-run fallback is narrowed to the main checkout.** "No branch matched, exactly one run
  on record" still adopts — that is the ordinary solo shape (session in the main checkout, work in a
  sibling worktree). But inside a *linked worktree* the branch is exact, so a HEAD matching no row
  now means no run owns this session. Caught by the tests: without this, once run B completed, B's
  still-existing worktree adopted the lone surviving row and recorded the finished feature's tree
  into run A.
- **Ambiguity is refused, not guessed.** Two live runs plus a CWD on neither branch ⇒ adopt nothing.
  A wrong guess does not fail; it mixes two runs' records and scopes.
- **`--persist` warns once, when the ambiguity is created**, naming the fix (open each session on its
  own worktree) — the one moment a human can act on it, rather than on every later tool call.
- **`--complete` drops only the finishing run's row**, so a sibling run keeps recording. Dead rows
  are pruned on every write. Legacy single-slot blocks are stripped on sight.
- **`runs/` stays shared and is not moved into worktrees**: records are keyed by `RUN_ID`, so
  concurrent runs never collide there, and one directory keeps every run visible to
  `track-reconcile.sh` / `track-report.sh`.

### Cost and legibility: pin versions up front, keep build noise out of context, say what each subagent was for

Three changes aimed at the same run's other complaints — 1.44M tokens, eleven post-hoc deviations,
and a PR body whose subagent trace said nothing.

- **New RESOLVE step in scaffold mode** (`references/scaffold-mode.md`), between the mode guard and
  GENERATE: probe and **pin** every version the batch will materialize, confirm the table with the
  human, append it to the governance bundle under `## Resolved toolchain`, re-pin. No new machinery —
  it then travels into every maker brief, `G1` re-hashes it, and a compacted session re-reads it.
  The three deviation classes are named and routed: task-vs-governance conflicts resolve at the
  governance gate (new `## Conflicts` bundle section, so the decision is made once instead of per
  maker), task-vs-reality conflicts resolve by probing the installed tool (`--version`,
  `config verify`, `npm view`) because no document can answer them, and registry drift resolves by
  pinning the generator — `npm create vite@latest` is a build artifact too, and the bundle already
  bans `:latest` for those.
- **"Never edit the deliverable to make the gate green"** (convergence gate). A scaffold's empty
  directories legitimately fail `go vet ./...`; the fix is to verify what exists
  (`golangci-lint config verify`, `docker compose config`, `npm run build`), record the gap as
  `n/a — no sources yet` evidence, and only then — if a guard genuinely belongs in the product —
  write it to skip *loudly* or fail *loudly*, never to return 0 in silence, and report it as a
  deviation.
- **Capture the verdict, not the log.** `npm install`/`uv sync`/`docker compose up` emit thousands
  of lines that prove nothing and re-enter context every turn. Redirect and tail; keep full output
  for the commands that are the evidence. A real `tail -50` clears `E2`'s 40-character floor, so
  this is a token decision and never an evidence one.
- **`TRACK_MAX_TOKEN_ESTIMATE` default raised to 1,500,000** (was 200,000 seeded / 800,000 in the
  template — the observed run measured 1,442,753). The old value tripped on essentially every
  scaffold run.
- **The PR body now says what each subagent was dispatched to do.** `track-trace.sh`'s `reason`
  comes from `SubagentStart`'s `agent_description`, which some surfaces leave empty — leaving N
  identical `SubagentStart general-purpose (a3c8254…)` rows. `track-brief.sh` sees the dispatch
  tool's own `description` and `subagent_type` at `PreToolUse`, so it records them, and
  `track-report.sh` renders a **Subagent dispatches** list showing each agent's purpose beside how
  much of the governance bundle its brief actually carried. When neither source is available the
  report says so, naming the wiring gap, rather than printing a bare trace.

**Not fixed here, tracked separately:** `track-guard.sh` scopes `Write`/`Edit` but not Bash, so a
heredoc or `cp` bypasses deny-by-default entirely; `install-hooks.sh` seeds an empty evidence
catalog on exactly the repos scaffold mode targets (nothing to detect before the scaffold exists),
with preflight's consistency check skipping silently when the catalog is empty; and per-track
recording in a wave needs process-per-worker fan-out, a change to how waves launch.

## [0.7.0] - 2026-08-11

### Governance gate now discovers task-scoped feature context, not just standing rules (`sso-single-branch-development` 0.4.1 → 0.5.0)

The governance gate already guaranteed that the constitution, matched instructions, and security
rules reached every maker and reviewer brief as content — but a SpecKit `spec.md`/`plan.md`/
`research.md`/`data-model.md`/`contracts/`, when the repo has one, was never part of that guarantee.
A maker briefed with only a task ID and a one-line title can produce code that compiles and passes
review while solving the wrong requirement, and nothing in the pipeline caught it.

- **New discovery item 6** in `references/governance.md`: when a SpecKit `specs/<slug>/` layout
  exists, the task-relevant slice of `spec.md`/`plan.md`/`research.md`/`data-model.md`/`contracts/`
  is discovered, distilled, and persisted into the same `runs/<RUN_ID>.governance.md` bundle
  governance already uses. **Scoped to this run's task IDs / user-story tags — never the whole
  feature** — a `spec.md` spanning five user stories only contributes the one bearing on the current
  task; absent SpecKit is a valid no-op, same as an absent constitution.
- **Reuses the existing brief-embedding and audit machinery for free — no new hooks.** The bundle is
  still pinned via `track-note.sh governance`, still pushed as content (never a filename) into every
  maker/reviewer brief across main-session and dispatched subagents alike, and still re-anchored
  after a compaction. `track-brief.sh` and audit check `G6` already scan every bullet line in the
  bundle regardless of section, so a brief that drops the feature-context slice fails exactly like
  one that drops a governance constraint.
- **New checklist item `A6b`** (`tests/prompt-level-checklist.md`, surfaced in `track-audit.sh`'s
  printed NOT-CHECKED-HERE list) for the one thing no hook can verify: whether the *right* slice was
  pulled for the task, not just that some content made the hop into the brief. The checklist's
  human-only tally moves from 12 to 13; README's own account of it updated to match.
- `SKILL.md`, `governance.md`, and README's governance callout document the new step end to end.
  `SKILL.md` grew but stays within the repo's 500-line hard maximum (499 lines).

## [0.6.1] - 2026-08-09

### README/CHANGELOG drift after 0.6.0

The 0.6.0 release added `track-brief.sh`, `G5`/`G6`, and narrowed the audit's MANUAL list, but the
README's own account of itself wasn't updated to match, and the test count it quoted predated v0.4.1's
run-state fixes. No skill code changed — this corrects the docs to what v0.6.0 already shipped.

- **Test count corrected**: README claimed 251 SBD tests; the suite is 310 (verified by running
  `tests/test-skill.sh`). The coverage summary now names the v0.4.1/v0.6.0 areas it omitted:
  `RUN_ID` self-retirement, the bricked-checkout recovery path, git/gh-scoped `--force` matching,
  single-line `cmd` extraction from a multi-line shell block, brief-hop counting, and `G4`/`G5`/`G6`
  exercised from purpose-built fixture repos.
- **MANUAL checklist list was pre-0.6.0**: README still listed `B2` as un-mechanizable and described
  `A5` in its pre-narrowing form. Now lists the actual six (`A5, C2, C3, D1, D3, E3`) and states why
  `B2` left the list — `I4` + `G6` now decide it from hook-observed artifacts.
  `tests/prompt-level-checklist.md`'s own header tally (14 automated / 3 partly) also didn't match its
  markers (13 / 4); fixed.
- **New governance env vars from 0.6.0 were undocumented**: `TRACK_BRIEF_DENY`, `TRACK_BRIEF_MIN_LINES`,
  `TRACK_BRIEF_SIG_LEN`, `TRACK_GOV_MIN_BULLETS`, and `TRACK_AUDIT` now have their own table in the
  Configure section instead of being buried in a hooks-table cell.
- **v0.4.1's `RUN_ID` self-retirement** (the fix for a finished run bricking every later session in a
  checkout) is now stated where a reader would look for it — the hooks table and the `RUN_ID` env row
  — instead of only in the changelog.
- **`TRACK_EVIDENCE_SKIP_GLOBS`** (added in v0.4.1) now has its rationale in the Evidence section
  itself, not just a table row.
- **`CHANGELOG.md` is now linked** from Key files and from the installer's version-selection
  paragraph; its own tag links were missing entries for 0.4.0, 0.4.1, 0.5.0, and 0.6.0.

## [0.6.0] - 2026-08-08

### Instructions bundle: de-project-ified, review rubric scoped, agentic security added

The `.github/instructions/*` files ship as reusable governance to client repos via `install.sh`, but
five of them (`backing-services`, `devops-cicd`, `python`, `reactjs`, `state-management`) named a
specific internal project (`AISAT-STUDIO`) and asserted a specific stack (Vite SPA, UV-only Python) —
wrong for any other repo installing this bundle. Project-specific framing is stripped while the worked
examples stay.

- **`code-review-generic.instructions.md` is now review-step-only.** It carried no `applyTo` yet
  `governance.md`/`SKILL.md` treated it as always-in-scope — duplicating the language files (~400
  lines/brief) and conflicting with `security-and-owasp` on the one surface with no stated precedence.
  It's now loaded by `requesting-code-review` instead of being injected during authoring; `governance.md`
  and `SKILL.md` were updated to match.
- **11 detection regexes in `security-and-owasp` were unverified against their own BAD/GOOD
  examples** — several never matched what they claimed to catch (`I1`, `S3`), one had a
  negative-lookahead-after-`.*` that's trivially satisfiable (`AU8`, `FE3`), one matched any line
  mentioning `cors` (`H8`). Rewrote and verified all 11 with a 48-assertion PCRE harness.
- **`governance.md`'s instruction-file enumeration was a hardcoded list that had already drifted**
  (missing `agent-skills.instructions.md`) — replaced with "list the directory, match `applyTo` globs
  at run time," matching how `track-audit.sh`'s `G2` check actually works.
- **New: `ai-agent-security.instructions.md`.** This repo's own skills are an agentic system (tool
  dispatch, subagent delegation, evidence hooks), and the existing security file's `AI1`-`AI3` cover
  single-turn LLM apps only — no coverage for tool scoping, MCP/third-party trust, agent identity,
  memory/RAG poisoning, inter-agent auth, approval gates, or token/cost ceilings. Structured around
  OWASP ASI01-ASI10 (Top 10 for Agentic Applications) and the OWASP AI Agent Security Cheat Sheet's 9
  control domains, with its own verified Detection regexes and a CI/CD section covering the GitHub
  Actions script-injection pattern `agent-pr-audit.yml` already guards against.
- `agent-skills.instructions.md` no longer calls `.claude/skills/` "Legacy" (it's primary for Claude
  Code now) and its frontmatter table documents `version:`, which all three shipped skills use.

### The governance bundle now has to reach the brief — mechanically (`sso-single-branch-development` 0.3.0 → 0.4.0)

Every governance check in this pipeline was a **proxy** for one hop nobody watched. `G1` proved the
bundle existed, `G2` that it covered the diff, `G3` that it was pinned before the first dispatch, `I4`
that it was re-read after a compaction — and then the audit's own NOT-CHECKED list admitted the
load-bearing step was taken on trust: *"A5 — maker briefs embed governance CONTENT, not filenames;
open a real dispatch and look."* A run could pass every mechanical gate and still hand its subagents
`"follow go.instructions.md"`, which is precisely the defect the whole gate exists to prevent.

A `PreToolUse` hook on the dispatch tool **does** see the brief. That closes the loop.

- **New hook: `track-brief.sh`** (`PreToolUse`, dispatch tools). Reads the outgoing brief
  (`tool_input.prompt`) before the subagent starts and counts how many of the pinned bundle's
  constraint lines it actually contains, recording `briefs[]` = `{t, tool, bundle_sha, lines_total,
  lines_matched, min_lines, declared_na, thin, below_min, sections?}`. Both sides are normalized
  (lowercase, punctuation collapsed), so a re-wrapped or back-ticked constraint still matches while a
  brief that names only the *file* matches nothing. Wired on both surfaces; **records by default**,
  denies only under `TRACK_BRIEF_DENY=1`.
- **New audit check `G6`** — a brief that carried **zero** bundle constraints with a bundle pinned is
  a **FAIL**. A brief carrying some but fewer than `TRACK_BRIEF_MIN_LINES` (default 3) is a WARN, not
  a FAIL: a fan-out brief legitimately embeds only its own cluster's sections, and no hook can tell a
  correct slice from a lazy one. A dispatch that genuinely needs no governance (read-only research)
  clears itself with an explicit `GOVERNANCE: n/a — <why>` line — the same "state ABSENT, never no-op
  by omission" rule the bundle itself follows.
- **New audit check `G5`** — `G2` was a substring test, so a bundle section consisting of a bare
  heading (or one `- see the file` bullet) satisfied coverage while transferring nothing any brief
  could embed. `G5` reads the section body and requires ≥2 substantive constraints per matched
  instruction file (`TRACK_GOV_MIN_BULLETS`).
- **`I4` gained its second half.** Re-reading the bundle was never the invariant — the *next brief
  carrying it* is. `I4` now also fails a run where the bundle was re-read after a compaction and the
  first brief after it still went out empty, which is the exact shape of the silent post-compaction
  degradation.
- **Mid-core re-pinning is legal now, and gated.** `track-note.sh governance` appends to a new
  append-only `governance_stamps[]` alongside the overwritten `governance_bundle`. `G3` asks whether
  **every** dispatch was preceded by *some* pin instead of comparing one overwritten timestamp against
  the first dispatch — the old form **failed a run for doing the right thing** when a later cluster
  widened the matched set and the bundle was correctly re-distilled and re-pinned. `G1` compares
  against the latest pin and reports how many briefs were built from an earlier version.
- **The honesty list shrank on evidence, not by assertion.** `A5` narrowed from "did content make the
  hop" to "was it the *right* content for that cluster" (G6 counts lines, it cannot judge relevance);
  `B2` left the manual list entirely, since `I4` + `G6` now decide it. The PR-body tier disclosure was
  updated to match, including which checks are artifact-derived vs mixed-provenance.

### Fixed: the audit test section read the contributor's working tree

`G2`/`G4`/`G5` resolve `applyTo` globs against the **real** git diff, while the audit tests seed a
fake bundle — so editing this repo's own `SKILL.md` (matched by the `ai-agent-*` globs) made the
seeded bundle "incomplete" and flipped `G2` to FAIL, taking down every clean-run assertion for reasons
unrelated to the change. The section now runs from an isolated fixture repo with a neutral diff;
`G2`/`G4`/`G5`/`G6`'s own positive and negative paths are asserted in purpose-built repos where the
diff *is* the fixture. Suite: 284 → **310** tests.

### Fixed: multi-line evidence commands corrupted the PR body table (`sso-single-branch-development` 0.4.0 → 0.4.1)

A captured Bash tool call can be a whole multi-line shell block (cd / setup / debug / the real test
invocation), not a one-liner. `track-evidence.sh` was recording that whole block verbatim as the
evidence `cmd`, and `track-report.sh` dropped it straight into a GFM table cell — a literal newline
ends a markdown table row, so everything after the first line lost its `|` delimiters and rendered as
an unstructured text blob with no visible Command/Result/Fingerprint columns.

`track-evidence.sh` now picks the single line that actually matched the evidence pattern (reusing the
same quote/heredoc-stripped text already used to decide a match, so decorative echoes and quoted
mentions are still correctly ignored) and stores it as `cmd`, keeping the full raw block as `cmd_full`
only when it differs so nothing is lost for an audit that wants the whole picture. `track-report.sh`
also collapses any remaining multi-line `cmd` at render time as a defensive fallback.

## [0.5.0] - 2026-08-07

### Renamed the 3 orchestration skills with an `sso-` prefix

- **`single-branch-development` → `sso-single-branch-development`** (0.2.2 → 0.3.0)
- **`executing-parallel-tracks` → `sso-executing-parallel-tracks`** (0.1.1 → 0.2.0)
- **`pr-review-feedback` → `sso-pr-review-feedback`** (0.1.0 → 0.2.0)

Namespaces the catalog's own skills so they can't collide with a dependency skill vendored flat
into `.claude/skills/` (see below) or with a future third-party skill of the same generic name.
Directories, `SKILL.md` `name:` frontmatter, and every in-repo reference (install.sh, hooks,
tests, workflows, docs) were updated together. Breaking: repos that invoke these by their old
bare names (`/single-branch-development`, etc.) need to switch to the `sso-` prefixed form on
their next install/update.

### Fixed: vendored `superpowers` skills were undiscoverable by Claude Code

`install.sh`'s dependency fetch cloned `obra/superpowers` and copied its `skills/` subtree into
a `.claude/skills/superpowers/` wrapper directory, nesting all 14 superpowers skills two levels
under `.claude/skills/`. Claude Code only discovers `SKILL.md` exactly one level deep
(`.claude/skills/NAME/SKILL.md`) — see
[anthropics/claude-code#28266](https://github.com/anthropics/claude-code/issues/28266) — so none
of those 14 skills, including several this catalog's own skills delegate to by name
(`dispatching-parallel-agents`, `using-git-worktrees`, `verification-before-completion`,
`requesting-code-review`, `subagent-driven-development`, `test-driven-development`,
`systematic-debugging`), actually resolved. `fetch_dep` now copies superpowers' skills flat into
`.claude/skills/` (no wrapper directory) so each lands exactly one level deep.

## [0.4.1] - 2026-08-07

Stale run state and guard false positives in `single-branch-development` (0.2.1 → 0.2.2), plus an
`install.sh` pin that could silently not apply. Every item was reported from real consuming-repo
sessions; the common thread is a gate that keeps firing after the thing it was protecting is gone.

### Stale run state

Reported from a real session
in a consuming repo: a Stage-1 run that had halted days earlier was still governing an unrelated
docs task on a different branch in a different worktree — the tool-call ceiling halted every `Bash`
call, and the evidence gate demanded `go-test`/`py` for a markdown-only diff in a checkout with no
`go.mod` at all. None of it was policy about the new task; all of it was one finished run that never
let go.

- **The managed `RUN_ID` block is now self-retiring** (`track-preflight.sh`). `--persist` used to
  append an unconditional `export RUN_ID="${RUN_ID:-<id>}"` to the installed `track-env.sh`, and
  `--complete` was its only removal path. Completion happens at draft-PR handoff *only*, so a run
  that ended any other way — **ceiling trip, `blocked`, `budget-exceeded`, crash, human abandon** —
  left that line behind permanently, and every later session in the checkout inherited a dead run's
  identity. The block now adopts its id only while the run is **live** (no terminal `status` in the
  record, no `completed_utc` on the breadcrumb) **and** the checkout is on the run's own branch. An
  exported `RUN_ID` still outranks it, so orchestrator-dispatched workers are unaffected.
  - The worst consequence was a **bricked checkout**: `track-meter.sh` re-read a record whose
    `tool_calls` already exceeded `TRACK_MAX_TOOL_CALLS` and returned `continue:false` for *every*
    subsequent tool call, in every session, unrecoverable without hand-editing the hook file.
  - Second consequence: **a fresh start silently reused the finished run's id.** Preflight sources
    `track-env.sh` during bootstrap, then treated any resulting `RUN_ID` as an explicit override, so
    a new track in that checkout wrote into the old run's record. Only a **caller-exported** `RUN_ID`
    counts as an override now; a file-supplied one is an activation hint and nothing more.
- **`track-reconcile.sh` ranks breadcrumbs instead of taking the newest.** Self-recovery preferred
  the newest `runs/*.dispatch` in the checkout, which adopts a finished run on an unrelated branch
  exactly as readily as this session's own — and then the whole resume report describes the wrong
  task. Order is now: the breadcrumb whose recorded `branch` is checked out here → any run not yet
  stamped terminal → newest match (kept last so recovery is never weaker than before).
- **`TRACK_EVIDENCE_SKIP_GLOBS` — a documentation-only escape for the evidence gate** (opt-in, ships
  empty, no behavior change on upgrade). `TRACK_REQUIRED_EVIDENCE` is a floor required on *every*
  diff by design, but a prose-only diff cannot change a go/py/ts result, so the floor demands of it
  something no honest action can produce — and a gate satisfiable only dishonestly gets satisfied
  dishonestly (re-run an unrelated suite, or waive the gate wholesale). When **every** path the diff
  touches matches a declared non-code glob, the gate no-ops. All-or-nothing: one code file anywhere
  in the diff restores the full requirement set, so it cannot smuggle code past the floor.
- **`track-meter.sh`'s halt message names the way out.** The ceiling counts cumulatively for the run,
  so the trip is sticky by design — but a sticky halt with no named exit reads as an unrecoverable
  one. It now states the current count and both deliberate exits (raise `TRACK_MAX_TOOL_CALLS` above
  it, or start a fresh run).
- **`references/hooks.md`: a triage table for "a hook is blocking and I don't know why."** The three
  gates read different inputs and fail independently: the guard's writable scope is **not** keyed to
  `RUN_ID`, so clearing the run state does nothing for a scope denial — the most common wrong turn,
  since all three trip together and look like one policy. Includes the commands that show what the
  hooks actually resolved, and how to tell leftover run state from a real constraint.
### Guard false positives — two rules with no in-bounds alternative

Both reported from the same consuming repo. A rule that denies a legitimate action while naming no
compliant path does not produce compliance; it produces workarounds.

- **`--force` / `--no-verify` are now matched only on git/gh commands.** The pattern was a raw
  substring match meant to catch `git push --force`, so it also denied
  `specify integration install claude --force`, `npm ci --force`, and `uv pip install
  --force-reinstall` — each with a message about rewriting git history that made no sense for the
  command being run. The check now splits the command on shell separators and applies only to
  segments that invoke `git`/`gh`, so `foo --force && git push --force` still trips on its second
  segment and nothing is smuggled through a compound command.
- **Scope prefixes no longer depend on the hook's CWD.** `TRACK_ALLOWED_PREFIXES` is
  worktree-relative, but the guard stripped `$PWD` for any path underneath it — so after a `cd` into
  a subdirectory, an edit to `specs/001-x/contracts/agent-graph.md` relativized to
  `contracts/agent-graph.md`, matched nothing, and was denied. Same failure as the sibling-worktree
  case flagged earlier, reached via `cd` instead. Every path — relative inputs included — now
  resolves through `git rev-parse --show-prefix`, which is also immune to the string-strip mismatch
  when a checkout is reached through a symlink (`/tmp` on macOS).
- **The immutable-prefix check was silently inert outside the worktree root.** `_git_relpath` set
  `GIT_WT_ROOT` as a side effect, but callers read it in a command substitution, so the assignment
  died with the subshell and the check fell back to `$PWD` — meaning it stopped matching in exactly
  the sibling-worktree case the root-tracking was added for, and quietly allowed edits to committed
  migrations. The root now comes back through stdout. The one test that would have caught this had
  been **silently skipping** since it was written, because its fixture path was built from the
  bundle's `.github/` dir rather than the git root; the suite now reports **0 skipped**.

### `install.sh`

- **A `specify integration install` no-op is no longer reported as a successful version pin.** The
  CLI is idempotent and `--force` does not change that: on a repo that already has the integration
  it prints `Integration '<key>' is already installed … No files were changed` and exits 0. The
  installer checked only the exit code, so it printed `✓ installed speckit skills` while the pinned
  version never applied. It now detects the no-op, escalates to `specify integration upgrade` (same
  flags, diff-aware), and **verifies the result** by reading `version` and `installed_integrations`
  back out of `.specify/integration.json` — reporting a mismatch instead of swallowing it.

- 33 new regression tests (284 total, **0 failing, 0 skipped**), including the end-to-end
  bricked-checkout case and the `--force` allow/deny matrix.

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

[0.7.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.7.0
[0.6.1]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.6.1
[0.6.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.6.0
[0.5.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.5.0
[0.4.1]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.4.1
[0.4.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.4.0
[0.3.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.3.0
[0.2.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.2.0
[0.1.1]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.1.1
[0.1.0]: https://github.com/truongpx396/supspec-orchestration/releases/tag/v0.1.0
