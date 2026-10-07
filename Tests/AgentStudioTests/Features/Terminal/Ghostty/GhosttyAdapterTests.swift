import AgentStudioCore
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@Suite("GhosttyAdapter")
@MainActor
struct GhosttyAdapterTests {
    @Test("known action tags map to typed events")
    func knownTagMappings() {
        let adapter = GhosttyAdapter.shared
        assertCoreMappings(using: adapter)
        assertObservedStateMappings(using: adapter)
        assertDeferredMappings(using: adapter)
    }

    private func assertCoreMappings(using adapter: GhosttyAdapter) {
        #expect(
            adapter.translate(actionTag: UInt32(GHOSTTY_ACTION_NEW_TAB.rawValue)) == .newTab
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_CLOSE_TAB.rawValue),
                payload: .closeTab(modeRawValue: GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS.rawValue)
            ) == .closeTab(mode: .thisTab)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_GOTO_TAB.rawValue),
                payload: .gotoTab(targetRawValue: GHOSTTY_GOTO_TAB_NEXT.rawValue)
            ) == .gotoTab(target: .next)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_MOVE_TAB.rawValue),
                payload: .moveTab(amount: 2)
            ) == .moveTab(amount: 2)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_NEW_SPLIT.rawValue),
                payload: .newSplit(directionRawValue: GHOSTTY_SPLIT_DIRECTION_RIGHT.rawValue)
            ) == .newSplit(direction: .right)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_GOTO_SPLIT.rawValue),
                payload: .gotoSplit(directionRawValue: GHOSTTY_GOTO_SPLIT_PREVIOUS.rawValue)
            ) == .gotoSplit(direction: .previous)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_RESIZE_SPLIT.rawValue),
                payload: .resizeSplit(amount: 3, directionRawValue: GHOSTTY_RESIZE_SPLIT_LEFT.rawValue)
            ) == .resizeSplit(amount: 3, direction: .left)
        )
        #expect(
            adapter.translate(actionTag: UInt32(GHOSTTY_ACTION_EQUALIZE_SPLITS.rawValue)) == .equalizeSplits
        )
        #expect(
            adapter.translate(actionTag: UInt32(GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM.rawValue)) == .toggleSplitZoom
        )
        #expect(
            adapter.translate(actionTag: UInt32(GHOSTTY_ACTION_RING_BELL.rawValue)) == .bellRang
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_SET_TITLE.rawValue),
                payload: .titleChanged("Build")
            ) == .titleChanged("Build")
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_PWD.rawValue),
                payload: .cwdChanged("/tmp/worktree")
            ) == .cwdChanged("/tmp/worktree")
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_COMMAND_FINISHED.rawValue),
                payload: .commandFinished(exitCode: 0, duration: 42, sourceInstant: ContinuousClock.now)
            ) == .commandFinished(exitCode: 0, duration: 42)
        )
    }

    private func assertObservedStateMappings(using adapter: GhosttyAdapter) {
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_PROGRESS_REPORT.rawValue),
                payload: .progressReport(
                    stateRawValue: UInt32(GHOSTTY_PROGRESS_STATE_SET.rawValue),
                    progress: 42
                )
            )
                == .progressReportUpdated(
                    ProgressState(kind: .set, percent: 42)
                )
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_PROGRESS_REPORT.rawValue),
                payload: .progressReport(
                    stateRawValue: UInt32(GHOSTTY_PROGRESS_STATE_REMOVE.rawValue),
                    progress: -1
                )
            ) == .progressReportUpdated(nil)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_READONLY.rawValue),
                payload: .readOnly(modeRawValue: UInt32(GHOSTTY_READONLY_ON.rawValue))
            ) == .readOnlyChanged(true)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_SECURE_INPUT.rawValue),
                payload: .secureInput(modeRawValue: UInt32(GHOSTTY_SECURE_INPUT_TOGGLE.rawValue))
            ) == .secureInputRequested(.toggle)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_RENDERER_HEALTH.rawValue),
                payload: .rendererHealth(rawValue: UInt32(GHOSTTY_RENDERER_HEALTH_HEALTHY.rawValue))
            ) == .rendererHealthChanged(healthy: true)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_CELL_SIZE.rawValue),
                payload: .cellSizeChanged(width: 8, height: 16)
            ) == .cellSizeChanged(NSSize(width: 8, height: 16))
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_INITIAL_SIZE.rawValue),
                payload: .initialSizeChanged(width: 80, height: 25)
            ) == .initialSizeChanged(NSSize(width: 80, height: 25))
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_SIZE_LIMIT.rawValue),
                payload: .sizeLimitChanged(minWidth: 640, minHeight: 480, maxWidth: 1440, maxHeight: 900)
            )
                == .sizeLimitChanged(
                    TerminalSizeConstraints(
                        minWidth: 640,
                        minHeight: 480,
                        maxWidth: 1440,
                        maxHeight: 900
                    )
                )
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_PROMPT_TITLE.rawValue),
                payload: .promptTitle(scopeRawValue: UInt32(GHOSTTY_PROMPT_TITLE_TAB.rawValue))
            ) == .promptTitleRequested(scope: .tab)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_DESKTOP_NOTIFICATION.rawValue),
                payload: .desktopNotification(title: "Build", body: "Complete")
            ) == .desktopNotificationRequested(title: "Build", body: "Complete")
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_OPEN_URL.rawValue),
                payload: .openURL(
                    url: "https://example.com",
                    kindRawValue: UInt32(GHOSTTY_ACTION_OPEN_URL_KIND_TEXT.rawValue)
                )
            ) == .openURLRequested(url: "https://example.com", kind: .text)
        )
        #expect(
            adapter.translate(actionTag: UInt32(GHOSTTY_ACTION_UNDO.rawValue)) == .undoRequested
        )
        #expect(
            adapter.translate(actionTag: UInt32(GHOSTTY_ACTION_REDO.rawValue)) == .redoRequested
        )
        #expect(
            adapter.translate(actionTag: UInt32(GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD.rawValue))
                == .copyTitleToClipboardRequested
        )
    }

    private func assertDeferredMappings(using adapter: GhosttyAdapter) {
        assertPromotedViewportAndInputMappings(using: adapter)
        assertPromotedConfigAndSearchMappings(using: adapter)
    }

    private func assertPromotedViewportAndInputMappings(using adapter: GhosttyAdapter) {
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_SET_TAB_TITLE.rawValue),
                payload: .tabTitleChanged("Build")
            ) == .tabTitleChanged("Build")
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_SCROLLBAR.rawValue),
                payload: .scrollbar(total: 100, offset: 20, length: 10)
            ) == .scrollbarChanged(ScrollbarState(top: 20, bottom: 30, total: 100))
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_MOUSE_SHAPE.rawValue),
                payload: .mouseShape(rawValue: UInt32(GHOSTTY_MOUSE_SHAPE_TEXT.rawValue))
            ) == .mouseShapeChanged(shape: .text)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_MOUSE_SHAPE.rawValue),
                payload: .mouseShape(rawValue: UInt32(GHOSTTY_MOUSE_SHAPE_POINTER.rawValue))
            ) == .mouseShapeChanged(shape: .pointer)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_MOUSE_SHAPE.rawValue),
                payload: .mouseShape(rawValue: UInt32(GHOSTTY_MOUSE_SHAPE_CROSSHAIR.rawValue))
            ) == .mouseShapeChanged(shape: .crosshair)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_MOUSE_SHAPE.rawValue),
                payload: .mouseShape(rawValue: UInt32(GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT.rawValue))
            ) == .mouseShapeChanged(shape: .verticalText)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_MOUSE_SHAPE.rawValue),
                payload: .mouseShape(rawValue: 999)
            ) == .mouseShapeChanged(shape: .other(rawValue: 999))
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_MOUSE_VISIBILITY.rawValue),
                payload: .mouseVisibility(rawValue: UInt32(GHOSTTY_MOUSE_HIDDEN.rawValue))
            ) == .mouseVisibilityChanged(isVisible: false)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_MOUSE_VISIBILITY.rawValue),
                payload: .mouseVisibility(rawValue: 99)
            ) == .unhandled(tag: UInt32(GHOSTTY_ACTION_MOUSE_VISIBILITY.rawValue))
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_MOUSE_OVER_LINK.rawValue),
                payload: .mouseOverLink("https://example.com")
            ) == .mouseLinkHovered(url: "https://example.com")
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_KEY_SEQUENCE.rawValue),
                payload: .keySequence(
                    active: true,
                    triggerTag: UInt32(GHOSTTY_TRIGGER_UNICODE.rawValue),
                    key: 97,
                    mods: 0
                )
            )
                == .keySequenceChanged(
                    active: true,
                    trigger: GhosttyInputTrigger(tag: .unicode, key: 97, modifiers: 0)
                )
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_KEY_TABLE.rawValue),
                payload: .keyTable(
                    tagRawValue: UInt32(GHOSTTY_KEY_TABLE_ACTIVATE.rawValue),
                    activateName: "copy-mode"
                )
            ) == .keyTableChanged(.activate(name: "copy-mode"))
        )
    }

    private func assertPromotedConfigAndSearchMappings(using adapter: GhosttyAdapter) {
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_COLOR_CHANGE.rawValue),
                payload: .colorChange(
                    kindRawValue: Int32(GHOSTTY_ACTION_COLOR_KIND_CURSOR.rawValue),
                    red: 10,
                    green: 20,
                    blue: 30
                )
            )
                == .colorChanged(
                    TerminalColorChange(kind: .cursor, red: 10, green: 20, blue: 30)
                )
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_RELOAD_CONFIG.rawValue),
                payload: .reloadConfig(soft: true)
            ) == .configReloadRequested(soft: true)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_CONFIG_CHANGE.rawValue),
                payload: .configChange
            ) == .configChanged
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_START_SEARCH.rawValue),
                payload: .startSearch("needle")
            ) == .searchStarted(query: "needle")
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_END_SEARCH.rawValue),
                payload: .endSearch
            ) == .searchEnded
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_SEARCH_TOTAL.rawValue),
                payload: .searchTotal(7)
            ) == .searchMatchesUpdated(totalMatches: 7)
        )
        #expect(
            adapter.translate(
                actionTag: UInt32(GHOSTTY_ACTION_SEARCH_SELECTED.rawValue),
                payload: .searchSelected(3)
            ) == .searchSelectionChanged(selectedMatchIndex: 3)
        )

        #expect(
            adapter.translate(actionTag: UInt32(GHOSTTY_ACTION_RENDER.rawValue))
                == .unhandled(tag: UInt32(GHOSTTY_ACTION_RENDER.rawValue))
        )
    }

    @Test("invalid payload maps to unhandled")
    func invalidPayloadMapsToUnhandled() {
        let adapter = GhosttyAdapter.shared
        let closeTag = UInt32(GHOSTTY_ACTION_CLOSE_TAB.rawValue)
        #expect(adapter.translate(actionTag: closeTag, payload: .noPayload) == .unhandled(tag: closeTag))
    }

    @Test("unknown raw action tags map to unhandled event")
    func unknownRawTagMapsToUnhandled() {
        let adapter = GhosttyAdapter.shared
        let unknownTag: UInt32 = 9_999_999
        #expect(adapter.translate(actionTag: unknownTag) == .unhandled(tag: unknownTag))
    }
}
