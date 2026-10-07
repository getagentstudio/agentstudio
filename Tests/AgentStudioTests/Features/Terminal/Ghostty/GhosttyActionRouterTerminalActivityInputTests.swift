import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioTerminal

/// SR6b (Program Design item 13, "Arming"). The isolated-instance tests
/// prove `GhosttyTerminalActivityInputBinding`'s wait-then-bind mechanic
/// without touching the shared global singleton other test files already
/// bind/unbind against; the `.serialized` suite below proves
/// `Ghostty.ActionRouter.armRestorePhase`'s integration with that real
/// singleton in its already-bound state (the path production code takes in
/// every real launch, since the router binds during boot).
@Suite("Ghostty action router restore-phase arming: isolated binding")
struct GhosttyActivityInputBindingRestorePhaseTests {
    @Test("awaitBound resumes only after bind — never before, proven by ordering")
    @MainActor
    func awaitBoundResumesOnlyAfterBind() async throws {
        let binding = GhosttyTerminalActivityInputBinding()
        let log = OrderedEventLog()
        let waiterRegisteredSource = LocalFactSource(vocabulary: waiterRegistrationFactVocabulary())
        let waiterRegisteredRecorder = try waiterRegisteredSource.attach()

        // R1 gate hang audit (Lead 2026-10-01): a single `Task.yield()` only
        // claims `waitTask` reached registration — Swift's scheduler makes
        // no such promise. `onWaiterRegistered` fires synchronously, still
        // inside `awaitBound`'s own `withCheckedContinuation` setup
        // closure, into `LocalFactSource.sink` -- synchronous by its own
        // contract (`Tests/AgentStudioTestHarnessTests/FactRecorderLocalSinkTests.swift`)
        // -- so awaiting this fact is a real registration, not a guess.
        // Replaces a hand-built `CheckedContinuation` signal the
        // architecture lint's `agentstudio_no_adhoc_continuation_wait` rule
        // correctly flagged: this harness fits the seam after all.
        let waitTask = Task { @MainActor in
            await binding.awaitBound(onWaiterRegistered: {
                waiterRegisteredSource.sink("binding", .waiterRegistered)
            })
            log.record("resumed")
        }
        try await waiterRegisteredRecorder.expectNext(in: "binding", .waiterRegistered)
        log.record("before-bind")
        #expect(!binding.isBound)

        binding.bind(
            id: UUID(), context: { _ in .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 1) },
            sink: { _ in })
        await waitTask.value

        #expect(log.events == ["before-bind", "resumed"])
    }

    @Test("already bound: awaitBound returns immediately without registering a waiter")
    @MainActor
    func alreadyBoundReturnsImmediately() async {
        let binding = GhosttyTerminalActivityInputBinding()
        binding.bind(
            id: UUID(), context: { _ in .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 1) },
            sink: { _ in })

        await binding.awaitBound()

        #expect(binding.isBound)
    }

    @Test("a cancelled wait resumes without ever binding")
    @MainActor
    func cancelledWaitResumesWithoutBinding() async throws {
        let binding = GhosttyTerminalActivityInputBinding()
        let waiterRegisteredSource = LocalFactSource(vocabulary: waiterRegistrationFactVocabulary())
        let waiterRegisteredRecorder = try waiterRegisteredSource.attach()

        let waitTask = Task { @MainActor in
            await binding.awaitBound(onWaiterRegistered: {
                waiterRegisteredSource.sink("binding", .waiterRegistered)
            })
        }
        try await waiterRegisteredRecorder.expectNext(in: "binding", .waiterRegistered)
        waitTask.cancel()
        await waitTask.value

        #expect(!binding.isBound)
    }
}

/// R1 gate hang audit (Lead 2026-10-01): the one fact `awaitBoundResumesOnlyAfterBind`
/// and `cancelledWaitResumesWithoutBinding` both need -- "the waiter is now
/// registered" -- carried through the approved `LocalFactSource`/`FactRecorder`
/// harness instead of a hand-built continuation waiter.
private enum WaiterRegistrationFact: Equatable, Sendable {
    case waiterRegistered
}

private func waiterRegistrationFactVocabulary() -> FactVocabulary<String, WaiterRegistrationFact> {
    FactVocabulary(
        describeScope: { $0 },
        describeFact: { String(describing: $0) },
        isClosing: { _, _ in true }
    )
}

@MainActor
private final class OrderedEventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// Exercises `Ghostty.ActionRouter.armRestorePhase` against the real shared
/// binding singleton, which several other test files also bind/unbind
/// against.
///
/// Isolation audit (Lead 2026-10-01): this suite's own `@MainActor` +
/// `.serialized` only serialize its own tests against each other, not
/// against a *different* suite that also binds the same process-wide
/// singleton -- confirmed against real reap-time evidence of two such
/// suites in flight at once. What actually prevents that collision is the
/// aggregate-serial lane runner itself:
/// `run_aggregate_serial_non_webkit_swift_tests`
/// (scripts/swift-test-helpers.sh:1496-1510) sends every auto-discovered
/// `@MainActor @Suite(.serialized)` suite, this one included, through
/// `dispatch_isolated_suites fast`, which runs each suite as its own
/// `swift-testing-helper` process (`run_selected_isolated_suite`,
/// scripts/swift-test-helpers.sh:1694-1716) -- confirmed by reading both
/// functions directly. Two suites binding the same singleton therefore
/// never share a process in the real lanes or in CI; they only collided
/// under the gate's own ad-hoc `--filter` invocation, which puts every
/// filtered suite into one process.
@MainActor
@Suite("Ghostty action router restore-phase arming: shared singleton", .serialized)
struct GhosttyActionRouterRestorePhaseArmingTests {
    @Test("arming an already-bound router submits .restorePhaseArmed and returns .armed")
    func armingAnAlreadyBoundRouterSubmitsAndAcknowledges() async {
        let bindingID = UUID()
        let recorder = SubmittedInputRecorder()
        Ghostty.ActionRouter.bindTerminalActivityInput(
            id: bindingID,
            context: { _ in .init(isAttended: false, isAgentClassified: false, outputBurstThreshold: 1) },
            sink: { [recorder] input in recorder.record(input) }
        )
        defer { Ghostty.ActionRouter.unbindTerminalActivityInput(id: bindingID) }
        let paneID = UUID()
        let generation = RestoreGeneration(rawValue: 42)

        let acknowledgment = await Ghostty.ActionRouter.armRestorePhase(
            paneID: paneID, restoreGeneration: generation)

        #expect(acknowledgment == .armed)
        #expect(recorder.inputs == [.restorePhaseArmed(paneID: paneID, restoreGeneration: generation)])
    }
}

@MainActor
private final class SubmittedInputRecorder {
    private(set) var inputs: [TerminalActivitySourceInput] = []
    func record(_ input: TerminalActivitySourceInput) { inputs.append(input) }
}
