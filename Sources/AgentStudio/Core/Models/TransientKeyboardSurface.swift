import AgentStudioInfrastructure
import Foundation

package struct TransientKeyboardSurfaceToken: Equatable, Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUIDv7.generate()) {
        self.id = id
    }
}

package enum TransientKeyboardSurfaceKind: Equatable, Sendable {
    case tabRename(tabId: UUID)
    case arrangementPanel(tabId: UUID)
    case arrangementRename(tabId: UUID, arrangementId: UUID)
    case paneInbox(parentPaneId: UUID)
    case editorChooser(paneId: UUID)
    case paneNote(paneId: UUID)
    case paneContextCardTextForm(paneId: UUID)

    package var defaultPolicy: TransientKeyboardSurfacePolicy {
        switch self {
        case .arrangementPanel:
            return .dismissable(dismissTriggers: [AppShortcut.showArrangementPanel.trigger])
        case .arrangementRename:
            return .dismissable(
                dismissTriggers: [AppShortcut.showArrangementPanel.trigger],
                consumesEscape: false
            )
        case .paneInbox:
            return .dismissable(dismissTriggers: [AppShortcut.showPaneInboxNotifications.trigger])
        case .editorChooser:
            return .dismissable(dismissTriggers: [AppShortcut.openPaneLocationInEditorMenu.trigger])
        case .paneNote:
            return .dismissable(dismissTriggers: [AppShortcut.editPaneNote.trigger])
        case .tabRename:
            // TabRenamePopover owns Return/Escape inside its AppKit text editor.
            // Keep the generic transient bridge out of that local responder loop.
            return .blocking
        case .paneContextCardTextForm:
            return .blocking
        }
    }
}

package struct TransientKeyboardSurfacePolicy: Equatable, Sendable {
    let dismissTriggers: Set<ShortcutTrigger>
    let consumesEscape: Bool

    static let blocking = Self()

    static func dismissable(
        dismissTriggers: Set<ShortcutTrigger> = [],
        consumesEscape: Bool = true
    ) -> Self {
        Self(
            dismissTriggers: dismissTriggers,
            consumesEscape: consumesEscape
        )
    }

    init(
        dismissTriggers: Set<ShortcutTrigger> = [],
        consumesEscape: Bool = false
    ) {
        self.dismissTriggers = dismissTriggers
        self.consumesEscape = consumesEscape
    }

}

package enum TransientKeyboardSurfaceDismissRouter {
    package static func shouldDismiss(
        trigger: ShortcutTrigger,
        policy: TransientKeyboardSurfacePolicy
    ) -> Bool {
        if trigger.key == .escape && trigger.modifiers.isEmpty {
            return policy.consumesEscape
        }

        return policy.dismissTriggers.contains(trigger)
    }
}

struct TransientKeyboardSurface: Equatable, Identifiable, Sendable {
    let token: TransientKeyboardSurfaceToken
    let workspaceWindowId: UUID
    let kind: TransientKeyboardSurfaceKind
    let policy: TransientKeyboardSurfacePolicy

    var id: TransientKeyboardSurfaceToken { token }

    init(
        token: TransientKeyboardSurfaceToken = TransientKeyboardSurfaceToken(),
        workspaceWindowId: UUID,
        kind: TransientKeyboardSurfaceKind,
        policy: TransientKeyboardSurfacePolicy = .blocking
    ) {
        self.token = token
        self.workspaceWindowId = workspaceWindowId
        self.kind = kind
        self.policy = policy
    }
}
