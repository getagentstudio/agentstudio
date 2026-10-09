import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite(.serialized)
struct ShortcutCatalogTests {
    @Test("D in the sidebar list toggles drawer rows without changing Command-D")
    func sidebarDrawerRowsUseScopedD() {
        let bareD = ShortcutTrigger(key: .character(.d), modifiers: [])
        let commandD = ShortcutTrigger(key: .character(.d), modifiers: [.command])
        #expect(ShortcutDecoder.shortcut(for: bareD, in: .sidebarList) == .togglePanesShowsDrawers)
        #expect(ShortcutDecoder.shortcut(for: bareD, in: .global) == nil)
        #expect(ShortcutDecoder.shortcut(for: commandD, in: .global) == .toggleDrawer)
    }

    @Test("superseded quarter-step identities have no aliases")
    func obsoleteQuarterStepIdentitiesAreRemoved() {
        for identifier in ["scrollQuarterPageUp", "scrollQuarterPageDown"] {
            #expect(AppCommand(rawValue: identifier) == nil)
            #expect(AppShortcut(rawValue: identifier) == nil)
        }
    }

    @Test("terminal navigation keeps scrolling on Command-Shift")
    func terminalNavigationFamilyUsesSettledMap() {
        let bindings: [(ShortcutTrigger, String)] = [
            (.init(key: .character(.i), modifiers: [.command, .shift]), "scrollPageUp"),
            (.init(key: .character(.k), modifiers: [.command, .shift]), "scrollPageDown"),
            (.init(key: .character(.j), modifiers: [.command, .shift]), "scrollSmallStepUp"),
            (.init(key: .character(.l), modifiers: [.command, .shift]), "scrollSmallStepDown"),
            (.init(key: .character(.j), modifiers: [.option, .shift]), "jumpToPreviousPrompt"),
            (.init(key: .character(.l), modifiers: [.option, .shift]), "jumpToNextPrompt"),
            (.init(key: .character(.k), modifiers: [.command, .option]), "scrollToBottom"),
        ]
        for (trigger, commandID) in bindings {
            #expect(ShortcutDecoder.shortcut(for: trigger, in: .terminalAppOwned)?.command.rawValue == commandID)
            #expect(ShortcutDecoder.shortcut(for: trigger, in: .global) == nil)
        }
        #expect(
            ShortcutDecoder.shortcut(
                for: .init(key: .character(.i), modifiers: [.option, .shift]), in: .terminalAppOwned
            ) == nil
        )
        #expect(
            ShortcutDecoder.shortcut(
                for: .init(key: .character(.k), modifiers: [.option, .shift]), in: .terminalAppOwned
            ) == nil
        )
    }

    @Test
    func everyShortcutHasASpec() {
        for shortcut in AppShortcut.allCases {
            let spec = shortcut.spec
            #expect(!spec.contexts.isEmpty)
        }
    }

    @Test("close commands have no shortcut and Undo Close keeps its canonical binding")
    func closeCommandsAreClickOnlyAndUndoCloseKeepsIdentity() {
        #expect(AppCommand.closeTab.definition.shortcut == nil)
        #expect(AppCommand.closeWindow.definition.shortcut == nil)
        #expect(AppCommand.closePane.definition.shortcut == nil)
        #expect(AppCommand.closeDrawerPane.definition.shortcut == nil)
        #expect(AppCommand.closeWindow.definition.surfacePolicy.exposes(.mainMenu))

        #expect(AppCommand.undoCloseTab.rawValue == "undoCloseTab")
        #expect(AppCommand.undoCloseTab.definition.shortcut == .undoCloseTab)
        #expect(AppCommand.undoCloseTab.definition.label == "Undo Close")
        #expect(AppCommand.undoCloseTab.definition.helpText == "Reopen the most recently closed pane or tab")

        #expect(
            ShortcutDecoder.shortcut(
                for: .init(key: .character(.w), modifiers: [.command]),
                in: .global
            ) == nil
        )
        #expect(
            ShortcutDecoder.shortcut(
                for: .init(key: .character(.w), modifiers: [.command, .shift]),
                in: .global
            ) == nil
        )
    }

    @Test
    func shortcutCatalog_declaresPaneTargetFallbacks() {
        for shortcut in AppShortcut.allCases {
            #expect(shortcut.requiresPaneTargetFallback == (shortcut == .addDrawerPane))
        }
    }

    @Test
    func shortcutTriggers_areUniqueWithinEachContext() {
        var seen: [ShortcutContext: Set<ShortcutTrigger>] = [:]

        for shortcut in AppShortcut.allCases {
            let spec = shortcut.spec
            for context in spec.contexts {
                let inserted = seen[context, default: []].insert(spec.trigger).inserted
                #expect(
                    inserted,
                    "Duplicate shortcut trigger \(String(describing: spec.trigger)) in context \(String(describing: context))"
                )
            }
            for (trigger, contexts) in spec.alternateTriggers {
                for context in contexts {
                    let inserted = seen[context, default: []].insert(trigger).inserted
                    #expect(
                        inserted,
                        "Duplicate shortcut trigger \(String(describing: trigger)) in context \(String(describing: context))"
                    )
                }
            }
        }
    }

    @Test
    func shortcutAndCommandDefinitions_stayBidirectionallyConsistent() {
        for shortcut in AppShortcut.allCases {
            let definition = shortcut.command.definition
            if shortcut == .showInboxNotifications || shortcut == .showPaneInboxNotifications {
                #expect(definition.shortcut == nil)
            } else {
                #expect(definition.shortcut == shortcut)
            }
        }
    }

    @Test
    func commandSpecDerivesGlobalKeyBindingFromShortcut() {
        let managementLayerDefinition = AppCommand.toggleManagementLayer.definition
        let quickOpenDefinition = AppCommand.showCommandBarEverything.definition
        let terminalQuickOpenDefinition = AppCommand.showCommandBarQuickOpen.definition
        let addDrawerPaneDefinition = AppCommand.addDrawerPane.definition
        let paneInboxDefinition = AppCommand.showPaneInboxNotifications.definition

        #expect(managementLayerDefinition.globalKeyBinding?.key == "r")
        #expect(managementLayerDefinition.globalKeyBinding?.modifiers == [.command])
        #expect(quickOpenDefinition.globalKeyBinding?.key == "p")
        #expect(quickOpenDefinition.globalKeyBinding?.modifiers == [.command])
        #expect(terminalQuickOpenDefinition.globalKeyBinding?.key == "t")
        #expect(terminalQuickOpenDefinition.globalKeyBinding?.modifiers == [.command])
        #expect(addDrawerPaneDefinition.globalKeyBinding?.key == "d")
        #expect(addDrawerPaneDefinition.globalKeyBinding?.modifiers == [.command, .shift])
        #expect(paneInboxDefinition.globalKeyBinding == nil)
        #expect(paneInboxDefinition.actionSpec.label == "Toggle Pane Inbox")
    }

    @Test
    func shortcutDecoder_decodesGlobalCommandBarShortcuts() {
        let quickOpen = ShortcutDecoder.shortcut(
            for: .init(key: .character(.p), modifiers: [.command]),
            in: .global
        )
        let commandPalette = ShortcutDecoder.shortcut(
            for: .init(key: .character(.p), modifiers: [.command, .shift]),
            in: .global
        )
        let panePicker = ShortcutDecoder.shortcut(
            for: .init(key: .character(.p), modifiers: [.command, .option]),
            in: .global
        )
        let smartNewTab = ShortcutDecoder.shortcut(
            for: .init(key: .character(.t), modifiers: [.command]),
            in: .global
        )

        #expect(quickOpen == .showCommandBarEverything)
        #expect(commandPalette == .showCommandBarCommands)
        #expect(panePicker == .showCommandBarPanes)
        #expect(smartNewTab == .newTab)
    }

    @Test
    func shortcutDecoder_commandSTogglesSidebar() {
        let showInbox = ShortcutDecoder.shortcut(
            for: .init(key: .character(.u), modifiers: [.command]),
            in: .global
        )
        let toggleSidebar = ShortcutDecoder.shortcut(
            for: .init(key: .character(.s), modifiers: [.command]),
            in: .global
        )
        let terminalToggleSidebar = ShortcutDecoder.shortcut(
            for: .init(key: .character(.s), modifiers: [.command]),
            in: .terminalAppOwned
        )

        #expect(showInbox == nil)
        #expect(toggleSidebar == .toggleSidebar)
        #expect(terminalToggleSidebar == .toggleSidebar)
    }

    @Test
    func reposSidebar_hasNoGlobalDisplayOrMenuBinding() {
        let definition = AppCommand.showReposSidebar.definition

        #expect(AppShortcut.showReposSidebar.displayKeyBinding(in: .global) == nil)
        #expect(definition.globalKeyBinding == nil)
    }

    @Test
    func sidebarListBindings_areExactToSidebarContext() {
        let showPanes = ShortcutDecoder.shortcut(
            for: .init(key: .character(.p), modifiers: []),
            in: .sidebarList
        )
        let showRepos = ShortcutDecoder.shortcut(
            for: .init(key: .character(.r), modifiers: []),
            in: .sidebarList
        )
        let showFilter = ShortcutDecoder.shortcut(
            for: .init(key: .character(.f), modifiers: []),
            in: .sidebarList
        )

        #expect(showPanes == .showPanesSidebar)
        #expect(showRepos == .showReposSidebar)
        #expect(showFilter == .filterSidebar)
        #expect(AppShortcut.showPanesSidebar.spec.displayTrigger(in: .global) == nil)
        #expect(AppShortcut.showReposSidebar.spec.displayTrigger(in: .global) == nil)
        #expect(AppShortcut.filterSidebar.spec.displayTrigger(in: .sidebarList)?.modifiers.isEmpty == true)
    }

    @Test
    func shortcutDecoder_commandShiftSFocusesSidebar() {
        let focusSidebar = ShortcutDecoder.shortcut(
            for: .init(key: .character(.s), modifiers: [.command, .shift]),
            in: .global
        )
        let terminalFocusSidebar = ShortcutDecoder.shortcut(
            for: .init(key: .character(.s), modifiers: [.command, .shift]),
            in: .terminalAppOwned
        )

        #expect(focusSidebar == .focusSidebar)
        #expect(terminalFocusSidebar == .focusSidebar)
    }

    @Test
    func shortcutDecoder_rejectsBareSidebarLettersInGlobalContext() {
        let barePanes = ShortcutDecoder.shortcut(
            for: .init(key: .character(.p), modifiers: []),
            in: .global
        )
        let bareRepos = ShortcutDecoder.shortcut(
            for: .init(key: .character(.r), modifiers: []),
            in: .global
        )
        let bareFilter = ShortcutDecoder.shortcut(
            for: .init(key: .character(.f), modifiers: []),
            in: .global
        )

        #expect(barePanes == nil)
        #expect(bareRepos == nil)
        #expect(bareFilter == nil)
    }

    @Test
    func shortcutDecoder_decodesTabAndArrangementShortcuts() {
        let previousTab = ShortcutDecoder.shortcut(
            for: .init(key: .character(.j), modifiers: [.command]),
            in: .global
        )
        let nextTab = ShortcutDecoder.shortcut(
            for: .init(key: .character(.l), modifiers: [.command]),
            in: .global
        )
        let showArrangements = ShortcutDecoder.shortcut(
            for: .init(key: .character(.i), modifiers: [.command, .option]),
            in: .global
        )
        let previousArrangement = ShortcutDecoder.shortcut(
            for: .init(key: .character(.j), modifiers: [.command, .option]),
            in: .global
        )
        let nextArrangement = ShortcutDecoder.shortcut(
            for: .init(key: .character(.l), modifiers: [.command, .option]),
            in: .global
        )

        #expect(previousTab == .prevTab)
        #expect(nextTab == .nextTab)
        #expect(showArrangements == .showArrangementPanel)
        #expect(previousArrangement == .previousArrangement)
        #expect(nextArrangement == .nextArrangement)
    }

    @Test
    func shortcutDecoder_decodesTabAndPaneOrdinalShortcuts() {
        let firstTab = ShortcutDecoder.shortcut(
            for: .init(key: .character(.digit1), modifiers: [.command]),
            in: .global
        )
        let ninthTabFromTerminal = ShortcutDecoder.shortcut(
            for: .init(key: .character(.digit9), modifiers: [.command]),
            in: .terminalAppOwned
        )
        let firstMainPane = ShortcutDecoder.shortcut(
            for: .init(key: .character(.digit1), modifiers: [.option]),
            in: .global
        )
        let ninthMainPaneFromTerminal = ShortcutDecoder.shortcut(
            for: .init(key: .character(.digit9), modifiers: [.option]),
            in: .terminalAppOwned
        )

        #expect(firstTab == .selectTab1)
        #expect(ninthTabFromTerminal == .selectTab9)
        #expect(firstMainPane == .focusPane1)
        #expect(ninthMainPaneFromTerminal == .focusPane9)
    }

    @Test
    func shortcutDecoder_rejectsRetiredPaneInboxShortcut() {
        let showPaneInbox = ShortcutDecoder.shortcut(
            for: .init(key: .character(.u), modifiers: [.command, .shift]),
            in: .global
        )
        let terminalShowPaneInbox = ShortcutDecoder.shortcut(
            for: .init(key: .character(.u), modifiers: [.command, .shift]),
            in: .terminalAppOwned
        )

        #expect(showPaneInbox == nil)
        #expect(terminalShowPaneInbox == nil)
    }

    @Test
    func shortcutDecoder_decodesSidebarSurfaceShortcutsInTerminalPanes() {
        let showInbox = ShortcutDecoder.shortcut(
            for: .init(key: .character(.u), modifiers: [.command]),
            in: .terminalAppOwned
        )
        let toggleSidebar = ShortcutDecoder.shortcut(
            for: .init(key: .character(.s), modifiers: [.command]),
            in: .terminalAppOwned
        )

        #expect(showInbox == nil)
        #expect(toggleSidebar == .toggleSidebar)
    }

    @Test
    func shortcutDecoder_decodesSidebarFilterShortcut() {
        let showFilter = ShortcutDecoder.shortcut(
            for: .init(key: .character(.f), modifiers: [.command]),
            in: .global
        )

        #expect(showFilter == .filterSidebar)
    }

    @Test
    func shortcutDecoder_decodesAddDrawerPaneShortcut() {
        let addDrawerPane = ShortcutDecoder.shortcut(
            for: .init(key: .character(.d), modifiers: [.command, .shift]),
            in: .global
        )
        let rawPGlobal = ShortcutDecoder.shortcut(
            for: .init(key: .character(.p), modifiers: []),
            in: .global
        )
        let rawPTerminal = ShortcutDecoder.shortcut(
            for: .init(key: .character(.p), modifiers: []),
            in: .terminalAppOwned
        )
        let rawPEmptyDrawer = ShortcutDecoder.shortcut(
            for: .init(key: .character(.p), modifiers: []),
            in: .emptyDrawer
        )

        #expect(addDrawerPane == .addDrawerPane)
        #expect(rawPGlobal == nil)
        #expect(rawPTerminal == nil)
        #expect(rawPEmptyDrawer == .addDrawerPane)
    }

    @Test
    func shortcutDecoder_decodesTerminalScrollAndPromptShortcuts() {
        let scrollToBottom = ShortcutDecoder.shortcut(
            for: .init(key: .character(.k), modifiers: [.command, .option]),
            in: .terminalAppOwned
        )
        let previousPrompt = ShortcutDecoder.shortcut(
            for: .init(key: .character(.j), modifiers: [.option, .shift]),
            in: .terminalAppOwned
        )
        let nextPrompt = ShortcutDecoder.shortcut(
            for: .init(key: .character(.l), modifiers: [.option, .shift]),
            in: .terminalAppOwned
        )
        let pageUp = ShortcutDecoder.shortcut(
            for: .init(key: .character(.i), modifiers: [.command, .shift]),
            in: .terminalAppOwned
        )
        let pageDown = ShortcutDecoder.shortcut(
            for: .init(key: .character(.k), modifiers: [.command, .shift]),
            in: .terminalAppOwned
        )
        let smallStepUp = ShortcutDecoder.shortcut(
            for: .init(key: .character(.j), modifiers: [.command, .shift]),
            in: .terminalAppOwned
        )
        let smallStepDown = ShortcutDecoder.shortcut(
            for: .init(key: .character(.l), modifiers: [.command, .shift]),
            in: .terminalAppOwned
        )
        let unassignedOptionShiftI = ShortcutDecoder.shortcut(
            for: .init(key: .character(.i), modifiers: [.option, .shift]),
            in: .terminalAppOwned
        )
        let ghosttyClearScrollback = ShortcutDecoder.shortcut(
            for: .init(key: .character(.k), modifiers: [.command]),
            in: .terminalAppOwned
        )

        #expect(scrollToBottom == .scrollToBottom)
        #expect(previousPrompt == .jumpToPreviousPrompt)
        #expect(nextPrompt == .jumpToNextPrompt)
        #expect(pageUp == .scrollPageUp)
        #expect(pageDown == .scrollPageDown)
        #expect(smallStepUp == .scrollSmallStepUp)
        #expect(smallStepDown == .scrollSmallStepDown)
        #expect(unassignedOptionShiftI == nil)
        #expect(ghosttyClearScrollback == nil)
    }

    @Test
    func shortcutDecoder_decodesViewerAndEditorShortcuts() {
        let showViewer = ShortcutDecoder.shortcut(
            for: .init(key: .character(.o), modifiers: [.command]),
            in: .global
        )
        let openFinder = ShortcutDecoder.shortcut(
            for: .init(key: .character(.o), modifiers: [.command, .shift]),
            in: .global
        )
        let openBookmarkedEditor = ShortcutDecoder.shortcut(
            for: .init(key: .character(.o), modifiers: [.command, .option]),
            in: .global
        )
        let openChooser = ShortcutDecoder.shortcut(
            for: .init(key: .character(.o), modifiers: [.command, .control, .option]),
            in: .global
        )

        #expect(showViewer?.rawValue == "showViewer")
        #expect(openBookmarkedEditor == .openPaneLocationInBookmarkedEditor)
        #expect(openFinder == .openPaneLocationInFinder)
        #expect(openChooser == .openPaneLocationInEditorMenu)
    }

    @Test
    func shortcutDecoder_decodesPaneZoomNoteAndCurrentPathShortcuts() {
        let zoomPane = ShortcutDecoder.shortcut(
            for: .init(key: .enter, modifiers: [.command, .shift]),
            in: .global
        )
        let editNote = ShortcutDecoder.shortcut(
            for: .init(key: .character(.n), modifiers: [.command, .option, .shift]),
            in: .global
        )
        let copyPath = ShortcutDecoder.shortcut(
            for: .init(key: .character(.o), modifiers: [.option]),
            in: .terminalAppOwned
        )

        #expect(zoomPane?.rawValue == "zoomPane")
        #expect(editNote == .editPaneNote)
        #expect(copyPath == .copyCurrentPanePath)
        #expect(AppShortcut.editPaneNote.command == .editPaneNote)
        #expect(AppShortcut.copyCurrentPanePath.command == .copyCurrentPanePath)
    }

    @Test
    func watchFolder_hasNoKeyboardShortcut() {
        let shortcuts = AppShortcut.allCases.filter { $0.command == .watchFolder }

        #expect(shortcuts.isEmpty)
    }

    @Test
    func shortcutDecoder_decodesCharacterAndEscapeEvents() {
        let managementToggle = ShortcutDecoder.decode(
            keyCode: 15,
            modifierFlags: [.command],
            charactersIgnoringModifiers: "r"
        )
        let escape = ShortcutDecoder.decode(
            keyCode: 53,
            modifierFlags: [],
            charactersIgnoringModifiers: nil
        )

        #expect(managementToggle == .init(key: .character(.r), modifiers: [.command]))
        #expect(escape == .init(key: .escape, modifiers: []))
    }

    @Test
    func shortcutCatalog_decodesDrawerMovementLetters() {
        let expectations: [(String, ShortcutTrigger)] = [
            ("i", .init(key: .character(.i), modifiers: [.option])),
            ("j", .init(key: .character(.j), modifiers: [.option])),
            ("k", .init(key: .character(.k), modifiers: [.option])),
            ("l", .init(key: .character(.l), modifiers: [.option])),
        ]

        for (character, expected) in expectations {
            let decoded = ShortcutDecoder.decode(
                keyCode: 0,
                modifierFlags: [.option],
                charactersIgnoringModifiers: character
            )
            #expect(decoded == expected)
        }
    }

    @Test
    func shortcutDecoder_decodesManagementShortcuts() {
        let focusLeft = ShortcutDecoder.shortcut(
            for: .init(key: .arrow(.left), modifiers: []),
            in: .managementLayer
        )
        let openDrawer = ShortcutDecoder.shortcut(
            for: .init(key: .character(.d), modifiers: []),
            in: .managementLayer
        )
        let openDrawerWithDownArrow = ShortcutDecoder.shortcut(
            for: .init(key: .arrow(.down), modifiers: []),
            in: .managementLayer
        )
        let exitMode = ShortcutDecoder.shortcut(
            for: .init(key: .character(.r), modifiers: []),
            in: .managementLayer
        )

        #expect(focusLeft == .managementLayerFocusLeft)
        #expect(openDrawer == .managementLayerOpenDrawer)
        #expect(openDrawerWithDownArrow == .managementLayerOpenDrawer)
        #expect(exitMode == .managementLayerExit)
    }

    @Test
    func shortcutDecoder_normalizesArrowKeyModifiers() {
        let trigger = ShortcutDecoder.decode(
            keyCode: 123,
            modifierFlags: [.numericPad],
            charactersIgnoringModifiers: nil
        )

        #expect(trigger == .init(key: .arrow(.left), modifiers: []))
    }

    @Test
    func shortcutDecoder_normalizesLeftBracketAndRejectsUnknownCharacters() {
        let leftBracket = ShortcutDecoder.decode(
            keyCode: 33,
            modifierFlags: [.command],
            charactersIgnoringModifiers: "\u{1B}"
        )
        let unknown = ShortcutDecoder.decode(
            keyCode: 999,
            modifierFlags: [],
            charactersIgnoringModifiers: "~"
        )

        #expect(leftBracket == .init(key: .character(.leftBracket), modifiers: [.command]))
        #expect(unknown == nil)
    }
}
