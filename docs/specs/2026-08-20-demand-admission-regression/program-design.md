# Demand Admission Regression — Program Design

Requirements: [requirements.md](requirements.md)
Specification: [specification.md](specification.md)

## Integrated Design

The repair keeps the existing domain owners and moves every reduction gate in front of the boundary it is intended to protect. Repo Explorer becomes demand- and key-scoped before it captures. Terminal keeps raw callback contraction in its existing source owners and publishes one deferred latest pane-status fact. Forge keeps request execution private and publishes one current repository presentation projection. `EagerDerivedAtom` becomes true one-active/one-pending execution rather than overlapping cooperative cancellation.

```text
Ghostty callback
  -> GhosttyActionDisposition                       existing source owner
  -> TerminalLocalActionAccumulator / projector    fixed-key contraction
  -> PaneActivityStatusAtom                        keyed latest fact + deferred latest
                                                     |
RepositoryTopologyAtom -- materialized keys --------+
RepoCacheAtom ---------- keyed Git/PR facts --------+--> RepoExplorerProjectionAdapter
workspace focus/recency - keyed demanded facts -----+      demand + invalidation owner
                                                            semantic baseline owner +
                                                            acknowledged-native-baseline broker
                                                            |
                                                            | admitted latest full/delta intent
                                                            v
                                                   EagerDerivedAtomFamily
                                                   one active/awaiting-settlement +
                                                   one latest pending intent
                                                            |
                                                            | adapter envelopes intent with
                                                            | lifetime + demand epoch +
                                                            | acknowledged native baseline
                                                            v
                                                   RepoExplorerProjectionWorker
                                                   off-main semantic result + inseparable
                                                   presentation/plan candidate envelope
                                                            |
                                                            v
                                                   complete rendered equality
                                                   lifetime/epoch/generation/baseline validation
                                                            |
                                                            v
                                                   one compact MainActor read-model binding
                                                            |
                                                            v
                                                   RepoExplorerMaterializationHost
                                                   persistent empty/content acceptance authority
                                                   + table child + viewport demand
                                                            |
                                                            | accepted-baseline acknowledgment
                                                            v
                                                   RepoExplorerProjectionAdapter
                                                   caches R or R+1; settles Eager barrier;
                                                   next pending intent is re-enveloped

App RepoExplorerCommandPresentationBatch
  -> visible-worktree generation + favorite/capability/request projection
  -> generation-validated presentation delta
  -> current represented row slots + Repo Explorer toolbar
  -> command execution re-enters AppCommandDispatcher

Forge provider task
  -> validate origin/generation/live scope before state mutation
  -> current PullRequestRepositoryProjection
  -> repository-keyed latest-state coalescing
  -> one atomic MainActor cache apply
  -> relevant Repo Explorer repository invalidation
```

The design adds no service, persistence, compatibility path, feature flag, or general admission framework.

## Current System And Constraint Degree

The system is legacy-ownership-bound, not greenfield:

- The repaired branch already moves observation, capture admission, deadlines, and publication ownership into `RepoExplorerProjectionAdapter`; paired profiling places adapter capture at about 4.6% of Main Thread CPU and the off-main worker at about 2.6% of total CPU.
- [`RepoExplorerView`](../../../Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift) still feeds the complete `rowIndex.entries` collection through SwiftUI `List` and `ForEach`. The paired source/Time Profiler evidence retained by the investigation places about 35.5% of Main Thread CPU in `OutlineListCoordinator`, 20.4% in hosting layout/render, 7.4% in repeated list-entry identity work, and 5.4% in focus-loop rebuilding.
- [`RepoExplorerVisibleRowsBridge`](../../../Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+VisibleRows.swift) discovers SwiftUI's backing `NSTableView` after materialization and reports its visible row range. It cannot prevent the earlier whole-list identity/diff/layout/focus work and makes viewport demand depend on an implementation detail it does not own.
- [`RepoExplorerListEntry.id`](../../../Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerListEntry.swift) constructs interpolated strings on repeated framework reads instead of carrying a stored typed identity produced off-main.
- `RepoExplorerProjectionAdapter` and `EagerDerivedAtomFamily` now own materialized projection state with one-active/one-pending execution; the remaining dominant cost is downstream UI materialization, not the projection worker.
- Current source has three non-interchangeable clocks. Request `generation` is admission/currentness identity; adapter `publishedRevision` advances after a changed projection publication; native materialization revision can advance only after a future AppKit transaction succeeds. Full work currently carries no baseline, delta promotion collapses to bare full work, equal completion advances the adapter's semantic baseline without advancing `publishedRevision`, and Eager starts pending work immediately after projection settlement. Therefore neither request generation nor `publishedRevision` can truthfully identify the table's accepted old state.
- `TerminalLocalActionAccumulator` and `TerminalActivityProjector` already own bounded raw-signal contraction; `PaneActivityStatusAtom` is the keyed MainActor read owner but discards changed values inside its interval.
- `ForgeActor` already owns demand, freshness, backoff, origin/generation validation, one active provider task, and one pending follow-up. `v0.0.90` exposes its loading edges as separate events and mutates success/publication baselines before final scope validation.
- `RepositoryTopologyAtom` already owns stable-key indexes, but `RepoPresentationItem.init(repo:)` recomputes path-derived keys during hot capture.
- OTLP projection and taxonomy allowlisting remain source-scrubbed. App imports `AgentStudioRepoExplorer`, whose adapter/worker/host/envelopes/child/applier remain internal. The first S6 experiment proved synchronous MainActor RunLoop pumping starved Eager's MainActor continuation (30.004 seconds, generation zero, no measurements). Two subsequent async runs proved 440 full projections cannot finish within the fixed 30 seconds and exposed unsafe cancellation teardown: crash reports `swiftpm-testing-helper-2026-08-22-152405.ips` and `...152545.ips` show main-thread `objc_release`/autorelease `EXC_BAD_ACCESS` while a user-initiated Eager detached attempt still executed `GitBranchStatus.status/merge` through `RepoExplorerProjectionWorker:451`. Current `stop` cancels but has no awaitable task-drain receipt, so fixture/work release raced the worker.

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

The AppKit/SwiftUI architecture recommends SwiftUI for dynamic lists as the ordinary implementation default, while explicitly supporting persistent `NSHostingView` instances for custom cells. The measured Repo Explorer path is the justified exception: the generic SwiftUI outline coordinator is the dominant remaining CPU owner, and the selected table retains the existing SwiftUI row components inside reused native cells rather than replacing their product presentation. This exception is feature-local and does not change the repository-wide UI default.

Changed behavior is limited to admission, state-transition order, capture shape, execution overlap, UI materialization ownership, viewport-demand publication, and proof. Existing feature presentation, commands, focus behavior, accessibility, scrolling, and domain authority remain authoritative.

## Structural Crux And Alternatives

The crux is where a source change becomes a consumer-relevant semantic invalidation.

| Alternative | Shape | Gain | Cost / failure | Decision |
| --- | --- | --- | --- | --- |
| Downstream suppression only | Keep broad observation and full capture; improve worker equality/debounce | Small edit | Still pays MainActor capture and filesystem work; cannot meet S2-S4 | Rejected |
| Producer-formatted sidebar rows | Terminal, Core, and Forge produce Repo Explorer row models | Early contraction | Moves consumer policy into sibling/domain owners and creates cross-feature coupling | Rejected |
| Consumer-owned keyed admission over existing domain facts | Domain owners publish compact facts; Repo Explorer observes only demanded keys and emits full/delta invalidations | Preserves ownership, removes work before capture, supports exact proof | More observation bookkeeping and explicit invalidation vocabulary | Selected |
| Keep SwiftUI `List` and tune IDs/focus/animations | Store row IDs, suppress avoidable focus work, and disable unnecessary animation while retaining generic outline materialization | Smallest code change; preserves current native behavior automatically | Cannot remove the measured whole-list `OutlineListCoordinator` and hosting-layout floor; the required action-CPU reduction exceeds the optimizable app-owned share | Rejected as the primary correction; stored IDs remain required hygiene |
| SwiftUI `ScrollView` + `LazyVStack` | Materialize only lazy visible/near-visible rows and publish viewport demand from row lifecycle | Small implementation surface; removes `OutlineListCoordinator` | Must recreate native table accessibility, focus/key-loop behavior, exact viewport demand, scroll anchoring, and sidebar row behavior; lazy retention makes visible demand approximate | Rejected for the first cut because UX preservation is P0 |
| Feature-owned view-based `NSTableView` | Consume immutable rows through a direct table data source, reuse hosted visible cells, apply precomputed update scope, and own the exact visible range | Removes generic outline diffing while preserving native scrolling, focus, accessibility, row reuse, and exact viewport demand | Larger feature-local AppKit boundary and cell lifecycle to maintain | Selected for UI materialization |
| New generic derived-state scheduler | Central admission/deadline/control service | Uniform mechanics | New authority/control plane, broad migration, and scope beyond the confirmed goal | Rejected |

The selected direction spends complexity in the existing adapter and persistent host. Native proof uses one async Feature facade, one normal full-path liveness transition per scale, then validated forward/reverse native-plan templates through that same host/child/applier. This preserves the fixed 30 seconds without pretending 440 full projections are native timing. RunLoop/synchronous modes, per-transaction projection, and scoped delta as an unproven drain workaround are rejected. Revisit the table only on its UX/CPU falsifiers, and a broader scheduler only if three unrelated consumers require identical policy.

## Components, Ownership, And Interfaces

```text
Repo Explorer feature
  RepoExplorerProjectionAdapter
    owns: lifetime/demand epoch, keyed invalidation, semantic baseline, current publication,
          acknowledged materialization-baseline brokerage
    consumed by: Eager execution lane, RepoExplorerView, table acknowledgment
    changes when: source admission, currentness, or baseline-broker policy changes
  RepoExplorerProjectionWorker
    owns: off-main grouping, row identity/content/index, plan and immutable template derivation
    consumed by: adapter and materialization host through one immutable candidate envelope
    changes when: derived sidebar meaning or off-main plan derivation changes;
                  never owns acceptance or increments accepted revision
  RepoExplorerNativeTablePilot
    owns: async liveness/drain, template replay, and native-only timing composition;
          consumed by App startup diagnostic; changes only with pilot composition
  RepoExplorerView
    owns: SwiftUI shell composition and filter/toolbar wiring
    consumed by: SidebarSurfaceHost
    changes when: product composition or interaction wiring changes
  RepoExplorerMaterializationHost
    owns: persistent materialization lifetime, accepted empty/content snapshot,
          visible generation/readiness, acceptance acknowledgment
    consumed by: RepoExplorerView, adapter acknowledgment
    changes when: presentation acceptance or demanded-host lifecycle changes
  RepoExplorerTableMaterializer
    owns: non-empty child transaction, visible cells, scrolling, viewport demand
    consumed by: persistent materialization host
    changes when: row transaction, scrolling, focus, or viewport policy changes
  RepoExplorerTableRowCell
    owns: one reusable native cell and persistent SwiftUI row-content slot
    consumed by: table materializer
    changes when: cell reuse/binding or row-host integration changes
App composition
  Existing startup diagnostic — owns debug selection plus outer MainActor task/await, never pilot execution
  SidebarPerformanceProofSession (DEBUG only)
    owns: one selected proof population, one outstanding action token/expected outcome,
          production-path dispatch/native input, and token-correlated settlement emission
    consumed by: startup diagnostic and external sampler/verifier through bounded telemetry
    changes when: strict performance-proof action/readback correlation changes;
                  never owns product state, commands, authorization, or CPU verdicts
  RepoExplorerCommandPresentationBatch
    owns: visible-worktree capability/favorite/request projection and generation
    consumed by: Repo Explorer toolbar and content-table child through an injected value
    changes when: App-owned command-presentation composition changes
```

Semantic projection truth remains in the adapter's latest current worker result. Visible accepted-presentation truth belongs to the persistent host's acknowledged empty-or-content baseline; it is not inferred from semantic publication. The table and cells are conditional consumers of that baseline, not another acceptance owner.

### RepoExplorerProjectionAdapter — demand, invalidation, and binding owner

`RepoExplorerProjectionAdapter` expands its existing role and removes observation lifecycle from `RepoExplorerView`.

It owns:

- one adapter lifetime identity and the registered materialization-host lifetime identity;
- the current demand epoch, advanced on every demand loss/reentry boundary;
- current surface demand and grouping mode;
- observation generation and exact observed repository/worktree/pane/tab keys;
- one bounded `RepoExplorerPendingInvalidation` accumulator;
- earliest demanded recency deadline;
- capture admission and current request generation;
- the latest current semantic delta baseline, including equal completions;
- the last host-acknowledged immutable presentation baseline;
- final validated observable result and the host-settlement barrier.

It exposes:

```text
start(demandSource, factSources)
registerMaterializationHost(lifetime, explicitEmptyBaseline | retainedBaseline)
updateDemand(surface, grouping, renderedKeys, hostLifetime)
invalidate(scope, cause)
hostDidAccept(candidateIdentity, acceptedBaseline)
hostDidReject(candidateIdentity, reason)
hostDidDetach(lifetime)
stopAndDrain() async
publishedResult
```

`invalidate` is idempotent and MainActor-fast. It unions affected keys, promotes to membership/full only when a structural input requires it, and schedules at most one capture turn. It does not build a request. If demand is absent, it retains no hot observation registrations and at most one demand-recheck invalidation; the current materialized result remains available for cache-first surface switching.

`RepoExplorerView` becomes a render/interaction consumer of `publishedResult`; it does not own polling, projection execution, or broad observation.

#### Grouping and visibility observation matrix

Membership is the bootstrap authority; rendered keys refine an already established demand set and are never required to obtain the first projection.

| Source fact family | By Repository | By Pane | By Tab | Invalidation scope |
| --- | --- | --- | --- | --- |
| sidebar surface visibility | enter: full bootstrap; leave: unregister hot facts | same | same | demand enter/leave |
| repository/worktree membership and grouping identity | observe | observe | observe | membership/full |
| repository favorite/enrichment and worktree Git/PR/loading facts | observe relevant repository/worktree keys | observe keys represented by pane rows | observe keys represented by tab pane rows | repository/worktree delta; membership/full only when grouping identity changes |
| pane-to-worktree placement and tab membership | observe because repo rows, placement, and menus consume it | observe | observe | affected worktree/repository or membership/full when placement membership changes |
| pane title, note, drawer, activity message, recency, and real-attention focus | do not observe | observe demanded pane keys | observe demanded pane keys | pane delta |
| tab display/group facts | do not observe | do not observe | observe demanded tab keys | tab delta |
| Bridge attendance/capability facts | observe only the exact repository/worktree command-presentation keys declared by the rendered row/menu model | observe exact pane-row keys when rendered | observe exact pane-row keys when rendered | affected command/row key; never implicit full capture |
| grouping, sort, search, collapsed-group inputs | observe | observe | observe | grouping/membership full, or presentation-only delta when structure is unchanged |

On first mount, hidden-to-visible transition, grouping change, or baseline loss, the adapter admits one demanded full intent. Demand loss advances epoch, revokes active/awaiting work, discards pending intent, unregisters hot facts, and cancels the recency deadline. A surviving host retains and re-acknowledges its accepted empty/content snapshot under the new epoch; a replacement host registers a new lifetime and explicit rowless R0. Rendered keys refine demand only after this bootstrap.

### RepoExplorerPendingInvalidation — bounded consumer scope

This feature-private value is either empty, affected repository/worktree/pane/tab ID sets, or membership/full; it is not a generic framework or state service. Unions preserve required scope, membership/full subsumes narrower keys, sets are bounded by current demanded topology, and loss of demand clears irrelevant keys. Its bounded diagnostic cause does not affect equality or authority.

### RepoExplorer capture — full and delta values

The adapter captures pure `RepoExplorerProjectionIntent` data: latest complete semantic request/facts, latest intent identity, affected scope, and a promotion class of full or scoped delta with structural-target key. It contains no baseline or effectful closure. Two compatible scoped intents with the same structural target union scope and keep latest facts; any incompatible target/promotion becomes the latest full intent. Baseline compatibility is decided only during execution preparation.

Eager owns one active/awaiting-settlement intent and one latest pending intent. Immediately before an intent starts execution, the adapter encloses it in a closed immutable `RepoExplorerProjectionWork`:

```text
RepoExplorerProjectionWork
  common:
    adapterLifetime
    materializationHostLifetime
    demandEpoch
    requestGeneration
    acceptedMaterializationBaseline(
      hostLifetime, demandEpoch, revision, presentationKind,
      rowCount, membershipFingerprint, immutablePresentationSnapshot
    )
    proposedChangedRevision = acceptedMaterializationBaseline.revision + 1

  full(common, completeCapture)

  delta(
    common,
    semanticBaseline(sequence, immutableProjectionResult),
    latestFactsByAffectedKey,
    affectedScope
  )
```

The native and semantic baselines are deliberately different. `RepoExplorerMaterializationHost` is authoritative for accepted empty/content presentation because it alone spans every visible state and knows its child update completed. The adapter caches its immutable acknowledgment and separately owns the latest current semantic result; every validated completion, including rendered-equal work, advances semantic sequence without necessarily consuming native revision.

The worker reads no mutable UI state. Pending delta merge is valid only when adapter/host lifetime, demand epoch, acknowledged baseline identity, and semantic baseline sequence/result match; it unions scope and retains latest facts. Structural invalidation, mismatch, removal, or unsupported combination promotes to full while retaining the acknowledgment; promotion never becomes a bare request.

Worker completion returns a complete semantic result and presentation candidate. Publication validates adapter/host lifetime, epoch, generation, baseline revision/count/fingerprint, and delta semantic sequence. Mismatch cannot become Eager equality/value state and re-arms one full intent from the current acknowledgment.

Full capture reads only current demanded keys. Delta capture reads only accumulated affected keys. Both consume already-materialized stable keys and domain facts. Neither invokes `StableKey.fromPath`, filesystem APIs, Git, SQLite, process, or network work.

`RepositoryTopologyAtom` remains the stable-identity read owner, but it never produces identity by touching a path. Topology admission carries explicit immutable repository/worktree stable-key facts alongside the admitted models. Persistence hydration supplies the existing stored stable keys; filesystem/runtime discovery canonicalizes and hashes paths before crossing to MainActor. `RepositoryTopologyReplacement` validates the supplied identity maps against model IDs, and the atom stores both `stable key -> ID` and `ID -> stable key` indexes from those facts. `RepoPresentationItem` receives the stored value explicitly. No persistence schema changes, and `StableKey.fromPath` is forbidden in hot capture and MainActor topology-index rebuild.

### EagerDerivedAtom and EagerDerivedAtomFamily — one closed shared interface

The current concrete-`Request`, commit-before-callback API is replaced by one generic behavioral shape:

```text
EagerDerivedAtom<Intent, IntentIdentity, Work, Candidate, Value>
  admit(Intent)
  prepare(Intent, revocationEpoch) -> prepared(Work) | rejected(outcome)
  project(Work) off-main -> Candidate
  classify(Candidate, current Value?) ->
    equalCurrent(Value) | changedAwaitingOwner(Value) |
    immediateAccepted(Value) | rejected(revoked | stale | failed)
  onAwaitingOwner(candidateToken, Candidate, proposed Value)
  settle(candidateToken, accepted(Value) | rejected(outcome)); stopAndDrain() async
```

`admit` assigns identity/generation and stores or purely combines only the latest pending `Intent`. When the lane may start, the owner-provided MainActor `prepare` converts that intent to immutable `Sendable Work` from then-current baselines; rejection is terminal for that attempt and starts no task. `project` returns `Candidate` without mutating value, latest-accepted value, readiness, equality, or revision. Configured behavior functions live once on the primitive; Intent/Work/Candidate store no effectful closures.

After validation, equal commits latest-accepted/current readiness without revision; immediate acceptance commits changed value/current readiness/revision. Awaiting-owner mints one opaque token, stores Candidate/proposed Value, invokes the configured owner callback, and stays unsettled. `settle` accepts only that token: acceptance commits proposed state; rejection retains stored value but leaves admitted identity invalidated/not-ready, then prepares pending Intent or reports terminal outcome. Late/duplicate tokens are controlled no-ops.

Demand revocation keeps its existing semantics. `stopAndDrain()` first performs idempotent terminal revocation: reject pending/awaiting, cancel every active attempt, and forbid later publication. The atom retains its task, captured Work/Candidate, terminal identity, and every checked-continuation drain waiter until all detached attempts terminate and MainActor completion bookkeeping runs; it then clears retained state and resumes every waiter exactly once. Repeated stop/drain calls share that terminal state. Family `removeAndDrain(for:)` removes readiness immediately but retains the slot/atom until its drain completes; family `stopAndDrain()` drains every snapshot slot before release. No polling, sleep, leak, unstructured cleanup, or late publication is permitted; Repo Explorer and Tab Bar must preserve their current equality/readiness behavior across stop/removal.

Repo Explorer maps `Intent` to the pure schema above; `prepare` adds current semantic/native baselines and promotes incompatible scoped intent to full. Its classifier returns equal-current, changed-awaiting-owner, or rejected. Newer intent before host apply revokes the candidate; synchronous host apply cannot interleave on MainActor.

Tab Bar maps the same interface to latest-complete Intent, preparation to its existing complete request, and projection Candidate to `TabBarProjection`. Equality returns `equalCurrent`; change returns `immediateAccepted`. Per-key readiness appears only after settlement, equal work preserves value/revision, the aggregate publishes only when every ordered tab is ready, changed aggregate publication remains suppressed when equal, and a partial tab list is never published.

### RepoExplorerProjectionWorker — off-main structural derivation

The worker retains grouping, branch/status merging, row construction, row indexing, cancellation checkpoints, and reference projection. It accepts full or delta input. Delta application returns a complete immutable result while preserving unchanged row values and stable IDs.

Rendered equality has one source: the complete immutable rendered row model consumed by the view. The parallel incomplete `RepoExplorerRenderedRowContent` comparator is removed. Equality includes every visible field in the current grouping. An equal completion therefore proves R-INV against the same values the view renders.

The worker also prepares the complete materialization payload consumed after publication. At changed-owner handoff the broker adds the opaque delivery identity without copying or altering the worker result, producing one inseparable feature-private envelope:

```text
RepoExplorerMaterializationCandidate
  candidateIdentity
  adapterLifetime + materializationHostLifetime
  demandEpoch + requestGeneration
  complete immutable presentation
    rowless(typed empty state) |
    content(snapshot: rows + row/index/worktree/repo maps + fingerprint)
  exact worker-derived RepoExplorerNativeUpdatePlan
```

The envelope is the only host-delivery value. The broker may validate it against the current adapter and acknowledged host baseline, but must not strip, derive, rebuild, substitute, or separately store its plan. Candidate identity and the plan therefore settle as one unit; no presentation can reach the host without the exact plan derived from its acknowledged baseline.

`RepoExplorerRowID` is a stored typed identity assembled from existing section/group/repository/worktree/pane identities. It includes a typed unresolved/topology-fault identity; the existing adapter comparator's `unresolved(String)` mechanically becomes `unresolved(RepoExplorerRowID)` rather than converting the new identity back to an interpolated string. The worker computes row identities, ordering, stable layout classes, fixed metric inputs, row-index maps, repo/worktree occurrence indexes, content revisions, and the complete native update plan off-main. MainActor does not compare, hash, sort, or diff the row fleet. Width-dependent text measurement is deliberately excluded from the worker and is bounded to represented visible rows by the table owner below.

Typed identity and fleet-work removal become one complete architecture boundary only at the hard UI cutover. An intermediate typed-ID contract may compile while the old SwiftUI `List` and its MainActor previous/next ID arrays still exist, but that slice is not green for S14 or the performance objective. The cutover removes those fleet arrays with the old container; the typed-ID slice must not claim the MainActor prohibition early, and the final slice must not leave the arrays for later cleanup.

### RepoExplorerNativeUpdatePlan — exact native transaction

The worker emits one closed discriminated value; the planner does not choose diff or index semantics:

```text
equal(
  lifetime, demandEpoch, requestGeneration,
  oldRevision R, newRevision R, count, membershipFingerprint
)

content(
  lifetime, demandEpoch, requestGeneration,
  oldRevision R, proposedRevision R+1,
  unchangedCount, membershipFingerprint,
  reloadRowsInNewSpace, heightReloadRowsInNewSpace
)

membership(
  lifetime, demandEpoch, requestGeneration,
  oldRevision R, proposedRevision R+1, oldCount, newCount,
  oldMembershipFingerprint, newMembershipFingerprint,
  removeRowsInOldSpace,
  insertRowsInNewSpace,
  movesFromOldToNewSpace: [(rowID, oldIndex, newIndex)],
  reloadRowsInNewSpace,
  heightReloadRowsInNewSpace
)

presentation(
  emptyToContent(tablePlan) | contentToEmpty(typedEmpty) |
  changedEmptyToEmpty(typedEmpty)
)
```

The private off-main production constructor validates bounds, unique row IDs, disjoint remove/insert/move participation, move identity, and exact baseline→candidate rows/fingerprint; reload indexes address final space. It may also seal a `RepoExplorerNativeUpdatePlanTemplate` from exact source/target snapshots and operations. The O(1) production `instantiate(template, baseline, requestGeneration, visibleGeneration)` may replace only lifetime, epoch, request/visible generation, and R→R+1 identity after matching baseline count/fingerprint; operations, source/target fingerprints, and presentation are immutable. Worker plans and instantiated plans remain indistinguishable to host preflight; the worker never owns accepted revision.

MainActor preflight is O(1): adapter/host lifetime, epoch, request generation, candidate identity, old revision/count/fingerprint, proposed revision, and presentation fingerprint must match the envelope and host baseline. An equal plan is a host no-op. A changed plan's presentation kind and new count/fingerprint must match the enclosed presentation. Stale input is rejected before child update, while malformed current plans fail invariant precondition rather than broad reload.

For `equal`, no host child or acknowledgment advances revision. The host itself applies the exact typed rowless transitions, including `contentToEmpty` whose plan identity remains present even though it has no table operations. `emptyToContent` carries an exact membership plan. Content transitions pass the table child one closed envelope containing the candidate identity/visible generation, snapshot, and exact `RepoExplorerNativeTableUpdatePlan`; the child invokes `RepoExplorerNativeTransactionApplier`, the sole production native applier, without rediff or alternate plan. Only after its one synchronous disposition returns accepted does the host replace accepted presentation, publish visible generation, and acknowledge R+1.

No ordinary update calls broad `reloadData`. Initial empty-to-current installation may use the same insertion transaction only after a cell-free pilot proves the API boundary. Objective-C/AppKit consistency exceptions are fatal process conditions, not recoverable Swift returns; correctness is provided by the off-main plan constructor, O(1) preflight, deterministic transaction proof, and the pilot. Before hosted cells or command integration depend on this boundary, the pilot runs the real 150/180/12/36 membership plans with a fixed visible-row count and then doubles offscreen rows. It falsifies the table design if app-owned fleet iteration appears, native membership MainActor p95 exceeds the `AppPolicies` four-millisecond bound, or p95 grows by more than twenty percent when only offscreen membership doubles. A falsifier returns to Program Design rather than permitting `reloadData` or a MainActor diff.

`RepoExplorerNativeTablePilot` remains the sole package API: `@MainActor run(recorder:) async -> scrubbed Result`. One global injected-Clock deadline covers both scales. Per scale, it creates an isolated fixture and persistent host, admits exactly one normal full adapter→Eager worker→host→typed child→sole-applier transition, awaits its exact acceptance event, then awaits adapter/family `stopAndDrain()` before native timing. It derives exact forward/reverse templates once off-main through the production constructor. The existing App diagnostic task awaits this work; no public/command/IPC/auth/stable-beta/Feature-DEBUG surface, RunLoop, polling, unstructured task, timer, observer, registry, mock, alternate diff/applier, or synchronous adapter exists.

After liveness/drain, the pilot alternates O(1)-instantiated forward/reverse membership plans through the same persistent host, typed cell-free real `NSTableView` child, and sole applier for exactly 20 warmups + 200 measurements per scale. Host preflights and acknowledges every candidate; templates cannot change operations/fingerprints/presentation. Only the synchronous applier call is timed—liveness, worker, template preparation/instantiation, waits, acknowledgments, and cleanup are excluded; later full-journey populations own end-to-end CPU. The fixed 30 seconds still covers liveness, template preparation, and both native populations; missing it irrevocably fails the marker. Timeout latches failure and cancels/stops, then enters an unmeasured safety drain before finishing the event stream and defer-detaching host/table/fixture. The facade never releases captured resources or returns before drain; if cooperative termination never completes, the existing outer launcher/verifier terminates the failed process rather than permitting unsafe teardown. No retry or policy relaxation follows. Later production uses the applier, not pilot wrappers.

### RepoExplorerMaterializationHost — total empty/content acceptance

`RepoExplorerView` mounts one feature-owned host for every demanded Repo Explorer state. Its lifetime and accepted immutable snapshot persist across initial empty, populated content, no-results, no-repositories, loading/empty variants, and transitions among them. The native table is only its non-empty child; a typed rowless shell child renders empty presentation with explicit generation/readiness.

It owns:

- one host lifetime identity and the immutable accepted presentation baseline;
- at most one candidate snapshot while its synchronous native transaction runs;
- one rowless empty-shell or non-empty table child;
- visible generation/readiness for both child kinds;
- synchronous accepted/rejected acknowledgment to the adapter.

Its only update interface is `apply(candidate)`. It performs the O(1) envelope/plan preflight above, owns rowless transitions, and passes only the exact typed content envelope to the table child. It never reconstructs a plan from presentation, advances R before child/applier completion, or accepts a plan through a side channel.

On creation the host installs and acknowledges explicit rowless R0 before first work starts. Empty equal R→R makes no child or revision change. Changed empty→empty updates the typed empty child and acknowledges R+1 after layout/accessibility readiness. Empty→content installs the table child and applies the insertion plan before acknowledging; content→empty installs the rowless child, clears viewport demand, disposes table cells only after anchor/focus disposition, then acknowledges. Content→content delegates its row plan to the table child. No empty state accepts through SwiftUI conditionals or a second owner.

### RepoExplorerTableMaterializer — non-empty child

The table replaces SwiftUI `List`/`ForEach` and backing-table discovery only for content presentation. It owns:

- native table data source/delegate lifecycle and one sidebar-styled column;
- visible-cell creation, reuse, stable/fixed row geometry, visible wrapping-row measurement, and content-slot binding;
- application of replacement-membership or affected-row update scope;
- the exact visible row range and visible-worktree demand publication;
- scroll-bound sampling used by bounded performance telemetry.

It does not own projection, row meaning, grouping, search, collapse policy, commands, favorite state, focus decisions, or domain facts. Those values arrive in the immutable materialized row or stable injected interaction callbacks.

The materializer receives one stable `RepoExplorerTableInteractions` value when the host is created. It routes typed row identity plus typed action to the existing command/focus/favorite/collapse owners. Cells create action closures only for represented visible rows; no fleet of closures is constructed or retained in the snapshot. Every callback carries the accepted table generation, row ID, and cell reuse token and is ignored unless all three remain current. Command/favorite callbacks also carry the accepted command generation. Reuse or a same-row command-only rebind therefore cannot turn the table into a second command or selection owner.

Behavioral interface:

```text
apply(contentCandidate)
  input: snapshot + exact RepoExplorerNativeTableUpdatePlan +
         visible generation/candidate identity
  precondition: host already matched candidate/plan kind and baseline
  membership/content: call RepoExplorerNativeTransactionApplier exactly once
  accepted/rejected: return exactly one synchronous disposition
  forbidden: rediff, replacement plan, plan side channel, second native applier

visibleWorktreeSnapshot
  opaque target(host lifetime + materialization generation + visible revision)
  + exact worktree set represented by the table's current visible row range
  equality-published by complete target + set at most once per coalesced viewport turn
  target change publishes even when the represented worktree set is equal
  cleared when the host leaves the window or sidebar demand is absent
```

Native membership application may ask the data source for its O(1) row count, O(1) indexed row facts, stable layout class, fixed metric, and visible cells, but row identity/order, content comparison, membership diff, and index lookup are already materialized. It must not invoke SwiftUI outline diffing, measure every SwiftUI row, or walk projection owners. The transaction creates or rebinds only AppKit-requested represented cells. The scroll anchor is the first fully visible row ID plus its clip-relative offset; focus and accessibility anchors are current row IDs and subcontrol identities. A surviving anchor is restored at the same offset/target. When an anchored row is removed, the plan's prevalidated nearest surviving successor, then predecessor, is used; absence clears only that anchor and follows existing refocus behavior.

### Width-dependent row height — visible-bounded measurement

The worker assigns a stable `RepoExplorerRowLayoutClass`: section header, loading header, loading row, group header, worktree row, pane row, or fault row, plus whether its declared text fields may wrap. Fixed classes use immutable `AppStyles` metrics carried in the snapshot. They never enter SwiftUI measurement. Wrapping classes carry minimum/fallback metrics and a bounded line policy, not a universal precomputed height.

The table's owned clip-view width is the sole width authority. It normalizes width to the current backing-pixel value, distinct-suppresses equal widths, and coalesces a resize burst to one latest width revision per MainActor turn under `AppPolicies.SidebarProjection`. On a new width or newly represented wrapping row, only represented visible wrapping cells are measured. Results are feature-local ephemeral values keyed by `(rowID, contentRevision, widthRevision)`; changed heights are applied through final-current-space `heightReloadRows` while preserving the row-ID scroll anchor. Offscreen rows use their stable fallback metric until AppKit represents them, then receive one bounded correction. No atom, App batch, worker, or table path measures the row fleet.

### RepoExplorerTableRowCell — reusable SwiftUI row-content host

Each visible native row uses one reusable `NSTableCellView` containing one persistent `NSHostingView` and one feature-private observable row slot. The hosting root persists, while the row-content subtree is keyed with `.id(rowID)` or an equivalent explicit identity-reset boundary. `prepareForReuse` first clears the slot, reuse token, hover/menu/gesture state, measurement cache attachment, and callbacks; installing another row creates a fresh row-identity subtree before interaction becomes ready. Same-row content-revision changes may retain identity-local state, but a changed row ID cannot retain SwiftUI `@State`, hover, focus, accessibility, or callback state from the prior row.

The hosted row view composes the existing Repo Explorer row components, context menus, hover behavior, chips, accessibility labels, and command callbacks. It receives direct row values and callbacks only. It reads no atoms, topology, cache, or projection owner. Reuse clears the prior row binding before installing the next identity so an offscreen or reused cell cannot dispatch an action for stale content.

The table remains view-based and native:

- source-list appearance, transparent background, row spacing/insets, and variable row heights preserve current visuals;
- stored layout metrics preserve section/header/row geometry without fleet SwiftUI measurement;
- row buttons and the existing Repo Explorer focus bridge preserve activation, keyboard traversal, escape/refocus, and sidebar focus semantics;
- native table/row accessibility plus the existing row accessibility labels and actions preserve VoiceOver order and navigation;
- context menus, hover controls, collapse disclosure, scroll position/anchor, and command dispatch continue through their existing owners;
- table selection is presentation-neutral and cannot become a second product-selection owner.

### App-owned command presentation — generation-validated row route

`RepoExplorerCommandPresentationBatch` remains App-owned composition truth. The Feature does not observe App atoms or resolve capabilities. The native viewport publishes a typed `RepoExplorerVisibleWorktreeSnapshot(target, worktreeIDs)`, where `target` is one opaque `RepoExplorerCommandPresentationTarget(materializationHostLifetimeID, materializationGeneration, visibleRevision)`. Host lifetime is load-bearing anti-ABA identity: numeric materialization generations and visible revisions may repeat after host replacement, but the target cannot. The App batch observes that value plus its existing favorite, active-tab, management, pane-structure, zoom, drawer, and command-capability inputs and emits one immutable `RepoExplorerCommandPresentationDelta` containing:

```text
commandGeneration
target(materializationHostLifetimeID + materializationGeneration + visibleRevision)
complete current RepoExplorerCommandPresentationSnapshot(
  command results + favoriteStateByRepositoryID
)
affected worktree IDs + affected repository IDs
union of old/new favorite and capability request identities
toolbarChanged
```

The batch advances generation only after it has resolved the complete current request set and current repository favorite state. A target-only change may reuse equal results but still publishes a newer command generation retargeted to the complete new host-lifetime/generation/revision target. App injects the delta into `RepoExplorerView`; no App type or state moves into the Feature. The target value is package-visible only as an opaque equality/transport identity; App cannot mint or inspect Feature host authority through it.

The table accepts a command delta only when its complete target—including host lifetime—matches the accepted table/viewport and its command generation is newer than the last accepted command generation. Using the worker's `rowIDsByWorktreeID`, `rowIDsByRepoID`, and per-row request identities, it intersects the affected IDs with represented visible slots and rebinds only those occurrences. Favorite changes include both the former and current add/remove-favorite request identities; capability changes include the current worktree request set. Toolbar changes update the toolbar from the same complete snapshot independently of table visibility. A stale delta is rejected and causes the App batch to observe the exact current visible snapshot; it never rebinds old capabilities or favorite state. Hidden/offscreen rows perform no update and resolve the latest accepted complete snapshot when reused.

Command-only same-row rebind retains the cell reuse token and row subtree identity. Every command/favorite callback therefore captures and validates `commandGeneration` in addition to materialization generation, row ID, and reuse token. A callback captured before a newer accepted command delta is stale even when the same row remains in the same cell. Presentation is advisory only: every current enabled row or toolbar action re-enters `AppCommandDispatcher`, which performs current targeting and authority validation.

### Materialization acknowledgment and viewport demand

Acceptance feedback is a feature-private typed interface, not an atom, store, EventBus fact, notification, public state, or second scheduling plane. Its accepted case carries candidate identity plus the host-owned immutable empty/content baseline: host lifetime, demand epoch, revision, presentation kind, row count/fingerprint, and snapshot. Its rejected case carries bounded reason. The adapter accepts feedback only for its current lifetime/epoch and awaiting token; duplicates and late acknowledgments are controlled no-ops.

For every invoked changed `apply`, the host delivers exactly one accepted or rejected disposition synchronously before returning. Missing/duplicate current disposition is an invariant failure. Before invocation, demand loss, supersession, host detach, or stop rejects the waiting candidate.

### RepoExplorerViewportDemand — bounded visible-set projection

Viewport demand is part of the table materializer rather than a separate view that searches for SwiftUI's private backing table. It observes the owned scroll view's clip bounds, asks the owned table for its visible row range, maps only those bounded rows through the precomputed optional worktree IDs, and publishes one typed snapshot containing the current opaque host-lifetime/generation/revision target plus the resulting set. Equality suppression compares the complete snapshot, so host replacement or numeric retargeting publishes even when the represented worktree IDs are equal.

Scroll callbacks are a burst of samples. One latest pending viewport calculation is retained per MainActor turn; intermediate bounds callbacks coalesce. Each pending calculation captures host lifetime and numeric target; any mismatch at publication is discarded. Work is bounded by visible rows, not fleet size. The owner publishes no change when the complete target-plus-worktree-set snapshot is equal and clears demand on teardown, sidebar hide/collapse, or generation replacement before stale callbacks can bind.

### PaneActivityStatusAtom — keyed latest-state publication

The atom remains the MainActor keyed read owner. Per pane it owns unknown, committed value/publication time, and optionally one latest pending value/eligibility. Equal input is suppressed without consuming eligibility. A changed eligible input commits immediately; a changed ineligible input replaces the pending value and one atom-wide reschedulable task targets the earliest deadline through the injected clock/delay seam. The deadline commits the latest still-distinct value; clear removes both states and recomputes that deadline.

The atom reports `equal`, `published`, `deferred`, `replaced`, `deadline_fired`, and `cleared`; it never reports a distinct drop as equality.

### Terminal source owners — exact settle and bounded tail read

`GhosttyActionDisposition` remains the mandatory first decision. Diagnostic trace selection runs after disposition and uses its volume class. Raw `setTitle` receipt traces are equal/rate-admitted per surface or aggregated; they do not enqueue one OTLP record per callback.

The source-delivered ordered `commandFinished` control reaches `TerminalActivityProjector` through the existing private action-input binding/accumulator path before any lossy coordination subscriber. Its ordinary semantic EventBus fact remains available to other consumers, but pane settlement does not depend on that bus delivery.

`TerminalLastOutputLineReader` becomes a behavioral boundary:

- one admitted read per settle generation;
- at most the policy-bounded trailing visible row window and byte count;
- one controlled result: `value`, `empty`, `surface_stale`, `read_failed`, or `oversized`;
- duration/row/byte buckets reported without content or identifiers.

Upstream Ghostty documents viewport-relative selection and labels text extraction expensive. The pinned vendor contract must prove its trailing-row selection semantics. If the pinned API cannot preserve selection order for the bounded window, the reader may retain a full-visible-viewport implementation only as an explicitly measured MainActor exception whose maximum cells, bytes, and duration satisfy the same interface; exceeding the policy fails admission/proof rather than silently expanding work.

### ForgeActor and PullRequestRepositoryProjection — execution versus published state

Forge keeps provider lifecycle private. Per repository, execution owns demand, origin, generation, active/latest-follow-up requests, freshness, and backoff. Published `PullRequestStablePresentation` is unknown, ready (including confirmed empty), or unavailable with prior confirmed facts; `loading` wraps that exact stable baseline plus request identity. Provider completion constructs a candidate but mutates no successful freshness or last-published equality state until origin, generation, live membership, and publication scope validate.

Loading always wraps the exact stable baseline; unknown, confirmed empty, ready facts, and unavailable are never inferred from an empty collection.

One changed `PullRequestRepositoryProjection` event carries the current loading state plus the facts/invalidation delta needed for atomic materialization. Loading false is never a separate event preceding its facts. Equality compares with the last projection actually accepted for emission, not a computed or rejected candidate.

After all currentness checks, Forge synchronously commits active-request completion, freshness/backoff, the accepted-for-emission projection baseline, and the captured follow-up decision before its first external await. It then emits the captured event. After emission it re-reads generation, demand, active state, and pending intent before admitting a follow-up; an older completion cannot overwrite a newer state. A rejected candidate mutates none of the success, freshness, or accepted-publication baselines.

Loading transitions are exhaustive:

| Event | Transition |
| --- | --- |
| admitted start from stable S | `stable(S) -> loading(S, request)` |
| valid success | `loading(S, request) -> stable(ready(confirmedFacts))` atomically with facts |
| ordinary failure or rate limit | restore `stable(S)`; retain existing confirmed facts and apply existing backoff |
| terminal current-origin unavailability | `stable(unavailable(previous confirmed facts from S, if any))` |
| cancellation, validation rejection, or demand loss | restore `stable(S)` unless a successor is actually admitted |
| supersession with admitted successor | remain `loading(S, successor)`; no intermediate stable publication |
| origin change/loss | invalidate prior-origin S, then become `stable(unknown)` or current-origin unavailable as the existing contract decides |
| repository removal | remove projection and keyed cache facts |

Loading may remain after a terminal path only when a concrete successor request has already been admitted. Every non-success path emits at most one coherent changed projection when the restored state differs from the last accepted projection.

### WorkspaceCacheCoordinator and RepoCacheAtom — coalesced atomic apply

Actual topology/Git/Forge domain facts keep their EventBus path. Raw provider start/stop work intent does not.

Repository projections use the existing consumer-side coalescing pattern keyed by repository. Latest projection replaces obsolete pending projection before MainActor application. One bounded MainActor batch applies loading state and facts/invalidation in one `AtomMutationContext`, so consumers observe one coherent revision.

`RepoCacheAtom` retains keyed `RepoBranchKey -> PullRequestFacts` and repository-loading slots. It exposes keyed reads and atomic projection application. Hot Repo Explorer capture never requests `loadingPullRequestRepoIds` or another whole-family snapshot.

## Allowed And Forbidden Dependencies

Allowed:

```text
Terminal owners -> compact Core pane-status fact
Core/App fact projections -> injected Repo Explorer read interfaces
Repo Explorer adapter -> Core keyed reads and feature worker
Repo Explorer adapter -> Eager pending intent + execution-time baseline envelope
Repo Explorer worker -> immutable semantic result + presentation/exact-plan candidate
RepoExplorerView -> persistent materialization host for every demanded state
App startup diagnostic task -> await async package RepoExplorerNativeTablePilot -> internal real pilot path
App startup diagnostic population selector -> DEBUG SidebarPerformanceProofSession
  -> existing AppCommandDispatcher or native search-field input driver
  <- one-at-a-time composite Repo Explorer readback -> token-correlated settlement record
external verifier -> candidate PID sampler + marker-scoped session records
materialization host -> rowless shell | non-empty table child
materialization host -> exact content candidate -> sole native transaction applier
materialization host -> feature-private accepted/rejected baseline acknowledgment -> adapter
table materializer -> reusable row cell slots + visible-worktree demand callback
table materializer -> typed visible-worktree generation snapshot -> App command-presentation batch
App command-presentation batch -> injected generation-validated delta -> Feature table/toolbar
ForgeActor -> changed repository projection event
WorkspaceCacheCoordinator -> atomic RepoCache apply
Repo Explorer/toolbar -> keyed RepoCache reads
```

Forbidden:

```text
Terminal/Core/Forge -> Repo Explorer row formatting
RepoExplorerView -> filesystem/Git/provider work or broad observation lifecycle
MainActor/table host -> fleet diff, sort, identity construction, content comparison, or projection-owner reads
broker/host/table -> strip, rebuild, substitute, side-store, or rediff a worker plan
App/facade -> RunLoop/polling/blocking, synchronous adapter, undrained release, scoped-delta drain workaround, per-measurement projection, mutable/manual template, host bypass, or alternate path/applier
worker -> accepted revision increment, visible acceptance, or mutable adapter/host state
adapter -> assume projected/read-model-bound candidate is native accepted
successor execution -> unacknowledged candidate baseline
table/SwiftUI empty branch -> acceptance acknowledgment bypassing persistent host
materialization acknowledgment -> atom/store/EventBus/public state/second scheduler
reusable row cell -> atoms, topology/cache lookup, projection policy, or stale-row actions
viewport demand -> private SwiftUI backing-view discovery, per-row geometry fleet scan, or uncoalesced bounds publication
Feature table/cell -> App composition state or capability resolution
App command batch -> direct row mutation, Feature ownership, or command execution bypass
width change -> fleet SwiftUI measurement or unbounded height invalidation
raw Ghostty callback -> MainActor/EventBus/OTLP before typed disposition
provider loading edge -> separate global work-intent event
hot capture -> whole cache/topology/loading snapshot
rejected Forge result -> freshness or last-published mutation
cooperative cancellation -> overlapping successor execution for one key
```

Architecture lint/tests enforce imports and forbidden hot-path calls. Behavioral tests enforce state and sequence contracts. Runtime telemetry proves cadence and cost.

## State And Concurrency

### Derived execution per key

| Current state | Input | Transition | Output |
| --- | --- | --- | --- |
| idle/current at acknowledged R | admitted intent A | adapter envelopes A from R; running(A,R) | execution started |
| running A | newer intent B | advance request generation; running A + pending B; request A cancellation | A publication revoked; retained pending intent one |
| running A + pending B | newer intent C | merge/replace pending intent through owner combiner | one complete latest intent retained; no work envelope frozen |
| running A, still current | completion `.equal R→R` | advance semantic baseline; settle Eager | no read-model/native invalidation; pending re-enveloped from R |
| running A, still current | completion `.changed R→R+1` | validate and bind read model; awaitingNative(A,R+1) | pending remains blocked |
| awaitingNative(A,R+1) | host accepts | cache acknowledged R+1; settle Eager | pending re-enveloped from R+1 and may start |
| awaitingNative(A,R+1) | rejection/revocation | keep acknowledged R; do not commit Eager candidate | one current full rearm from R |
| awaitingNative(A,R+1) | newer intent B before `apply` | revoke A; retain/merge B; reject A against R | B becomes the one full rearm from R after A settles |
| running A | completion after B/C accepted | current unchanged | superseded; cannot bind |
| running | cancelled/superseded/failed | idle/current(existing) | exact terminal outcome |
| demanded lane | demand loss | advance demand epoch; revoke active/awaiting; discard pending | no late read-model/native acceptance |
| any | stop/removal | revoke immediately; retain task/work/slot until async drain + terminal bookkeeping | all waiters resume once; no later binding/release race |

No two executions for one key overlap. Different keys may execute concurrently under their existing family bounds.

### Materialization host and native rows

| Current state | Input | Transition | Output |
| --- | --- | --- | --- |
| new host lifetime | install rowless shell; register/acknowledge empty R0 | visible empty R0 ready | first full intent may start from R0 |
| empty R | equal empty plan R→R | no child/readiness/revision change | equal settles immediately |
| empty R | changed empty→empty R+1 | update rowless shell; acknowledge when ready | R+1 accepted without table |
| empty R | exact empty→content membership envelope R+1 | install table; child invokes sole applier; acknowledge after disposition | content R+1 ready |
| content R | exact content→empty envelope R+1 | host applies typed rowless plan; clear table/viewport; acknowledge | empty R+1 ready; plan identity retained |
| accepted revision R | valid content plan R→R+1 | expose candidate; reload final-space represented rows/heights; acknowledge after completion | R+1 accepted; unaffected rows/cells retain identity |
| accepted revision R | valid membership plan R→R+1 | capture anchors; exact batch transaction; restore; acknowledge after completion | R+1 accepted; viewport recomputed once |
| accepted revision R | equal plan R→R | no host state change or acknowledgment | no table/layout/focus invalidation |
| lifetime/epoch/generation/revision mismatch | stale plan or command delta | reject candidate; keep R | accepted cells, anchors, viewport, and command presentation unchanged |
| current table target T | command delta for a different host lifetime or numeric target | reject delta; report exact current visible snapshot T | no command/favorite state or cell mutation |
| current table target T at command generation C | matching delta with generation ≤ C | reject duplicate/out-of-order delta | represented and offscreen presentation unchanged |
| current table target T at command generation C | matching delta with generation C+N | accept complete snapshot; rebind affected represented occurrences only | offscreen rows resolve the accepted snapshot on representation; old callbacks fail command-generation validation |
| any | bounds burst | replace one pending viewport calculation | one latest visible-worktree set per coalesced turn |
| represented wrapping row + new width revision | measure that cell; height-reload its current index; restore scroll anchor | no offscreen/fleet measurement |
| any | cell reuse | `prepareForReuse`; clear identity state; install fresh keyed subtree | no stale state, action, focus, or accessibility value |
| surviving host | demand loss/hide | clear viewport, retain empty/content R, reject late candidate | reentry re-acknowledges R under new demand epoch |
| teardown | detach host lifetime | clear child/candidate; adapter discards baseline | replacement host registers new lifetime + empty R0 |
| pilot running | one full liveness acceptance per scale, then template replay; or 30s wins | await drain before replay/release; timeout latches failure then safety-drains | native-only distribution or failed marker; never retry/pass on cleanup |

Assignment to `publishedResult` is **read-model binding**. The host's prior baseline remains visible authority until empty-shell/table update, layout/focus/accessibility, viewport publication, and R+1 acknowledgment complete; those are **visible UI update** outcomes. MainActor serialization prevents child-state interleaving.

### Pane activity publication per pane

The state chain is `unknown -> committed`; equal input stays committed, eligible change commits, ineligible change installs/replaces one latest pending value, its deadline commits if still distinct, and clear returns to unknown while recomputing the earliest deadline. This deferral gate equals the ungated latest sequence at the first demanded checkpoint.

### Forge completion order

```text
provider result
  -> derive candidate against captured request
  -> validate origin + generation
  -> intersect with live membership
  -> validate current publication scope
  -> derive complete repository presentation projection
  -> compare with last accepted-for-emission projection
  -> synchronously commit completion + freshness/backoff + accepted baseline
     and capture the current follow-up decision before any await
  -> emit the captured changed projection
  -> re-read/revalidate actor state after the await
  -> admit latest follow-up only if demand remains eligible and no newer work owns the state

validation failure
  -> leave success/freshness/accepted-publication baselines unchanged
  -> restore the exact loading baseline unless a successor is admitted
  -> retain/admit latest pending follow-up under current demand
```

Actor isolation serializes state. The provider task performs external work outside the actor. Reentry after every await revalidates captured identity.

## Current-To-Target Call Paths

### Repo Explorer invalidation and publication

```text
CURRENT
source keyed fact change
  -> RepoExplorerProjectionAdapter key-specific observation
  -> demand/equality admission + invalidation union
  -> affected-key or demanded full capture
  -> EagerDerivedAtom one-active/one-pending execution
  -> worker full/delta projection
  -> complete rendered equality + currentness validation
  -> one MainActor publishedResult binding
  -> RepoExplorerView List { ForEach(all rowIndex.entries) }
  -> SwiftUI OutlineListCoordinator fleet identity/diff/focus/layout
  -> private backing NSTableView
  -> RepoExplorerVisibleRowsBridge discovers table and publishes visible worktrees

TARGET
source keyed fact change
  -> [intentionally unchanged] RepoExplorerProjectionAdapter keyed admission
  -> [changed] adapter creates latest full/delta intent under lifetime + demand epoch
  -> [changed] Eager starts only after adapter envelopes intent with acknowledged native R
  -> [changed] worker emits semantic candidate plus typed presentation and exact
               `.equal R→R` or `.changed R→R+1` plan in one delivery envelope
  -> [changed] broker validates but never strips/rebuilds the envelope plan
  -> [changed] host O(1)-validates lifetime/epoch/generation/native R/fingerprints
  -> [changed] equal advances semantic baseline only; changed binds read model
  -> [removed] generic SwiftUI List/OutlineListCoordinator fleet diff
  -> [added] persistent host applies exact rowless plan or delegates the exact
              snapshot/table-plan child envelope to the sole native applier
  -> [added] host acknowledges accepted immutable empty/content R+1 to adapter
  -> [added] adapter caches R+1 and releases Eager settlement barrier
  -> [changed] only now may pending intent be re-enveloped and start from R+1
  -> [added] reusable native cells host row-ID-reset SwiftUI content
  -> [changed] viewport publishes host lifetime + materialization generation +
               visible revision + worktrees as one anti-ABA target
  -> [added] App command batch returns generation-validated affected presentation delta
  -> [added] current represented slots/toolbar rebind; actions re-enter dispatcher
  <- current visible rows / focus / accessibility / commands, or stale-generation rejection
```

Unchanged and preserved: source state owners, immutable request/result boundary, keyed admission, off-main worker, cancellation checkpoints, complete rendered equality, row appearance, row commands/context menus, sidebar focus target, and cached projection behavior. Removed edges eliminate only generic outline materialization and private backing-table discovery.

### Terminal pane activity

```text
CURRENT
Ghostty action
  -> trace received before disposition
  -> typed disposition / accumulator / projector
  -> commandFinished EventBus
  -> lossy TerminalActivityRouter subscriber
  -> full viewport MainActor read
  -> changed line
  -> PaneActivityStatusAtom may drop distinct value for 10s
  -> broad Repo Explorer wake

TARGET
Ghostty action
  -> typed disposition
  -> disposition-bounded diagnostic aggregation
  -> accumulator/projector ordered local settle control
  -> bounded measured tail read
  -> changed latest pane-status fact
  -> PaneActivityStatusAtom equal-or-defer-latest
  -> demanded pane-key Repo Explorer invalidation
```

Unchanged and preserved: exact semantic EventBus fact for other consumers, sufficient-statistics scrollbar aggregation, projector generation/lifetime guards, and keyed status storage.

### Forge loading and facts

```text
CURRENT v0.0.90
provider start -> loading=true event -> direct MainActor cache apply
provider completion -> mutate success/published baseline
                    -> loading=false event -> direct MainActor cache apply
                    -> late current-scope validation
                    -> facts event -> direct MainActor cache apply
                    -> whole loading-set sidebar capture

TARGET
provider start/completion -> private execution state
completion candidate -> validate before owner-state mutation
changed current repository projection
  -> repository-keyed latest coalescing
  -> one atomic MainActor loading+facts apply
  -> relevant repository-key sidebar invalidation
```

Unchanged and preserved: demand projection, active/follow-up bound, provider batching, backoff/freshness deadline, origin/generation/live-membership checks, and confirmed-fact retention.

## Failure And Recovery

- **Lost demand:** adapter advances demand epoch, removes hot observations, revokes active/awaiting work, discards pending intent, and blocks late binding/acknowledgment. Returning demand first registers the same-host retained baseline or new-host empty baseline, then performs one current full capture.
- **Cancellation:** exact `cancelled` outcome; never equality. Pending latest starts only after predecessor projection and owner settlement terminate. Stop/revocation prevents late binding.
- **Unknown equality:** owner retains one invalidation or executes. It never suppresses on absence of proof.
- **Terminal read failure/oversize/stale surface:** status remains last confirmed; controlled outcome is reported; a later settle can recover. No empty value overwrites confirmed content.
- **Exact settle pressure:** the private ordered control is not lossy. Duplicate controls are idempotent by settle generation; out-of-order/stale surface generations are rejected.
- **Forge stale completion:** candidate is discarded before freshness/accepted baseline mutation; the exact stable loading baseline is restored unless a successor is admitted, and latest follow-up remains eligible.
- **Forge failure/rate limit:** current facts remain; loading restores the exact pre-loading stable state for ordinary failure/rate limit, while terminal current-origin unavailability uses the explicit unavailable state; existing backoff and next-deadline owner recovers.
- **Atomic cache apply failure:** no partial loading/facts revision is committed. The next changed repository projection or demand refresh can recover from Forge's authoritative current state.
- **Stale materialization candidate or plan mismatch:** O(1) lifetime/epoch/generation/revision/count/fingerprint, proposed-revision, presentation-kind, or presentation-fingerprint mismatch is rejected before the child. The host retains R, semantic result is not promoted, and the existing bounded broker recovery rearms one full intent from R.
- **Stale semantic or native baseline:** lifetime, demand epoch, generation, native revision/count/fingerprint, and semantic sequence are validated before binding. Rejection mutates neither Eager value/equality state nor acknowledged native baseline and re-arms one full intent from the current acknowledgment.
- **Acknowledgment loss/duplication:** an invoked changed `apply` must synchronously return exactly one disposition; missing or duplicate current disposition is an invariant failure. Before invocation, demand loss, supersession, detach, or stop rejects the waiting candidate from the still-acknowledged baseline. Duplicate or late stale acknowledgments fail candidate identity and do nothing.
- **Demand loss while projecting or awaiting native acceptance:** advance the demand epoch, revoke active/awaiting work, discard pending intent, and reject late binding/acknowledgment. Same-host hidden state may retain only its last acknowledged baseline; no unacknowledged candidate becomes reentry authority.
- **Host empty/content transition failure:** preflight rejection retains prior accepted child/baseline. A malformed current transition is an invariant failure. Empty presentation never bypasses the host, and content→empty clears viewport only as part of the acknowledged transition.
- **Host teardown/replacement:** detach retires its lifetime and baseline. A replacement host synchronously installs/acknowledges empty R0. Numeric generations/revisions may repeat, but old work cannot pass lifetime validation.
- **Drain or pilot failure:** stop revokes immediately but resources remain retained until every detached attempt and MainActor terminal callback drains; late work can only cancel. Family removal awaits the same receipt. At the 30-second deadline the pilot latches failure, cancels/stops, awaits safety drain outside the accepted distribution, finishes events, then detaches. Non-cooperative drain never releases resources or returns; the outer verifier terminates the failed process. No retry, scoped-delta workaround, timeout/threshold change, `reloadData`, SwiftUI `List`, or alternate algorithm is allowed.
- **Cell reuse race:** `prepareForReuse` clears the prior slot and identity-keyed subtree before installing the next row. Delayed hover, accessibility, or measurement callbacks validate materialization generation, row ID, and reuse token. Command/favorite callbacks additionally validate the latest accepted command generation, so a same-row command-only rebind revokes older actions without resetting row identity.
- **Width/height race:** a measurement carries row ID, content revision, and width revision. Mismatch is discarded; a current changed height invalidates only the represented current row and restores the row-ID scroll anchor.
- **Command-presentation race:** a delta with a stale host lifetime, materialization generation, visible revision, or command generation is rejected. Numeric target reuse after host replacement cannot pass the lifetime check. Rejection reports the exact current typed visible snapshot so App retargets from current authority and mutates no accepted command/favorite state or represented cell. Offscreen rows bind the latest accepted complete presentation on reuse, same-row callbacks validate command generation, and dispatcher execution remains authoritative.
- **Viewport callback after replacement/teardown:** pending work carries host lifetime, epoch, accepted revision, and generation; mismatch cancels publication and teardown clears demand.
- **Accessibility or focus regression:** candidate materialization fails native proof and does not ship. Recovery is implementation correction inside the selected native host, not restoration of the measured generic-list path.
- **Telemetry sink loss:** application remains fail-open. Strict proof fails when stage evidence or zero-drop condition is absent.

## Cutover

This is a hard in-process cutover with no persisted schema or version skew:

1. The new keyed admission/controller path becomes the only Repo Explorer projection path; broad View observation and the 60-second fleet loop are removed.
2. `EagerDerivedAtom` adopts one-active/one-pending semantics for all consumers; overlapping behavior is not retained.
3. Pane activity distinct-drop state is replaced by committed-plus-latest-pending state; no migration is needed because it is runtime-only.
4. Separate Forge loading events are removed. The changed repository projection is the sole Forge presentation publication; cache application is atomic.
5. Hot stable-key derivation is removed; topology index materialization is authoritative immediately on hydration/mutation.
6. `RepoExplorerMaterializationHost` becomes the persistent empty/content acceptance owner; its table child is the only non-empty row container. SwiftUI conditional ownership, `List`, backing-table discovery, and computed string identity are removed together.
7. The feature-private host acknowledgment and replacement Eager settlement interface become the only acceptance path. Projected/read-model-bound candidates are never accepted baselines, and no pending successor starts before settlement.

Rollback is binary rollback to the preceding app version, not a runtime dual path. No candidate build may mix old and new projection/loading authority.

## Performance, Observability, And Proof Architecture

### Separate acceptance populations

One real-size fixture identity is the isolated debug app after its watched-folder owner has discovered both complete canonical roots `/Users/shravansunder/Documents/dev/open-source` and `/Users/shravansunder/Documents/dev/project-dev`. A local source-scrubbed topology manifest records the two root roles, stable root hashes, per-repository/worktree stable-identity hashes, counts, and one aggregate fingerprint; every population must match that fingerprint before and after measurement. The UI fixture contains five tabs and twenty pane models but mounts only the PTY count declared by the selected idle/action variant. Performance phases use fresh markers and isolated data roots but the same discovered topology fingerprint, deterministic tab/pane facts, candidate binary, hardware, power mode, trace selection, and sampler. Startup, watched-root discovery, and fixture construction end before any acceptance population begins.

Fixture preparation uses the existing product owners directly: the DEBUG startup diagnostic adds both `WatchedPath` values through `WorkspaceMutationCoordinator`, then awaits one `WatchedFolderCommandHandling.refreshWatchedFolders` call over the complete two-root set. The returned tracked scan receipts must contain a nonempty completed result for each exact root, the topology projection must contain both watched paths, and filesystem logical debt must be freshly observed at zero before quiescence can start. The proof never routes through the fire-and-forget folder-picker wrapper. It does not synthesize, prune, or top up repository/worktree discoveries to reach an old numeric fixture target; the complete real discovery and its fingerprint are the workload identity.

`AppPolicies.SidebarPerformanceProof` owns one immutable versioned descriptor with these exact values:

| Policy field | Immutable value |
| --- | --- |
| fixture | complete canonical `opensource` and `project-dev` watched roots with one stable discovered-topology fingerprint; five tabs and twenty pane models; query `worktree`; two populated tab-switch identities; PTYs bounded separately by population |
| CPU gates | idle nearest-rank p99 `<10%`; action nearest-rank p95 `<20%` |
| sampling and floors | one-second intervals; 1,000 usable samples per idle variant; at least 100 successful actions/cycles and 200 complete action-bearing samples per action class |
| action boundary | first production input exactly on a sampler boundary; after settlement, next action on the first eligible boundary and no later than one interval |
| search cadence | eight native text-entry events at exactly 100 milliseconds per character; clear through the same control with no hold |
| quiescence and timeout | five consecutive seconds of unchanged capture/execute/publish/bind/visible-update/export state; five-second semantic+native readback timeout per action |
| exact process scope | acceptance samples come only from the state-file-bound isolated debug PID; the PID identity is revalidated during the population; no debug-owned descendant may remain active; unrelated host processes, beta, and production are outside the measurement and control scope; candidate-fixture terminal command/output absence is proven separately; maximum sampler gap 1.25 seconds |
| standard tags | exactly `performance,app.startup,terminal.startup` |
| diagnostic perturbation | paired diagnostic minus standard process-CPU p95 at most 5 percentage points and interaction-time p95 at most 10% |
| native-table pilot | one global 30s deadline covering one full liveness+drain and one off-main forward/reverse template pair per scale, then 24-row host replay with 20 warmups +200 measurements at 180/360 worktrees; sole-applier-call p95 ≤4ms and growth ≤20%; safety drain cannot pass a timeout |

The descriptor is safely projected through the existing startup diagnostic with a policy version/hash and controlled values only, so the verifier binds evidence to the candidate's actual policy identity instead of duplicating or overriding it through environment values. Timing, threshold, admission, and validity constants have no environment override.

The verifier samples only the exact candidate debug PID for the acceptance distribution and records sampler gaps against the fixed descriptor. Process inventory is limited to proving that the candidate PID exists and has no live descendants; it does not classify, measure, reject, signal, or otherwise control unrelated host processes. Candidate-owned proof readback establishes that no terminal commands/output or agent execution occur inside the debug fixture.

The PTY capacity guard resolves only the current marker state file's exact debug data root and zmx directory and uses the zmx executable copied into that same root. It reuses `scripts/cleanup-debug-zmx-sessions.sh` through an exact-root dry-run inventory interface that accepts this one validated zmx folder; the broad all-debug-roots mode and execute mode are never used by performance measurement. It inventories sessions before launch preparation, periodically during measurement, immediately after candidate exit, and after exact-root reset, appends every result, and explicitly joins its monitor. Zero-PTY idle must remain `0 → 0 → 0 → 0`. Quiescent-PTY idle and all action/diagnostic populations must remain `0 → 1 → at most 1 → 0`; the one retained post-exit session is allowed only until exact-root reset, and its client count must not exceed the fixed fixture expectation. A list error, unknown/duplicate session, extra client, count above one, unexpected transition, topology-fingerprint change, or other envelope breach invalidates and retains the whole population. Pane count is never used as a PTY proxy. The verifier cannot trim samples, relax/replace policy, inventory or kill broad debug roots, touch stable/beta roots, kill unrelated processes, or exclude candidate CPU.

The debug launcher owns one `SidebarPerformanceCandidateIdentity` written with the marker state: runtime flavor, debug code, bundle identifier, canonical app and executable paths, canonical isolated data and zmx roots, marker, PID, and a kernel-derived process-start identity captured immediately after launch. The verifier may use the PID for sampling only while the launcher's identity validator confirms that complete tuple. Candidate retirement is also launcher-owned: before every signal, the launcher re-reads the state and live process and requires the same complete tuple, including process-start identity. An already-exited candidate produces an `already_absent` receipt and no signal. A stale/reused PID, executable/app mismatch, wrong debug code, non-debug flavor, marker mismatch, or stable/beta/data-root mismatch produces a refusal receipt, invalidates the population, and sends no signal. The verifier never calls `kill` with `APP_PID` directly. After either absence or refusal, only the separately validated exact-root zmx inventory/reset path may proceed, and only when it proves no live process or session can still own those resources. Candidate identity is revalidated throughout the population so PID reuse cannot become either sampling or cleanup authority.

`SidebarPerformanceProofSession` owns one bounded `SidebarPerformanceWorkloadReceipt` spanning positive readiness through population completion. The receipt snapshots controlled monotonic facts from their existing source boundaries: accepted terminal key/text input at the Ghostty surface input boundary, terminal-output advancement at the typed scrollbar/source-disposition boundary, and ordered `commandFinished` admission at `TerminalActivitySourceInput`. The search driver targets the native sidebar field only after first-responder readback, so it cannot increment terminal input. Completion requires zero delta for all three counters; a missing baseline, reset, dropped receipt, nonzero delta, or counter regression invalidates the whole population. The fields contain counts only and aggregate before OTLP; terminal text, keys, commands, paths, pane IDs, and process arguments never enter the receipt or telemetry. Pane-agent execution is structurally unavailable in the current product graph: `PaneAgentLaunchOwner.launchPaneAgent` has no production caller or composition edge. A source-bound architecture test keeps that invariant part of the proof-policy identity; introducing a production caller makes the strict proof fail until an owner-tracked launch/active-process counter is incorporated into this receipt. This proves the workload inside the exact candidate without creating a second agent or terminal owner.

Quiescence is positive, not a wall-clock guess. For each selected startup-diagnostic population, the DEBUG-only App-owned `SidebarPerformanceProofSession` prepares the fixed fixture through existing owners and emits bounded current readback. The external verifier requires projection capture/execution/publication/read-model-binding/visible-UI-update counters and trace-export backlog to remain unchanged for the policy quiescence interval while the mounted UI remains demanded. The acceptance window starts only after this observation succeeds.

Fresh markers keep zero-PTY idle, quiescent-PTY idle, search/clear, grouping, hide/show, and tab switching as six independent populations. Both positively quiesced idle populations use at least 1,000 one-second samples and nearest-rank p99 `<10%`; each action population uses at least 100 successful actions/cycles plus 200 complete action-bearing samples and nearest-rank p95 `<20%`, with zero terminal output/commands or agent execution inside the debug fixture and exact semantic/native readback. The zero-PTY variant must remain at zero candidate-owned PTYs/sessions; the quiescent/action variant may retain only its fixed mounted quiescent terminal count. Pane-model count never implies mounted-terminal count.

Idle and action distributions never combine. Search, grouping, visibility, and tab switching never combine with each other. A no-op, failed readback, delayed/missing publication, hidden sidebar during the visible-idle phase, or slowed-beyond-policy action does not count toward the sample/action floor.

Each action population follows the Specification's immutable attribution rule. The proof session schedules the first production input at a monotonic sampler boundary, mints one opaque action token, records its expected state, and permits no second action until one composite readback proves the first token's semantic, acknowledged-native, visible, focus, and accessibility settlement. It emits bounded started/settled/failed records carrying only population class, sequence token, monotonic boundary/settlement timing, generation/revision counts, and controlled outcomes. The external sampler attributes every complete one-second interval intersecting input-through-token-matched settlement to that action; idle pacing intervals do not count, and the next action begins on the first eligible boundary. The population runs enough production actions to satisfy both floors; no external control message is required. Any no-op, failed/timeout input, wrong expected state or generation, absent native readiness, duplicate/out-of-order readback, partial/overlapping interval, sampler gap, cross-class sample, or policy/host breach invalidates the whole population without replacement or trimming.

Grouping, hide/show, and tab selection use their existing production `AppCommandDispatcher` paths. Search first uses the existing Filter Sidebar command, then the proof session's debug-only native input driver locates the actual focused search control and delivers the fixed key events; it has no arbitrary query mutation, stable/beta availability, public IPC projection, or product command identity. The Repo Explorer read-only callback reports the adapter's semantic generation and settled query/grouping/demand state plus the table's accepted generation/revision, transaction readiness, represented row count, field state, and accessibility/focus disposition. The session compares that callback with its single outstanding token and expected state; unmatched or duplicate callbacks cannot settle an action. These are bounded debug-proof facts under the current marker, not a second product state owner.

Each of the six standard populations is selected through an explicit DEBUG-only startup-diagnostic kind and runs in a fresh launch/marker/PID. The selector chooses a fixed descriptor-owned population; it carries no thresholds, arbitrary input, query text, command name, target identity, or transport payload. Idle sessions prepare and remain settled while the external sampler collects the required floor. Action sessions execute the fixed production cycle in-process until the descriptor-owned action and action-bearing-sample floors can be satisfied. A diagnostic perturbation launch reuses the same population selector with the separately declared diagnostic trace tags. No local socket, FIFO, marker-name command encoding, new IPC method, public command, atom, store, EventBus fact, or cross-process control plane is introduced.

The standard acceptance runs use exactly `performance,app.startup,terminal.startup` and exclude atom, exact row-body, raw-action, and per-mutation tracing. Only these standard populations establish the absolute CPU verdicts. Exact-attribution profiles run under separate diagnostic markers using the same fixture and action script. One paired standard-versus-diagnostic population reports CPU-distribution and interaction-time deltas and binds them to the descriptor's five-percentage-point/ten-percent limits. A diagnostic run beyond either limit remains useful only for qualitative stack attribution; it cannot supply, replace, or be pooled with an acceptance percentile or quantitative waste ratio.

The historical `v0.0.88` and faulty-release evidence remains diagnostic comparison only. Absolute 10%/20% gates, correct final state, zero delivery/trace/collector drops, and bounded stage ratios are independently required.

Proof paths and real/fixed boundaries:

```text
FAILED v7: async facade -> 440 full projections -> 30s/no usable population
  -> timeout stop + detach before drain; Eager worker still in Git merge
  <- main release/autorelease EXC_BAD_ACCESS; no p95/growth
TARGET/scale: one full-path liveness -> host ack -> stopAndDrain
  -> production constructor seals forward/reverse templates off-main
  -> O(1) identity-only instantiate -> same host/child/sole applier 20+200
  <- applier-only distribution; timeout latches fail before safety drain/detach

LATER production acceptance: verifier -> fixed fixture -> isolated debug launcher
  -> real app composition -> adapter/worker -> production table/viewport
  -> existing dispatcher + native search input driver
  <- semantic generation + native table generation/readiness observation

external low-overhead process sampler
  -> candidate PID CPU distribution                   real process boundary
  -> exact PID / no descendants / sampler-gap validity   measurement validity

real owner telemetry -> OTLP collector -> Victoria
  <- marker-scoped stage counts, durations, drops, quiescence

paired sample / Instruments
  -> same PID + marker during named phase
  <- attribution only; never substitutes for CPU acceptance distribution
```

No projection, materializer, viewport, command, OTLP, or UI owner is mocked in acceptance. Watched-root discovery is read-only against the two required real roots; the isolated debug database owns only its discovered topology projection and must never write into, copy state from, or clean up those roots. The local proof artifact records stable identity hashes, counts, and the aggregate topology fingerprint; OTLP receives only controlled root-role presence, counts, and the aggregate safe hash. A script-only canned metrics response remains limited to verifier unit tests and cannot satisfy runtime proof.

### Native UX and visible-update proof

The native table cutover is accepted only through the packaged debug app bound to the current marker and exact PID. The proof uses the real row host and verifies every existing behavior through its production owner:

| UX contract | Required native observation |
| --- | --- |
| content and grouping | By Repository, By Pane, and By Tab show the same ordered rows, counts, sections, loading/empty states, and collapse results as the bound projection |
| search and switching | fixed native type/clear, grouping, sidebar hide/show, and tab switching use the specified production drivers and reach generation-matched semantic/table readiness within policy |
| row interaction | worktree/pane activation, favorite and disclosure controls, context menus, hover controls, and command dispatch target the current host lifetime/generation/row/reuse token; command/favorite actions also target current command generation; recycled identity state is absent |
| focus and keyboard | filter focus, down-arrow exit, escape/refocus, key-loop order, row activation, and active-pane focus match the existing sidebar behavior without fleet focus-loop rebuilding |
| scrolling | wheel/trackpad scrolling, row-ID/offset anchoring across content/membership/visible-height updates, and host-lifetime/generation-stamped visible-worktree demand remain current without jumps or stale demand |
| accessibility | table/row roles, order, labels, header traits, actions, enabled state, and VoiceOver navigation match the existing semantic tree |
| appearance | source-list background, row geometry/insets, section spacing, icons, chips, text, recency color, selection neutrality, and loading/fault presentation match the existing surface |

Each action readback proves the bound projection generation first, then the visible table generation and expected represented row/accessibility state. This keeps semantic correctness, read-model binding, and visible UI update independently attributable. Screenshots or visual feel alone cannot prove focus, accessibility, command targeting, generation currentness, or CPU.

### Bounded stage evidence

Each owner records a controlled stage/outcome and aggregate numeric scope/duration:

```text
observe/project: input class, demanded key counts
distinct: equal / changed / unknown
coalesce: retained / replaced, retained scope count
admission: admitted / deferred / rejected / capacity-limited
execute: started / completed / failed / cancelled / superseded + duration
validate: current / stale-generation / stale-origin / stale-scope
publish: changed / equal / invalidated
bind: changed / equal / revoked / stale
visible_update: membership_applied / affected_visible_rows / equal / stale / failed
deadline: scheduled / rescheduled / fired / cancelled
```

No raw paths, branch/repo names, UUIDs, terminal content, payloads, or errors enter OTLP. High-volume row-body and raw action diagnostics aggregate before the trace queue. Primary performance proof runs without high-volume atom logging and requires zero trace-queue loss.

Each often/heavy domain owns a non-observable fixed-state accumulator before the trace queue. Repo Explorer, Terminal, and Forge do not share policy or state; each stores only its declared fixed outcome counters, bounded scope buckets, and fixed histogram buckets. Recording is synchronous and allocation-bounded at the owning stage. One existing performance-report cadence flushes an immutable aggregate snapshot through `AgentStudioPerformanceTraceRecorder`, then resets interval counters. There is no per-input task or log record. Repo Explorer records publication, read-model binding, and visible UI update through separate counters even when one MainActor turn contains both. Exact mutation attribution is available only in a narrow opt-in diagnostic mode with the `AppPolicies` admission limit and controlled marker; the paired standard/diagnostic rule above determines whether its quantitative attribution is valid.

### Requirement-to-owner-to-proof trace

| Specification | Structural owner | Proof seam |
| --- | --- | --- |
| S1-S5 | RepoExplorerProjectionAdapter, topology stable-key index | deterministic grouping/key invalidation tests; forbidden-call architecture check; marker stage ratios |
| S6-S8 | Ghostty disposition/accumulator/projector, PaneActivityStatusAtom | exact-pressure integration; latest-sequence R-INV; pinned Ghostty tail-read contract; deadline test |
| S9-S12 | ForgeActor repository projection, coalesced coordinator apply, RepoCacheAtom | A→B→A controlled provider; atomic cache observation; unrelated-repo isolation; one-active/one-follow-up |
| S13-S14 | Eager/Family drain receipt, adapter broker, candidate/plan, worker/template constructor, host, async pilot, child/sole applier, baseline, App batch | two crash/drain falsifiers; repeated-stop/waiter/family-remove/late-completion and Repo/Tab-Bar preservation; one full liveness+drain per scale; immutable template/identity-only instantiation oracle; host replay/applier-only timing; no-rediff/bypass/scoped-delta workaround; existing lifecycle/currentness/UX proof |
| S15 | watched-root fixture, topology fingerprint, PTY/zmx capacity guard, quiescence detector, exact-process-scope guard and sampler | complete `opensource`/`project-dev` discovery; five tabs/twenty pane models; separate zero-PTY and quiescent-PTY markers; pre/during/post session counts; exact PID plus zero descendants; complete distributions; p99 gate; scheduled-background-work and zero-drop evidence |
| S16 | DEBUG App-owned proof session, existing command dispatch, debug-only native search driver, semantic/table readiness observation | separate search/grouping/visibility/tab markers; one outstanding token; 100-action and 200-sample floors; boundary attribution; nearest-rank p95; whole-population invalidation |
| S17 | immutable versioned `AppPolicies.SidebarPerformanceProof` descriptor and verifier | exact watched-root roles/fingerprint, tags/pacing/timeout/process identity/PTY bounds/perturbation; debug-descendant, topology-drift, and sampler-gap rejection; no unrelated-host gate or process-name proxy; historical comparison without threshold substitution |
| S18-S20 | owning emitters and OTLP safe projection | outcome-matrix tests, binding-to-visible-update ratios, perturbation comparison, zero-drop verifier, sensitive canary and allowlist tests |

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

The S13-S14 protocol proof covers inseparable candidate/plan transport into the sole production applier; initial empty R0; exact empty→content and content→every empty kind; changed/equal empty; A/B/C; equal-before-delta; pre-apply supersession; rejected plan/presentation mismatch before child entry with R retained and bounded recovery; accepted/rejected/late-duplicate settlement; demand revoke, family remove, stop, same/new-host reentry; Tab Bar current/equal/changed-only/no-partial-list; and a randomized plan oracle. Acknowledged revision advances iff one changed host presentation completes through its exact plan and is acknowledged.

Unit tests may replace clocks/providers/projectors at designed seams. Performance acceptance keeps topology, pane fleet, adapter, worker, persistent host, table child, viewport, binding, EventBus, cache, sampler, OTLP, and Victoria real. Native proof binds the exact debug PID for empty/content presentation, appearance, scrolling, hover, collapse, menus, commands, focus, and accessibility; paired profiles bind the same marker/PID.

## External Boundary Note

DeepWiki inspection of `ghostty-org/ghostty` identifies `ghostty_surface_read_text` as expensive, mutex-protected, caller-freed text extraction and describes viewport-relative bounded selection for trailing visible rows. The local vendor submodule is intentionally not hydrated in this worktree, so the pinned-vendor selection semantics remain a required integration proof seam rather than an assumed implementation detail.

## Requirement Coverage

| Requirement identity | Disposition | Design anchor |
| --- | --- | --- |
| U-PERF-1 | covered | keyed pre-capture admission, visible-only native materialization, separate idle/action CPU gates |
| U-ADMISSION-1 | covered | source disposition, invalidation accumulator, repository projection coalescing |
| U-CURRENTNESS-1 | covered | complete equality, persistent empty/content acceptance, deferred pane fact, validated Forge/cache apply |
| U-ISOLATION-1 | covered | materialized capture, topology-owned keys, off-main worker/update planning, visible-bounded MainActor table apply |
| U-BOUNDS-1 | covered | one active/one pending, bounded invalidation sets, deadline state machines |
| U-OBSERVABILITY-1 | covered | bounded stage evidence, aggregate hot diagnostics, zero-drop proof |
| U-PRESERVATION-1 | covered | explicit preserved edges plus Tab Bar immediate settlement/no-partial-list |

## Tradeoffs And Revisit Signals

- Key-specific observations add lifecycle bookkeeping to the adapter. The adapter owns this cost because it alone knows grouping and rendered demand. Revisit only if observation registration itself becomes an often/heavy measured lane.
- The persistent host and table child replace a concise conditional empty/`List` tree. Repo Explorer pays explicit shell/cell/viewport lifecycle so every visible state has one acceptance owner; revisit only if it misses UX or CPU targets.
- Full grouping, sort, search, or membership replacement uses the exact off-main `RepoExplorerNativeUpdatePlan`; AppKit receives prevalidated old/new index spaces while cells remain visible-bounded. This increases plan proof and anchor complexity, paid by Repo Explorer. The mandatory cell-free pilot is the falsifier: failure returns to design rather than licensing broad reload or MainActor diff.
- Async drain adds continuation bookkeeping and can extend failed-run cleanup beyond 30 seconds; Eager/Family pays it because only the primitive knows detached termination. The pilot pays one full liveness projection and immutable template preparation per scale, then measures native replay. Revisit if this honest composition still misses 30 seconds—never by releasing undrained work, weakening policy, using scoped delta, or restoring 440 full projections.
- Native acceptance adds one feature-private acknowledgment and holds the existing Eager lane open through downstream settlement. The cost is slightly longer pending latency and explicit lifetime/demand/baseline state; the gain is that no successor can plan from unaccepted rows. Revisit only if synchronous native application demonstrably makes the barrier unnecessary; do not replace it with a second scheduler or generation-as-revision shortcut.
- The adapter retains two baselines: latest current semantic result and last native acknowledgment. This is intentional rather than duplicated truth because equal semantic changes can feed the next delta without changing rendered rows. The invariant is that semantic sequence may advance on equal, while native revision advances iff a changed AppKit transaction acknowledges success.
- Stable layout classes avoid fleet measurement, while wrapping rows pay one represented-visible width measurement and possible anchored height correction. Repo Explorer owns the small correction risk; offscreen eager measurement is forbidden.
- The App command-presentation batch remains a separate App-owned projection and therefore adds generation/visible-revision routing into the Feature. App pays that composition bookkeeping; Feature rows stay direct-value consumers and dispatcher execution remains authoritative.
- Viewport demand from native visible rows is exact but MainActor-bound because AppKit geometry is MainActor-owned. It is coalesced once per turn and bounded by visible rows. Revisit only if scroll proof shows this bounded calculation exceeds its performance classification.
- Separate zero-PTY and quiescent-PTY idle runs increase proof time. The cost is borne by the verifier because combining the variants would hide idle-shell or empty-app false greens.
- Atomic repository projections can coalesce a very short loading interval away; this favors latest honest state over displaying every provider lifecycle edge. Revisit only if an explicit product requirement demands minimum spinner visibility.
- Bounded Ghostty tail selection depends on the pinned vendor contract. If it is unavailable or slower than the measured full-viewport exception, preserve the behavioral interface and choose the lowest-cost proven implementation without moving surface lifetime authority off MainActor.
- Making `EagerDerivedAtom` true single-flight may delay a newest request until cancellation settles. The payer is newest-result latency under expensive non-cooperative work; cancellation checkpoints and maximum termination latency are therefore proof obligations.
