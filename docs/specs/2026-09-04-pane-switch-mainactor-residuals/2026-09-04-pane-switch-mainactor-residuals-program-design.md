# Pane And Tab Switching Without MainActor Stalls — Program Design

Date: 2026-09-04

Program Design identity: `PD-2026-09-04-PANE-SWITCH-MAINACTOR-RESIDUALS`

Requirements: [REQ-2026-09-04-PANE-SWITCH-MAINACTOR-RESIDUALS](2026-09-04-pane-switch-mainactor-residuals-requirements.md)

Specification: [SPEC-2026-09-04-PANE-SWITCH-MAINACTOR-RESIDUALS](2026-09-04-pane-switch-mainactor-residuals-specification.md)

## How the system works

A switch writes selection state through the existing pane focus executor. The
Repo Explorer command-presentation batch observes only the facts that decide
capabilities for the rows currently presented, wakes at most once per MainActor
turn, and refreshes at most once per wake. Sidebar content updates that change
no geometry rebind only their changed rows and leave the scroll offset alone.
The presentation coordinator republishes the visible snapshot only when the
snapshot or its consumer changed. One test lane mounts the real composition on
a store bound to the test core atoms, performs switches, and counts refreshes
and applies. The batch no longer tracks which panes belong to which worktree:
capability resolution never reads that, so the whole-workspace lookup is
deleted rather than narrowed.

```text
user switch
  |
  v
PaneTabViewController.handlePaneFocusTrigger           [focus owner]
  -> PaneFocusOrchestrator.decide
       content click: already active -> .keep            UNCHANGED
       drawer tap:    already active -> .keep            CHANGED (was re-select)
  -> PaneFocusExecutor.apply -> selectPane / selectDrawerPane
  -> WorkspaceTabLayoutAtom.setActivePane                UNCHANGED (equal writes
                                                          already suppressed)
  |
  | AtomFamilySlot willSet on tracked keys only
  v
RepoExplorerCommandPresentationBatch                    [command presentation owner]
  -> one pending wake per MainActor turn                 ADDED coalescing
  -> refresh: tracked reads = active tab, its active pane and zoom,
              management layer, visible repos/worktrees, progress, prefs
                                                        CHANGED (was all tabs × panes)
  -> resolve only affected requests; publish delta if changed   UNCHANGED
  |
  v
SidebarSurfaceHost -> RepoExplorerView -> RepoExplorerPresentationHostView
  -> Coordinator.update republishes only on snapshot or consumer change
                                                        CHANGED
  -> RepoExplorerTableMaterializer.apply
       content-only plan: reload changed rows, keep offset   CHANGED
       height/membership plan: frame, layout, anchor         UNCHANGED
```

No atom, store, event, coordinator, queue, persisted state, command, or IPC
method is added. The `armedTrackingGeneration` guard and `wake_trigger`
attribute from #323 remain.

## What is wrong in the current structure

1. `RepoExplorerCommandPresentationBatch.observeApprovedCapabilityFacts`
   (`Sources/AgentStudio/App/Windows/RepoExplorerCommandPresentationBatch.swift:373-416`)
   calls `WorkspaceLookupDerived.paneLocationsByWorktreeId`, which iterates
   every tab and every pane in the workspace and validates each association
   (`Sources/AgentStudio/Core/State/MainActor/Atoms/WorkspaceLookupDerived.swift:7-19`),
   then assembles a whole `Tab` per location through
   `WorkspaceTabLayoutDerived.tab(_:)`. The tracked read set is therefore the
   whole workspace: any pane, tab, or arrangement write anywhere wakes a
   refresh, and each refresh recomposes arrangement state for every presented
   tab. Live burst sample: 1,488 of 2,166 refresh samples in this function.
2. Every `onChange` wake schedules its own `Task`; N writes in one turn produce
   N refreshes (`RepoExplorerCommandPresentationBatch.swift:157-162`).
3. `PaneDrawerFocusDecider.decide` returns `.selectDrawerPane` for every
   `.selectPane` trigger with no already-active check
   (`Sources/AgentStudio/Core/PaneFocus/PaneDrawerFocusDecider.swift:9-15`),
   while `PaneContentClickFocusDecider.decide` keeps when
   `context.targetPaneIsAlreadyActive`
   (`Sources/AgentStudio/Core/PaneFocus/PaneContentClickFocusDecider.swift:18-26`).
4. `RepoExplorerTableMaterializer.apply` updates the table frame before every
   plan, `endUpdates` forces two layout passes and rebinds every represented
   cell, and `restore(anchor:)` scrolls and forces two more passes even for a
   content-only plan (`Sources/AgentStudio/Features/RepoExplorer/RepoExplorerTableMaterializer.swift:246-296,437-458,464-497`).
   12:21 production sample: 800 of 4,731 main-thread samples, 610 in
   restoration.
5. `RepoExplorerPresentationHostView.Coordinator.update` republishes
   `currentVisibleSnapshot` on every SwiftUI update
   (`Sources/AgentStudio/Features/RepoExplorer/RepoExplorerPresentationHostView.swift:136-150`).
   The batch's accept guard already rejects an equal snapshot, so the cost is
   upstream: `RepoExplorerView.updateSidebarVisibleWorktrees` runs on every
   update, writing `sidebarVisibleWorktreesRuntime` and invoking the sidebar
   callbacks (`RepoExplorerView+VisibleRows.swift:89-96`).
6. No test mounts `SidebarSurfaceHost` with a store bound to the core atoms;
   the parked probe built a standalone `WorkspaceStore()` while
   `RepoExplorerProjectionInputCapture` reads `CoreAtomScope.store`, so the
   projection saw an empty topology and the batch never engaged.

The rest remains authoritative: the pane focus decision model and executor,
`AtomFamily`/`@Observable` equal-write suppression, `WorkspaceTabArrangementAtom`
write path, the projection worker, `RepoExplorerMaterializationHost` generation
and transaction ownership, `RepoExplorerNativeTransactionApplier`, the native
plan builder's `content` versus `membership` classification, and #323.

## The structural crux and selected tradeoff

The crux is whether the batch needs per-worktree pane-location facts at all.
Today it recomputes them from the whole workspace on every wake to decide which
worktree requests to re-resolve. Capability resolution for every request the
sidebar makes (`AppCommandDispatcher.repoExplorerCommandPresentationSnapshot`
→ `appCommandRouter.canExecute` / `PaneTabViewController.repoExplorerCommandCapabilities`
→ `WorkspaceCommandValidator.validate` over `actionStateSnapshot()`) reads
only global facts: the active tab, its active pane, that tab's zoom
presentation, the management layer, and repository/worktree membership
(`PaneTabViewController.swift:4051-4115,4356-4380`, `ActionValidator.swift:231-237`).
Pane-to-worktree association never changes a capability result; rows that
show pane locations are produced by the projection worker, not by the batch.

| Alternative | Structure | Gain | Cost and failure mode | Decision |
| --- | --- | --- | --- | --- |
| Keep whole-workspace lookup, add capture equality | Recompute, compare, skip resolve | Fewer resolutions | Recompute is the cost (~1 ms); wakes and cost unchanged; R3 unmet | Rejected |
| Presented-location tracking | Materializer forwards presented rows' pane destinations; batch reads per-key slots for those locations | Bounded tracked set | Adds a snapshot field and a read path for facts no capability reads; more mechanism than the obligation needs | Rejected (deletion preserves every requirement) |
| Delete location facts; track global capability inputs only | Fingerprint = active tab, its active pane, its zoom presentation, management layer; visible repo/worktree slots, progress, favorites, prefs as today; coalesce wakes per turn | No whole-workspace scan; unpresented pane/tab writes never wake; refresh cost O(visible rows) for request assembly only | Association moves no longer force re-resolution of worktree requests (they never changed results); one existing test encodes the old heuristic and is rewritten to assert quiet | Selected |
| Move command presentation off MainActor | New actor computing capabilities | Removes cost from MainActor entirely | New owner, new actor boundary for MainActor-only dispatcher state; outside acceptable complexity | Rejected |
| Debounce refreshes on a timer | Timer-coalesced refresh | Fewer refreshes under bursts | Adds latency to real capability changes; timer is a mechanism the spec forbids as sole fix; ordering not preserved | Rejected |

The selected design removes mechanism: `LocationCapabilityFacts`,
`paneLocationsByWorktreeId` in the batch, and whole-`Tab` assembly are deleted.
Revisit only if a sidebar request ever gains a capability that depends on a
specific pane's location; the proof seam below fails first.

## Component ownership and dependency direction

| Component | Owns | Consumed by | Changes when |
| --- | --- | --- | --- |
| `PaneDrawerFocusDecider` | Selection, responder, runtime decision for drawer triggers, including the already-active keep rule | `PaneFocusOrchestrator` | Drawer focus policy changes |
| `PaneFocusExecutor` | Applying decisions to store, responder, runtime | `PaneTabViewController` | Focus effect ownership changes |
| `RepoExplorerTableMaterializer` | Table transaction, content-only classification, geometry and anchor policy, viewport publication | `RepoExplorerMaterializationHost` | Table cost or viewport policy changes |
| `RepoExplorerVisibleWorktreeSnapshot` | Visible worktrees, repositories, settled receipts, target (unchanged) | Materializer, coordinator, batch | Presented-set contract changes |
| `RepoExplorerPresentationHostView.Coordinator` | Bridging SwiftUI updates to the host; last-published snapshot and consumer token | `RepoExplorerView` | SwiftUI bridging changes |
| `RepoExplorerCommandPresentationBatch` | Tracked read set = global capability inputs plus visible repo/worktree keys, per-turn wake coalescing, tracking generation, resolution, publication, telemetry | `SidebarSurfaceHost` | Capability presentation policy changes |
| `SidebarSurfaceHostSwitchGuardTests` (lane) | Mounted composition, bound store, switch workload, refresh and apply counts | `mise run test` | Guard bounds change |

Allowed dependency direction:

```text
Core pane focus deciders -> App executor -> Core atoms
Features/RepoExplorer materializer -> visible snapshot (unchanged) -> App batch -> Core atoms per key
App sidebar host -> Features RepoExplorer view -> coordinator -> host/materializer
Tests -> App composition + Core test atoms
```

Forbidden edges:

- The batch must not iterate all tabs or all panes and must not assemble a
  `Tab`; it reads the active tab id, that tab's active pane and zoom slots, the
  management layer, and slots keyed by visible worktrees and repositories.
- The coordinator must not call the batch directly; it publishes through the
  existing closures only when snapshot or consumer token changed.
- Deciders must not read atoms; already-active facts come from
  `PaneFocusContext`.
- No timer, poll, or new observer anywhere in this design.

## Behavioral interfaces

### Drawer selection idempotence

`PaneDrawerFocusDecider.decide(.selectPane(parentPaneId, drawerPaneId))`
returns `selection: .keep` when `context.activeDrawer?.parentPaneId ==
parentPaneId && context.activeDrawer?.paneId == drawerPaneId`. Responder and
runtime actions for that case are the same as today's `.selectDrawerPane`
outcome (`.focusPaneHost(paneId: drawerPaneId)`, `.preserveRuntimeFocus`), so
focus reconciliation is unchanged and only the selection write disappears.
`PaneFocusExecutor.apply` is unchanged; `.keep` already writes nothing.

### Bounded tracked reads in the batch

`observeApprovedCapabilityFacts` and `LocationCapabilityFacts` are deleted.
`CapabilityFactsFingerprint` becomes:

```text
activeTabID:            store.tabLayoutAtom.activeTabId
activePaneID:           cursor atom active pane of the active tab's active
                        arrangement (per-key slot; nil when no active tab)
activeTabZoom:          store.panePresentationAtom.zoomPresentation(forTab: activeTabID)
isManagementLayerActive: atom(\.managementLayer).isActive
```

`globalCapabilitiesMatch` compares all four; when any differs every request is
re-resolved (today's behavior for active tab and management layer, extended to
the two facts `actionStateSnapshot()` also feeds). `changedWorktreeIDs` no
longer exists; the surviving-visible request set is re-resolved only on
global change, on visible-set delta, on repository progress change, or on
favorite change, exactly as today for those triggers. Visible-repo progress,
topology worktree/repo slots, favorite state, and prefs sort order remain
tracked per key. The batch never calls `paneLocationsByWorktreeId` or
assembles a `Tab`.

Why this is complete: every sidebar request is worktree-, repo-, or
toolbar-targeted (`RepoExplorerCommandPresentation.swift:172-334`); their
capability results derive from `WorkspaceCommandValidator.validate` over
`actionStateSnapshot()` plus `targetedAction`, which read only the active
tab, its active pane, its zoom presentation, management layer, and
repo/worktree membership. Proof seam: a test that mutates each of those five
facts asserts re-resolution, and a test that moves a pane association
between two visible worktrees asserts no re-resolution and unchanged results
(replacing "association move resolves only affected visible worktree rows").

### Per-turn wake coalescing

The batch keeps `pendingObservationRefresh: Bool`. `onChange` (generation
checked as in #323) sets it and schedules one `Task { @MainActor }` only when
it was false; the task clears it and calls `refresh(trigger: .observation)`.
A wake arriving while a refresh is pending folds into it. A wake arriving
during a running refresh schedules the next one. Ordering is preserved because
refresh always reads current atom state.

### Content-only application policy in the materializer

`apply` classifies the plan before mutating:

- `membership` or `content` with non-empty `heightReloadRowsInNewSpace`, or
  any reload row whose new `layout.requiresVisibleWidthMeasurement` is true:
  `requiresGeometryUpdate = true` (today's behavior: frame update, forced
  layout passes, height notes, anchor restoration, rebind all represented).
- otherwise `requiresGeometryUpdate = false`: no `updateTableFrame`, no forced
  layout pass, no anchor restoration; `endUpdates` reloads only the represented
  intersection of `reloadRowsInNewSpace`, rebinds only those rows, and stamps
  the readback for the represented set.

Counters `tableFrameUpdateCount`, `forcedLayoutPassCount`,
`explicitScrollRestorationCount` become `private(set)` observables for proof.
Width-measured rows are conservative: a changed row that requires visible
width measurement is treated as height-affecting.

### Coordinator republication

`Coordinator.update` receives `visibleSnapshotConsumerToken: UUID?` (the batch's
identity, passed by `SidebarSurfaceHost` through `RepoExplorerView`). It
republishes `currentVisibleSnapshot` only when the snapshot differs from
`lastPublishedVisibleSnapshot` or the token differs from
`lastPublishedConsumerToken`; both are updated on publish. Materializer-driven
publications continue to flow immediately through `publishVisibleWorktreeSnapshot`.
`applyCommandPresentationDelta` is called as today.

### Switch guard lane

`SidebarSurfaceHostSwitchGuardTests` (App/Windows tests) constructs the store
as `WorkspaceStore(catalogAtom: atoms.workspaceRepositoryTopology, graphAtom:
atoms.workspacePane, interactionAtom: atoms.workspaceTabLayout)` inside
`withAsyncTestCoreAtoms`, adds three repositories, two tabs and three panes
bound to worktrees, mounts `SidebarSurfaceHost` in a window, waits for the
first `command_presentation` record (engagement gate), performs one active-pane
switch and one tab switch, pumps bounded yields, and asserts refreshes per
switch ≤ 2 and materializer applies per switch ≤ 1 from the JSONL recorder and
`nativeTransactionApplyCount`. It runs in the fast Swift lane, therefore in
`mise run test`. A seeded regression (temporarily restoring per-update
republication) must fail it.

## State and lifecycle

Runtime-only state changes:

| State | Owner | Transition | Guard |
| --- | --- | --- | --- |
| `pendingObservationRefresh` | batch | false → true on wake; true → false when the refresh task starts | generation check precedes |
| `armedTrackingGeneration` | batch | unchanged from #323 | |
| `lastPublishedVisibleSnapshot`, `lastPublishedConsumerToken` | coordinator | set on publish | publish only on difference |
| drawer selection | arrangement atoms | unchanged; `.keep` performs no write | already-active predicate |

No persisted state changes. Illegal transitions: a refresh scheduled by a
stale generation is dropped (existing); a republish with an unchanged snapshot
and token is dropped (new); a content-only plan that later measures a height
change is not possible because width-measured rows are classified as
height-affecting.

## Current-to-proposed call-path deltas

```text
1. Drawer tap on the active drawer pane

CURRENT
PaneLeafContainer.onTapGesture -> handlePaneFocusTrigger(.drawer(.selectPane))
  -> PaneDrawerFocusDecider.decide -> .selectDrawerPane        REMOVED for active target
  -> PaneFocusExecutor.applySelection -> selectDrawerPane
  -> WorkspaceTabArrangementAtom.setActiveDrawerPane           REMOVED for active target
  -> responder .focusPaneHost                                   UNCHANGED

PROPOSED
  -> PaneDrawerFocusDecider.decide -> .keep                     CHANGED
  -> responder .focusPaneHost                                   UNCHANGED
Evidence: PaneDrawerFocusDecider.swift:9-15; PaneFocusExecutor.swift:106-128.
Result: no selection write, no coordinator write, no wake.
```

```text
2. Tracked-atom write -> batch refresh

CURRENT
AtomFamilySlot.acceptValue (any pane/tab/arrangement key)
  -> willSet -> batch onChange -> Task -> refresh                N tasks for N writes
  -> observeApprovedCapabilityFacts
       -> paneLocationsByWorktreeId (all tabs × all panes)       REMOVED
       -> WorkspaceTabLayoutDerived.tab per location (compose)   REMOVED
  -> resolve/publish                                              UNCHANGED

PROPOSED
AtomFamilySlot.acceptValue (presented key only wakes)
  -> willSet -> batch onChange -> generation check                UNCHANGED (#323)
  -> pendingObservationRefresh gate -> one Task per turn          ADDED
  -> refresh -> four global per-key reads + visible repo/worktree slots   CHANGED
  -> resolve/publish                                              UNCHANGED
Evidence: RepoExplorerCommandPresentationBatch.swift:120-165,373-416;
WorkspaceLookupDerived.swift:7-19; live sample /tmp/agentstudio-storm-loop-4.sample.txt.
Result: pane/tab/arrangement writes outside the active tab's active pane, zoom, or
tab id wake nothing; a switch wakes at most one coalesced refresh.
```

```text
3. Content-only sidebar update

CURRENT
materializer.apply -> updateTableFrame -> applier -> endUpdates
  -> layoutSubtreeIfNeeded ×2 -> reloadData(visible) -> rebindRepresentedCells
  -> restore(anchor) -> scroll -> layoutSubtreeIfNeeded ×2       REMOVED for content-only

PROPOSED
materializer.apply -> classify plan
  content-only: applier -> endUpdates -> reloadData(changed ∩ represented)
                -> rebind changed rows -> stamp readback           CHANGED
  geometry:     today's path                                       UNCHANGED
Evidence: RepoExplorerTableMaterializer.swift:246-296,437-497.
Result: scroll offset preserved; counters stay flat for content-only plans.
```

```text
4. SwiftUI update of the presentation host

CURRENT
updateNSView -> Coordinator.update -> onVisibleWorktreeSnapshotChange(current)   REMOVED when unchanged
  -> applyCommandPresentationDelta                                               UNCHANGED

PROPOSED
updateNSView -> Coordinator.update
  -> publish only if snapshot != lastPublished || token != lastToken            CHANGED
  -> applyCommandPresentationDelta                                               UNCHANGED
Evidence: RepoExplorerPresentationHostView.swift:136-150; SidebarSurfaceHost.swift:73-111.
Result: a new batch still receives the current snapshot once; steady updates publish nothing.
```

```text
5. Switch guard lane (proposed-only, no predecessor)

withAsyncTestCoreAtoms -> bound WorkspaceStore -> repos/tabs/panes
  -> NSHostingView(SidebarSurfaceHost) in NSWindow -> engagement gate
  -> setActivePane / setActiveTab -> bounded yields -> JSONL counts
Evidence: parked probe (scratchpad) failed only because the store was unbound;
RepoExplorerViewActivePaneFocusTests.swift:30-41 shows the bound-store form.
Result: fails on refreshes per switch > 2, applies per switch > 1, or no engagement.
```

## Failure, recovery, and partial success

| Condition | Detection | Containment | Recovery | Observable |
| --- | --- | --- | --- | --- |
| A future sidebar command depends on a pane-location fact | Proof seam test mutating each tracked fact plus the association-move quiet test | Fingerprint miss → stale presentation until next global change | The design is revisited; the seam fails before release | Test failure, not runtime corruption |
| Content-only misclassification (height actually changed) | Conservative rule on width-measured rows; height cache | Row re-measured on next geometry plan | Existing `noteHeightOfRows` path | Visible only as a one-frame height lag, bounded |
| Coordinator token missing (batch nil) | `nil` token | Publish once when the batch appears (token changes nil → id) | Existing lifecycle | Batch receives snapshot exactly once |
| Wake during refresh | `pendingObservationRefresh` | One follow-up refresh | Same path | No lost update |

## Concurrency and consistency

All owners are MainActor. Ordering: atom writes are synchronous; the batch's
single pending task runs after the current turn, reading current state, so
coalescing never observes a torn intermediate. The materializer publishes
viewport changes through its existing sequence/cancellation. No new actors,
locks, or async boundaries.

## Compatibility and cutover

Hard internal cutover, runtime-only. No persisted, IPC, command, or schema
change. Rollback is code-only. #323 stays.

## Cross-cutting realization

| Obligation | Owner and mechanism | Degradation | Proof seam |
| --- | --- | --- | --- |
| Performance R1/R2/R3/R5 | Global-only fingerprint, per-turn coalescing, content-only policy, republish suppression | None beyond one coalesced refresh per turn | Refresh and apply counts per switch; materializer counters; tab-bar queue wait |
| Responsiveness | Same | Same | Debug-app switch workload, production comparison |
| Observability R8 | `wake_trigger` (#323) plus existing stage snapshots | Fail-open exporter | OTLP projection test; VictoriaLogs by service.version |
| Reliability R9 | No persisted change | — | Install/downgrade round trip |
| Privacy | No new attributes with paths or content | — | Attribute allowlist |
| Accessibility | No UI change | — | Existing focus tests |

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

## How each requirement is realized and verified

| Requirement | Realization | Proof seam | Enforcement |
| --- | --- | --- | --- |
| R1 switch budget | Deltas 1–4 together | Tab-bar queue wait in debug workload and production | Runtime measurement |
| R2 refreshes per switch bounded, age-invariant | #323 generation + per-turn coalescing + global-only fingerprint; one switch = at most one snapshot refresh (one viewport publication) plus one coalesced observation refresh | Lane counts after 200 prior publications | Lane test |
| R3 unpresented facts no refresh | Global-only fingerprint plus per-key visible repo/worktree slots | Test: write to a pane/tab outside the active selection → 0 observation refreshes; active-pane change or visible-repo progress → 1 | Batch unit test |
| R4 re-selection no-op | Drawer decider keep rule | Decider test + executor test: no write, no refresh | Unit tests |
| R5 content-only cost | Materializer classification | Counters flat, offset unchanged, only changed rows rebound | Materializer tests |
| R6 republish suppression | Coordinator token + last-published | Host view test: N identical updates → 0 publications; new token → 1 | Host view test |
| R7 gate lane | Switch guard lane in fast Swift lane | Seeded regression fails | `mise run test` |
| R8 telemetry | #323 | Projection test (exists) | — |
| R9 compatibility | No persisted change | Round trip | Manual |
