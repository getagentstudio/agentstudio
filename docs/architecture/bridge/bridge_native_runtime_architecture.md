# Bridge Native Runtime Architecture

The native Bridge runtime is the authority for worktree identity, production
Git reads, immutable File/Review construction, pane publication, product
sessions, and content authorization. It keeps expensive Git and preparation
work off the main actor while leaving WebKit and pane presentation under
pane-local control.

Start with [Bridge Viewer Architecture](bridge_viewer_architecture.md) for the
outer model. Continue with [Bridge Web Runtime
Architecture](bridge_web_runtime_architecture.md) at the worker boundary. The
route-level contract is [Bridge Product Transport
Architecture](bridge_product_transport_architecture.md).

**Updated 2026-10-09 for Bridge PR1 (#463).** The native owners below follow the
[Bridge Stability Program
Design](../../specs/2026-09-24-bridge-stability-redesign/2026-09-24-bridge-stability-program-design.md#components-and-ownership)
(N1 pane session, N2 operation table, N3 view sender, N4 subscription state,
N5 surface reconcilers, N10 view publishers). One known gap: the native
per-subscription lifecycle is spread over loose containers in
`BridgePaneProductMetadataCoordinator` and is not yet modeled as a state machine
(Linear LUNA-408; see [Bridge after
PR1](../../specs/2026-10-09-bridge-after-pr1/2026-10-09-bridge-after-pr1.md) §5).
Until then, every multi-step transition in that coordinator must change state
and register its effect in one actor turn, before any `await`.

## Ownership Map

```mermaid
flowchart TB
    Host[App pane host / MainActor]
    Controller[BridgePaneController]
    Admission[Pane refresh admission]
    Session[Pane product session owner]
    Metadata[Pane metadata coordinator]
    Content[Pane content demand authority]
    Publication[Review publication coordinator]

    Scheduler[BridgeGitReadScheduler]
    Construction[BridgeWorktreeProductConstructionCoordinator]
    Provider[AgentStudioGitBridgeReviewDataClient]
    Repo[(Worktree)]

    Host --> Controller
    Controller --> Admission
    Controller --> Session
    Controller --> Publication
    Session --> Metadata
    Session --> Content
    Metadata --> Construction
    Publication --> Construction
    Construction --> Provider
    Provider --> Scheduler
    Scheduler --> Repo
```

| Owner | Owns | Does not own |
| --- | --- | --- |
| `BridgePaneController` | WKWebView lifecycle, pane commands, accepted surface and publication wiring | Shared Git artifacts or another pane's state |
| Refresh admission coordinator | Foreground work epoch and hidden/closed admission | Git results or UI selection |
| Product session owner | Capability, stream, subscription, resync, revocation, drain | File/Review semantic construction |
| Metadata/content sources | Pane-scoped metadata production and authorized content reads | Global mutable UI state |
| Review publication coordinator | Prepared, pending, committed, and retiring publication for one pane | Worktree-wide artifact identity |
| Construction coordinator | Worktree epoch, semantic build identity, shared build, leases, invalidation | Pane publication or presentation |
| Git read scheduler | Queued/running/draining Git operation admission and activity priority | Product semantics |
| `agentstudio-git` client | Git object/status/content access and mapping into Bridge contracts | Web rendering or pane selection |

## Shared Construction

```mermaid
sequenceDiagram
    participant P1 as Pane 1
    participant P2 as Pane 2
    participant C as Construction coordinator
    participant G as Git pipeline

    P1->>C: acquire(key, epoch)
    C->>G: start build
    P2->>C: acquire(same key, same epoch)
    C-->>P2: join in-flight build
    G-->>C: immutable artifact
    C-->>P1: lease A
    C-->>P2: lease B
    P1->>C: release lease A
    Note over C: artifact retained by lease B
    P2->>C: release lease B
    C->>C: invalidate backing and remove entry
```

A construction identity combines:

- repository, worktree, stable root, and provider identity;
- File status/ignore/path semantics, or Review query/filter/grouping semantics;
- resolved Review endpoints rather than unresolved branch labels;
- the current worktree freshness epoch.

Equivalent requests share one build only when all of those facts match. An
epoch advance makes old entries stale. In-flight waiters fail or retry against
the new epoch; ready artifacts remain alive only while a consumer lease pins
them.

File construction is progressive: consumers can acquire the shared manifest
and request content while construction continues. Review construction produces
an immutable shared template, then binds pane-specific publication identity
after acquisition. That binding step is why construction can be shared without
sharing pane authority.

## Review Build And Publication

```mermaid
flowchart LR
    Request[Pane Review request]
    Resolve[Resolve endpoints]
    Key[Semantic construction key]
    Template[Shared immutable template]
    Bind[Bind pane package/generation]
    Prepare[Prepare publication]
    Commit[Commit pane publication]
    Stream[Publish metadata stream]

    Request --> Resolve --> Key --> Template --> Bind --> Prepare --> Commit --> Stream
```

The ordering is transactional:

1. Resolve endpoint identity and acquire the matching shared template.
2. Bind the template into a pane-specific package and artifact pin.
3. Prepare publication off-main.
4. Recheck cancellation, foreground admission, and request freshness.
5. Commit the publication and product metadata for that pane.
6. Retire the previous publication only after the replacement is accepted.

Every abandoned or stale path releases its artifact pin. Content handles are
served only through a committed or retiring publication lease, so a body cannot
outlive its publication authority accidentally.

**Review builds only while shown (R15).** Accepting a Review→File viewer-mode
signal fences the building Review attempt in the same MainActor turn as the
acceptance, before any receipt or telemetry `await`: it advances Review
authority, retains the attempt's build reason, and retires the task. An
attempt whose publication has already started (Publishing or AwaitingInstall)
is not fenced; it keeps its own lifecycle. A hidden failure therefore ends as
superseded, never Failed, and the retained input builds when Review is shown
again. Known residual: an explicitly triggered Review load (refresh command or
IPC) does not run in the scheduled-task slot and is not fenced yet; main had
the same behavior before PR1.

## File Metadata And Content

File mode has two related but separate native products:

- a shared progressive File snapshot/manifest describes the tree and content
  read plans;
- the pane metadata source publishes a pane-scoped stream and authorizes content
  reads for committed subscriptions.

Tree metadata can advance incrementally without pushing complete file bodies.
Content requests are checked against the current subscription, authoritative
path or Review item, demand lane, generation, capability, and source
containment before a byte stream is opened.

Since PR1 the File source publishes **keyed state**: `BridgeWorktreeFileManifestIndex`
keeps one record per tracked path (symlink rows included; only the worktree root
is resolved), and row, newest descriptor outcome and wire revision change
together in one non-suspending index update. First paint is progressive
(`coverage` batches) followed by one certifying `snapshot`.

The File surface reconciler (`BridgeFileSurfaceReconciler`) owns build attempts
and outcomes. An interrupted File source restarts in place on the same handle
without user action (C5, R14). When a source context retires, its revision floor
moves to its successor in one actor turn, so a Retry's smaller repaired snapshot
still advances the page's revisions instead of being discarded as older.

## Git Scheduling

```mermaid
flowchart TB
    Calls[File and Review Git calls]
    Queue[Semantic queue]
    Rank{Worktree activity}
    FG[Foreground operations]
    BG[Background operations]
    Run[Bounded running set]
    Drain[Completion / shutdown drain]

    Calls --> Queue --> Rank
    Rank --> FG --> Run
    Rank --> BG --> Run
    Run --> Drain
```

The scheduler is a shared execution boundary, not a second cache. It owns
queueing, cancellation, activity ranking, concurrency, and shutdown drain.
Construction owns reuse. `agentstudio-git` owns the Git operation. Keeping
those jobs separate prevents queue state, semantic identity, and provider code
from collapsing into one actor.

Packaged production reads must use [agentstudio-git](../state/agentstudio_git.md#agentstudio-git).
TypeScript Git helpers are limited to Vite development and fixture construction.

## Product Transport

The native/web product transport has three physical routes:

| Path | Direction | Purpose |
| --- | --- | --- |
| Command | Web to Swift | Typed calls/mutations, subscription changes, demand updates, and query initiation |
| Metadata stream | Swift to worker | Compact pushed state, lifecycle, File/Review metadata, invalidations, and notifications |
| Content | Swift to worker | Finite requested application data referenced by an authorized descriptor |

The session capability is pane-scoped. Request admission validates capability,
route, body budget, sequence, stream/session state, and revocation. Since PR1:

- **N1 pane session (`BridgeProductSession`)** owns each page installation's
  authority (E1), set once at ingress; nothing from an ended installation
  applies to a newer one. Exact replay covers admission only.
- **N2 operation table (`BridgeProductSession+Operations`)** answers a control
  request when it is admitted and settles its result separately, with
  deadlines from `AppPolicies`. An effectful operation whose result is unknown
  settles as `outcomeUnknown`.
- **N3 view sender (`BridgeProductViewSenderState`)** seals keyed batches,
  coalesces dirty keys, paces delivery with per-view credits and cumulative
  acknowledgements, and owns each view's owed snapshot cause
  (`BridgeProductSession+SnapshotCause`).
- The product bootstrap reply to the page is bounded by
  `AppPolicies.Bridge.productBootstrapDeliveryProgressDeadline`
  (`BridgeProductBootstrapDelivery`), so an unresponsive page fails visibly
  instead of hanging.

Application queries compose the existing command and content routes: a typed
call returns a descriptor, then `content.open` returns the actual result. Native
query owners may retain only request-scoped immutable data behind that
descriptor. A selectable catalog or other finite requested dataset does not
belong in pane presentation or a File/Review metadata subscription.

## Activity, Suspension, And Resume

```mermaid
stateDiagram-v2
    Foreground --> Hidden: activity leaves foreground
    Hidden --> Foreground: activity returns
    Foreground --> Closed: close
    Hidden --> Closed: close

    state Foreground {
      [*] --> Admitted
      Admitted --> Refreshing
      Refreshing --> Admitted
    }

    state Hidden {
      [*] --> AdmissionRevoked
      AdmissionRevoked --> ProducersSuspended
    }
```

Leaving foreground advances or revokes the foreground-work admission epoch.
Metadata producers suspend and in-flight foreground work becomes stale. Shared
construction is not automatically destroyed: another foreground pane may still
lease it, and the same pane may reuse current immutable state after resume.

Native pane activity is the only authority that can mint foreground admission.
Browser visibility, focus, and active File/Review mode are presentation facts;
they cannot promote a native pane from `loadedHidden` or `dormant` to
`foreground`. `closed` is terminal.

Resume reacquires admission and restarts work from committed subscription and
publication state. Code must not merely continue an old task after visibility
returns; it must revalidate the current admission and generation.

## Close And Failure Boundaries

The stable close contract is ordered so no producer can publish after authority
is gone. Exact controller composition and call ordering remain subordinate to
the resolved `BridgePaneController` implementation:

1. mark pane activity closed and revoke foreground admission;
2. stop accepting product control and content work;
3. close metadata producers and the product session;
4. close publication and release artifact pins;
5. drain frame pumps, content admission, scheduler consumers, and cleanup;
6. release WebKit handlers and pane resources.

For the product session itself, PR1's rule is **fence, then release**: ending
an installation (E1) synchronously advances the epoch, refuses admissions,
rejects late publications and settles pending operations as cancelled; a new
installation may start immediately; each owner (producer, carrier, credits)
releases its own resources when its task stops, and an uncooperative task is a
diagnostic, never a blocker for the next installation. Pane disposal is bounded
as a whole from entry. Known follow-up (final review D1): some successor and
disposal paths still wait for an ended installation's physical tasks; logical
completion must not wait for physical drain.

Expected failures are converted into bounded product failure/reset state and
telemetry at the owner boundary. A WebView, worker, Git read, or content stream
failure must not crash the application. Replacement sessions request a fresh
native bootstrap; they do not reuse a revoked capability.

## Invariants

- Shared construction is immutable and worktree-scoped; publication is mutable
  only inside one pane.
- A semantic key is resolved before acquisition; raw branch labels do not stand
  in for immutable Git object identity.
- Every acquired lease has exactly one terminal release path.
- Foreground admission is checked again at commit/publication boundaries.
- Metadata publication precedes content demand for that generation.
- Content routes never trust a client path in place of native metadata.
- Closing and invalidation are idempotent and drain their asynchronous cleanup.
- Git provider, construction, scheduler, publication, and transport remain
  separate owners.

## Source Map

| Concern | Source |
| --- | --- |
| Worktree and semantic keys | [`Runtime/Construction/BridgeWorktreeProductConstructionKeys.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/Construction/BridgeWorktreeProductConstructionKeys.swift) |
| Shared build, leases, epochs | [`BridgeWorktreeProductConstructionCoordinator+Diagnostics.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/Construction/BridgeWorktreeProductConstructionCoordinator+Diagnostics.swift), [`BridgeWorktreeProductConstructionCoordinator+FileReads.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/Construction/BridgeWorktreeProductConstructionCoordinator+FileReads.swift), [`BridgeWorktreeProductConstructionCoordinator+Lifecycle.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/Construction/BridgeWorktreeProductConstructionCoordinator+Lifecycle.swift), [`BridgeWorktreeProductConstructionCoordinator.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/Construction/BridgeWorktreeProductConstructionCoordinator.swift) |
| Review template binding | [`Transport/BridgePaneReviewSharedConstructionBinder.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneReviewSharedConstructionBinder.swift) |
| Progressive File binding | [`Transport/BridgePaneProductFileSharedConstructionBinder.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductFileSharedConstructionBinder.swift) |
| Git provider | [`AgentStudioGitBridgeReviewDataClient+Contribution.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/AgentStudioGitBridgeReviewDataClient+Contribution.swift), [`AgentStudioGitBridgeReviewDataClient+Fallbacks.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/AgentStudioGitBridgeReviewDataClient+Fallbacks.swift), [`AgentStudioGitBridgeReviewDataClient+GitIO.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/AgentStudioGitBridgeReviewDataClient+GitIO.swift), [`AgentStudioGitBridgeReviewDataClient+SharedContent.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/AgentStudioGitBridgeReviewDataClient+SharedContent.swift), [`AgentStudioGitBridgeReviewDataClient.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/AgentStudioGitBridgeReviewDataClient.swift) |
| Git queue | [`BridgeGitReadScheduler.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/Git/BridgeGitReadScheduler.swift), [`BridgeGitReadSchedulerModels.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/Git/BridgeGitReadSchedulerModels.swift) |
| Review pipeline/publication | [`Runtime/ReviewFoundation/BridgeReviewPipeline.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewPipeline.swift), [`BridgeReviewPublicationCoordinator.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/ReviewFoundation/BridgeReviewPublicationCoordinator.swift) |
| Pane refresh admission | [`Runtime/BridgePaneRefreshAdmissionCoordinator.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneRefreshAdmissionCoordinator.swift) |
| Pane Review command flow | [`Runtime/BridgePaneController+DiffCommands.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+DiffCommands.swift), [`BridgePaneController+ReviewProductPublication.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+ReviewProductPublication.swift) |
| Product session | [`Transport/BridgePaneProductSessionOwner.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductSessionOwner.swift), [`BridgeProductSession+ProtocolLifecycle.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSession+ProtocolLifecycle.swift), [`BridgeProductSession+Resync.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSession+Resync.swift), [`BridgeProductSession.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSession.swift), [`BridgeProductSessionControlTransition.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSessionControlTransition.swift), [`BridgeProductSessionRevocationBarrier.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSessionRevocationBarrier.swift), [`BridgeProductSessionState.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSessionState.swift) |
| Metadata producers | [`BridgePaneProductMetadataCoordinator+ProducerLifecycle.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductMetadataCoordinator+ProducerLifecycle.swift), [`BridgePaneProductMetadataCoordinator+ProducerOutcomes.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductMetadataCoordinator+ProducerOutcomes.swift), [`BridgePaneProductMetadataCoordinator+ReviewPublication.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductMetadataCoordinator+ReviewPublication.swift), [`BridgePaneProductMetadataCoordinator.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductMetadataCoordinator.swift) |
| Content demand/admission | [`Transport/BridgePaneProductContentDemandAuthority.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductContentDemandAuthority.swift), [`BridgeContentDemandAdmission.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeContentDemandAdmission.swift) |
| Operations (N2) and view sender (N3) | [`BridgeProductSession+Operations.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSession+Operations.swift), [`BridgeProductViewSenderState.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductViewSenderState.swift), [`BridgeProductSession+ViewDelivery.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSession+ViewDelivery.swift), [`BridgeProductSession+SnapshotCause.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSession+SnapshotCause.swift) |
| File keyed index and source | [`BridgeWorktreeFileManifestIndex.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/WorktreeFileSurface/BridgeWorktreeFileManifestIndex.swift), [`BridgePaneProductFileMetadataSource.swift`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgePaneProductFileMetadataSource.swift) |
| File surface reconciler (C5) | [`BridgeFileSurfaceReconciler.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/SurfaceReconciliation/BridgeFileSurfaceReconciler.swift) |
| Review hide fence (R15) | [`BridgePaneController+ActiveViewerMode.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+ActiveViewerMode.swift), [`BridgePaneController+RefreshAdmission.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+RefreshAdmission.swift) |
| Bounded bootstrap reply | [`BridgeProductBootstrapDelivery.swift`](../../../Sources/AgentStudio/Features/Bridge/Runtime/BridgeProductBootstrapDelivery.swift) |
