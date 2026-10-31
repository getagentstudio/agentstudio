import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("KeyboardRoutingContext active surface", .serialized)
struct KeyboardRoutingContextSurfaceTests {
    @discardableResult
    private func makeKeyWindow(_ windowLifecycle: WindowLifecycleAtom) -> UUID {
        let workspaceWindowId = UUID()
        windowLifecycle.recordWindowRegistered(workspaceWindowId)
        windowLifecycle.recordWindowBecameKey(workspaceWindowId)
        return workspaceWindowId
    }

    @Test("command bar takes precedence over transient and stable owner")
    func commandBarTakesPrecedenceOverTransientAndStableOwner() {
        let windowLifecycle = WindowLifecycleAtom()
        let managementLayer = ManagementLayerAtom()
        let uiState = WorkspaceSidebarState()
        let commandBarSurface = CommandBarSurfaceAtom()
        let transientSurface = TransientKeyboardSurfaceAtom()
        let workspaceWindowId = makeKeyWindow(windowLifecycle)

        managementLayer.activate()
        commandBarSurface.present(scope: .commands, workspaceWindowId: workspaceWindowId)
        _ = transientSurface.present(.tabRename(tabId: UUID()), workspaceWindowId: workspaceWindowId)

        let context = KeyboardRoutingContext.current(
            windowLifecycle: windowLifecycle,
            managementLayer: managementLayer,
            uiState: uiState,
            commandBarSurface: commandBarSurface,
            transientKeyboardSurface: transientSurface
        )

        #expect(context.stableOwner == .managementLayer)
        #expect(context.activeSurface == .commandBar(scope: .commands))
    }

    @Test("command bar in another window does not affect current window")
    func commandBarInAnotherWindowDoesNotAffectCurrentWindow() {
        let windowLifecycle = WindowLifecycleAtom()
        let managementLayer = ManagementLayerAtom()
        let uiState = WorkspaceSidebarState()
        let commandBarSurface = CommandBarSurfaceAtom()
        let transientSurface = TransientKeyboardSurfaceAtom()
        let currentWindowId = makeKeyWindow(windowLifecycle)
        let otherWindowId = UUID()

        commandBarSurface.present(scope: .commands, workspaceWindowId: otherWindowId)

        let context = KeyboardRoutingContext.current(
            windowLifecycle: windowLifecycle,
            managementLayer: managementLayer,
            uiState: uiState,
            commandBarSurface: commandBarSurface,
            transientKeyboardSurface: transientSurface,
            workspaceWindowId: currentWindowId
        )

        #expect(context.stableOwner == .mainWindowChain)
        #expect(context.activeSurface == .stable(.mainWindowChain))
    }

    @Test("transient takes precedence over stable owner")
    func transientTakesPrecedenceOverStableOwner() {
        let windowLifecycle = WindowLifecycleAtom()
        let managementLayer = ManagementLayerAtom()
        let uiState = WorkspaceSidebarState()
        let commandBarSurface = CommandBarSurfaceAtom()
        let transientSurface = TransientKeyboardSurfaceAtom()
        let workspaceWindowId = makeKeyWindow(windowLifecycle)
        let tabId = UUID()

        _ = transientSurface.present(.arrangementPanel(tabId: tabId), workspaceWindowId: workspaceWindowId)

        let context = KeyboardRoutingContext.current(
            windowLifecycle: windowLifecycle,
            managementLayer: managementLayer,
            uiState: uiState,
            commandBarSurface: commandBarSurface,
            transientKeyboardSurface: transientSurface
        )

        #expect(context.stableOwner == .mainWindowChain)
        #expect(context.activeSurface == .transient(.arrangementPanel(tabId: tabId)))
    }

    @Test("transient remains active when its workspace window temporarily loses key focus")
    func transientRemainsActiveWhenWorkspaceWindowTemporarilyLosesKeyFocus() {
        let transientKinds: [(String, TransientKeyboardSurfaceKind)] = [
            ("tab rename", .tabRename(tabId: UUID())),
            ("arrangement panel", .arrangementPanel(tabId: UUID())),
            ("arrangement rename", .arrangementRename(tabId: UUID(), arrangementId: UUID())),
            ("pane inbox", .paneInbox(parentPaneId: UUID())),
            ("editor chooser", .editorChooser(paneId: UUID())),
        ]

        for (label, transientKind) in transientKinds {
            let windowLifecycle = WindowLifecycleAtom()
            let managementLayer = ManagementLayerAtom()
            let uiState = WorkspaceSidebarState()
            let commandBarSurface = CommandBarSurfaceAtom()
            let transientSurface = TransientKeyboardSurfaceAtom()
            let workspaceWindowId = makeKeyWindow(windowLifecycle)
            _ = transientSurface.present(
                transientKind,
                workspaceWindowId: workspaceWindowId
            )
            windowLifecycle.recordWindowResignedFocused(workspaceWindowId)
            windowLifecycle.recordWindowResignedKey(workspaceWindowId)

            let context = KeyboardRoutingContext.current(
                windowLifecycle: windowLifecycle,
                managementLayer: managementLayer,
                uiState: uiState,
                commandBarSurface: commandBarSurface,
                transientKeyboardSurface: transientSurface
            )

            #expect(context.workspaceWindowId == workspaceWindowId, "\(label) should resolve its workspace window")
            #expect(
                context.activeSurface == .transient(transientKind),
                "\(label) should remain the active keyboard surface"
            )
        }
    }

    @Test("stable owner is active when no overlay is active")
    func stableOwnerIsActiveWhenNoOverlayIsActive() {
        let windowLifecycle = WindowLifecycleAtom()
        let managementLayer = ManagementLayerAtom()
        let uiState = WorkspaceSidebarState()
        let commandBarSurface = CommandBarSurfaceAtom()
        let transientSurface = TransientKeyboardSurfaceAtom()
        makeKeyWindow(windowLifecycle)
        uiState.setSidebarCollapsed(false)
        uiState.setSidebarSurface(.inbox)
        uiState.setSidebarHasFocus(true)

        let context = KeyboardRoutingContext.current(
            windowLifecycle: windowLifecycle,
            managementLayer: managementLayer,
            uiState: uiState,
            commandBarSurface: commandBarSurface,
            transientKeyboardSurface: transientSurface
        )

        #expect(context.stableOwner == .sidebar(.repos))
        #expect(context.activeSurface == .stable(.sidebar(.repos)))
    }
}
