import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioWebview

@MainActor
@Suite("WebviewRuntime lifecycle")
struct WebviewRuntimeTests {
    @Test("webview runtime posts browser events to EventBus and replay")
    func webviewRuntimePostsEvents() async {
        let paneEventBus = EventBus<RuntimeEnvelope>()
        let runtime = makeRuntime(paneEventBus: paneEventBus)
        runtime.transitionToReady()

        let busStream = await paneEventBus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var busIterator = busStream.makeAsyncIterator()
        runtime.ingestBrowserEvent(.pageLoaded(url: URL(string: "https://example.com")!))

        let busEnvelope = await busIterator.next()
        let replay = await runtime.eventsSince(seq: 0)

        #expect(busEnvelope?.source == .pane(runtime.paneId))
        #expect(busEnvelope?.seq == 1)
        #expect(replay.events.count == 1)
        #expect(replay.nextSeq == 1)
        #expect(!replay.gapDetected)
    }

    @Test("handleCommand rejects when runtime is not ready")
    func handleCommandRejectsWhenNotReady() async {
        let runtime = makeRuntime()
        let envelope = makeEnvelope(command: .activate, paneId: runtime.paneId)

        let result = await runtime.handleCommand(envelope)

        #expect(result == .failure(.runtimeNotReady(lifecycle: .created)))
    }

    @Test("shutdown finishes subscriber streams")
    func shutdownFinishesSubscriberStreams() async {
        let runtime = makeRuntime()
        runtime.transitionToReady()
        var iterator = runtime.subscribe().makeAsyncIterator()

        _ = await runtime.shutdown(timeout: .seconds(1))
        let nextEvent = await iterator.next()

        #expect(runtime.lifecycle == .terminated)
        #expect(nextEvent == nil)
    }

    @Test("prepareForClose transitions lifecycle to draining and rejects follow-up commands")
    func prepareForCloseTransitionsLifecycleToDraining() async {
        let runtime = makeRuntime()
        runtime.transitionToReady()

        let prepareEnvelope = makeEnvelope(command: .prepareForClose, paneId: runtime.paneId)
        let prepareResult = await runtime.handleCommand(prepareEnvelope)
        let followupResult = await runtime.handleCommand(
            makeEnvelope(command: .activate, paneId: runtime.paneId)
        )

        #expect(prepareResult == .success(commandId: prepareEnvelope.commandId))
        #expect(runtime.lifecycle == .draining)
        #expect(followupResult == .failure(.runtimeNotReady(lifecycle: .draining)))
    }

    @Test("ingestBrowserEvent after termination is dropped")
    func ingestBrowserEventAfterTerminationIsDropped() async {
        let runtime = makeRuntime()
        runtime.transitionToReady()

        _ = await runtime.shutdown(timeout: .seconds(1))
        let sequenceBefore = runtime.snapshot().lastSeq
        runtime.ingestBrowserEvent(.pageLoaded(url: URL(string: "https://example.com")!))
        let sequenceAfter = runtime.snapshot().lastSeq
        let replay = await runtime.eventsSince(seq: 0)

        #expect(sequenceBefore == sequenceAfter)
        #expect(replay.events.isEmpty)
    }

    @Test("handleCommand forwards browser commands to webview controller handler")
    func handleCommandForwardsBrowserCommands() async {
        let handler = WebviewRuntimeCommandHandlerSpy()
        let runtime = makeRuntime(commandHandler: handler)
        runtime.transitionToReady()

        let navigateCommandId = UUID()
        let navigateEnvelope = RuntimeCommandEnvelope(
            commandId: navigateCommandId,
            correlationId: nil,
            targetPaneId: runtime.paneId,
            command: .browser(.navigate(url: URL(string: "https://example.com/runtime-command")!)),
            timestamp: ContinuousClock().now
        )
        let navigateResult = await runtime.handleCommand(navigateEnvelope)

        let reloadCommandId = UUID()
        let reloadEnvelope = RuntimeCommandEnvelope(
            commandId: reloadCommandId,
            correlationId: nil,
            targetPaneId: runtime.paneId,
            command: .browser(.reload(hard: false)),
            timestamp: ContinuousClock().now
        )
        let reloadResult = await runtime.handleCommand(reloadEnvelope)

        #expect(navigateResult == .success(commandId: navigateCommandId))
        #expect(reloadResult == .success(commandId: reloadCommandId))
        #expect(handler.invocations == ["navigate:https://example.com/runtime-command", "reload:soft"])
    }

    private func makeRuntime(
        commandHandler: (any WebviewRuntimeCommandHandling)? = nil,
        paneEventBus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared
    ) -> WebviewRuntime {
        let paneId = PaneId.generateUUIDv7()
        let metadata = PaneMetadata(
            paneId: paneId,
            contentType: .browser,
            title: "Web"
        )
        return WebviewRuntime(
            paneId: paneId,
            metadata: metadata,
            commandHandler: commandHandler,
            paneEventBus: paneEventBus
        )
    }

    private func makeEnvelope(command: PaneRuntimeCommand, paneId: PaneId) -> RuntimeCommandEnvelope {
        RuntimeCommandEnvelope(
            commandId: UUID(),
            correlationId: nil,
            targetPaneId: paneId,
            command: command,
            timestamp: ContinuousClock().now
        )
    }
}

@MainActor
private final class WebviewRuntimeCommandHandlerSpy: WebviewRuntimeCommandHandling {
    private(set) var invocations: [String] = []

    func handleBrowserCommand(_ command: BrowserCommand) -> Bool {
        switch command {
        case .navigate(let url):
            invocations.append("navigate:\(url.absoluteString)")
        case .reload(let hard):
            invocations.append(hard ? "reload:hard" : "reload:soft")
        case .stop:
            invocations.append("stop")
        case .showTabs:
            invocations.append("showTabs")
        }
        return true
    }
}
