# MainActor runtime pressure investigation

## 2026-08-05 18:15 EDT — research synthesis from `origin/main`

### Decision status

This document is a research artifact, not an implementation plan.

- Source: `origin/main` at `3c2ff9c22888e0ec77dd0b20ab447d7864a26c85`.
- Runtime evidence: locally shared VictoriaMetrics, stable `0.0.72`, fixed query evaluation time `2026-08-05T22:07:39Z` over the preceding 24 hours.
- Observed symptom: production-sized workspaces can make typing and tab switching feel delayed by hundreds of milliseconds while CPU exceeds one core.
- Goal: identify work that is fleet-shaped, unnecessarily frequent, or performed on `MainActor`; separate product requirements from accidental fanout; document existing resource controls and missing proof.
- Non-goals: no source/config/runtime behavior changes, no merge, and no release.

The leading result is not one root cause. Three additive pressure families survived source and metric counterchecks:

1. A surviving terminal title change is a local fact that currently invalidates whole-pane state, rebuilds every tab-bar item, and dirties whole-workspace persistence.
2. Git reads execute off-main, but the production fleet keeps the four-read pool saturated; accepted results also trigger fleet-shaped MainActor projection, including untimed trace-identity capture.
3. Independent MainActor paths remain fleet-shaped: compatibility layout recomposition, command-bar typing/filtering, repeated main-menu context construction, repository-topology index rebuilds, and telemetry attributes that derive rich pane/tab fleets.

Current telemetry proves frequency and correlation. It does not measure keystroke-to-presentation, tab-selection-to-input-ready, or establish that title refreshes cause AppKit layout.

### Recent release boundary

The investigated source is the merge commit released as both `v0.0.72-beta.1` and stable `v0.0.72` on 2026-08-05.

| Release/change | Relevant effect |
| --- | --- |
| PR #229 / `50d0b0ac3` | Moved Repo Explorer projection request construction behind Observation admission. |
| PR #241 / `f6420fc1a` | Removed durable pane topology facets and made rich pane projection derive repo/worktree association from CWD. This made pre-existing broad rich-pane reads more expensive. |
| PR #242 / `67c241c80` | Replaced whole-workspace tab context-menu capability reads with targeted graph/cursor reads. |
| PR #243 / `3c2ff9c22` | Replaced whole-workspace pane command capability reads with targeted pane/layout reads. |

PRs #242 and #243 fixed real render-time regressions. They did not create or remove the title fanout, Git cadence, compatibility layout facade, command-bar filtering, main-menu validation, trace-identity capture, or topology-rebuild paths described below.

### User requirements versus current coupling

The product requirements found in current code and tests are narrower than the implementation coupling:

- Terminal runtime metadata must retain the latest title and suppress equal values.
- `setTitle` also updates the mounted Ghostty surface title; `setTabTitle` does not.
- IPC `titleChanged` waits and runtime replay require changed title facts and ordering.
- A placeholder tab may derive its display title from active-pane runtime titles.
- A user-renamed tab is durable and overrides runtime pane titles.
- A worktree-backed pane displays repository/worktree context instead of its terminal title.
- The macOS window title is static and hidden; terminal title traffic does not update `NSWindow.title`.

Those requirements do not inherently require every changed runtime title to:

- mutate durable pane metadata;
- wake every tab item when a custom tab name or worktree label guarantees no visible change;
- enter unrelated MainActor consumers that immediately ignore it;
- cancel and recreate a whole-workspace autosave task;

There is also a correctness mismatch: title display uses the active arrangement, but runtime-event pane ownership is also resolved only through `tab.activePaneIds`. A pane that exists only in an inactive arrangement can update runtime replay and then have its canonical title event dropped. The existing all-arrangement lookup is not used by this path.

Primary sources: `TerminalRuntime.swift:249`, `TabDisplayDerived.swift:5`, `WorkspaceSurfaceCoordinator.swift:505`, `WorkspaceSurfaceCoordinator.swift:563`, `WorkspacePaneGraphAtom.swift:417`, `WorkspaceStore.swift:292`, `AgentStudioIPCRuntimeAdapter.swift:274`, and `MainWindowController.swift:64`.

### Title call path and amplification

```text
Ghostty metadata callback
  -> Ghostty.ActionRouter.handleMetadataAction
  -> per-surface TerminalLocalActionAccumulator
  -> 225 ms non-sliding title publication window
  -> MainActor compact drain
  -> TerminalRuntime equality check + metadata mutation
  -> PaneRuntimeEventChannel replay/local/outbound publication
  -> critical shared EventBus envelope
  -> MainActor WorkspaceSurfaceCoordinator
  -> WorkspacePaneGraphAtom.updatePaneTitle (keyed O(1) write)
       |-> TabBarAdapter observes paneAtom.panes wholesale
       |    -> re-derive all rich tabs and every TabBarItem
       |    -> SwiftUI tab-bar invalidation
       |-> WorkspaceStore observes paneStates wholesale
       |    -> cancel/recreate 500 ms autosave debounce
       |    -> capture and persist workspace after quiescence
       `-> unrelated shared-bus subscribers receive and ignore title
```

Existing contraction is meaningful: latest-value coalescing is per surface, the publication deadline is non-sliding, equal writes are suppressed in the accumulator/runtime/core atom, exact non-title events act as ordering barriers, and persistence has a separate debounce. The problem is that every *surviving unequal* value remains globally expensive.

The countercheck limits the causal claim:

- Proven: an admitted unequal title mutates shared pane state and causes `TabBarAdapter.refresh()`.
- Proven: many refreshed tab items cannot visibly change because custom names and worktree labels override terminal titles.
- Inferred: SwiftUI host invalidation may cause later AppKit layout.
- Not proven: title traffic causes most `PaneTabViewController.viewWillLayout()` calls or most observed interaction latency.

Primary sources: `TerminalLocalActionDrainScheduler.swift:5`, `GhosttyActionRouter+LocalActions.swift:237`, `TerminalRuntime.swift:249`, `PaneRuntimeEventChannel.swift:141`, `TabBarAdapter.swift:121`, and `TabBarAdapter.swift:163`.

### Git and repository work

Git status is not a shell process and is not executed on `MainActor`:

```text
MainActor source synchronization
  -> FilesystemGitPipeline
  -> GitWorkingDirectoryProjector actor
  -> @concurrent nonisolated status provider
  -> detached utility task
  -> agentstudio-git concurrent blocking-read queue
  -> synchronous libgit2 status
  -> FilesystemActor reduction/emission
  -> MainActor WorkspaceCacheCoordinator application
```

The distinction matters: a 1,050 ms Git status sample is off-main native-read time, not 1,050 ms of direct actor blocking. It can still compete for CPU, memory bandwidth, filesystem cache, and scheduler time while downstream application performs MainActor work.

#### Existing Git controls

| Control | Current value/behavior |
| --- | --- |
| Active cadence | 15 seconds. |
| Background distribution | 16 stable stripes, nominally one periodic full status per background worktree every 240 seconds. |
| Projector concurrency | Four computes, including one oldest-stale/active reservation. |
| Native registry | Four reads, same-root in-flight dedupe; timed-out reads retain slots until native completion. |
| Status timeout | One second. |
| Timeout breaker | Exponential 5 seconds to 60 seconds. |
| Capacity retry | Deterministic 500–600 ms, separate from failure health. |
| File event coalescing | 500 ms settle, 10 second maximum, chunks of at most 256 paths. |
| Pathspec admission | Requires a full cache and at most 128 safe literal paths; otherwise full status. |
| Watched traversal | Depth four, two traversal quanta, bounded per-quantum entries/bytes/validations/time. |
| Discovery validation | Two physical jobs, 256 logical requests, two-second logical deadline. |
| Git result apply | 16 ms coalescing before MainActor cache mutation. |

#### Remaining fleet waste

- Every 15-second tick scans and sorts all registered worktrees before selecting one background stripe: `O(W log W)` scheduler work each tick.
- Unchanged background worktrees never become quiescent; the native read floor is approximately `Wbackground / 240` reads per second.
- Active-pane changes and newly visible sidebar worktrees immediately request full status.
- A manual watched-folder refresh performs all watched-root scans and forces full status for every registered worktree.
- Fallback watched-folder discovery re-enumerates each watched root every 300 seconds.
- A discovered-repository batch can repeatedly validate/rebuild fleet indexes on MainActor. Deferred batching deduplicates path-index rebuild, not every entity dictionary/validation pass.
- Every coalesced Git enrichment batch requests trace-identity refresh. The MainActor capture rebuilds rich panes and snapshots all worktrees before equal-snapshot suppression can occur.

Primary sources: `AgentStudioGitWorkingTreeStatusProvider.swift:58`, `GitWorkingDirectoryProjector.swift:789`, `GitWorkingDirectoryProjector+Admission.swift:11`, `AppPolicies.swift:123`, `AppPolicies.swift:158`, `WorkspaceCacheCoordinator.swift:179`, `RepositoryTopologyAtom.swift:73`, and `AppDelegate+WorkspaceBoot.swift:474`.

### Live stable `0.0.72` evidence

The following are exported/surviving records, not necessarily all produced records. The trace queue uses bounded `bufferingNewest` and ignores record-yield results, so overflow is silent.

Query selector:

```promql
{service.version="0.0.72", agentstudio.release_channel="stable"}
```

Fixed evaluation window: `2026-08-04T22:07:39Z` through `2026-08-05T22:07:39Z`.

| Event | 24 h count | p95 elapsed ms | reported max ms |
| --- | ---: | ---: | ---: |
| `terminal.accumulator_drain` | 3,275 | 249.31 | 3,027.97 |
| `terminal.compact_apply` | 3,271 | 0.49 | 111.69 |
| `tabbar.refresh` | 3,208 | 11.84 | 109.61 |
| `pane_tab.layout` | 3,157 | 8.30 | 114.73 |
| `git.status` | 1,628 | 765.69 | 1,050.23 |
| `git.status_unavailable` | 1,251 | 1,081.66 | 1,257.88 |
| `coordinator.write` | 116 | 30.94 | 2,141.78 |
| `trace_identity.snapshot` | 38 | no duration | no duration |
| `commandbar.items` | 0 | null | null |
| `commandbar.filter` | 0 | null | null |

Title-drain classes:

| Drain class | count | p95 elapsed ms |
| --- | ---: | ---: |
| `title_window` | 3,130 | 248.81 |
| `immediate` | 331 | 473.15 |
| `exact_barrier` | 4 | 24.00 |

The title-window p95 is expected to include the intentional 225–250 ms contraction window. It is offer-to-drain-complete latency, not MainActor service time and not typing latency.

Git admission pressure was also high in a prior fixed trailing-30-minute stable query: 510 successful reads, 509 full-worktree reads, one pathspec read, 415 unavailable attempts, 315 capacity-exceeded attempts, 85 timeouts, 15 same-root-in-flight rejections, and logical debt up to 14. The four-read pool reached capacity. This is direct evidence of waste/pressure, not proof that libgit2 directly blocks the actor.

Process/runtime maxima over the 24-hour query were 158,259,168 bytes allocator size in use, 281,018,368 bytes allocated, 788,728 malloc blocks, and runtime-delivery debt of eight. Exported runtime/EventBus dropped gauges remained zero. These gauges are not CPU, RSS, run-loop delay, or interaction correlation.

Exact frequency query:

```promql
sum by (event) (
  increase(agentstudio_performance_events_total{
    service.version="0.0.72",
    agentstudio.release_channel="stable"
  }[24h])
)
```

Exact p95 query:

```promql
histogram_quantile(
  0.95,
  sum by (event, le) (
    increase(agentstudio_performance_event_elapsed_ms_bucket{
      service.version="0.0.72",
      agentstudio.release_channel="stable"
    }[24h])
  )
)
```

The `_max` series is a process-lifetime running maximum gauge, not a window-local histogram maximum. Resets and mixed series can make a histogram p95 exceed the displayed max; those values must not be compared naively.

### Metric boundary defects

1. There is no keystroke-to-visible-terminal-frame or command-query-to-presented-results metric.
2. There is no tab-selection-to-focused-input-ready metric.
3. `pane_action.execution` stops before Observation delivery, tab-bar refresh, host visibility reconciliation, next-turn focus, AppKit/SwiftUI display, and terminal input readiness.
4. VictoriaMetrics does not retain `pane_action.name`, so tab selection is combined with unrelated pane actions.
5. `terminal.accumulator_drain.elapsed_ms` includes pending-window wait, apply, and optional activity projection; it is not pure queue age or typing latency.
6. `git.status` measures off-main status resolution, not event-to-render convergence.
7. `pane_tab.layout` stops its timer before constructing rich pane/tab telemetry attributes and before rendering/presentation.
8. Call-site attributes are evaluated before the recorder checks whether the performance tag is enabled. Layout, pane-action, and restore sites can therefore reconstruct rich global pane/tab values on MainActor even when no performance event is emitted.
9. Trace-identity telemetry counts requests/captures/coalescing but does not time the fleet capture.
10. Persistence is log-only and has no operation duration metric in VictoriaMetrics.
11. The trace queue can silently discard records, biasing both counts and latency distributions during the pressure being measured.
12. Current process telemetry measures allocator state, not CPU, RSS, main-run-loop stall, or MainActor scheduling delay.

Primary sources: `AgentStudioPerformanceTraceRecorder.swift:168`, `AgentStudioOTLPPerformanceMetrics.swift:228`, `AgentStudioTraceEventQueue.swift:51`, `PaneTabViewController.swift:461`, and `GhosttySurfaceView+Input.swift:38`.

### Ranked MainActor inventory

This ranking combines static cost shape with trigger frequency. “Confirmed” means the source boundary/cost shape is direct; it does not imply live causal magnitude unless stated.

| Priority | Path | Trigger and cost | Boundary verdict | Evidence |
| --- | --- | --- | --- | --- |
| P0 | Layout compatibility recomposition | Divider/action mutations access computed `arrangementStates`, compose all tabs/arrangements/drawers, then replace graph/cursor dictionaries; repeated during resize. | Observable mutation stays main; rich reconstruction/index preparation is pure and should not be repeatedly fleet-shaped. | Confirmed static; runtime magnitude unmeasured. |
| P0 | Command-bar snapshot while typing | Each snapshot fuzzy-scores, sorts, groups, flattens, calculates dimming, and capability-validates displayed actions. Root cache avoids rebuilding rows, not per-query work. | State capture/apply stays main; scoring/grouping and much capability projection are pure. | Confirmed static; stable metrics absent in current window. |
| P1 | Trace-identity capture | Pane/topology/enrichment changes capture all rich panes, repos, and worktree enrichments; pane CWD association can scan worktree paths. Equal suppression occurs after capture. | Coherent atom capture stays main; matching and snapshot construction can be immutable/off-main. | Confirmed static; 38 captures, no duration. |
| P1 | Main-menu validation | AppKit validates each menu item and rebuilds similar focused-pane/context/rich-tab state per item. | Menu mutation stays main; one context snapshot can be shared per validation wave. | Confirmed static; unmeasured frequency. |
| P1 | Repository topology replacement | Rebuilds entity dictionaries and sorts worktree path indexes across the fleet; discovered batches can invoke replacement repeatedly. | Atomic publication stays main; validation/index calculation is pure. | Confirmed static; duration unmeasured. |
| P1 | Filesystem/Git downstream fanout | Core projection is actor-owned, but MainActor still captures source-sync pane/worktree fleets, scans Bridge views, applies sorted pending mutations, and refreshes identity. | Mixed: UI publication is valid; request construction/matching is movable. | Boundary confirmed; magnitude partly measured and conflated. |
| P2 | Tab-bar title fanout | Unequal title is a keyed write but whole `paneAtom.panes` observation re-derives every tab item, including items whose label cannot change, and whole-pane persistence observation is dirtied. | Main publication valid; observation granularity is accidental. | Refresh causality confirmed; AppKit-layout causality unresolved. |
| P2 | Sidebar request construction | Repo/Inbox projections run in actors, but MainActor request keys/snapshots still map full repo/worktree/notification facts. | Heavy projection already off-main; capture breadth remains. | Limited lead, not a primary proven choke. |
| P2 | Telemetry attribute construction | Hot call sites derive rich pane/tab counts after timer end and before enabled-tag rejection. | Diagnostics should be lazy/cheap and must not perturb disabled runs. | Confirmed source defect; live cost unmeasured. |
| P3 | Workspace persistence | Change observation and snapshot capture are MainActor; preparation/validation/SQLite I/O are awaited off-main. | Mostly correct ownership; title-triggered debounce churn is wasteful but not proven as synchronous choke. | Leading synchronous-persistence hypothesis refuted. |
| P3 | Terminal geometry | AppKit/Ghostty surface mutation is per mounted surface and main-required; equality/verification controls exist. | Correct isolation and local per call, though frequent layout waves can multiply it. | Fleet-shaped-per-call hypothesis refuted. |

Key anchors: `WorkspaceTabArrangementAtom+Projection.swift:7`, `CommandBarResultSession.swift:52`, `CommandBarItemSearch.swift:46`, `AppDelegate.swift:294`, `RepositoryTopologyAtom.swift:218`, `WorkspaceSurfaceCoordinator+FilesystemSource.swift:590`, `RepoExplorerView.swift:115`, and `WorkspaceSQLiteSaveCoordinator.swift:133`.

### What should remain on MainActor

- AppKit and SwiftUI state mutation, view hierarchy/layout calls, focus, menu-item mutation, and Ghostty surface mutation.
- Atomic publication into `@Observable` canonical atoms.
- A short coherent capture of main-owned values before immutable work moves elsewhere.
- Final application of generation-checked results.

### What should not remain fleet-shaped on MainActor

- Fuzzy scoring, grouping, sorting, and repeated command capability projection.
- Reconstructing rich panes/tabs solely to produce diagnostics counts.
- Worktree-path matching for every pane in trace-identity capture.
- Topology validation, grouping, index-dictionary construction, and path-index sorting before atomic publication.
- Rebuilding a whole command context independently for each AppKit menu item.
- Reconstructing all arrangement compatibility values several times for one targeted resize/mutation.
- Recomputing every tab display item for a title that cannot affect most items.

Moving calculation off-main alone is insufficient. An off-main fleet scan still consumes CPU and can starve UI work. The preferred boundary is targeted/keyed reads first; immutable off-main calculation second; bounded/coalesced publication third.

### Smallest separable proof and fix slices

No slice should combine behavioral semantics, performance instrumentation, and multiple hot paths in one PR.

1. **Measurement correctness:** make hot attributes lazy, count trace-queue drops/high-water, add duration around trace-identity capture/topology index preparation, and preserve a bounded trigger dimension for tabbar/layout. Prove disabled telemetry has no rich-projection calls.
2. **Interaction readiness:** add workload-marker-scoped tab-select-to-focused-input-ready and command-input-to-presented-results boundaries. Do not export pane IDs, titles, query text, or paths.
3. **Title semantics:** decide whether runtime/replay title, durable pane metadata, visible tab label, and inactive-arrangement ownership are one concept. Then narrow invalidation to affected tabs while preserving IPC ordering and user-renamed/worktree overrides.
4. **Git admission/cadence:** measure full-versus-pathspec reads and pool utilization under the 118-repo/163-worktree fixture; then address background quiescence and full-fleet tick sorting without changing correctness priority.
5. **Trace identity/topology:** capture minimal raw values, build immutable snapshot/indexes off-main, and atomically publish only generation-current results.
6. **Command bar/menu:** keep UI capture/apply on main, move deterministic search/grouping off-main, and reuse one command-context snapshot per validation wave.
7. **Layout compatibility:** replace repeated whole-value facade mutation with targeted graph/cursor operations and prove resize work scales with affected nodes, not fleet size.

Suggested controlled proof actions:

- 100 divider-drag updates;
- a ten-character command-bar query over the production-like item fleet;
- one validation pass over each main menu;
- one equal and one changed topology replacement;
- alternating unequal OSC titles slower than 250 ms versus repeated equal titles;
- one Git workload of at least 255 seconds to cover all 16 background stripes.

Bind each proof to tab, arrangement, drawer, pane, repo, worktree, notification, and Bridge-view counts. Aggregate count similarity alone is not causal proof.

### Setup and proof limitations

`PNPM_CONFIG_REGISTRY=https://registry.npmjs.org mise run setup` installed BridgeWeb dependencies but could not complete because the primary checkout does not contain `Frameworks/GhosttyKit.xcframework`. Therefore this branch has no local Swift build/test or launched-app proof. The source audit and Victoria queries are unaffected. Before an implementation PR claims completion, restore the vendored framework through the documented setup path and run the appropriate focused tests, `mise run lint`, `mise run test`, debug workload, and marker-bound runtime proof.
