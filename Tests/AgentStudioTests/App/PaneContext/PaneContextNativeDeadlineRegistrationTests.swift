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
            atoms: CoreAtomScope.store, clock: clock, bridge: bridge)
        var advancing: Task<Void, any Error>?
        var monitors: [Task<Void, Never>] = []
        do {
            try await host.window.open()
            try await host.window.rendered()
            try await publish(.elicitation(id: "b", summary: "First queued prompt update"), to: host)
            let operation = Task { @MainActor in
                defer { captured.retire() }
                try await host.window.advance(
                    by: .seconds(10), registeredAt: firstDue,
                    onRegistration: { phase in
                        if case .captured(let wake) = phase { try await captured.arrive(wake) }
                    })
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
            try await host.window.rendered()
            #expect(clock.now == firstDue, "The native fixture drives the clock exactly once")
            #expect(host.prompts.map(\.summary) == ["First prompt", "Replacement prompt update"])
            #expect(host.window.native.labels().contains("Needs you · question: Replacement prompt update Now"))
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

    @Test("G18 a registered wake replaced before time drive cannot advance the clock for a stale producer")
    func replacementAfterRegistrationKeepsTheNativeJoinCausal() async throws {
        installTestCoreAtomsIfNeeded()
        let registered = HeldStep<PaneContextPopoverWakeProducer>(
            "native fixture observed the first registration", cancellation: .holdThroughCancellation)
        let successorBeforeSleep = HeldStep<Void>(
            "replacement producer before clock registration", cancellation: .holdThroughCancellation)
        let decision = HeldStep<PaneContextNativeRegistrationPhase>(
            "native fixture decided whether its captured wake is current", cancellation: .holdThroughCancellation)
        let bridge = PopoverOwnerFactBridge()
        let start = TestPushClock().now
        let due = start.advanced(by: .seconds(10))
        let registrations = Mutex(0)
        let clock = TestPushClock(
            pendingSleepFactSink: bridge.observeClock,
            beforeRegistration: { deadline in
                let isSuccessor = registrations.withLock { count in
                    guard deadline == due else { return false }
                    count += 1
                    return count == 2
                }
                if isSuccessor { try await successorBeforeSleep.arrive(()) }
            })
        let host = try await PromptRefreshHost.make(
            atoms: CoreAtomScope.store, clock: clock, bridge: bridge)
        var advancing: Task<Void, any Error>?
        var successorMonitor: Task<Void, Never>?
        do {
            try await host.window.open()
            try await host.window.rendered()
            try await publish(.elicitation(id: "b", summary: "First registered prompt update"), to: host)
            var firstSequence: UInt64?
            let operation = Task { @MainActor in
                defer {
                    registered.retire()
                    decision.retire()
                    successorBeforeSleep.retire()
                }
                try await host.window.advance(
                    by: .seconds(10), registeredAt: due,
                    onRegistration: { phase in
                        switch phase {
                        case .registered(let wake) where firstSequence == nil:
                            firstSequence = wake.sequence
                            try await registered.arrive(wake)
                        case .advanced(let wake), .superseded(let wake):
                            if wake.sequence == firstSequence { try await decision.arrive(phase) }
                        default: break
                        }
                    })
            }
            advancing = operation
            let old = try await registered.firstArrival()
            try await publish(.elicitation(id: "b", summary: "Replacement after registration"), to: host)
            try #require(old.task.isCancelled, "The real canonical input must cancel the registered old wake")
            let successor = try #require(await host.window.bindings.owner.scheduledWakeProducer())
            try #require(successor.sequence != old.sequence)
            successorMonitor = Task {
                await successor.task.value
                successorBeforeSleep.retire()
            }
            _ = try await successorBeforeSleep.firstArrival()
            #expect(clock.pendingSleepCount == 0, "The replacement is held before registering")
            registered.release()
            let observed = try await decision.firstArrival()
            if case .superseded = observed {} else { Issue.record("The stale registration advanced the clock") }
            #expect(clock.now == start, "Superseding a registration must not drive time")
            successorBeforeSleep.release()
            decision.release()
            try await operation.value
            try await host.window.rendered()
            #expect(clock.now == due, "Only the current registered producer drives the clock once")
            #expect(host.prompts.map(\.summary) == ["First prompt", "Replacement after registration"])
            #expect(host.window.native.labels().contains("Needs you · question: Replacement after registration Now"))
            await successorMonitor?.value
            try await host.close()
        } catch {
            registered.retire()
            successorBeforeSleep.retire()
            decision.retire()
            _ = try? await advancing?.value
            await successorMonitor?.value
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
