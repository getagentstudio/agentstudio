# Implementation Plan: Bridge stability stack v3 (4 PRs)

## Canonical record
- **plan path:** `docs/specs/2026-10-09-bridge-after-pr1/plans/2026-09-25-bridge-stability-stack-v3.md` (moved from a local tmp plan)
- **supersedes:** `2026-09-25-bridge-stability-stack-v2.md`. The meaning changed on 2026-09-25:
  - #367 (multi-root) joined as PR2, and the stack became 4 PRs;
  - the INST core and in-session late outcomes moved into PR1;
  - per-domain recovery (F6) was added;
  - Export became drawer-first (U11);
  - pane close got bounded cleanup.

  Committed slices 1.0 `8a1e9f8a8`, 1.1a `54039d679`, 1.2a `5069e0a20` and 1.3a `7b666f542` carry over unchanged.
- **originating planner:** plan-implementation (orchestrator 94afdd01)
- **planning result:** ready. All slices are released; the remainder verification returned **ready** at 703eb7d0f (2026-09-25 22:10).
- **governing planning basis:**
  - kind: reviewed three-artifact design (Requirements, Specification, Program Design) in `docs/specs/2026-09-24-bridge-stability-redesign/`, at **`e730d9eaa`** (`703eb7d0f` plus advisor rounds 4–7, delta reviews DV26-1/2, Q15, Q20, Q22/23 and Q26, all ready: comment revisions, whole-host disposal, INST moved to PR2, Export intent);
  - reviews:
    - `design-review/2026-09-25-three-artifact-review.md` (ready, 13/13);
    - `design-review-combined/2026-09-25-combined-review.md` (F1–F6);
    - remainder verification `design-review-combined/2026-09-25-remainder-verification.md` (**ready**: F1, F4, F6 and numbering resolved; 0 new);
  - advisor rounds 1–3 in `tmp/2026-09-24-bridge-stability-research/advisor/`;
  - #367's governing design: `agent-studio.bridge-multi-root/docs/specs/2026-09-12-bridge-navigation/` (R1–R19, C1–C7), as merged by the Program Design's "Merged seams with #367".
- **owner decisions (2026-09-25):**
  - joint design C; drop old comments; migration 018 after 017; loose documents shown as "not in git";
  - keep PR #367 as PR2;
  - a late save across a reload keeps today's unknown state until PR4;
  - pane close follows a bounded deadline plus a leak diagnostic;
  - Export is drawer-first with no blocking dialog;
  - review process as set (no Opus pass);
  - S10 native proof run tonight.
- **delivery context:**
  - requested terminal: **pr-ready-unmerged** (the owner merges; squash only);
  - topology: a linear stack, `main` ← #364 (not ours) ← PR1 ← PR2 (#367) ← PR3 ← PR4. Each boundary freezes the shared contracts and fixtures.

## Goal and scope
Deliver the Program Design's four PRs. Each PR head passes `mise run test` and leaves a working app.

| PR | Branch | Delivers |
|---|---|---|
| **PR1** Transport that always settles | `bridge-stability-1-transport` | N1–N4, N9, N10, W1–W5; per-domain batch state (single domain exercised); INST core; late-outcome evidence; clocks, probes, seams; the transport contract suite |
| **PR2** = #367 on PR1 | `bridge-multi-root` (PR #367 kept; PR1 merged in, base retargeted to PR1) | the receiver, navigation, Files collection and subjects re-carried on PR1; the collection domain plus member domains; activation generation; reveal by point lookup; search coverage |
| **PR3** Surfaces that converge | `bridge-stability-3-surfaces` | N5–N7 (extending INST), File/Review status and Retry UI, the U12 change filter per member |
| **PR4** Comments stand on their own | `bridge-stability-4-comments` | N8, migration 018, comment kinds on the Comments surface, placement UI, persistent receipts |

- **Non-goals:** Markdown images and links; perf tuning; stored bytes; prewarm; shims; turn- and time-based diffs (docs/wip).
- **Protected:** Ghostty/zmx vendors; non-Bridge features; the IPC command catalog (#364 owns it); CI-guardrails files (#358); release.
- **Hard rules (CLAUDE.md), for every slice:**
  - hard cutover; no `#if DEBUG` hooks;
  - no timed or polling waits in tests (controlled clocks and event or quiescence waits only);
  - Swift Testing only; UUIDv7 ids;
  - every deadline, window and budget in `AppPolicies`;
  - new WebKit suites registered in `webkit_suite_filters`, and new serialized MainActor suites in their isolated lane (the #358 lane gate enforces this);
  - the import graph;
  - new controls go through the action-spec display pipeline.

## Per-PR closing gates (owner, 2026-09-25)
Before each PR's wrap-up, in this order:
1. **Orchestrator self-review** of the diff and actual proof against Requirements, Specification, Program Design and this plan.
2. **Advisor review** (Astra high, 01a0d602).
3. **Independent reviewer:** ONE persistent Astra xhigh session for all PRs. It gets ONLY Requirements, Specification and code: no Program Design, plan or conversation. It is created at the first PR gate and reused for every PR.
   - **Owner, 2026-09-26: every stability review at the end is Astra xhigh, and it must fan out wide.** The reviewer uses MANY Luna Worker subagents to scrape and sweep the code:
     - one Worker per seam or file cluster, looking for correctness and concurrency bugs, lost or duplicated settlement, and wedge paths;
     - read-only;
     - each returns findings with file:line evidence.
   - The reviewer verifies each Worker's evidence before it becomes a finding. The brief must say this explicitly.
   - Named review items: the 2.0g diagnostic telemetry volume (+1,231 lines in `70341ab16`), and whether it stays, shrinks or goes.
4. **Variety check (owner, 2026-09-26).** After the Astra xhigh review and its corrections, an **Opus high** reviewer double-checks the final code for stability and multi-root issues. It is a different model lineage and gets the same independent inputs (Requirements, Specification and code only).
   - **Grok 4.6 high** may be used at any time for scoped reviews of a single slice, seam or file cluster.
   - Every finding from either one is verified against the code before it is accepted.
   - Look up the exact model ids and endpoints (likely cursor-local for Grok) when commissioning.

Corrections need fresh proof, and the same reviewers verify them. There are at most 3 remediation passes per PR. Then `implementation-pr-wrapup` runs (a 🔧 Operator or the implementer). PR-ready means unmerged; the owner merges.

## Agents
| Role | Model | Session | Scope |
|---|---|---|---|
| 🦉 Advisor | Astra high | 01a0d602 | design decisions, boundaries, gate 2 |
| 🔎 Combined design reviewer | Astra xhigh | 01a0d8b3 | design remainders only |
| 🔎 Independent implementation reviewer | Astra xhigh | created at the PR1 gate | gate 3, every PR |
| 🐒 PR1 implementer | Sol medium | 01a0d836 | PR1 |
| 🐒 PR2 implementer | Luna xhigh | 01a0d3f0 | #367 lanes 1 and 4 plus integration; knows #367 |
| 🐒 PR2 lanes 2 and 3 | Sol high (new) | when PR2 opens | web File projection; comment subjects |
| 🐒 S10 operator | Sol medium | 01a0db67 | computer-use proof, second monitor |
| 🐒 Test lane T | Luna xhigh (new) | now | the test-audit items below |

Implementers report through `impl/<pr>/slice-*.md` and `QUESTION-n.md`. Main verifies against the source, never against receipts.

## Validation discipline
- Focused lanes per slice. `mise run test` once per PR head, scheduled by main; no concurrent full runs across agents.
- Scratch or gate worktrees go outside `~/Documents/dev/project-dev`, because the production app watches that folder.
- Red-first evidence is captured before the fix. A red CI run is diagnosed from the lane report plus the event-stream artifact: never rerun it, never raise a bound.

## PR1: Transport that always settles
Owner: 🐒 Sol medium (01a0d836).

| Slice | State | Obligations | Write surfaces | Red-first / proof | Stop / replan when |
|---|---|---|---|---|---|
| 1.0 | ✓ `8a1e9f8a8` | clock and quiescence seams | — | — | — |
| 1.1a | ✓ `54039d679` | v2 envelopes (kind-agnostic) | — | — | — |
| 1.2a | ✓ `5069e0a20` | admission, operation table, result requests, settlement, escape controls, human pool, replay, sessionSuspect | — | S13 and loopback. **2 Save late-outcome tests held red, owned by 1.2b** | — |
| 1.3a | ✓ `7b666f542` | successor before old release; retirement keyed by worker installation | — | router and host red→green; S13 6/6 | — |
| **1.1b** | gated | File/comment kind payloads. The File record key = canonical document location, with display key and read descriptor as fields; `kind = deleted` ghost rows; U12 scope values `none \| uncommitted(kinds) \| allChanges(kinds)`. **Batch domain fields** `domain`, `incarnation`, `requiresCollection?`. **Watch and observe wire:** `observe(operationId, after)`, `stillUnknown`, `lateOutcome`, `mutationWatchCapacityExhausted` | Swift `Models/Transport/*Contract*.swift` and `BridgeProductStrictJSON.swift` vocabulary; TS `core/comm-worker/bridge-product-*-contracts.ts`; `Tests/BridgeContractFixtures/**` | Both sides round-trip the same fixtures. Freeze the serialized File-key recipe in shared fixtures (PD "Merged seams") | A fixture can't express a design rule |
| **1.2b** | gated | F4: a watch pool reserved at mutation admission; revision-aware `observe(after:)`; `lateOutcome` evidence; rev1 ack never deletes rev2; watches released at session end; no replay | `BridgeProductSession*.swift`, `BridgeProductOperationTable*.swift`; worker `bridge-product-session-authority.ts`, `bridge-comm-worker-runtime-product-control-dispatch.ts`; `AppPolicies.Bridge` | The 2 held Save tests turn green. New cases: completion before the unknown ack; full watch pool (mutations refused, reads proceed); `stillUnknown` expiry with no recovery; **draft retained through session loss** | The result channel can't hold observers without breaking W1 |
| **1.3b** | gated | bounded retirement cleanup: the whole sequence (lifecycle ack, router drain, tasks) is bounded by `AppPolicies.Bridge` retirement quiescence; completion through a separately owned signal, **not** a task-group exit; a typed diagnostic of unfinished executions; physical resources kept until the provider exits | `BridgePaneProductSessionOwner.swift`, the router, `BridgeDevelopmentProductHost.swift` | A permanently uncooperative provider: `.paneDisposal` returns at the controlled-clock deadline with a leak count, and a late publication is rejected. A cooperative provider converges to 0 before the deadline | — |
| **1.4a** | **released** | N10 publishers plus N3 view sender: keyed state per kind; **per-(view, domain, incarnation) state** (`default` only in PR1); dirty-key set plus budget; credits on receipt; ack deadline → resnapshot for that domain; comment revision minted inside the SQLite transaction; File keyed by canonical location; stale producer input rejected before minting; tombstones | `BridgePaneProductFileMetadataSource*.swift`, `BridgePaneProductMetadataCoordinator*.swift`, `BridgeProductProducerRegistry*.swift`, `WorktreeAnnotations/*Source*.swift`, `WorktreeAnnotationServiceActor+MetadataPublication.swift`, the SQLite repository | Swift contract suite, × 4 kinds. **Wedge b** historical red at `e40ac70f3^`. The domain key is internal until 1.1b lands the wire field | The largest-tree snapshot can't stay under the staging budget |
| **1.4b** | after 1.1b | W2 lifecycle, W3 registry, W4 receiver **per domain**: side bank, applicability, `requiresCollection` staging, ownership check, tombstones, newest-wins, pruning of owned certified ranges, a stale presentation bank on a new handle. Delete the sequence poison, per-frame ack, `sourceAccepted` wipe and per-kind reopen budgets (v2 line refs) | worker `bridge-product-subscription-state.ts`, `bridge-product-transport.ts`, `bridge-product-metadata-application-registry.ts`, `bridge-comm-worker-file-metadata-projection.ts`, `bridge-comm-worker-review-metadata-*.ts`, `bridge-comm-worker-product-controller.ts`, `bridge-comm-worker-annotation-*.ts` | Worker contract suite against the real codec, × 4 kinds. **Wedges a, i.** Two-domain property tests: both delivery orders of transfer vs member change; delete then stale write; failed member keeps stale rows. Test repairs as in v2 | Staging a Review publication exceeds page memory |
| 1.4c | after 1.4a + 1.4b | integration through the dev server: R8 sibling isolation, the fault proxy (drop, duplicate, reorder, stall parts; lose an ack) | as v2 | E2E contract layer, × 4 kinds | The proxy can't reach a fault without product edits |
| 1.5 | **after 1.4a** (Q5) | content: credits via the common N3 owner; cumulative ack; finite progress; typed `superseded` using the 1.1b descriptor field | as v2 | as v2 | — |
| **1.6** | released; remembered-folder persistence awaits the owner | N9 Export (U11): wire `destination: remembered \| choose` on JSON `output.scope.commit`; **Change folder… is a separate preference action** (no export); the remembered folder sits behind an injected App-owned preference protocol. **Interim until the owner decides persistence:** application-lifetime memory starting at `~/Downloads`, declared as interim in code and report. Export writes to a remembered folder with no dialog; "Export to… / Change folder…" opens a modeless picker; drawer shows "Saved to …" with Reveal and Change folder…; typed errors; write token with atomic `tryBeginWrite`; callbacks settle once; begun writes are application-owned; controls via action specs | `App/Coordination/WorktreeAnnotationOutputEffects.swift`, `Runtime/WorktreeAnnotations/WorktreeAnnotationOutputCoordinatorActor.swift`, `worktree-annotations/worktree-annotation-share-mode.tsx` + output controls, the action-spec catalog entries | Close before selection → cancelled, no write. Close between selection and `tryBeginWrite` → no write. A begun write completes and is recorded. Other panes and ops proceed while the picker is open. Remembered folder, no overwrite, missing folder → typed error. **Visual:** debug app via Sol operator | The action-spec pipeline can't express a drawer menu |
| 1.8 | **moved to PR2 slice 2.1** (advisor round 4, QUESTION-11) | — | — | — | — |
| 1.7 | last | the full transport contract suite; packaged WKWebView replacement journey; test-audit items 2 and 3 (below); diagnose the three open hangs | as v2, plus audit sites | `mise run test` green on the PR1 head | Any gate red: diagnose, never rerun |

**Edges:**
- 1.1b → 1.2b, 1.4b, 1.5, 1.6;
- 1.4a → 1.4b (lockstep wire), 1.5;
- 1.4a + 1.4b → 1.4c;
- all → 1.7.

**Integration gate:** 1.4c.

## PR2: #367 re-carried on PR1
Starts when the PR1 head passes `mise run test` (it doesn't wait for PR1 review).

**Mechanics:**
1. Merge PR1 into `bridge-multi-root`. That's a merge, with no rebase and no force-push.
2. Retarget PR #367's base to `bridge-stability-1-transport`.
3. If #364 hasn't landed, PR2 carries both histories until PR1 merges `main` after #364.

**Inventory:** `agent-studio.bridge-multi-root/tmp/b1-luna/2026-09-25-pr2-adaptation-inventory.md` (governing seams A1–A5, test dispositions, lanes).

| Slice | Lane | Obligations | Write set | Proof |
|---|---|---|---|---|
| 2.0 | now, on the current #367 (worktree `/private/tmp/agentstudio-367-ci-2-0`, branch `bridge-multi-root-ci-2-0`) | **Production fix:** a File *query transaction* must not wait on paint. Today `queryCommit` rides the rAF tree-patch drain (`bridge-file-viewer-pierre-tree-runtime.ts:296-308` → `bridge-file-viewer-tree-patch-coordinator.ts:88-98` → `bridge-main-render-snapshot-store.ts:766` → `bridge-main-file-display-patch-applier.ts:185-206`). A hidden page therefore holds the query and tree slices pending until the acknowledgement timeout fails the transaction (:349-365). Complete the logical transaction when the worker commit is received; keep rAF for Pierre paint only. **Tests:** the RealGit WebKit tests assert logical File state (index, query, selection, content-open) with frames withheld; paint assertions only in visible runs | `BridgeWeb/src/file-viewer/bridge-file-viewer-pierre-tree-runtime.ts`, `bridge-file-viewer-tree-patch-coordinator.ts`, `core/comm-worker/bridge-main-file-display-patch-applier.ts`, `bridge-main-render-snapshot-store.ts`; the two RealGit WebKit tests and carrier support | red-first: a hidden-page query replacement fails with `acknowledgementTimeout` and frames withheld. Then green. #367 CI run green; the W4 visible-host gate kept only on paint assertions |
| 2.1 | integration (Luna) | merge PR1; shared contracts (File key recipe, member groups, annotation subject); fixtures. **Then the INST core** (moved from PR1 1.8): a page receipt on model and content install, independent of paint and visibility, correlated by session and source, selection generation, command id and displayed descriptor; monotonic, idempotent native acceptance; human supersede, including the same file; two completion predicates **Plus (PR1 QUESTION-35):** the INST receipt acquires the exact editor lease on its displayed File descriptor (released on supersession, selection end or revocation) and DELETES PR1's interim capped retention; the "editor-held A" proof moves here (identity retained and verifiable reads only; never historical bytes and never B's bytes under A, per PR1 QUESTION-36). | integration-owned files (inventory list), plus `use-bridge-file-viewer-selection-receipts.ts` and `BridgePaneController+FileActivation.swift` | Swift/TS fixture round-trip; two selections in one publication distinguished; a hidden page answers 'installed, not shown'; a human same-file selection doesn't inherit a native command id |
| 2.1c | integration (Luna) | **Pane links = per-contribution membership, port contract, receiver storage** (PD *Pane links are membership*, *Pane-link port and git/PR summary delivery*, *Receiver storage*; board `01a0cdc9` seq 1876). Contributions with a runtime-stamped `addedBy: agent\|person\|app`; derived CWD protection; item-owned order; PR references by forge identity. Replace #367's `local_bridge_navigation` whole-workspace blob with `bridge_receiver_state` + `bridge_receiver_item`, keyed upsert/delete by the repository, generation-ordered, commit-then-publish for membership, and next-day purge with late-write rejection. Outcome unions: membership v3 (add/remove/pending-removal incl. refusedNotAuthor/PR reference) and reveal v4 (agent reveal never waits on a draft or a live page → `waitingInOpenView`; the human Open of the Open view item runs the draft barrier). The Open view item is PR B's `.notice` with an `.openFile` action, idempotent per (owner pane, canonical location). Publish the shared fixtures `Tests/BridgeContractFixtures/pane-links/` and `reveal/`. Drop B3; the git/PR summary is consumed from PR B/PR C (stand-in until they land). | Core `BridgeNavigationRecord`, `BridgeNavigationMembershipRules`, `WorkspaceLocalRepository+BridgeNavigation.swift` + its migration, `BridgeNavigationCommandHandler` | round trip per kind with rejection of a malformed row; two contributors add/remove concurrently and neither loses the other's row; agent removes own vs person removes the link; `refusedNotAuthor` vs `alreadyAbsent`; draft settlement only when effective membership disappears; pending removal revalidated (becomes protected, owner moved); commit failure leaves the atom unchanged; the stale-UI-save interleaving (g10 selection, g11 removal, g10 delivered → stays cleared); the delayed-commit interleaving (g20 commit behind g21 UI → g20 membership published, g21 kept where valid); crash between commit and publication restores the committed membership; removing a member drops its dependent comparison/selection in one transaction; retired receiver rejects a late write and purges at `purge_after` under a controlled clock; fixture parity with the unions; the populated-database test for #367 dev rows (or a recorded drop-and-recreate decision) |
| 2.2 | lane 1 native collection (Luna) | the collection index plus one minter; collection domain plus member domains; a sealed membership transfer; `requiresCollection`; per-member coverage and status; search's own coverage **Plus (PR2 QUESTION-2.5-1):** the regroup put also carries the comment subject. Annotation scope and exact-file refresh derive from the keyed index entry, not `layout.openedDocuments`. Today (#367), a loose-to-member regroup drops the local subject. | `Transport/FileCollection/**`, `Runtime/FileCollection/**`, `BridgePaneController+FileCollection.swift`, collection tests | membership during a member scan; transfer vs member change in both orders; a failed member keeps its rows; the regroup-keeps-editor E2E; the regroup-keeps-comments test |
| 2.3 | lane 4 receiver navigation (Luna) | generation captured before discovery, checked before every effect and receipt; bounded re-issue across session replacement; activation completes on an INST generation-matched receipt **Plus (from PR2 QUESTION-2.1c-3):** the editor barrier `BridgeEditorPreparationOutcome` and its page contract split `.failed` into `refused **Plus (PR2 QUESTION-2.3-1):** 2.3a lands agent reveal preparation with production failing closed to `waitingInOpenView` behind a typed eligibility seam; PR2 MUST NOT ship with that interim. The real read-only visible/draft-free fact and line-confirmed shown receipt come from the 2.1 INST core after PR1 merges in, and the stand-in is deleted. **Plus (PR2 QUESTION-2.3-7):** 2.3b lands the pre-discovery generation capture and the editor-barrier split natively. The in-controller generation check before the selection effect and before the displayed receipt, a typed session-replacement outcome split from `.cancelled`, and at most one re-issue per observed replacement move to 2.1 integration. They go through the internal `BridgeReceiverPresentation` activation contract, built on PR1's installation identity, and are proven there by the A/B race and a one-session re-issue case. | saveFailed | saveOutcomeUnknown`, so the pending-removal `draftKept(reason)` becomes precise (2.1c maps `.failed` to `saveOutcomeUnknown` until then). | `BridgeNavigationCommandHandler*`, Core navigation | the A/B activation race; a full-pool activation with drafts; an unknown draft flush counts as refused |
| 2.4 | lane 2 web File projection (Sol high) | a logical keyed File model; reveal by point lookup with its dependency tuple; hidden installed state; the Pierre rAF queue as paint only; INST from 2.1 | `BridgeWeb/src/file-viewer/**` and the listed app composition files | reveal before enumeration, reveal filtered or unopened, a failed-member reveal, hidden reveal with frames withheld |
| 2.5 | lane 3 comment subjects (Sol high) | a subject survives regrouping; `scopeKey` as a view-scope value; authorization by admitted subject; epochs kept (PR4 cuts over) | `Runtime/WorktreeAnnotations/**` (except output and version), the migration 017 proof, `worktree-annotations/**` projection | local-subject comments re-proved; the regroup-keeps-comments test |
| 2.6 | integration | old-stream test dispositions (inventory table); S10 remainder; `mise run test` | per the inventory | green PR2 head, plus S10 |

**Edges:**
- PR1 head → 2.1 → {2.2, 2.3, 2.4, 2.5} in parallel (disjoint write sets);
- all → 2.6;
- 2.0 runs now, independently.

## PR3: Surfaces that converge
v2's PR2 content, renumbered 3.x, with these changes:
- the U12 change filter is **per member** (each member uses its own HEAD and origin default; a member with no baseline reports a failure and never borrows another's baseline);
- loose documents are exempt and shown as "not in git";
- INST is extended from PR2 slice 2.1, not created.

**Wedges:** c, d (`stale_source`), f, h.
**Owner:** Sol high for the reconciler (3.2); Luna xhigh for UI and filter (3.5, 3.7).

## PR4: Comments stand on their own
v2's PR3 content, renumbered 4.x, with these changes:
- **migration 018 runs after #367's 017**: drop old rows; add `version_record_json` to thread and session; add the `annotation_mutation_receipt` table;
- persistent receipts extend 1.2b's in-session evidence across reloads;
- the Comments-surface lifetime replaces epochs.

**Wedges:** g, k.
4.1 (the migration) may start in parallel once PR2's 017 is on the branch.

## Test lane T: test-audit intake (Luna xhigh, now; disjoint from PR1)
Source: `tmp/2026-09-24-bridge-stability-research/2026-09-25-test-audit-intake.md`. The Astra verification is controlling.

| Item | Change | Owner |
|---|---|---|
| T1 | `review-tree-click.ts:10-58`: drop the 160×rAF reachability scan from `selectReviewFile`; keep the full traversal only for reachability tests | lane T now (test-support only) |
| T2 | `BridgeRuntimeTests.swift:143`: inject a fresh bus instead of `PaneRuntimeEventBus.shared` | lane T now |
| T3 | carrier `waitUntil(timeout:)` at 23 sites → owner events | PR1 1.7 |
| T4 | per-test clock budgets → config-level bounds | PR1 1.7; coordinate the config change with CI-guardrails |
| T5 | WebKit process folding | the CI-guardrails session (runner); we supply the suite list |
| — | keep: warm-reload AND cold-restart journeys; `BridgeDevelopmentAnnotationHTTPRoutingTests.swift:267`; the local-first perf verifier tests | binding |

## Gates on this plan
- 1.1b, 1.2b, 1.3b and 1.6 start after the remainder verification (01a0d8b3) returns resolved, or after its bounded corrections land.
- The advisor round-3 verification may refine wording. Implementers take slice meaning from the Program Design at the verified commit.

## Stop and replan (return to main with evidence)
- a platform gap (WKURLSchemeTask concurrency; modeless picker ownership);
- a memory or staging bound can't be met;
- a fixture can't express a rule;
- a protected surface or a new owner decision is needed;
- any gate red after diagnosis.

## Amendment 2026-09-27: agent show simplified (owner decision)
The owner **supersedes** row 2.3's agent-reveal parts (Q2.3-1 fail-closed eligibility and stand-in, the Q2.3-3/-4/-5 retention, provenance and close-floor work, the INST "real draft-free fact" binding) and the reveal-draft owner brief, which is moot. The new R39: one IPC `show(pane, file+line, mode)`. **background** writes the Open files inventory and line, and posts an inbox notification; **takeOver** goes through the existing IPC human approval and then the ordinary human activation. One reply: `opened · shown · declined · notFound · paneUnavailable`.

Work: (1) a small contract PR on main replacing `PaneRevealPort` (the storage agent, then the owner merges); (2) PR2 deletes the 2.3a reveal machinery and implements `show` on the 2.1c inventory; (3) the Panes/IPC orchestrator owns inbox attention types and filters (informational vs needs-approval), per board 01a0cdc9 msg 01a0e305. Unaffected: the human-activation parts of row 2.3 (generation, one re-issue and the INST receipt at 2.1).
