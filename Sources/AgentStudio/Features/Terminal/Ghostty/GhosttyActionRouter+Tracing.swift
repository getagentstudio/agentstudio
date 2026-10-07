import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

final class GhosttyActionTraceQueueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: AgentStudioTraceEventQueue?

    func bind(_ runtime: AgentStudioTraceRuntime?) {
        lock.lock()
        let previousQueue = queue
        queue = runtime.map(AgentStudioTraceEventQueue.init(traceRuntime:))
        lock.unlock()
        previousQueue?.cancel()
    }

    func record(
        tag: AgentStudioTraceTag,
        body: String,
        attributes: [String: AgentStudioTraceValue]
    ) {
        lock.lock()
        let queue = queue
        lock.unlock()
        queue?.record(tag: tag, body: body, attributes: attributes)
    }

    func drain() async throws {
        let queue = takeQueue()
        try await queue?.drain()
    }

    private func takeQueue() -> AgentStudioTraceEventQueue? {
        lock.lock()
        let queue = queue
        self.queue = nil
        lock.unlock()
        return queue
    }
}

extension Ghostty.ActionRouter {
    static func recordTerminalEqualSuppressed(
        publicationKind: TerminalPerformancePublicationKind
    ) {
        actionTraceQueueStore.record(
            tag: .performance,
            body: "performance.terminal.equal_suppressed",
            attributes: [
                "agentstudio.performance.terminal.publication.kind": .string(
                    publicationKind.rawValue
                ),
                "agentstudio.performance.terminal.equal_suppressed.count": .int(1),
            ]
        )
    }

    enum GhosttyTraceSignalClass: String, Sendable {
        case semantic
        case inferred
        case context
        case deferred
        case unhandled
    }

    static func traceGhosttyAction(
        body: String,
        actionTag: UInt32,
        payload: GhosttyAdapter.ActionPayload? = nil,
        event: GhosttyEvent? = nil,
        paneId: UUID? = nil,
        surfaceId: UUID? = nil,
        signalClass: GhosttyTraceSignalClass,
        routeResult: Bool?,
        reason: String?
    ) {
        guard !isHighVolumeTraceAction(actionTag) else { return }
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.ghostty.action.tag": .int(Int(actionTag)),
            "agentstudio.ghostty.signal.class": .string(signalClass.rawValue),
        ]
        if let actionName = GhosttyActionTag(rawValue: actionTag).map({ String(describing: $0) }) {
            attributes["agentstudio.ghostty.action.name"] = .string(actionName)
        }
        if let payload {
            attributes["agentstudio.ghostty.action.payload"] = .string(payloadTraceName(payload))
        }
        if let event {
            attributes["agentstudio.runtime.event"] = .string(event.traceEventName)
        }
        if let paneId {
            attributes["agentstudio.pane.id"] = .string(paneId.uuidString)
        }
        if let surfaceId {
            attributes["agentstudio.surface.id"] = .string(surfaceId.uuidString)
        }
        if let routeResult {
            attributes["agentstudio.ghostty.route.result"] = .bool(routeResult)
        }
        if let reason {
            attributes["agentstudio.ghostty.route.reason"] = .string(reason)
        }
        actionTraceQueueStore.record(
            tag: .terminalSignal,
            body: body,
            attributes: attributes
        )
    }

    static func isHighVolumeTraceAction(_ actionTag: UInt32) -> Bool {
        guard let actionTag = GhosttyActionTag(rawValue: actionTag) else { return false }
        switch actionTag {
        case .scrollbar, .render, .mouseShape, .mouseVisibility, .mouseOverLink, .keySequence:
            return true
        default:
            return false
        }
    }

    static func signalClass(
        for event: GhosttyEvent,
        fallbackActionTag actionTag: UInt32
    ) -> GhosttyTraceSignalClass {
        switch event {
        case .unhandled:
            return .unhandled
        case .deferred:
            return .deferred
        case .scrollbarChanged:
            return .inferred
        default:
            return GhosttyActionTag(rawValue: actionTag).map(signalClass(for:)) ?? .unhandled
        }
    }

    static func signalClass(for actionTag: GhosttyActionTag) -> GhosttyTraceSignalClass {
        if interceptedTags.contains(actionTag) {
            return .deferred
        }
        if deferredTags.contains(actionTag) {
            return .deferred
        }

        switch actionTag {
        case .desktopNotification, .ringBell, .commandFinished, .progressReport, .rendererHealth, .secureInput,
            .openURL, .readOnly:
            return .semantic
        case .scrollbar:
            return .inferred
        case .quit, .newWindow, .closeAllWindows, .toggleMaximize, .toggleFullscreen, .toggleTabOverview,
            .toggleWindowDecorations, .toggleQuickTerminal, .toggleCommandPalette, .toggleVisibility,
            .toggleBackgroundOpacity, .gotoWindow, .presentTerminal, .resetWindowSize, .resizeWindow, .inspector,
            .render,
            .showGtkInspector, .renderInspector, .openConfig, .quitTimer, .floatWindow, .closeWindow,
            .checkForUpdates, .showChildExited, .showOnScreenKeyboard:
            return .deferred
        case .newTab, .setTitle, .setTabTitle, .pwd, .newSplit, .gotoSplit, .resizeSplit, .equalizeSplits,
            .toggleSplitZoom, .closeTab, .gotoTab, .moveTab, .sizeLimit, .initialSize, .cellSize,
            .promptTitle, .mouseShape, .mouseVisibility, .mouseOverLink, .keySequence, .keyTable, .colorChange,
            .reloadConfig, .configChange, .undo, .redo, .startSearch, .endSearch, .searchTotal,
            .searchSelected, .copyTitleToClipboard:
            return .context
        case .exportTerminalIO, .setWindowTitle, .selectionChanged, .moveTabToNewWindow:
            return .deferred
        }
    }

    static func payloadTraceName(_ payload: GhosttyAdapter.ActionPayload) -> String {
        let description = String(describing: payload)
        return description.split(separator: "(", maxSplits: 1).first.map(String.init) ?? description
    }
}
