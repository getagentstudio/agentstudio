import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Terminal app-owned shortcut policy", .serialized)
struct TerminalAppOwnedShortcutPolicyTests {
    @Test("terminal app-owned shortcuts are blocked by transient surfaces")
    func terminalAppOwnedShortcutsAreBlockedByTransientSurfaces() {
        for surface in [
            TransientKeyboardSurfaceKind.paneInbox(parentPaneId: UUIDv7.generate())
        ] {
            let context = KeyboardRoutingContext(
                stableOwner: .mainWindowChain, activeSurface: .transient(surface), workspaceWindowId: UUIDv7.generate())
            #expect(!AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.nextTab, context: context))
            #expect(!AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.nextTab, context: context))
            for shortcut in [
                AppShortcut.scrollPageUp, .scrollPageDown, .scrollSmallStepUp,
                .scrollSmallStepDown, .scrollToBottom, .jumpToPreviousPrompt, .jumpToNextPrompt,
            ] {
                #expect(!AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(shortcut, context: context))
            }
        }
    }

    @Test("command bar activation is allowed through terminal transient surfaces")
    func commandBarActivationIsAllowedThroughTerminalTransientSurfaces() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .transient(.editorChooser(paneId: UUID())),
            workspaceWindowId: UUID()
        )

        #expect(AppShortcut.newTab.spec.contexts.contains(.terminalAppOwned))
        #expect(AppShortcut.newTab.command == .showCommandBarQuickOpen)
        #expect(
            AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(
                .showCommandBarEverything, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.newTab, context: context))
    }

    @Test("terminal app-owned shortcuts are blocked when command bar owns keyboard")
    func terminalAppOwnedShortcutsAreBlockedWhenCommandBarOwnsKeyboard() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .commandBar(scope: .everything),
            workspaceWindowId: UUID()
        )

        #expect(!AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.nextTab, context: context))
        for shortcut in [
            AppShortcut.scrollPageUp, .scrollPageDown, .scrollSmallStepUp,
            .scrollSmallStepDown, .scrollToBottom, .jumpToPreviousPrompt, .jumpToNextPrompt,
        ] {
            #expect(!AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(shortcut, context: context))
        }
        #expect(
            AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(
                .showCommandBarEverything, context: context))
    }

    @Test("terminal app-owned shortcuts are allowed in the main window chain")
    func terminalAppOwnedShortcutsAreAllowedInMainWindowChain() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .stable(.mainWindowChain),
            workspaceWindowId: UUID()
        )

        #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.nextTab, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.newTab, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.selectTab1, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.focusPane1, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.toggleSidebar, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.focusSidebar, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.scrollPageDown, context: context))
        #expect(
            AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.scrollSmallStepUp, context: context)
        )
        #expect(
            AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.scrollSmallStepDown, context: context)
        )
    }

    @Test("focus sidebar is blocked while Management owns the keyboard")
    func focusSidebarIsBlockedWhileManagementOwnsKeyboard() {
        let context = KeyboardRoutingContext(
            stableOwner: .managementLayer,
            activeSurface: .stable(.managementLayer),
            workspaceWindowId: UUID()
        )

        #expect(!AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.focusSidebar, context: context))
        #expect(!AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.focusSidebar, context: context))
        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.toggleSidebar, context: context))
        for shortcut in [
            AppShortcut.scrollPageUp, .scrollPageDown, .scrollSmallStepUp,
            .scrollSmallStepDown, .scrollToBottom, .jumpToPreviousPrompt, .jumpToNextPrompt,
        ] {
            #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(shortcut, context: context))
        }
    }

    @Test("sidebar list commands route only while the stable sidebar owns keyboard input")
    func sidebarListCommandsRequireStableSidebarOwnership() {
        let sidebarContext = KeyboardRoutingContext(
            stableOwner: .sidebar(.repos),
            activeSurface: .stable(.sidebar(.repos)),
            workspaceWindowId: UUID()
        )
        let mainWindowContext = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .stable(.mainWindowChain),
            workspaceWindowId: UUID()
        )

        #expect(sidebarContext.isStableSidebar)
        #expect(!mainWindowContext.isStableSidebar)
        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.showPanesSidebar, context: sidebarContext))
        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.showReposSidebar, context: sidebarContext))
        #expect(AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.filterSidebar, context: sidebarContext))
        #expect(!AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.showPanesSidebar, context: mainWindowContext))
        #expect(!AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.showReposSidebar, context: mainWindowContext))
        #expect(!AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(.filterSidebar, context: mainWindowContext))
    }

    @Test("terminal navigation shortcuts are terminal owned only")
    func terminalNavigationShortcutsAreTerminalOwnedOnly() {
        let context = KeyboardRoutingContext(
            stableOwner: .mainWindowChain,
            activeSurface: .stable(.mainWindowChain),
            workspaceWindowId: UUID()
        )

        for shortcut in [
            AppShortcut.scrollPageUp, .scrollPageDown, .scrollSmallStepUp,
            .scrollSmallStepDown, .scrollToBottom, .jumpToPreviousPrompt, .jumpToNextPrompt,
        ] {
            #expect(!AppShortcutDispatchPolicy.shouldDispatchGlobalShortcut(shortcut, context: context))
            #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(shortcut, context: context))
        }
    }

    @Test("terminal app-owned shortcuts are blocked when sidebar owns keyboard")
    func terminalAppOwnedShortcutsAreBlockedWhenSidebarOwnsKeyboard() {
        let context = KeyboardRoutingContext(
            stableOwner: .sidebar(.inbox),
            activeSurface: .stable(.sidebar(.inbox)),
            workspaceWindowId: UUID()
        )

        #expect(!AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.nextTab, context: context))
        for shortcut in [
            AppShortcut.scrollPageUp, .scrollPageDown, .scrollSmallStepUp,
            .scrollSmallStepDown, .scrollToBottom, .jumpToPreviousPrompt, .jumpToNextPrompt,
        ] {
            #expect(!AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(shortcut, context: context))
        }
        #expect(AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(.newTab, context: context))
    }

    @Test("source pane targeting is explicit for terminal runtime commands only")
    func sourcePaneTargetingIsExplicitForTerminalRuntimeCommandsOnly() {
        let sourcePaneId = UUID()

        for command in [
            AppCommand.scrollPageUp, .scrollPageDown, .scrollSmallStepUp,
            .scrollSmallStepDown, .scrollToBottom, .jumpToPreviousPrompt, .jumpToNextPrompt,
        ] {
            #expect(
                AppShortcutDispatchPolicy.sourcePaneTarget(for: command, sourcePaneId: sourcePaneId) == sourcePaneId)
            #expect(AppShortcutDispatchPolicy.sourcePaneTarget(for: command, sourcePaneId: nil) == nil)
        }

        #expect(
            AppShortcutDispatchPolicy.sourcePaneTarget(for: .showCommandBarEverything, sourcePaneId: sourcePaneId)
                == nil)
        #expect(AppShortcutDispatchPolicy.sourcePaneTarget(for: .selectTab1, sourcePaneId: sourcePaneId) == nil)
        #expect(AppShortcutDispatchPolicy.sourcePaneTarget(for: .focusPane1, sourcePaneId: sourcePaneId) == nil)
        #expect(
            AppShortcutDispatchPolicy.sourcePaneTarget(for: .showPaneInboxNotifications, sourcePaneId: sourcePaneId)
                == nil)
        #expect(AppShortcutDispatchPolicy.sourcePaneTarget(for: .zoomPane, sourcePaneId: sourcePaneId) == nil)
    }
}
