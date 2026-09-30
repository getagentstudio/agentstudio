import AgentStudioAppIPC
import AgentStudioProgrammaticControl
import AppKit
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct GhosttyActionRouterMixedPressureTests {
    final class FakeActionRoutingLookup: GhosttyActionRoutingLookup {
        private let surfaceIdsByViewObjectId: [ObjectIdentifier: UUID]
        private let paneIdsBySurfaceId: [UUID: UUID]

        init(
            surfaceIdsByViewObjectId: [ObjectIdentifier: UUID] = [:],
            paneIdsBySurfaceId: [UUID: UUID] = [:]
        ) {
            self.surfaceIdsByViewObjectId = surfaceIdsByViewObjectId
            self.paneIdsBySurfaceId = paneIdsBySurfaceId
        }

        func surfaceId(forViewObjectId viewObjectId: ObjectIdentifier) -> UUID? {
            surfaceIdsByViewObjectId[viewObjectId]
        }

        func paneId(for surfaceId: UUID) -> UUID? {
            paneIdsBySurfaceId[surfaceId]
        }
    }

    @Test(
        "translated admission isolates mixed local pressure while exact facts retain every publication path"
    )
    func translatedAdmission_mixedLocalPressureIsolatedFromExactFacts() async throws {
        let localSampleCount = 100_000
        let exactFactCount = 25
        let fixture = await MixedAdmissionFixture(exactFactCapacity: exactFactCount)
        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(fixture.runtimeRegistry)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
            fixture.accumulator.removeSurface(fixture.surfaceID)
        }

        try routeMixedTerminalPressure(
            fixture: fixture,
            localSampleCount: localSampleCount,
            exactFactCount: exactFactCount
        )
        try assertMixedPressureAccumulatorConverges(fixture: fixture, localSampleCount: localSampleCount)
        try await assertMixedPressurePublicationPaths(fixture: fixture, exactFactCount: exactFactCount)
        await fixture.shutdown()
    }

    private func commandFinishedFacts(from envelopes: [RuntimeEnvelope]) -> [CommandFinishedFact] {
        envelopes.compactMap { envelope in
            guard case .pane(let paneEnvelope) = envelope,
                case .terminal(.commandFinished(let exitCode, let duration)) = paneEnvelope.event
            else { return nil }
            return CommandFinishedFact(exitCode: exitCode, duration: duration)
        }
    }

    private func expectedCommandFinishedFacts(count: Int) -> [CommandFinishedFact] {
        (0..<count).map { CommandFinishedFact(exitCode: $0, duration: UInt64($0 + 1)) }
    }

    private func routeMixedTerminalPressure(
        fixture: MixedAdmissionFixture,
        localSampleCount: Int,
        exactFactCount: Int
    ) throws {
        let localSamplesPerExactFact = localSampleCount / exactFactCount
        for factIndex in 0..<exactFactCount {
            for localOffset in 0..<localSamplesPerExactFact {
                let sampleIndex = factIndex * localSamplesPerExactFact + localOffset
                routeLocalTranslatedSample(sampleIndex, fixture: fixture)
            }

            let ipcSnapshotBeforeExactFact = try fixture.ipcAdapter.terminalSnapshot(
                fixture.paneHandle, ownPaneAssertion: nil)
            #expect(ipcSnapshotBeforeExactFact.lastSequence == UInt64(factIndex))
            routeExactCommandFinishedFact(factIndex, fixture: fixture)
        }
    }

    private func routeLocalTranslatedSample(_ sampleIndex: Int, fixture: MixedAdmissionFixture) {
        let localAction = localTranslatedAction(sampleIndex: sampleIndex)
        let translatedEvent = GhosttyAdapter.shared.translate(
            actionTag: UInt32(localAction.tag.rawValue),
            payload: localAction.payload
        )
        let disposition = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
            translatedEvent,
            surfaceID: fixture.surfaceID,
            accumulator: fixture.accumulator
        )
        #expect(disposition == .handledLocally)
    }

    private func localTranslatedAction(
        sampleIndex: Int
    ) -> (tag: GhosttyActionTag, payload: GhosttyAdapter.ActionPayload) {
        switch sampleIndex % 7 {
        case 0:
            return (.mouseShape, .mouseShape(rawValue: UInt32(GHOSTTY_MOUSE_SHAPE_TEXT.rawValue)))
        case 1:
            return (.mouseVisibility, .mouseVisibility(rawValue: UInt32(GHOSTTY_MOUSE_VISIBLE.rawValue)))
        case 2:
            return (
                .scrollbar,
                .scrollbar(
                    total: UInt64(sampleIndex + 100),
                    offset: UInt64(sampleIndex + 80),
                    length: 20
                )
            )
        case 3:
            return (.startSearch, .startSearch("query-\(sampleIndex)"))
        case 4:
            return (.searchTotal, .searchTotal(sampleIndex))
        case 5:
            return (.searchSelected, .searchSelected(sampleIndex))
        default:
            return (.endSearch, .endSearch)
        }
    }

    private func routeExactCommandFinishedFact(_ factIndex: Int, fixture: MixedAdmissionFixture) {
        let exactPayload = GhosttyAdapter.ActionPayload.commandFinished(
            exitCode: factIndex,
            duration: UInt64(factIndex + 1)
        )
        let exactActionTag = UInt32(GHOSTTY_ACTION_COMMAND_FINISHED.rawValue)
        let translatedEvent = GhosttyAdapter.shared.translate(
            actionTag: exactActionTag,
            payload: exactPayload
        )
        let disposition = Ghostty.ActionRouter.admitTranslatedActionToTerminalRuntime(
            translatedEvent,
            surfaceID: fixture.surfaceID,
            accumulator: fixture.accumulator
        )

        #expect(disposition == .routeExactFactOrControl(precedingTitle: nil))
        #expect(
            Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
                actionTag: exactActionTag,
                payload: exactPayload,
                surfaceViewObjectId: fixture.surfaceViewObjectID,
                routingLookup: fixture.routingLookup
            )
        )
    }

    private func assertMixedPressureAccumulatorConverges(
        fixture: MixedAdmissionFixture,
        localSampleCount: Int
    ) throws {
        #expect(fixture.drainScheduleRecorder.scheduledSurfaceIDs == [fixture.surfaceID])
        #expect(fixture.accumulator.pendingSurfaceCount == 1)
        #expect(
            fixture.accumulator.retainedEntryCount
                <= TerminalLocalActionAccumulator.maximumRetainedEntriesPerSurface
        )

        let localBatch = try #require(fixture.accumulator.beginDrain(for: fixture.surfaceID, lane: .immediate))
        #expect(localBatch.metrics.offeredCount == UInt64(localSampleCount))
        #expect(fixture.accumulator.finishDrain(for: fixture.surfaceID, lane: .immediate) == .idle)
        #expect(fixture.accumulator.pendingSurfaceCount == 0)
        #expect(fixture.accumulator.retainedEntryCount == 0)
    }

    private func assertMixedPressurePublicationPaths(
        fixture: MixedAdmissionFixture,
        exactFactCount: Int
    ) async throws {
        let replay = await fixture.runtime.eventsSince(seq: 0)
        let replayFacts = commandFinishedFacts(from: replay.events)
        #expect(replayFacts == expectedCommandFinishedFacts(count: exactFactCount))

        await assertEventuallyAsync("runtime and EventBus subscribers should receive every exact fact") {
            let runtimeEventCount = await fixture.runtimeSubscriber.snapshot().count
            let eventBusEventCount = await fixture.eventBusSubscriber.snapshot().count
            return runtimeEventCount == exactFactCount && eventBusEventCount == exactFactCount
        }
        #expect(commandFinishedFacts(from: await fixture.runtimeSubscriber.snapshot()) == replayFacts)
        #expect(commandFinishedFacts(from: await fixture.eventBusSubscriber.snapshot()) == replayFacts)

        let eventBusDiagnostics = await fixture.eventBusHarness.bus.diagnosticsSnapshot()
        let deliveryDiagnostics = try #require(
            eventBusDiagnostics.activeSubscribers.first { $0.subscriberName == "mixedTerminalAdmission" }
        )
        #expect(deliveryDiagnostics.yieldedCount == UInt64(exactFactCount))
        #expect(deliveryDiagnostics.consumedCount == UInt64(exactFactCount))
        #expect(deliveryDiagnostics.pendingDeliveryCount == 0)
        #expect(deliveryDiagnostics.liveDroppedCount == 0)
        #expect(deliveryDiagnostics.replayDroppedCount == 0)

        let finalIPCSnapshot = try fixture.ipcAdapter.terminalSnapshot(fixture.paneHandle, ownPaneAssertion: nil)
        #expect(finalIPCSnapshot.lastSequence == UInt64(exactFactCount))
        let ipcWaitResult = try await fixture.ipcAdapter.waitForTerminal(
            fixture.paneHandle,
            condition: .commandFinished,
            timeout: .milliseconds(1),
            afterSequence: 0,
            ownPaneAssertion: nil
        )
        #expect(ipcWaitResult.eventName == .terminalCommandFinished)
        #expect(ipcWaitResult.exitCode == 0)
        #expect(ipcWaitResult.duration == 1)
    }

    @MainActor
    private struct MixedAdmissionFixture {
        let surfaceViewObjectID: ObjectIdentifier
        let surfaceID: UUID
        let pane: Pane
        let eventBusHarness: EventBusHarness<RuntimeEnvelope>
        let eventBusSubscriber: RecordingSubscriber<RuntimeEnvelope>
        let runtime: TerminalRuntime
        let runtimeSubscriber: RecordingSubscriber<RuntimeEnvelope>
        let runtimeRegistry: RuntimeRegistry
        let routingLookup: FakeActionRoutingLookup
        let ipcAdapter: AgentStudioIPCRuntimeAdapter
        let drainScheduleRecorder: MixedAdmissionDrainScheduleRecorder
        let accumulator: TerminalLocalActionAccumulator

        var paneHandle: IPCHandle {
            IPCHandle(kind: .pane, reference: .canonicalUUID(pane.id))
        }

        init(exactFactCapacity: Int) async {
            let surfaceViewObjectID = ObjectIdentifier(NSView(frame: .zero))
            let surfaceID = UUIDv7.generate()
            let workspaceStore = WorkspaceStore()
            let pane = workspaceStore.createPane(
                content: .terminal(
                    TerminalState(provider: .zmx, lifetime: .temporary, zmxSessionID: .generateUUIDv7())
                ),
                metadata: PaneMetadata(
                    launchDirectory: URL(filePath: "/tmp/mixed-admission"),
                    title: "Mixed admission"
                )
            )
            workspaceStore.appendTab(Tab(paneId: pane.id))
            workspaceStore.setActiveTab(workspaceStore.tabs[0].id)

            let paneID = PaneId(existingUUID: pane.id)
            let eventBusHarness = EventBusHarness<RuntimeEnvelope>()
            let eventBusSubscriber = await eventBusHarness.makeSubscriber(
                policy: .criticalUnbounded,
                subscriberName: "mixedTerminalAdmission"
            )
            let runtime = TerminalRuntime(
                paneId: paneID,
                metadata: PaneMetadata(paneId: paneID, contentType: .terminal, title: "Mixed admission"),
                replayBuffer: EventReplayBuffer(capacity: exactFactCapacity),
                paneEventBus: eventBusHarness.bus
            )
            let runtimeSubscriber = RecordingSubscriber(stream: runtime.subscribe())
            let runtimeRegistry = RuntimeRegistry()
            _ = runtimeRegistry.register(runtime)
            let routingLookup = FakeActionRoutingLookup(
                surfaceIdsByViewObjectId: [surfaceViewObjectID: surfaceID],
                paneIdsBySurfaceId: [surfaceID: pane.id]
            )
            let ipcAdapter = AgentStudioIPCRuntimeAdapter(
                workspaceStore: workspaceStore,
                runtimeRegistry: runtimeRegistry,
                commandDispatcher: SuccessfulRuntimeCommandDispatcher(),
                eventBus: eventBusHarness.bus
            )
            let drainScheduleRecorder = MixedAdmissionDrainScheduleRecorder()
            let accumulator = TerminalLocalActionAccumulator(scheduleDrain: drainScheduleRecorder.record)

            self.surfaceViewObjectID = surfaceViewObjectID
            self.surfaceID = surfaceID
            self.pane = pane
            self.eventBusHarness = eventBusHarness
            self.eventBusSubscriber = eventBusSubscriber
            self.runtime = runtime
            self.runtimeSubscriber = runtimeSubscriber
            self.runtimeRegistry = runtimeRegistry
            self.routingLookup = routingLookup
            self.ipcAdapter = ipcAdapter
            self.drainScheduleRecorder = drainScheduleRecorder
            self.accumulator = accumulator
        }

        func shutdown() async {
            await runtimeSubscriber.shutdown()
            await eventBusSubscriber.shutdown()
            _ = await runtime.shutdown(timeout: .zero)
            await assertBusDrained(eventBusHarness.bus)
        }
    }
}

private struct CommandFinishedFact: Equatable {
    let exitCode: Int
    let duration: UInt64
}

@MainActor
private struct SuccessfulRuntimeCommandDispatcher: PaneRuntimeCommandDispatching {
    func dispatchRuntimeCommand(
        _ command: PaneRuntimeCommand,
        target: RuntimeCommandTarget,
        correlationId: UUID?
    ) async -> ActionResult {
        .success(commandId: UUIDv7.generate())
    }
}

private final class MixedAdmissionDrainScheduleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID] = []

    var scheduledSurfaceIDs: [UUID] {
        lock.withLock { storage }
    }

    func record(_ surfaceID: UUID, _: TerminalLocalDrainRequest) {
        lock.withLock {
            storage.append(surfaceID)
        }
    }
}
