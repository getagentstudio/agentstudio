# Bridge after PR1: state, learnings, improvements and next work

Status: current as of 2026-10-09, right after Bridge PR1 (#463) merged.
Start any new Bridge session here. This file consolidates what used to be spread over local plans, a WIP note and session traces.

Tracking: Linear **LUNA-408** (native subscription lifecycle state machine; it carries the improvements table in section 5).

## 1. Where we are

```
Landing order (owner, 2026-09-25)

#364 IPC ──► PR1 transport ──► PR2 = #367 multi-root ──► PR3 surfaces ──► PR4 comments
 merged       MERGED 10-09       next (re-carry onto PR1)
```

- **PR1 merged:** getagentstudio/agentstudio#463, squash `8fb260c01` (head `bf68ab69e`), 2026-10-09.
- **Governing design (on main):** `docs/specs/2026-09-24-bridge-stability-redesign/` — Requirements, Specification, Program Design. The Program Design's PR table (PR1–PR4) and its "Settled during PR1" sections are the contract the next PRs build on.
- **What PR1 delivered:** a transport that always settles; per-installation authority (E1); keyed sealed batches for File, Review and Comments (W4); the page-side per-subscription lifecycle owner (W2); explicit region states (content, loading, empty, updating, failed) with one failure message and one Retry per pane; File restart in place (C5); Review builds only while shown (R15); and the R13 rule that only real recovery charges a view's retry budget.
- **Proof at merge:** product last changed at `6a02f219b`, which was green on every PR1-owned hosted lane (Swift fast/large/WebKit, BridgeWeb unit/integration/browser, Vite E2E 21/21). Sunclaw ran full BridgeWeb green under load at `8495ccb52`. Remaining reds were classified test-only or foreign (section 6).

## 2. Core ideas to carry forward

| Idea | One line | Where it is defined |
|---|---|---|
| Keyed sealed batches (N10, W4) | Native emits keyed records in sealed batches; the page installs a batch atomically or not at all | Program Design N10, W4 |
| Per-installation authority (E1) | Every page installation has its own authority set once at ingress; nothing from an ended installation applies to a newer one | Specification E1, R5 |
| Page lifecycle owner (W2) | One generic owner per subscription on the page decides begins, recovery and Failed | Program Design W2 |
| Snapshot cause on the wire (R13) | `snapshotCause` = open, requested, recovery or newerInput; only real recovery charges the budget | Program Design "Settled 2026-10-08" |
| Region states (U13, R40–R43) | Every region ends in exactly one state; nothing hangs in Loading | Requirements U13; Specification R40–R43 |
| Review only while shown (R15) | Hiding Review fences building attempts; Publishing and AwaitingInstall keep their own lifecycle | Program Design "Settled during PR1" |
| File restart in place (C5) | An interrupted File source restarts on the same handle without user action and keeps its revision floor | Specification C5, R14 |
| Multi-root seams | Canonical-location File keys, the read descriptor shape, membership as one sealed batch | Program Design "Merged seams with #367" |
| Missing piece | The **native** per-subscription lifecycle is not modeled (section 5, LUNA-408) | This file |

## 3. PR1's final review and how it closed

Owner request (2026-10-09): four Sol 6.1 reviewers, one section each of the 446 product files, cross-checking seams; a reducer anchored every finding to the design. Result: 2 P1 + 12 P2, reduced to 11 causes. The owner chose fix packages 1–5 before merge.

| Package | Finding | Outcome |
|---|---|---|
| 1. Tracked symlinks (P1, GO21) | A repo tracking symlinks made the File batch throw | Fixed: each tracked path owns its record; only the root is resolved; reader validation unchanged |
| 2. W2 demand vs recovery (GO22) | Healthy File demand forced false "recovering"; older-demand recovery escaped containment | Fixed |
| 3. Review Retry and Updating | Retry could be a no-op; a retained Review under recovery looked current | Fixed |
| 4. Hidden Review build fence | Review kept building after Review→File | Partly fixed: scheduled builds fenced in the acceptance turn (after GO24 showed the first fence ran after `await`s). **Residual:** explicitly triggered loads (command/IPC) are not fenced; identical on main |
| 5. File Retry revision floor | A failed bootstrap lost its floor, so Retry's snapshot was discarded | Fixed |

Packages 6–9 became follow-ups (section 6).

## 4. Learnings

### Why PR1 had so many late problems

1. **A design gap.** The native per-subscription lifecycle lives in loose containers in `BridgePaneProductMetadataCoordinator` (`subscriptionKindById`, `deferredOpenSubscriptionIds`, `openedSourceSubscriptionIds`, `bootstrapTaskBySubscriptionId`; 7 files, 2,588 lines at `4b9fd2a4e`). Illegal combinations are reachable. GO11 (circular wait across `await`), GO12 (a terminal result dropped with its entry), GO19 (a marker cleared before the work it promised was committed) and GO24 (a fence that ran after `await`s) are all one class: multi-step transitions crossing `await`.
2. **PR size.** About 620 commits; product +72,850/−33,959 across 744 files. Races appeared only at the final, expensive gates.
3. **Tests that sample instead of awaiting owner facts.** GO13, GO14, GO16, GO17, GO18, GO20, GO25, GO27, GO28, GO29 and GO30 were test-only. Under load each gate cycle surfaced a different one.
4. **Proof-environment friction.** Linked worktrees could not build at PR1's ghostty pin while the primary checkout was stale; helpers proved fixes on older bases; WebKit stalls when the console is locked.

### Process lessons (rules going forward)

| What happened | Rule |
|---|---|
| A helper proved a TS fix on a branch without GO10's schema; it failed at the merged head | Prove at the merged head; the Lead reruns affected lanes after every merge |
| A Swift test was merged without compiling (no local tree could build) | No Swift test change merges without a prebuild somewhere |
| Linked worktrees could not build Swift locally | Fast-forward the primary checkout (`~/code/projects/agentstudio`, clean `main`) and run plain `mise run setup` there and in the linked tree (owner approved 2026-10-09) |
| A day of re-gating test-only flakes after product was proven | Once product is proven, say so, hand the merge line, and route test debt to the CI Lead |
| A fence placed after `await`s fenced a newer attempt (GO24) | State change and effect registration happen in one actor turn, before any `await` |
| WebKit pages stopped answering while the console was locked (GO26) | Harness waits need a "page died" closing fact; record console-lock state in lane reports |
| Reviewer sessions unloaded without writing reports | Check for the report file and session state, not just "running" |
| Raw traces contain local paths and session ids | Public repo gets curated docs; raw traces go to the private session-logs repo |

## 5. Improvements to make (tracked with LUNA-408)

| # | Improvement | Evidence | Kind | Owner | Tracking |
|---|---|---|---|---|---|
| 1 | **Native subscription lifecycle state machine:** one per-subscription value replaces the loose containers; pure transitions return effects; state change and effect registration in one actor turn | GO11, GO12, GO19, GO24 | Product | Bridge | **LUNA-408** |
| 2 | One writer per status: separate typed statuses for delivery recovery and render health, combined only by the region renderer | GO15 (render watchdog wrote the delivery budget) | Product | Bridge | LUNA-408 (related) |
| 3 | The owner announces, the test awaits: replace polls and samples with owner facts; a missing signal becomes a small production fact | GO25, GO27, GO28, GO29, GO30, TQ21 | Product signals + tests | CI Lead (tests), Bridge (signals) | CI handoff |
| 4 | A reusable test-resource owner for BridgeWeb browser tests, built outside a PR crunch | GO17-R3 cascade on 3-core | Tests | CI Lead | CI handoff |
| 5 | A scheduled stress lane (throttled cores plus load) so races surface before a PR's final gate | Most late reds appeared only under load or on 3-core | CI | CI Lead | CI handoff |
| 6 | Always-on failure timelines: event ledger plus install and receipt sequence in every failure artifact; WebKit waits with closing facts; console-lock state | GO26 silent 600 s reap; empty CI event logs | Telemetry + tests | CI Lead + Bridge | CI handoff |
| 7 | Reduce the surface: split the large coordinator and test-support files by responsibility | Coordinator 2,588 lines; carrier test support 900+ lines | Product + tests | Bridge | LUNA-408 (related) |
| 8 | Smaller vertical PRs: PR2 lands as slices, not one rewrite | Learning 2 | Process | Bridge | Section 7 |

**LUNA-408 design direction (to be designed, not decided):** states roughly `closed / opening(task) / open / pendingReopen(cause) / retired`; `BridgeFileSurfaceReconciler` plugs in as the File build sub-machine; model-based tests drive event interleavings (GO11/GO12/GO19/GO24 orders); existing behavior suites stay green. About 26 write sites in 3 coordinator files. It is a production change: design cycle first, its own PR, and it should land **before PR2 builds more on this coordinator**.

## 6. Follow-up backlog

**Product (Bridge Lead):**
- Packages 6–9 from the final review: D1 logical completion vs physical drain on pane disposal (S1-F1/S2-F1); remembered Export/Repeat deadline classification (S1-F4); dev-host parity (S2-F2, S2-F5).
- Package 4 residual: explicit Review loads not fenced on hide (main has the same behavior). Fix with item 1.
- Tracked-symlink alias refresh when only the target changes (pre-existing; stale reads fail typed, never serve wrong bytes).
- Investigate V2 refused retryability: `bridge-product-session-authority.ts` flattens refused/superseded to `retryable=false`.

**Test reliability (CI Lead, via side agents; handoff in the private session-logs repo):** R68 Review deep-scroll witness (main-inherited), GO30 hard-cut Files filter dismissal (3-core), GO26 WebKit waits without closing facts, TQ23 markdown act escape, TQ35 shared-profile tab ownership, and audits for the GO25/GO27 patterns.

**Closed by PR1 (reopen only if seen again):** TQ24, TQ25, TQ26, TQ33.

## 7. Multi-root (#367)

**What it is.** #367's own design (copied here under `multi-root/` from branch `bridge-multi-root` at `3d97772e7`):
- **B1, stable receiver and multi-root Files collection:** one stable receiving Bridge per terminal; Files over all member worktrees plus loose documents with collection-wide search; Review of one member; known-worktree membership with CWD protection; local-file annotations; IPC reachability. Requirements R1–R4, R14–R16; contracts C1–C4, C7.
- **B2:** agent opens an exact file for the human, the Open view, and ⌘-click on terminal paths.
- **B3:** multi-PR summary.

**State today.** PR #367 is a draft against `main`; branch `bridge-multi-root` was last changed 2026-09-28 and is 80 commits ahead and over 112 behind `main` (now also behind PR1). It is built on the pre-PR1 transport. The local worktree `agentstudio.bridge-multi-root-restored` is 28 commits behind the remote branch.

**How it lands.** PR2 re-carries #367 onto PR1 slice by slice; it is not a rebase of 80 commits. The plan is `plans/2026-09-25-bridge-stability-stack-v3.md` § "PR2: #367 re-carried on PR1" (slices 2.0–2.6: INST receipt core first, then collection index, receiver navigation, web File projection, comment subjects, integration) with the file-by-file inventory `plans/2026-09-25-pr2-adaptation-inventory.md` (KEEP / ADAPT / REPLACE per file). B1's original implementation plan is `plans/2026-09-23-bridge-b1-receiver-and-collection.md`.

**What is stale and must be refreshed before PR2 starts:**
- Stack v3 and the inventory were written against PR1 at `0b7f66d83`. PR1 then grew (W2/W4, R13 causes, packages 1–5). Re-run the inventory against main.
- The mechanics "merge PR1 into `bridge-multi-root` and retarget the base" are obsolete: PR1 is on main.
- B2 and B3 have no plans.
- LUNA-408 should land before PR2 builds on the coordinator, or PR2's first slice must include it.

## 8. Decisions for the next session

1. PR2 approach: re-carry B1 onto main in slices (recommended) vs merging main into #367.
2. Order: LUNA-408 first, or as PR2's first slice.
3. PR2 scope: B1 only, with B2 and B3 as later PRs.
4. Whether PR3 (surfaces, per-member change filter) and PR4 (comments, migration 018 after #367's 017) keep their current shape.

## 9. Index

| Path | What |
|---|---|
| `2026-10-09-bridge-after-pr1.md` | This file |
| `multi-root/` | #367 Requirements, Specification (`2026-09-12-bridge-navigation.md`), Program Design, proposal and diagrams |
| `plans/2026-09-25-bridge-stability-stack-v3.md` | The 4-PR plan (PR1 historical; PR2–PR4 sections are next-work input) |
| `plans/2026-09-25-pr2-adaptation-inventory.md` | #367 → PR1 file inventory |
| `plans/2026-09-23-bridge-b1-receiver-and-collection.md` | #367 B1 implementation plan (S1–S10) |
| `docs/specs/2026-09-24-bridge-stability-redesign/` | The governing stability design (separate folder) |
| Private `session-logs/2026-10-09-bridge-pr1-history/` | Raw PR1 trace, final-review reports and re-reviews, PR #463 body, B1 working notes |
| Private `session-logs/2026-10-09-bridge-pr1-test-reliability-handoff.md` | CI Lead handoff |
