import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("PaneTabViewController global shortcut routing", .serialized)
struct PaneTabViewControllerGlobalShortcutRoutingTests {
    @Test("filterSidebar is only handled when the repos sidebar owns focus")
    func filterSidebarRequiresFocusedReposSidebar() {
        #expect(
            !AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(
                .filterSidebar,
                keyboardOwner: .mainWindowChain
            )
        )

        #expect(
            !AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(
                .filterSidebar,
                keyboardOwner: .sidebar(.inbox)
            )
        )

        #expect(
            AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(
                .filterSidebar,
                keyboardOwner: .sidebar(.repos)
            )
        )

        #expect(
            !AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(
                .filterSidebar,
                keyboardOwner: .managementLayer
            )
        )
    }

    @Test("surface switch shortcuts remain globally routable")
    func surfaceSwitchShortcutsRemainGlobal() {
        #expect(
            AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(
                .showInboxNotifications,
                keyboardOwner: .sidebar(.inbox)
            )
        )
        #expect(
            AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(
                .showReposSidebar,
                keyboardOwner: .sidebar(.repos)
            )
        )
    }

    @Test("sidebar focus blocks workspace global shortcuts")
    func sidebarFocusBlocksWorkspaceGlobalShortcuts() {
        for shortcut in [AppShortcut.nextTab, .prevTab, .addDrawerPane, .showPaneInboxNotifications] {
            #expect(
                !AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(
                    shortcut,
                    keyboardOwner: .sidebar(.inbox)
                ),
                "\(shortcut) should not dispatch while inbox owns keyboard focus"
            )
        }
    }

    @Test("production global key path consults keyboard owner policy")
    func productionGlobalKeyPathConsultsKeyboardOwnerPolicy() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            let handler = MockCommandHandler()
            configureMainWindowKeyboardOwner(atoms)
            atoms.workspaceSidebarState.setSidebarCollapsed(false)
            atoms.workspaceSidebarState.setSidebarSurface(.inbox)
            atoms.workspaceSidebarState.setSidebarHasFocus(true)

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.command],
                    characters: "l",
                    charactersIgnoringModifiers: "l",
                    keyCode: 37
                )
            )
            let trigger = try #require(ShortcutDecoder.decode(event: event))
            #expect(ShortcutDecoder.shortcut(for: trigger, in: .global) == .nextTab)

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = handler
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    #expect(!harness.controller.handleAppOwnedKeyEvent(event))
                    #expect(handler.executedCommands.isEmpty)
                }
            )
        }
    }

    @Test("production global key path uses injected window lifecycle")
    func productionGlobalKeyPathUsesInjectedWindowLifecycle() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let injectedWindowLifecycle = WindowLifecycleAtom()
            let harness = makeHarness(windowLifecycleStore: injectedWindowLifecycle)
            let handler = MockCommandHandler()
            let windowId = UUID()
            injectedWindowLifecycle.recordWindowRegistered(windowId)
            injectedWindowLifecycle.recordWindowBecameKey(windowId)
            atoms.workspaceSidebarState.setSidebarCollapsed(false)
            atoms.workspaceSidebarState.setSidebarHasFocus(false)
            atoms.managementLayer.deactivate()

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.command],
                    characters: "l",
                    charactersIgnoringModifiers: "l",
                    keyCode: 37
                )
            )

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = handler
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    #expect(harness.controller.handleAppOwnedKeyEvent(event))
                    #expect(handler.executedCommands.map(\.0) == [.nextTab])
                }
            )
        }
    }

    @Test("scope-aware pane shortcuts are blocked while sidebar owns keyboard")
    func scopeAwarePaneShortcutsAreBlockedBySidebarOwnership() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            configureMainWindowKeyboardOwner(atoms)
            atoms.workspaceSidebarState.setSidebarSurface(.repos)
            atoms.workspaceSidebarState.setSidebarHasFocus(true)

            let first = harness.store.createPane()
            let second = harness.store.createPane()
            let tab = Tab(paneId: first.id)
            harness.store.appendTab(tab)
            harness.store.insertPane(
                second.id,
                inTab: tab.id,
                at: first.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(second.id, inTab: tab.id)
            atoms.workspaceFocusOwner.focusMainPane(second.id)

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.option],
                    characters: "j",
                    charactersIgnoringModifiers: "j",
                    keyCode: 38
                )
            )

            #expect(!harness.controller.handleAppOwnedKeyEvent(event))
            #expect(harness.store.tab(tab.id)?.activePaneId == second.id)
        }
    }

    @Test("scope-aware pane shortcuts consume impossible pane movement")
    func scopeAwarePaneShortcutsConsumeImpossiblePaneMovement() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            configureMainWindowKeyboardOwner(atoms)

            let pane = harness.store.createPane()
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(pane.id, inTab: tab.id)
            atoms.workspaceFocusOwner.focusMainPane(pane.id)

            let impossibleMovements: [(String, UInt16)] = [
                ("i", 34),
                ("j", 38),
                ("k", 40),
                ("l", 37),
            ]

            for (character, keyCode) in impossibleMovements {
                let event = try #require(
                    makeKeyEvent(
                        modifierFlags: [.option],
                        characters: character,
                        charactersIgnoringModifiers: character,
                        keyCode: keyCode
                    )
                )

                #expect(harness.controller.handleAppOwnedKeyEvent(event))
                #expect(harness.store.tab(tab.id)?.activePaneId == pane.id)
            }
        }
    }

    @Test("scope-aware pane shortcuts do not steal text input")
    func scopeAwarePaneShortcutsDoNotStealTextInput() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            configureMainWindowKeyboardOwner(atoms)

            let first = harness.store.createPane()
            let second = harness.store.createPane()
            let tab = Tab(paneId: first.id)
            harness.store.appendTab(tab)
            harness.store.insertPane(
                second.id,
                inTab: tab.id,
                at: first.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(second.id, inTab: tab.id)
            atoms.workspaceFocusOwner.focusMainPane(second.id)

            let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
            let textView = NSTextView()
            window.contentView?.addSubview(textView)
            #expect(window.makeFirstResponder(textView))

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.option],
                    characters: "j",
                    charactersIgnoringModifiers: "j",
                    keyCode: 38,
                    windowNumber: window.windowNumber
                )
            )

            #expect(!harness.controller.handleAppOwnedKeyEvent(event))
            #expect(harness.store.tab(tab.id)?.activePaneId == second.id)
        }
    }

    @Test("old tab cycling shortcut is not decoded after migration")
    func oldTabCyclingShortcutIsNotDecodedAfterMigration() {
        let oldNextTabTrigger = ShortcutTrigger(key: .character(.rightBracket), modifiers: [.command, .shift])
        let oldPrevTabTrigger = ShortcutTrigger(key: .character(.leftBracket), modifiers: [.command, .shift])

        #expect(ShortcutDecoder.shortcut(for: oldNextTabTrigger, in: .global) == nil)
        #expect(ShortcutDecoder.shortcut(for: oldPrevTabTrigger, in: .global) == nil)
    }

    @Test("management layer preserves command-modified pass through")
    func managementLayerPreservesCommandModifiedPassThrough() {
        #expect(
            AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(
                .showPaneInboxNotifications,
                keyboardOwner: .managementLayer
            )
        )
    }

    @Test("tab rename transient surface blocks app shortcut dispatch")
    func tabRenameTransientSurfaceBlocksAppShortcutDispatch() {
        let workspaceWindowId = UUID()
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .transient(.tabRename(tabId: UUID())),
            workspaceWindowId: workspaceWindowId
        )

        for shortcut in AppShortcut.allCases where !AppShortcutDispatchPolicy.isCommandBarActivationShortcut(shortcut) {
            #expect(
                !AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(shortcut, context: context),
                "\(shortcut) should not dispatch while tab rename owns keyboard input"
            )
        }
    }

    @Test("transient surface does not affect another workspace window")
    func transientSurfaceDoesNotAffectAnotherWorkspaceWindow() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .stable(.mainWindowChain),
            workspaceWindowId: UUID()
        )

        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.nextTab, context: context))
    }

    @Test("command bar activation shortcuts are allowed through transient surfaces")
    func commandBarActivationShortcutsAreAllowedThroughTransientSurfaces() {
        let contexts = [
            KeyboardRoutingContext(
                stableOwner: .managementLayer,
                activeSurface: .transient(.arrangementPanel(tabId: UUID())),
                workspaceWindowId: UUID()
            ),
            KeyboardRoutingContext(
                stableOwner: .managementLayer,
                activeSurface: .transient(.arrangementRename(tabId: UUID(), arrangementId: UUID())),
                workspaceWindowId: UUID()
            ),
        ]

        for context in contexts {
            for shortcut in [
                AppShortcut.newTab,
                .showCommandBarEverything,
                .showCommandBarCommands,
                .showCommandBarPanes,
            ] {
                #expect(
                    AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(shortcut, context: context),
                    "\(shortcut) should remain reserved for command bar activation"
                )
            }
        }
    }

    @Test("non command bar shortcuts are blocked while command bar owns keyboard")
    func nonCommandBarShortcutsAreBlockedWhileCommandBarOwnsKeyboard() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .commandBar(scope: .everything),
            workspaceWindowId: UUID()
        )

        for shortcut in AppShortcut.allCases where !AppShortcutDispatchPolicy.isCommandBarActivationShortcut(shortcut) {
            #expect(
                !AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(shortcut, context: context),
                "\(shortcut) should not dispatch while command bar owns keyboard input"
            )
        }
    }

    @Test("arrangement panel allows tab-local navigation shortcuts")
    func arrangementPanelAllowsTabLocalNavigationShortcuts() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .transient(.arrangementPanel(tabId: UUID())),
            workspaceWindowId: UUID()
        )

        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.previousArrangement, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.nextArrangement, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.prevTab, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.nextTab, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.selectTab1, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.selectTab9, context: context))
    }

    @Test("arrangement panel blocks non owned app shortcuts")
    func arrangementPanelBlocksNonOwnedAppShortcuts() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .transient(.arrangementPanel(tabId: UUID())),
            workspaceWindowId: UUID()
        )

        for shortcut in AppShortcut.allCases
        where !AppShortcutDispatchPolicy.isCommandBarActivationShortcut(shortcut)
            && shortcut != .previousArrangement
            && shortcut != .nextArrangement
            && shortcut != .prevTab
            && shortcut != .nextTab
            && ![
                AppShortcut.selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
                .selectTab6, .selectTab7, .selectTab8, .selectTab9,
            ].contains(shortcut)
        {
            #expect(
                !AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(shortcut, context: context),
                "\(shortcut) should not dispatch while arrangement panel owns keyboard input"
            )
        }
    }

    @Test("arrangement panel allows tab ordinal shortcuts and blocks pane ordinals")
    func arrangementPanelAllowsTabOrdinalShortcutsAndBlocksPaneOrdinals() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .transient(.arrangementPanel(tabId: UUID())),
            workspaceWindowId: UUID()
        )

        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.selectTab2, context: context))
        #expect(!AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.focusPane2, context: context))
    }

    @Test("arrangement rename blocks tab local navigation shortcuts")
    func arrangementRenameBlocksTabLocalNavigationShortcuts() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .transient(.arrangementRename(tabId: UUID(), arrangementId: UUID())),
            workspaceWindowId: UUID()
        )

        for shortcut in [
            AppShortcut.previousArrangement,
            .nextArrangement,
            .prevTab,
            .nextTab,
        ] {
            #expect(
                !AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(shortcut, context: context),
                "\(shortcut) should not dispatch while arrangement rename owns keyboard input"
            )
        }
    }

    @Test("global shortcuts are blocked while transient surfaces own keyboard")
    func globalShortcutsAreBlockedWhileTransientSurfacesOwnKeyboard() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .transient(.editorChooser(paneId: UUID())),
            workspaceWindowId: UUID()
        )

        #expect(!AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.showArrangementPanel, context: context))
    }

    @Test("production global key path consults transient surface policy")
    func productionGlobalKeyPathConsultsTransientSurfacePolicy() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            let handler = MockCommandHandler()
            configureMainWindowKeyboardOwner(atoms)
            let workspaceWindowId = try #require(atoms.windowLifecycle.focusedWindowId)
            _ = atoms.transientKeyboardSurface.present(
                .tabRename(tabId: UUID()),
                workspaceWindowId: workspaceWindowId
            )

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.command],
                    characters: "l",
                    charactersIgnoringModifiers: "l",
                    keyCode: 37
                )
            )
            let trigger = try #require(ShortcutDecoder.decode(event: event))
            #expect(ShortcutDecoder.shortcut(for: trigger, in: .global) == .nextTab)

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = handler
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    #expect(!harness.controller.handleAppOwnedKeyEvent(event))
                    #expect(handler.executedCommands.isEmpty)
                }
            )
        }
    }

    @Test("production global key path dispatches arrangement navigation through arrangement panel")
    func productionGlobalKeyPathDispatchesArrangementNavigationThroughArrangementPanel() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            let handler = MockCommandHandler()
            configureMainWindowKeyboardOwner(atoms)
            let workspaceWindowId = try #require(atoms.windowLifecycle.focusedWindowId)
            _ = atoms.transientKeyboardSurface.present(
                .arrangementPanel(tabId: UUID()),
                workspaceWindowId: workspaceWindowId
            )

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.command, .option],
                    characters: "l",
                    charactersIgnoringModifiers: "l",
                    keyCode: 37
                )
            )

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = handler
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    #expect(harness.controller.handleAppOwnedKeyEvent(event))
                    #expect(handler.executedCommands.map(\.0) == [.nextArrangement])
                }
            )
        }
    }

    @Test("arrangement panel maps command digit shortcuts to tab selection")
    func arrangementPanelMapsCommandDigitShortcutsToTabSelection() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            let handler = MockCommandHandler()
            configureMainWindowKeyboardOwner(atoms)
            let workspaceWindowId = try #require(atoms.windowLifecycle.focusedWindowId)
            _ = atoms.transientKeyboardSurface.present(
                .arrangementPanel(tabId: UUID()),
                workspaceWindowId: workspaceWindowId
            )

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.command],
                    characters: "2",
                    charactersIgnoringModifiers: "2",
                    keyCode: 19
                )
            )

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = handler
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    #expect(harness.controller.handleAppOwnedKeyEvent(event))
                    #expect(handler.executedCommands.map(\.0) == [.selectTab2])
                }
            )
        }
    }

    @Test("arrangement panel consumes unavailable tab ordinal shortcuts")
    func arrangementPanelConsumesUnavailableTabOrdinalShortcuts() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            let handler = MockCommandHandler()
            handler.canExecuteResult = false
            configureMainWindowKeyboardOwner(atoms)
            let workspaceWindowId = try #require(atoms.windowLifecycle.focusedWindowId)
            _ = atoms.transientKeyboardSurface.present(
                .arrangementPanel(tabId: UUID()),
                workspaceWindowId: workspaceWindowId
            )

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.command],
                    characters: "9",
                    charactersIgnoringModifiers: "9",
                    keyCode: 25
                )
            )

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = handler
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    #expect(harness.controller.handleAppOwnedKeyEvent(event))
                    #expect(handler.executedCommands.isEmpty)
                }
            )
        }
    }

    @Test("transient surface blocks scope-aware pane shortcuts")
    func transientSurfaceBlocksScopeAwarePaneShortcuts() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            configureMainWindowKeyboardOwner(atoms)
            let workspaceWindowId = try #require(atoms.windowLifecycle.focusedWindowId)
            _ = atoms.transientKeyboardSurface.present(
                .tabRename(tabId: UUID()),
                workspaceWindowId: workspaceWindowId
            )

            let first = harness.store.createPane()
            let second = harness.store.createPane()
            let tab = Tab(paneId: first.id)
            harness.store.appendTab(tab)
            harness.store.insertPane(
                second.id,
                inTab: tab.id,
                at: first.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(second.id, inTab: tab.id)
            atoms.workspaceFocusOwner.focusMainPane(second.id)

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.option],
                    characters: "j",
                    charactersIgnoringModifiers: "j",
                    keyCode: 38
                )
            )

            #expect(!harness.controller.handleAppOwnedKeyEvent(event))
            #expect(harness.store.tab(tab.id)?.activePaneId == second.id)
        }
    }
}
