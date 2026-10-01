# Testing Architecture

This document owns how a test in this repository waits, which lane runs it, what
"done" means for the production components a test awaits, and what to do when a
run comes back red. It is the standard the polling-wait lint gate enforces and
the one `AGENTS.md` routes to.

Source of the requirements behind it:
[CI Reliability — Specification](../../specs/2026-09-17-ci-reliability/2026-09-17-ci-reliability.md).

## The one rule

**A test's verdict is a function of program logic, never of machine speed. The
only elapsed-time bound a test may have is the runner-owned hang bound, and it
is never raised to make a test pass.**

Two weeks of red CI came from ignoring that. The tests were not wrong about the
product; they were wrong about the machine. Here is the machine:

| | A developer Mac (the one this was diagnosed on) | GitHub runner (`macos-26`) |
| --- | --- | --- |
| CPU count | 16 | 3 |
| Swift cooperative-pool threads | one per core: 16 | one per core: 3 |
| Test lane entry point | `mise run test` → [`scripts/run-swift-test-task.sh`](../../../scripts/run-swift-test-task.sh) | the same `mise run test:swift:*` tasks ([`ci.yml`](../../../.github/workflows/ci.yml)) |
| In-process case concurrency | unbounded | unbounded |
| Isolated suite processes at once | `min(ncpu, 4)` = 4 | `min(ncpu, 4)` = 3 |
| `SWIFT_TEST_TIMEOUT_SECONDS` | 600 | 600 |
| Serialized E2E lane | runs (`SWIFT_TEST_INCLUDE_E2E=1`) | not yet; spec R17, PR 2 |

The cooperative pool is the whole story. A test that parks a pool thread — on
process exit, a semaphore, a socket read — removes one of three threads from a
runner that has three. Three such tests at once deadlocked the entire fast lane
with no failure message, only a ten-minute silence. A test that polls with a
"200 turns or 10 seconds" budget gets its turns instantly here and starves
there, because the work it is waiting for is queued behind the loop that is
waiting for it.

So: **a green local run is evidence that the logic works on as many threads as
your Mac has. It is not evidence that CI will pass on three.** The lane reports are how you tell the
difference; see [When a run is red](#when-a-run-is-red).

The concurrency width is opt-in with no default, deliberately. Setting
`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH` made the fast lane hang
intermittently at every width tried — 15 of 28 local runs blocked at widths 3,
8, 16, 17, 64 and 256. Until that is understood the width stays unset; see
[`swift-test-helpers.sh:17-45`](../../../scripts/swift-test-helpers.sh).

## Pyramid as applied here

| Layer | What it proves | Where it lives here |
| --- | --- | --- |
| Unit | Focused logic and state transitions in isolation | The paired module test targets: `AgentStudioInfrastructureTests`, `AgentStudioSharedComponentsTests`, `AgentStudioCoreTests`, `AgentStudio<Feature>Tests` |
| Integration | Real interactions across components, storage, process, filesystem, or protocol boundaries | Paired targets for real boundaries (`AgentStudioAppIPCTests`, `AgentStudioIPCTransportTests`, `AgentStudioBridgeDevelopmentServerTests`) and the executable target for cross-Feature composition |
| E2E | A complete journey through the real system from its entry point | `E2ESerializedTests` and `ZmxE2ETests` inside `AgentStudioTests` |
| Smoke | The runnable system starts and performs essential behavior | Packaged and observability proof; see [Observability — Proof Model](../observability/observability_and_traceability.md#proof-model) |

Machine-speed assertions — "p95 under N milliseconds", "this completed in under
a second" — are never a pull-request gate. They belong to the observability
proof lane, where a marker-scoped probe measures a running app against real
telemetry. A timing assertion inside a unit or integration test is a correctness
budget wearing a performance costume, and it fails on a three-core runner for
reasons that have nothing to do with the change under test.

## Test target ownership

Product modules have paired SwiftPM test targets:

```text
AgentStudioInfrastructureTests     ──► AgentStudioInfrastructure
AgentStudioSharedComponentsTests   ──► AgentStudioSharedComponents
AgentStudioCoreTests               ──► AgentStudioCore + AgentStudioTestSupport
AgentStudio<Feature>Tests          ──► matching Feature + lower modules
AgentStudioTests                   ──► AgentStudio executable + product modules
AgentStudioTestHarnessTests        ──► AgentStudioTestHarness
```

`AgentStudioTestHarness` depends only on the standard library, Foundation and
`Synchronization`. Its sources live at
[`Tests/AgentStudioTestHarness`](../../../Tests/AgentStudioTestHarness) and its
declarations are `package`. It owns the primitives every test target shares —
`HeldStep`, `proveReplyDependsOnStep` and `valueFromDedicatedThread` (see
[How a test may wait](#how-a-test-may-wait)) — so a target that cannot see
`AgentStudioTestSupport` depends on the harness instead of copying a gate.
`AgentStudioTestSupport` depends on it too. Its self-tests live in
[`Tests/AgentStudioTestHarnessTests`](../../../Tests/AgentStudioTestHarnessTests).

`AgentStudioTestSupport` depends on `AgentStudioCore` and `AgentStudioTestHarness`. Its sources live at
[`Tests/AgentStudioTests/TestSupport`](../../../Tests/AgentStudioTests/TestSupport) (a nested path under the executable test
folder, a separate SwiftPM target). It provides Core-level fixtures and helpers
without becoming an App or Feature registry. Infrastructure and SharedComponents
tests do not depend on it. Each paired test target owns unit and module-boundary
tests for its product module.

Additional paired targets cover non-Feature modules:
`AgentStudioBridgeDevelopmentServerTests`, `AgentStudioIPCTransportTests`,
`AgentStudioProgrammaticControlTests`, `AgentStudioAppIPCTests`, and
`AgentStudioIPCClientTests`.

The executable-level `AgentStudioTests` target owns App composition,
cross-Feature integration, executable resources, WebKit integration, zmx
integration, and packaged/runtime proof that cannot be expressed by a lower
module test. This ownership does not replace the existing execution lanes:
`mise run test:swift:fast`, `mise run test:swift:large`,
`mise run test:swift:webkit`, `mise run test:swift:e2e`, and
`mise run test:swift:zmx-e2e` retain their filter, serialization, prebuild,
and timeout semantics. `swift test --filter` selects tests to execute; it
does not redefine module ownership or guarantee that unrelated same-package test
products avoid compilation.

## Lanes and why they are split

One owner: the `mise run test:*` tasks and
[`scripts/run-swift-test-task.sh`](../../../scripts/run-swift-test-task.sh),
which dispatches on a mode and sources
[`scripts/swift-test-helpers.sh`](../../../scripts/swift-test-helpers.sh). CI
calls those same mise tasks; it never recreates a raw `swift test` command.
Pull requests and the nightly run execute every lane below; a push to main runs
only `test:swift:prebuild` and the seed publication (owner decision 2026-09-30).

```text
   mise run test                          CI (.github/workflows/ci.yml)
   ─────────────                          ────────────────────────────
   lint, test:architecture,               test:swift:prebuild
   bridge-web, web, vendors                       │
        │                                         ├─► test:swift:fast
   SWIFT_TEST_INCLUDE_E2E=1                       ├─► test:swift:large
   test:swift ──┬─► fast lane                     └─► test:swift:webkit
                ├─► large lane
                ├─► WebKit lane                   (no E2E lane yet — spec R17,
                └─► E2E serialized                 PR 2)
   git diff --check
```

| Lane | Task | What it holds |
| --- | --- | --- |
| fast | `test:swift:fast` | Everything not claimed by another lane, run concurrently inside one process by Swift Testing itself, then the isolated process-global phases |
| large | `test:swift:large` | Exact suite type paths in `swift_test_suite_lane_inventory` marked `large`: concurrent rows run in the parallel phase, serial rows run in the serial phase, and process-global rows run in isolated processes |
| WebKit | `test:swift:webkit` | Real WKWebView runtime suites, one filter at a time. A teardown signal crash fails the lane and the receipt names the suite and signal; the runner never retries |
| width comparison | `test:swift:width-comparison` | One prebuild, then the fast lane at width 3 and with the width unset on that same bundle. Each half prints its own receipt as a `reused` bundle linked to that prebuild's build receipt and keeps every ledger under `tmp/plan-workflows/ci-runs/width-comparison/`. It is an experiment, not a pull-request gate, and it never changes the default width |
| E2E | `test:swift:e2e` | `E2ESerializedTests`; inside `mise run test` only when `SWIFT_TEST_INCLUDE_E2E=1` |
| zmx E2E | `test:swift:zmx-e2e` | `ZmxE2ETests`; opt-in, not a pull-request gate |
| benchmark | `test:swift:benchmark` | The two benchmark suites; nightly on main, not a pull-request gate |

**Why process-global suites get a process each.** `@Suite(.serialized)`
serializes tests *within one suite*. It does not isolate that suite from the
other suites sharing the process. A suite that touches AppKit, a MainActor
singleton, a shared datastore, or a long-lived bus therefore needs a process of
its own. The inventory comes from two sources unioned in
`aggregate_serial_non_webkit_suite_filters`: a scan for types annotated with
both `@MainActor` and `@Suite(..., .serialized)`, and an explicit list of
`path:Suite` pairs for suites the annotation cannot express (long-lived actors,
live-socket IPC suites). The runner executes one suite per process, at most
`min(ncpu, 4)` at once, against the already-built test bundle through
`swiftpm-testing-helper` — which avoids SwiftPM's shared build-path lock.

**Why SwiftPM `--parallel` is not a substitute.** `--parallel` and
`--num-workers` govern XCTest process fan-out. Xcode 26.3 still runs Swift
Testing through one helper process, so neither flag isolates a Swift Testing
suite. Do not add `--parallel` to the fast inventory; the concurrency there is
Swift Testing's own.

**Why filters are anchored.** Swift Testing matches `--filter` as a regex with
`contains` over a test's id, and a *function's* id ends with its source
location. A bare `RepoScannerTests` therefore also selects
`RepoScannerClassificationTests/gitDirectoryIsCloneRoot()/RepoScannerTests.swift:430:6`
— a different suite that merely lives in a file named after the first. That is
how two process-global suites ended up sharing one process and SIGSEGVing at
exit. `swift_test_isolated_suite_filter_pattern` anchors the type component as
`\.<Type>(/|$)`, so only the type matches.

## How a test may wait

These are the permitted forms. Anything not in the left column is a poll.

| Situation | Permitted form | Forbidden |
| --- | --- | --- |
| State changes and is observable | Await the observed change until a predicate holds | Re-reading the value in a loop |
| A component or test double knows when something happened | Await its event or completion signal | Polling a counter it keeps |
| A test double must hold work at one point | A `HeldStep`: await `firstArrival()`, then `release()`, `fail(_:)` or `retire()` | A hand-rolled gate type, a flag read in a loop |
| A reply must depend on a held dependency's outcome | `proveReplyDependsOnStep` (fail branch and release branch) | "Not replied yet" asserted after a delay |
| Delivery on a stream or the bus | Attach a `FactRecorder` ([Typed facts](#typed-facts)) before the stimulus, then `expectNext` the specific fact in its scope | Polling subscriber counts or received arrays; `firstEvent(where:)` over history |
| Work finishes but announces nothing | The owner emits a closing fact for the operation; `expectNext` it ([Typed facts](#typed-facts)) | Yield-and-hope; `waitUntilIdle` in a test |
| Something must not happen | `expectNone` from an opening position marked before the stimulus, until the operation's correlated closing fact | "Did not happen in N turns/seconds"; asserting after idle |
| Time is the behavior | Advance a controlled clock, then `expectNext` the owner's deadline disposition | Waiting in real time |
| None of the above fits | The production owner is missing a signal; add it | Any poll |

**No correctness budgets.** A test must not decide pass or fail by an
elapsed-time budget, a poll count, or a scheduler-turn count. A wait must
complete because a named event, an owner's typed fact, or an observed state
change occurred. Idle or quiescence is never a test wait; it is a production
lifecycle contract ([Quiescence](#quiescence)). The test for whether a wait is a budget: *can
it expire while the awaited work is correct and still in flight?* If yes, it is
a budget.

**Holding work: `HeldStep`.** A test double that stands in for a dependency
holds the work under test with a named
[`HeldStep`](../../../Tests/AgentStudioTestHarness/HeldStep.swift). The double
calls `arrive(_:)` at the point it replaces; the test awaits `firstArrival()`,
which completes because the work got there and returns what arrived, then ends
the step. The first of `release()`, `fail(_:)` and `retire()` wins and is sticky,
and one made before any arrival is kept. A cancelled arrival resumes as
cancelled by default; `.holdThroughCancellation` keeps it held, the way a
dependency that ignores cancellation behaves, and `cancellationObserved()` is the
event to await. A synchronous seam reached from a thread that may block (a
socket accept queue, a thread from `valueFromDedicatedThread`) uses
`arriveBlocking(_:)`; called from inside a task it parks nothing and fails naming
the step. No harness wait has a deadline: a step that is never reached leaves the
test waiting for the hang bound, whose cancellation makes the wait throw
`HeldStepNeverReached` with the step's name. A lane's own hang bound kills the
process instead of cancelling the task, so when `AGENTSTUDIO_HELD_STEP_LOG` names a
file every step appends `waiting` and `arrived` lines there
([`HeldStepEventLog.swift`](../../../Tests/AgentStudioTestHarness/HeldStepEventLog.swift)),
and a step with a wait and no arrival is the one never reached. Do not add a new
gate type; the existing ones are frozen by the lint baseline and move onto
`HeldStep`.

**Causal replies: `proveReplyDependsOnStep`.** Where a boundary's held
dependency can report failure through its own contract, prove that the reply
comes from the effect rather than from starting it: the helper builds a fresh
scenario twice, fails the step in one and releases it in the other, and requires
the reply to report failure and success respectively. A reply produced before the
step finishes cannot depend on it, so an early reply fails the test with no clock
and no quiescence wait. The helper never invents an error the boundary does not
have.

**One hang bound, never tuned.** The only elapsed-time bound permitted in a test
is the runner-owned hang bound: the framework's time limit on the test, and the
lane's own bound against a hung process. If a hang bound expires, the failure
must identify what was being awaited — a `.timeLimit` trait is a hang bound only
when its failure names the thing that never arrived; otherwise it is a budget
with a friendlier name. A hang bound is never raised to make a correct but slow
test pass. A test that needs a larger bound is telling you it violates the
concurrency, waiting, or blocking rule, not that the bound is wrong.
A subprocess runs to exit through `runProcessToExit` or `runCommandToExit`
([`RunToExitProcess.swift`](../../../Tests/AgentStudioTests/TestSupport/RunToExitProcess.swift)),
never under a per-call timeout. The `agentstudio_no_test_elapsed_time_budget` lint
rule fails a `DefaultProcessExecutor` construction, a semaphore or group
`wait(timeout:)`, an `asyncAfter`, or a timed `waitForFile` in a test outside its
named owners.

**Time as subject uses a controlled clock.** Where the behavior under test
depends on time — debounce, cadence, backoff, retention — the test drives that
time through a clock it controls and never waits in real time. Use
[`TestPushClock`](../../../Tests/AgentStudioTests/TestSupport/TestPushClock.swift).
If the component reads more than one clock, every clock that can affect the
asserted outcome must be controllable by the test; injecting one clock and
leaving a second real one inside the component is a diagnosed failure family, not
a detail.

**Proving a negative.** To show something does not happen, mark an opening
position before the stimulus and consume, with `expectNone`, every fact in that
operation's scope up to the operation's correlated closing fact. The closing fact
is emitted only after every accepted effect of the operation has settled, so the
claim covers exactly that operation. "It did not happen during a budget" is not
"it does not happen", and neither is "it did not happen before the owner went
idle": tests never wait for idle (owner decision 2026-09-28).

**No blocking on the cooperative pool.** Test code, and production code
reachable from tests, must not block a cooperative-pool thread on process exit,
a semaphore, a lock held across long work, or synchronous I/O. On three cores
there are three threads; the in-process IPC server answers every accepted
connection from a `Task` on that same pool, so a test blocking there is starving
the server it is waiting on. Route the block through
[`valueFromDedicatedThread`](../../../Tests/AgentStudioTestHarness/DedicatedThreadWork.swift),
which lands it on a thread of its own, or through
[`withoutBlockingCooperativePool`](../../../Tests/AgentStudioTests/TestSupport/BlockingWorkOffCooperativePool.swift),
which delegates to it. `@concurrent` is not a substitute — it still
draws from the cooperative pool. The
`agentstudio_test_blocking_wait_off_cooperative_pool` lint rule enforces this.

## Typed facts

Async tests observe typed facts that owners emit at each step, in order, and a
fact that doesn't arrive is a failure. The contract is the
[typed-fact test harness specification](../../specs/2026-09-28-typed-fact-test-harness/2026-09-28-typed-fact-test-harness.md).
In short:

- An owner emits facts from its own `Hashable & Sendable` scope and fact types
  through an injected synchronous sink, at the transition's serialization point.
  Internal steps stay owner-local; only real runtime facts go on the `EventBus`.
- A test creates a `LocalFactSource` (or an `EventBusFactSource`) before the
  owner, attaches a `FactRecorder` before the stimulus, and consumes facts per
  scope with `expectNext` and `expectNone`. An unexpected fact, a lost fact, an
  early end or a close from the wrong operation fails at once.
- Every operation has a closing fact per terminal disposition (completed,
  no-op, rejected, superseded, cancelled, shut down). A deadline's disposition
  closes that evaluation, not the work it admitted.
- A hung expectation is named in the lane's timeout report, next to unarrived
  `HeldStep`s.
- `waitUntilIdle`, `assertEventuallyAsync` and `assertEventuallyMain` are
  forbidden in tests (`agentstudio_no_forbidden_test_wait`); remaining uses are
  debt in `Tools/AgentStudioArchitectureLint/forbidden-test-wait-ledger.tsv`,
  which only goes down.

<a id="quiescence"></a>

## Quiescence (production contracts, not a test wait)

Some production owners expose quiescence for their own shutdown and drain. Tests
do not await it; they observe the owner's closing facts instead. The rules below
describe what such a production contract must guarantee.

Awaiting quiescence on a component completes only when every unit of work the
component accepted before the await began has finished and been handed to the
next stage, including work buffered for coalescing, debounce, or a later tick.

- **Applied, not delivered.** When quiescence is reported, every effect of that
  work is visible in the state the component publishes. "The consumer has been
  handed the item" is not quiescence.
- **Work accepted during the await.** Quiescence must not complete while such
  work is unfinished if it was caused by the work being awaited. Whether
  unrelated new work extends the await is left to each owner and documented by
  it.
- **Pipelines.** Quiescence of a pipeline holds only when all of its stages are
  quiescent at the same time; a stage finishing can hand work to a stage that
  was already quiescent.
- **Held work versus a standing schedule.** Work already accepted and merely
  held for a coalescing, debounce, or tick window is unfinished work: the
  component is not quiescent. A standing schedule that will generate work in the
  future (a periodic refresh waiting on its next deadline) is not accepted work
  and does not prevent quiescence.
- **Clocks.** A component whose held work is released by a clock makes that
  clock controllable by the test; the test advances it and consumes the owner's
  deadline disposition fact.
- **Dropped delivery.** Quiescence covers work a component accepted. An envelope
  that a bounded, lossy subscription discarded was never accepted, so quiescence
  says nothing about it. A test whose outcome depends on delivery across such a
  subscription asserts that the subscription dropped nothing.
- **Shutdown and cancellation.** If the component shuts down, pending awaits
  complete rather than hang. If the awaiting task is cancelled, the await ends
  promptly and leaves no stored waiter behind.
- **Cost.** With no one awaiting, quiescence adds no work to the hot path beyond
  bookkeeping the component already does.
- **Not promised.** That no future work will arrive; ordering across independent
  pipelines; a whole-application idle signal; any exposure over IPC; suitability
  for measuring performance.

### What exists today

These are production contracts, usable by shutdown, not test-only hooks.

| Seam | What "done" means for that owner |
| --- | --- |
| [`RemoteReferenceRefreshActor+ExplicitUpdates.swift:14`](../../../Sources/AgentStudio/Core/RuntimeEventSystem/Git/RemoteReferenceRefreshActor+ExplicitUpdates.swift) `waitUntilIdle()` | No outstanding physical remote-reference work remains; returns immediately when there was none |
| [`RepositoryFactDemandCoordinator.swift:219`](../../../Sources/AgentStudio/App/Coordination/RepositoryFactDemandCoordinator.swift) `waitUntilIdle()` | No delivery task is in flight; with none, it flushes its performance snapshot and returns |
| [`BridgeProductSchemeSessionRouter.swift:116`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeSessionRouter.swift) `waitForDrain()` | Every transport claim is gone — zero residue in the router's snapshot |
| [`BridgeProductSchemeSessionRouter.swift:128`](../../../Sources/AgentStudio/Features/Bridge/Transport/BridgeProductSchemeSessionRouter.swift) `waitForStreamClaimDrain()` | Only the metadata-stream claims are gone; deliberately narrower, because a command or content claim can legitimately outlive a stream. Cancellation-safe and lost-wakeup-free |
| [`RepositoryFactUpdateProgress.swift:69`](../../../Sources/AgentStudio/Core/Models/RepositoryFactUpdateProgress.swift) `settled(_:)` | Every applicable fact source has a terminal result; the progress value moves to `.settled` with no unsettled sources |

### Withdrawn

The planned composed `QuiescenceAwaiting` protocol and `awaitQuiescence(of:)`
helper are withdrawn: tests don't wait for idle. A test that needs to know an
owner finished consumes that owner's closing fact.

## Harness catalog

[`Tests/AgentStudioTestHarness/`](../../../Tests/AgentStudioTestHarness), the Core-free `AgentStudioTestHarness`
target that every test target may depend on:

| Harness | What it fakes or controls | The wait it enables |
| --- | --- | --- |
| `HeldStep.swift` | One named point where a test double holds the work under test | `firstArrival()` returns what arrived; `cancellationObserved()` for hold-through-cancellation interleavings; no deadlines |
| `ReplyDependsOnStepProof.swift` | Two fresh scenarios, one failed and one released at the held step | `proveReplyDependsOnStep` rejects a reply that does not depend on the step's outcome |
| `DedicatedThreadWork.swift` | Nothing; it runs blocking work on a thread of its own | `valueFromDedicatedThread` returns the blocking work's value without parking a cooperative thread |
| `FactRecording/` (`LocalFactSource`, `FactRecorder`, `FactVocabulary`) | An owner's typed fact stream, attached before the stimulus | `expectNext` / `expectNone` per scope; loss, end and cancellation fail distinctly; hung expectations named in the lane report |

Everything in [`Tests/AgentStudioTests/TestSupport/`](../../../Tests/AgentStudioTests/TestSupport), the `AgentStudioTestSupport` target.

| Harness | What it fakes or controls | The wait it enables |
| --- | --- | --- |
| `BlockingWorkOffCooperativePool.swift` | Nothing; it delegates to the harness's `valueFromDedicatedThread` | Lets a test wait on process exit, a semaphore, or a socket read without parking a cooperative thread |
| `RunToExitProcess.swift` | Nothing; it runs a real subprocess with both streams in files | `runProcessToExit` and `runCommandToExit` suspend until `terminationHandler` reports the exit — no timeout, no parked thread. `RunToExitProcessExecutor` adapts them to `ProcessExecutor` in the AgentStudioTests target |
| `TestPushClock.swift` | A `Clock` the test advances by hand | Time as subject: advance, then `expectNext` the owner's deadline disposition. Never real time |
| `EventBusFactSource.swift` | A lossless (critical-unbounded) subscription on a real `EventBus`, awaited before attach returns | Feeds a `FactRecorder`; a drop or truncated replay reports loss |
| `EventBusHarness.swift` | A real `EventBus` with a recording subscriber and an actor-backed buffer | Legacy: its default subscription is lossy and `firstEvent(where:)` searches history. New tests use `EventBusFactSource` |
| `RuntimeEnvelopeHarness.swift` | Typed envelope records for system, worktree, and pane scopes | Assert on the exact fact that was posted |
| `ControllableFSEventStreamClient.swift` | The FSEvents stream client | Tests inject batches explicitly and read registrations, overflow recovery, and activity fences — no OS callback, no waiting for one |
| `PaneRuntimeProviderStubs.swift` | Git working-tree status providers, pathspec-aware or not | The stub's handler is the completion signal |
| `WorkspaceStoreTestAccess.swift` | A `WorkspaceStore` built from explicitly supplied atom owners, including an injected clock and debounce duration | Drives persistence debounce through the injected clock |
| `TestAtomRegistry.swift` | The ambient `CoreAtomScope` for tests | Deterministic Core atom installation; no shared-scope leakage between suites |
| `PaneArrangementStateTestAdapters.swift` | Convenience `Tab` initializers over arrangements | Construction, not waiting |
| `MockTab.swift` | A `ResolvableTab` of pure UUIDs, no NSViews | Construction, not waiting |
| `ModelFactories.swift` | `Worktree`, `Repo`, and peer fixtures | Construction, not waiting |
| `RepoCachePullRequestFactsTestSupport.swift` | Keyed reads and writes of pull-request facts on `RepoCacheAtom` | Construction, not waiting |
| `FilesystemTestGitRepo.swift` | A real on-disk git repository with seeded changes | Real filesystem and git boundary for integration tests |
| `TestPathResolver.swift` | Project-root resolution from `#filePath` | Construction, not waiting |
| `TestResourceInputs.swift` | Resource and BridgeWeb app root URLs | Construction, not waiting |

### Legacy polling helpers — do not add call sites

These exist, they are counted in the architecture debt ledger, and they are
being converted under PR 2. Do not call them from new code.

| Helper | Why it is a poll |
| --- | --- |
| `assertEventuallyAsync` ([`EventBusHarness.swift:150`](../../../Tests/AgentStudioTests/TestSupport/EventBusHarness.swift)) | A loop around `Task.yield()` governed by both a `minimumTurns` count and a wall-clock `timeout`. Both are correctness budgets; having two does not make either one a signal |
| `assertEventuallyMain` ([`EventBusHarness.swift:173`](../../../Tests/AgentStudioTests/TestSupport/EventBusHarness.swift)) | The same dual budget for a `@MainActor` condition |
| Per-file `eventually(...)` | Local re-implementations of the same shape |
| `waitUntil(iterations:)` ([`PaneTabViewControllerLaunchRestoreTests.swift:403`](../../../Tests/AgentStudioTests/App/PaneTabViewControllerLaunchRestoreTests.swift)) | A turn budget with the budget in the signature |
| `.timeLimit(...)` used as a budget | A hang bound only when its failure names what was awaited; otherwise a per-test correctness budget |

A `waitUntilStarted()` or `waitUntilReleased()` on a harness is usually **not** a
poll — those are continuation gates resumed by an event. Read the
implementation before classifying a wait by its name; that is also why the lint
rule matches shape and never names.

## Process-global state and isolation

A suite shares process-global state when it touches AppKit, a MainActor
singleton, a shared datastore, or a long-lived bus. Mark it with both
attributes, in either order:

```swift
@MainActor
@Suite("Repo explorer projection", .serialized)
struct RepoExplorerProjectionTests { }
```

`aggregate_serial_non_webkit_suite_filters` discovers that pair and gives the
suite a process of its own. Suites the annotation cannot express — long-lived
actors, live-socket IPC suites — are listed explicitly as `path:Suite` pairs in
the same function.

That explicit half is hand-kept, and a hand-kept list that test correctness
depends on needs a gate, or a member falls out of it silently. The gate is
[`SwiftLaneIsolationListGateTests`](../../../Tests/AgentStudioTests/Scripts/SwiftLaneIsolationListGateTests.swift):
it checks every hand-kept `path:Suite` entry still names a real declaration, and
it re-discovers the annotated suites independently of the shell script's own
patterns, asserting each one lands in some isolated lane. Writing that gate
against the script's output instead would have proved only that the script
agrees with itself.

The lane `--filter` and `--skip` patterns are anchored to the type; see
[Why filters are anchored](#lanes-and-why-they-are-split).

## When a run is red

**A red run is diagnosed, never rerun.** The point of this whole standard is
that a failure means something. Re-running throws away the evidence and the
signal.

1. **Read the lane report.** Every lane prints `[<lane>] lane-report <label>=…`
   before and after its tests: `cpu_count`, `memory_bytes`,
   `parallelization_width`, `isolated_process_concurrency`, `head_sha`,
   `tree_dirty`, then `exit_status`, `wall_seconds`, `cpu_seconds`,
   `cpu_utilization`, `peak_announced_tests`, `peak_running_parameterized_cases`,
   `failed_isolated_suites`, one `failed_isolated_suite=` line per failure, and
   the receipt identity: `head_sha`, `tree_dirty`, `bundle_state`,
   `bundle_identity`, `receipt_valid`, `verdict`. Low utilization with long wall
   time is blocking; high utilization is saturation. `peak_announced_tests` counts
   tests whose start event was *posted*, which is an announcement, not a running
   test, and does not reflect any cap; `peak_running_parameterized_cases` does,
   over the parameterized subset only.

   **A receipt is evidence only when it is valid.** A lane is valid when its
   bundle is a clean build of this commit and the tree stayed clean from the
   opening to the closing receipt. A lane that ran its own prebuild has
   `bundle_state=fresh`. A lane that reused a bundle (`SWIFT_TEST_SKIP_PREBUILD=1`,
   as every CI lane after the prebuild step) has `bundle_state=reused` and is
   linked to the build receipt the prebuild published beside the bundle
   (`<build path>/agentstudio-test-build-receipt`). The prebuild deletes that
   receipt before compiling, samples `head_sha` and `tree_dirty` before
   compiling, and publishes the receipt by atomic rename only after the build
   succeeds. `bundle_identity` is the exact test executable: path, size and
   modification time. The lane prints the receipt's commit as
   `build_receipt_head_sha`. Otherwise the receipt reads
   `receipt_valid=false reason=…`, where the reason is one of:
   - `reused_bundle_unlinked`: no receipt, a malformed one, or one naming
     another executable;
   - `built_from_dirty_tree`: the build tree had uncommitted changes;
   - `bundle_head_mismatch`: the receipt names another commit;
   - `dirty_tree`: uncommitted changes now;
   - `unbuilt_bundle`: the prebuild failed.

   An invalid receipt's verdict is `unverified` whatever the exit status. The
   exit status itself is unchanged, so the local edit-test loop still works. A
   lane ended by a signal exits 128+signal and reports `verdict=fail`.
2. **Download the ledger.** On a lane timeout the runner preserves Swift
   Testing's event-stream JSONL under `tmp/plan-workflows/ci-runs/lane-*.events.jsonl`,
   and CI uploads it as `swift-lane-event-streams-<run_id>`. Compute
   started-without-ended per `payload.testID` from the `testStarted`/`testEnded`
   and `testCaseStarted`/`testCaseEnded` records. That ledger is the
   authoritative account of what was in flight. **The console's "unfinished"
   counts lie** — stdio is block-buffered and stops mid-line at a wedge.
3. **Check for signal deaths.** A test process can die of a signal after its
   last flushed line, so the job log shows a passing run and then nothing. CI
   uploads `swift-crash-reports-<run_id>`; traps raised by libdispatch and
   `os_unfair_lock` report through os_log, so the `.ips` "Application Specific
   Information" field is the only place their reason survives.
4. **Reproduce locally with a short hang bound.**
   `SWIFT_TEST_TIMEOUT_SECONDS=90 mise run test:swift:fast`. When a helper is
   parked, `xcrun swift-inspect dump-concurrency <pid>` lists every parked task
   with its resume function. It is unprivileged, and it is the only tool that
   shows suspended tasks — `sample` cannot. When the hang bound fires, the runner
   gathers the evidence itself before anything is terminated, and keeps it
   beside the ledger under one stem, `lane-<label>-<time>-<pid>`. CI uploads
   all three with the ledgers:
   - `…-pid<pid>.task-dump.txt`: one task dump per stuck test process, taken
     whether or not the thread sampler (`sample`) is available. Each tool that
     cannot run says why: `stack_sample=unavailable reason=…` and
     `task_dump=unavailable reason=…`. It cannot attach to a binary without
     `get-task-allow`, and `swift-inspect` exits 0 even then, which is why the
     runner judges success by the dump's content.
   - `….held-steps.log`: the lane hands each test process this path as
     `AGENTSTUDIO_HELD_STEP_LOG`. The causal-test harness appends one
     TAB-separated line per event, because step names contain spaces:
     `waiting<TAB><instance id><TAB><name><TAB><fileID function>` and
     `arrived<TAB><instance id><TAB><name>`. Waits and arrivals pair by instance
     id, so one step's arrival cannot hide another same-named step's missing
     one. The hang report prints every wait that never arrived as
     `held_step_unarrived name=<name> id=<id> test=<fileID function>`.
   - `….events.jsonl`: the event ledger itself.

   The hang verdict is failed whatever evidence was gathered.
5. **Classify the owner, then fix it there.** Test oracle (the assertion is
   wrong about what should happen), product (the behavior is wrong), runner
   (the lane, filter, or isolation is wrong), or harness (the fake is wrong).
   Fixing the wrong owner is how a family comes back.

**Forbidden responses to a red run:** rerunning the job; raising a budget or a
hang bound; skipping the test; quarantining it; bumping a `.timeLimit`; removing
an assertion without a replacement that states the invariant at least as
strongly.

**A red lint or ratchet step is diagnosed the same way.** A guardrail diagnostic
names its rule and site; fix the site. A file over its count in the
[debt ledger](../../../Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv)
reports every site in that file with both counts — the new site is the fix, not
the row. A file under its count, or a row whose file is gone, names the row to
lower or remove (`--lower-ledger-counts` does exactly that, and nothing more).
The `Debt ledger ratchet` CI step fails when a pull request raises a row or adds
one compared with the merge base; raising a count is never the response. The
lint prints per-stage and per-rule timings on every run; a slow rule is a defect
to fix, and no timing changes the verdict.

## Workarounds and hand-kept lists

A version pin or a note that exists for a workaround must state the condition
under which it is removed, and must be removed once that condition is met.

A hand-maintained list that test correctness depends on — the set of suites that
need process isolation, the lint debt — must be verified by a gate, so that
a member cannot silently fall out. The isolation list has
[`SwiftLaneIsolationListGateTests`](../../../Tests/AgentStudioTests/Scripts/SwiftLaneIsolationListGateTests.swift).
Lint debt — polling waits, blocking waits, ad-hoc gates, void wait helpers and
the MainActor shapes — lives in one file,
[`architecture-debt-ledger.tsv`](../../../Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv),
as a permitted site count per rule and file. Every lint run requires each file
to hold exactly its count, so the ledger always states the real debt; the CI
ratchet rejects a raised count or a new row. The ledger and the ratchet are
described in the
[architecture lint inventory](../structure/architecture_lint_inventory.md#debt-ledger).

## BridgeWeb

**Cold start is outside the measured window.** A BridgeWeb E2E journey's bounded
steps must not include Vite dependency-optimizer cold start, and a retry must not
repeat a cost that made the first attempt fail. Each live Vite server still owns
its own cache directory; sharing one is how two servers optimize over each
other's dependencies.

**Waits are condition-driven and declared.** A BridgeWeb wait completes because
an application event or a DOM condition occurred. Its time bound is a hang
bound: `testTimeout` is declared once in shared configuration, never left to an
undeclared library default, and never tuned per test to obtain a pass. An awaited
animation is driven to completion by the test or has its cancellation handled;
it is never awaited unbounded or uncaught.

See [`BridgeWeb/AGENTS.md` — Test Waits](../../../BridgeWeb/AGENTS.md#test-waits).

## Key files

| File | Role |
| --- | --- |
| [`scripts/run-swift-test-task.sh`](../../../scripts/run-swift-test-task.sh) | Lane entry point: mode dispatch, hang-bound defaults, lane report |
| [`scripts/swift-test-helpers.sh`](../../../scripts/swift-test-helpers.sh) | Lane inventories, isolation discovery, anchored filters, watchdog, timeout diagnostics |
| [`.mise.toml`](../../../.mise.toml) | `test`, `test:swift*`, `test:architecture` task definitions |
| [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) | The CI steps that call those same mise tasks, and the failure artifacts |
| [`TestPollingWaitRule.swift`](../../../Tools/AgentStudioArchitectureLint/Sources/AgentStudioArchitectureLintCore/Rules/TestPollingWaitRule.swift) | `agentstudio_no_polling_wait_in_tests` |
| [`TestBlockingWaitOffCooperativePoolRule.swift`](../../../Tools/AgentStudioArchitectureLint/Sources/AgentStudioArchitectureLintCore/Rules/TestBlockingWaitOffCooperativePoolRule.swift) | `agentstudio_test_blocking_wait_off_cooperative_pool` |
| [`TestTaskSleepRule.swift`](../../../Tools/AgentStudioArchitectureLint/Sources/AgentStudioArchitectureLintCore/Rules/TestTaskSleepRule.swift) | `agentstudio_no_task_sleep_in_tests` |
| [`TestElapsedTimeBudgetRule.swift`](../../../Tools/AgentStudioArchitectureLint/Sources/AgentStudioArchitectureLintCore/Rules/TestElapsedTimeBudgetRule.swift) | `agentstudio_no_test_elapsed_time_budget` |
| [`architecture-debt-ledger.tsv`](../../../Tools/AgentStudioArchitectureLint/architecture-debt-ledger.tsv) | Permitted site counts per lint rule and file; only ever lowered |
| [`check-ledger-ratchet.sh`](../../../Tools/AgentStudioArchitectureLint/check-ledger-ratchet.sh) | The CI step that rejects a raised count or a new ledger row against the merge base |
| [`ArchitectureAllowlists.swift`](../../../Tools/AgentStudioArchitectureLint/Sources/AgentStudioArchitectureLintCore/Paths/ArchitectureAllowlists.swift) | Named owners of blocking waits and other allowed sites (ownership, not debt) |
| [`Tests/AgentStudioTests/TestSupport/`](../../../Tests/AgentStudioTests/TestSupport) | The `AgentStudioTestSupport` harnesses |
| [`SwiftLaneIsolationListGateTests.swift`](../../../Tests/AgentStudioTests/Scripts/SwiftLaneIsolationListGateTests.swift) | The isolation-list gate |
| [CI Reliability — Specification](../../specs/2026-09-17-ci-reliability/2026-09-17-ci-reliability.md) | The requirements this document implements |
