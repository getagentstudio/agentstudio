import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneCardRelativeTimeRefreshTests {
    @Test("replacement and hide return actual cancellation dispositions before terminal awaits")
    func synchronousDispositionsCloseWrongKeyAndNoCancelFailures() async throws {
        let clock = NativeCardTestClock()
        let refresh = PaneCardRelativeTimeRefresh(onEvent: { clock.observeOwner($0) })
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

    @Test("retiring the relative-time owner cancels its worker")
    func deinitializationCancelsWorker() async throws {
        let clock = NativeCardTestClock()
        var refresh: PaneCardRelativeTimeRefresh? = PaneCardRelativeTimeRefresh(onEvent: { clock.observeOwner($0) })
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
