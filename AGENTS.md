# Agent Studio - Project Context

macOS terminal application embedding Ghostty terminal emulator with
project/worktree management.

This file is the everyday operating contract. Match the question, open the
linked doc, then verify in current code and tests. Do not treat this file as the
architecture, atom catalog, or observability launch runbook. When you need to
know how the app is organized — folders, modules, or commands — always load
both
[Directory Structure — Source And Target Structure](docs/architecture/structure/directory_structure.md#source-and-target-structure)
and
[Command Specs And Execution Owners](docs/architecture/commands/command_specs.md#command-specs-and-execution-owners).
Do not infer organization from this file.

## Daily Commands

Use mise. Discover other tasks with `mise tasks ls`. Read one task with
`mise tasks info <name>`. First-time bootstrap lives in
[Agent Resources — First-Time Setup](docs/guides/agent_resources.md#first-time-setup).
The BridgeWeb Vite loop is
[BridgeWeb Fast UI Loop](docs/guides/agent_resources.md#bridgeweb-fast-ui-loop).
The zig/Xcode vendor note is
[Xcode And Zig Vendor Builds](docs/guides/agent_resources.md#xcode-and-zig-vendor-builds).
Swift build-slot recovery is
[Swift Build-Slot Recovery](docs/guides/agent_resources.md#swift-build-slot-recovery).
Always use `mise run` for
build and test; do not point raw `swift build` at `.build`.

```bash
mise run setup                # Prepare or reuse vendored build inputs for this worktree
mise run build                # Build the Swift app
mise run test                 # Run every routine local test and pull-request gate
mise run test:swift           # Run the Swift + serialized WebKit test lane
mise run format               # Auto-format all Swift sources
mise run lint                 # Lint (swift-format + SwiftLint + AgentStudio architecture lint)
```

Before pushing, opening, or updating a PR, run `mise run test` from the
repository root. That aggregate owns Swift lint and architecture lint, the
architecture-tool package tests, BridgeWeb lint/typecheck/unit/integration/browser/ordinary
Vite E2E tests, the packaged BridgeWeb build, Swift non-serialized, serialized
WebKit, and general E2E tests, and `git diff --check`. Use
`mise run test:<lane>` for focused work, such as
`mise run test:swift -- --filter "CommandBarState"`,
`mise run test:bridge-web`, or `mise run test:architecture`. Scope-specific
manual, packaged, observability, performance, release, or UI proof remains
additional when the change requires it. Post-merge benchmark/stress tasks and
the opt-in zmx lifecycle lane are not pull-request gates. Do not claim a branch
or PR is ready until `mise run test` exits successfully on the current HEAD.

CI runs these same mise tasks on a 3-core runner, so the Swift cooperative pool
has three threads there and sixteen on a developer Mac. A wait that polls or
blocks passes locally and starves in CI; a local green proves the logic, not the
CI verdict. A red CI run is diagnosed from its lane report and the
`swift-lane-event-streams-<run_id>` artifact and fixed at its owner. It is never
rerun, and no budget or `.timeLimit` is raised to make it pass. The protocol is
[Testing Architecture — When a run is red](docs/architecture/testing/testing_architecture.md#when-a-run-is-red).

Agents must use plain `mise run setup` by default. It builds vendors in the
primary worktree and reuses those prepared inputs from linked worktrees. Do not
hydrate submodules or invoke low-level vendor tasks directly. Use
`mise run setup --use-local-vendors` only when the user explicitly requests
Ghostty/zmx vendor work or the accepted task requires changing one of those
vendors; an ordinary setup failure does not authorize the flag.

Test topology has one owner: the `mise run test:*` tasks and
`scripts/run-swift-test-task.sh`. CI may schedule the prebuild, fast, large, and
WebKit tasks independently, but it must call those same mise tasks rather than
recreate raw `swift test` commands. The Swift fast lane keeps ordinary suites
concurrent through Swift Testing itself; do not add SwiftPM `--parallel` to the
fast inventory. Suites that share process-global state (including AppKit, MainActor
singletons, shared datastores, or long-lived buses) must be excluded from that
concurrent invocation. Annotate MainActor global suites with both `@MainActor`
and `@Suite(..., .serialized)` so `aggregate_serial_non_webkit_suite_filters`
discovers them; explicitly classified long-lived actor suites live in that same
function. Its runner executes one suite per process with at most four processes
concurrently against the already-built test bundle, avoiding SwiftPM's shared
build-path lock. `@Suite(.serialized)` serializes only within one suite; it does
not isolate that suite from other suites in the same process. Do not use SwiftPM
`--parallel` or `--num-workers` as a substitute for process isolation: Xcode
26.3 still runs Swift Testing through one helper process.

Testing: Swift 6 `Testing` only — `@Suite`, `@Test`, `#expect`. No XCTest.

Identifiers: use the repo's UUIDv7 APIs for newly generated application and test
identifiers (`UUIDv7.generate()` or the owning type's `generateUUIDv7()` helper).
Do not substitute `UUID()` merely to avoid importing
`AgentStudioInfrastructure`; add the owning import instead.

## Open The Right Doc

Start from the smallest source of truth that owns the question. For
organization, always load command specs and directory structure together.

| When | Load | What you get wrong if you skip |
| --- | --- | --- |
| How the app is organized | Always load [Source And Target Structure](docs/architecture/structure/directory_structure.md#source-and-target-structure) and [Command Specs And Execution Owners](docs/architecture/commands/command_specs.md#command-specs-and-execution-owners) (then [Files to load](docs/architecture/commands/command_specs.md#files-to-load)) | You put a type in the wrong slice, invent a parallel command path, or guess owners from this file. |
| Any architecture question | [Architecture Overview — How To Read](docs/architecture/README.md#how-to-read-this-index) | You search the tree instead of the owning doc. That index is the one architecture catalog. |
| File or new type placement | [Directory Structure — Decision Process](docs/architecture/structure/directory_structure.md#decision-process-where-does-this-file-go) | A Feature type lands in `Core/Models/`. Named component → slice lookup is [Component Architecture §7](docs/architecture/structure/component_architecture.md#7-key-files). Repo tree and SwiftPM DAG: [Repository Root](docs/architecture/structure/directory_structure.md#repository-root), [Source And Target Structure](docs/architecture/structure/directory_structure.md#source-and-target-structure), [SwiftPM Module Graph](docs/architecture/structure/directory_structure.md#swiftpm-module-graph). |
| File or module test placement | [Testing Architecture — Test Target Ownership](docs/architecture/testing/testing_architecture.md#test-target-ownership) | A module test parks on the executable target, or you infer ownership from `swift test --filter`. |
| How to write a test, wait in it, choose its lane, or diagnose a red CI run | [Testing Architecture](docs/architecture/testing/testing_architecture.md) | You add a polling wait, a per-test time budget, or a process-global suite outside isolation; you rerun CI instead of reading the lane report and the event-stream ledger. |
| Do I need an atom, derived node, eager projection, or a repository? | [Need An Atom?](docs/architecture/state/atom_persistence_boundaries.md#need-an-atom) | You wrap CRUD in an atom, assume every atom is a SQL table, or reach for `EagerDerivedAtomFamily` as a default. |
| Write-owner vs derived vs SQLite row | [Atom Persistence Boundaries — Roles](docs/architecture/state/atom_persistence_boundaries.md#roles) | A `Codable` convenience type becomes both live state and the storage contract. Survey does not mean persist. |
| Command, shortcut, tooltip, or IPC | [Command Specs And Execution Owners](docs/architecture/commands/command_specs.md#command-specs-and-execution-owners), then [Files to load](docs/architecture/commands/command_specs.md#files-to-load), [Adding a new command — decision tree](docs/architecture/commands/command_specs.md#adding-a-new-command-decision-tree), and [Exhaustive interactive and IPC projections](docs/architecture/commands/command_specs.md#exhaustive-interactive-and-ipc-projections) | You invent a button, label, icon, tooltip, shortcut, or IPC method off the spec catalog. Display hops: [Tooltips, help text, and compact control copy](docs/architecture/commands/command_specs.md#tooltips-help-text-and-compact-control-copy). |
| Native chrome / shared UI | [Style Guide — Shared Shell Controls](docs/guides/style_guide.md#shared-shell-controls) and [App Architecture — Core Hosting Patterns](docs/architecture/hosting/appkit_swiftui_architecture.md#core-hosting-patterns) | You copy styling into a feature or put a behavior constant in `AppStyles`. |
| Native git / `agentstudio-git` / `git` CLI | [agentstudio-git](docs/architecture/state/agentstudio_git.md#agentstudio-git) then the [agentstudio-git package](https://github.com/ShravanSunder/agentstudio-git) at the `Package.swift` revision | You shell out to `git`/`wt`, reimplement Git in this repo, or skip reading the package. |
| BridgeWeb React UI | This file, then [BridgeWeb AGENTS.md — UI Components](BridgeWeb/AGENTS.md#ui-components) | You hand-roll route-local controls instead of owned primitives. Token recipes live in [BridgeWeb Design-Token Architecture — Source and rendering paths](docs/architecture/bridge/bridgeweb_design_token_architecture.md#source-and-rendering-paths). The Vite loop lives in [BridgeWeb Fast UI Loop](docs/guides/agent_resources.md#bridgeweb-fast-ui-loop). |
| Bootstrap, Vite loop, zig/Xcode, build slots | [First-Time Setup](docs/guides/agent_resources.md#first-time-setup), [BridgeWeb Fast UI Loop](docs/guides/agent_resources.md#bridgeweb-fast-ui-loop), [Xcode And Zig](docs/guides/agent_resources.md#xcode-and-zig-vendor-builds), [Swift Build-Slot Recovery](docs/guides/agent_resources.md#swift-build-slot-recovery) | You hydrate vendors by hand, rebuild the full app for Bridge UI, or collide on `.build`. |
| Debug/beta proof launch | [Observability — Local proof launch](docs/architecture/observability/observability_and_traceability.md#local-proof-launch) | You inherit production identity, share zmx roots, or treat JSONL as proof. |
| MainActor, debounce, Ghostty samples, sidebar rows | [Performance Lane](#performance-lane-directive) below | You infer hop shape from `@MainActor` and skip source admission. |
| Designing or reviewing an atom, store, coordinator, actor, bus case, observer, timer, cache, projection, or MainActor hop | [MainActor And Atom Boundaries skill](.codex/skills/agentstudio-mainactor-atom-boundaries/SKILL.md) | You put gating, ordering, deadlines, retention, or I/O in an atom, or approve a lint-clean diff that still breaks the atom-method rule. |
| Writing or reviewing any test (Swift Testing, Vitest, Playwright E2E) or test support | [Writing Tests skill](.codex/skills/agentstudio-writing-tests/SKILL.md) | You write a wait with only a success exit that hangs CI for ten minutes, a diagnostic that destroys the real error, a test of a test helper, or a test in the wrong lane. |

Do not infer hop shape from `@MainActor` annotations in this file.

## Hard Rules

**Import graph.** `App/` → Core, Features, Infrastructure, SharedComponents.
`Features/` → Core, Infrastructure, SharedComponents. `Core/` → Infrastructure,
SharedComponents. `SharedComponents/` → Infrastructure. Never `Core/` →
Features, never `Features/X` → `Features/Y`, never SharedComponents →
Core/Features/App. Features never import sibling Features. App owns
cross-Feature composition. SharedComponents is stateless and depends only on
Infrastructure. Cross-target declarations use the narrowest necessary `package`
visibility; do not broadly promote product APIs to `public`. Exact placement
tests live in [Directory Structure — Import Rule](docs/architecture/structure/directory_structure.md#import-rule-hard-boundary).

**Folder arcs.** Everyday placement. Always load Directory Structure when
placing, renaming, or asking where a type lives. Trees and the compiled DAG live in
[Repository Root](docs/architecture/structure/directory_structure.md#repository-root),
[Source And Target Structure](docs/architecture/structure/directory_structure.md#source-and-target-structure),
and [SwiftPM Module Graph](docs/architecture/structure/directory_structure.md#swiftpm-module-graph).
Use [Decision Process](docs/architecture/structure/directory_structure.md#decision-process-where-does-this-file-go)
for a new file:

- `App/` — composition root, shells, pane/window controllers, lifecycle, cross-slice orchestration
- `Core/` — shared domain state and contracts (models, atoms, persistence, actions, runtime, shared split/drawer)
- `SharedComponents/` — reusable UI that does not own host placement
- `Features/` — Terminal, Bridge, Webview, CodeViewer, CommandBar, RepoExplorer, InboxNotification, EditorChooser, Sessions
- `Infrastructure/` — domain-agnostic utilities. `AtomLib/` is generic observation primitives only. Core owns `CoreAtoms`, `CoreAtomScope`, and `atom(\...)`. App owns `AtomRegistry`.

**Shared UI.** When two surfaces need the same control, extract a
SharedComponents primitive. Shared components take values, `@Binding`,
callbacks, or explicit view models; they do not read atoms or import Core,
Features, or App. Styling parity alone is not reuse. Use `AppStyles` for paint
(spacing, radii, icon sizes, opacity, typography, colors). Use `AppPolicies`
for behavior (limits, thresholds, retention, validation, routing). If changing
the value can change a state transition or command/event behavior, it is a
policy. Sidebar search uses `SharedComponents/SidebarSearchField`. Command-bar
search stays command-bar-owned. Webview select-all stays Webview-owned until a
second feature needs that exact AppKit behavior.

**BridgeWeb.** Start at [BridgeWeb UI task entry](BridgeWeb/AGENTS.md#ui-components)
for composition, shared-recipe and rendering-boundary changes. That entry routes
to the single component-language authority and its proof requirements. Use the
documented Vite loop for iteration, not full app rebuilds. Native Git:
[agentstudio-git](docs/architecture/state/agentstudio_git.md#agentstudio-git).

**Commands.** Only add commands **and command displays** through the spec
system. That means label, icon, help, tooltip, shortcut glyph, toolbar/menu
presence, command-bar row, and IPC method. Do not put those on a view.
**Why:** one `AppCommand` identity so keyboard, menu, toolbar, command bar,
tooltips, and IPC cannot drift. Hosts consume the catalog; they do not define
verbs or copy. **When:** any new user-visible verb, keystroke, chrome control,
or programmatic method. UI with no `AppCommand` still uses `LocalActionSpec` /
`ActionSpec` for the same display pipeline.

Load [Command Specs And Execution Owners](docs/architecture/commands/command_specs.md#command-specs-and-execution-owners)
then the [file table](docs/architecture/commands/command_specs.md#files-to-load).
Code against
[Adding a new command — decision tree](docs/architecture/commands/command_specs.md#adding-a-new-command-decision-tree)
and
[Exhaustive interactive and IPC projections](docs/architecture/commands/command_specs.md#exhaustive-interactive-and-ipc-projections).
Display:
[Tooltips, help text, and compact control copy](docs/architecture/commands/command_specs.md#tooltips-help-text-and-compact-control-copy).

- `AppCommand` is identity. Add the case first.
- `AppCommandSpec` is the interactive catalog: label, `CommandIcon`,
  `helpText`, shortcut, `surfacePolicy`, targeting, `visibleWhen`. Hosts
  project the spec; they do not copy those strings or icons.
  `shouldPresent` is presence only. `canDispatch` plus validators are
  enablement and authority.
- Icons, labels, help, and dense tooltips come from the spec projection:
  `AppCommandSpec` → `CommandDisplayDescriptor` → `ControlTooltipSource` →
  `ControlTooltipRenderValue`. UI-only controls use
  `LocalActionSpec.actionSpec` into the same shape. No `.help`, AppKit
  `toolTip`, or ad-hoc SF Symbol on the control.
- `AppShortcut` is bindings. Display keys with `displayKeyBinding(in:)`.
- Execute only through `AppCommandDispatcher`. Shell vs pane owners:
  [Choosing the execution owner](docs/architecture/commands/command_specs.md#choosing-the-execution-owner).
- IPC is a separate exhaustive `ipcSpec` (exposure, durable target,
  privilege, arguments). Adding an `AppCommand` must classify IPC in the
  same change. Do not add a **command.execute** verb that is not an
  `AppCommand`. Transport methods (`command.list`, `pane.*`, `terminal.*`,
  `events.subscribe`, auth) live in the IPC registry and are not a second
  command catalog.
- `LocalActionSpec` / `ActionSpec` is presentation-only when there is no
  `AppCommand`. Reuse it; do not invent a second label.

**Atoms.** Inspired by Jotai: a piece of **shared UI state** that subscribers
observe. Read our implementation:
[Need An Atom?](docs/architecture/state/atom_persistence_boundaries.md#need-an-atom),
[AtomLib Observation Primitives](docs/architecture/state/atom_persistence_boundaries.md#atomlib-observation-primitives),
and `Sources/AgentStudio/Infrastructure/AtomLib/`.

- Use an atom only when SwiftUI, a command surface, or a derived projection
  must observe the value and wake on change.
- Product atoms are `@MainActor @Observable` owners that hold values. Jotai
  atoms are config; a Provider/Store holds values.
- Derived reads use declared `AtomRevision` inputs, not Jotai `get()`
  tracking. Equal writes are comparator-suppressed.
- An atom is not a SQL table and does not have to be backed by SQLite.
- CRUD, query, coalesce, or retention with no subscriber belongs in a
  repository, not an atom.
- Pick the primitive in
  [Which primitive](docs/architecture/state/atom_persistence_boundaries.md#which-primitive).
  Choose local UI vs atom vs SQLite in
  [Shared UI, local view state, or SQLite only](docs/architecture/state/atom_persistence_boundaries.md#shared-ui-local-view-state-or-sqlite-only).
  Then classify the type in
  [Roles](docs/architecture/state/atom_persistence_boundaries.md#roles).
- Atom methods may only assign, equal-write suppress, and keep observation
  indexes — no SQL, I/O, or business rules.
- Path: `<owner>/State/MainActor/Atoms/`. Core reads `atom(\.foo)`; Feature
  atoms are injected.
- Worktrees stay structure-only; enrichment is observed cache state.

**Stores.** Persistence wrappers, not UI observation.

- One store per persistence boundary.
- Stores own I/O, debounced saves, and schema versioning. They never contain
  domain logic.
- Path: `<owner>/State/MainActor/Persistence/`. Tiers live in
  [Three Persistence Tiers](docs/architecture/state/workspace_data_architecture.md#three-persistence-tiers).

**Always ask the user** before adding an atom or store, adding unrelated
properties to an existing atom, or adding new event types or coordinator
responsibilities. Adding an atom starts at
[Update Rule](docs/architecture/state/atom_persistence_boundaries.md#update-rule).

**Coordinators.** Sequence operations across stores. Own no state, contain no
domain logic. If a coordinator `if` decides *what* to do with domain data, that
logic does not belong there.

**Bus.** Facts, not commands. Mutate the store, emit a fact, coordinator
updates the other store. Do not add command enums, route mutations through the
bus, or build CQRS. All new event plumbing uses `AsyncStream` +
`swift-async-algorithms`. No new Combine. No new NotificationCenter for
app-domain coordination. No god-store, no `ObservableObject/@Published`, no
`DispatchQueue.main.async` from C callbacks. Store-level time-dependent logic
accepts `any Clock<Duration>`.

**Coordination Plane Decision Table.** Use the narrowest plane that still
preserves the boundary:

| If the change is... | Use |
| --- | --- |
| Workspace mutation | `WorkspaceActionCommand` |
| Runtime command | `PaneRuntimeCommand` |
| Runtime fact | `PaneRuntimeEventBus` (including topology facts) |
| Ordered post-topology effects | `TopologyEffectHandler` (not via bus) |
| App-level notification that is not a command | `AppEventBus` |
| AppKit/macOS lifecycle ingress | `ApplicationLifecycleMonitor` |
| UI-only local state | Local `@Observable` state |

The old `AppCommand -> AppEventBus -> controller -> WorkspaceActionCommand`
chain is retired. Workspace work enters through validated
`WorkspaceActionCommand` routing directly.

**Architecture at a glance.** AppKit-main hosting SwiftUI. Shared UI state is
*published* from `@MainActor @Observable` atoms; that mark is the publication
owner, not a license to derive, admit, or own SQL there.
Shared Core state is actor-bound in `CoreAtoms` through the one ambient
`CoreAtomScope`. Feature-owned mutable state is never ambient. Named
coordinators sequence across stores and do not own domain logic:
[`WorkspaceSurfaceCoordinator`](Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator.swift)
(model↔view↔surface),
[`WorkspaceCacheCoordinator`](Sources/AgentStudio/App/Coordination/WorkspaceCacheCoordinator.swift)
(bus → cache/topology effects),
[`WorkspacePreparedContentMountCoordinator`](Sources/AgentStudio/App/Coordination/WorkspacePreparedContentMountCoordinator.swift)
(startup mount join),
[`WorkspaceMutationCoordinator`](Sources/AgentStudio/Core/State/MainActor/Coordination/WorkspaceMutationCoordinator.swift)
(cross-atom workspace mutations). `AtomRegistry` is App-only composition, never an
ambient lookup. `Infrastructure/AtomLib` owns only generic primitives.
Architecture lint is stock SwiftLint plus
`Tools/AgentStudioArchitectureLint`; do not add SwiftSyntax to the app package
or restore repo-local `rg` architecture-lint scripts. Catalogs and diagrams:
[Architecture Overview — How To Read](docs/architecture/README.md#how-to-read-this-index),
[Component Architecture — Principles](docs/architecture/structure/component_architecture.md#architecture-principles),
project tree and target DAG in
[Repository Root](docs/architecture/structure/directory_structure.md#repository-root)
and [SwiftPM Module Graph](docs/architecture/structure/directory_structure.md#swiftpm-module-graph),
component → slice in
[Component Architecture §7](docs/architecture/structure/component_architecture.md#7-key-files).

## Performance Lane Directive

Publish and mutate UI/atom state on MainActor. Schedule, contract, and derive
off it. `@MainActor` on an atom names the publication owner, not the
derivation thread. Classify a lane as `often` at about 10 or more
events/minute, or `heavy` at 1 ms MainActor / 50 ms off-main, then load the
owning doc before adding a hop, timer, debounce, observer, or cache.

**New EventBus case, runtime fact, or MainActor transform.** Load
[Pane Runtime Architecture — New signal decision tree](docs/architecture/runtime/pane_runtime_architecture.md#new-signal-decision-tree).
Do not invent a bus event and join/transform it on MainActor.

**New observer, debounce, poll, timer, or cache.** Load
[Demand-Driven Derived-State Refresh — Selection Rule](docs/architecture/state/demand_driven_derived_state_refresh.md#selection-rule).
Classify the input first (ordered fact, latest-state, burst, expensive
refresh, or future deadline). Debounce, throttle, and queues are mechanisms,
not classifications; the wrong one silently drops ordering, scope, or
currentness.

**What may run on MainActor vs off-main.** Load
[EventBus Design — Admission And Hop Shape](docs/architecture/runtime/pane_runtime_eventbus_design.md#admission-and-hop-shape).
It owns hop shape: contract off-main, thin MainActor adapter, publish only
changed semantic outcomes. A `@MainActor` type is not permission to derive,
schedule, or admit there.

**Ghostty title, output, CWD, or similar high-rate samples.** Load
[Contract 7](docs/architecture/runtime/pane_runtime_architecture.md#contract-7-typed-ghostty-source-admission-and-contraction)
for what must be true, then
[EventBus admission](docs/architecture/runtime/pane_runtime_eventbus_design.md#typed-admission-before-multiplexing)
for how the hop is built. Raw callbacks must not wake the bus. Exact admitted
facts/controls may take one thin MainActor runtime hop after Contract 7
disposition. Contract and equality-suppress at the source; MainActor may apply
one already-admitted value.

**Sidebar row capture vs projection.** Load
[Sidebar Data Flow](docs/architecture/state/workspace_data_architecture.md#sidebar-data-flow).
MainActor captures keyed canonical facts only. Filtering, grouping, and
row-index derivation stay in the existing detached worker. Do not join
dictionaries or derive rows in the view.

**Timing, cadence, or threshold constants.** Put them in `AppPolicies`, not
`AppStyles`. If changing the value can change a state transition or
command/event behavior, it is a policy. `AppStyles` is paint only. See
[Style Guide — Shared Shell Controls](docs/guides/style_guide.md#shared-shell-controls).

**Proving an `often`/`heavy` lane.** Load
[Observability And Traceability — Proof Model](docs/architecture/observability/observability_and_traceability.md#proof-model).
Measurement is part of the lane contract. Add marker-scoped probes; unit
tests and feel are not performance proof.

## Proof

Climb the proof pyramid. Start with focused `mise run test:<lane>` for the
changed code. Before PR readiness, run `mise run test`. Do not call unit tests,
mocks, or fake integration coverage a smoke. If a higher proof layer is
blocked, report the blocker separately from the passing lower-layer proof.

AgentStudio is an observability producer only. Do not add Docker Compose,
VictoriaMetrics, VictoriaLogs, VictoriaTraces, or collector ownership to this
repo. The shared host lives at `~/dev/ai-tools/observability`. Prefer
marker-scoped verifiers over screenshots, stale JSONL, or ad hoc log scraping.

```bash
mise run observability:up
mise run run-debug-observability -- --detach
mise run verify-debug-observability
```

Launch identity, already-running refusal, IPC escrow, beta LaunchServices, and
OTLP export rules live in
[Observability — Local proof launch](docs/architecture/observability/observability_and_traceability.md#local-proof-launch).
Collector absence or exporter failure must be fail-open for normal app startup
and must not prevent JSONL writes. OTLP exports every recorded attribute to the
configured loopback endpoint.
Agent message text must never be recorded in telemetry.

Native UI: prefer headless proof first. When visual proof is required, run a
debug or beta app and use Peekaboo with **PID targeting**. Never target debug
builds by name. **Never `pkill AgentStudio`** — it kills the user's running
app. Launch recipe:
[Peekaboo PID Targeting](docs/guides/agent_resources.md#peekaboo-pid-targeting).

**UX-first for UI changes:** talk to the user, research, align, then implement,
then Peekaboo. A wrong UX assumption wastes Swift compile time.

### No Wall-Clock Tests

A test's verdict is a function of program logic, never of machine speed. The
only elapsed-time bound a test may carry is the runner-owned hang bound, and it
is never raised to make a test pass. The standard is
[Testing Architecture — How a test may wait](docs/architecture/testing/testing_architecture.md#how-a-test-may-wait);
the lint rule `agentstudio_no_polling_wait_in_tests` enforces it.

Do not:
- use `Task.sleep(...)` in a test body to wait for async work
- loop around `Task.yield()`, a sleep, or a clock deadline until a condition holds
- give a wait a turn, poll, or time budget (`minimumTurns`, `iterations`, `timeout:`)
- use `.timeLimit` as a correctness budget; it is a hang bound, and its failure
  must name what was being awaited
- assert intermediate state after an arbitrary delay
- rely on suite serialization to hide leaked async work
- use `Task.sleep(for:)` in AgentStudio code. It has caused crash issues in this
  app; use `Task.sleep(nanoseconds:)` with explicit `Duration` conversion only
  when a sleep is unavoidable, and prefer event/state waits or injected clocks.

Instead:
- await the exact event or the owner's typed fact through the fact harness (`FactRecorder`), or the observed state change
- drive time-as-subject through a controlled clock (`TestPushClock`)
- to prove a negative, consume the operation's facts with `expectNone` from an opening position up to its correlated closing fact; never wait for idle (`waitUntilIdle` is forbidden in tests)
- give every wait an exit for each way the awaited work can fail to arrive (the producing task ending, the owner's final failure, page or process retirement); see [Every wait has an exit for every outcome](docs/architecture/testing/testing_architecture.md#every-wait-has-an-exit-for-every-outcome)
- fully shut down tasks, streams, actors, and observers before the test returns
- use explicit protocol seams and fakes for testability
- if nothing announces completion, the production owner is missing a signal:
  add it as a production contract; never poll
- do not add new `#if DEBUG` test hooks in production files

### Definition of Done

1. All requirements met
2. All applicable tests pass, including `mise run test` — show commands,
   pass/fail counts, and exit codes
3. Lint passes (`mise run lint` — zero errors)
4. Code reflects the shared mental model
5. Evidence provided (exit codes, counts)

Use DeepWiki and official docs; never guess at APIs. Grounded setup and
research sources: [Agent Resources — DeepWiki Knowledge Base](docs/guides/agent_resources.md#deepwiki-knowledge-base). Core
repos: `ghostty-org/ghostty`, `swiftlang/swift`.

## Swift Concurrency

Target: Swift 6.2 / macOS 26. `@MainActor` for store, coordinator, and UI
mutations — not for derivation, admission, or deadline scheduling. Load
[EventBus Design — Admission And Hop Shape](docs/architecture/runtime/pane_runtime_eventbus_design.md#admission-and-hop-shape)
when choosing a hop; load its
[Swift 6.2 concurrency rules](docs/architecture/runtime/pane_runtime_eventbus_design.md#swift-62-concurrency-rules-se-0461)
only for isolation gotchas.

1. **Isolation first** — `@MainActor` for UI/store mutations, `actor` for boundary work
2. **`@concurrent nonisolated` for blocking I/O** — In Swift 6.2 (SE-0461), plain `nonisolated async` inherits the caller's actor executor. Without `@concurrent`, blocking I/O called from inside an actor blocks that actor's serial executor. `@concurrent` forces escape to the global concurrent executor. **This is a correctness requirement in 6.2, not a style choice.**
3. **Structured concurrency** preferred; `Task.detached` only when isolation inheritance must be broken
4. **C callback bridging** — capture stable IDs synchronously, never defer pointer dereference across async hops
5. **AsyncStream standard** — `AsyncStream.makeStream(of:)`, explicit buffering policy, always cancel on shutdown

## Release

Releases are tag-driven from `main` via `.github/workflows/release.yml`; tag
parsing lives in `scripts/release-tag-metadata.sh`.

- Stable: `vX.Y.Z` → `AgentStudio.app`, `com.agentstudio.app`, `~/.agentstudio`, `agentstudio://oauth/callback`, Homebrew `agent-studio`.
- Beta: `vX.Y.Z-beta.N` → `AgentStudio Beta.app`, `com.agentstudio.app.beta`, `~/.agent-studio-b`, `agentstudio-beta://oauth/callback`, Homebrew `agent-studio@beta`.

After the tag workflow completes, smoke the downloaded `.app`
plist/signature/notarization and confirm the Homebrew cask SHA.

## Linear Work

Architecture documents in `docs/architecture/` are the source of truth for
design. Linear tickets track progress. Docs answer "how does it work and why."
Tickets answer "what's done and what's next." Two levels only: milestones and
tasks. A task is a concept, not an implementation step. Dependencies are
first-class (`blockedBy` / `blocks`). Active plans live in `docs/plans/` and
are date-prefixed (`YYYY-MM-DD-feature-name.md`). If a plan's date is before
the current branch's work started, it is likely completed — verify before
executing.
