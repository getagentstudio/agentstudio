import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import os.log

let ghosttyAdapterLogger = Logger(subsystem: "com.agentstudio", category: "GhosttyAdapter")

/// Pure copied-payload translation and TerminalRuntime delivery.
enum GhosttyActionTranslation {
    private static let interceptOnlyTags: Set<GhosttyActionTag> = [
        .quit,
        .newWindow,
        .closeAllWindows,
        .toggleMaximize,
        .toggleFullscreen,
        .toggleTabOverview,
        .toggleWindowDecorations,
        .toggleQuickTerminal,
        .toggleCommandPalette,
        .toggleVisibility,
        .toggleBackgroundOpacity,
        .gotoWindow,
        .presentTerminal,
        .resetWindowSize,
        .resizeWindow,
        .inspector,
        .showGtkInspector,
        .renderInspector,
        .openConfig,
        .quitTimer,
        .floatWindow,
        .closeWindow,
        .checkForUpdates,
        .showChildExited,
        .showOnScreenKeyboard,
        .render,
        .exportTerminalIO,
        .setWindowTitle,
        .selectionChanged,
        .moveTabToNewWindow,
    ]

    static func translate(
        actionTag: UInt32,
        payload: GhosttyActionPayload = .noPayload
    ) -> GhosttyEvent {
        guard let knownActionTag = GhosttyActionTag(rawValue: actionTag) else {
            return .unhandled(tag: actionTag)
        }
        return translate(actionTag: knownActionTag, payload: payload)
    }

    static func translate(
        actionTag: GhosttyActionTag,
        payload: GhosttyActionPayload = .noPayload
    ) -> GhosttyEvent {
        if Self.interceptOnlyTags.contains(actionTag) {
            return .unhandled(tag: actionTag.rawValue)
        }

        if let coreEvent = translateCoreAction(actionTag: actionTag, payload: payload) {
            return coreEvent
        }

        if let observedEvent = translateObservedAction(actionTag: actionTag, payload: payload) {
            return observedEvent
        }

        preconditionFailure("translate(actionTag:) missing routed case for \(actionTag)")
    }

    @MainActor
    static func route(
        actionTag: UInt32,
        payload: GhosttyActionPayload = .noPayload,
        to runtime: TerminalRuntime
    ) {
        let event = translate(actionTag: actionTag, payload: payload)
        let commandFinishedSourceInstant: ContinuousClock.Instant?
        if case .commandFinished(_, _, let sourceInstant) = payload {
            commandFinishedSourceInstant = sourceInstant
        } else {
            commandFinishedSourceInstant = nil
        }
        if case .unhandled(let unhandledTag) = event {
            ghosttyAdapterLogger.warning(
                "Unhandled Ghostty action tag \(unhandledTag) payload=\(String(describing: payload), privacy: .public)"
            )
        }
        runtime.handleGhosttyEvent(event, commandFinishedSourceInstant: commandFinishedSourceInstant)
    }

    static func translateCoreAction(
        actionTag: GhosttyActionTag,
        payload: GhosttyActionPayload
    ) -> GhosttyEvent? {
        switch actionTag {
        case .ringBell:
            return .bellRang
        case .setTitle:
            return translateSetTitle(payload: payload, actionTag: actionTag)
        case .setTabTitle:
            return translateSetTabTitle(payload: payload, actionTag: actionTag)
        case .pwd:
            return translatePwd(payload: payload, actionTag: actionTag)
        case .commandFinished:
            return translateCommandFinished(payload: payload, actionTag: actionTag)
        case .newTab:
            return .newTab
        case .closeTab:
            return translateCloseTab(payload: payload, actionTag: actionTag)
        case .gotoTab:
            return translateGotoTab(payload: payload, actionTag: actionTag)
        case .moveTab:
            return translateMoveTab(payload: payload, actionTag: actionTag)
        case .newSplit:
            return translateNewSplit(payload: payload, actionTag: actionTag)
        case .gotoSplit:
            return translateGotoSplit(payload: payload, actionTag: actionTag)
        case .resizeSplit:
            return translateResizeSplit(payload: payload, actionTag: actionTag)
        case .equalizeSplits:
            return .equalizeSplits
        case .toggleSplitZoom:
            return .toggleSplitZoom
        default:
            return nil
        }
    }

    static func translateObservedAction(
        actionTag: GhosttyActionTag,
        payload: GhosttyActionPayload
    ) -> GhosttyEvent? {
        if let viewportEvent = translateViewportOrDisplayAction(actionTag: actionTag, payload: payload) {
            return viewportEvent
        }
        if let controlEvent = translateControlAction(actionTag: actionTag, payload: payload) {
            return controlEvent
        }
        if let searchEvent = translateSearchAction(actionTag: actionTag, payload: payload) {
            return searchEvent
        }
        return translateClipboardOrReadonlyAction(actionTag: actionTag, payload: payload)
    }

    static func translateViewportOrDisplayAction(
        actionTag: GhosttyActionTag,
        payload: GhosttyActionPayload
    ) -> GhosttyEvent? {
        switch actionTag {
        case .sizeLimit:
            return translateSizeLimit(payload: payload, actionTag: actionTag)
        case .initialSize:
            return translateInitialSize(payload: payload, actionTag: actionTag)
        case .cellSize:
            return translateCellSize(payload: payload, actionTag: actionTag)
        case .scrollbar:
            return translateScrollbar(payload: payload, actionTag: actionTag)
        case .desktopNotification:
            return translateDesktopNotification(payload: payload, actionTag: actionTag)
        case .promptTitle:
            return translatePromptTitle(payload: payload, actionTag: actionTag)
        case .mouseShape:
            return translateMouseShape(payload: payload, actionTag: actionTag)
        case .mouseVisibility:
            return translateMouseVisibility(payload: payload, actionTag: actionTag)
        case .mouseOverLink:
            return translateMouseOverLink(payload: payload, actionTag: actionTag)
        case .rendererHealth:
            return translateRendererHealth(payload: payload, actionTag: actionTag)
        default:
            return nil
        }
    }

    static func translateControlAction(
        actionTag: GhosttyActionTag,
        payload: GhosttyActionPayload
    ) -> GhosttyEvent? {
        switch actionTag {
        case .keySequence:
            return translateKeySequence(payload: payload, actionTag: actionTag)
        case .keyTable:
            return translateKeyTable(payload: payload, actionTag: actionTag)
        case .colorChange:
            return translateColorChange(payload: payload, actionTag: actionTag)
        case .reloadConfig:
            return translateReloadConfig(payload: payload, actionTag: actionTag)
        case .configChange:
            return translateConfigChange(payload: payload, actionTag: actionTag)
        case .secureInput:
            return translateSecureInput(payload: payload, actionTag: actionTag)
        case .openURL:
            return translateOpenURL(payload: payload, actionTag: actionTag)
        case .progressReport:
            return translateProgressReport(payload: payload, actionTag: actionTag)
        default:
            return nil
        }
    }

    static func translateSearchAction(
        actionTag: GhosttyActionTag,
        payload: GhosttyActionPayload
    ) -> GhosttyEvent? {
        switch actionTag {
        case .startSearch:
            return translateStartSearch(payload: payload, actionTag: actionTag)
        case .endSearch:
            return translateEndSearch(payload: payload, actionTag: actionTag)
        case .searchTotal:
            return translateSearchTotal(payload: payload, actionTag: actionTag)
        case .searchSelected:
            return translateSearchSelected(payload: payload, actionTag: actionTag)
        default:
            return nil
        }
    }

    static func translateClipboardOrReadonlyAction(
        actionTag: GhosttyActionTag,
        payload: GhosttyActionPayload
    ) -> GhosttyEvent? {
        switch actionTag {
        case .readOnly:
            return translateReadOnly(payload: payload, actionTag: actionTag)
        case .undo:
            return .undoRequested
        case .redo:
            return .redoRequested
        case .copyTitleToClipboard:
            return .copyTitleToClipboardRequested
        default:
            return nil
        }
    }

    static func payloadMismatch(
        actionTag: GhosttyActionTag,
        payload: GhosttyActionPayload,
        expectedPayload: String
    ) -> GhosttyEvent {
        ghosttyAdapterLogger.warning(
            "Ghostty payload mismatch for action tag \(actionTag.rawValue, privacy: .public): expected \(expectedPayload, privacy: .public), got \(String(describing: payload), privacy: .public)"
        )
        return .unhandled(tag: actionTag.rawValue)
    }
}
