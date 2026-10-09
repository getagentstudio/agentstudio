# Bridge reliability checklist

Production is read-only. Runtime mutations use isolated Debug 371p and disposable repositories under `/private/tmp/agentstudio-annotation-repro`. No production restart, settings change, rescan or data write occurred. No merge or release has been performed.

## Current delivery

- [x] Fix stale annotation subscriptions after a File/Review surface epoch advance. User reproduced missing drawer comments plus “Updates unavailable” in Debug on the real ipc-improvements worktree. Real-transport regression failed before the fix; three regression cases pass after it. Native save/edit reached the drawer without reopening.
- [x] Fix saved comment text remaining stale while the old Markdown source is retained. Browser regression failed before the fix; native edited text subsequently appeared without navigation.
- [x] Register filesystem effects for newly discovered repositories, including unchanged main-worktree reconciliation. Twenty-seven discovery/reassociation tests and two real-coordinator integration tests pass. Exact original production repository disappearance is not retrospectively explained.
- [x] Fix contiguous `ipc` / `IPC` matches being rejected by fuzzy search. Forty focused tests and native Debug search proof pass.
- [x] Map changed-file annotation captures to the existing invalid-source result rather than generic unexpected failure. Twelve focused source/adapter tests pass; additional real-file source-witness coverage passes.
- [x] Replace the rejected full-width yellow file-change banner with a neutral floating control: icon, “File changed”, and Update. Shared floating styling comes from popover roles. Nineteen affected browser tests pass, including exact durable draft receipt, failed preparation, stale/inactive completion, compact geometry and no document movement.
- [x] Complete the bounded Copy investigation. The original intermittent `failed/unavailable` remains unresolved; no speculative Copy fix was made. Both ungated native churn and controlled real-transport overlap pass. Owner authorized moving forward with this limitation documented.
- [ ] Complete final `mise run test` after integrating current main. Candidate6 reached native WebKit but did not pass. Packaged build and current native proof pass. Earlier fixture length, formatting and helper typing issues were repaired without changing proof requirements.
- [x] Scope the floating control's explicit failure label to its document request. Failed Update → automatic recovery → later held file change reproduced the stale label (one failed/seven passed); request-scoped error state fixes it (20 affected browser tests pass). Evidence: `floating-label-red.log`, `floating-label-green.log`.
- [x] Verify the final floating Update control in rebuilt Debug 371p. A disk edit displayed the compact neutral control; Update installed new text, hid the control and retained the exact draft in the editor. SQLite confirmed one unsaved draft. Save then produced one saved message (revision 1) and no leftover draft. Native screenshots captured in the conversation.
- [x] Complete native fresh-discovery file-update proof. Created `fresh-registration-live-proof` after current Debug startup; it appeared in command search, its Files view opened, and a disk edit appeared automatically without reopening or restarting.

## 2026-09-23 continuation

- [x] Restore the test build after the second main merge: `WorkspaceCacheCoordinatorDiscoveryEffectsTests` lacked main's new `ipcLifecycle:` argument, so HEAD's test target did not compile.
- [x] Root-cause the WebKit File/Review "inactivity timeout". Since #351 the DOM waits are unbounded by design, so a Review that never renders shows as a runner kill, not a failure. A/B with identical Swift builds: branch BridgeWeb 1/6 suite runs green; `origin/main` BridgeWeb 4/4; branch with only `bridge-comm-worker-product-controller.ts` reverted 3/3. Cause: every Review/File metadata open awaited retirement of the same-surface annotation subscription.
- [x] Owner decision: generic transport-level epoch advance (the annotation-specific cutover was bespoke). `BridgeProductTransport.advanceWorkerDerivationEpoch(surface)` replaces `bumpWorkerDerivationEpoch`: it releases every subscription admitted on the surface at an older epoch (cancel at the old epoch, awaiting only native's acknowledgement, never the drain), holds new admissions and calls on that surface until the releases land, and ends retired subscriptions with `BridgeProductSubscriptionEpochRetiredError`. Consumers choose their reaction; the annotation controller keeps comments visible as `refreshing` (with `catalogAuthorityRetired`) and reopens, so a routine refresh never shows "Updates unavailable".
- [x] Why ordering is required: native refuses any control tagged with a stale epoch (`staleDerivationEpoch` → `resync_required`). An interim non-blocking design (commit `47ddb3664`, superseded) cancelled after the advance; native refused, the worker dropped a subscription native still owned, and its next `subscription.data` poisoned the shared stream (Review metadata unavailable). Captured with temporary worker diagnostics in `bridge-viewer-vite-worker-recovery` (deterministic, ~47 s).
- [x] Generic refused-cancel safety: a stale-epoch cancel refusal keeps the subscription registered; its frames drain until native's terminal or resync reconciliation.
- [x] Proof so far: 2,397 BridgeWeb unit tests; mutation checks kill "no release", "no admission gate", "no silent drain", "no duplicate guard", and "unavailable flash"; worker-recovery, tab-ownership and annotation-system E2E 6/6 (were 6/6 failing).
- [x] `BridgeProductSubscriptionState.cancel()` settles after a prior failed operation (terminal = local no-op); a live native cancel refusal still rejects.
- [x] Test quality: drain-time and mutation-checked assertions replace a two-microtask negative proof; screenshot side effect removed; exact per-click preparation counts (the arriving candidate's automatic draft flush is intended); receipts replace Swift polling waits; title-over-subtitle search ranking; Copy E2E asserts monotonic annotation epochs; main-thread test that a routine replacement keeps threads visible.
- Correction: native `open` does not reset lower-epoch subscriptions (only resync reconciliation compares epochs); the 2026-09-13 receipt's claim to the contrary was wrong.
- Follow-up (not done): at pane startup annotations subscribe before the first metadata advance, so they are retired and reopened once (one extra round-trip before first comments; no visible flash because no catalog is current yet). Could be avoided by subscribing annotations after the first advance.

## Copy evidence and limits

The original failure occurred during the initial save/reload/Copy journey before the large stress workload. The aggregate retry separately failed Review telemetry settlement. Neither is explained merely by later passing tests.

- Isolated File save/reload/Copy: one passed, one skipped, exit 0 (`copy-focused.log`).
- Instrumented existing stress journey: one passed, exit 0 (`copy-instrumented-stress.log`); no missing-context diagnostic emitted.
- Native churn: three batches across 128 sibling files (32,768 / 65,536 / 49,152 lines), plus selected-file growth/replacement; new save, existing edit and Copy succeeded. Annotated lines stayed unchanged. This establishes observed behavior, not guaranteed timing overlap.
- Marker-scoped native evidence: `churn-native-events.jsonl`, 164 annotation lifecycle rows, with successful terminal results.
- Ungated new E2E: three real 13-file bursts and an edit, with the newest selected hash unpainted at Copy; passed with retries disabled (`copy-file-churn-corrected.log`).
- Permanent deterministic E2E: hold only the exact replacement File content request until Copy starts, then deliver real native bytes. Assert intercepted before Copy, unpainted source, and release by `output.scope.commit`. One test passed with retries disabled (`tmp/deterministic-copy-churn.log`). This proves correctness under controlled overlap, not natural failure frequency.
- The first new churn run expected the old file hash after deliberate mutation. That was a harness defect, corrected with exact current path/hash/line-count expectations; it was not a product reproduction.

Failure-only native instrumentation records source-context counts, admission validity and generation, without paths, identifiers or comment text. It remains available for recurrence. Context-lifetime tests prove a retired subscription cannot remove a newer distinct context and stale producer completion preserves replacement generation (22-test File metadata suite passes).

## Last full-gate failure

Candidate4 passed all web lanes (2,381 unit, 25 Node integration, 466 browser, one stress E2E, 27 ordinary E2E), marketing gates, and substantial native suites. It then failed initial clean-authority establishment in `DarwinSharedExactItemRealStreamIntegrationTests`' rename parameter case, before the rename operation. The fixture collapses several outcomes into nil; exact cause is unproven. No changed Core continuity code or Darwin-test semantics explain it. Read-only diagnosis: `tmp/2026-09-13-native-authority-gate-diagnosis.md`. One focused reproduction is authorized before the next full gate; no authority rule, timeout or assertion is weakened.

The unchanged focused observer suite subsequently passed: three tests, including the three replacement parameter cases, exit 0 (`native-authority-focused.log`). This is a passing isolated recheck, not proof of the aggregate failure's cause or a repair. The next full run remains required.

Candidate5 passed all web lanes again, then exposed a race in the existing projector shutdown test: it released its provider immediately after spawning shutdown, without waiting for cancellation. The fixture now observes cancellation before release and drains a critical collector through a post-shutdown topology marker instead of 300 yields. Runtime code and zero-event assertions are unchanged. All 68 projector tests pass (`projector-shutdown-order-green.log`). Candidate6 validates the complete repaired test set.

## File-change behavior

Without an editor, load the new source automatically. While editing, keep the displayed source and draft until the user chooses Update or finishes/cancels editing. Update first prepares the existing editors, installs only the still-current candidate and never silently changes stored annotation anchors.

The existing preparation contract refuses an empty unpersisted composer. Update does not discard it; finish/cancel is required before retry. A failed preparation keeps the old document and draft. This is distinct from a committed comment save.

Browser visual: `tmp/bridgeweb-file-change-floating.png`. The older yellow banner screenshots are rejected-design evidence.

## Explicit follow-up PR

- [ ] Markdown same-worktree PNG/JPEG/GIF/WebP images, automatically loaded remote HTTPS images, and clickable HTTP(S) links. Owner explicitly chose a separate follow-up because implementation is unfinished.

Retain markdown-exit and existing source-map/layout ownership. Local transport direction: one batch authorization query, typed per-image descriptors and existing raw content streams; contained paths, bounded immutable reservations, four concurrent opens. No ASMI binary envelope, generic resource route or new cache. Draft design: `tmp/2026-09-13-markdown-resource-transport-comparison.md`; earlier ASMI proposal is superseded. Unimplemented contract-test draft is outside the compiled test tree at `tmp/BridgeProductMarkdownImageContractTests.swift.pending`.

## Evidence and runtime

Primary evidence directory: `tmp/debug-workflows/2026-09-13-annotation-drawer/`. Search evidence: `tmp/debug-workflows/2026-09-13-ipc-search/`. Initial investigation and preserved history are in the primary directory (`debug-investigation.md`, `todo-history.md`).

Native cutover save/edit proof used Debug 371p PID 77611 and marker `debug-observability-371p-1789333150-76598`; `epoch-native-events.jsonl` records save, delivery, validation, install and paint. That process was identity-checked and gracefully replaced. Current verified candidate: PID 94264, marker `debug-observability-371p-1789341531-93114`, launched by LaunchServices using the isolated 371p root. `mise run build` exited 0 (`final-debug-build-5.log`); marker-scoped `mise run verify-debug-observability` passed (`final-debug-observability.log`). Reverify PID before future UI actions.

Parent owns integration, native proof and the final verdict. All writers are frozen; the validation operator is checking combined-main File/Review WebKit readiness before the next aggregate. The running Debug app and its native proof predate main integration. No claim of stable readiness until the required current-candidate gates and native verification complete.

## Main integration

Main advanced to `b52a75a92` (PR #344) while this patch was developed. It introduces repository observation lifetimes, scoped topology and reload-retirement safeguards. Read-only preflight found no design contradiction: keep main's current structure, port only missing initial-worktree registration into `WorkspaceCacheCoordinator+TopologyIngress.swift`, remove the redundant `+Discovery.swift`, and retain the annotation subscription factory alongside main's worker-test-support import. Preserve the patch in a local checkpoint before merging. Candidate6 failed native Review metadata readiness; do not repair obsolete fixtures blindly before this integration. All web lanes and the rebuilt native floating-control proof passed on the pre-integration candidate.

The port now uses main's topology ingress owner. Strengthened integration tests record exact effect batches while forwarding into the real surface coordinator: two tests failed with four expected issues before the port, then both passed. All 50 nearby coordinator tests passed, exit 0; scoped formatting and diff checks passed. Receipts: `tmp/main-topology-port-proof.md`. The tests cover immediate unscanned-main registration, the complete newly discovered linked-worktree family, and duplicate-free replay.

## Follow-up (owner, 2026-09-25): turn- and time-based diffs, Cursor-style
- Want: show only the changes from the last agent turn, or from the last N hours.
- Decision: a **separate later project**, with its own requirements, spec and review. It is outside the Bridge stability boundary.
- Groundwork done now: the File filter's wire contract uses a general `changes(baseline, kinds)`, where baseline is `uncommitted | originDefaultMergeBase`. It can be extended with `commit(oid)` without a wire break.
- Likely shape:
  - capture worktree checkpoints as git commit objects (write-tree + commit-tree) under a private ref such as `refs/agentstudio/checkpoints/*`;
  - Review can then compare against them through the existing `WorkspaceReviewContributionTarget.commit(oid:)`;
  - the File filter uses the same files-only diff;
  - comment version records store the checkpoint oid.
- New work: checkpoint capture and retention/GC, turn-boundary hooks from agent sessions (unverified whether they exist), and a "last N hours" lookup.
