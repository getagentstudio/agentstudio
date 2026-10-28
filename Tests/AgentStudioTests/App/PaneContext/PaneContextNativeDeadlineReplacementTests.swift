import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Native fixture deadline-producer correlation", .serialized)
struct PaneContextNativeDeadlineReplacementTests {
    @Test("A cancelled wake cannot complete native refresh before its held canonical input admits the due read")
    func cancelledWakeJoinsItsActualInputProducer() async throws {
        let pane = PaneId.generateUUIDv7()
        let firstId = AgentMessageId.generateUUIDv7()
        let secondId = AgentMessageId.generateUUIDv7()
        let first = try PaneContextMessageFixtures.askDetail(pane: pane, id: firstId, state: .open, revision: 1)
            .messages[0]
        let second = try PaneContextMessageFixtures.askDetail(pane: pane, id: secondId, state: .open, revision: 1)
            .messages[0]
        let harness = PopoverOwnerHarness(
            detail: PaneContextPopoverShapingTests.detail(paneId: pane, messages: [first, second]))
        let firstKey = PaneContextMessageKey(paneId: pane, messageId: firstId)
        let secondKey = PaneContextMessageKey(paneId: pane, messageId: secondId)
        harness.capture.setSource(PaneContextPreparedDetailFixture.cardSource(pane, selected: firstKey), for: pane)
        let held = HeldStep<PaneContextPopoverSnapshot>("canonical input's actual pending publication")
        var input: Task<Void, Never>?
        var completion: Task<PaneContextPopoverExecution, any Error>?
        do {
            let opened = try await harness.open(content: .card)
            _ = try await harness.completed(opened.initialExecution)
            await harness.invalidations.bump(pane, emit: false)
            await harness.owner.sourceInvalidated(
                .init(sourcePaneId: pane, generation: 1),
                epoch: opened.initialExecution.serviceEpoch)
            let wake = try await harness.timer()
            try #require(wake.deadline == harness.clock.now.advanced(by: .seconds(10)))
            await harness.projections.holdNext(harness.key, at: held)
            harness.capture.setSource(PaneContextPreparedDetailFixture.cardSource(pane, selected: secondKey), for: pane)
            let capture = harness.capture.snapshot(for: [pane])
            input = Task {
                defer { held.retire() }
                await harness.owner.receive(capture, for: harness.key, opening: opened.epoch)
            }
            let pending = try await held.firstArrival()
            guard case .input(let operation) = pending.identity.producer else {
                throw NativeDeadlineCalibrationFailure.wrongProducer
            }
            await wake.task.value
            try #require(harness.bridge.didFinish(.deadline(wake.sequence)))
            harness.clock.advance(by: .seconds(10))
            let started = await startNativeDueCompletion(
                on: harness.owner, key: harness.key, opening: opened.epoch,
                previous: opened.initialExecution.id, wake: wake.sequence, input: operation)
            completion = started.task
            #expect(started.waitingForInput, "The native completion must join the real held input before returning")
            held.release()
            await input?.value
            let next = try await started.task.value
            try #require(next.id != opened.initialExecution.id)
            _ = try await harness.completed(next)
            let state = await harness.owner.consumers[harness.key]?.acceptedState
            guard case .ready(.detail(_, .current(let selected))) = state else {
                throw NativeDeadlineCalibrationFailure.missingCurrentRead
            }
            #expect(selected.key == secondKey)
            #expect(next.kind == .background)
            try await harness.finish()
        } catch {
            held.retire()
            await input?.value
            _ = try? await completion?.value
            try? await harness.finish()
            throw error
        }
    }
    @Test("An already-due replacement wake is joined without another clock advance")
    func dueReplacementWakeUsesItsActualProducer() async throws {
        let pane = PaneId.generateUUIDv7()
        let harness = PopoverOwnerHarness(detail: PaneContextPopoverShapingTests.detail(paneId: pane))
        var completion: Task<PaneContextPopoverExecution, any Error>?
        do {
            let opened = try await harness.open()
            _ = try await harness.completed(opened.initialExecution)
            await harness.invalidations.bump(pane, emit: false)
            await harness.owner.sourceInvalidated(
                .init(sourcePaneId: pane, generation: 1),
                epoch: opened.initialExecution.serviceEpoch)
            let retired = try await harness.timer()
            harness.capture.setTitle("Current title after replacement")
            await harness.owner.receive(
                harness.capture.snapshot(for: [pane]),
                for: harness.key, opening: opened.epoch)
            await retired.task.value
            let replacement = try await harness.timer()
            try #require(replacement.sequence != retired.sequence)
            let origin = harness.clock.now
            let task = await startAfterNativeDueClockAdvance(
                on: harness.owner, key: harness.key, opening: opened.epoch,
                previous: opened.initialExecution.id, retiredWake: retired.sequence)
            completion = task
            let next = try await task.value
            _ = try await harness.completed(next)
            #expect(harness.clock.now == origin.advanced(by: .seconds(10)))
            #expect(
                await harness.projections.requests.last?.capture.sources[pane]?.title
                    == "Current title after replacement")
            #expect(next.kind == .background)
            try await harness.finish()
        } catch {
            _ = try? await completion?.value
            try? await harness.finish()
            throw error
        }
    }

}

private struct StartedNativeDueCompletion: Sendable {
    let task: Task<PaneContextPopoverExecution, any Error>
    let waitingForInput: Bool
}

/// Immediate entry selects the owned interleaving; verdicts use the actual returned read and selection.
private func startNativeDueCompletion(
    on owner: isolated PopoverOwnerHarness.Owner,
    key: PaneContextPopoverConsumerKey, opening: UInt64, previous: UUID, wake: UInt64, input: UUID
) -> StartedNativeDueCompletion {
    let task = Task.immediate {
        try await awaitDueNativeExecution(on: owner, key: key, opening: opening, after: previous, retiredWake: wake)
    }
    return .init(task: task, waitingForInput: !(owner.inputCompletions[input]?.waiters.isEmpty ?? true))
}

/// Advancing on the isolated owner holds the due callback until the helper enters its actual task join.
private func startAfterNativeDueClockAdvance(
    on owner: isolated PopoverOwnerHarness.Owner,
    key: PaneContextPopoverConsumerKey, opening: UInt64, previous: UUID, retiredWake: UInt64
) -> Task<PaneContextPopoverExecution, any Error> {
    owner.clock.advance(by: .seconds(10))
    return Task.immediate {
        try await awaitDueNativeExecution(
            on: owner, key: key, opening: opening,
            after: previous, retiredWake: retiredWake)
    }
}

private enum NativeDeadlineCalibrationFailure: Error { case wrongProducer, missingCurrentRead }
