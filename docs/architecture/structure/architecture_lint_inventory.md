# Architecture Lint Inventory

This inventory maps AgentStudio's architecture rules to their current proof
surface. Update it in the same change when adding, removing, or reclassifying an
architecture lint rule.

Architecture lint now has two layers:

- stock SwiftLint from `.swiftlint.yml`, including regex `custom_rules`
- AgentStudio's repo-local SwiftPM/SwiftSyntax tool at
  [`Tools/AgentStudioArchitectureLint`](../../../Tools/AgentStudioArchitectureLint)

The local architecture tool is not a SwiftLint plugin. It runs alongside stock
SwiftLint through `mise run lint` and CI. Do not restore an external
custom-SwiftLint toolchain. Do not reintroduce repo-local shell/`rg`
architecture-lint scripts for rules that SwiftSyntax can express, and do not
add SwiftSyntax dependencies to the app package.

Architecture diagnostics have two severities, `error` and `warning`, and both
make the architecture-lint command exit non-zero. There is no report-only
severity: a new guardrail whose shape already exists in the tree freezes those
sites in the debt ledger instead.

## Enforcement Points

| Where | What runs | Fails on |
| --- | --- | --- |
| `mise run lint` (locally, and the CI `Code quality` job) | swift-format, stock SwiftLint, then [`scripts/lint-swift.sh`](../../../scripts/lint-swift.sh) builds the architecture tool in release inside the build slot and runs it over `Sources`, `Tests` and every tracked `AGENTS.md` with `--ledger` | any `error`/`warning` diagnostic, including ledger drift |
| `mise run lint -- <files>` (scoped) | the same tool, parsing the whole corpus but validating only the named `.swift` files and `AGENTS.md` files (`--only`) | the same diagnostics a full run reports for those files |
| CI `Code quality` job, step `Debt ledger ratchet` | [`Tools/AgentStudioArchitectureLint/check-ledger-ratchet.sh`](../../../Tools/AgentStudioArchitectureLint/check-ledger-ratchet.sh) compares each debt ledger — this tool's and [`BridgeWeb/architecture-debt-ledger.tsv`](../../../BridgeWeb/architecture-debt-ledger.tsv), which share one format — with its copy at the merge base (`--check-ledger-ratchet`) | a raised count or a new row in either ledger |
| `mise run test:architecture` (part of `mise run test`) | the lint tool's own tests: rule inventory, Good/Bad fixtures per rule, ledger and ratchet tables, scoped-versus-full parity | a rule that stops matching its Bad fixture or starts matching its Good fixture |

Every run prints `lint-swift timing stage=<stage> ms=<n>` per lint stage and
`architecture-lint timing rule=<id> ms=<n>` per rule (its `prepared(for:)` plus
its validation summed across files). Timings are reported, never compared with a
threshold, and never change the exit code.

## Debt Ledger

[`Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv`](../../../Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv)
holds the only debt: one row per rule and repository-relative path with the
number of violation sites that file may still hold. It is tab-separated with a
header and sorted by rule, then path; a malformed or unsorted ledger fails the
run closed.

| Sites found (n) vs row (k) | Result |
| --- | --- |
| n = k | pass: known debt |
| n > k, or no row and n > 0 | every site in the file is reported, with both counts |
| 0 < n < k | one error naming the count to record |
| n = 0 < k | one error naming the row to remove |
| row path gone or not linted (full runs) | one error at the ledger row |

`--lower-ledger-counts` rewrites the ledger down to what the run found and
removes zero or missing rows; it never raises a count or adds a row. Raising or
adding is what the CI ratchet rejects. Named-owner allowances are not debt: they
stay in `ArchitectureAllowlists` with one owner and reason each (for example
`mainActorPerElementAdapters`).

### Integration note: causal-test harness owners

The blocking-wait rule exempts only the named owner files, not a folder. The
causal-test harness pull request adds its two owner entries to
`ArchitectureAllowlists.blockingTestWaitOwners` when it merges:
`Tests/AgentStudioTestHarness/HeldStep.swift` (`HeldStep.arriveBlocking` parks
a dedicated thread per arrival) and
`Tests/AgentStudioTestHarness/DedicatedThreadWork.swift`
(`valueFromDedicatedThread`, the one implementation of running blocking work
off the cooperative pool). They are not listed before then, because a full run
fails on an owner whose file does not exist.

## SwiftSyntax Architecture Rules

| Contract | Rule ID | Severity | Source |
| --- | --- | --- | --- |
| Drawer toolbar actions render through `ToolbarActionButton`, not raw `Button`s. | `agentstudio_drawer_toolbar_owned_controls` | error | [`docs/guides/style_guide.md`](../../guides/style_guide.md#shared-shell-controls) |
| Source layers follow the documented import direction. | `agentstudio_import_direction` | error | [`docs/architecture/structure/directory_structure.md`](directory_structure.md) |
| Product atom state follows the Core, Feature, and App composition boundaries; removed compatibility, resolver, registration, and secondary-scope APIs stay absent. | `agentstudio_product_atom_boundary` | error | [`docs/architecture/structure/directory_structure.md`](directory_structure.md) |
| Canonical atom-owner classes expose mutable stored state only as `private` or `private(set)` and reject writable bindings. | `agentstudio_canonical_atom_mutation` | error | `AGENTS.md#hard-rules` |
| The retired Worktrunk CLI and production `wt`/Git CLI worktree data plane must not be reintroduced. | `agentstudio_retired_worktrunk_cli` | error | `AGENTS.md#hard-rules` |
| `SharedComponents/` render from explicit inputs and do not access atoms or global stores. | `agentstudio_shared_components_are_stateless` | error | [`docs/architecture/structure/directory_structure.md`](directory_structure.md) |
| [`Infrastructure/AtomLib`](../../../Sources/AgentStudio/Infrastructure/AtomLib) stays generic and does not reference product atoms or feature state. | `agentstudio_atomlib_is_generic` | error | [`docs/architecture/state/atom_persistence_boundaries.md`](../state/atom_persistence_boundaries.md) |
| `DerivedAtom` compute closures use declared inputs and do not hide atom reads through direct or same-file helper/wrapper calls. | `agentstudio_derived_atom_declared_inputs` | error | [`docs/architecture/state/atom_persistence_boundaries.md`](../state/atom_persistence_boundaries.md) |
| Hot production reads use keyed repo-cache readers instead of raw observable dictionaries. | `agentstudio_repo_cache_keyed_reads` | error | [`docs/architecture/state/atom_persistence_boundaries.md`](../state/atom_persistence_boundaries.md) |
| Hot tab/sidebar command presentation uses pane membership plus keyed structural reads, not bulk pane snapshots. | `agentstudio_hot_pane_snapshot_reads` | error | [`docs/architecture/state/workspace_data_architecture.md`](../state/workspace_data_architecture.md#sidebar-data-flow) |
| `WorktreeEnrichment` atom comparators do not use raw equality. | `agentstudio_worktree_enrichment_comparator` | error | [`docs/architecture/state/atom_persistence_boundaries.md`](../state/atom_persistence_boundaries.md) |
| New state files use the `State/MainActor/{Atoms,Persistence}` path convention. | `agentstudio_state_actor_path` | warning | [`docs/architecture/structure/directory_structure.md`](directory_structure.md) |
| Programmatic-control contracts stay transport/app/UI independent. | `agentstudio_ipc_programmatic_control_boundary` | error | [`docs/architecture/commands/ipc.md`](../commands/ipc.md) |
| `AgentStudioAppIPC` exposes ports instead of concrete app/runtime owners. | `agentstudio_appipc_port_boundary` | error | [`docs/architecture/commands/ipc.md`](../commands/ipc.md) |
| Concrete AppIPC port implementations and method contributions live under [`Sources/AgentStudio/App/IPCComposition`](../../../Sources/AgentStudio/App/IPCComposition). | `agentstudio_ipc_composition_location` | error | [`docs/architecture/commands/ipc.md`](../commands/ipc.md) |
| Feature slices do not import the app IPC service target directly; feature IPC methods are app-composed contributions. | `agentstudio_features_do_not_import_appipc` | error | [`docs/architecture/commands/ipc.md`](../commands/ipc.md) |
| Public IPC surfaces expose scrubbed DTOs, not zmx namespaces or raw runtime payloads. | `agentstudio_ipc_public_surface_sanitization` | error | [`docs/architecture/commands/ipc.md`](../commands/ipc.md) |
| AppIPC services and adapters route through ports and owners instead of direct atom access. | `agentstudio_ipc_no_direct_atom_access` | error | [`docs/architecture/commands/ipc.md`](../commands/ipc.md) |
| Sentinel fixture proves the local architecture rule registry is active. | `agentstudio_no_forbidden_architecture_marker` | error | [`Tools/AgentStudioArchitectureLint/Tests/AgentStudioArchitectureLintTests/Fixtures/Bad/Sources/AgentStudio/App/BadForbiddenArchitectureMarker.swift`](../../../Tools/AgentStudioArchitectureLint/Tests/AgentStudioArchitectureLintTests/Fixtures/Bad/Sources/AgentStudio/App/BadForbiddenArchitectureMarker.swift) |
| Production async delays avoid generic clock sleep overloads. | `agentstudio_no_generic_clock_sleep` | error | `AGENTS.md#no-wall-clock-tests` |
| Tests avoid direct wall-clock `Task.sleep(...)` calls and wait for events, state, or injected fake clocks. | `agentstudio_no_task_sleep_in_tests` | error | `AGENTS.md#no-wall-clock-tests` |
| Tests contain no polling wait: a loop around a scheduler yield, a sleep, or a clock deadline. Existing sites are counted in the debt ledger. | `agentstudio_no_polling_wait_in_tests` | error | [`docs/architecture/testing/testing_architecture.md`](../testing/testing_architecture.md#how-a-test-may-wait) |
| Tests park a thread in a socket read, semaphore wait or process wait only off the cooperative pool. The named owners in `ArchitectureAllowlists.blockingTestWaitOwners` (each with an owner and reason) own their blocking waits; a full run fails when an owner's file is gone or no longer blocks at all. Existing sites elsewhere are counted in the debt ledger. | `agentstudio_test_blocking_wait_off_cooperative_pool` | error | [`docs/architecture/testing/testing_architecture.md`](../testing/testing_architecture.md#how-a-test-may-wait) |
| Tests carry no per-test elapsed-time budget: no `DefaultProcessExecutor` construction, no `wait(timeout:)` or `wait(wallTimeout:)` on a `DispatchSemaphore` or `DispatchGroup` binding, no `asyncAfter`, and no timed `waitForFile`. The named owners in `ArchitectureAllowlists.elapsedTimeBudgetOwners` (each with an owner and reason) keep theirs; a full run fails when an owner's file is gone or no longer carries a budget. Existing sites elsewhere are counted in the debt ledger. | `agentstudio_no_test_elapsed_time_budget` | error | [`docs/architecture/testing/testing_architecture.md`](../testing/testing_architecture.md#how-a-test-may-wait) |
| Tests install the shared Core atom fallback only through [`TestAtomRegistry.swift`](../../../Tests/AgentStudioTests/TestSupport/TestAtomRegistry.swift). | `agentstudio_test_core_atom_fallback_ownership` | error | [`docs/architecture/testing/testing_architecture.md`](../testing/testing_architecture.md#test-target-ownership) |
| A completion handle (`Task`) is never discardable: no `@discardableResult` on a declaration returning `Task<…>`/`Task<…>?`; an explicit `_ =` or `_ = await` discard of a call to a task-returning function carries `// fire-and-forget: <reason>` on its line or the line directly above; and no task-returning name is also declared with a non-task result. | `agentstudio_completion_handle_not_discardable` | error | `docs/specs/2026-09-23-ci-guardrails/2026-09-23-ci-guardrails-program-design.md#completion-handles-s3` |
| Dense action controls use typed tooltip sources instead of raw `.help("...")`, AppKit `toolTip = "..."`, or custom hover strings. Shared components consume resolved render values only. | `agentstudio_toolbar_tooltip_source` | error | `docs/architecture/commands/command_specs.md#tooltips-help-text-and-compact-control-copy` |
| Production EventBus subscriptions and wait helpers name an explicit semantic subscriber policy; wrappers cannot hide a default or zero-argument policy. | `agentstudio_eventbus_subscriber_policy_required` | error | [`Sources/AgentStudio/Core/RuntimeEventSystem/Events/EventBus.swift`](../../../Sources/AgentStudio/Core/RuntimeEventSystem/Events/EventBus.swift) |
| Terminal-local `GhosttyActionDisposition` branches contract locally and cannot reach the shared exact semantic publication edge. | `agentstudio_terminal_local_disposition_publication` | error | [Pane Runtime Contract 7](../runtime/pane_runtime_architecture.md#contract-7-typed-ghostty-source-admission-and-contraction) |
| Bridge comparison-target query control authorizes and reserves content; catalog production belongs to the content task producer. | `agentstudio_comparison_target_query_control_production` | error | [Bridge Product Transport — The three route jobs](../bridge/bridge_product_transport_architecture.md#the-three-route-jobs) |
| Observation-capture closures use keyed reads instead of named whole-snapshot calls. | `agentstudio_observation_capture_keyed_reads` | error | [`docs/architecture/state/atom_persistence_boundaries.md`](../state/atom_persistence_boundaries.md) |
| `@MainActor` types do not perform named collection-wide sort, reduce, grouping, or hash calls without an allowlisted owner. | `agentstudio_mainactor_unbounded_collection_work` | error | [EventBus Design — Admission And Hop Shape](../runtime/pane_runtime_eventbus_design.md#admission-and-hop-shape) |
| Numeric timing and performance-threshold constants live in `AppPolicies`. | `agentstudio_performance_constants_in_app_policies` | error | [`docs/guides/style_guide.md`](../../guides/style_guide.md#shared-shell-controls) |
| `nonisolated async` declarations that make syntactically blocking file reads use `@concurrent`. | `agentstudio_nonisolated_async_blocking_io_requires_concurrent` | error | `AGENTS.md#swift-concurrency` |
| A `withObservationTracking` whose `onChange` re-invokes its arming method is controlled by a generation fence that compares stored state (`self.generation`, a stored member or subscript) with a captured `let` or parameter — `guard stored == captured else { exit }` or `if stored != captured { exit }` before the re-arm, or the re-arm nested in `if stored == captured` — or by an arm latch whose `guard !flag` and `flag = true` are top-level statements before the arm and whose `onChange` sets `flag = false`. A literal or local on the stored side is not a fence. Product sources. | `agentstudio_observation_rearm_guarded` | error | [Demand-Driven Derived-State Refresh](../state/demand_driven_derived_state_refresh.md#selection-rule) |
| A SwiftUI `body`, and the same-file builders and helpers of its own type (or file-scope functions) it reaches, does no dispatcher `canDispatch`, `snapshot(state:)`, `fuzzyMatch`/`score*`, `sorted`/`sort`/`filter`/`reduce`/`grouping:`, and calls no resolver the prepared cross-file index shows calling dispatcher `canDispatch`. Deferred closures (`action:`, `perform:`, `on…:` handlers, `Button`/`.task`/`.on…` trailing closures) and `Optional.map`/`compactMap` are outside it. Product sources. | `agentstudio_swiftui_body_derivation` | error | [`docs/architecture/state/workspace_data_architecture.md`](../state/workspace_data_architecture.md#sidebar-data-flow) |
| A `*Atom` type under `/State/MainActor/Atoms/` references no `FileManager`, `Process`, `URLSession`, `Timer`, `DispatchQueue` or `sqlite3_*`, starts no `Task`/`Task.detached`, and calls no `withObservationTracking`, `sorted` or `sort`. `*Derived` readers, rule modules and free functions are outside it. | `agentstudio_atom_assign_only` | error | [Need An Atom?](../state/atom_persistence_boundaries.md#need-an-atom) |
| No `MainActor.run` or `@MainActor` closure inside a `for await` body; a `for await` that runs on MainActor (lexically: a `@MainActor` closure, method or type, through unannotated `Task { }` bodies) starts, after bindings and cancellation checks, with a guard comparing the element with stored last-published state: `guard element != stored else { exit }`, `if element == stored { exit }`, or the body is exactly `if element != stored { … }`. A literal or loop local on the other side is not a guard. Named-owner allowance: `WorkspaceSurfaceCoordinator.startRuntimeReducerConsumers`. Product sources. | `agentstudio_mainactor_hop_per_element` | error | [EventBus Design — Admission And Hop Shape](../runtime/pane_runtime_eventbus_design.md#admission-and-hop-shape) |
| Files under `Diagnostics/` or `Telemetry/`, or named `*Recorder*`, `*Telemetry*`, `*Probe*` or `*Sampler*`, report off MainActor: no `MainActor.run`, `@MainActor` closure, or `@MainActor` `*Reporter` type or typealias. | `agentstudio_probe_reports_off_main` | error | [Observability — Proof Model](../observability/observability_and_traceability.md#proof-model) |
| A `*Gate`, `*Latch`, `*Barrier`, `*Blocker` or `*Hold` type in `Tests/`, outside the causal-test harness target (`AgentStudioTestHarness`), stores no continuation, `DispatchSemaphore` or `NSCondition`; holds use the harness's `HeldStep`. | `agentstudio_test_ad_hoc_gate` | error | [`docs/architecture/testing/testing_architecture.md`](../testing/testing_architecture.md#how-a-test-may-wait) |
| An `async` test helper named `wait…`, `require…`, `await…`, `waitUntil…` or `expect…Eventually` returns the observation that satisfied it. | `agentstudio_test_wait_helper_returns_observation` | error | [`docs/architecture/testing/testing_architecture.md`](../testing/testing_architecture.md#how-a-test-may-wait) |
| Every link target and repository-path code token in each `AGENTS.md` exists, and each `#anchor` is a GitHub heading slug or explicit `<a id>`/`<a name>` in its target. | `agentstudio_agent_doc_reference_resolves` | error | `AGENTS.md` |
| Owner-local synchronous fact sinks are stored and injected only by their indexed owner, owner sink initializers use optional `nil` defaults, and supported fact-scope preparation stays behind a sink gate. | `agentstudio_owner_fact_sink_boundary` | error | [Fact-sink boundary rule](#fact-sink-boundary-rule) |

All rules are lexical: they recognize only the call, declaration and literal
shapes named above and do not resolve types, executors or control flow. Their
false-negative limits:

- `agentstudio_observation_rearm_guarded` judges the construction, not the call
  graph: a fenced re-arm with a second, unfenced arm path elsewhere passes, and
  a re-arm through a differently named helper is not seen.
- `agentstudio_swiftui_body_derivation` follows only same-file members and
  `Type.member`/`Type(...)` resolvers; a resolver reached through a protocol-typed
  variable or a stored closure's later call is not seen.
- `agentstudio_mainactor_hop_per_element` sees only lexical `@MainActor`; a loop
  that inherits MainActor from a caller, or a `for try await`, is judged by the
  same text rules, and an implicitly isolated SwiftUI `View` is not seen.
- `agentstudio_atom_assign_only` names types, not behaviour: I/O through a helper
  defined outside the atom type is not seen.
- `agentstudio_test_ad_hoc_gate` matches the name suffixes only; a gate with
  another name is caught only when it also becomes a void wait helper.
- `agentstudio_agent_doc_reference_resolves` checks only `AGENTS.md` files and
  treats root entries present on disk as repository paths.

The Terminal publication guard is deliberately lexical. In AgentStudio's
Terminal source, it recognizes switches whose subject is
`GhosttyActionDisposition.classify(...)`; the exact classifier call must be the
direct switch subject rather than a stored result. Each `.latestPresentation`,
`.latestSemanticMetadata`, `.activityEvidence`, `.exactLocalLifecycle`, and
`.diagnostic` branch must end in a top-level `return` and must not directly call
`routeActionToTerminalRuntimeOnMainActor`. This blocks direct local-branch
publication, stored-classifier bypass, and post-switch fallthrough to the shared
semantic edge while leaving `.exactFactOrControl` eligible for that ordered
route. The rule does not perform general type resolution or control-flow
analysis. It does not enforce Inbox classification; `InboxNotificationRouter`
is outside this active guard.

The completion-handle rule is syntax-only. Its explicit-discard predicate
resolves a callee by base name against an index of every `func` declaration in
the linted tree whose result is `Task<…>` or `Task<…>?`. The index is exact
because a third predicate fails when a task-returning name is also declared with
any other result anywhere in `Sources` or `Tests`: the non-task twin gets its own
name, and there is no exclusion list. Only a direct call (`f(…)`, `x.f(…)`,
`x?.f(…)`) on the right of `_ =`, optionally under `await` or `try`, is checked;
`_ = await f().value` discards an awaited outcome, not the handle, and is not
flagged. Stored-handle accessors that return a task (`take*Task`, an enum
payload `task`) are neither discardable nor discarded. A bare, unused
non-discardable result is rejected by the compiler instead: every
repository-owned SwiftPM target sets `treatAllWarnings(as: .error)`.

The retained `InboxNotificationRouter` source is dormant historical implementation:
its exhaustive switches describe preserved source, not an active enforcement owner.
It must not be reconnected without a new product decision.

### Fact-sink boundary rule

`agentstudio_owner_fact_sink_boundary` indexes synchronous two-argument
`*FactSink` aliases, their companion owner hints, owner initializers and stored
sink properties from workspace-relative production `Sources/` roots. Test
paths are excluded even when a test directory contains a nested `Sources/`
component. Rule fixtures use a fixture corpus as their workspace root, so its
`Sources/` fixtures exercise the same path classifier.

An owner hint comes from the alias's companion source stem or a type extension
declared beside it. The rule accepts an owner only when that type both declares
an initializer parameter and stores a property of the alias type; property
names do not establish ownership. Other types may not declare a sink
initializer/property or forward it into another type. Owner initializers must
take an optional sink with a default of `nil`.

The eager-preparation subset checks named scope factories and computed scope
properties, direct `ScopeType(...)` and qualified `ScopeType.case(...)` /
`ScopeType.init(...)` construction, and `.case(...)` / `.init(...)` when a
scope type is explicit on the local binding or enclosing function return. It
accepts `guard let sink` and `guard let localSink = sink`, matching `if let`
forms, `sink != nil` conditions without disjunction, a sole `if sink == nil`
whose body exits with `return`, `throw`, `continue` or `break` before later
statements, optional sink-call arguments, and an optional sink's `map` closure.
Factory bodies are checked at their call site; factories with a leading sink
guard that exits may prepare internally. `sink != nil || condition` is not a
gate.

This is a syntax subset, not general Swift type or control-flow analysis. It
does not infer `.case(...)` from an argument position alone, derive fact
payload/outcome values through switches, or recursively inspect stored
collections such as `[Scope]`, `Set<Scope>` or maps containing scopes. Those
shapes remain review responsibilities. A zero-diagnostic result does not claim
that Bridge payload derivation or those argument-position scopes are clean.

## Former Shell And Custom SwiftLint Coverage

| Former behavior | Current status | Replacement |
| --- | --- | --- |
| Fail Core importing Features. | Blocking | `agentstudio_import_direction` |
| Fail Core importing App. | Blocking | `agentstudio_import_direction` |
| Fail Features importing sibling Features. | Blocking | `agentstudio_import_direction` |
| Fail SharedComponents importing Core, Features, or App. | Blocking | `agentstudio_import_direction` |
| Fail SharedComponents reading atoms, resolving global stores, or owning atom/store objects. | Blocking | `agentstudio_shared_components_are_stateless` |
| Fail AtomLib importing product layers or referencing product atoms. | Blocking | `agentstudio_atomlib_is_generic` |
| Fail `DerivedAtom` direct `atom(...)`, `CoreAtomScope`, or `CoreAtoms` reads. | Blocking | `agentstudio_derived_atom_declared_inputs` |
| Fail same-file helper/wrapper calls from `DerivedAtom` compute closures when the helper hides an atom read. | Blocking | `agentstudio_derived_atom_declared_inputs` |
| Fail raw `WorktreeEnrichment` equality as an atom comparator. | Blocking | `agentstudio_worktree_enrichment_comparator` |
| Fail hot `repoEnrichmentByRepoId`, `worktreeEnrichmentByWorktreeId`, and `pullRequestFactsByBranch` dictionary reads outside named cold surfaces. | Blocking | `agentstudio_repo_cache_keyed_reads` |
| Fail IPC contract code importing the app, AppKit, SwiftUI, or feature/runtime owners. | Blocking | `agentstudio_ipc_programmatic_control_boundary` and `agentstudio_appipc_port_boundary` |
| Fail IPC composition outside the approved app composition location. | Blocking | `agentstudio_ipc_composition_location` |
| Fail feature slices importing `AgentStudioAppIPC` directly. | Blocking | `agentstudio_features_do_not_import_appipc` |
| Fail public IPC zmx namespace/raw runtime payload leakage. | Blocking | `agentstudio_ipc_public_surface_sanitization` |
| Fail direct atom access from IPC services and adapters. | Blocking | `agentstudio_ipc_no_direct_atom_access` |
| Fail production `Task.sleep(for:)` and generic `.sleep(for:)` outside the approved delay seam. | Blocking | `agentstudio_no_generic_clock_sleep` |
| Fail direct `Task.sleep(...)` calls in test files. | Blocking | `agentstudio_no_task_sleep_in_tests` |
| Fail a loop in a test file whose own condition or body yields, sleeps, or reads a clock, beyond the file's count in the debt ledger. A ledger row whose path is gone, or whose count is above what remains, fails until it is lowered or removed. | Blocking | `agentstudio_no_polling_wait_in_tests` |
| Fail production EventBus subscriptions or wait helpers that omit semantic subscriber policy, use raw buffering policy, or hide a default policy in a wrapper. | Blocking | `agentstudio_eventbus_subscriber_policy_required` |
| Fail Terminal-local Ghostty disposition branches that directly publish or can fall through to the shared exact semantic publication edge. | Blocking | `agentstudio_terminal_local_disposition_publication` |
| Print repo-cache dictionary read inventory. | Reclassified to review-only | The old script's report-only inventory is replaced by this document plus blocking rules for the hot-path violation class. Broad inventory reports were noisy and not a required CI gate. |

## Test And Fixture Proof

| Proof | Covers |
| --- | --- |
| `mise run test:architecture` | Builds the local SwiftPM/SwiftSyntax tool, checks the exact rule inventory and severity map, lints good fixtures, verifies bad fixtures fail with each rule's exact lines, proves every rule is exercised by the fixture corpus, and covers every ledger reconciliation state, the ratchet, and scoped-versus-full parity. |
| `ArchitectureSwiftLintRulesTests` | Verifies AgentStudio's `mise`, CI, stock SwiftLint, local architecture tool, deleted old-runner files, and `no_combine_import` regex custom-rule behavior through stock SwiftLint. |
| `mise run lint` | Runs swift-format, stock SwiftLint, the local AgentStudio architecture linter with the debt ledger, and release script checks. |

## Review-Only Guidance

Some architecture guidance remains review-only because it depends on semantic
judgment rather than a reliable syntax pattern: when to extract a shared
component on second use, whether a coordinator owns domain decisions, and
whether a dictionary-shaped read is an explicitly measured cold exception.
