import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import GhosttyKit
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions
@testable import AgentStudioTerminal

extension AgentStudioIPCSessionsVerticalTests {
    @Test(
        "native commandFinished capture survives the held ordered-control route and fences newer mains",
        arguments: NativeCommandExitScenario.allCases)
    func nativeCommandFinishedCarriesSourceInstant(scenario: NativeCommandExitScenario) async throws {
        let harness = try await SessionsVerticalHarness.make()
        let database = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: database.root) }
        let pane = harness.boundPaneId
        let native = NativeCommandExitRoute(pane: pane, bus: harness.commandHarness.coordinator.paneEventBus)
        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(native.registry)
        Ghostty.ActionRouter.bindTerminalActivityInput(
            id: native.bindingId,
            context: { _ in
                .init(isAttended: true, isAgentClassified: true, outputBurstThreshold: 30)
            }, sink: { _ in try? await native.held.arrive(()) })
        let time = Mutex(ContinuousClock.now.advanced(by: .seconds(-1)))
        let endFacts = FactRecorder<UUID, UUID>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { "ended \($0)" }, isClosing: { _, _ in false }))
        do {
            if scenario == .restored {
                try await database.withIngestion(
                    continuousNow: { time.withLock { $0 } },
                    operation: { _, adapter in
                        try await nativeExitHook(adapter, pane: pane, session: "A", event: .toolActivity)
                    })
            }
            let expected = try await database.withIngestion(
                continuousNow: { time.withLock { $0 } },
                sessionEnded: { generation in endFacts.append(scope: pane, fact: generation) },
                operation: { ingestion, adapter in
                    try await exerciseNativeExit(
                        .init(
                            scenario: scenario, harness: harness, native: native, ingestion: ingestion,
                            adapter: adapter, setTime: { next in time.withLock { $0 = next } }, endFacts: endFacts))
                })
            try await database.withIngestion { ingestion, _ in
                let summary = try await ingestion.sessionSummary(paneId: pane)
                #expect(summary == expected)
            }
            await native.cleanUp(originalRegistry: originalRegistry)
            await harness.tearDown()
            try await endFacts.finish()
        } catch {
            harness.commandHarness.coordinator.sessionsIngestion = nil
            await native.cleanUp(originalRegistry: originalRegistry)
            await harness.tearDown()
            try? await endFacts.finish()
            throw error
        }
    }
}

private struct NativeCommandExitContext: Sendable {
    let scenario: NativeCommandExitScenario
    let harness: SessionsVerticalHarness
    let native: NativeCommandExitRoute
    let ingestion: SessionsIngestion
    let adapter: AgentStudioIPCSessionsAdapter
    let setTime: @Sendable (ContinuousClock.Instant) -> Void
    let endFacts: FactRecorder<UUID, UUID>
}

@MainActor
private func exerciseNativeExit(_ context: NativeCommandExitContext) async throws -> SessionSummary? {
    let scenario = context.scenario
    let harness = context.harness
    let native = context.native
    let ingestion = context.ingestion
    let adapter = context.adapter
    let setTime = context.setTime
    let endFacts = context.endFacts
    let pane = harness.boundPaneId
    harness.commandHarness.coordinator.sessionsIngestion = ingestion
    defer { harness.commandHarness.coordinator.sessionsIngestion = nil }
    if scenario != .restored {
        try await nativeExitHook(adapter, pane: pane, session: "A", event: .toolActivity)
    }
    let initial = try #require(try await ingestion.sessionSummary(paneId: pane))
    let invocation = try await native.invokeCallback()
    try #require(invocation.handled)
    try await native.held.firstArrival()
    #expect((await native.runtime.eventsSince(seq: 0)).events.isEmpty)
    let captured = try #require(native.capture.instant.withLock { $0 })
    if scenario == .newerMain {
        setTime(captured.advanced(by: .milliseconds(100)))
        try await nativeExitHook(adapter, pane: pane, session: "A", event: .sessionEnd)
        try await endFacts.expectNext(in: pane, initial.bindingGeneration)
        setTime(captured.advanced(by: .milliseconds(200)))
        try await nativeExitHook(adapter, pane: pane, session: "B", event: .toolActivity)
    }
    let beforeRelease = try await ingestion.sessionSummary(paneId: pane)
    native.held.release()
    #expect(await invocation.route.value)
    let replay = await native.runtime.eventsSince(seq: 0)
    let envelope = try #require(replay.events.first)
    guard case .pane(let exit) = envelope else {
        Issue.record("Expected the native commandFinished pane envelope")
        return nil
    }
    #expect(exit.timestamp == captured)
    if scenario == .newerMain {
        let observation = try #require(await native.waitForCoordinatorDelivery(pane: pane))
        guard case .worktreeBellRang(let observedPane) = observation else {
            Issue.record("Expected the coordinator's bell barrier fact")
            return nil
        }
        #expect(observedPane == pane)
        #expect(try await ingestion.sessionSummary(paneId: pane) == beforeRelease)
    } else {
        try await endFacts.expectNext(in: pane, initial.bindingGeneration)
        #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .idle(.ended))
    }
    return try await ingestion.sessionSummary(paneId: pane)

}

enum NativeCommandExitScenario: CaseIterable, Equatable, Sendable {
    case normal, newerMain, restored
}

@MainActor
private final class NativeCommandExitRoute {
    let held = HeldStep<Void>("native commandFinished ordered control")
    let capture = NativeCommandExitCapture()
    let bindingId = UUIDv7.generate()
    let surfaceId = UUIDv7.generate()
    let view = NSView(frame: .zero)
    let runtime: TerminalRuntime
    let registry = RuntimeRegistry()
    let lookup: NativeCommandExitLookup
    let accumulator = TerminalLocalActionAccumulator { _, _ in }

    init(pane: UUID, bus: EventBus<RuntimeEnvelope>) {
        runtime = TerminalRuntime(
            paneId: .init(existingUUID: pane), metadata: .init(paneId: .init(existingUUID: pane), title: "Native exit"),
            paneEventBus: bus)
        lookup = NativeCommandExitLookup(view: ObjectIdentifier(view), surface: surfaceId, pane: pane)
        _ = registry.register(runtime)
    }

    func cleanUp(originalRegistry: RuntimeRegistry) async {
        held.retire()
        if let route = capture.routeTask.withLock({ $0 }) { _ = await route.value }
        _ = await runtime.shutdown(timeout: .zero)
        Ghostty.ActionRouter.unbindTerminalActivityInput(id: bindingId)
        Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
    }

    func waitForCoordinatorDelivery(pane: UUID) async -> AppEvent? {
        let stream = await AppEventBus.shared.subscribe(
            policy: .criticalUnbounded, subscriberName: "NativeCommandExit.coordinatorBarrier")
        let bellWaiter = Task { @MainActor () -> AppEvent? in
            for await event in stream {
                if case .worktreeBellRang(let observedPane) = event, observedPane == pane { return event }
            }
            return nil
        }
        // Both facts share this runtime channel and the coordinator's critical stream.
        // The bell is observed only after the coordinator awaited the exit's FIFO result.
        runtime.handleGhosttyEvent(.bellRang)
        return await bellWaiter.value
    }

    func invokeCallback() async throws -> (handled: Bool, route: Task<Bool, Never>) {
        let callbackCapture = capture
        let callbackLookup = lookup
        let callbackAccumulator = accumulator
        let viewIdentity = ObjectIdentifier(view)
        let expectedSurface = surfaceId
        let handled = await valueFromDedicatedThread {
            var action = ghostty_action_s(tag: GHOSTTY_ACTION_COMMAND_FINISHED, action: ghostty_action_u())
            action.action.command_finished.exit_code = 0
            action.action.command_finished.duration = 42
            guard let app = UnsafeMutableRawPointer(bitPattern: 1) else { return false }
            return Ghostty.ActionRouter.handleAction(
                app, target: ghostty_target_s(tag: GHOSTTY_TARGET_APP, target: ghostty_target_u(surface: nil)),
                action: action, routingLookupProvider: { callbackLookup },
                metadataActionRouter: { tag, payload, _, handledResult in
                    guard case .commandFinished(_, _, let instant) = payload else { return false }
                    callbackCapture.instant.withLock { $0 = instant }
                    let task = Task { @MainActor in
                        await Ghostty.ActionRouter.routeExactFactOrControlOnMainActor(
                            precedingTitle: nil, actionTag: tag, payload: payload,
                            surfaceViewObjectID: viewIdentity, expectedSurfaceID: expectedSurface,
                            routingLookup: callbackLookup, accumulator: callbackAccumulator)
                    }
                    callbackCapture.routeTask.withLock { $0 = task }
                    return handledResult
                })
        }
        return (handled, try #require(callbackCapture.routeTask.withLock { $0 }))
    }

}

@MainActor
private final class NativeCommandExitLookup: GhosttyActionRoutingLookup {
    let view: ObjectIdentifier
    let surface: UUID
    let pane: UUID
    init(view: ObjectIdentifier, surface: UUID, pane: UUID) {
        self.view = view
        self.surface = surface
        self.pane = pane
    }
    func surfaceId(forViewObjectId value: ObjectIdentifier) -> UUID? { value == view ? surface : nil }
    func paneId(for value: UUID) -> UUID? { value == surface ? pane : nil }
}

private func nativeExitHook(
    _ adapter: AgentStudioIPCSessionsAdapter, pane: UUID, session: String, event: IPCSessionEventName
) async throws {
    _ = try await adapter.recordProviderEvent(
        paneId: pane,
        params: .init(
            handle: pane.uuidString, provider: .init(identifier: "codex", version: "0.160.0", mode: "cli"),
            event: .init(
                name: event, conversationId: session, turnId: "turn", requestId: nil, toolId: nil,
                subagentId: nil, occurrenceId: UUIDv7.generate()), correlationId: UUIDv7.generate()),
        provenance: .matchingPane)
}

private final class NativeCommandExitCapture: Sendable {
    let instant = Mutex<ContinuousClock.Instant?>(nil)
    let routeTask = Mutex<Task<Bool, Never>?>(nil)
}
