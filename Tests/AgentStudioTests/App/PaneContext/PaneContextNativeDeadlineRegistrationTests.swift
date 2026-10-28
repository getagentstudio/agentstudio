import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Native deadline registration replacement", .serialized)
struct PaneContextNativeDeadlineRegistrationTests {
    @Test("G18 a real input may replace a captured deadline before it registers without breaking the native clock join")
    func replacementBeforeRegistrationKeepsTheNativeJoinCausal() async throws {
        installTestCoreAtomsIfNeeded()
        let beforeSleep = HeldStep<Void>(
            "first useful deadline before clock registration", cancellation: .holdThroughCancellation)
        let captured = HeldStep<PaneContextPopoverWakeProducer>(
            "native fixture captured the pre-registration wake", cancellation: .holdThroughCancellation)
        let bridge = PopoverOwnerFactBridge()
        let firstDue = TestPushClock().now.advanced(by: .seconds(10))
        let intercepted = Mutex(false)
        let clock = TestPushClock(
            pendingSleepFactSink: bridge.observeClock,
            beforeRegistration: { deadline in
                let intercept = intercepted.withLock { value in
                    guard deadline == firstDue, !value else { return false }
                    value = true
                    return true
                }
                if intercept { try await beforeSleep.arrive(()) }
            })
        let host = try await PromptRefreshHost.make(
            atoms: CoreAtomScope.store, cardMode: true, clock: clock, bridge: bridge)
        var advancing: Task<Void, any Error>?
        var monitors: [Task<Void, Never>] = []
        do {
            try await host.window.open()
            try await host.window.renderedCard()
            try await publish(.elicitation(id: "b", summary: "First queued prompt update"), to: host)
            let operation = Task { @MainActor in
                defer { captured.retire() }
                try await host.window.advance(
                    by: .seconds(10), registeredAt: firstDue,
                    beforeRegistrationJoin: { try await captured.arrive($0) })
            }
            advancing = operation
            let wake = try await captured.firstArrival()
            monitors.append(
                Task {
                    await wake.task.value
                    beforeSleep.retire()
                })
            _ = try await beforeSleep.firstArrival()
            #expect(!clock.pendingSleepDeadlines.contains(firstDue), "The captured producer has not registered yet")
            try await publish(.elicitation(id: "b", summary: "Replacement prompt update"), to: host)
            try #require(wake.task.isCancelled, "The real canonical input must cancel the captured old deadline")
            let successor = try #require(await host.window.bindings.owner.scheduledWakeProducer())
            try #require(successor.sequence != wake.sequence, "A distinct real successor deadline must replace it")
            beforeSleep.release()
            await wake.task.value
            try #require(
                bridge.didFinish(.deadline(wake.sequence)), "Old deadline producer must publish its terminal fact")
            captured.release()
            try await operation.value
            try await host.window.renderedCard()
            #expect(clock.now == firstDue, "The native fixture drives the clock exactly once")
            #expect(host.prompts.map(\.summary) == ["First prompt", "Replacement prompt update"])
            #expect(host.window.native.labels().contains("+1 more"))
            for monitor in monitors { await monitor.value }
            try await host.close()
        } catch {
            beforeSleep.retire()
            captured.retire()
            _ = try? await advancing?.value
            for monitor in monitors { await monitor.value }
            try? await host.close()
            throw error
        }
    }

    private func publish(_ signal: SessionProviderSignal, to host: PromptRefreshHost) async throws {
        try await host.submit(signal)
        let handle = try #require(host.window.handle)
        let mailbox = await host.fixture.composition.ingestion.statusPublicationMailbox
        let batch = mailbox.takeBatch()
        try #require(!batch.isEmpty, "The real Sessions owner must publish this update")
        host.status.apply(batch)
        let forwarding = host.window.bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch)
        try #require(!forwarding.isEmpty, "The canonical input must have a real forwarding producer")
        for producer in forwarding { await producer.value }
    }
}
