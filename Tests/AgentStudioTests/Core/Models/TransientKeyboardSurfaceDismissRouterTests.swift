import Foundation
import Testing

@testable import AgentStudioCore

@Suite("TransientKeyboardSurfaceDismissRouter")
struct TransientKeyboardSurfaceDismissRouterTests {
    @Test("escape dismisses only when policy opts in")
    func escapeDismissesOnlyWhenPolicyOptsIn() {
        let escape = ShortcutTrigger(key: .escape, modifiers: [])

        #expect(
            TransientKeyboardSurfaceDismissRouter.shouldDismiss(
                trigger: escape,
                policy: .dismissable()
            )
        )
        #expect(
            !TransientKeyboardSurfaceDismissRouter.shouldDismiss(
                trigger: escape,
                policy: .blocking
            )
        )
    }

    @Test("activation shortcut dismisses when declared")
    func activationShortcutDismissesWhenDeclared() {
        let activation = ShortcutTrigger(key: .character(.i), modifiers: [.command, .option])
        let policy = TransientKeyboardSurfacePolicy.dismissable(dismissTriggers: [activation])

        #expect(
            TransientKeyboardSurfaceDismissRouter.shouldDismiss(
                trigger: activation,
                policy: policy
            )
        )
    }

    @Test("command I is not the arrangement dismiss trigger")
    func commandIIsNotArrangementDismissTrigger() {
        let commandI = ShortcutTrigger(key: .character(.i), modifiers: [.command])
        let policy = TransientKeyboardSurfacePolicy.dismissable(
            dismissTriggers: [ShortcutTrigger(key: .character(.i), modifiers: [.command, .option])]
        )

        #expect(
            !TransientKeyboardSurfaceDismissRouter.shouldDismiss(
                trigger: commandI,
                policy: policy
            )
        )
    }

    @Test("default policies classify current transient surfaces")
    func defaultPoliciesClassifyCurrentTransientSurfaces() {
        let tabId = UUID()
        let arrangementId = UUID()
        let paneId = UUID()

        #expect(TransientKeyboardSurfaceKind.tabRename(tabId: tabId).defaultPolicy == .blocking)
        #expect(
            TransientKeyboardSurfaceKind.arrangementPanel(tabId: tabId)
                .defaultPolicy
                .dismissTriggers == [AppShortcut.showArrangementPanel.trigger]
        )
        #expect(TransientKeyboardSurfaceKind.arrangementPanel(tabId: tabId).defaultPolicy.consumesEscape)
        #expect(
            TransientKeyboardSurfaceKind.arrangementRename(tabId: tabId, arrangementId: arrangementId)
                .defaultPolicy
                .dismissTriggers == [AppShortcut.showArrangementPanel.trigger]
        )
        #expect(
            !TransientKeyboardSurfaceKind.arrangementRename(tabId: tabId, arrangementId: arrangementId)
                .defaultPolicy
                .consumesEscape
        )
        #expect(
            TransientKeyboardSurfaceKind.paneInbox(parentPaneId: paneId)
                .defaultPolicy
                .dismissTriggers == [AppShortcut.showPaneInboxNotifications.trigger]
        )
        #expect(
            TransientKeyboardSurfaceKind.editorChooser(paneId: paneId)
                .defaultPolicy
                .dismissTriggers == [AppShortcut.openPaneLocationInEditorMenu.trigger]
        )
    }
}
