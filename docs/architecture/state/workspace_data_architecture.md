# Workspace Data Architecture

> **Status:** Authoritative architecture for workspace-level data model, persistence, enrichment pipeline, and sidebar data flow.
> **Target:** Swift 6.2 / macOS 26
> **Companion docs:** [Pane Runtime Architecture](../runtime/pane_runtime_architecture.md) (event envelope contracts, pane-level concerns), [EventBus Design](../runtime/pane_runtime_eventbus_design.md) (actor threading, connection patterns), [Component Architecture](../structure/component_architecture.md) (structural overview), [Atom Persistence Boundaries](atom_persistence_boundaries.md) (write-owner atom and SQLite boundary model)

## TL;DR

Workspace state is split into three persistence tiers: canonical config (user intent), derived cache (enrichment), and UI state (preferences). A sequential enrichment pipeline — `FilesystemActor → GitWorkingDirectoryProjector → ForgeActor` — produces facts on `EventBus<RuntimeEnvelope>`. Subscribers declare the fact topics they consume: `WorkspaceCacheCoordinator` owns topology and enrichment-cache effects, while the surface coordinator, forge projector, and terminal activity router consume their own matched facts. Repo Explorer hosts the Repos and Panes sidebar screens and reads state owners via `@Observable` binding. Projection performs no imperative fetches or mutations; controls dispatch through command specs.

Normal boot explicitly prepares authoritative `core.sqlite` and the one app-root
`local.sqlite` before any hydration, then retains one writable owner for each
accepted database. Workspace composition is loaded from core; local
workspace rows are keyed by `workspace_id`, window/sidebar rows by `window_id`,
and repository/worktree/PR caches have no workspace owner. Workspace JSON and
per-workspace local sidecars are not boot, import, migration, fallback, or
recovery sources. Core preparation failure stops boot. A physically unavailable
local database defaults all local lanes; when local is available, a query or
decode failure defaults only its logical slice. Neither changes or blocks
accepted core startup. Historical
core GRDB migrations remain so valid older core databases can open;
`preferences.global.json` remains independently owned.

Inbox source, schema, preference rows, and history rows are retained but
dormant. Normal boot does not load, observe, route, promote, present, or write
them. Unrelated settings saves must leave every retained row and timestamp
unchanged. There is no active Inbox presentation, command/query, router/store,
settings, or notification-count read lane. Reconnecting any of those edges
requires a new product decision.

---

## Three Persistence Tiers

Data flows DOWN only — tier N never reads tier N+1.

```
TIER A: CANONICAL CONFIG (source of truth, user intent)
  Live source: ~/.agentstudio/core.sqlite
  Owner: RepositoryTopologyAtom plus canonical workspace atoms and WorkspaceStore
  Mutated by: explicit user actions + topology consumer (discovery events)
  Contains: application-global repos/worktrees/watched paths plus workspace panes,
            tabs, drawers, and layouts

TIER B: APPLICATION LOCAL DATABASE (rebuildable enrichment + entity recency)
  Live source: ~/.agentstudio/local.sqlite
  Owner: RepoEnrichmentCacheAtom + ApplicationEntityRecencyAtom +
         WorkspaceEntityRecencyAtom
  Mutated by: WorkspaceCacheCoordinator for enrichment, successful worktree-open
              paths for application recency, attended-pane transitions for pane recency
  Contains: global repo enrichment, worktree enrichment, PR counts,
           global repository/worktree recency, and workspace-keyed pane recency

TIER C: UI STATE (preferences, non-structural + composition state)
  Live source: ~/.agentstudio/local.sqlite
  Owner: WorkspaceSidebarMemoryAtom and active feature-local preferences
  Mutated by: sidebar view actions, MainSplitViewController
              (publishing sidebar collapsed state), composite commands
              (⌘I / ⌘S), and repo sidebar filter actions
  Contains: window-keyed filter state, sidebar collapsed state, sidebar surface,
            expanded groups, width, and frame
```

Only the enrichment/rebuild metadata slice is rebuildable from actors. Entity
recency is non-authoritative local UX memory: repository/worktree facts are
application-global, while pane facts carry an explicit `workspace_id`. If the
database is corrupt, local recovery may quarantine it and all local lanes
default; enrichment rebuilds and recency starts empty while core remains usable.

> **Note on composition state.** `sidebarCollapsed` and `sidebarSurface` live on `WorkspaceSidebarMemoryAtom` as workspace-scoped shell memory. `sidebarHasFocus` lives on `SidebarFocusRuntimeAtom` and is runtime-only. `WorkspaceSidebarState` composes both for UI callers. See [directory_structure.md — composition state vs feature state](../structure/directory_structure.md).

### Tier A: Canonical Models

> **Files:** [`Core/Models/CanonicalRepo.swift`](../../../Sources/AgentStudio/Core/Models/CanonicalRepo.swift), [`Core/Models/CanonicalWorktree.swift`](../../../Sources/AgentStudio/Core/Models/CanonicalWorktree.swift)

```swift
struct CanonicalRepo: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String               // folder name from path
    var repoPath: URL              // filesystem path
    var createdAt: Date
    var stableKey: String { StableKey.fromPath(repoPath) }  // derived, SHA-256
}

struct CanonicalWorktree: Codable, Identifiable, Hashable {
    let id: UUID
    let repoId: UUID               // FK to CanonicalRepo.id
    var name: String
    var path: URL
    var isMainWorktree: Bool
    var stableKey: String { StableKey.fromPath(path) }  // derived, SHA-256
}
```

The runtime `Worktree` model mirrors `CanonicalWorktree` — structure-only, no enrichment:

```swift
struct Worktree: Codable, Identifiable, Hashable {
    let id: UUID
    let repoId: UUID               // explicit FK (not implicit array containment)
    var name: String
    var path: URL
    var isMainWorktree: Bool
}
```

**What is NOT canonical** (lives in cache, populated by event bus):
- `organizationName`, `origin`, `upstream` → `RepoEnrichment`
- `branch`, git snapshot → `WorktreeEnrichment`
- PR counts → `RepoEnrichmentCacheAtom` dictionaries
- Retained Inbox unread-count code is dormant historical source. No active
  sidebar, pane chrome, command, query, or projection reads it.

### Identity Semantics

Two identity types serve different purposes:

- **UUID** is the primary identity for runtime references: pane links, event envelopes, cache keys, and actor scope. Rediscovery at the same canonical path reuses a retained record's UUID; discovery after collection creates a new UUID.
- **stableKey** (SHA-256 of path) is a secondary index for rebuild/re-association. If workspace config is wiped and regenerated, re-adding the same path produces the same stableKey, enabling matching against previous canonical entries.

Different canonical paths are independent locations. Current package discovery does not prove a cross-path move, so a new path receives a new record while the missing old path remains hidden for its retention interval. Equal common Git directories establish current family membership, not checkout identity. A same-path family change preserves that checkout's UUID and updates its membership under validated package evidence.

Discovery reconciles against the global canonical path index and persisted stable keys. One canonical location has one checkout record; distinct linked checkouts remain distinct. Conflicting current family claims defer membership changes instead of creating a duplicate.

Pane references: `Pane.metadata.facets.worktreeId` references `CanonicalWorktree.id` (UUID). Cache rebuilds do not change that identity. Accepted unavailability clears invalid optional facets immediately while preserving the pane, terminal, and Undo lifecycle; current CWD resolution may associate the pane again after a return.

Pane metadata has two identity channels:

- `PaneMetadata.source` is fixed launch provenance. It records where the pane
  started: worktree source or floating source plus launch directory. Do not add
  `startingRepoId` or `startingWorktreeId` parallel fields.
- `PaneMetadata.facets` is live identity. Runtime cwd changes refresh
  `facets.cwd`, `facets.repoId`, and `facets.worktreeId` through
  `WorkspaceSurfaceCoordinator`, which already receives surface/runtime cwd facts and can
  resolve the current repository topology.

If a pane's cwd leaves all known worktrees, live repo/worktree facets clear
while `source` remains unchanged. User-authored `PaneMetadata.note` is neither
launch provenance nor derived identity; it is a persisted pane label used for
collapsed display and `$` search.

### Tier B: Cache Models

```swift
/// Repo identity resolution is explicit. The cache distinguishes
/// "still resolving", "confirmed local-only", and "resolved remote".
enum RepoEnrichment: Codable, Sendable, Equatable {
    case awaitingOrigin(repoId: UUID)
    case resolvedLocal(repoId: UUID, identity: RepoIdentity, updatedAt: Date)
    case resolvedRemote(repoId: UUID, raw: RawRepoOrigin, identity: RepoIdentity, updatedAt: Date)
}

struct RawRepoOrigin: Codable, Sendable, Equatable {
    var origin: String
    var upstream: String?
}

struct RepoIdentity: Codable, Sendable, Equatable {
    var groupKey: String
    var remoteSlug: String?
    var organizationName: String?
    var displayName: String
}

/// Enrichment data for a canonical worktree. Derived from git status/branch.
struct WorktreeEnrichment: Codable, Sendable, Equatable {
    var branch: String
    var isMainWorktree: Bool
    var gitSnapshot: GitWorkingTreeSnapshot?  // changed/staged/untracked counts
}

/// Cache projection shape. Live storage is the application local SQLite database.
struct WorkspaceCacheState: Codable {
    var sourceRevision: UInt64          // monotonic, incremented on any cache write
    var lastRebuiltAt: Date
    var repoEnrichment: [UUID: RepoEnrichment]           // keyed by CanonicalRepo.id
    var worktreeEnrichment: [UUID: WorktreeEnrichment]    // keyed by CanonicalWorktree.id
    // Live PR lane is RepoCacheAtom.pullRequestFacts(for:) keyed by RepoBranchKey,
    // not a worktree-id Int map named pullRequestCounts.
    // Historical notificationCounts remain absent from this cache shape.
    // Retained Inbox atom/source code is dormant and has no active App reader.
}
```

The live `RepoEnrichmentCacheAtom` does not expose those dictionaries as the
hot observation surface. It owns each repo-cache lane through keyed
`AtomFamily` slots:

```swift
AtomFamily<UUID, RepoEnrichment>                 // keyed by CanonicalRepo.id
AtomFamily<UUID, WorktreeEnrichment>             // keyed by CanonicalWorktree.id
AtomFamily<RepoBranchKey, PullRequestFacts>      // keyed by repo+branch, not worktree Int counts
```

Keyed reads: `repoEnrichment(for:)`, `worktreeEnrichment(for:)`, and
`pullRequestFacts(for:)` on `RepoCacheAtom` / `RepoEnrichmentCacheAtom`.
There is no `RepoWorktreeCacheFacts` type and no `pullRequestCount(for:)`.
PR badges come from `PullRequestFacts` keyed by `RepoBranchKey`.
Dictionary-shaped snapshots remain for SQLite/legacy persistence, boot
pruning, and cold batch projection.

### Tier C: Sidebar Local UX Memory

```swift
struct WorkspaceSidebarExpandedGroupState: Codable {
    var expandedGroups: Set<String>        // groupKey strings
}
```

`expandedGroups` is window-keyed local memory owned by `SidebarExpandedGroupAtom`.

### Tier D: Sidebar Settings-Bound Preferences

Sidebar settings intentionally do not own checkout colors. Repo/sidebar
presentation uses automatic colors, while `SidebarCheckoutColorAtom` remains a
legacy cleanup surface only. `WorkspaceSettingsStore` must ignore and clear
legacy checkout-color payloads instead of writing them back to local storage.

### Tier E: Workspace UI State

```swift
struct WorkspaceUIState: Codable {
    var filterVisible: Bool
    var filterText: String

    // Composition state (added LUNA-361) — app-wide UI shell state
    var sidebarCollapsed: Bool             // OWNERSHIP MOVE (LUNA-361):
                                           //   was owned by MainSplitView-
                                           //   Controller + UserDefaults
                                           //   key "sidebarCollapsed";
                                           //   now atom-owned + persisted
                                           //   in application local.sqlite.
                                           //   Greenfield cutover: no
                                           //   dual-write, no migration
                                           //   from the legacy UserDefaults
                                           //   value. UserDefaults key is
                                           //   dead code after LUNA-361.
    var sidebarSurface: SidebarSurface     // live value is always .repos;
                                           // legacy .inbox input normalizes
    // sidebarHasFocus is NOT persisted — runtime-only, resets to false
    // on launch. Published by each sidebar surface view via @FocusState.
}
```

---

## Enrichment Pipeline

Sequential enrichment facts still travel through EventBus, but workspace
filesystem projection has two effect shapes. Boot, explicit rebuild, and an
accepted topology delta request full reconciliation. Ordinary pane mount,
removal, CWD, and active-pane changes use affected-key effects and do not
rebuild the full projection.

```
APPLICATION TOPOLOGY + WORKSPACE STATE
(global repos/worktrees/watched paths + workspace panes/tabs)
      │
      │ restored at boot → canonical baseline seeds discovery before its first scan
      │                    topology events also replayed on bus (.notScanned)
      ▼
FilesystemActor (raw filesystem I/O)
  watched folder scan via RepoScanner:
    - classifies .git directory (clone root) vs .git file (linked worktree)
    - groups linked worktrees under parent clones into ScannedRepoGroup
    - reconciles source inventories with complete/additive coverage and registration receipts
  worktree roots → logical deep watches multiplexed onto one local FSEvents
                   stream per filesystem volume (DarwinFSEventStreamClient)
  emits: SystemEnvelope(.topology(.watchedFolderReconciled(observation)))
         physical worktreeRegistered/worktreeUnregistered facts (effects only)
         WorktreeEnvelope(.filesystem(.filesChanged))
      │
      │ posts to EventBus<RuntimeEnvelope>
      ▼
GitWorkingDirectoryProjector (local git enrichment)
  subscribes to .filesystem(.filesChanged)
  runs: AgentStudioGitWorkingTreeStatusProvider → LibGit2AgentStudioGitLocalClient
  emits: .snapshotChanged, .branchChanged, .originChanged, .originUnavailable
         .worktreeDiscovered, .worktreeRemoved
      │
      │ posts to EventBus
      ▼
ForgeActor (remote forge enrichment)
  subscribes to .branchChanged, .originChanged, .worktreeDiscovered
  runs: GitHubCLIForgeStatusProvider → `gh api graphql`
  emits: .pullRequestsChanged, .checksUpdated, .refreshFailed
      │
      │ all three post to EventBus, fan-out to:
      ▼
WorkspaceCacheCoordinator (App sequencing and collection admission)
  .topology(.watchedFolderReconciled):
    → validate current registration and baseline revision
    → RepositoryLifecycleReconciliation.prepare off MainActor
    → revision-guarded publication, cache/facet invalidation, ordered topology effects
    → durable acknowledgement through RepositoryTopologyStore
  Legacy explicit/boot discovery ingress:
  .topology(.repoDiscovered, linkedWorktrees: .scanned):
    → WorkspaceMutationCoordinator.reconcileDiscoveredWorktrees → WorktreeTopologyDelta
    → cache prune for delta.removedWorktrees
    → topologyEffectHandler.topologyDidChange(delta) → WorkspaceSurfaceCoordinator
  .topology(.repoDiscovered, linkedWorktrees: .notScanned):
    → register/reassociate repo only, skip worktree reconciliation (boot replay)
  .topology(.repoRemoved) → mark unavailable → clear invalid pane associations
                           → preserve pane residency/tab membership → prune cache
  .snapshotChanged/.branchChanged → lifetime-validated keyed cache publication
  Forge repository projections → lifetime-validated family PR cache publication
  Physical watcher registration facts never create or delete canonical topology
      │
      │ topology effects via TopologyEffectHandler (NOT bus):
      ▼
WorkspaceSurfaceCoordinator (ordered post-topology effects)
  topologyDidChange(delta):
    → clear invalid associations for delta.removedWorktrees
    → preserve pane identity, residency, runtime, and tab membership
    → full filesystem reconciliation for accepted topology delta
  ordinary pane/CWD/active changes:
    → typed affected-key effect admission
    → pane or active-worktree projection only
      │
      ▼
RepoEnrichmentCacheAtom + ApplicationEntityRecencyAtom +
WorkspaceEntityRecencyAtom (@Observable, direct owners)
  → keyed atom slots for hot UI reads
  → independent snapshot bridges persisted to application local SQLite
      │
      ▼
SIDEBAR (pure reader of canonical atoms + RepoCacheAtom read surface + WorkspaceSidebarState)
```

### Repository location lifecycle

A repository family and each checkout have separate availability. Canonical
location keys reuse retained application IDs when the same validated path
returns. Distinct paths remain distinct, including independent clones of one
remote. Current common-directory evidence determines family membership; it
does not prove a cross-path move. A same-path family change re-parents the
checkout with an explicit expected-old-owner SQL transition.
Current complete sources also contribute their checkout-family claims. An
incoming path with contradictory current family claims defers re-parenting until
the sources agree; a conflict at an unrelated path does not block discovery.

[Watched-folder admission](../../../Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/WatchedFolderTopologyAdmission.swift)
accepts Git-marker changes and structural directory events that can change
repository membership: a known checkout or its ancestor moving/disappearing,
or a candidate directory appearing outside known checkouts. Ordinary files,
directory metadata changes and directory changes inside a known checkout do not
request a full scan. Coverage loss and overflow retain bounded rescan intent;
losing detailed event flags cannot silently discard a directory move.

Observations also capture the registrations and authoritative scan versions of
overlapping watched roots. Before publication, the filesystem actor validates
these dependencies together with the source's own receipt. A new demand on a
previously complete covering root invalidates the old negative authority;
unrelated roots do not. Regions captured as incomplete remain protected when
their pending scans finish, so completion alone does not discard safe evidence
for the rest of the source's scope.

```text
available location
  ├─ complete current absence ──> hidden record + first-absence clock
  │                                ├─ same-path return ──> available, same ID
  │                                └─ 30 elapsed days + fresh complete absence
  │                                     └─ bounded core commit ──> collected
  └─ incomplete/stale/inaccessible scan ──> preserve negative space

unproven different path ──> independent validated location
pane on unavailable checkout ──> same pane, optional topology facets cleared
```

`unavailable_repo` and `unavailable_worktree` retain typed absence records in
core.sqlite. Repeated scans and saves preserve the first timestamp. Legacy
unknown age stays untimed until authoritative absence; incomplete overlapping
coverage cannot start its clock. Empty families left by positive reparenting
remain unavailable with unknown age until that validation. Available linked
checkouts can outlive the main location; launch targets must select an available
checkout. Repos/search omit unavailable locations; pane membership is independent.

[RepositoryRetentionScheduler](../../../Sources/AgentStudio/Core/RuntimeEventSystem/Retention/RepositoryRetentionScheduler.swift)
owns one injected-clock deadline and joins admitted validation on shutdown.
[WorkspaceCacheCoordinator](../../../Sources/AgentStudio/App/Coordination/WorkspaceCacheCoordinator+Retention.swift)
awaits current applied scan receipts, excludes unsettled owned operations, and
selects the watched scopes covering due or unknown-age hidden locations, and
reserves at most 64 combined family/checkout records while SQL commits. Selective
scan demand preserves the complete authorized watch registration set. After
preparation and reservation, one filesystem-actor operation revalidates every
candidate observation and its covering dependencies before SQL admission. A
superseded receipt releases the reservation without deletion. The committed
result publishes before queued topology mutations resume. Removing a watch is
not absence evidence and cannot authorize collection.
Boot's delayed exact-root reassociation uses the same admission wait, so it
cannot change the topology revision while a collection is awaiting persistence.

[Core collection](../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreRepository+Retention.swift)
revalidates exact absence and elapsed age transactionally. It removes eligible
topology and owned metadata, and clears invalid optional pane facets across
workspaces. Panes, sessions, undo and annotation history keep their own lifecycle.
[Local cleanup](../../../Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceLocalRepository+RepositoryRetention.swift)
then prunes orphan enrichment, repository/worktree recency and settled activity
in bounded transactions, preserving shared keys and volume cursors. Startup
repeats this reconstructible sweep after a crash between databases. Local
read/write fences reject retired keys and mismatched checkout-family ownership
before deferred cleanup finishes; stale topology captures are revision-rejected.

Git/Forge requests capture launch-scoped observation lifetimes. Hide, return,
reparenting and replacement invalidate the relevant lifetime; queued/coalesced
facts revalidate it at publication and never borrow values from another lifetime.
The pipeline orders physical scope mutations across awaits. A stale unregister
cannot remove a newer registered lifetime. Reparenting invalidates the moved
checkout's enrichment and both families' PR projections while preserving
unchanged checkouts' Git metadata.

Marker-scoped `performance.repository_lifecycle.preparation` and `.publication`
separate worker preparation from synchronous MainActor publication. Retention
uses `performance.repository_retention.preparation` and `.commit`, with combined
location counts and separate `mainactor_held_ms`. These measurements export
bounded numeric values; filesystem I/O, SQL and deadlines remain off MainActor.

### Actor Responsibilities

#### FilesystemActor

| Aspect | Detail |
|--------|--------|
| **Owns** | FSEvents ingestion via DarwinFSEventStreamClient, path filtering, debounce, batching |
| **Scope** | Logical worktree and watched-folder roots, multiplexed onto one physical local FSEvents stream per filesystem volume; external exact-item parents remain separately shared by parent identity |
| **Reads** | Registered worktree paths from WorkspaceSurfaceCoordinator sync |
| **Produces** | `SystemEnvelope(.topology(.watchedFolderReconciled))` — scoped validated positives and complete/additive coverage |
| | `WorktreeEnvelope(.filesystem(.filesChanged))` — file change facts |
| **Does not** | Run git commands, access network, mutate canonical store |

`DarwinFSEventStreamClient` separates logical registration identity from
physical observation. Each logical root retains its worktree ID, lifecycle
generation, observation scopes, continuity participant, and callback routing,
while `DarwinSharedLocalFSEventObserverRegistry` contracts same-volume watched
paths into one physical stream. Every distinct live logical root remains in the
physical stream's watched-path set because macOS `WatchRoot` replacement events
are defined only for paths supplied when the stream is created. A required
physical replacement starts the successor, buffers successor callbacks,
flushes the still-current predecessor, atomically installs the successor,
and replays the buffer into a client-owned activation gate before retiring the
physical predecessor. The client publishes the matching logical generation and
continuity identity before activating that gate, which drains the replay in
order; only then does it retire the logical predecessor registration. Thus
steady native-client cardinality is bounded by mounted-volume count rather than
repository/worktree count, with at most one physical replacement overlap at a
time.

Ordinary callbacks route only to intersecting logical registrations. Coverage
loss from stream-global flags is broadcast to every logical participant on that
physical stream so continuity fails closed. `UserDropped`, `KernelDropped`, and
`EventIdsWrapped` are stream-global; bare `MustScanSubDirs`, `Mount`, `Unmount`,
and `RootChanged` remain path-scoped. Only registrations rooted at or below a
`RootChanged` watched path retire, including when a stream-global loss flag is
present in the same event. Callback-driven logical retirement is deferred off
the synchronous callback stack so a predecessor `FSEventStreamFlushSync` cannot
wait on its own configuration lock.

The native API accepts only eight exclusion directories, so the shared physical
stream does not install per-repository private-staging exclusions in the kernel.
Instead, the shared ingress contracts `refs/agentstudio/staged` events once in
user space before logical callback fan-out. Activity barriers flush each
physical local stream once, not once per logical worktree. Shutdown retires the
final physical stream after its last logical lease disappears. Native callback
context lifetime is owned through `FSEventStreamContext.retain`/`release`;
application teardown does not manually free callback closures.

An activity barrier is admitted only when the client registration generations
exactly match the shared registry's logical generations, no physical replacement
is pending, and every client activation gate is delivering live events. The same
conditions are rechecked after the ingress fence; a handoff overlap fails closed
instead of certifying a predecessor generation against a successor stream.

#### GitWorkingDirectoryProjector

| Aspect | Detail |
|--------|--------|
| **Owns** | Local git state materialization |
| **Scope** | Per-worktree, keyed by worktreeId |
| **Subscribes to** | `.filesystem(.filesChanged)` from EventBus |
| **Runs** | `AgentStudioGitWorkingTreeStatusProvider` → `LibGit2AgentStudioGitLocalClient` (libgit2). Not `git` CLI. Package link: [agentstudio-git](agentstudio_git.md#agentstudio-git) |
| **Produces** | `GitWorkingDirectoryEvent` envelopes on EventBus |
| **Carries forward** | `correlationId` from source `.filesChanged` event |
| **Admission** | Demand-gated to visible, active-pane, active-in-app, or explicit requests; bounded slots reserve capacity for the active pane and oldest stale demanded work |
| **Pending work** | Unions affected paths across ordinary pending, immediate, capacity-retry, and circuit-breaker debt while retaining the freshest ordering context |
| **Cadence and recovery** | Equal results lengthen the `AppPolicies` cadence; changed results restore prompt cadence; capacity contention uses a short retry, status timeouts use per-worktree exponential backoff, and dead roots are quarantined |
| **Status scope** | Uses pathspec-scoped status for bounded changed-path sets and conservatively widens to a full status for git-internal, rename-unsafe, or over-cap changes |
| **Does not** | Access network, scan filesystem for repos, mutate canonical store |

Watched-folder refresh preserves that admission boundary. `FilesystemGitPipeline`
maps the supplied watched paths to intersecting registered worktree roots and
requests immediate status only for that affected set. The explicit user
refresh-all entry point remains fleet-wide. Runtime demand and retry state are
not persisted. The accumulator retains a bounded pending invalidation with the
union of affected paths while waiting for demand; an eligible event re-arms
that work, and an explicit request may admit it immediately.

#### ForgeActor

| Aspect | Detail |
|--------|--------|
| **Owns** | Remote forge API interaction (PR status, checks, reviews) |
| **Scope** | Per-repo, keyed by repoId + remoteURL |
| **Subscribes to** | `.gitWorkingDirectory(.branchChanged)`, `.originChanged`, `.worktreeDiscovered` from EventBus |
| **Runs** | `GitHubCLIForgeStatusProvider` → `gh api graphql` (not `gh pr list`) via `@concurrent nonisolated` helpers |
| **Self-driven** | One reschedulable next-eligibility deadline for demanded repositories; no fleet-wide periodic poll |
| **Command-plane** | `refresh(repo:)` after git push |
| **Admission** | Current demand, freshness, provider backoff, and generation gate one provider call per repo; overlapping eligible triggers retain one latest-scope follow-up |
| **Recovery** | Per-repo failure backoff is policy-derived and cancelled on unregister/shutdown |
| **Publication** | Successful `ForgeEvent.pullRequestsChanged` publishes only when `factsByBranch` differs from the last accepted map |
| **Produces** | `ForgeEvent` envelopes on EventBus |
| **Does not** | Scan filesystem, run git commands, discover repos, mutate canonical store |

#### WorkspaceCacheCoordinator

Single topology accumulator. For scanned discovery, `WorkspaceMutationCoordinator.reconcileDiscoveredWorktrees` (in `RepositoryWorktreeReconciliation.swift`) computes a `WorktreeTopologyDelta`, then the coordinator delegates ordered effects to an injected `TopologyEffectHandler`. There is no `WorktreeReconciler` type.

```
handleTopology(_ envelope: SystemEnvelope)
  — CANONICAL mutations (RepositoryTopologyAtom via WorkspaceStore.mutationCoordinator)
  Events: .topology(.repoDiscovered / .reposDiscovered / .repoRemoved),
          .worktreeRegistered, .worktreeUnregistered
  For .repoDiscovered with .scanned(linkedPaths):
    → mutationCoordinator.reconcileDiscoveredWorktrees(...) → WorktreeTopologyDelta
    → cache prune for delta.removedWorktrees (coordinator owns repoCache)
    → topologyEffectHandler.topologyDidChange(delta) → WorkspaceSurfaceCoordinator
  For .repoDiscovered with .notScanned:
    → register/reassociate repo only, skip scanned reconciliation (boot replay)

Enrichment handlers — DERIVED cache writes (RepoEnrichmentCacheAtom through RepoCacheAtom)
  Events: .snapshotChanged, .branchChanged, .originChanged, .originUnavailable,
          .pullRequestsChanged, .checksUpdated
  Touches: repo enrichment cache only; entity recency has separate direct owners

Scope sync — ACTOR registration management
  Operations: register/unregister worktrees with FilesystemActor, ForgeActor
  Called from topology handlers as needed
```

Does not run git/network commands or access filesystem directly.

### Filesystem Effect Admission And Projection

Filesystem source authority and workspace projection are separate
responsibilities. There are two independent lanes:

```text
FilesystemActor / GitWorkingDirectoryProjector
  -> globally published WorktreeScopedEvent
  -> PaneFilesystemProjectionAdmission (consumer-side)
     -> filesChanged / snapshotChanged -> project affected panes
     -> every other owned case         -> explicitly ignored here
  -> FilesystemProjectionIndex
  -> WorkspaceSurfaceCoordinator sequences any published pane facts

pane mount / removal / CWD / active-pane change
  -> local affected-key coordinator effect
  -> FilesystemProjectionIndex
  -> applied / stale / inapplicable
  -> changed activity/active-worktree update to FilesystemActor
  -> no EventBus fact solely for index maintenance
```

`PaneFilesystemProjectionAdmission` exhaustively switches over the owned
`WorktreeScopedEvent`, `FilesystemEvent`, and `GitWorkingDirectoryEvent`
families. Every case explicitly selects projection or `.ignored`; no catch-all
default silently schedules work. This is pane-projection admission after the
bounded worktree fact reaches EventBus, not Terminal-style pre-publication
source admission. The original filesystem/Git facts remain globally available
to other consumers; only relevant cases derive pane-scoped
`PaneFilesystemContextEvent` facts.

Effect rules:

- Full reconciliation is reserved for boot, explicit rebuild, and an accepted
  topology delta.
- Pane mount, pane removal, and pane CWD changes update only the keyed pane.
- Active-pane changes project only the active-worktree effect.
- Unrelated actions schedule no filesystem projection work.
- `FilesystemProjectionIndex.applyPaneUpdate` reports `.applied`, `.stale`, or
  `.inapplicable`, so the coordinator can distinguish a committed projection
  from obsolete or irrelevant work.
- Full source-sync requests carry an explicit
  `appliedContextsByWorktreeId` baseline with no implicit empty default.
  Coordinator mirrors advance immediately after each awaited source write, so
  a superseding pass compares desired state with registration, activity, and
  active-worktree effects that actually completed rather than an optimistic
  committed index snapshot.

`FilesystemActor` remains the authority for observed filesystem facts and root
registration. `FilesystemProjectionIndex` remains a rebuildable, off-main
projection of those facts and of current pane/worktree membership; it does not
become canonical workspace state. Terminal contraction and filesystem
projection deliberately use separate domain types rather than a generic
admission framework.

### Discovery — Repo Scanning

`RepoScanner` walks the filesystem from a root URL and classifies each `.git` entry:
- `.git` **directory** → clone root (real `git init`/`git clone`)
- `.git` **file** → linked worktree (reads `gitdir:` line to derive parent clone path by stripping `/.git/worktrees/<name>`)
- `.git` exists but unreadable → treated as clone root (conservative boundary — scanner stops descending)

After classification, linked worktrees are grouped under their parent clone into `RepoScanGroup` entries via `groupClassifiedPaths()`. Repository validation and discovery semantics come exclusively from the pinned `agentstudio-git` package and its libgit2-backed discovery client; this app does not invoke Git CLI commands or `wt` directly. Submodule and worktree classification remain the package-owned discovery contract.

Used by `FilesystemActor` as the blocking filesystem walk behind watched-folder refresh. The grouped results enable the coordinator to create correct worktree families from the first topology event.

> **Files:** [`Infrastructure/RepoScanner.swift`](../../../Sources/AgentStudio/Infrastructure/RepoScanner.swift), [`Core/State/MainActor/Coordination/RepositoryWorktreeReconciliation.swift`](../../../Sources/AgentStudio/Core/State/MainActor/Coordination/RepositoryWorktreeReconciliation.swift)

### Event Namespaces

```
TopologyEvent (envelope: SystemEnvelope, all via bus)
  .repoDiscovered(repoPath:, parentPath:, linkedWorktrees: LinkedWorktreeInfo = .notScanned)
      — producer: AppDelegate (boot replay with .notScanned), FilesystemActor (watched folder diff with .scanned)
      — LinkedWorktreeInfo distinguishes "scanner found these linked worktrees" from "no scan performed"
      — .scanned([]) = authoritative empty (remove stale linked worktrees)
      — .scanned([url1, url2]) = authoritative list (reconcile to match)
      — .notScanned = boot replay / manual add (leave existing worktrees unchanged)
  .reposDiscovered(parentPath:, repositories:) — producer: FilesystemActor (batch scan)
  .repoRemoved(repoPath:)                   — producer: FilesystemActor (watched folder diff, global dedup)
  .worktreeRegistered(worktreeId:, repoId:, rootPath:) — producer: FilesystemActor
  .worktreeUnregistered(worktreeId:, repoId:)          — producer: FilesystemActor

FilesystemEvent (producer: FilesystemActor, envelope: WorktreeEnvelope)
  .filesChanged(changeset:)
  .worktreeRegistered(worktreeId:, repoId:, rootPath:)
  .worktreeUnregistered(worktreeId:, repoId:)
  .gitSnapshotChanged(snapshot:)
  .diffAvailable(diffId:, worktreeId:, repoId:)
  .branchChanged(worktreeId:, repoId:, from:, to:)

GitWorkingDirectoryEvent (producer: GitWorkingDirectoryProjector, envelope: WorktreeEnvelope)
  .statusOutcome(GitStatusOutcomeFact)
  .snapshotChanged(snapshot:)
  .branchChanged(worktreeId:, repoId:, from:, to:)
  .originChanged(repoId:, from:, to:)
  .originUnavailable(repoId:)
  .worktreeDiscovered(repoId:, worktreePath:, branch:, isMain:)
  .worktreeRemoved(repoId:, worktreePath:)
  .diffAvailable(diffId:, worktreeId:, repoId:)

ForgeEvent (producer: ForgeActor, envelope: WorktreeEnvelope)
  .pullRequestsChanged(repoId:, factsByBranch:)
  .pullRequestBranchesInvalidated(repoId:, branches:)
  .pullRequestRepositoryInvalidated(repoId:)
  .pullRequestsUnavailable(repoId:)
  .checksUpdated(repoId:, status:)
  .refreshFailed(repoId:, error:)
  .rateLimited(repoId:, retryAfterSeconds:)
```

Discovery events (`.repoDiscovered`, `.repoRemoved`) live in `SystemEnvelope` because the canonical repo does not exist yet at emit time — no repoId is available. All other workspace events live in `WorktreeEnvelope` where repoId is always present. For the full 3-tier envelope hierarchy, see [Pane Runtime Architecture — Contract 3](../runtime/pane_runtime_architecture.md#contract-3-event-envelope).

---

## Sidebar Data Flow

The sidebar is a pure reader. It combines canonical structure, keyed display
facts, and persisted presentation choices through the existing projection.

```
RepositoryTopologyAtom                       → global repo/worktree structure
RepoCacheAtom keyed enrichment and PR facts  → prepared display facts
WorkspaceSidebarState                        → filter, surface, grouping, subgroup,
                                               Show Pinned, collapse, runtime focus
RepoExplorerSidebarPrefsAtom                 → per-surface sort field and direction

ZERO imperative fetches. ZERO mutations. Pure @Observable binding.
```

Repo Explorer captures only declared membership and keyed facts. The immutable
capture enters the existing `EagerDerivedAtomFamily`;
`RepoExplorerProjectionWorker` builds the projection and row index off
MainActor. Cancellation, supersession, removal, and generation checks prevent
stale binding. MainActor owns keyed capture, current-result binding, and command
presentation publication only.

Repos offers Repo and Activity grouping only and has no effective subgroup.
Repo renders remote-identity groups under Pinned Repos, Open Repos, and
Available Repos. Activity keeps Pinned Repos first and replaces Open/Available
with fixed, noncollapsible activity sections. One remote-identity group uses the
newest eligible output timestamp across every represented repository and
worktree. Repository headers remain expandable to checkout rows.

Panes renders independent Pinned Panes and Other Panes, grouped by Repo, Tab,
or Activity. Repo and Tab may subgroup by None or Activity; subgroup headings
appear only when the parent contains more than one nonempty bucket. Activity as
the main group has no redundant subgroup. Hiding a pinned section merges its
members into ordinary membership without clearing flags or duplicating rows.

Panes membership comes from canonical active-residency `allPaneIds`, including
panes retained across arrangements. Repository association adds context but does
not decide membership. Unassociated panes retain a No Repository group.
Repository headers keep display-name order, tab headers keep shell order, and
activity buckets keep fixed time order. Name/Activity and direction sort only
leaves within their section, group, and optional subgroup.

Existing window-local persistence owns surface, grouping, subgroup, Show Pinned,
and collapse. Workspace-local persistence owns per-surface sort. Repos reuses
`repoGroupingMode`; its legacy subgroup field remains persisted but has no
presentation effect. Local migration 007 already owns per-screen organization.
Core migration 017 already renamed repository `is_favorite` to `is_pinned` and
added independent pane `is_pinned`. This correction adds no schema. Both
surfaces default to Name ascending and Show Pinned on. Activity main grouping
suppresses Panes subgrouping without overwriting the saved choice.

The worker classifies `PaneActivityStatusFact.observedAt` into Active, Just Now,
Last Hour, Today, Last 7 Days, Older, or No Activity and prepares presentation
deadlines. This runtime-only settled-output fact retains existing coverage and
equal-line limitations. Missing evidence never falls back to focus time.

The header has two rows: Repos/Panes plus Filter, then Show Pinned, animated
sort-direction arrow, Name/Activity picker, and one grouping summary. The
summary opens one native `.popover` with shared 12-point padding and equal Group and
Subgroup columns. Catalog icons label both headers. An unavailable subgroup
retains its column with lighter `No Subgroups`; valid None remains selectable.
Presentation filtering and dispatch guards reject invalid commands.

Section headings use entity icons and blue word-initial lowercase-small-caps
labels. Expandable repository/tab headers use chevron and title without an
entity icon. Activity subgroup headings use the same casing in secondary color
with a trailing divider. Shared `AppStyles` increases noninitial section and
subgroup top spacing without changing leaf alignment.

This is not a broad live join: each store has one job and capture declares the
keys being combined. MainActor binds prepared results; grouping, activity
aggregation, sorting, deadline selection, and row derivation stay detached.
Existing focus/recency chips remain. Unseen dots, running animations, zmx IPC,
and vendor changes are outside this sidebar slice.

Branch display: `WorktreeEnrichment.branch` from cache, falling back to `"detached HEAD"`. No branch field on the `Worktree` model itself.

---

## Lifecycle Flows

### App Boot (implemented)

Boot is driven by `WorkspaceBootSequence` ([`App/Boot/WorkspaceBootSequence.swift`](../../../Sources/AgentStudio/App/Boot/WorkspaceBootSequence.swift)). Presentation prerequisites run first (sync or async). Post-presentation steps run **async** and must not be treated as one blocking list.

```
Presentation (shell may not appear until these finish):
  1. prepareDatabases
  2. loadCanonicalStore
  3. loadSidebarMemory          ← UIStateStore restore before sidebar hosts exist
  4. establishRuntimeBus

Post-presentation (async, after the composition-backed shell is visible):
  5. loadCacheStore
  6. loadWorkspaceSettings      ← settings only
  7. startFilesystemActor
  8. startGitProjector
  9. startForgeActor
 10. startCacheCoordinator
 11. armPersistenceObservation   ← after both restores, before topology replay
 12. triggerInitialTopologySync
 13. readyForReactiveSidebar
```

Database preparation is cached for the launch. Local recovery is exactly
`quarantine present DB/WAL/SHM → create and migrate fresh local.sqlite`.
Classified corruption and orphan sidecars may enter that path. Unclassified
open failures preserve the file set. Quarantine or fresh-creation failure leaves
local unavailable for the launch; consumers do not retry the open.

After the boot sequence completes, `AppDelegate` calls `observeLaunchRestoreReadiness()` which creates a `WindowRestoreBridge`. The bridge observes `WindowLifecycleAtom.isReadyForLaunchRestore` and yields trusted terminal container bounds once the window layout has settled. `AppDelegate` then calls `workspaceSurfaceCoordinator.restoreAllViews(in: bounds)` to create views for all persisted panes. See [Deferred Launch Restore](#deferred-launch-restore) for the geometry gate that handles panes whose bounds are not yet available.

Boot replay uses the same `.repoDiscovered` event and same coordinator code path as live discovery. The cached data provides instant display; the replay validates and refreshes everything.

### User Adds a Folder (implemented)

```
1. User: File → Add Folder → selects /projects
2. AppDelegate persists watched scope:
   → store.addWatchedPath(/projects)
3. AppDelegate calls watched-folder command:
   → refreshWatchedFolders(paths: store.watchedPaths.map(\.path))
4. FilesystemActor performs the authoritative scan:
   a. Reconcile watched-folder registrations
   b. Scan watched roots via RepoScanner
   c. Diff current repo set against prior baseline
   d. Emit .repoDiscovered / .repoRemoved on RuntimeEventBus
   e. Return WatchedFolderRefreshSummary to caller
5. AppDelegate uses returned summary for immediate UX:
   a. If zero repos under /projects → show empty-folder alert
   b. Does NOT emit topology facts directly
6. WorkspaceCacheCoordinator.handleTopology(.repoDiscovered):
   a. Idempotent check by stableKey — skip if repo already exists
   b. Seed enrichment to .awaitingOrigin in RepoEnrichmentCacheAtom
7. WorkspaceSurfaceCoordinator reacts from topology facts and syncs registered worktree roots
8. Actors start producing enrichment events → cache updates → sidebar renders
```

### User Adds a Repo (implemented)

```
1. User: File → Add Repo → selects /projects/my-repo
2. AppDelegate validates it has a .git directory
3. If path is a child of a repo (not the repo root), offers to add the parent folder instead
4. addRepoIfNeeded(path) → same flow as step 4 above
```

### Branch Change → Forge Refresh (implemented)

```
1. User changes the checked-out branch to `feat-2` in worktree wt-1 using their Git client
2. FSEvents fires → FilesystemActor detects .git/HEAD change
   → emits .filesChanged (contains .git internal changes)
3. GitWorkingDirectoryProjector:
   → AgentStudioGit status read → detects branch changed
   → emits .branchChanged(wt-1, repo-A, from: "feat-1", to: "feat-2")
   → emits .snapshotChanged(new snapshot)
4. ForgeActor subscribes to .branchChanged (via bus fan-out):
   → updates repo-A membership and requests refresh through demand admission
   → starts immediately only when demanded and stale/missing
   → `gh api graphql` for the repo
   → emits .pullRequestsChanged
5. CacheCoordinator writes enrichment to RepoCacheAtom (branch + pullRequestFacts)
6. Sidebar: branch chip updates, PR badge updates
```

Note: ForgeActor gets `.branchChanged` directly from the bus fan-out. The coordinator does NOT additionally trigger ForgeActor — this prevents duplicate network refreshes.

### Repo Moved

A current authoritative watched-folder observation hides the missing old
location and admits a validated different path independently. Pane context
clears while pane identity, terminal ownership and membership remain intact.
Same-path return before collection reuses the retained identity. No Locate or
Repair action participates; current package discovery does not prove a unique
cross-path move. See [Repository location lifecycle](#repository-location-lifecycle)
for retention, separate checkout membership and collection.

### Deferred Launch Restore

> **Files:** [`App/Boot/AppDelegate+LaunchRestore.swift`](../../../Sources/AgentStudio/App/Boot/AppDelegate+LaunchRestore.swift), [`App/Lifecycle/WindowRestoreBridge.swift`](../../../Sources/AgentStudio/App/Lifecycle/WindowRestoreBridge.swift), [`App/Boot/AppDelegateLaunchRestoreObservationState.swift`](../../../Sources/AgentStudio/App/Boot/AppDelegateLaunchRestoreObservationState.swift), [`App/Coordination/WorkspaceSurfaceCoordinator+ViewLifecycle.swift`](../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ViewLifecycle.swift), [`Features/Terminal/Hosting/TerminalStatusPlaceholderView.swift`](../../../Sources/AgentStudio/Features/Terminal/Hosting/TerminalStatusPlaceholderView.swift), [`Features/Terminal/Restore/TerminalRestoreScheduler.swift`](../../../Sources/AgentStudio/Features/Terminal/Restore/TerminalRestoreScheduler.swift)

zmx terminal panes require a trusted `initialFrame` before Ghostty surface creation. During app boot, `terminalContainerBounds` may be zero because the window has not settled layout yet. The deferred launch restore flow handles this geometry gate.

**Geometry gate.** When `WorkspaceSurfaceCoordinator.createView(for:...)` is called for a zmx pane and `initialFrame` is nil, it does not create a Ghostty surface. Instead it registers a `.preparing` placeholder via `registerTerminalPlaceholderIfNeeded(for:mode:)` and returns nil. The same gate applies to floating zmx panes (drawers, standalone terminals) in `createFloatingTerminalView`.

**Placeholder modes.** `TerminalStatusPlaceholderView` has two modes:
- `.preparing` — transient waiting-for-geometry state. `shouldRetryCreationWhenBoundsChange` returns true.
- `.failedToStart` — resting startup-failure state (surface creation failed). `shouldRetryCreationWhenBoundsChange` returns false. The user can retry or close.

**Retry trigger.** When AppKit delivers a layout pass, `PaneTabViewController.handleTerminalContainerBoundsChanged()` calls `WorkspaceSurfaceCoordinator.restoreViewsForActiveTabIfNeeded()`. This method checks the active tab for any `.preparing` placeholders, resolves geometry from the now-settled bounds, and calls `createViewForContent(pane:initialFrame:treatAsRestoredSessionStart:)` with real frames. The placeholder is replaced by the live terminal surface.

**Restore ordering.** `TerminalRestoreScheduler.order(_:resolver:)` sorts panes by `VisibilityTier` — `p0Visible` first, then `p1Hidden`. Within the visible tier, the active pane sorts first. This ensures the active tab paints before background tabs are hydrated. Background tabs are restored cooperatively with `Task.yield()` after every two panes.

**Background hidden-pane restore behavior.** Every active zmx pane remains in the startup cohort. Foreground main panes restore first, followed by foreground drawer children, hidden main panes, and hidden drawer children. Hidden panes do not require selection or a pre-existing live-session inventory entry; the terminal activation owner resolves whether to reconnect or start each pane when its phase runs.

**The flow:**

```
AppDelegate: WorkspaceBootSequence.run() → stores loaded, actors started, topology replayed
  ↓
AppDelegate: observeLaunchRestoreReadiness()
  → creates WindowRestoreBridge (observes WindowLifecycleAtom)
  ↓
WindowLifecycleAtom: recordTerminalContainerBounds() + recordLaunchLayoutSettled()
  → isReadyForLaunchRestore becomes true
  ↓
WindowRestoreBridge: yields trusted bounds via AsyncStream
  ↓
AppDelegate: finishLaunchRestore(using: bounds)
  → workspaceSurfaceCoordinator.restoreAllViews(in: bounds)
  ↓
restoreAllViews:
  → TerminalRestoreScheduler orders panes (p0Visible first)
  → For each pane: resolveInitialFramesByTabId(in: bounds)
    → createViewForContent(pane, initialFrame, treatAsRestoredSessionStart: true)
      ↓ zmx pane with initialFrame available → surface created
      ↓ zmx pane with initialFrame == nil → .preparing placeholder registered
  ↓
Window layout settles (AppKit viewDidLayout)
  → PaneTabViewController.handleTerminalContainerBoundsChanged()
  ↓
restoreViewsForActiveTabIfNeeded()
  → checks: .preparing placeholders in active tab? bounds non-empty?
  → For each .preparing pane: createViewForContent(pane, initialFrame: REAL_FRAME)
    → surface created, placeholder replaced
```

**Timeout recovery.** `AppDelegateLaunchRestoreObservationState` installs a 10-second diagnostic timer. If `WindowRestoreBridge` has not yielded by then, the timer attempts restore with whatever bounds are currently recorded in `WindowLifecycleAtom` as a fallback.

---

## Ordering, Replay, and Idempotency

### Ordering Contract

Per-source `seq` counter (monotonic `UInt64`). Each source maintains its own counter starting at 1.

- Counter resets to 1 when the source actor is restarted (app relaunch)
- Reset is detectable: new `seq=1` + newer `timestamp` than last seen event from that source
- Cross-source ordering NOT guaranteed — use `timestamp` for cross-source comparison
- Within a single source, `seq` ordering is authoritative

Gap handling: if consumer sees `seq=5` after `seq=3` from same source, buffer overflowed. Cache consumer treats gaps as "full refresh needed" — re-queries source for current state. This is pragmatic: the enrichment pipeline is idempotent and stateless per-event.

### Replay

Two distinct, complementary replay layers:

- **Bus-level replay:** Per-source buffer (256 events) on EventBus for late-joining bus subscribers catching up on recent workspace events. Not persistent — on restart, actors re-emit current state via initial scan.
- **Pane-level replay (C14):** Per-pane replay buffer on PaneRuntime for UI consumers catching up on a specific pane's event stream. Distinct concern — serves UI, not coordination.

### Idempotency

Every cache write is a "set to latest value" operation, not a delta. Writing the same `WorktreeEnrichment.branch = "feat-1"` twice is a no-op. The entire enrichment pipeline is naturally idempotent by design.

Cache coordinator and cache atoms use value-equality checks: if the incoming
fact matches the existing cached content, the write is skipped and no atom
invalidation is fired. `RepoEnrichment` cache equality ignores timestamp-only
refreshes. `sourceRevision` on `WorkspaceCacheState` increments on actual cache
changes. On boot, if cache is missing/corrupt/stale, coordinator sets
`needsFullRebuild` and treats all events from initial scan as new.

---

## Event System Design: What It Is (and Isn't)

The event bus is a **notification mechanism** — runtime actors produce facts, the coordinator consumes them and calls store methods. This is NOT CQRS. There is no command bus, no command/event segregation, no command handlers.

### How It Works

**Events are facts about the world.** "A repo exists at this path." "Branch changed to X." "PR count is 3." Events carry data, not instructions.

**Canonical state is mutated by the owning atoms or `WorkspaceMutationCoordinator`.** The bus does not route mutations, and `WorkspaceStore` is not a convenience mutation facade.

**The coordinator bridges events to store methods.** `WorkspaceCacheCoordinator` subscribes to the bus, pattern-matches on events, and calls the appropriate store methods. It contains no domain logic — just "when I see X, call Y."

### Concrete Flow: User Adds a Folder

```swift
// 1. User clicks Add Folder → AppDelegate receives path
func handleAddFolderRequested(path: URL) async {
    let rootURL = path.standardizedFileURL

    // 2. Persist the watched path
    _ = store.mutationCoordinator.addWatchedPath(rootURL)

    // 3. Call the focused watched-folder command surface.
    // Do not depend on the concrete FilesystemGitPipeline type here.
    let refreshSummary = await watchedFolderCommands.refreshWatchedFolders(
        store.watchedPaths.map(\.path)
    )

    // 4. Use the returned summary for immediate UX only.
    // Topology facts come from FilesystemActor, not AppDelegate.
    let repoPaths = refreshSummary.repoPaths(in: rootURL)
    if repoPaths.isEmpty {
        showEmptyFolderAlert(for: rootURL)
    }
}

// 5. WorkspaceCacheCoordinator.handleTopology(_ envelope: SystemEnvelope)
//    reads TopologyEvent from the system envelope. Repo identity lives on
//    RepositoryTopologyAtom via WorkspaceMutationCoordinator — there is no
//    WorkspaceStore.repos / addRepo.
// 6. Later, GitWorkingDirectoryProjector emits .snapshotChanged, .branchChanged
// 7. WorkspaceCacheCoordinator writes enrichment to RepoCacheAtom
// 8. Sidebar re-renders via @Observable
```

The pattern is: **persist user intent → call watched-folder command → actor scans once and posts facts via bus → coordinator processes all topology uniformly**.

### Capability Protocol Rule

The actor or pipeline that owns the work is not automatically the type that
feature code should depend on.

```text
concurrency boundary != dependency boundary
```

Use focused capability protocols for direct commands:

```text
AppDelegate
  |
  v
WatchedFolderCommandHandling
  |
  v
FilesystemGitPipeline
  |
  v
FilesystemActor
```

This keeps the caller's dependency honest:

```text
AppDelegate may ask for watched-folder refresh.
AppDelegate may not reach into unrelated pipeline methods.
```

Composition-root rule:

```text
- composition root may know the concrete pipeline type
- feature consumers should store only the focused capability they need
- do not introduce a generic command executor abstraction
```

### Topology Intake: Single Bus Pathway

All `.repoDiscovered` events flow through the `EventBus`. The coordinator's bus subscription is the single intake for all topology facts. There are no direct `coordinator.consume()` calls for topology.

**Authority model:** The user authorizes a scope (by clicking Add Folder → `store.addWatchedPath()`). The actor executes within that authorized scope (rescans only persisted watched folders). The bus carries the results.

```
User: "Watch /projects"
         │
         ▼
AppDelegate ──► store.addWatchedPath(/projects)     [authority persisted]
         │
         ▼
WatchedFolderCommandHandling ──► FilesystemActor    [direct command]
         │
         ├── return WatchedFolderRefreshSummary     [command result]
         │
         ▼
AppDelegate uses summary for immediate UX           [empty-folder alert]
         │
         ▼
FilesystemActor ──► bus.post(.repoDiscovered/.repoRemoved) [reports facts]
         │
         ▼
Bus ──► WorkspaceCacheCoordinator                   [single intake]
         │
         ├── idempotent upsert (dedup by stableKey)
         ├── seed enrichment in RepoCacheAtom
         └── sidebar re-renders via @Observable
```

Boot replay follows the same bus path:

```
Boot: restore() loads watchedPaths + repos
         │
         ├── AppDelegate posts .repoDiscovered on bus for each persisted repo
         ├── scopeSyncHandler(.updateWatchedFolders) → actor starts watching
         │         │
         │         └── actor rescans → posts .repoDiscovered for anything new
         │
         ▼
Bus ──► Coordinator (single intake, dedup by stableKey)
```

### Topology Accumulator Pattern

Topology facts flow through a layered pipeline. Each layer's output is the next layer's input. No layer reaches back.

```
LAYER              COMPONENT                        OWNS
─────              ─────────                        ────
Fact Producer      FilesystemActor                  Observing filesystem, emitting raw facts
Publication        EventBus                         Match fact topics; replay and delivery diagnostics
Accumulator        WorkspaceCacheCoordinator         Interpreting facts, sequencing effects
Reconciler         WorkspaceMutationCoordinator     WorktreeTopologyDelta in RepositoryWorktreeReconciliation.swift
State              WorkspaceStore                   Canonical truth, mutation methods
Effects            TopologyEffectHandler             Ordered follow-on work (WorkspaceSurfaceCoordinator)
Reader             Sidebar                          Rendering truth via @Observable
```

**Why not pure pub/sub for topology:** Multiple bus subscribers independently inferring what changed from raw events is fragile — ordering implicit, diffs rediscovered, cleanup ad hoc. The accumulator pattern ensures one interpreter, one diff (`WorktreeTopologyDelta`), one ordered effect chain (via `TopologyEffectHandler`).

**Why the bus still exists for topology:** Independent consumers (ForgeActor, NotificationReducer) subscribe to raw topology facts on the bus. They react independently, don't depend on store state, and don't need ordering guarantees. The bus serves notification; the handler serves sequencing.

**The handler pattern:**
- `WorkspaceCacheCoordinator` produces a `WorktreeTopologyDelta` after reconciliation
- It handles cache cleanup itself (it owns `repoCache`)
- It calls `topologyEffectHandler.topologyDidChange(delta)` for ordering-sensitive effects and a full filesystem reconciliation
- `WorkspaceSurfaceCoordinator` conforms to `TopologyEffectHandler`: it clears invalid pane associations while preserving pane lifecycle, then reconciles filesystem roots after accepted topology changes
- `WorkspaceSurfaceCoordinator` does NOT subscribe to topology events on the bus — it receives topology changes only via the handler

Ordinary pane mount/removal/CWD and active-pane changes do not re-enter this
topology accumulator. They use the separate affected-key entry points described
in [Filesystem Effect Admission And Projection](#filesystem-effect-admission-and-projection).

This replaces the previous pattern where `WorkspaceSurfaceCoordinator` subscribed to topology events on the bus and scheduled a deferred filesystem sync. That worked by accident (deferred `Task` ran after the coordinator's synchronous store mutation) but was fragile — any change to the timing would break ordering.

**Constraint:** FilesystemActor may emit `.repoDiscovered` and `.repoRemoved` only for paths under a persisted watched scope (`store.watchedPaths`). This is structurally enforced — watched-folder refresh scans only `watchedFolderIds` paths and diffs against the actor-owned baseline for those roots. The `parentPath` field on `.repoDiscovered` provides traceability back to the watched scope without coupling the event type to `WatchedPath.id`.

### What NOT to Do

- **Do not add command enums or command handlers.** Store methods ARE the commands.
- **Do not route store mutations through the bus.** The bus carries facts, not instructions.
- **Do not create separate command/event types for the same action.** One event type per fact.
- **Do not build CQRS-style read/write segregation.** Both stores are read/write via their own methods.
- **Actors may emit `.repoDiscovered` and `.repoRemoved` only within user-authorized watched-folder scopes.** `FilesystemActor` rescans persisted `WatchedPath` folders, diffs against its prior baseline, and posts topology facts on the bus. This is not autonomous discovery — the user delegated authority via Add Folder. All topology events flow through the unified bus pathway.

### Idempotency Contract

All topology handlers in `WorkspaceCacheCoordinator` are idempotent:

| Event | Dedup key | Behavior |
|-------|-----------|----------|
| `.repoDiscovered` | `stableKey` (SHA-256 of path) | Upsert: skip if exists, seed enrichment if missing |
| `.worktreeRegistered` | `worktreeId` (UUID) | Upsert: skip if exists |
| `.snapshotChanged` | `worktreeId` | Overwrite: latest wins |
| `.branchChanged` | `worktreeId` | Overwrite: latest wins |

Ordering tolerance: `.worktreeRegistered` arriving before `.repoDiscovered` is a safe no-op (guard + return). No crash, no queue.

### Writing Integration Tests with Events

Test the full event flow: emit an event → coordinator processes it → assert both stores updated. Tests call `coordinator.consume(_:)` directly — this is a deliberate test seam. App code must always flow through the bus; tests bypass it to verify coordinator logic in isolation.

```swift
@Suite struct WorkspaceCacheCoordinatorTests {
    @Test func repoDiscovered_seedsEnrichmentInCache() async {
        // Arrange
        let store = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let coordinator = WorkspaceCacheCoordinator(
            workspaceStore: store,
            repoCache: repoCache
        )
        let repoPath = URL(fileURLWithPath: "/tmp/test-repo")
        store.addRepo(at: repoPath)

        // Act — emit the topology event
        let envelope = AppDelegate.makeTopologyEnvelope(
            repoPath: repoPath,
            source: .builtin(.coordinator)
        )
        coordinator.consume(envelope)

        // Assert — cache is waiting for origin resolution for the repo
        let repo = store.repos.first!
        let enrichment = repoCache.repoEnrichmentByRepoId[repo.id]
        #expect(enrichment != nil)
    }

    @Test func repoDiscovered_idempotent_doesNotDuplicate() async {
        // Arrange
        let store = WorkspaceStore()
        let repoCache = RepoCacheAtom()
        let coordinator = WorkspaceCacheCoordinator(
            workspaceStore: store,
            repoCache: repoCache
        )
        let repoPath = URL(fileURLWithPath: "/tmp/test-repo")
        store.addRepo(at: repoPath)

        // Act — emit the same event twice
        let envelope = AppDelegate.makeTopologyEnvelope(
            repoPath: repoPath,
            source: .builtin(.coordinator)
        )
        coordinator.consume(envelope)
        coordinator.consume(envelope)

        // Assert — still only one repo, one enrichment entry
        #expect(store.repos.count == 1)
        #expect(repoCache.repoEnrichmentByRepoId.count == 1)
    }
}
```

Key testing principles:
- **Test the event path, not the store in isolation.** The coordinator IS the glue — test it with real stores.
- **Assert both owners.** A topology event should update the shared
  `RepositoryTopologyAtom` (reachable through the store wrapper) and
  `RepoCacheAtom` enrichment.
- **Test idempotency.** Emit the same event twice. Assert no duplicates.
- **Test ordering tolerance.** Emit events in wrong order. Assert no crash.

---

## Cross-References

- **Event envelope hierarchy:** [Pane Runtime Architecture — Contract 3](../runtime/pane_runtime_architecture.md#contract-3-event-envelope) — `RuntimeEnvelope` 3-tier discriminated union (`SystemEnvelope`, `WorktreeEnvelope`, `PaneEnvelope`)
- **Actor threading model:** [EventBus Design](../runtime/pane_runtime_eventbus_design.md) — connection patterns, `@concurrent` helpers, multiplexing rule
- **Pane-level replay:** [Ordering, Replay, and Idempotency](#ordering-replay-and-idempotency); EventBus per-source replay in [Current shipped behavior](../runtime/pane_runtime_eventbus_design.md#current-shipped-behavior)
- **Filesystem batching:** [Actor Responsibilities](#actor-responsibilities) (FilesystemActor debounce/max-latency)
- **Component overview:** [Component Architecture](../structure/component_architecture.md) — data model, store boundaries, coordinator role
- **Pane identity and restore:** [Session Lifecycle](../runtime/session_lifecycle.md) — pane identity contract, restore sequencing, undo/residency states
- **Surface lifecycle:** [Surface Architecture](../runtime/ghostty_surface_architecture.md) — Ghostty surface ownership, health monitoring
- **Planned: persistent folder watching:** `WatchedPath` model, periodic rescan
