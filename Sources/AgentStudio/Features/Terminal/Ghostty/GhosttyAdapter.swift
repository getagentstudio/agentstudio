import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import os.log

// swiftlint:disable type_body_length
private let ghosttyAdapterLogger = Logger(subsystem: "com.agentstudio", category: "GhosttyAdapter")

/// Adapter boundary translating low-level Ghostty action tags into typed
/// domain events consumed by TerminalRuntime.
final class GhosttyAdapter: Sendable {
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

    enum ActionPayload: Sendable, Equatable {
        case noPayload
        case titleChanged(String)
        case cwdChanged(String)
        case commandFinished(exitCode: Int, duration: UInt64, sourceInstant: ContinuousClock.Instant)
        case tabTitleChanged(String)
        case closeTab(modeRawValue: UInt32)
        case gotoTab(targetRawValue: Int32)
        case moveTab(amount: Int)
        case newSplit(directionRawValue: UInt32)
        case gotoSplit(directionRawValue: UInt32)
        case resizeSplit(amount: UInt16, directionRawValue: UInt32)
        case progressReport(stateRawValue: UInt32, progress: Int8)
        case readOnly(modeRawValue: UInt32)
        case secureInput(modeRawValue: UInt32)
        case rendererHealth(rawValue: UInt32)
        case cellSizeChanged(width: UInt32, height: UInt32)
        case initialSizeChanged(width: UInt32, height: UInt32)
        case sizeLimitChanged(minWidth: UInt32, minHeight: UInt32, maxWidth: UInt32, maxHeight: UInt32)
        case mouseShape(rawValue: UInt32)
        case mouseVisibility(rawValue: UInt32)
        case mouseOverLink(String?)
        case keySequence(active: Bool, triggerTag: UInt32, key: UInt32?, mods: UInt32)
        case keyTable(tagRawValue: UInt32, activateName: String?)
        case colorChange(kindRawValue: Int32, red: UInt8, green: UInt8, blue: UInt8)
        case reloadConfig(soft: Bool)
        case configChange
        case startSearch(String?)
        case endSearch
        case searchTotal(Int)
        case searchSelected(Int)
        case scrollbar(total: UInt64, offset: UInt64, length: UInt64)
        case promptTitle(scopeRawValue: UInt32)
        case desktopNotification(title: String, body: String)
        case openURL(url: String, kindRawValue: UInt32)
    }

    static let shared = GhosttyAdapter()

    private init() {}

    func translate(
        actionTag: UInt32,
        payload: ActionPayload = .noPayload
    ) -> GhosttyEvent {
        guard let knownActionTag = GhosttyActionTag(rawValue: actionTag) else {
            return .unhandled(tag: actionTag)
        }
        return translate(actionTag: knownActionTag, payload: payload)
    }

    func translate(
        actionTag: GhosttyActionTag,
        payload: ActionPayload = .noPayload
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
    func route(
        actionTag: UInt32,
        payload: ActionPayload = .noPayload,
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

    private func translateSetTitle(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .titleChanged(let title) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".titleChanged(String)"
            )
        }
        return .titleChanged(title)
    }

    private func translateSetTabTitle(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .tabTitleChanged(let title) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".tabTitleChanged(String)"
            )
        }
        return .tabTitleChanged(title)
    }

    private func translatePwd(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .cwdChanged(let cwdPath) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".cwdChanged(String)"
            )
        }
        return .cwdChanged(cwdPath)
    }

    private func translateCommandFinished(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .commandFinished(let exitCode, let duration, _) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload:
                    ".commandFinished(exitCode: Int, duration: UInt64, sourceInstant: ContinuousClock.Instant)"
            )
        }
        return .commandFinished(exitCode: exitCode, duration: duration)
    }

    private func translateMouseShape(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .mouseShape(let rawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".mouseShape(rawValue: UInt32)"
            )
        }
        let mouseShape: TerminalMouseShape
        switch rawValue {
        case UInt32(GHOSTTY_MOUSE_SHAPE_TEXT.rawValue):
            mouseShape = .text
        case UInt32(GHOSTTY_MOUSE_SHAPE_POINTER.rawValue):
            mouseShape = .pointer
        case UInt32(GHOSTTY_MOUSE_SHAPE_CROSSHAIR.rawValue):
            mouseShape = .crosshair
        case UInt32(GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT.rawValue):
            mouseShape = .verticalText
        default:
            mouseShape = .other(rawValue: rawValue)
        }
        return .mouseShapeChanged(shape: mouseShape)
    }

    private func translateMouseVisibility(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .mouseVisibility(let rawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".mouseVisibility(rawValue: UInt32)"
            )
        }

        switch rawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_MOUSE_VISIBLE.rawValue):
            return .mouseVisibilityChanged(isVisible: true)
        case UInt32(truncatingIfNeeded: GHOSTTY_MOUSE_HIDDEN.rawValue):
            return .mouseVisibilityChanged(isVisible: false)
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known mouse visibility value"
            )
        }
    }

    private func translateMouseOverLink(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .mouseOverLink(let url) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".mouseOverLink(String?)"
            )
        }
        return .mouseLinkHovered(url: url)
    }

    private func translateKeySequence(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .keySequence(let active, let triggerTag, let key, let mods) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".keySequence(active: Bool, triggerTag: UInt32, key: UInt32?, mods: UInt32)"
            )
        }

        let trigger: GhosttyInputTrigger? =
            switch triggerTag {
            case UInt32(truncatingIfNeeded: GHOSTTY_TRIGGER_PHYSICAL.rawValue):
                .init(tag: .physical, key: key, modifiers: mods)
            case UInt32(truncatingIfNeeded: GHOSTTY_TRIGGER_UNICODE.rawValue):
                .init(tag: .unicode, key: key, modifiers: mods)
            case UInt32(truncatingIfNeeded: GHOSTTY_TRIGGER_CATCH_ALL.rawValue):
                .init(tag: .catchAll, key: nil, modifiers: mods)
            default:
                nil
            }

        if active, trigger == nil {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known triggerTag value"
            )
        }

        return .keySequenceChanged(active: active, trigger: trigger)
    }

    private func translateKeyTable(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .keyTable(let tagRawValue, let activateName) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".keyTable(tagRawValue: UInt32, activateName: String?)"
            )
        }

        let change: GhosttyKeyTableChange
        switch tagRawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_KEY_TABLE_ACTIVATE.rawValue):
            guard let activateName else {
                return payloadMismatch(
                    actionTag: actionTag,
                    payload: payload,
                    expectedPayload: "UTF-8 decodable activate key table name"
                )
            }
            change = .activate(name: activateName)
        case UInt32(truncatingIfNeeded: GHOSTTY_KEY_TABLE_DEACTIVATE.rawValue):
            change = .deactivate
        case UInt32(truncatingIfNeeded: GHOSTTY_KEY_TABLE_DEACTIVATE_ALL.rawValue):
            change = .deactivateAll
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known key table action"
            )
        }

        return .keyTableChanged(change)
    }

    private func translateColorChange(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .colorChange(let kindRawValue, let red, let green, let blue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".colorChange(kindRawValue: Int32, red: UInt8, green: UInt8, blue: UInt8)"
            )
        }

        let kind: TerminalColorKind
        switch kindRawValue {
        case Int32(GHOSTTY_ACTION_COLOR_KIND_FOREGROUND.rawValue):
            kind = .foreground
        case Int32(GHOSTTY_ACTION_COLOR_KIND_BACKGROUND.rawValue):
            kind = .background
        case Int32(GHOSTTY_ACTION_COLOR_KIND_CURSOR.rawValue):
            kind = .cursor
        case 0...255:
            kind = .palette(index: UInt8(kindRawValue))
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known color kind or 0...255 palette index"
            )
        }

        return .colorChanged(
            TerminalColorChange(
                kind: kind,
                red: red,
                green: green,
                blue: blue
            )
        )
    }

    private func translateReloadConfig(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .reloadConfig(let soft) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".reloadConfig(soft: Bool)"
            )
        }

        return .configReloadRequested(soft: soft)
    }

    private func translateConfigChange(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .configChange = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".configChange"
            )
        }

        return .configChanged
    }

    private func translateStartSearch(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .startSearch(let query) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".startSearch(String?)"
            )
        }

        return .searchStarted(query: query)
    }

    private func translateEndSearch(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .endSearch = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".endSearch"
            )
        }

        return .searchEnded
    }

    private func translateSearchTotal(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .searchTotal(let total) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".searchTotal(Int)"
            )
        }

        return .searchMatchesUpdated(totalMatches: total >= 0 ? total : nil)
    }

    private func translateSearchSelected(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .searchSelected(let selected) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".searchSelected(Int)"
            )
        }

        return .searchSelectionChanged(selectedMatchIndex: selected >= 0 ? selected : nil)
    }

    private func translateScrollbar(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .scrollbar(let total, let offset, let length) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".scrollbar(total: UInt64, offset: UInt64, length: UInt64)"
            )
        }

        return .scrollbarChanged(ScrollbarState(top: Int(offset), bottom: Int(offset + length), total: Int(total)))
    }

    private func translateCloseTab(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard
            case .closeTab(let modeRawValue) = payload,
            let mode = closeTabMode(from: modeRawValue)
        else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".closeTab(modeRawValue: UInt32)"
            )
        }
        return .closeTab(mode: mode)
    }

    private func translateGotoTab(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard
            case .gotoTab(let targetRawValue) = payload,
            let target = gotoTabTarget(from: targetRawValue)
        else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".gotoTab(targetRawValue: Int32)"
            )
        }
        return .gotoTab(target: target)
    }

    private func translateMoveTab(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .moveTab(let amount) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".moveTab(amount: Int)"
            )
        }
        return .moveTab(amount: amount)
    }

    private func translateNewSplit(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard
            case .newSplit(let directionRawValue) = payload,
            let direction = splitDirection(from: directionRawValue)
        else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".newSplit(directionRawValue: UInt32)"
            )
        }
        return .newSplit(direction: direction)
    }

    private func translateGotoSplit(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard
            case .gotoSplit(let directionRawValue) = payload,
            let direction = gotoSplitDirection(from: directionRawValue)
        else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".gotoSplit(directionRawValue: UInt32)"
            )
        }
        return .gotoSplit(direction: direction)
    }

    private func translateResizeSplit(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard
            case .resizeSplit(let amount, let directionRawValue) = payload,
            let direction = resizeSplitDirection(from: directionRawValue)
        else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".resizeSplit(amount: UInt16, directionRawValue: UInt32)"
            )
        }
        return .resizeSplit(amount: amount, direction: direction)
    }

    private func translateProgressReport(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .progressReport(let stateRawValue, let progress) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".progressReport(stateRawValue: UInt32, progress: Int8)"
            )
        }

        switch stateRawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_PROGRESS_STATE_REMOVE.rawValue):
            return .progressReportUpdated(nil)
        case UInt32(truncatingIfNeeded: GHOSTTY_PROGRESS_STATE_SET.rawValue):
            return .progressReportUpdated(ProgressState(kind: .set, percent: progressPercent(progress)))
        case UInt32(truncatingIfNeeded: GHOSTTY_PROGRESS_STATE_ERROR.rawValue):
            return .progressReportUpdated(ProgressState(kind: .error, percent: progressPercent(progress)))
        case UInt32(truncatingIfNeeded: GHOSTTY_PROGRESS_STATE_INDETERMINATE.rawValue):
            return .progressReportUpdated(
                ProgressState(kind: .indeterminate, percent: progressPercent(progress))
            )
        case UInt32(truncatingIfNeeded: GHOSTTY_PROGRESS_STATE_PAUSE.rawValue):
            return .progressReportUpdated(ProgressState(kind: .paused, percent: progressPercent(progress)))
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known progress report state"
            )
        }
    }

    private func translateCoreAction(
        actionTag: GhosttyActionTag,
        payload: ActionPayload
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

    private func translateObservedAction(
        actionTag: GhosttyActionTag,
        payload: ActionPayload
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

    private func translateViewportOrDisplayAction(
        actionTag: GhosttyActionTag,
        payload: ActionPayload
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

    private func translateControlAction(
        actionTag: GhosttyActionTag,
        payload: ActionPayload
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

    private func translateSearchAction(
        actionTag: GhosttyActionTag,
        payload: ActionPayload
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

    private func translateClipboardOrReadonlyAction(
        actionTag: GhosttyActionTag,
        payload: ActionPayload
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

    private func translateReadOnly(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .readOnly(let modeRawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".readOnly(modeRawValue: UInt32)"
            )
        }

        switch modeRawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_READONLY_OFF.rawValue):
            return .readOnlyChanged(false)
        case UInt32(truncatingIfNeeded: GHOSTTY_READONLY_ON.rawValue):
            return .readOnlyChanged(true)
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known readonly mode"
            )
        }
    }

    private func translateSecureInput(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .secureInput(let modeRawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".secureInput(modeRawValue: UInt32)"
            )
        }

        switch modeRawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_SECURE_INPUT_ON.rawValue):
            return .secureInputRequested(.on)
        case UInt32(truncatingIfNeeded: GHOSTTY_SECURE_INPUT_OFF.rawValue):
            return .secureInputRequested(.off)
        case UInt32(truncatingIfNeeded: GHOSTTY_SECURE_INPUT_TOGGLE.rawValue):
            return .secureInputRequested(.toggle)
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known secure input mode"
            )
        }
    }

    private func translateRendererHealth(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .rendererHealth(let rawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".rendererHealth(rawValue: UInt32)"
            )
        }

        switch rawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_RENDERER_HEALTH_HEALTHY.rawValue):
            return .rendererHealthChanged(healthy: true)
        case UInt32(truncatingIfNeeded: GHOSTTY_RENDERER_HEALTH_UNHEALTHY.rawValue):
            return .rendererHealthChanged(healthy: false)
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known renderer health value"
            )
        }
    }

    private func translateCellSize(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .cellSizeChanged(let width, let height) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".cellSizeChanged(width: UInt32, height: UInt32)"
            )
        }

        return .cellSizeChanged(
            NSSize(width: Double(width), height: Double(height))
        )
    }

    private func translateInitialSize(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .initialSizeChanged(let width, let height) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".initialSizeChanged(width: UInt32, height: UInt32)"
            )
        }

        return .initialSizeChanged(
            NSSize(width: Double(width), height: Double(height))
        )
    }

    private func translateSizeLimit(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .sizeLimitChanged(let minWidth, let minHeight, let maxWidth, let maxHeight) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload:
                    ".sizeLimitChanged(minWidth: UInt32, minHeight: UInt32, maxWidth: UInt32, maxHeight: UInt32)"
            )
        }

        return .sizeLimitChanged(
            TerminalSizeConstraints(
                minWidth: minWidth,
                minHeight: minHeight,
                maxWidth: maxWidth,
                maxHeight: maxHeight
            )
        )
    }

    private func translatePromptTitle(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .promptTitle(let scopeRawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".promptTitle(scopeRawValue: UInt32)"
            )
        }

        switch scopeRawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_PROMPT_TITLE_SURFACE.rawValue):
            return .promptTitleRequested(scope: .surface)
        case UInt32(truncatingIfNeeded: GHOSTTY_PROMPT_TITLE_TAB.rawValue):
            return .promptTitleRequested(scope: .tab)
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known prompt title scope"
            )
        }
    }

    private func translateDesktopNotification(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .desktopNotification(let title, let body) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".desktopNotification(title: String, body: String)"
            )
        }

        return .desktopNotificationRequested(title: title, body: body)
    }

    private func translateOpenURL(payload: ActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .openURL(let url, let kindRawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".openURL(url: String, kindRawValue: UInt32)"
            )
        }

        let kind: OpenURLKind =
            switch kindRawValue {
            case UInt32(truncatingIfNeeded: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT.rawValue):
                .text
            case UInt32(truncatingIfNeeded: GHOSTTY_ACTION_OPEN_URL_KIND_HTML.rawValue):
                .html
            case UInt32(truncatingIfNeeded: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8.rawValue):
                .osc8
            default:
                .unknown
            }

        return .openURLRequested(url: url, kind: kind)
    }

    private func closeTabMode(from rawValue: UInt32) -> GhosttyCloseTabMode? {
        switch rawValue {
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS.rawValue:
            return .thisTab
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER.rawValue:
            return .otherTabs
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT.rawValue:
            return .rightTabs
        default:
            return nil
        }
    }

    private func gotoTabTarget(from rawValue: Int32) -> GhosttyGotoTabTarget? {
        switch rawValue {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue:
            return .previous
        case GHOSTTY_GOTO_TAB_NEXT.rawValue:
            return .next
        case GHOSTTY_GOTO_TAB_LAST.rawValue:
            return .last
        default:
            guard rawValue >= 1 else { return nil }
            return .index(Int(rawValue))
        }
    }

    private func splitDirection(from rawValue: UInt32) -> GhosttySplitDirection? {
        switch rawValue {
        case GHOSTTY_SPLIT_DIRECTION_LEFT.rawValue:
            return .left
        case GHOSTTY_SPLIT_DIRECTION_RIGHT.rawValue:
            return .right
        case GHOSTTY_SPLIT_DIRECTION_UP.rawValue:
            return .up
        case GHOSTTY_SPLIT_DIRECTION_DOWN.rawValue:
            return .down
        default:
            return nil
        }
    }

    private func gotoSplitDirection(from rawValue: UInt32) -> GhosttyGotoSplitDirection? {
        switch rawValue {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS.rawValue:
            return .previous
        case GHOSTTY_GOTO_SPLIT_NEXT.rawValue:
            return .next
        case GHOSTTY_GOTO_SPLIT_LEFT.rawValue:
            return .left
        case GHOSTTY_GOTO_SPLIT_RIGHT.rawValue:
            return .right
        case GHOSTTY_GOTO_SPLIT_UP.rawValue:
            return .up
        case GHOSTTY_GOTO_SPLIT_DOWN.rawValue:
            return .down
        default:
            return nil
        }
    }

    private func resizeSplitDirection(from rawValue: UInt32) -> GhosttyResizeSplitDirection? {
        switch rawValue {
        case GHOSTTY_RESIZE_SPLIT_LEFT.rawValue:
            return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT.rawValue:
            return .right
        case GHOSTTY_RESIZE_SPLIT_UP.rawValue:
            return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN.rawValue:
            return .down
        default:
            return nil
        }
    }

    private func progressPercent(_ rawProgress: Int8) -> UInt8? {
        rawProgress >= 0 ? UInt8(rawProgress) : nil
    }

    private func payloadMismatch(
        actionTag: GhosttyActionTag,
        payload: ActionPayload,
        expectedPayload: String
    ) -> GhosttyEvent {
        ghosttyAdapterLogger.warning(
            "Ghostty payload mismatch for action tag \(actionTag.rawValue, privacy: .public): expected \(expectedPayload, privacy: .public), got \(String(describing: payload), privacy: .public)"
        )
        return .unhandled(tag: actionTag.rawValue)
    }
}
// swiftlint:enable type_body_length
