import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Synchronization

final class GhosttyActionTraceQueueStore: Sendable {
    private struct State: Sendable {
        var queue: AgentStudioTraceEventQueue?
    }

    private let state: Mutex<State>

    init(traceRuntime: AgentStudioTraceRuntime? = nil) {
        state = Mutex(State(queue: traceRuntime.map(AgentStudioTraceEventQueue.init(traceRuntime:))))
    }

    func record(
        tag: AgentStudioTraceTag,
        body: String,
        attributes: [String: AgentStudioTraceValue]
    ) {
        let queue = state.withLock { $0.queue }
        queue?.record(tag: tag, body: body, attributes: attributes)
    }

    func drain() async throws {
        let queue = takeQueue()
        try await queue?.drain()
    }

    private func takeQueue() -> AgentStudioTraceEventQueue? {
        state.withLock { storage in
            let queue = storage.queue
            storage.queue = nil
            return queue
        }
    }
}

extension Ghostty.ActionRouter {
    enum GhosttyTraceSignalClass: String, Sendable {
        case semantic
        case inferred
        case context
        case deferred
        case unhandled
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

    static func payloadTraceName(_ payload: GhosttyActionPayload) -> String {
        let description = String(describing: payload)
        return description.split(separator: "(", maxSplits: 1).first.map(String.init) ?? description
    }
}
