# Performance Program — Program Design

Structural realization of the fixed observable contract in
[Requirements](requirements.md) and
[Specification](2026-08-10-performance-program.md).

**Artifact set** — [Requirements](requirements.md) (WHY) →
[Specification](2026-08-10-performance-program.md) (WHAT) →
Program Design (this file, HOW) ·
supporting: [doc-drift inventory](doc-drift-inventory.md) ·
[plans](plans/) ·
[Linear — AgentStudio Performance](https://linear.app/askluna/project/agentstudio-performance-af1a052f81d5)

Source anchors use `origin/main` at `f3b0fa1824d80967e38668d32b062d73f72fbbe8`.
The drafting worktree is older at `ca4cb95c47bb4603659cbf350e9160dac2192650`;
all load-bearing newer paths were re-opened from `origin/main`.

## Integrated structural overview

The program contracts waste at the earliest owner that has enough semantic
information to decide safely. Source owners suppress equal work before a
MainActor hop; trigger owners coalesce and gate before expensive compute;
keyed projection owners capture only declared entities before off-main
materialization; startup publishes usable placeholders before terminal
surface creation. `EventBus` remains a fact transport, canonical atoms remain
the state owners, and existing telemetry, recovery, persistence, command, and
trust boundaries remain authoritative.

```text
interactive input                         runtime facts
(command bar, tab, divider, Cmd+R)        (terminal, filesystem, git, forge)
        │                                         │
        ▼                                         ▼
owning controller records boundary       source owner applies admission
        │                                ├─ equal/redundant → suppress + metric
        │                                ├─ undemanded → defer + re-admit trigger
        │                                └─ uncertain → proceed
        │                                         │
        ├──────────────────────────────┐          ▼
        │                              │    EventBus fact transport
        ▼                              │    └─ interest-matched delivery only
published terminal state                │
        │                              ▼
        └──────── latency/outcome ─► performance telemetry
                                      │ trace-tag gated
                                      │ OTLP scrub projection
                                      ▼
                               VictoriaMetrics / Logs
                                      │
                                      ▼
                                perf:report

canonical atom owners
  ├─ keyed AtomFamily slots ─► reusable eager keyed-projection seam
  │                             ├─ consumer-declared key set
  │                             ├─ off-main materialization
  │                             └─ generation-checked MainActor publish
  └─ cold snapshots only

launch restore
  └─ placeholder publication ─► interactive frame
                                 └─ deferred/chunked SurfaceManager creation
                                    ├─ ready: replace placeholder + attach zmx anchor
                                    └─ failed: existing health/recovery presentation
```

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

No new persistence schema, external service, command plane, trust boundary,
or vendor dependency is introduced.

## Admission gates are source-owned behavioral boundaries

Every gate implements R-INV as one local decision:

| Gate | Decision | Equivalence checkpoint | Failure behavior |
|---|---|---|---|
| Suppression | equal/redundant → drop; changed → proceed | end of the fact sequence | uncertainty proceeds |
| Coalescing | merge sufficient evidence into one admission | end of the coalesced sequence | overflow widens scope rather than losing evidence |
| Deferral | undemanded → retain eligibility debt; demanded → admit | first settled demanded/visible point | re-admit within the stated interval |
| Targeting | subscription/key does not match → do not deliver/wake | same published end state for matching consumers | ambiguous match proceeds |

The authoritative equality decision belongs where the owner has both the
candidate projection and its last-published value. This follows the existing
Terminal Contract-7 source-contraction shape:
`origin/main:Sources/AgentStudio/Features/Terminal/Ghostty/TerminalLocalActionAccumulator.swift:202-282,319-367`.

Waste-ratio and outcome telemetry is emitted at the publication/admission
site, where `equal`, `changed`, `deferred`, and `uncertain_proceeded` have
unambiguous meaning. Gates use injected clocks where time affects admission;
source dependencies remain replaceable by deterministic fakes.

Rejected alternatives:

- **Bus-side semantic filtering** would centralize equality but make the
  transport interpret product facts. It is rejected because `EventBus` is the
  fact plane, not a command or domain-policy owner
  (`CLAUDE.md:642-690`). Revisit only if a future transport contract itself
  becomes the authoritative topic-policy boundary.
- **Consumer-side equality** preserves current ownership but spends scheduling,
  MainActor capture, and delivery before rejecting work. It is rejected because
  the measured waste has already occurred. Revisit only if source-side equality
  is provably more expensive than the avoided downstream work.

## Slice 1 — Measurement and enforcement rails

### Current state and target composition

`AgentStudioPerformanceTraceRecorder` already gates the performance lane on
the `performance` trace tag and queues source-side records
(`origin/main:Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:116-227`).
OTLP projection allowlists marker identity and scrubbed performance attributes
(`origin/main:Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioOTLPTraceProjection.swift:36-55,374-488`).

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

The interaction boundaries remain with their existing owners:

- command-bar open/dismiss: `CommandBarPanelController.show` and `dismiss`
  (`origin/main:Sources/AgentStudio/Features/CommandBar/CommandBarPanelController.swift:120-190,647-673`);
- tab reorder commit: `DraggableTabBarHostingView.performDragOperation`
  (`origin/main:Sources/AgentStudio/App/Panes/TabBar/DraggableTabBarHostingView.swift:468-480`);
- divider samples: `FlatPaneDivider` and nested `SplitView` drag callbacks
  (`origin/main:Sources/AgentStudio/Core/Views/Panes/FlatPaneDivider.swift:80-115`;
  `origin/main:Sources/AgentStudio/Core/Views/Panes/SplitView.swift:108-142`);
- Cmd+R admission: `AppCommandDispatcher`, with `.toggleManagementLayer`
  bound to Cmd+R
  (`origin/main:Sources/AgentStudio/App/Commands/AppCommandDispatcher.swift:8-38`;
  `origin/main:Sources/AgentStudio/Core/Actions/Commands/AppShortcut.swift:357-361`).

Each owner retains the interaction start and records duration only when its
R1 terminal state is published. No central interaction coordinator is added.
[GAP: current source has no common “no invalidation pending from this input”
token for command-bar, tab-move, divider, or Cmd+R settlement; each owning
surface must expose an inspectable terminal callback without changing command
ownership.]

Repo Explorer currently measures request construction, worker work, row-index
construction, and the `cachedProjectionResult` assignment
(`origin/main:Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift:641-669,753-835`).
The native SwiftUI outline consumes `rowIndex.entries`
(`origin/main:Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift:316-335`).
[GAP: no current source hook observes completion of SwiftUI’s internal
`OutlineListCoordinator.diffRows`; the existing `mainactor_apply` duration
ends at assignment and is not an outline-apply probe.]

`perf:report` is a new headless script plus mise surface. It queries the
existing loopback VictoriaMetrics and VictoriaLogs endpoints, resolves
candidate and baseline only from completed marker-scoped windows, and prints
the C2 report without launching the app or generating telemetry. Existing
verifiers bind `agent.proof.marker` and require completion records, for example
`scripts/verify-debug-observability.sh:349-521` and
`scripts/verify-title-pane-performance-workload.sh:227-294`.
[GAP: current proof runners use more than one completion message—launch
success and diagnostic completion—so C2 needs one documented resolver mapping,
not a newly invented completion record.]

The four R4 rules live in the SwiftSyntax architecture-lint registry. Their
initial report-only state uses the existing warning/review classification;
R19 changes the affected rule/surface to blocking error. Stable IDs, severity,
and proof remain recorded in
`docs/architecture/structure/architecture_lint_inventory.md:1-25,62-83`.
The concise R5 contract lives in `CLAUDE.md` beside the existing high-volume
source rule (`CLAUDE.md:518-525`).

```text
current: input → owner → publish
proposed: input → owner [start] → publish/settle [duration + outcome]
                                      └─ trace tag → scrub projection → Victoria
new report path: completed Victoria windows → C2 resolver → ranked stdout
new lint path: SwiftSyntax rule → warning/report-only → per-surface error
```

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

Allowed edges are controller → performance recorder, report → loopback
Victoria APIs, and lint registry → diagnostics. Telemetry must not carry
content, raw paths, or UUIDs; report code must not launch the app; lint must
not move into shell/regex architecture scanners. Proof seams are V1, V2, V4,
V5, and V7.

## Slice 2 — Terminal equality and targeted fact delivery

### Current state and target composition

Terminal-local actions already have independent `.immediate` and `.title`
lanes, a retained title deadline, and an off-main scheduler whose drain enters
the MainActor
(`origin/main:Sources/AgentStudio/Features/Terminal/Ghostty/TerminalLocalActionAccumulator.swift:202-282,319-367`;
`origin/main:Sources/AgentStudio/Features/Terminal/Ghostty/TerminalLocalActionDrainScheduler.swift:26-136`).
The accumulator gains per-surface last-published title/CWD projections.
Before requesting a drain, it compares the projected retained value with that
publication state. Equal values record suppression and do not schedule the
MainActor; uncertain comparison proceeds.

Ghostty CWD currently splits at `.pwd`: one branch calls
`SurfaceView.pwdDidChange`, reaches `SurfaceManager.surfaceCWDChanges`, and
updates the coordinator; the other publishes `.cwdChanged` through the
runtime bus and reaches the same coordinator lookup
(`origin/main:Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyActionRouter.swift:268-282`;
`origin/main:Sources/AgentStudio/Features/Terminal/Ghostty/SurfaceManager.swift:631-702`;
`origin/main:Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator.swift:309-357,563-571`).

The target keeps local SurfaceManager metadata current but gives only the
exact runtime CWD fact permission to call
`updatePaneCWDAndResolvedContext`. The SurfaceManager CWD stream ceases to be
a second coordinator-publication path. One distinct CWD therefore performs
one topology lookup and one pane mutation attempt.

`EventBus.post` currently yields every envelope to every subscriber
(`origin/main:Sources/AgentStudio/Core/RuntimeEventSystem/Events/EventBus.swift:182-260`).
The existing `subscribe(policy:subscriberName:)` boundary gains a declared
event-kind/topic interest descriptor. `post` matches that fact-only descriptor
before yielding; buffering, replay, delivery diagnostics, and fact semantics
remain unchanged. Subscribers may not place command semantics or mutable
product policy in the descriptor.

```text
current CWD:
Ghostty .pwd ─┬─ SurfaceView → SurfaceManager stream ─┐
              └─ TerminalRuntime → EventBus ──────────┴→ coordinator lookup

proposed CWD:
Ghostty .pwd → local SurfaceView metadata
            └→ one exact TerminalRuntime CWD fact → interested subscribers
                                               └→ one coordinator lookup

current bus:   post → every subscriber → consumer-side switch
proposed bus:  post → fact-interest match → matching subscriber → switch
```

Accumulator publication state and subscription interest are runtime-only.
Drain claims remain per surface/lane; exact facts preserve ordering.
Cancellation cannot convert uncertain work into suppression. Proof seams are
lossless sequence tests, one-CWD/one-lookup observation, targeted-delivery
counts, and waste-ratio telemetry under V2, V3, and V8.

## Slice 3 — Bounded and demand-aware background triggers

### Current state and target composition

`GitWorkingDirectoryProjector` already owns pending work, bounded status
admission, quiescence, failure backoff, and priority
(`origin/main:Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector.swift:502-542,583-617,789-860`;
`origin/main:Sources/AgentStudio/Core/RuntimeEventSystem/Git/GitWorkingDirectoryProjector+Admission.swift:11-97`).
That owner remains authoritative:

- R9 extends its quiescent per-worktree state into a policy-derived adaptive
  interval; unchanged results lengthen cadence, changed results restore prompt
  cadence, with constants in `AppPolicies`.
- R10 replaces pending latest-wins assignment
  (`GitWorkingDirectoryProjector.swift:266-268,535-538`) and retry selection
  (`GitWorkingDirectoryProjector+StatusBackoff.swift:206-214`) with a union of
  affected paths while retaining the freshest ordering/context metadata.
- R12 adds eligibility to projector admission: visible worktrees from
  `SidebarVisibleWorktreesRuntimeAtom`, active-pane demand, and explicit
  requests are admitted; undemanded work remains deferred and visibility
  re-admits it within one interval. Current visibility only affects immediate
  refresh and priority (`GitWorkingDirectoryProjector.swift:317-323`;
  `GitWorkingDirectoryProjector+Admission.swift:86-96`).

R11 changes watched-folder refresh from the current fleet-wide call
(`origin/main:Sources/AgentStudio/App/Coordination/FilesystemGitPipeline.swift:116-119`)
to affected-worktree admission derived through the filesystem→git pipeline.
The explicit user refresh-all entry remains exempt.

`ForgeActor` retains repo registration and polling ownership but adds per-repo
in-flight state, failure backoff, and last-published count-map equality before
posting. Current awaited provider calls publish every successful map and have
no per-repo flight guard
(`origin/main:Sources/AgentStudio/Core/RuntimeEventSystem/Forge/ForgeActor.swift:145-165,202-259`).

R21 bounds the `DarwinFSEventStreamClient`→`FilesystemActor` stream. Current
construction has no buffering policy
(`origin/main:Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/DarwinFSEventStreamClient.swift:27-60,192-200`).
On overflow, the ingress owner sets a coarser affected-scope refresh flag;
it never treats missing buffered paths as “no change.”

R22 reverses the current Bridge ordering. Today product invalidation and
fleet activity recapture run before `FilesystemProjectionIndex`
(`origin/main:Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+FilesystemSource.swift:114-145,193-238`).
The target first obtains affected intents from the index, then admits Bridge
product invalidation only for matching pane/worktree keys. The index remains
the filtering owner
(`origin/main:Sources/AgentStudio/App/Coordination/FilesystemProjectionIndex.swift:282-307,395-449`).

```text
filesystem callback
  → bounded ingress [overflow → coarse affected-scope flag]
  → FilesystemActor coalescing
  → affected worktrees
  → projector union + demand gate + adaptive cadence
  → bounded git compute → equality publication
  → affected-key index → eligible Bridge invalidation

forge trigger → per-repo single-flight → provider
             ├─ failure → per-repo backoff
             └─ equal map → suppress / changed map → fact publication
```

Allowed dependencies are source actor → `AppPolicies`, App composition →
runtime visibility/demand facts, and affected index → coordinator sequencing.
EventBus must not own eligibility; visibility is not persisted; overflow must
not drop scope. Proof uses injected-clock state transitions, union/overflow
equivalence, affected-key isolation, single-flight overlap, and V2/V3/V8
telemetry.

## Slice 4 — Reusable keyed capture and off-main projection

### Current wake path

The merged eager foundation has one generic materialization owner. It uses the
documented narrow `Task.detached` exception for cancellation-resistant
projection work: `admit` cancels the retained task, `stop` revokes it, and the
actor-isolated completion path accepts results only when generation, request
identity, and revocation epoch still match
(`origin/main:Sources/AgentStudio/Infrastructure/AtomLib/EagerDerivedAtom.swift:54-108,148-183`).
`EagerDerivedAtomFamily` owns per-key readiness and lifecycle
(`origin/main:Sources/AgentStudio/Infrastructure/AtomLib/EagerDerivedAtomFamily.swift:43-150`).

Tab Bar is the sole product adopter. It observes one tab, captures a request,
admits the per-tab projection, and publishes the collection only when every
retained tab has a current value
(`origin/main:Sources/AgentStudio/App/Panes/TabBar/TabBarAdapter.swift:165-246,265-297`).
Its capture still includes a complete topology snapshot
(`origin/main:Sources/AgentStudio/Core/State/MainActor/Atoms/RepositoryTopologyAtom.swift:14-58,198-209`).

Repo Explorer remains broader. Its observation reads the complete topology,
every sidebar repo/worktree fact, all-tab/pane placement, and Bridge attendance
before its worker starts
(`origin/main:Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift:106-155,641-669`;
`origin/main:Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+ProjectionHelpers.swift:59-114`).
The worker itself is correctly off-main and cancellation-aware
(`origin/main:Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerProjectionWorker.swift:80-134`).

```text
current unrelated topology/pane/attendance write
  → broad Repo Explorer observation wakes
  → MainActor rebuilds complete request
  → request-key comparison
  ├─ equal → stop after capture cost
  └─ changed → cancel old worker
              → detached full projection + RowIndex
              → generation check
              → replace complete cached result
              → SwiftUI traverses complete entries array
```

### Target component tree and ownership

```text
Infrastructure / AtomLib
  reusable eager keyed-projection seam
    owns: per-key admission identity, cancellation, revocation, freshness
    consumes: Sendable request + equality function + pure projector
    knows no: CoreAtoms, product keys, repos, tabs, panes, Feature state

Core
  RepositoryTopologyAtom
    owns: canonical repo/worktree values
    exposes: keyed repo slots, keyed worktree slots, membership generation
  product keyed-capture adapters
    own: mapping declared consumer keys to immutable Sendable rows
    read: only keyed AtomFamily slots and structural membership generation

RepoExplorer Feature
  Repo Explorer capture owner
    owns: rendered/derived key set and feature request composition
  RepoExplorerProjectionWorker
    owns: off-main projection and row-index construction
  RepoExplorerView
    owns: MainActor binding/publish and native outline presentation

App composition
  supplies sibling Feature facets as keyed read-only projections
  never gives Repo Explorer ambient sibling Feature atoms
```

The generic seam is the existing eager lifecycle generalized around a
consumer-declared key set. Infrastructure owns scheduling semantics only.
Core and Feature adapters perform product capture; this preserves the
AtomLib boundary in `CLAUDE.md:328-363`.

`RepositoryTopologyAtom` changes from broad observable `repos` plus ignored
indexes (`origin/main:Sources/AgentStudio/Core/State/MainActor/Atoms/RepositoryTopologyAtom.swift:60-75,119-149`)
to keyed repo/worktree slots with a membership generation. Structural
insert/remove/reorder wakes membership consumers; metadata changes wake only
the owning entity slot. Broad arrays and `captureReadSnapshot()` remain
cold-path APIs only.

Repo Explorer declares the keys needed for its current rendered/derived set.
Per-repo, per-worktree, per-pane, per-tab, Bridge-attendance, and cache-fact
rows are captured through their owning keyed readers. These immutable rows
form the request identity. MainActor performs keyed capture and final binding;
the worker retains pure projection and row-index work.

Facet-scoped rows follow the same edge:

- inbox unread/roll-up counts stop reducing the whole observable notification
  array for every row; current broad reduction is at
  `origin/main:Sources/AgentStudio/Features/InboxNotification/State/MainActor/Atoms/InboxNotificationAtom.swift:33-76,345-358`;
- zoom uses the existing per-tab family reader rather than
  `zoomPresentationsByTabId`
  (`origin/main:Sources/AgentStudio/Core/State/MainActor/Atoms/WorkspacePanePresentationAtom.swift:62-80`);
- command capability presentation stops observing whole tabs, topology,
  zoom maps, and every pane
  (`origin/main:Sources/AgentStudio/App/Windows/RepoExplorerCommandPresentationBatch.swift:45-119`);
- Bridge attendance replaces the whole `ordinalSnapshot()` edge with keyed
  pane reads
  (`origin/main:Sources/AgentStudio/Features/Bridge/State/MainActor/Atoms/BridgePaneAttendanceAtom.swift:18-41`).

```text
proposed keyed wake:
entity/facet K changes
  → AtomFamily slot K wakes
  → consumer recaptures declared key K / affected membership
  → eager seam admits request identity for K
  → off-main materialization
  ├─ cancelled/superseded → discard, no publish
  ├─ equal → mark current, no revision/publication
  └─ changed → current generation only
               → MainActor bind/publish affected result
               → owning row/outline receives bounded change
```

State is runtime-derived and nonpersistent:

| State | Owner | Concurrency rule |
|---|---|---|
| declared key set | consumer capture owner | changes only on MainActor observation |
| keyed canonical values | owning Core/Feature atom | mutations remain MainActor-serialized |
| request identity/freshness | eager keyed seam | latest generation wins |
| projection/row index | RepoExplorer worker/result | immutable and Sendable |
| published result | RepoExplorer view | bind/publish only on MainActor |

Cancellation is cooperative but correctness does not depend on prompt worker
termination: revocation epoch and generation checks reject stale completion.
A missing keyed slot remains observable for later insertion. Capture ambiguity
proceeds rather than suppressing. Removing a key stops and retains any
unsettled atom only until its work settles, matching the existing family
lifecycle.

Allowed edges are Feature/Core capture → generic eager seam and App-provided
read-only sibling projections → Feature. Forbidden edges are AtomLib →
product state, worker → atoms/AppKit, Repo Explorer → sibling Feature mutable
atoms, and hot capture → whole-topology snapshots.

Proof seams are per-key observation isolation, missing-key insertion,
unrelated-key non-wake, cancellation/supersession, equal non-publication,
membership-only structural wake, MainActor capture/apply duration, off-main
worker duration, outline-apply duration, and marker-scoped waste ratio under
V2/V3/V8.

The selected general seam avoids two adopters implementing separate
generation/cancellation/readiness contracts. Its accepted cost is a bounded
generic API plus Core/Feature capture adapters. Falsifier: if the general API
must expose product concepts, grows beyond the existing eager lifecycle
surface, or regresses Tab Bar isolation/publication, return to a per-surface
design.

## Slice 5 — Placeholder-first deferred terminal creation

### Current path and preserved owners

Current launch readiness is owned by `WindowLifecycleAtom`: nonempty terminal
bounds plus `isLaunchLayoutSettled`
(`origin/main:Sources/AgentStudio/Core/State/MainActor/Atoms/WindowLifecycleAtom.swift:27-40,137-150`).
`WindowRestoreBridge` turns that state into one restore signal
(`origin/main:Sources/AgentStudio/App/Lifecycle/WindowRestoreBridge.swift:22-62`).

Launch restore then installs frames and awaits the prepared-content mount
coordinator
(`origin/main:Sources/AgentStudio/App/Boot/AppDelegate+LaunchRestore.swift:10-60`).
`TerminalActivationScheduler` is already an off-main cohort owner, but every
terminal admission enters a `@MainActor` port
(`origin/main:Sources/AgentStudio/Features/Terminal/Restore/TerminalActivationScheduler.swift:5-9,70-108,160-166`;
`origin/main:Sources/AgentStudio/App/Coordination/PreparedTerminalMountAdmissionPort.swift:14-20,61-89`).

`SurfaceManager` is `@MainActor` and creates `Ghostty.SurfaceView`
synchronously
(`origin/main:Sources/AgentStudio/Features/Terminal/Ghostty/SurfaceManager.swift:11-15,148-231`).
`SurfaceView.init` embeds its `NSView` pointer and calls
`ghostty_surface_new` synchronously
(`origin/main:Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift:347-465`).

```text
current:
WindowLifecycle ready
  → finishLaunchRestore
  → prepared mount coordinator
  → TerminalActivationScheduler workers
  → MainActor admission port
  → SurfaceManager.createSurface
  → SurfaceView.init → ghostty_surface_new [synchronous MainActor]
  → attach/display → restore settles
```

The target publishes `.preparing` terminal placeholders for the accepted
restore cohort before surface creation. It reuses
`WorkspaceSurfaceCoordinator.registerTerminalPlaceholderIfNeeded`
(`origin/main:Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+TerminalPlaceholders.swift:7-72`)
and the existing `.preparing`/`.failedToStart` presentation states
(`origin/main:Sources/AgentStudio/Features/Terminal/Hosting/TerminalStatusPlaceholderView.swift:5-12,45-98`).

After the first interactive frame, the existing prepared-content coordinator
releases terminal admissions in bounded chunks. The scheduler retains cohort,
priority, retry, and settlement ownership; the MainActor admission port yields
between chunks. `SurfaceManager` retains creation, attachment, health, and
destruction ownership.

```text
proposed:
accepted restore cohort
  → register placeholder host for each terminal pane
  → window publishes usable placeholder composition
  → first interactive frame signal
  → prepared-content coordinator releases bounded chunk
  → MainActor admission port
  → SurfaceManager creates one surface
  ├─ ready → attach to pane → bind stored zmx anchor → replace placeholder
  └─ failed → placeholder.failedToStart → retry/close + health flow
  → MainActor yield
  → next bounded chunk
```

Stored terminal identity remains authoritative. The existing restore runtime
derives the zmx attach command from `TerminalState.zmxSessionID`
(`origin/main:Sources/AgentStudio/Features/Terminal/Restore/TerminalRestoreRuntime.swift:29-53`);
deferred creation must not generate a replacement session or rewrite restored
composition. Current failure already rolls back prepared runtime and publishes
`.failedToStart`
(`origin/main:Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ViewLifecycle.swift:183-197,337-374`).
Surface death continues through existing health delegates and repair UI
(`origin/main:Sources/AgentStudio/Features/Terminal/Ghostty/SurfaceManager.swift:731-775`).

State transitions are:

```text
restored identity
  → placeholder.preparing
  → creation admitted
  ├─ surface ready → attached/running
  ├─ creation failed → placeholder.failedToStart
  └─ generation replaced → cancelled; newer cohort remains authoritative

failedToStart
  ├─ retry → placeholder.preparing → creation admitted
  └─ close → existing pane/tab close command
```

No AppKit object, Ghostty pointer, or C-string lifetime crosses an executor.
Preparation may move off-main only when current APIs prove the value is owned
and `Sendable`. No ghostty or zmx vendor code changes are authorized.

[GAP: local source proves that `ghostty_surface_new` currently receives an
`NSView` pointer synchronously, but does not establish an upstream thread-safety
contract or a supported off-main preparation API. Until proven otherwise,
creation stays on MainActor and only its restore-time placement is deferred.]
[GAP: `WindowLifecycleAtom.isReadyForLaunchRestore` proves layout settlement,
not a rendered first interactive frame; the target needs an existing or
source-provable AppKit frame callback rather than equating these facts.]
If one deferred MainActor creation still blocks long enough to miss R17/V6,
the no-vendor structure is falsified and the program returns for an explicit
vendor-work decision.

The time-to-usable probe starts from the existing launch marker and ends when
WindowLifecycle launch-settle facts and the usable placeholder composition
are published. Proof seams cover placeholder-first ordering, generation
replacement, chunk/yield ordering, exact zmx identity, failure presentation,
health recovery, and marker-scoped V2/V6/V8 deltas.

## Requirement realization and proof seams

| Requirement | Structural owner and realization | Proof seam |
|---|---|---|
| R-INV | each source admission owner; uncertain proceeds, suppression/deferral checkpoints remain explicit | deterministic reference-vs-gated sequence |
| R1 | four owning interaction controllers/dispatcher | V1 input-to-terminal-state metrics |
| R2 | Repo Explorer apply owner and startup lifecycle owner | V2 duration/outcome metrics |
| R3 | headless report script and mise surface | V4 success, selection, partial-data, unreachable-stack transcript |
| R4 | SwiftSyntax architecture-lint registry | V5 stable rule IDs and diagnostics |
| R5 | CLAUDE performance contract | V7 inspection |
| R6 | Terminal accumulator/drain publication gate | V2/V3 equal projection never schedules MainActor |
| R7 | Ghostty action router plus single runtime CWD publication | V3 one distinct CWD, one coordinator lookup |
| R8 | EventBus subscription interest matching | V3/V8 unrelated subscriber receives no delivery |
| R9 | GitWorkingDirectoryProjector adaptive cadence state | V8 injected-clock unchanged/change cadence |
| R10 | projector pending/backoff union | V3 burst union equals ungated end state |
| R11 | FilesystemGitPipeline affected-worktree mapping | V3/V8 watched refresh scope; explicit refresh-all exemption |
| R12 | projector eligibility admission | V3/V8 zero undemanded admission and bounded re-admission |
| R13 | ForgeActor per-repo flight/backoff/equality state | V3 overlap, failure, and equal-publication tests |
| R14 | keyed capture adapters and eager keyed seam | V2/V3 unrelated entity/facet non-wake |
| R15 | inbox, zoom, attendance, capability keyed row facts | V3 owning-row-only observation |
| R16 | RepoExplorerProjectionWorker plus bind-only MainActor owner | V2/V8 worker/apply placement and duration |
| R17 | placeholder owner, prepared mount coordinator, SurfaceManager | V2/V6/V8 time-to-usable and failure recovery |
| R18 | owning architecture documents and closed drift inventory | V7 each D1–D16/M1–M12 resolved once |
| R19 | architecture-lint severity classification | V5 cleaned surface flips to blocking |
| R20 | interaction owners plus perf report comparison | V1/V8 plan-set thresholds and baseline delta |
| R21 | Darwin ingress capacity boundary and coarse-scope overflow | V3 overflow preserves affected-scope end state |
| R22 | FilesystemProjectionIndex before Bridge invalidation | V2/V3 unrelated pane/CWD admits no Bridge work |

## Debt, falsifiers, and feasibility gaps

- Source-side gates intentionally duplicate small comparison state across
  owners; this cost is paid by each lane owner to avoid centralizing semantics.
- EventBus interest matching reduces delivery work but is not equality,
  eligibility, coalescing, or command policy.
- Broad snapshots remain permitted for persistence, cold bridges, and measured
  exceptions; hot capture cannot use them.
- The keyed seam is revisited if it leaks product concepts, expands beyond a
  bounded lifecycle API, or regresses the existing Tab Bar contract.
- The startup design is revisited if placeholder-first presentation worsens
  perceived readiness, changes restore ordering, or a deferred creation still
  violates the accepted interaction threshold.
- Native outline-diff causality remains unproven. Structural broad-wake removal
  is justified by R14/R16, but must not be described as the confirmed cause of
  the 2026-08-07 sample.
- Interaction terminal-state hooks, native outline completion, the shared
  completion-marker resolver, first-interactive-frame evidence, and Ghostty
  threading feasibility remain the explicit `[GAP: ...]` items above.
- No gap authorizes a persistence migration, vendor modification, second event
  plane, new trust boundary, or compatibility path.

## Structural resolutions (integrated after independent design review)

These resolutions are normative design content refining the sections above;
where they conflict with earlier prose in this document, they govern.

### perf:report resolver boundary (C2 / R3)

The candidate/baseline resolver is owned entirely by the report script
(`scripts/` + mise task). It reads channel identity from the
`dev.release.channel` label and completion from the runners' existing
end-of-run marker records. It introduces no new telemetry lifecycle, no
stored state, and no writer: resolution is a pure query over existing
records, and both resolved identities are printed (C2).

### Interaction probe interfaces (R1)

Each owning interactive controller exposes one narrow settle interface:
`beginInteraction(kind, correlationId)` at the input event and
`settleInteraction(correlationId)` at terminal publication. Correlation ids
are per-interaction; a new `begin` for the same surface cancels and marks the
prior id `superseded` (never reported as latency). Owners: command bar panel
controller (open/close), tab bar controller (move commit), the two divider
owners `FlatPaneDivider`/`SplitView` (per-frame budget, one admitted sample
per frame), command dispatcher (Cmd+R). Settlement is the owner's existing
terminal publication callback; where an owner lacks one, adding that
callback is part of slice 1 (it is an observation seam, not new behavior).
The outline probe measures the outline apply call boundary per the
Specification's defined proxy.

### Terminal accumulator publication state machine (R6)

Current-state defect (source-proven on this branch and origin/main,
owner-confirmed 2026-08-10): after a title batch drains, the accumulator
retains no memory of the applied title, so a repeated identical title from
Ghostty schedules another title-deadline drain and MainActor hop, with
equality checked only after that work. The `committed(v)` state below is the
direct fix: the last successfully published value persists across drains and
equal repeats are dropped at admission.

Per pane, per lane (`title`, `cwd`, `activity`):

| state | on new projection | on MainActor publish ack |
|---|---|---|
| `unknown` (no ack yet) | always schedule (uncertain → proceed) | → `committed(v)` |
| `pending(v')` | equal to v' → drop; else replace pending | → `committed(v')`, clear pending |
| `committed(v)` | equal to v → drop (suppressed); else → `pending(v')` + schedule | — |

The acknowledgement edge is the accumulator's completion callback from the
successful MainActor apply (one new edge from drain scheduler back to
accumulator). Stale generations (pane closed, session detached) drop pending
state; shutdown clears without publishing. Failure to publish keeps
`pending` and reschedules — never silently committed.

### Keyed off-main seam (R14–R16): reuse, not new primitive

The generic lifecycle already exists on origin/main as
`EagerDerivedAtomFamily` (Infrastructure/AtomLib); it is reused unchanged.
No new AtomLib primitive is introduced unless a concrete missing generic
operation is proven during slice 4, in which case that single operation is
added to AtomLib (generic only). Product wiring is Core/Feature-owned
adapters: Repo Explorer declares its key set (repo ids, worktree ids,
per-row facets) and consumes keyed materializations; the request key is
composed from keyed reads only. Broad topology readers are classified:
hot-path readers migrate to keyed slots; persistence, cold bulk bridges,
and mutation-side accumulation retain the array/dictionary paths (existing
rule). The classification table lives with the slice-4 section anchors.

### Startup readiness signal and preparation boundary (R17)

AppKit/Ghostty objects remain MainActor-owned; no vendor change. The
structure is placeholder-first: restore publishes placeholder views, then
`SurfaceManager` creates surfaces serially with MainActor yields between
creations. The first-interactive-frame signal is a one-shot fact emitted by
`ApplicationLifecycleMonitor` (the AppKit ingress owner) from the main
window's first post-launch-settle draw/`CATransaction` completion, recorded
into `WindowLifecycleAtom`; surface creation begins only after that fact.
Feasibility of any true off-main preparation is bounded by what the current
Ghostty wrapper provably allows; if per-surface main-bound creation cost
alone breaks the V6 threshold, that is returned to the owner as a vendor
decision (falsifier), not absorbed silently.

### Ghostty renderer probe (R2 / measure-first)

Owner: the surface render/health layer (`SurfaceManager` + surface view
callbacks). Boundary: frame render begin → present, emitted marker-scoped
under the existing trace-tag gating. Its only role in this program is
measurement and startup attribution for V6; renderer optimization stays out
of scope.

### Animation admission (R23)

Owned by the existing animating surfaces, not a new subsystem: divider/
layout animation configuration (the global-implicit-animation gating issue
verified in the layout investigation) and any priority-surface transition.
Realization: animations run with explicitly scoped transactions (no
implicit inheritance beyond the animating view subtree), and their
completion handlers publish no state whose value is equal to the committed
state (same admission-gate contract as R6). Proof seam: V3 deterministic
tests on the gate; V2 waste-ratio on the affected lanes.

### Report-only lint severity channel (R4)

The architecture linter currently exits non-zero on warnings, so "report-only"
needs a structural home: the linter gains a non-blocking diagnostics severity
class — report-only rules print their findings and do not affect the exit
code; blocking rules keep the non-zero exit. Flipping a rule (R19) is a
severity-class change, PR-visible in the lint inventory doc. This channel is
slice-1 work and is generic linter capability, not per-rule special-casing.

### perf:report completion resolver (C2)

The completion predicate is realized as a resolver table inside the report
script mapping each known proof-runner family to its exact end-record
message. Unknown families resolve to in-flight (fail-safe). The table is the
single home of runner-completion knowledge; runners are not modified.
