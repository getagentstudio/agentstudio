import Foundation

package enum PaneFocusTrigger: Sendable, Equatable {
    case contentClick(PaneContentClickFocusTrigger)
    case tabClick(PaneTabClickFocusTrigger)
    case drawer(PaneDrawerFocusTrigger)
    case keyboard(PaneKeyboardFocusTrigger)
    case mode(PaneModeFocusTrigger)
    case refocusRequest(PaneRefocusRequestTrigger)
    case command(PaneCommandFocusTrigger)
}

extension PaneFocusTrigger {
    package var isUserFocusInteraction: Bool {
        switch self {
        case .refocusRequest:
            false
        case .contentClick, .tabClick, .drawer, .keyboard, .mode, .command:
            true
        }
    }
}

package struct PaneContentClickFocusTrigger: Sendable, Equatable {
    package enum Location: Sendable, Equatable {
        case content
        case chrome
    }

    package enum ClickPhase: Sendable, Equatable {
        case completed
    }

    package let targetPaneId: UUID
    let location: Location
    let clickPhase: ClickPhase

    package init(targetPaneId: UUID, location: Location, clickPhase: ClickPhase) {
        self.targetPaneId = targetPaneId
        self.location = location
        self.clickPhase = clickPhase
    }
}

package struct PaneTabClickFocusTrigger: Sendable, Equatable {
    package let targetTabId: UUID

    package init(targetTabId: UUID) {
        self.targetTabId = targetTabId
    }
}

package enum PaneDrawerFocusTrigger: Sendable, Equatable {
    case contentClick(parentPaneId: UUID, drawerPaneId: UUID)
    case selectPane(parentPaneId: UUID, drawerPaneId: UUID)
    case toggle(parentPaneId: UUID)
}

package enum PaneKeyboardFocusTrigger: Sendable, Equatable {
    case moveToPane(tabId: UUID, paneId: UUID, paneKind: PaneFocusContext.PaneKind)
}

package struct PaneModeFocusTrigger: Sendable, Equatable {
    package enum Transition: Sendable, Equatable {
        case enteredManagementLayer
        case exitedManagementLayer
    }

    package enum Source: Sendable, Equatable {
        case keyboardShortcut
        case command
    }

    let transition: Transition
    let source: Source

    package init(transition: Transition, source: Source) {
        self.transition = transition
        self.source = source
    }
}

package struct PaneRefocusRequestTrigger: Sendable, Equatable {
    package enum Reason: Sendable, Equatable {
        case explicit
        case windowBecameKey
        case managementLayerExited
        case restoreTail
        case parkedRestoreReplay
    }

    let reason: Reason

    package init(reason: Reason) {
        self.reason = reason
    }
}

package enum PaneCommandFocusTrigger: Sendable, Equatable {
    case focusPane(tabId: UUID, paneId: UUID)
    case selectTab(UUID)
    case paneCreated(paneId: UUID, paneKind: PaneFocusContext.PaneKind)
}
