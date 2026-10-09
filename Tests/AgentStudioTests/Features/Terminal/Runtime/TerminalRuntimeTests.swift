import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("TerminalRuntime lifecycle", .serialized)
struct TerminalRuntimeTests {
    @Test("handleCommand rejects when lifecycle not ready")
    func rejectWhenNotReady() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        let commandEnvelope = makeEnvelope(command: .activate, paneId: runtime.paneId)
        let result = await runtime.handleCommand(commandEnvelope)
        #expect(result == .failure(.runtimeNotReady(lifecycle: .created)))
    }

    @Test("handleCommand succeeds after ready transition")
    func succeedsWhenReady() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()
        let commandEnvelope = makeEnvelope(command: .activate, paneId: runtime.paneId)
        let result = await runtime.handleCommand(commandEnvelope)
        switch result {
        case .success(let commandId):
            #expect(commandId == commandEnvelope.commandId)
        default:
            Issue.record("Expected success result for ready runtime")
        }
    }

    @Test("terminal commands fail when no surface is attached")
    func terminalCommandFailsWithoutSurface() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        let commandEnvelope = makeEnvelope(command: .terminal(.clearScrollback), paneId: runtime.paneId)
        let result = await runtime.handleCommand(commandEnvelope)
        #expect(result == .failure(.backendUnavailable(backend: "SurfaceManager")))
    }

    @Test("scrollToBottom terminal command fails without surface")
    func scrollToBottomTerminalCommandFailsWithoutSurface() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        let commandEnvelope = makeEnvelope(command: .terminal(.scrollToBottom), paneId: runtime.paneId)
        let result = await runtime.handleCommand(commandEnvelope)

        #expect(result == .failure(.backendUnavailable(backend: "SurfaceManager")))
    }

    @Test("fractional scroll fails without surface", arguments: [-0.9, 0.9, -0.33, 0.33])
    func fractionalScrollFailsWithoutSurface(fraction: Double) async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        let commandEnvelope = makeEnvelope(
            command: .terminal(.scrollPageFractional(fraction: fraction)), paneId: runtime.paneId)
        let result = await runtime.handleCommand(commandEnvelope)

        #expect(result == .failure(.backendUnavailable(backend: "SurfaceManager")))
    }

    @Test("fractional scroll reaches the exact terminal with its signed amount", arguments: [-0.9, 0.9, -0.33, 0.33])
    func fractionalScrollPreservesTargetAndAmount(fraction: Double) async {
        let surfaceDispatcher = RecordingTerminalSurfaceCommandDispatcher()
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"),
            surfaceCommandDispatcher: surfaceDispatcher
        )
        runtime.transitionToReady()
        let commandEnvelope = makeEnvelope(
            command: .terminal(.scrollPageFractional(fraction: fraction)), paneId: runtime.paneId
        )

        let result = await runtime.handleCommand(commandEnvelope)

        #expect(result == .success(commandId: commandEnvelope.commandId))
        #expect(surfaceDispatcher.recordedOperations == [.scrollPageFractional(runtime.paneId.uuid, fraction)])
    }

    @Test("jumpToPrompt terminal command fails without surface")
    func jumpToPromptTerminalCommandFailsWithoutSurface() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        let commandEnvelope = makeEnvelope(command: .terminal(.jumpToPrompt(delta: -1)), paneId: runtime.paneId)
        let result = await runtime.handleCommand(commandEnvelope)

        #expect(result == .failure(.backendUnavailable(backend: "SurfaceManager")))
    }

    @Test("non-terminal command families are rejected as unsupported")
    func rejectsUnsupportedCommandFamilies() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        let browserCommand = makeEnvelope(
            command: .browser(.reload(hard: false)),
            paneId: runtime.paneId
        )
        let result = await runtime.handleCommand(browserCommand)

        switch result {
        case .failure(.unsupportedCommand(let command, let requiredCapability)):
            #expect(command.contains("browser"))
            #expect(requiredCapability == browserCommand.command.requiredCapability)
        default:
            Issue.record("Expected unsupported command failure for browser command")
        }
    }

    @Test("prepareForClose transitions runtime to draining and rejects follow-up command")
    func prepareForCloseTransitionsToDraining() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        let closeEnvelope = makeEnvelope(command: .prepareForClose, paneId: runtime.paneId)
        let closeResult = await runtime.handleCommand(closeEnvelope)
        #expect(closeResult == .success(commandId: closeEnvelope.commandId))
        #expect(runtime.lifecycle == .draining)

        let followupEnvelope = makeEnvelope(command: .terminal(.sendInput("echo hi")), paneId: runtime.paneId)
        let followupResult = await runtime.handleCommand(followupEnvelope)
        #expect(followupResult == .failure(.runtimeNotReady(lifecycle: .draining)))
    }

    @Test("terminal send writes input without focus side effects")
    func terminalSendWritesInputWithoutFocusSideEffects() async {
        let surfaceDispatcher = RecordingTerminalSurfaceCommandDispatcher()
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"),
            surfaceCommandDispatcher: surfaceDispatcher
        )
        runtime.transitionToReady()

        let commandEnvelope = makeEnvelope(command: .terminal(.sendInput("echo hi\r")), paneId: runtime.paneId)
        let result = await runtime.handleCommand(commandEnvelope)

        #expect(result == .success(commandId: commandEnvelope.commandId))
        #expect(
            surfaceDispatcher.recordedOperations == [
                .sendInput(runtime.paneId.uuid, "echo hi\r")
            ])
    }

    @Test("eventsSince replays emitted events")
    func replaysEvents() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()
        runtime.handleGhosttyEvent(.bellRang)
        runtime.handleGhosttyEvent(.titleChanged("Build"))

        let replay = await runtime.eventsSince(seq: 0)

        #expect(!replay.gapDetected)
        #expect(replay.events.count == 2)
        #expect(replay.nextSeq == 2)
    }

    @Test("handleGhosttyEvent updates metadata and preserves envelope identifiers")
    func ghosttyEventMetadataAndEnvelope() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        let commandId = UUID()
        let correlationId = UUID()
        runtime.handleGhosttyEvent(.titleChanged("Updated"), commandId: commandId, correlationId: correlationId)
        runtime.handleGhosttyEvent(.cwdChanged("/tmp"), commandId: commandId, correlationId: correlationId)

        #expect(runtime.metadata.title == "Updated")
        #expect(runtime.metadata.cwd == URL(fileURLWithPath: "/tmp"))

        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.count == 2)
        #expect(
            replay.events.allSatisfy { envelope in
                guard case .pane(let paneEnvelope) = envelope else { return false }
                return paneEnvelope.commandId == commandId
            }
        )
        #expect(
            replay.events.allSatisfy { envelope in
                guard case .pane(let paneEnvelope) = envelope else { return false }
                return paneEnvelope.correlationId == correlationId
            }
        )
        guard
            let lastEvent = replay.events.last,
            case .pane(let paneEnvelope) = lastEvent,
            case .terminal(.cwdChanged(let cwdPath)) = paneEnvelope.event
        else {
            Issue.record("Expected replay to include terminal cwdChanged event")
            return
        }
        #expect(URL(fileURLWithPath: cwdPath) == URL(fileURLWithPath: "/tmp"))
    }

    @Test("eventsSince reports gap after replay eviction")
    func replayGapAfterEviction() async {
        let replayBuffer = EventReplayBuffer(config: .init(maxEvents: 2, maxBytes: 10_000, ttl: .seconds(300)))
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"),
            replayBuffer: replayBuffer, surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()
        runtime.handleGhosttyEvent(.bellRang)
        runtime.handleGhosttyEvent(.bellRang)
        runtime.handleGhosttyEvent(.bellRang)

        let replay = await runtime.eventsSince(seq: 0)

        #expect(replay.gapDetected)
        #expect(replay.events.count == 2)
        #expect(replay.events.first?.seq == 2)
    }

    @Test("action events emit to subscribers but are not persisted in replay")
    func actionEventsBypassReplayBuffer() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()
        var iterator = runtime.subscribe().makeAsyncIterator()

        runtime.handleGhosttyEvent(.newTab)
        let streamedEnvelope = await iterator.next()

        guard let streamedEnvelope else {
            Issue.record("Expected streamed envelope for action event")
            return
        }
        guard
            case .pane(let paneEnvelope) = streamedEnvelope,
            case .terminal(.newTab) = paneEnvelope.event
        else {
            Issue.record("Expected streamed newTab runtime event")
            return
        }

        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.isEmpty)
        #expect(replay.nextSeq == 0)
        #expect(!replay.gapDetected)
    }

    @Test("local geometry state stays local while semantic state remains replayable")
    func localGeometryState_staysOutOfRuntimeEvents() async {
        let harness = EventBusHarness<RuntimeEnvelope>()
        let subscriber = await harness.makeSubscriber()
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"),
            paneEventBus: harness.bus, surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        let expectedProgress = ProgressState(kind: .set, percent: 50)
        let expectedCellSize = NSSize(width: 8, height: 16)
        let expectedSizeConstraints = TerminalSizeConstraints(
            minWidth: 640,
            minHeight: 480,
            maxWidth: 1440,
            maxHeight: 900
        )

        runtime.handleGhosttyEvent(.progressReportUpdated(expectedProgress))
        runtime.handleGhosttyEvent(.rendererHealthChanged(healthy: false))
        runtime.handleGhosttyEvent(.cellSizeChanged(expectedCellSize))
        runtime.handleGhosttyEvent(.sizeLimitChanged(expectedSizeConstraints))

        #expect(runtime.commandProgress == expectedProgress)
        #expect(!runtime.rendererHealthy)
        #expect(runtime.cellSize == expectedCellSize)
        #expect(runtime.sizeConstraints == expectedSizeConstraints)

        await assertEventuallyAsync(
            "subscriber should receive replayable state events",
            minimumTurns: 5000
        ) {
            await subscriber.snapshot().count == 2
        }

        let streamedEvents = RuntimeEnvelopeHarness.paneEvents(from: await subscriber.snapshot())
        #expect(streamedEvents.map(\.seq) == [1, 2])
        #expect(
            streamedEvents.contains(where: { record in
                guard case .terminal(.progressReportUpdated(let progress)) = record.event else { return false }
                return progress == expectedProgress
            }))
        #expect(
            streamedEvents.contains(where: { record in
                guard case .terminal(.rendererHealthChanged(let healthy)) = record.event else { return false }
                return healthy == false
            }))
        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.count == 2)

        await subscriber.shutdown()
        await assertBusDrained(harness.bus)
    }

    @Test("readOnly updates observable state and posts replayable event")
    func readOnly_postsReplayableBusEvent() async {
        let paneEventBus = EventBus<RuntimeEnvelope>()
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"),
            paneEventBus: paneEventBus, surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()
        let stream = await paneEventBus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        runtime.handleGhosttyEvent(.readOnlyChanged(true))

        #expect(runtime.isReadOnly)
        guard
            let busEnvelope = await iterator.next(),
            case .pane(let paneEnvelope) = busEnvelope,
            case .terminal(.readOnlyChanged(let isReadOnly)) = paneEnvelope.event
        else {
            Issue.record("Expected readOnlyChanged event on pane bus")
            return
        }
        #expect(isReadOnly)

        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.count == 1)
    }

    @Test("mouse events update observable runtime state")
    func mouseEventsUpdateObservableRuntimeState() {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        runtime.handleGhosttyEvent(.mouseShapeChanged(shape: .pointer))
        runtime.handleGhosttyEvent(.mouseVisibilityChanged(isVisible: false))

        #expect(runtime.mouseShape == .pointer)
        #expect(runtime.isMouseVisible == false)
    }

    @Test("promptTitle posts to bus but is not replayed")
    func promptTitle_postsNonReplayableBusEvent() async {
        let paneEventBus = EventBus<RuntimeEnvelope>()
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"),
            paneEventBus: paneEventBus, surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()
        let stream = await paneEventBus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        runtime.handleGhosttyEvent(.promptTitleRequested(scope: .surface))
        guard
            let busEnvelope = await iterator.next(),
            case .pane(let paneEnvelope) = busEnvelope,
            case .terminal(.promptTitleRequested(let scope)) = paneEnvelope.event
        else {
            Issue.record("Expected promptTitleRequested event on pane bus")
            return
        }
        #expect(scope == .surface)

        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.isEmpty)
    }

    @Test("non-replayable terminal request events still post to the bus")
    func nonReplayableTerminalRequestEvents_postWithoutReplay() async {
        let harness = EventBusHarness<RuntimeEnvelope>()
        let subscriber = await harness.makeSubscriber()
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"),
            paneEventBus: harness.bus,
            surfaceCommandDispatcher: TerminalFixtureSurfaceCommands(), openExternalURL: { _ in }
        )
        runtime.transitionToReady()

        let initialSize = NSSize(width: 80, height: 25)
        runtime.handleGhosttyEvent(.openURLRequested(url: "https://example.com", kind: .text))
        runtime.handleGhosttyEvent(.undoRequested)
        runtime.handleGhosttyEvent(.redoRequested)
        runtime.handleGhosttyEvent(.copyTitleToClipboardRequested)
        runtime.handleGhosttyEvent(.initialSizeChanged(initialSize))

        await assertEventuallyAsync(
            "subscriber should receive non-replayable request events",
            minimumTurns: 5000
        ) {
            await subscriber.snapshot().count == 4
        }

        let streamedEvents = RuntimeEnvelopeHarness.paneEvents(from: await subscriber.snapshot())
        #expect(streamedEvents.map(\.seq) == [1, 2, 3, 4])
        #expect(
            streamedEvents.contains(where: { record in
                guard case .terminal(.openURLRequested(let url, let kind)) = record.event else { return false }
                return url == "https://example.com" && kind == .text
            }))
        #expect(
            streamedEvents.contains(where: { record in
                guard case .terminal(.undoRequested) = record.event else { return false }
                return true
            }))
        #expect(
            streamedEvents.contains(where: { record in
                guard case .terminal(.redoRequested) = record.event else { return false }
                return true
            }))
        #expect(
            streamedEvents.contains(where: { record in
                guard case .terminal(.copyTitleToClipboardRequested) = record.event else { return false }
                return true
            }))
        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.isEmpty)

        await subscriber.shutdown()
        await assertBusDrained(harness.bus)
    }

    @Test("local presentation state does not enter replay")
    func localPresentationState_staysOutOfRuntimeEvents() async {
        let harness = EventBusHarness<RuntimeEnvelope>()
        let subscriber = await harness.makeSubscriber()
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"),
            paneEventBus: harness.bus, surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        let scrollbar = ScrollbarState(top: 5, bottom: 15, total: 100)
        let colorChange = TerminalColorChange(kind: .foreground, red: 1, green: 2, blue: 3)

        runtime.handleGhosttyEvent(.tabTitleChanged("Build"))
        runtime.handleGhosttyEvent(.scrollbarChanged(scrollbar))
        runtime.handleGhosttyEvent(.searchStarted(query: "needle"))
        runtime.handleGhosttyEvent(.searchMatchesUpdated(totalMatches: 4))
        runtime.handleGhosttyEvent(.searchSelectionChanged(selectedMatchIndex: 2))
        runtime.handleGhosttyEvent(.colorChanged(colorChange))
        runtime.handleGhosttyEvent(.configChanged)

        #expect(runtime.metadata.title == "Build")
        #expect(runtime.scrollbarState == scrollbar)
        #expect(runtime.searchLifecycleState == .active(query: "needle", epoch: 1))
        #expect(runtime.searchState == TerminalSearchState(query: "needle", totalMatches: 4, selectedMatchIndex: 2))

        await assertEventuallyAsync(
            "subscriber should receive the changed exact title fact",
            minimumTurns: 5000
        ) {
            await subscriber.snapshot().count == 1
        }

        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.count == 1)

        await subscriber.shutdown()
        await assertBusDrained(harness.bus)
    }

    @Test("searchEnded clears local state without replay")
    func searchEnded_clearsLocalStateWithoutReplay() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        runtime.handleGhosttyEvent(.searchStarted(query: "needle"))
        runtime.handleGhosttyEvent(.searchEnded)

        #expect(runtime.searchLifecycleState == .inactive(lastEndedEpoch: 1))
        #expect(runtime.searchState == nil)

        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.isEmpty)
    }

    @Test("local transient events stay out of bus while config reload remains exact")
    func localTransientEvents_stayOutOfRuntimeEvents() async {
        let harness = EventBusHarness<RuntimeEnvelope>()
        let subscriber = await harness.makeSubscriber()
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"),
            paneEventBus: harness.bus, surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        runtime.handleGhosttyEvent(.mouseShapeChanged(shape: .pointer))
        runtime.handleGhosttyEvent(.mouseVisibilityChanged(isVisible: false))
        runtime.handleGhosttyEvent(.mouseLinkHovered(url: "https://example.com"))
        runtime.handleGhosttyEvent(
            .keySequenceChanged(
                active: true,
                trigger: GhosttyInputTrigger(tag: .unicode, key: 97, modifiers: 0)
            )
        )
        runtime.handleGhosttyEvent(.keyTableChanged(.activate(name: "copy-mode")))
        runtime.handleGhosttyEvent(.configReloadRequested(soft: true))

        await assertEventuallyAsync(
            "subscriber should receive promoted deferred transient events",
            minimumTurns: 5000
        ) {
            await subscriber.snapshot().count == 1
        }

        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.isEmpty)

        await subscriber.shutdown()
        await assertBusDrained(harness.bus)
    }

    @Test("deferred events stay out of bus and replay")
    func deferredEvent_doesNotPostOrReplay() async {
        let paneEventBus = EventBus<RuntimeEnvelope>()
        let subscriber = RecordingSubscriber(
            subscription: await paneEventBus.subscribe(
                policy: .lossyNewest(BusSubscriberPolicy.standardLossyBufferLimit),
                subscriberName: #function
            )
        )
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"),
            paneEventBus: paneEventBus, surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        runtime.handleGhosttyEvent(.deferred(tag: UInt32(GHOSTTY_ACTION_RENDER.rawValue)))

        let replay = await runtime.eventsSince(seq: 0)
        #expect(replay.events.isEmpty)

        await Task.yield()
        #expect(await subscriber.snapshot().isEmpty)
        await subscriber.shutdown()
        await assertBusDrained(paneEventBus)
    }

    @Test("subscribe returns independent streams and broadcasts events to all subscribers")
    func subscribeBroadcastsToMultipleSubscribers() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()

        var firstIterator = runtime.subscribe().makeAsyncIterator()
        var secondIterator = runtime.subscribe().makeAsyncIterator()

        runtime.handleGhosttyEvent(.bellRang)

        let firstEvent = await firstIterator.next()
        let secondEvent = await secondIterator.next()

        #expect(firstEvent?.seq == 1)
        #expect(secondEvent?.seq == 1)

        guard let firstEvent, let secondEvent else {
            Issue.record("Expected both subscribers to receive runtime event")
            return
        }

        guard
            case .pane(let firstPaneEnvelope) = firstEvent,
            case .terminal(.bellRang) = firstPaneEnvelope.event
        else {
            Issue.record("Expected bellRang terminal event for first subscriber")
            return
        }
        guard
            case .pane(let secondPaneEnvelope) = secondEvent,
            case .terminal(.bellRang) = secondPaneEnvelope.event
        else {
            Issue.record("Expected bellRang terminal event for second subscriber")
            return
        }
    }

    @Test("shutdown finishes event stream")
    func shutdownFinishesEventStream() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()
        var iterator = runtime.subscribe().makeAsyncIterator()

        _ = await runtime.shutdown(timeout: .seconds(1))
        let nextEvent = await iterator.next()

        #expect(runtime.lifecycle == .terminated)
        #expect(nextEvent == nil)
    }

    @Test("commands are rejected after shutdown")
    func rejectCommandsAfterShutdown() async {
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Runtime"), surfaceCommandDispatcher: TerminalFixtureSurfaceCommands()
        )
        runtime.transitionToReady()
        _ = await runtime.shutdown(timeout: .seconds(1))

        let commandEnvelope = makeEnvelope(command: .activate, paneId: runtime.paneId)
        let result = await runtime.handleCommand(commandEnvelope)

        #expect(result == .failure(.runtimeNotReady(lifecycle: .terminated)))
    }

    private func makeEnvelope(command: PaneRuntimeCommand, paneId: PaneId) -> RuntimeCommandEnvelope {
        let clock = ContinuousClock()
        return RuntimeCommandEnvelope(
            commandId: UUID(),
            correlationId: nil,
            targetPaneId: paneId,
            command: command,
            timestamp: clock.now
        )
    }
}

@MainActor
private final class RecordingTerminalSurfaceCommandDispatcher: TerminalSurfaceCommandDispatching {
    enum Operation: Equatable {
        case sendInput(UUID, String)
        case clearScrollback(UUID)
        case scrollToBottom(UUID)
        case scrollPageFractional(UUID, Double)
        case jumpToPrompt(UUID, Int)
    }

    private(set) var recordedOperations: [Operation] = []

    func sendInput(_ input: String, toPaneId paneId: UUID) -> Result<Void, SurfaceError> {
        recordedOperations.append(.sendInput(paneId, input))
        return .success(())
    }

    func clearScrollback(forPaneId paneId: UUID) -> Result<Void, SurfaceError> {
        recordedOperations.append(.clearScrollback(paneId))
        return .success(())
    }

    func scrollToBottom(forPaneId paneId: UUID) -> Result<Void, SurfaceError> {
        recordedOperations.append(.scrollToBottom(paneId))
        return .success(())
    }

    func scrollPageFractional(fraction: Double, forPaneId paneId: UUID) -> Result<Void, SurfaceError> {
        recordedOperations.append(.scrollPageFractional(paneId, fraction))
        return .success(())
    }

    func jumpToPrompt(delta: Int, forPaneId paneId: UUID) -> Result<Void, SurfaceError> {
        recordedOperations.append(.jumpToPrompt(paneId, delta))
        return .success(())
    }
}
