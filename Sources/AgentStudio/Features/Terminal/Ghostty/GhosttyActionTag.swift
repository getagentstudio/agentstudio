import Foundation
import GhosttyKit

/// Canonical tag vocabulary for Ghostty action callbacks.
/// Kept explicit so routing and adapter switches remain exhaustive without catch-alls.
enum GhosttyActionTag: Sendable, CaseIterable {
    case quit
    case newWindow
    case newTab
    case ringBell
    case setTitle
    case setTabTitle
    case pwd
    case newSplit
    case gotoSplit
    case resizeSplit
    case equalizeSplits
    case toggleSplitZoom
    case closeTab
    case gotoTab
    case moveTab
    case closeAllWindows
    case toggleMaximize
    case toggleFullscreen
    case toggleTabOverview
    case toggleWindowDecorations
    case toggleQuickTerminal
    case toggleCommandPalette
    case toggleVisibility
    case toggleBackgroundOpacity
    case gotoWindow
    case presentTerminal
    case sizeLimit
    case resetWindowSize
    case resizeWindow
    case initialSize
    case cellSize
    case scrollbar
    case render
    case inspector
    case showGtkInspector
    case renderInspector
    case desktopNotification
    case promptTitle
    case mouseShape
    case mouseVisibility
    case mouseOverLink
    case rendererHealth
    case openConfig
    case quitTimer
    case floatWindow
    case secureInput
    case keySequence
    case keyTable
    case colorChange
    case reloadConfig
    case configChange
    case closeWindow
    case undo
    case redo
    case checkForUpdates
    case openURL
    case showChildExited
    case progressReport
    case showOnScreenKeyboard
    case commandFinished
    case startSearch
    case endSearch
    case searchTotal
    case searchSelected
    case readOnly
    case copyTitleToClipboard
    case exportTerminalIO
    case setWindowTitle
    case selectionChanged
    case moveTabToNewWindow

    private static let tagsByRawValue: [UInt32: Self] = Dictionary(
        uniqueKeysWithValues: Self.allCases.map { ($0.rawValue, $0) }
    )

    init?(rawValue: UInt32) {
        guard let mappedTag = Self.tagsByRawValue[rawValue] else {
            return nil
        }
        self = mappedTag
    }

    var rawValue: UInt32 {
        switch self {
        case .quit: return UInt32(GHOSTTY_ACTION_QUIT.rawValue)
        case .newWindow: return UInt32(GHOSTTY_ACTION_NEW_WINDOW.rawValue)
        case .newTab: return UInt32(GHOSTTY_ACTION_NEW_TAB.rawValue)
        case .ringBell: return UInt32(GHOSTTY_ACTION_RING_BELL.rawValue)
        case .setTitle: return UInt32(GHOSTTY_ACTION_SET_TITLE.rawValue)
        case .setTabTitle: return UInt32(GHOSTTY_ACTION_SET_TAB_TITLE.rawValue)
        case .pwd: return UInt32(GHOSTTY_ACTION_PWD.rawValue)
        case .newSplit: return UInt32(GHOSTTY_ACTION_NEW_SPLIT.rawValue)
        case .gotoSplit: return UInt32(GHOSTTY_ACTION_GOTO_SPLIT.rawValue)
        case .resizeSplit: return UInt32(GHOSTTY_ACTION_RESIZE_SPLIT.rawValue)
        case .equalizeSplits: return UInt32(GHOSTTY_ACTION_EQUALIZE_SPLITS.rawValue)
        case .toggleSplitZoom: return UInt32(GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM.rawValue)
        case .closeTab: return UInt32(GHOSTTY_ACTION_CLOSE_TAB.rawValue)
        case .gotoTab: return UInt32(GHOSTTY_ACTION_GOTO_TAB.rawValue)
        case .moveTab: return UInt32(GHOSTTY_ACTION_MOVE_TAB.rawValue)
        case .closeAllWindows: return UInt32(GHOSTTY_ACTION_CLOSE_ALL_WINDOWS.rawValue)
        case .toggleMaximize: return UInt32(GHOSTTY_ACTION_TOGGLE_MAXIMIZE.rawValue)
        case .toggleFullscreen: return UInt32(GHOSTTY_ACTION_TOGGLE_FULLSCREEN.rawValue)
        case .toggleTabOverview: return UInt32(GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW.rawValue)
        case .toggleWindowDecorations: return UInt32(GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS.rawValue)
        case .toggleQuickTerminal: return UInt32(GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL.rawValue)
        case .toggleCommandPalette: return UInt32(GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE.rawValue)
        case .toggleVisibility: return UInt32(GHOSTTY_ACTION_TOGGLE_VISIBILITY.rawValue)
        case .toggleBackgroundOpacity: return UInt32(GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY.rawValue)
        case .gotoWindow: return UInt32(GHOSTTY_ACTION_GOTO_WINDOW.rawValue)
        case .presentTerminal: return UInt32(GHOSTTY_ACTION_PRESENT_TERMINAL.rawValue)
        case .sizeLimit: return UInt32(GHOSTTY_ACTION_SIZE_LIMIT.rawValue)
        case .resetWindowSize: return UInt32(GHOSTTY_ACTION_RESET_WINDOW_SIZE.rawValue)
        case .resizeWindow: return UInt32(GHOSTTY_ACTION_RESIZE_WINDOW.rawValue)
        case .initialSize: return UInt32(GHOSTTY_ACTION_INITIAL_SIZE.rawValue)
        case .cellSize: return UInt32(GHOSTTY_ACTION_CELL_SIZE.rawValue)
        case .scrollbar: return UInt32(GHOSTTY_ACTION_SCROLLBAR.rawValue)
        case .render: return UInt32(GHOSTTY_ACTION_RENDER.rawValue)
        case .inspector: return UInt32(GHOSTTY_ACTION_INSPECTOR.rawValue)
        case .showGtkInspector: return UInt32(GHOSTTY_ACTION_SHOW_GTK_INSPECTOR.rawValue)
        case .renderInspector: return UInt32(GHOSTTY_ACTION_RENDER_INSPECTOR.rawValue)
        case .desktopNotification: return UInt32(GHOSTTY_ACTION_DESKTOP_NOTIFICATION.rawValue)
        case .promptTitle: return UInt32(GHOSTTY_ACTION_PROMPT_TITLE.rawValue)
        case .mouseShape: return UInt32(GHOSTTY_ACTION_MOUSE_SHAPE.rawValue)
        case .mouseVisibility: return UInt32(GHOSTTY_ACTION_MOUSE_VISIBILITY.rawValue)
        case .mouseOverLink: return UInt32(GHOSTTY_ACTION_MOUSE_OVER_LINK.rawValue)
        case .rendererHealth: return UInt32(GHOSTTY_ACTION_RENDERER_HEALTH.rawValue)
        case .openConfig: return UInt32(GHOSTTY_ACTION_OPEN_CONFIG.rawValue)
        case .quitTimer: return UInt32(GHOSTTY_ACTION_QUIT_TIMER.rawValue)
        case .floatWindow: return UInt32(GHOSTTY_ACTION_FLOAT_WINDOW.rawValue)
        case .secureInput: return UInt32(GHOSTTY_ACTION_SECURE_INPUT.rawValue)
        case .keySequence: return UInt32(GHOSTTY_ACTION_KEY_SEQUENCE.rawValue)
        case .keyTable: return UInt32(GHOSTTY_ACTION_KEY_TABLE.rawValue)
        case .colorChange: return UInt32(GHOSTTY_ACTION_COLOR_CHANGE.rawValue)
        case .reloadConfig: return UInt32(GHOSTTY_ACTION_RELOAD_CONFIG.rawValue)
        case .configChange: return UInt32(GHOSTTY_ACTION_CONFIG_CHANGE.rawValue)
        case .closeWindow: return UInt32(GHOSTTY_ACTION_CLOSE_WINDOW.rawValue)
        case .undo: return UInt32(GHOSTTY_ACTION_UNDO.rawValue)
        case .redo: return UInt32(GHOSTTY_ACTION_REDO.rawValue)
        case .checkForUpdates: return UInt32(GHOSTTY_ACTION_CHECK_FOR_UPDATES.rawValue)
        case .openURL: return UInt32(GHOSTTY_ACTION_OPEN_URL.rawValue)
        case .showChildExited: return UInt32(GHOSTTY_ACTION_SHOW_CHILD_EXITED.rawValue)
        case .progressReport: return UInt32(GHOSTTY_ACTION_PROGRESS_REPORT.rawValue)
        case .showOnScreenKeyboard: return UInt32(GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD.rawValue)
        case .commandFinished: return UInt32(GHOSTTY_ACTION_COMMAND_FINISHED.rawValue)
        case .startSearch: return UInt32(GHOSTTY_ACTION_START_SEARCH.rawValue)
        case .endSearch: return UInt32(GHOSTTY_ACTION_END_SEARCH.rawValue)
        case .searchTotal: return UInt32(GHOSTTY_ACTION_SEARCH_TOTAL.rawValue)
        case .searchSelected: return UInt32(GHOSTTY_ACTION_SEARCH_SELECTED.rawValue)
        case .readOnly: return UInt32(GHOSTTY_ACTION_READONLY.rawValue)
        case .copyTitleToClipboard: return UInt32(GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD.rawValue)
        case .exportTerminalIO: return UInt32(GHOSTTY_ACTION_EXPORT_TERMINAL_IO.rawValue)
        case .setWindowTitle: return UInt32(GHOSTTY_ACTION_SET_WINDOW_TITLE.rawValue)
        case .selectionChanged: return UInt32(GHOSTTY_ACTION_SELECTION_CHANGED.rawValue)
        case .moveTabToNewWindow: return UInt32(GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW.rawValue)
        }
    }
}
