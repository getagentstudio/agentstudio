# Terminal Title Cadence And Pane Observation Proportionality — Program Design

Date: 2026-08-06
Status: archived historical cross-cutting design record; not current Repo Explorer guidance

Requirements:
[2026-08-06-terminal-title-pane-entity-observation-requirements.md](2026-08-06-terminal-title-pane-entity-observation-requirements.md)

Specification:
[2026-08-06-terminal-title-pane-entity-observation.md](2026-08-06-terminal-title-pane-entity-observation.md)

> Historical cross-cutting design note. Its Repo Explorer visibility-command
> discriminator is superseded by the current favorites-first contract in
> [2026-08-08-repo-sidebar-favorites-first](../2026-08-08-repo-sidebar-favorites-first/2026-08-08-repo-sidebar-favorites-first-specification.md).
> The terminal and pane-observation design remains historical context; do not
> reintroduce the removed visibility argument.
>
> Archive boundary: the Repo Explorer visibility-command passages in this
> document are retained only to explain the historical cross-cutting change.
> They are not current requirements, interfaces, or proof obligations; use the
> linked favorites-first artifacts for Repo Explorer behavior.

## Structural Overview

The design changes two internal amplification boundaries while retaining their
current semantic owners.

```text
terminal callback owner
  TerminalLocalActionAccumulator
    immediate lane ──► immediate MainActor drain
    title lane ──────► fixed absolute title deadline
    exact barrier ───► detach preceding title only

pane state owner
  WorkspacePaneGraphAtom
    canonical PaneID-keyed state
      ├──► keyed rich-pane readers
      ├──► explicit cold snapshots
      ├──► coarse accepted-commit revision for persistence
      └──► private equality-gated structural facts
             ├──► Repo Explorer projection
             └──► command-presentation snapshot

tab presentation owner
  TabBarAdapter
    membership/order observation
      └──► one item observation scope per tab
```

There is no new actor, event bus, persistence model, durable queue, command
authority, or product-visible API. The title lanes remain two bounded classes
inside the existing per-surface owner. Pane structural facts are rebuildable
projection state inside the canonical pane owner, not a second source of truth.

## Current System And Constraint Degree

The change is compatibility-bound and legacy-observation-bound rather than
greenfield.

### Terminal publication

`TerminalLocalActionAccumulator` currently stores presentation, activity,
search, and title metadata in one `PendingBatch` and gives the surface one
`DrainPhase`. When immediate work arrives during a title window, the phase is
upgraded to immediate. `TerminalLocalActionDrainScheduler` correspondingly
cancels the title deadline and converts the one per-surface claim into a
MainActor admission. `beginDrain` then detaches the complete mixed batch.

Current source anchors:

- `TerminalLocalActionAccumulator.swift:222-260` — one pending batch and phase;
- `TerminalLocalActionAccumulator.swift:318-334` — title-to-immediate upgrade;
- `TerminalLocalActionDrainScheduler.swift:92-134` — one claim and cancellation;
- `GhosttyActionRouter+LocalActions.swift:257-290` — one complete-batch apply.

Exact facts and controls already take the correct separate path:
`detachTitleBeforeExactBarrier` seals title metadata under the accumulator lock,
cancels only a scheduled title-only drain, and the router applies the host and
semantic title effects before the exact event. The mixed `setTitle` then
`setTabTitle` representation already retains `surfaceTitle` and `runtimeTitle`
independently.

Those contraction, exact-ordering, lifetime, host-effect, runtime-event,
sequence, replay, EventBus, IPC, and readiness semantics remain authoritative.
Only cadence and immediate/title claim coupling change.

### Pane observation

`WorkspacePaneGraphAtom` currently exposes one observed
`[UUID: PaneGraphState]`. A title write mutates a nested dictionary value, but
observers cannot subscribe to only that dictionary key or a title-insensitive
fact. `WorkspacePaneDerived.panes` rebuilds the entire rich pane dictionary, and
`WorkspacePaneAtom.panes` exposes that broad shape to hot and cold consumers.

Current source anchors:

- `WorkspacePaneGraphAtom.swift:288-318` — observed dictionary owner;
- `WorkspacePaneGraphAtom.swift:417-424` — nested title mutation;
- `WorkspacePaneDerived.swift:21-38` — whole rich-pane reconstruction;
- `WorkspacePaneAtom.swift:27-56` — broad compatibility facade.

`TabBarAdapter` installs one observation scope that reads the complete tab
layout and complete pane collection, then `refresh` maps every tab into a new
`TabBarItem`. Repo Explorer builds pane locations and Bridge candidates from
the same rich pane collection. Row command presentation calls
`dispatcher.canDispatch` once per presented command and target; the App router
can enter a whole action-state snapshot on each call.

Current source anchors:

- `TabBarAdapter.swift:121-143,163-212` — fleet observation and rebuild;
- `RepoExplorerView+ProjectionHelpers.swift:47-109` — fleet pane inputs;
- `RepoExplorerCommandPresentation.swift:42-70` — per-command live query;
- `PaneTabViewController.swift:2302-2317` — action-state snapshot.

`AtomEntityMap` already supplies keyed present/missing reads, membership
revision, equality-gated writes, replacement, explicit snapshots, and slot
pruning. Its observation tests establish the primitive needed here. The pane
owner has not adopted it, and a naïve adoption would still leave two leaks:
a full `PaneGraphState` slot couples title to same-pane structural readers, and
one observer reading every keyed pane still rebuilds the fleet.

## Structural Crux And Alternatives

The crux is not whether a pane has one canonical state. It must. The crux is
where observation boundaries sit relative to that state.

### Keep the observed dictionary and add output equality checks — rejected

This can suppress some final assignments after the expensive reads and
reconstruction already happened. It does not prevent Repo Explorer command
resolution, whole-workspace capability snapshots, or unrelated item rebuilding.

### Convert only canonical storage to `AtomEntityMap` — rejected

This correctly isolates Pane A from Pane B, but every structural consumer of
Pane A still observes its title because `PaneGraphState` is one slot value. A
single tab-bar observer reading all pane slots also remains a fleet invalidation
boundary. This fails fact and consumer proportionality.

### Split every pane property into an authoritative atom family — rejected

This maximizes theoretical granularity but fragments one pane invariant across
many write owners, complicates multi-field mutation, persistence snapshots,
removal, and replacement, and makes partial state observable. The accepted
behavior needs a small number of dependency classes, not an atom per field.

### Canonical keyed state plus derived structural facts and scoped consumers — selected

One `AtomEntityMap<UUID, PaneGraphState>` remains canonical. The same owner
projects each accepted state into one private
`AtomEntityMap<UUID, PaneStructuralFacts>`. Equality gating means a title-only
write changes the canonical slot but not the structural slot. Tab presentation
uses per-tab observation scopes. Fleet-shaped Repo Explorer and command
presentation consume title-insensitive keyed facts and publish equality-gated
projection outputs.

The cost is a derived structural value, centralized pane mutation, per-tab
observer lifecycle, and one batched presentation interface. The pane owner and
App presentation composition bear that cost. The design should be revisited if
measured hot consumers require another independently changing fact class; that
evidence may justify one additional projection, not automatic field splitting.

## Target Components And Ownership

### `TerminalLocalActionAccumulator`

Remains the sole per-surface contraction and ordering owner. Each surface owns
two independent bounded pending lanes:

```text
ImmediatePending
  presentation + activity + search
  first admission + metrics + phase

TitlePending
  latest semantic callback kind/value
  latest setTitle host value
  first admission + fixed deadline + metrics + phase
```

It exposes lane-specific drain detachment. An immediate detachment cannot read,
remove, reschedule, or publish `TitlePending`. An ordinary title detachment
cannot carry immediate work. The exact-barrier operation is the only non-title
operation permitted to detach title state before its deadline.

All lane state remains under the existing accumulator lock. Search epoch and
activity context remain surface facts shared by their existing immediate
operations; they do not enter the title lane.

### `TerminalLocalActionDrainScheduler`

Remains the scheduling owner, but claims are keyed by surface identity and
lane rather than surface identity alone:

```text
DrainClaimKey = SurfaceID × { immediate, title }
```

An immediate claim uses the existing next-turn MainActor admission. A title
claim carries the absolute monotonic deadline produced by
`TerminalLocalActionAccumulator` from the first pending title admission. The
accumulator passes that value through both the initial and follow-up scheduling
callbacks. The scheduler's title-claim registration and its injected scheduling
seam accept the same absolute deadline; they do not derive a new relative delay
from callback registration or earlier-drain completion. Later title offers
replace data without changing that deadline. A title admitted while the
previous title drain is in progress keeps its own first-admission deadline;
completing the earlier claim forwards that pending deadline and cannot restart
a full window relative to completion.

The scheduler retains admission slack inside the one-second maximum by
scheduling no later than the supplied deadline. The injected seam receives the
absolute deadline as an observable value and remains the deterministic clock
seam. Tokens make cancelled or superseded work items harmless.

### `WorkspacePaneGraphAtom`

Remains the single canonical owner of pane graph state, drawer ownership
invariants, membership, and pane lifetime. Its canonical storage becomes a
private `AtomEntityMap<UUID, PaneGraphState>`.

The owner exposes five distinct read shapes:

```text
paneState(PaneID)             keyed observable canonical read
paneStructuralFacts(PaneID)   keyed observable title-insensitive read
paneIDs                       membership-only observation
paneStateSnapshot()           explicit non-observed canonical bulk read
paneAcceptedCommitRevision    coarse observation of accepted durable changes
```

The broad observable `paneStates` dictionary is removed. The compatibility
facade's ambiguous `panes` property is also removed. Cold consumers that need
rich `Pane` values use an explicitly named bulk snapshot; hot consumers choose
keyed state, membership, or structural facts.

`paneAcceptedCommitRevision` is reserved for persistence and autosave dirty
tracking. The pane owner's existing mutation boundary bumps it once after any
accepted canonical commit and never for equality-suppressed writes or slot
pruning. `WorkspaceStore` observes only that revision, then retains its existing
dirty flag, sudden-termination protection, debounce, and explicit snapshot save
path. The revision exposes neither pane values nor an execution-authority cache.

Every write becomes a copy-transform-commit operation through the pane owner.
The commit applies canonical state, structural facts, drawer indexes, and
membership changes within one MainActor mutation boundary. Direct nested
dictionary mutations disappear, preventing a write path from bypassing derived
projection maintenance.

### `PaneStructuralFacts`

This is a private, immutable, equality-comparable projection sufficient for
title-insensitive workspace presentation:

```text
pane identity
residency class
content kind / Bridge eligibility
drawer parent and owned-drawer structure
filesystem/topology association inputs needed for repo/worktree resolution
capability-relevant placement facts
```

It excludes title, note text, content payloads, terminal contents, and other
facts that cannot change Repo Explorer destinations or command capability.
Repository/worktree identity remains derived according to the existing
CWD/topology authority; structural facts carry only the admitted inputs needed
by that projection. The projection is rebuildable from canonical state and is
never persisted or mutated by a consumer.

### `WorkspacePaneDerived`

Remains the rich-pane composer. `pane(PaneID)` composes only the requested
canonical slot with drawer cursor, repository topology, and enrichment facts.
Its bulk operation is explicitly named as a cold snapshot and cannot be reached
through the hot keyed interface by accident.

### `TabBarAdapter` item observation scopes

The adapter observes tab identity/order and active-tab selection globally, but
does not globally observe pane values. It owns one observation registration and
cached `TabBarItem` per live tab identity.

Each item registration reads only that tab's shell/arrangement/presentation,
the pane identities referenced by that tab, and the keyed pane/enrichment facts
needed to derive its item. On change it recomputes one item, compares the result,
and publishes only a changed item. A custom tab name short-circuits pane-title
reads where the existing display rule permits; a worktree-derived or otherwise
unchanged output is suppressed by item equality.

Tab insertion/removal reconciles item-observer lifetimes. Removed tabs cancel
their registration before cached item removal. Re-registration follows the
existing `withObservationTracking` one-shot contract on MainActor.

### Repo Explorer workspace projection

The existing Repo Explorer projection remains the feature-owned presentation
model. Its pane-location and Bridge-candidate inputs change from rich fleet
snapshots to pane membership plus keyed structural facts and current tab
layout. A title mutation therefore touches none of its dependencies.

The projection may remain fleet-shaped because its output is fleet-shaped, but
it must enumerate membership and perform keyed structural reads. It cannot call
the canonical bulk snapshot. Equality of its immutable request/result continues
to gate publication.

### Batched command-presentation snapshot

App composition supplies Repo Explorer with one immutable presentation result
for its bounded visible command/target requests. The batch interface:

```text
input
  command identity + surface + target identity/type
  + Repo Explorer presentation argument choice

output
  should-present + currently-enabled presentation facts

guarantees
  one coherent capability context per batch
  existing command catalog and validators remain semantic owners
  no command execution and no authority grant
missing/invalid requests present disabled or absent according to catalog
```

The argument choice is a Repo Explorer-owned, hashable presentation
discriminator for no arguments, the requested visibility mode, or the
requested sort order. App composition maps that discriminator to the existing
typed `AppCommandExecutionArguments` while resolving the batch. This keeps
distinct toolbar choices from collapsing into one lookup key without making
App execution types Feature-owned.

The snapshot is application-specific presentation state adjacent to
`SidebarSurfaceHost`. It is not a generic atom primitive, a reusable global
command cache, a persistence owner, or an execution-authority cache.

App composition also owns a capability-context generation. One App-owned
observation scope reads every capability-relevant fact captured by the batch:
tab membership and arrangement, active selection, zoom presentation,
management-layer state, topology, drawer ownership, visibility, and keyed pane
structural facts. An accepted change republishes the generation on MainActor
independently of Repo Explorer's sidebar projection generation. Repo Explorer
combines the latest capability generation with its bounded visible
command/target request set, so the batch refreshes even when no sidebar
projection input changed. The generation is only an invalidation signal; the
batch remains advisory and contains no reusable execution authority.

The App implementation captures the capability-relevant tab, arrangement,
zoom, management, topology, and keyed pane structural facts once, then evaluates
the bounded request set against that context. It reuses the existing validation
rules rather than copying command switches into Repo Explorer.

Repo Explorer body construction reads the immutable result and does not call
`dispatcher.canDispatch`. User actions still call `AppCommandDispatcher`, which
performs current authoritative validation through the existing execution
owners. A stale presentation can therefore be rejected but can never authorize
an invalid command.

### Consumer read-shape policy

Removing `paneAtom.panes` makes every current fleet caller choose an explicit
semantic class:

```text
hot identity-shaped UI
  pane leaves, targeted controls
  ──► keyed canonical or keyed structural read

hot tab-shaped UI
  tab bar labels, controls, visibility items
  ──► one tab-scoped observer over that tab's referenced PaneIDs

hot fleet-shaped presentation
  Repo Explorer destinations, notification/sidebar correlation,
  command presentation
  ──► membership + keyed structural reads + equality-gated projection

execution-time validation
  command dispatch, drag/drop commit, pane actions
  ──► one current explicit action-state snapshot per operation;
      never installed as a SwiftUI observation dependency

cold fleet work
  boot, restore, persistence, IPC bulk read, diagnostics, reconciliation
  ──► explicit canonical or rich-pane snapshot

persistence dirty tracking
  WorkspaceStore autosave observation
  ──► coarse accepted-commit revision; snapshot only while saving
```

Event-driven coordination is not automatically hot merely because it examines
the fleet. A consumer that already has a non-observation trigger uses an
explicit snapshot and must not install that snapshot inside
`withObservationTracking` or a SwiftUI body. A coordination consumer whose only
refresh trigger is Swift Observation—including Bridge pane activity—is hot and
fleet-shaped: it observes membership plus the keyed structural facts on which
its output depends. Likewise, a fleet-shaped sidebar projection remains hot and
uses the title-insensitive structural path even though its output legitimately
covers many panes.

## Dependency Direction And Forbidden Edges

```text
Infrastructure/AtomLib
  AtomEntityMap + AtomRevision + mutation/telemetry primitives
        ▲
        │ generic dependency only
Core WorkspacePaneGraphAtom
  canonical state + accepted-commit revision + private structural projection
        ▲                 ▲                         ▲
        │ keyed read      │ revision               │ keyed structural read
Core derived readers   WorkspaceStore                 │
        ▲                 autosave                     │
        │                                              │
App tab presentation                    Feature Repo Explorer projection
                                                  ▲
App capability-context generation ─────────────────────┘
        └──► App command-presentation composition
```

Forbidden edges:

- Infrastructure does not name pane product types.
- Feature modules do not import App or sibling Features.
- Structural facts do not depend on Repo Explorer or command presentation.
- Hot UI and command presentation do not call canonical bulk snapshots.
- Derived facts and presentation snapshots do not accept writes from consumers.
- Presentation capability does not bypass live command dispatch validation.
- Telemetry does not control cadence, projection, or command correctness.

Package visibility, distinct keyed-versus-snapshot interfaces, and the existing
SwiftSyntax architecture lint enforce these edges. The lint class forbids bulk
pane snapshot access from designated hot UI and command-presentation contexts;
behavior tests prove the dynamic invalidation boundary.

## Title State And Ordering

The two lane phases are independent dimensions:

```text
Immediate lane
  idle ── first immediate offer ──► scheduled
  scheduled ── admitted ──────────► draining
  draining ── new offer ──────────► follow-up pending
  draining/scheduled ── retire ───► removed

Title lane
  idle ── first title offer ──────► pending(deadline = first + 1s)
  pending ── later title ─────────► pending(same deadline, latest value)
  pending ── deadline claim ──────► draining
  pending ── exact barrier ───────► detached-before-exact
  draining ── new title ──────────► next pending(its own first deadline)
  any state ── retire ────────────► removed
```

Legal interleavings:

```text
title pending + immediate offer
  immediate claim/drain proceeds
  title value and absolute deadline remain unchanged

title pending + exact fact/control
  accumulator seals latest title under its lock
  scheduler cancels only matching title claim
  MainActor applies retained host title, semantic title, then exact event

title deadline + immediate claim both admitted
  MainActor serializes applies
  neither lane detaches the other's state

surface retirement
  cancel both lane claims
  delete accumulator state and lifetime watermark as currently required
  stale work-item tokens fail current-claim/lifetime checks
```

The accumulator lock remains ordered before the scheduler lock. Scheduler
callbacks never enter the accumulator while holding the scheduler lock.

## Pane State And Lifecycle

```text
missing read
  └──► nil slot for PaneID
         └── insertion updates same key and wakes that reader

insert
  ├──► canonical slot
  ├──► structural-facts slot
  └──► membership revision

value-only mutation
  ├──► canonical key when content changed
  ├──► structural key only when structural projection changed
  └──╳ membership revision

remove
  ├──► invalidate canonical and structural readers
  ├──► delete both slots and drawer index entries
  └──► membership revision

replace / restore
  └──► one mutation boundary reconciles all three views

teardown / pruning
  └──► invalidate nil slots before removal; active missing readers re-register
```

After every accepted mutation, canonical membership, structural membership, and
drawer indexes describe the same live PaneIDs. The structural projection of
each live canonical value equals the stored structural value. Explicit bulk
snapshots are point-in-time MainActor reads from the canonical map and cannot
become a parallel mutable store.

The graph owner also owns nil-slot pruning. After pane membership/lifecycle
cleanup—removal, replacement/restore reconciliation, or teardown—it prunes
canonical and structural nil slots while excluding the current live PaneIDs.
Pruning invalidates a removed nil slot before deletion. A still-live missing-key
observation receives that invalidation and re-registers through its existing
one-shot observation scope. Therefore stabilized storage is bounded by live
PaneIDs plus missing identities that still have active readers; pruning itself
does not bump the accepted-commit revision.

## Current-To-Target Call-Path Deltas

### Immediate work during a title window

```text
CURRENT
Ghostty callback
  ──► accumulator mixed PendingBatch                         unchanged entry
  ──► phase titleWindow upgraded to immediate                removed
  ──► scheduler cancels title claim                          removed
  ──► beginDrain detaches immediate + title                  removed
  ──► router applies both                                    changed

TARGET
Ghostty callback
  ──► accumulator ImmediatePending                           changed
  ──► scheduler claims (surface, immediate)                  changed
  ──► beginDrain(immediate) detaches immediate only          added
  ──► router applies immediate batch                         changed
  ──► independent (surface, title) deadline remains          added

result/error
  immediate presentation remains prompt;
  missing/retired surface discards the lane through existing lifetime checks.
```

### Ordinary title publication

```text
CURRENT
first title ──► relative 250 ms class ──► complete mixed drain

TARGET
first title
  ──► store latest semantic title + latest setTitle host value
  ──► accumulator computes absolute deadline = first admission + 1s
  ──► scheduling callback and injected seam receive that deadline
  ──► scheduler registers no later than the supplied deadline
  ──► title-only MainActor detach/apply
  ──► existing runtime sequence/replay/EventBus/IPC path

Preserved unchanged:
  changed-value suppression, host-title distinction, surface lifetime guard,
  semantic kind, sequence, replay, EventBus, IPC wait, startup readiness.
```

### Title mutation to pane/tab presentation

```text
CURRENT
runtime title event
  ──► WorkspacePaneGraphAtom dictionary title write
  ──► WorkspacePaneDerived whole dictionary
  ──► TabBarAdapter fleet observer
  ──► rebuild every TabBarItem

TARGET
runtime title event
  ──► WorkspacePaneGraphAtom canonical PaneID slot
  ──► structural-facts comparison is equal; no structural publication
  ──► only tab item scopes that read that PaneID can wake
  ──► equality-gated replacement of only a changed item

Result:
  unrelated pane and tab observers stay quiet; an overridden label may
  recompute in its owning tab scope but publishes no unchanged item.
```

### Repo Explorer and command presentation

```text
CURRENT
RepoExplorerView body/projection
  ──► rich pane fleet snapshot
  ──► commands × visible rows
  ──► dispatcher.canDispatch
  ──► repeated live action-state snapshots

TARGET
Repo Explorer projection trigger
  ──► membership + keyed structural facts + tab facts
  ──► immutable sidebar projection

Capability-relevant state change
  ──► App capability-context observation                     added
  ──► publish independent capability generation             added
  ──► recompute one bounded command-presentation batch       added
  ──► immutable row presentation
  ──► body performs no live capability snapshot

User command
  ──► AppCommandDispatcher                              unchanged
  ──► current execution-owner validation                unchanged
  ──► execute or reject                                 unchanged
```

### Pane mutation to persistence

```text
CURRENT
accepted pane mutation
  ──► observed paneStates dictionary                      removed
  ──► WorkspaceStore marks dirty                         unchanged effect
  ──► disable sudden termination + debounce autosave      unchanged
  ──► save captures current pane snapshot                 changed interface

TARGET
accepted pane mutation
  ──► pane owner commits once and bumps accepted revision added
  ──► WorkspaceStore observes revision                   changed read
  ──► mark dirty + sudden-termination guard + debounce    intentionally unchanged
  ──► save captures explicit canonical snapshot          changed interface

result/error
  pane-only durable changes still schedule autosave; equality-suppressed
  writes and observation-slot pruning do not create false dirty state.
```

## Failure, Recovery, And Concurrency

### Deadline and cancellation races

Every drain claim has a token scoped to surface and lane. Cancellation removes
only the matching claim. A work item that races after cancellation observes a
missing or different token and performs no drain. Absolute title deadlines
prevent follow-up scheduling from sliding a window.

### Immediate/title overlap

The accumulator serializes admission and detachment under one lock; the two
lane phases prevent cross-detachment. MainActor serializes final application.
No retry is required because each lane retains latest bounded state and a
post-drain offer owns its explicit follow-up claim.

### Surface replacement

Retirement cancels both claims and removes both pending lanes. Router lifetime
checks continue comparing the expected surface identity and mounted host before
any host or runtime effect. A replacement surface gets independent state.

### Structural projection mismatch

Consumers cannot create mismatch because they have read-only access. All pane
writes converge on the canonical commit boundary. Restore/replacement builds
both maps from the admitted canonical replacement before publication. Internal
equivalence checks and mutation-sequence proof compare live keys and projected
values; mismatch is an owner invariant failure, not a recoverable second
authority.

### Missing-key and removal churn

Missing reads keep the key observable. Removal and explicit pruning invalidate
before deleting a slot, allowing an active observer to re-register. The pane
graph owner invokes pruning after membership/lifecycle cleanup and supplies the
current live PaneIDs as the retained set. It applies the same lifecycle rule to
canonical and structural maps. Cleanup therefore removes abandoned missing-key
slots while active readers re-establish only the slots they still require,
returning storage to the live-plus-actively-observed quiescent bound.

### Stale command presentation

Presentation is advisory. If state changes between snapshot and click, live
dispatch rejects the request. A presentation recomputation failure contains
itself to absent or disabled presentation; it never weakens execution checks.

## Cutover And Compatibility

The pane observation slice is a hard cut, not a compatibility period:

```text
before cutover
  observed paneStates dictionary + paneAtom.panes

single cutover
  canonical entity map + structural facts + explicit snapshot APIs
  all hot consumers classified and moved to keyed/projection reads
  all cold consumers moved to explicit snapshot reads

after cutover
  no observed dictionary or ambiguous panes compatibility property remains
  WorkspaceStore observes the accepted-commit revision for autosave
```

No database or serialized schema changes. Restore and persistence consume the
same canonical values through an explicit snapshot boundary. Runtime events and
public IPC DTOs retain their existing vocabulary and identity.

The title slice likewise has no dual scheduling path. The per-surface claim key
and lane-specific detach replace the upgrade behavior in one cut while exact
barriers and downstream semantic publication remain intact.

## Cross-Cutting Realization

### Performance and capacity

Title state remains constant-size per live surface and signal class. Separate
claims add at most two live claims per surface. Pane state adds one bounded
structural value per live pane plus observable missing-key slots already owned
by `AtomEntityMap`. Repo Explorer builds one capability context per relevant
capability generation rather than one whole-workspace context per command row.

### Reliability

Fixed absolute deadlines, lane tokens, lifetime guards, centralized pane
commit, derived equality, and live command revalidation own the material
ordering and consistency risks. Telemetry is not in any correctness path.

### Privacy and trust

No new trust boundary or external service is introduced. Atom and terminal
telemetry exports only controlled operation, lane/trigger class, counts,
durations, revisions, and bounded sizes. Pane IDs, titles, paths, queries,
terminal contents, errors, and command payloads remain excluded from OTLP.

### Accessibility and platform behavior

Immediate cursor, scrollbar/activity, and search application retains the
existing AppKit/Ghostty host path. Tab and sidebar views retain their existing
controls and accessibility semantics; only observation and projection ownership
change.

### Observability

Existing trace tags remain the only instrumentation selector. Terminal drain
evidence distinguishes `immediate`, `title_deadline`, and `exact_barrier`
trigger classes plus queue age and retained count. Atom telemetry distinguishes
canonical keyed reads/mutations, structural keyed reads/mutations, membership,
and explicit snapshots using controlled vocabulary. Each `AtomEntityMap`
receives a caller-supplied, product-agnostic controlled map label at
construction; Infrastructure records that label but does not name pane product
types. Canonical pane, structural pane, and unrelated entity maps are therefore
distinguishable without exporting entity identities. Tab and Repo Explorer
performance events record affected-item count, command-resolution count, and
capability-snapshot count without identities or content.

Marker-scoped VictoriaLogs and VictoriaMetrics remain the runtime proof source.
JSONL remains a local forensic aid, not an automatic substitute for shared
collection.

## Proof Architecture

```text
deterministic title harness
  injected deadline scheduler + accumulator + fake MainActor admission
  observes accumulator-produced absolute deadlines crossing initial/follow-up
  scheduling callbacks, lane claims, detached batches, and final debt

runtime title integration
  real accumulator/router/runtime/event path
  observes host title, semantic event kind/count, sequence, replay, IPC wait,
  readiness, and lifetime rejection

keyed observation oracle
  real AtomEntityMap + WorkspacePaneGraphAtom mutation owner
  observes present/missing key callbacks, membership, projection equality,
  accepted-commit revision, graph-owned pruning/re-registration, controlled map
  labels, and final canonical/structural equivalence

presentation integration
  real tab adapter + Repo Explorer projection + App capability owners
  observes affected item count, body/projection work, command resolution,
  independent capability-generation refresh, capability snapshots, and live
  execution rejection

runtime workload
  debug app + controlled title/structural mutations + marker-scoped Victoria
  observes cadence, latency, invalidation scope, snapshot counts, and interaction
```

Real production boundaries are required for the router/runtime event path,
Swift Observation behavior, tab adapter, Repo Explorer projection, command
owners, OTLP projection, Victoria ingestion, and native UI interaction. The
clock and scheduling executor may be replaced only at the deterministic timing
seam. An independent final-state oracle, not one of the two maps, judges pane
equivalence.

Structural enforcement classes:

```text
Invariant                                      Enforcement
──────────────────────────────────────────────────────────────────────
one canonical pane owner                       type/private visibility
keyed present and missing observation          AtomEntityMap + behavior proof
membership changes only on insert/remove       AtomRevision + behavior proof
structural facts equal canonical projection    single commit + oracle proof
durable pane changes retain autosave            commit revision + integration
no hot canonical bulk snapshots                interface split + static lint
per-tab publication                            scoped observer + integration
capability batch refreshes independently        App generation + integration
presentation cannot execute                    interface/type boundary
live command authority                         existing runtime validators
map operation attribution                       caller label + OTLP projection
OTLP content safety                            allowlist projection + tests
```

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

## Requirement Realization

```text
U1 / R-T1,R-T2,R-T5
  accumulator-produced absolute deadline carried through the scheduler seam;
  separate title claim; independent immediate lane; token and lifetime
  cancellation
  proof: deterministic timing/interleaving + marker-scoped workload

U2 / R-T2,R-T3
  immediate-only detach; exact barrier as sole early title detach
  proof: mixed urgency/order integration + native interaction

U3 / R-T3,R-T4,R-T5
  independent semantic and setTitle host values retained in title lane;
  existing downstream runtime publication preserved
  proof: ordinary and exact mixed-kind runtime integration

U4 / R-P1,R-P2,R-P3
  canonical entity family, structural-facts family, per-tab scopes,
  Repo Explorer keyed projection, App-owned capability-context generation,
  batched advisory capability snapshot, unchanged live execution validation
  proof: observation oracle + presentation integration + runtime counters

U5 / R-P4,R-P5
  explicit keyed/membership/snapshot APIs, centralized mutation,
  accepted-commit revision for autosave, graph-owned pruning, equivalence
  oracle, caller-labeled controlled atom telemetry
  proof: mutation-sequence equivalence + marker-scoped runtime evidence
```

## Deliberate Negative Space

- No per-pane actor or generic mailbox.
- No atom per pane field.
- No second canonical pane store or writable projection.
- No durable title queue, schema, migration, or retry service.
- No new runtime event or IPC vocabulary.
- No command-validation fork in Repo Explorer.
- No cached execution authority.
- No global MainActor utilization redesign.
- No unrelated Git cadence, terminal admission, or UI visual changes.

Removing the private structural-facts family would restore same-pane
title-to-capability invalidation. Removing per-tab observation would restore
fleet tab rebuilding. Removing the batched advisory snapshot would restore
commands-times-rows live snapshot construction. The remaining components are
existing owners or the minimum boundaries required to close those three edges.
