import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
final class AppCommandCatalogTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    // MARK: - Sidebar Commands

    @MainActor

    @Test
    func test_dispatcher_filterSidebar_registered() {
        // Act
        let def = AppCommand.filterSidebar.definition

        // Assert
        #expect(def.label == "Filter Sidebar")
        #expect(def.icon == .system(.magnifyingglass))
    }

    @MainActor

    @Test
    func test_dispatcher_filterSidebar_hasCorrectKeyBinding() {
        // Act
        let def = AppCommand.filterSidebar.definition

        // Assert
        #expect(def.globalKeyBinding?.key == "f")
        #expect(def.globalKeyBinding?.modifiers.contains(.command) ?? false)
        #expect(!(def.globalKeyBinding?.modifiers.contains(.shift) ?? false))
    }

    @MainActor

    @Test
    func test_dispatcher_openNewTerminalInTab_registered() {
        // Act
        let def = AppCommand.openNewTerminalInTab.definition

        // Assert
        #expect(def.label == "Open Terminal in New Tab")
        #expect(def.icon == .system(.terminalFill))
        #expect(def.helpText == "Open a worktree in a fresh terminal tab")
    }

    @MainActor

    @Test
    func test_dispatcher_openNewTerminalInTab_targetsWorktrees() {
        // Act
        let def = AppCommand.openNewTerminalInTab.definition

        // Assert
        #expect(def.targeting == .targeted([.worktree, .pane]))
    }

    @MainActor

    @Test
    func test_dispatcher_openNewTerminalInTab_isExposedInCommandBarAndContextMenus() {
        // Act
        let def = AppCommand.openNewTerminalInTab.definition

        // Assert
        #expect(def.surfacePolicy == .exposed([.commandBar, .contextMenu]))
    }

    @MainActor

    @Test
    func test_dispatcher_filterSidebar_doesNotRequireManagementLayer() {
        // Act
        let def = AppCommand.filterSidebar.definition

        // Assert
        #expect(!def.requiresManagementLayer)
    }

    @MainActor

    @Test
    func test_dispatcher_filterSidebar_isContextual() {
        // Act
        let def = AppCommand.filterSidebar.definition

        // Assert
        #expect(def.targeting == .contextual)
        #expect(def.surfacePolicy == .exposed([.commandBar, .mainMenu]))
    }

    // MARK: - Webview Commands

    @MainActor

    @Test
    func test_dispatcher_openWebview_registered() {
        let def = AppCommand.openWebview.definition
        #expect(def.label == "Open New Webview Tab")
        #expect(def.icon == .system(.globe))
    }

    @MainActor

    @Test
    func test_dispatcher_openWebview_noKeyBinding() {
        let def = AppCommand.openWebview.definition
        #expect(def.globalKeyBinding == nil)
    }

    @MainActor

    @Test
    func test_dispatcher_showViewer_registered() {
        let def = AppCommand.showViewer.definition
        let canonicalViewerSymbol = SystemSymbol(
            rawValue: "text.page.badge.magnifyingglass"
        )
        #expect(def.label == "Worktree Viewer")
        #expect(def.icon == canonicalViewerSymbol.map(CommandIcon.system))
        #expect(def.helpText == "Show or hide the Worktree Viewer in Pane Zoom")
        #expect(def.commandBarGroupName == "Worktree Viewer")
    }

    @MainActor

    @Test
    func test_dispatcher_zoomPane_registered() {
        let def = AppCommand.zoomPane.definition
        let canonicalZoomSymbol = SystemSymbol(
            rawValue: "square.arrowtriangle.4.outward"
        )
        #expect(def.label == "Pane Zoom")
        #expect(def.icon == canonicalZoomSymbol.map(CommandIcon.system))
        #expect(
            def.surfacePolicy
                == .exposed([
                    .contextMenu,
                    .commandBar,
                    .toolbar(.pane),
                    .toolbar(.terminalZoom),
                    .inlineControl,
                ])
        )
        #expect(
            def.targeting
                == .contextualAndTargeted(
                    [.pane],
                    preferredInvocation: .contextual
                )
        )
        #expect(def.visibleWhen == [.supportsTerminalZoom])
        #expect(AppCommand.zoomPane.ipcSpec.executionMode == .headless)
        #expect(AppCommand.zoomPane.ipcSpec.allowedTargetKinds == [.window, .pane])
        #expect(AppCommand.zoomPane.ipcSpec.requiredPrivilege == .layoutMutate)
    }

    @MainActor

    @Test
    func test_dispatcher_zoomPaneAndViewer_useAcceptedKeyBindings() {
        #expect(AppCommand.zoomPane.definition.shortcut?.trigger.displayString == "⌘⇧↵")
        #expect(AppCommand.showViewer.definition.globalKeyBinding == KeyBinding(key: "o", modifiers: [.command]))
    }

    @MainActor

    @Test
    func test_dispatcher_showViewer_isAvailableForZoomEntryAndActiveZoom() {
        let definition = AppCommand.showViewer.definition

        #expect(
            definition.surfacePolicy
                == .exposed([
                    .commandBar,
                    .toolbar(.terminalZoom),
                ])
        )
        #expect(
            definition.targeting
                == .contextualAndTargeted(
                    [.pane],
                    preferredInvocation: .contextual
                )
        )
        #expect(definition.visibleWhen == [.supportsTerminalZoom])
    }

    @Test
    func test_catalog_preserves_menu_and_generatedCommandDistinction() {
        #expect(AppCommand.selectTab1.definition.surfacePolicy == .exposed([.mainMenu]))
        #expect(AppCommand.selectTab1.definition.targeting == .contextual)
        #expect(AppCommand.selectTab.definition.surfacePolicy == .notPresented)
        #expect(AppCommand.selectTab.definition.targeting == .targeted([.tab]))
        #expect(AppCommand.focusPane1.definition.surfacePolicy == .notPresented)
        #expect(AppCommand.focusPane.definition.surfacePolicy == .notPresented)
        #expect(AppCommand.focusPane.definition.targeting == .targeted([.pane, .floatingTerminal]))
    }

    @Test
    func test_catalog_preserves_multiStageMovePaneTargeting() {
        let definition = AppCommand.movePaneToTab.definition

        #expect(definition.surfacePolicy == .exposed([.commandBar, .contextMenu, .inlineControl]))
        #expect(definition.targeting == .targeted([.pane, .tab]))
    }

    @Test
    func test_catalog_preserves_collapsedPaneCloseContextMenu() {
        let definition = AppCommand.closePane.definition

        #expect(definition.surfacePolicy == .exposed([.commandBar, .contextMenu, .inlineControl]))
        #expect(
            definition.targeting
                == .contextualAndTargeted(
                    [.pane, .floatingTerminal],
                    preferredInvocation: .targetSelection
                )
        )
    }

    @Test
    func test_catalog_declaresExactArrangementPlacementSurfaces() {
        #expect(
            AppCommand.switchArrangement.definition.surfacePolicy
                == .exposed([.commandBar, .toolbar(.app), .inlineControl])
        )
        #expect(
            AppCommand.saveArrangement.definition.surfacePolicy
                == .exposed([.commandBar, .contextMenu, .inlineControl])
        )
        #expect(
            AppCommand.renameArrangement.definition.surfacePolicy
                == .exposed([.commandBar, .contextMenu, .inlineControl])
        )
        #expect(
            AppCommand.deleteArrangement.definition.surfacePolicy
                == .exposed([.commandBar, .contextMenu])
        )
    }

    @MainActor

    @Test
    func test_dispatcher_signInGitHub_registered() {
        let def = AppCommand.signInGitHub.definition
        #expect(def.label == "Sign in to GitHub")
        #expect(def.icon == .system(.personBadgeKey))
    }

    @MainActor

    @Test
    func test_dispatcher_signInGoogle_registered() {
        let def = AppCommand.signInGoogle.definition
        #expect(def.label == "Sign in to Google")
        #expect(def.icon == .system(.personBadgeKey))
    }

    @MainActor

    @Test
    func test_dispatcher_signIn_noKeyBindings() {
        // Sign-in commands are internal dispatch identities with no global shortcuts.
        #expect(AppCommand.signInGitHub.definition.globalKeyBinding == nil)
        #expect(AppCommand.signInGoogle.definition.globalKeyBinding == nil)
        #expect(AppCommand.signInGitHub.definition.surfacePolicy == .notPresented)
        #expect(AppCommand.signInGoogle.definition.surfacePolicy == .notPresented)
    }
}
