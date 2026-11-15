import AgentStudioInfrastructure
import AppKit
import Foundation

// swiftlint:disable identifier_name
package enum ShortcutCharacterKey: String, CaseIterable, Sendable {
    case a
    case b
    case d
    case e
    case f
    case i
    case j
    case k
    case l
    case m
    case n
    case o
    case p
    case r
    case s
    case t
    case u
    case w
    case comma = ","
    case leftBracket = "["
    case rightBracket = "]"
    case digit1 = "1"
    case digit2 = "2"
    case digit3 = "3"
    case digit4 = "4"
    case digit5 = "5"
    case digit6 = "6"
    case digit7 = "7"
    case digit8 = "8"
    case digit9 = "9"

    package var displayString: String {
        switch self {
        case .leftBracket:
            return "["
        case .rightBracket:
            return "]"
        case .comma:
            return ","
        default:
            return rawValue.uppercased()
        }
    }
}
// swiftlint:enable identifier_name

package enum ShortcutArrowKey: CaseIterable, Sendable {
    case left
    case right
    case down
    case up

    package var displayString: String {
        switch self {
        case .left:
            return "←"
        case .right:
            return "→"
        case .down:
            return "↓"
        case .up:
            return "↑"
        }
    }
}

package enum ShortcutInputKey: Hashable, Sendable {
    case character(ShortcutCharacterKey)
    case arrow(ShortcutArrowKey)
    case enter
    case escape

    package var displayString: String {
        switch self {
        case .character(let key):
            return key.displayString
        case .arrow(let key):
            return key.displayString
        case .enter:
            return "↵"
        case .escape:
            return "Esc"
        }
    }
}

package struct ShortcutTrigger: Hashable, Sendable {
    package let key: ShortcutInputKey
    package let modifiers: Set<KeyBinding.Modifier>

    package init(key: ShortcutInputKey, modifiers: Set<KeyBinding.Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    package var displayString: String {
        var keys: [String] = []
        if modifiers.contains(.command) { keys.append("⌘") }
        if modifiers.contains(.shift) { keys.append("⇧") }
        if modifiers.contains(.option) { keys.append("⌥") }
        if modifiers.contains(.control) { keys.append("⌃") }
        keys.append(key.displayString)
        return keys.joined()
    }

    package var displayText: ShortcutDisplayText {
        ShortcutDisplayText(value: displayString)
    }

    package var keyBinding: KeyBinding? {
        guard case .character(let key) = key else { return nil }
        return KeyBinding(key: key.rawValue, modifiers: modifiers)
    }
}

package enum ShortcutContext: CaseIterable, Hashable {
    case global
    case managementLayer
    case terminalAppOwned
    /// The stable Repo Explorer list owns keyboard input. Raw-character
    /// navigation bindings are valid only in this context.
    case sidebarList
    /// Drawer is open AND has no panes AND focus is on the drawer.
    /// Raw-character bindings (no modifiers) fire here, gated upstream
    /// on a neutral responder so text fields keep receiving keystrokes.
    case emptyDrawer
}

package struct AppShortcutSpec: Equatable {
    /// Primary trigger — what shows in the command bar / menus.
    package let trigger: ShortcutTrigger

    /// Alternate triggers keyed by the exact contexts where they are
    /// valid. This prevents a context-specific raw character binding
    /// from inheriting the broader contexts of the primary trigger.
    package let alternateTriggers: [ShortcutTrigger: Set<ShortcutContext>]

    package let contexts: Set<ShortcutContext>

    package init(
        trigger: ShortcutTrigger,
        alternateTriggers: [ShortcutTrigger: Set<ShortcutContext>] = [:],
        contexts: Set<ShortcutContext>
    ) {
        self.trigger = trigger
        self.alternateTriggers = alternateTriggers
        self.contexts = contexts
    }

    /// Returns the trigger declared for this exact context.
    /// Context-specific alternates take precedence over the primary trigger.
    package func displayTrigger(in context: ShortcutContext) -> ShortcutTrigger? {
        if let alternate = alternateTriggers.first(where: { _, contexts in
            contexts.contains(context)
        })?.key {
            return alternate
        }
        return contexts.contains(context) ? trigger : nil
    }

    package func matches(_ candidate: ShortcutTrigger, in context: ShortcutContext) -> Bool {
        if candidate == trigger {
            return contexts.contains(context)
        }
        guard let contexts = alternateTriggers[candidate] else {
            return false
        }
        return contexts.contains(context)
    }
}

package enum AppShortcut: String, CaseIterable {
    case newTab
    case undoCloseTab
    case focusPreviousPinnedPane
    case focusNextPinnedPane
    case nextTab
    case prevTab
    case showArrangementPanel
    case previousArrangement
    case nextArrangement
    case zoomPane
    case showViewer
    case showBrowserTabs
    case addDrawerPane
    case toggleDrawer
    case scrollToBottom
    case scrollPageUp
    case scrollPageDown
    case scrollSmallStepUp
    case scrollSmallStepDown
    case jumpToPreviousPrompt
    case jumpToNextPrompt
    case openPaneLocationInBookmarkedEditor
    case openPaneLocationInFinder
    case openPaneLocationInEditorMenu
    case editPaneNote
    case copyCurrentPanePath
    case toggleManagementLayer
    case toggleSidebar
    case focusSidebar
    case filterSidebar
    case showInboxNotifications
    case showPaneInboxNotifications
    case showReposSidebar
    case showPanesSidebar
    case togglePanesShowsDrawers
    case newWindow
    case showCommandBarEverything
    case showCommandBarCommands
    case showCommandBarPanes
    case selectTab1
    case selectTab2
    case selectTab3
    case selectTab4
    case selectTab5
    case selectTab6
    case selectTab7
    case selectTab8
    case selectTab9
    case focusPane1
    case focusPane2
    case focusPane3
    case focusPane4
    case focusPane5
    case focusPane6
    case focusPane7
    case focusPane8
    case focusPane9
    case managementLayerFocusLeft
    case managementLayerFocusRight
    case managementLayerEnterDrawer
    case managementLayerExitDrawer
    case managementLayerOpenDrawer
    case managementLayerCreateTerminal
    case managementLayerCreateBrowser
    case managementLayerExit

    package var spec: AppShortcutSpec {
        switch self {
        case .newTab:
            return .init(
                trigger: .init(key: .character(.t), modifiers: [.command]),
                contexts: [.global, .terminalAppOwned]
            )
        case .undoCloseTab:
            return .init(
                trigger: .init(key: .character(.t), modifiers: [.command, .shift]),
                contexts: [.global]
            )
        case .focusPreviousPinnedPane, .focusNextPinnedPane:
            return .init(
                trigger: .init(
                    key: .arrow(self == .focusPreviousPinnedPane ? .up : .down),
                    modifiers: [.option, .shift]
                ),
                contexts: [.global, .terminalAppOwned]
            )
        case .nextTab:
            return .init(
                trigger: .init(key: .character(.l), modifiers: [.command]),
                contexts: [.global, .terminalAppOwned]
            )
        case .prevTab:
            return .init(
                trigger: .init(key: .character(.j), modifiers: [.command]),
                contexts: [.global, .terminalAppOwned]
            )
        case .showArrangementPanel:
            return .init(
                trigger: .init(key: .character(.i), modifiers: [.command, .option]),
                contexts: [.global, .terminalAppOwned]
            )
        case .previousArrangement:
            return .init(
                trigger: .init(key: .character(.j), modifiers: [.command, .option]),
                contexts: [.global, .terminalAppOwned]
            )
        case .nextArrangement:
            return .init(
                trigger: .init(key: .character(.l), modifiers: [.command, .option]),
                contexts: [.global, .terminalAppOwned]
            )
        case .zoomPane:
            return .init(
                trigger: .init(key: .enter, modifiers: [.command, .shift]),
                contexts: [.global, .terminalAppOwned]
            )
        case .showViewer:
            return .init(
                trigger: .init(key: .character(.o), modifiers: [.command]),
                contexts: [.global, .terminalAppOwned]
            )
        case .addDrawerPane:
            // Primary: cmd-shift-D fires globally (also in
            // terminal-app-owned context). Alternate: raw-character
            // P fires in `.emptyDrawer` (gated on neutral responder
            // upstream so text fields still receive the keystroke).
            return .init(
                trigger: .init(key: .character(.d), modifiers: [.command, .shift]),
                alternateTriggers: [
                    .init(key: .character(.p), modifiers: []): [.emptyDrawer]
                ],
                contexts: [.global, .terminalAppOwned, .emptyDrawer]
            )
        case .toggleDrawer:
            return .init(
                trigger: .init(key: .character(.d), modifiers: [.command]),
                contexts: [.global, .terminalAppOwned]
            )
        case .showBrowserTabs:
            // Chrome's Search Tabs binding; fires only while a browser pane is focused.
            return .init(
                trigger: .init(key: .character(.a), modifiers: [.command, .shift]),
                contexts: [.global]
            )
        case .scrollToBottom:
            return .init(
                trigger: .init(key: .character(.k), modifiers: [.command, .option]),
                contexts: [.terminalAppOwned]
            )
        case .scrollPageUp:
            return .init(
                trigger: .init(key: .character(.i), modifiers: [.command, .shift]),
                contexts: [.terminalAppOwned]
            )
        case .scrollPageDown:
            return .init(
                trigger: .init(key: .character(.k), modifiers: [.command, .shift]),
                contexts: [.terminalAppOwned]
            )
        case .scrollSmallStepUp:
            return .init(
                trigger: .init(key: .character(.j), modifiers: [.command, .shift]),
                contexts: [.terminalAppOwned]
            )
        case .scrollSmallStepDown:
            return .init(
                trigger: .init(key: .character(.l), modifiers: [.command, .shift]),
                contexts: [.terminalAppOwned]
            )
        case .jumpToPreviousPrompt:
            return .init(
                trigger: .init(key: .character(.j), modifiers: [.option, .shift]),
                contexts: [.terminalAppOwned]
            )
        case .jumpToNextPrompt:
            return .init(
                trigger: .init(key: .character(.l), modifiers: [.option, .shift]),
                contexts: [.terminalAppOwned]
            )
        case .openPaneLocationInBookmarkedEditor:
            return .init(
                trigger: .init(key: .character(.o), modifiers: [.command, .option]),
                contexts: [.global, .terminalAppOwned]
            )
        case .openPaneLocationInFinder:
            return .init(
                trigger: .init(key: .character(.o), modifiers: [.command, .shift]),
                contexts: [.global, .terminalAppOwned]
            )
        case .openPaneLocationInEditorMenu:
            return .init(
                trigger: .init(key: .character(.o), modifiers: [.command, .control, .option]),
                contexts: [.global, .terminalAppOwned]
            )
        case .editPaneNote:
            return .init(
                trigger: .init(key: .character(.n), modifiers: [.command, .option, .shift]),
                contexts: [.global, .terminalAppOwned]
            )
        case .copyCurrentPanePath:
            return .init(
                trigger: .init(key: .character(.o), modifiers: [.option]),
                contexts: [.global, .terminalAppOwned]
            )
        case .toggleManagementLayer:
            return .init(
                trigger: .init(key: .character(.r), modifiers: [.command]),
                contexts: [.global, .terminalAppOwned]
            )
        case .toggleSidebar:
            return .init(
                trigger: .init(key: .character(.s), modifiers: [.command]),
                contexts: [.global, .terminalAppOwned]
            )
        case .focusSidebar:
            return .init(
                trigger: .init(key: .character(.s), modifiers: [.command, .shift]),
                contexts: [.global, .terminalAppOwned]
            )
        case .filterSidebar:
            return .init(
                trigger: .init(key: .character(.f), modifiers: [.command]),
                alternateTriggers: [
                    .init(key: .character(.f), modifiers: []): [.sidebarList]
                ],
                contexts: [.global, .sidebarList]
            )
        case .showInboxNotifications:
            return .init(
                trigger: .init(key: .character(.u), modifiers: [.command]),
                contexts: [.global, .terminalAppOwned]
            )
        case .showPaneInboxNotifications:
            return .init(
                trigger: .init(key: .character(.u), modifiers: [.command, .shift]),
                contexts: [.global, .terminalAppOwned]
            )
        case .showReposSidebar:
            return .init(
                trigger: .init(key: .character(.r), modifiers: []),
                contexts: [.sidebarList]
            )
        case .showPanesSidebar:
            return .init(
                trigger: .init(key: .character(.p), modifiers: []),
                contexts: [.sidebarList]
            )
        case .togglePanesShowsDrawers:
            return .init(
                trigger: .init(key: .character(.d), modifiers: [.shift]),
                alternateTriggers: [
                    .init(key: .character(.d), modifiers: []): [.sidebarList]
                ],
                contexts: [.sidebarList]
            )
        case .newWindow:
            return .init(
                trigger: .init(key: .character(.n), modifiers: [.command]),
                contexts: [.global]
            )
        case .showCommandBarEverything:
            return .init(
                trigger: .init(key: .character(.p), modifiers: [.command]),
                contexts: [.global, .terminalAppOwned]
            )
        case .showCommandBarCommands:
            return .init(
                trigger: .init(key: .character(.p), modifiers: [.command, .shift]),
                contexts: [.global, .terminalAppOwned]
            )
        case .showCommandBarPanes:
            return .init(
                trigger: .init(key: .character(.p), modifiers: [.command, .option]),
                contexts: [.global, .terminalAppOwned]
            )
        case .selectTab1:
            return Self.selectTabSpec(key: .digit1)
        case .selectTab2:
            return Self.selectTabSpec(key: .digit2)
        case .selectTab3:
            return Self.selectTabSpec(key: .digit3)
        case .selectTab4:
            return Self.selectTabSpec(key: .digit4)
        case .selectTab5:
            return Self.selectTabSpec(key: .digit5)
        case .selectTab6:
            return Self.selectTabSpec(key: .digit6)
        case .selectTab7:
            return Self.selectTabSpec(key: .digit7)
        case .selectTab8:
            return Self.selectTabSpec(key: .digit8)
        case .selectTab9:
            return Self.selectTabSpec(key: .digit9)
        case .focusPane1:
            return Self.focusPaneSpec(key: .digit1)
        case .focusPane2:
            return Self.focusPaneSpec(key: .digit2)
        case .focusPane3:
            return Self.focusPaneSpec(key: .digit3)
        case .focusPane4:
            return Self.focusPaneSpec(key: .digit4)
        case .focusPane5:
            return Self.focusPaneSpec(key: .digit5)
        case .focusPane6:
            return Self.focusPaneSpec(key: .digit6)
        case .focusPane7:
            return Self.focusPaneSpec(key: .digit7)
        case .focusPane8:
            return Self.focusPaneSpec(key: .digit8)
        case .focusPane9:
            return Self.focusPaneSpec(key: .digit9)
        case .managementLayerFocusLeft:
            return Self.managementSpec(key: .arrow(.left))
        case .managementLayerFocusRight:
            return Self.managementSpec(key: .arrow(.right))
        case .managementLayerEnterDrawer:
            return Self.managementSpec(key: .enter)
        case .managementLayerExitDrawer:
            return Self.managementSpec(key: .arrow(.up))
        case .managementLayerOpenDrawer:
            return Self.managementSpec(
                key: .character(.d),
                alternateTriggers: [
                    .init(key: .arrow(.down), modifiers: []): [.managementLayer]
                ]
            )
        case .managementLayerCreateTerminal:
            return Self.managementSpec(key: .character(.p))
        case .managementLayerCreateBrowser:
            return Self.managementSpec(key: .character(.b))
        case .managementLayerExit:
            return Self.managementSpec(key: .character(.r))
        }
    }

    package var trigger: ShortcutTrigger { spec.trigger }

    /// All triggers (primary + alternates) that dispatch this command.
    var triggers: [ShortcutTrigger] { [spec.trigger] + Array(spec.alternateTriggers.keys) }

    package var command: AppCommand {
        switch self {
        case .newTab:
            return .showCommandBarQuickOpen
        case .undoCloseTab:
            return .undoCloseTab
        case .focusPreviousPinnedPane: return .focusPreviousPinnedPane
        case .focusNextPinnedPane: return .focusNextPinnedPane
        case .nextTab:
            return .nextTab
        case .prevTab:
            return .prevTab
        case .showArrangementPanel:
            return .switchArrangement
        case .previousArrangement:
            return .previousArrangement
        case .nextArrangement:
            return .nextArrangement
        case .zoomPane:
            return .zoomPane
        case .showViewer:
            return .showViewer
        case .showBrowserTabs:
            return .showBrowserTabs
        case .addDrawerPane:
            return .addDrawerPane
        case .toggleDrawer:
            return .toggleDrawer
        case .scrollToBottom:
            return .scrollToBottom
        case .scrollPageUp:
            return .scrollPageUp
        case .scrollPageDown:
            return .scrollPageDown
        case .scrollSmallStepUp:
            return .scrollSmallStepUp
        case .scrollSmallStepDown:
            return .scrollSmallStepDown
        case .jumpToPreviousPrompt:
            return .jumpToPreviousPrompt
        case .jumpToNextPrompt:
            return .jumpToNextPrompt
        case .openPaneLocationInBookmarkedEditor:
            return .openPaneLocationInBookmarkedEditor
        case .openPaneLocationInFinder:
            return .openPaneLocationInFinder
        case .openPaneLocationInEditorMenu:
            return .openPaneLocationInEditorMenu
        case .editPaneNote:
            return .editPaneNote
        case .copyCurrentPanePath:
            return .copyCurrentPanePath
        case .toggleManagementLayer:
            return .toggleManagementLayer
        case .toggleSidebar:
            return .toggleSidebar
        case .focusSidebar:
            return .focusSidebar
        case .filterSidebar:
            return .filterSidebar
        case .showInboxNotifications:
            return .showInboxNotifications
        case .showPaneInboxNotifications:
            return .showPaneInboxNotifications
        case .showReposSidebar:
            return .showReposSidebar
        case .showPanesSidebar:
            return .showPanesSidebar
        case .togglePanesShowsDrawers:
            return .togglePanesShowsDrawers
        case .newWindow:
            return .newWindow
        case .showCommandBarEverything:
            return .showCommandBarEverything
        case .showCommandBarCommands:
            return .showCommandBarCommands
        case .showCommandBarPanes:
            return .showCommandBarPanes
        case .selectTab1:
            return .selectTab1
        case .selectTab2:
            return .selectTab2
        case .selectTab3:
            return .selectTab3
        case .selectTab4:
            return .selectTab4
        case .selectTab5:
            return .selectTab5
        case .selectTab6:
            return .selectTab6
        case .selectTab7:
            return .selectTab7
        case .selectTab8:
            return .selectTab8
        case .selectTab9:
            return .selectTab9
        case .focusPane1:
            return .focusPane1
        case .focusPane2:
            return .focusPane2
        case .focusPane3:
            return .focusPane3
        case .focusPane4:
            return .focusPane4
        case .focusPane5:
            return .focusPane5
        case .focusPane6:
            return .focusPane6
        case .focusPane7:
            return .focusPane7
        case .focusPane8:
            return .focusPane8
        case .focusPane9:
            return .focusPane9
        case .managementLayerFocusLeft:
            return .managementLayerFocusLeft
        case .managementLayerFocusRight:
            return .managementLayerFocusRight
        case .managementLayerEnterDrawer:
            return .managementLayerEnterDrawer
        case .managementLayerExitDrawer:
            return .managementLayerExitDrawer
        case .managementLayerOpenDrawer:
            return .managementLayerOpenDrawer
        case .managementLayerCreateTerminal:
            return .managementLayerCreateTerminal
        case .managementLayerCreateBrowser:
            return .managementLayerCreateBrowser
        case .managementLayerExit:
            return .managementLayerExit
        }
    }
    package var contexts: Set<ShortcutContext> { spec.contexts }
}

extension AppShortcut {
    package var requiresPaneTargetFallback: Bool {
        switch self {
        case .addDrawerPane:
            return true
        case .undoCloseTab, .newTab, .nextTab, .prevTab,
            .focusPreviousPinnedPane, .focusNextPinnedPane, .showArrangementPanel,
            .previousArrangement, .nextArrangement, .zoomPane, .showViewer, .showBrowserTabs,
            .toggleDrawer, .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollSmallStepUp, .scrollSmallStepDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .openPaneLocationInBookmarkedEditor,
            .openPaneLocationInFinder, .openPaneLocationInEditorMenu, .editPaneNote,
            .copyCurrentPanePath, .toggleManagementLayer, .toggleSidebar, .focusSidebar, .filterSidebar,
            .showInboxNotifications, .showPaneInboxNotifications, .showReposSidebar, .showPanesSidebar,
            .togglePanesShowsDrawers,
            .newWindow, .showCommandBarEverything, .showCommandBarCommands,
            .showCommandBarPanes, .selectTab1, .selectTab2, .selectTab3, .selectTab4,
            .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectTab9, .focusPane1,
            .focusPane2, .focusPane3, .focusPane4, .focusPane5, .focusPane6, .focusPane7,
            .focusPane8, .focusPane9, .managementLayerFocusLeft, .managementLayerFocusRight,
            .managementLayerEnterDrawer, .managementLayerExitDrawer, .managementLayerOpenDrawer,
            .managementLayerCreateTerminal, .managementLayerCreateBrowser, .managementLayerExit:
            return false
        }
    }

    package func displayKeyBinding(in context: ShortcutContext) -> KeyBinding? {
        spec.displayTrigger(in: context)?.keyBinding
    }

    fileprivate static func selectTabSpec(key: ShortcutCharacterKey) -> AppShortcutSpec {
        .init(
            trigger: .init(key: .character(key), modifiers: [.command]),
            contexts: [.global, .terminalAppOwned]
        )
    }

    fileprivate static func focusPaneSpec(key: ShortcutCharacterKey) -> AppShortcutSpec {
        .init(
            trigger: .init(key: .character(key), modifiers: [.option]),
            contexts: [.global, .terminalAppOwned]
        )
    }

    fileprivate static func managementSpec(
        key: ShortcutInputKey,
        alternateTriggers: [ShortcutTrigger: Set<ShortcutContext>] = [:]
    ) -> AppShortcutSpec {
        .init(
            trigger: .init(key: key, modifiers: []),
            alternateTriggers: alternateTriggers,
            contexts: [.managementLayer]
        )
    }
}

package enum ShortcutDecoder {
    package static func decode(event: NSEvent) -> ShortcutTrigger? {
        decode(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
    }

    package static func decode(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> ShortcutTrigger? {
        let modifiers = shortcutModifiers(from: modifierFlags)

        switch keyCode {
        case 36, 76:
            return .init(key: .enter, modifiers: modifiers)
        case 53:
            return .init(key: .escape, modifiers: modifiers)
        case 123:
            return .init(key: .arrow(.left), modifiers: modifiers)
        case 124:
            return .init(key: .arrow(.right), modifiers: modifiers)
        case 125:
            return .init(key: .arrow(.down), modifiers: modifiers)
        case 126:
            return .init(key: .arrow(.up), modifiers: modifiers)
        default:
            break
        }

        guard let charactersIgnoringModifiers else { return nil }
        let normalized = normalizeCharacter(charactersIgnoringModifiers)
        guard let key = ShortcutCharacterKey(rawValue: normalized) else { return nil }
        return .init(key: .character(key), modifiers: modifiers)
    }

    package static func shortcut(
        for trigger: ShortcutTrigger,
        in context: ShortcutContext
    ) -> AppShortcut? {
        AppShortcut.allCases.first { shortcut in
            guard shortcut != .showInboxNotifications,
                shortcut != .showPaneInboxNotifications
            else { return false }
            return shortcut.spec.matches(trigger, in: context)
        }
    }

    private static func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<KeyBinding.Modifier> {
        let normalizedFlags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers = Set<KeyBinding.Modifier>()
        if normalizedFlags.contains(.command) { modifiers.insert(.command) }
        if normalizedFlags.contains(.control) { modifiers.insert(.control) }
        if normalizedFlags.contains(.option) { modifiers.insert(.option) }
        if normalizedFlags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    private static func normalizeCharacter(_ charactersIgnoringModifiers: String) -> String {
        switch charactersIgnoringModifiers {
        case "\u{1B}":
            return ShortcutCharacterKey.leftBracket.rawValue
        default:
            return charactersIgnoringModifiers.lowercased()
        }
    }
}
