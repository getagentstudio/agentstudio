---
name: agentstudio-mainactor-atom-boundaries
description: Use when designing, planning, implementing, or reviewing any Agent Studio Swift change that adds or changes an atom, store, repository, coordinator, actor, EventBus or AppEventBus case, runtime fact, observer, debounce, throttle, timer, deadline, cache, projection, derived reader, MainActor hop, `Task {}` on MainActor, or `nonisolated async` function. Applies to program designs, implementation plans, code, and code review.
---

# Agent Studio MainActor And Atom Boundaries

`@MainActor` on an atom, runtime, or coordinator names the **publication
owner**. It is not permission to admit, order, gate, schedule, derive, or do
I/O there. Architecture lint catches some shapes lexically; this skill covers
the semantic judgment the lint cannot make. Every rule below cites its owning
doc. Cite that doc in a review, not this file.

## 1. Decision procedure (run in order)

1. **Need an atom at all?** Nothing observes it and nothing derives from it:
   use a SQLite `*Repository`, local `@State`, or a host-owned `@Observable`.
   [Need An Atom?](../../../docs/architecture/state/atom_persistence_boundaries.md#need-an-atom),
   [Shared UI, local view state, or SQLite only](../../../docs/architecture/state/atom_persistence_boundaries.md#shared-ui-local-view-state-or-sqlite-only).
2. **Classify the input** before naming a mechanism: ordered fact,
   latest-state projection, burst of samples, expensive refresh, or future
   eligibility deadline. Debounce, throttle, polling, and queues are
   mechanisms. Each one silently drops ordering, scope, or currentness unless
   the class licenses it.
   [Selection Rule](../../../docs/architecture/state/demand_driven_derived_state_refresh.md#selection-rule),
   [The Nine-Stage Loop](../../../docs/architecture/state/demand_driven_derived_state_refresh.md#the-nine-stage-loop).
3. **Classify the plane**: command, bus fact, topology effect, atom publish,
   or AppKit lifecycle.
   [New signal decision tree](../../../docs/architecture/runtime/pane_runtime_architecture.md#new-signal-decision-tree),
   [Coordination boundaries](../../../docs/architecture/runtime/pane_runtime_architecture.md#coordination-boundaries-quick).
4. **Decide what runs where** (section 2): admit and contract at the source,
   derive and schedule off-main, then one thin MainActor apply of a compact
   `Sendable` outcome. Publish only changed semantic outcomes.
   [Admission And Hop Shape](../../../docs/architecture/runtime/pane_runtime_eventbus_design.md#admission-and-hop-shape).
5. **Pick the primitive** (section 3), then check placement and the import
   graph: `<owner>/State/MainActor/Atoms/`, Core never imports Features, and
   Features never import sibling Features.
   [Atom And Actor Placement](../../../docs/architecture/state/atom_persistence_boundaries.md#atom-and-actor-placement),
   [Hard Rules](../../../AGENTS.md#hard-rules).
6. **Name the proof.** An `often` lane (about 10 or more events/minute) or a
   `heavy` lane (1 ms MainActor, 50 ms off-main) needs marker-scoped probes.
   Unit tests and feel are not performance proof.
   [Performance Lane Directive](../../../AGENTS.md#performance-lane-directive),
   [Proof Model](../../../docs/architecture/observability/observability_and_traceability.md#proof-model).

## 2. What runs where

| Work | Runs on | Owner |
| --- | --- | --- |
| Raw callback classification, coalescing, aggregation | Source, before any MainActor hop | Runtime source admission ([Contract 7](../../../docs/architecture/runtime/pane_runtime_architecture.md#contract-7-typed-ghostty-source-admission-and-contraction)) |
| Git, filesystem, SQLite, network, process | Actor, store, or `@concurrent nonisolated` helper | Runtime/store actor ([Atom And Actor Placement](../../../docs/architecture/state/atom_persistence_boundaries.md#atom-and-actor-placement)) |
| Joins, filtering, grouping, sorting, row-index derivation | Off-main worker or existing eager seam | e.g. `RepoExplorerProjectionWorker` ([Sidebar Data Flow](../../../docs/architecture/state/workspace_data_architecture.md#sidebar-data-flow)) |
| Deadlines, cadence, retry, backoff | One reschedulable next-deadline task in the scheduling owner, with an injected `any Clock<Duration>` | Source actor or coordinator ([Selection Rule](../../../docs/architecture/state/demand_driven_derived_state_refresh.md#selection-rule)) |
| Applying a compact admitted value; equal-write suppression | MainActor | Owning atom |
| Sequencing writes across stores | MainActor | Coordinator: owns no state and makes no domain decisions ([Hard Rules](../../../AGENTS.md#hard-rules)) |

Swift 6.2 (SE-0461): plain `nonisolated async` **inherits the caller's
executor**. Pool escape needs `@concurrent nonisolated`, usually `static` with
snapshot arguments. `Task { }` inside `@MainActor` also runs on MainActor.
Prefer `@concurrent` over `Task.detached`.
[Swift 6.2 concurrency rules](../../../docs/architecture/runtime/pane_runtime_eventbus_design.md#swift-62-concurrency-rules-se-0461),
[Gotchas](../../../docs/architecture/runtime/pane_runtime_eventbus_design.md#swift-62-gotchas-quick-reference).

## 3. Pick the primitive

Read the source in `Sources/AgentStudio/Infrastructure/AtomLib/` before
using any of these.
[Which primitive](../../../docs/architecture/state/atom_persistence_boundaries.md#which-primitive),
[AtomLib Observation Primitives](../../../docs/architecture/state/atom_persistence_boundaries.md#atomlib-observation-primitives).

| Need | Use | Not |
| --- | --- | --- |
| One cohesive observed value | `AtomValue` (explicit `isContentEqual` unless the value is a `Bool`/`Int`/`Double`/`Float`/`String` scalar), or `private(set)` on the owner for a trivial field | A table-shaped atom |
| Many keys; one row wakes | `AtomFamily`; hot reads use `value(for:)`; `snapshot()` is a cold bridge only | Raw dictionary reads in hot UI |
| Cheap compose of observed atoms | A `*Derived` reader struct (`WorkspacePaneDerived`, `CommandContextDerived`). `DerivedAtom` exists but is marked not-yet-production in its source | Copying fields onto another atom; `atom(\...)` hidden inside a compute |
| Expensive keyed UI kept current off-main | The two existing `EagerDerivedAtomFamily` seams only: `TabBarAdapter`, `RepoExplorerProjectionAdapter` | A third eager seam, eager as a cache, or eager as a SQL layer |
| Grouped writes in one owner | `AtomMutationContext`: one aggregate revision bump per commit | A state kind |
| Durable copy of observed state | A store snapshots the atom; the repository writes SQL | Atom methods that touch GRDB |

## 4. The atom-method rule

Verbatim from [Hard Rules](../../../AGENTS.md#hard-rules): **"Atom methods may
only assign, equal-write suppress, and keep observation indexes — no SQL, I/O,
or business rules."**

The reference shape is `Core/State/MainActor/Atoms/RepositoryLocalActivityAtom.swift`:
about 50 lines. It holds one `AtomFamily`, keyed reads, a snapshot bridge, and
`publishAuthoritative`/`publishUnavailable` that assign already-decided
values.

| Logic | Where it goes instead |
| --- | --- |
| Ordering: newest-wins, `max`/`min`, monotonic guards | The source actor or projector that sees the ordered stream, or a pure `nonisolated` rule function outside the `*Atom` type. The atom receives the winner. |
| Gating, rate limits, coalescing, "publish at most every N" | Source admission ([Contract 7](../../../docs/architecture/runtime/pane_runtime_architecture.md#contract-7-typed-ghostty-source-admission-and-contraction)) or the scheduling owner; the class comes from the [Selection Rule](../../../docs/architecture/state/demand_driven_derived_state_refresh.md#selection-rule) |
| Deadlines, timers, pending maps, `Task` handles | Scheduling owner with an injected clock. The atom never owns a `Task`. |
| First-insert or provenance admission, fallbacks, validation | Validator, `*Policy` rule module, or coordinator step before the write ([Validation Boundary](../../../docs/architecture/state/atom_persistence_boundaries.md#validation-boundary)) |
| Retention: horizons, caps, eviction | Repository or store policy. Numbers live in `AppPolicies`. |
| SQL, files, processes | Repository or store; the atom is snapshotted, never the writer ([Writer-Owned Atoms](../../../docs/architecture/state/atom_persistence_boundaries.md#writer-owned-atoms)) |
| Behavior constants (limits, thresholds, clamps, cadence) | `AppPolicies`, not `AppStyles` and not an atom literal ([Shared Shell Controls](../../../docs/guides/style_guide.md#shared-shell-controls)) |

## 5. Ask the owner first

Stop and ask before any of these ([Hard Rules](../../../AGENTS.md#hard-rules),
[Update Rule](../../../docs/architecture/state/atom_persistence_boundaries.md#update-rule)):

- adding an atom or a store;
- adding unrelated properties to an existing atom;
- adding a new event type (a `RuntimeEnvelope`/`AppEvent` case or a runtime fact);
- giving a coordinator a new responsibility;
- adding a third `EagerDerivedAtomFamily` seam, which the doc forbids outright.

## 6. Reviewer checklist

Cite the linked section in each finding.

- [ ] Is there a subscriber that must wake? If not, it should not be an atom. [Need An Atom?](../../../docs/architecture/state/atom_persistence_boundaries.md#need-an-atom)
- [ ] Is every new type or field classified into one lifecycle lane and one role, and not both live state and a row projection? [Roles](../../../docs/architecture/state/atom_persistence_boundaries.md#roles), [Update Rule](../../../docs/architecture/state/atom_persistence_boundaries.md#update-rule)
- [ ] Does every write path have a content comparator, so that equal writes do not wake observers? [Update Rule](../../../docs/architecture/state/atom_persistence_boundaries.md#update-rule)
- [ ] Do atom methods only assign, suppress equal writes, and keep indexes? [Hard Rules](../../../AGENTS.md#hard-rules)
- [ ] Is the input classified before a debounce, throttle, poll, queue, or timer is named? [Selection Rule](../../../docs/architecture/state/demand_driven_derived_state_refresh.md#selection-rule)
- [ ] Is every stage made explicit, and does each implemented stage emit bounded outcome telemetry? [The Nine-Stage Loop](../../../docs/architecture/state/demand_driven_derived_state_refresh.md#the-nine-stage-loop), [Per-Stage Outcome Telemetry](../../../docs/architecture/state/demand_driven_derived_state_refresh.md#per-stage-outcome-telemetry)
- [ ] Are raw samples contracted at the source rather than waking the bus or MainActor per callback? [Contract 7](../../../docs/architecture/runtime/pane_runtime_architecture.md#contract-7-typed-ghostty-source-admission-and-contraction), [Typed Admission Before Multiplexing](../../../docs/architecture/runtime/pane_runtime_eventbus_design.md#typed-admission-before-multiplexing)
- [ ] Does MainActor apply one compact admitted value and publish only changed outcomes? [Admission And Hop Shape](../../../docs/architecture/runtime/pane_runtime_eventbus_design.md#admission-and-hop-shape)
- [ ] Do filtering, grouping, sorting, and joins stay off-main, never in a view `body` or an atom? [Sidebar Data Flow](../../../docs/architecture/state/workspace_data_architecture.md#sidebar-data-flow)
- [ ] Does blocking or heavy work leave the actor through `@concurrent nonisolated`, not through `nonisolated async` or `Task {}`? [Swift 6.2 Gotchas](../../../docs/architecture/runtime/pane_runtime_eventbus_design.md#swift-62-gotchas-quick-reference)
- [ ] Are there no commands on either bus, and does every new fact sit on the right plane? [Commands never on the bus](../../../docs/architecture/runtime/pane_runtime_eventbus_design.md#commands-never-on-the-bus), [Coordination Planes](../../../docs/architecture/README.md#coordination-planes)
- [ ] Is new plumbing built on `AsyncStream`, with no Combine, no app-domain NotificationCenter, and no `DispatchQueue.main.async` from C callbacks? [Hard Rules](../../../AGENTS.md#hard-rules)
- [ ] Is persistence tiered correctly, with data flowing down only? [Three Persistence Tiers](../../../docs/architecture/state/workspace_data_architecture.md#three-persistence-tiers)
- [ ] Do tests await the owner's typed facts, events, or observed state, never idle or quiescence, with no yield loops, sleeps, or budgets? [Typed facts](../../../docs/architecture/testing/testing_architecture.md#typed-facts) [How a test may wait](../../../docs/architecture/testing/testing_architecture.md#how-a-test-may-wait)
- [ ] Is the debt ledger unchanged or lower, with no new rows and no raised counts? [Debt Ledger](../../../docs/architecture/structure/architecture_lint_inventory.md#debt-ledger)

## 7. Red flags

Current examples are on `main` at 60dc05cbd. They are known debt. Do not copy
them, and do not cite them as precedent.

| Pattern | Why it is wrong | Correct shape | Real example |
| --- | --- | --- | --- |
| Publish gate, pending map, and deadline `Task` inside an atom | Admission and scheduling on the publication owner; the lint sees only the `Task` | Latest-value deferral in the source/projector; the atom assigns the admitted fact | `Core/State/MainActor/Atoms/PaneActivityStatusAtom.swift:41-49,91-129,152-174` |
| Timeout `Task` plus continuation waiters in an atom | Deadline scheduling lives in an observed-state owner | Waiter/deadline owner outside the atom; the atom records the fact | `Core/State/MainActor/Atoms/WindowLifecycleAtom.swift:192,206` |
| Newest-wins ordering, horizon cutoff, per-kind caps, and sort in an atom | Ordering, retention, and derivation in atom methods | Retention policy in the store/repository; ordering by a rule function outside the type | `Core/State/MainActor/Atoms/EntityRecencyAtoms.swift:88-127,193-208` |
| CWD admission with a `FileManager` fallback in an atom write | Admission rule and environment read inside the atom | Admit through the policy before the write; pass the admitted value | `Core/State/MainActor/Atoms/WorkspacePaneGraphAtom.swift:371-379` |
| Literal layout clamp in atom logic | A behavior constant outside `AppPolicies` and a rule in an atom (review-only; no lint catches it) | `AppPolicies` constant applied by a layout rule | `Core/State/MainActor/Atoms/WorkspaceTabArrangementAtom.swift:95` |
| `for await` on MainActor with a per-element hop and no stored-value guard | MainActor wakes per element, not per changed outcome | Contract off-main; guard `element != stored` before applying | `Features/Terminal/Routing/TerminalActivityRouter.swift:163-167` |
| Sort, reduce, or grouping in `@MainActor` types | Unbounded collection work on MainActor | Off-main worker or eager seam | `Core/RuntimeEventSystem/Replay/EventReplayBuffer.swift:257-279` (10 ledger sites) |
| `canDispatch`, sort, or filter in a SwiftUI `body` | Derivation in view evaluation | Prepared read model or deferred closure | `App/Panes/TabBar/ShellTabBarControls.swift:92` (`body` builds a presentation whose init calls `canDispatch` at `:48`; 15 ledger files) |
| `await Task.yield()` loops in tests | Verdict depends on machine speed; starves a 3-core CI runner | Use `expectNext` for the owner's typed fact, or await an observed state change; use `TestPushClock` for time | `Tests/AgentStudioTests/Core/PaneRuntime/Sources/GitWorkingDirectoryProjectorTests.swift:357` (20 ledger sites) |

Paths above are relative to `Sources/AgentStudio/` except the test row.

## 8. Lint is a backstop, not the review

`mise run lint` runs `Tools/AgentStudioArchitectureLint` with a shrink-only
debt ledger (`architecture-debt-ledger.tsv`). The relevant rules are
`agentstudio_atom_assign_only`, `agentstudio_mainactor_unbounded_collection_work`,
`agentstudio_mainactor_hop_per_element`, `agentstudio_swiftui_body_derivation`,
`agentstudio_nonisolated_async_blocking_io_requires_concurrent`,
`agentstudio_performance_constants_in_app_policies`, and
`agentstudio_no_polling_wait_in_tests`. All of them are lexical.
`agentstudio_atom_assign_only` sees `Task`, `Timer`, `FileManager`,
`DispatchQueue`, `sorted`, and `sort`. It does not see `min`/`max` ordering,
publish gates, pending maps, or I/O through a helper outside the type. A
lint-clean diff can still break section 4. Never add a ledger row or raise a
count to land a change.
[Debt Ledger](../../../docs/architecture/structure/architecture_lint_inventory.md#debt-ledger),
[SwiftSyntax Architecture Rules](../../../docs/architecture/structure/architecture_lint_inventory.md#swiftsyntax-architecture-rules),
[Review-Only Guidance](../../../docs/architecture/structure/architecture_lint_inventory.md#review-only-guidance).
