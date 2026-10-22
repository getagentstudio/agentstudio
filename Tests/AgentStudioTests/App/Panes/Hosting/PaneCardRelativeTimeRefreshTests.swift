import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneCardRelativeTimeRefreshTests {
    @Test("message replacement uses its own metadata and hiding before entry cancels both workers")
    func messageReplacementAndImmediateHide() async throws {
        let clock = NativeCardTestClock()
        var events: [PaneRelativeTimeRefresh.Event] = []
        let refresh = PaneRelativeTimeRefresh(onEvent: {
            events.append($0)
            clock.observeOwner($0)
        })
        let pane = UUIDv7.generate()
        let initial = PaneManagementIdentityCapture.VisibleInput.message(
            paneId: pane,
            detail: .init(
                summary: "First", refs: [], writer: .pane(.init(existingUUID: pane)),
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let replacement = PaneManagementIdentityCapture.VisibleInput.message(
            paneId: pane,
            detail: .init(
                summary: "First", refs: [], writer: .pane(.init(existingUUID: pane)),
                updatedAt: Date(timeIntervalSince1970: 1_800_000_010)))
        let clockOpening = await clock.facts.mark(0)
        let ownerOpening = await clock.facts.mark(1)
        do {
            try #require(refresh.startOrReplace(initial, clock: clock) == .started)
            try #require(refresh.startOrReplace(initial, clock: clock) == .unchanged)
            try #require(refresh.startOrReplace(replacement, clock: clock) == .replaced(cancelRequested: true))
            try #require(refresh.hide() == .cancelled(requested: true))
            try await clock.retire()
            try await clock.facts.expectNone(
                of: {
                    if case .registered = $0 { return true }
                    return false
                },
                "deadline registered after immediate hide", from: clockOpening, closedBy: { $0 == .retired })
            try await clock.facts.expectNone(
                of: {
                    if case .workerEnded(_, _, false) = $0 { return true }
                    return false
                },
                "uncancelled hidden worker", from: ownerOpening, closedBy: { $0 == .retired })
            #expect(events.contains(.ended(initial, .cancelled)))
            #expect(events.contains(.ended(replacement, .cancelled)))
            #expect(refresh.presentation == nil)
            #expect(clock.pendingSleepCount == 0)
            try await clock.facts.finish()
        } catch {
            refresh.hide()
            try? await clock.retire()
            try? await clock.facts.finish()
            throw error
        }
    }

    @Test("replacement and hide return actual cancellation dispositions before terminal awaits")
    func synchronousDispositionsCloseWrongKeyAndNoCancelFailures() async throws {
        let clock = NativeCardTestClock()
        let refresh = PaneRelativeTimeRefresh(onEvent: { clock.observeOwner($0) })
        let initialTime = clock.now
        let initial = input(at: initialTime)
        do {
            try #require(refresh.startOrReplace(initial, clock: clock) == .started)
            #expect(try await clock.nextOperation(pane: initial.paneId, input: initialTime) == .started)
            try await clock.entered(pane: initial.paneId, input: initialTime)
            try await clock.registered(
                initialTime.advanced(by: .seconds(60)), pane: initial.paneId, currentInput: initialTime)

            try #require(refresh.startOrReplace(initial, clock: clock) == .unchanged)
            #expect(try await clock.nextOperation(pane: initial.paneId, input: initialTime) == .unchanged)
            #expect(clock.pendingSleepCount == 1)

            clock.advance(by: .seconds(10))
            let changedTime = clock.now
            var changed = initial
            changed.activityTime = .init(orderingInstant: changedTime, wallTime: .now, source: .hook)

            let replacement = refresh.startOrReplace(changed, clock: clock)
            // The wrong-key fault returns unchanged here. Do not await a missing new worker.
            try #require(
                replacement == .replaced(cancelRequested: true), "Replacement must request old worker cancellation")
            #expect(try await clock.nextOperation(pane: initial.paneId, input: changedTime) == replacement)
            try await clock.replacedWorkers(pane: initial.paneId, oldInput: initialTime, newInput: changedTime)
            try await clock.registered(
                changedTime.advanced(by: .seconds(60)), pane: initial.paneId,
                currentInput: changedTime, retiredInput: initialTime)

            let hidden = refresh.hide()
            // The omitted-cancel fault returns requested=false here, before a terminal await.
            try #require(hidden == .cancelled(requested: true), "Hide must request worker cancellation")
            #expect(try await clock.nextHideResult() == hidden)
            try await clock.cancelledWorker(pane: initial.paneId, input: changedTime)
            #expect(clock.pendingSleepCount == 0)
            try await clock.finish()
        } catch {
            refresh.hide()
            try? await clock.retire()
            try? await clock.facts.finish()
            throw error
        }
    }

    @Test("replacement barrier drains either clock-fact order before the next tick and hide", arguments: [true, false])
    func replacementBarrierConsumesBothClockOrders(registrationFirst: Bool) async throws {
        let clock = NativeCardTestClock()
        let pane = UUIDv7.generate()
        let oldInput = clock.now
        let currentInput = oldInput.advanced(by: .seconds(10))
        let deadline = currentInput.advanced(by: .seconds(60))
        let nextDeadline = deadline.advanced(by: .seconds(60))
        let oldTerminal = NativeCardClockFact.workerEnded(pane, oldInput, cancelled: true)
        let registration = NativeCardClockFact.registered(deadline)

        // Both sequences are valid across workers. Queue them explicitly so the
        // regression cannot pass just because this runner schedules retirement first.
        clock.facts.append(scope: 0, fact: .ended(0, oldInput.advanced(by: .seconds(60)), cancelled: true))
        for fact in registrationFirst ? [registration, oldTerminal] : [oldTerminal, registration] {
            clock.facts.append(scope: 0, fact: fact)
        }
        clock.facts.append(scope: 0, fact: .ended(1, deadline, cancelled: false))
        clock.facts.append(scope: 0, fact: .registered(nextDeadline))
        clock.facts.append(scope: 0, fact: .ended(2, nextDeadline, cancelled: true))
        let currentTerminal = NativeCardClockFact.workerEnded(pane, currentInput, cancelled: true)
        clock.facts.append(scope: 0, fact: currentTerminal)
        clock.facts.append(scope: 1, fact: currentTerminal)
        // Close the source before waiting: missing facts fail instead of hanging.
        try await clock.retire()

        try await clock.registered(deadline, pane: pane, currentInput: currentInput, retiredInput: oldInput)
        try await clock.registered(nextDeadline, pane: pane, currentInput: currentInput)
        try await clock.cancelledWorker(pane: pane, input: currentInput)
        try await clock.finish()
    }

    @Test("retiring the relative-time owner cancels its worker")
    func deinitializationCancelsWorker() async throws {
        let clock = NativeCardTestClock()
        var refresh: PaneRelativeTimeRefresh? = PaneRelativeTimeRefresh(onEvent: { clock.observeOwner($0) })
        let reference = clock.now
        let initial = input(at: reference)
        do {
            try #require(refresh?.startOrReplace(initial, clock: clock) == .started)
            _ = try await clock.nextOperation(pane: initial.paneId, input: reference)
            try await clock.entered(pane: initial.paneId, input: reference)
            try await clock.registered(
                reference.advanced(by: .seconds(60)), pane: initial.paneId, currentInput: reference)

            refresh = nil

            try await clock.cancelledWorker(pane: initial.paneId, input: reference)
            #expect(clock.pendingSleepCount == 0)
            try await clock.finish()
        } catch {
            refresh = nil
            try? await clock.retire()
            try? await clock.facts.finish()
            throw error
        }
    }

    private func input(at instant: ContinuousClock.Instant) -> PaneManagementIdentityCapture.LineInput {
        .init(
            paneId: UUIDv7.generate(), terminalTitle: "Clock proof", cwd: nil,
            shellExecutablePath: nil, agentTitle: nil, note: nil, isDrawer: false,
            agentLine: nil, sessionPresentation: nil,
            activityTime: .init(orderingInstant: instant, wallTime: .now, source: .terminal))
    }
}
