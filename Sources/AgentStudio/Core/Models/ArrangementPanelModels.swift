import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import SwiftUI

package struct PaneVisibilityInfo: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let title: String
    package let isMinimized: Bool
    package let supportsZoom: Bool
    package let paneIcon: AppEntityIcon
    package let agentLine: String?
    package let worktreeName: String?
    package let branchName: String?
    package let worktreePath: String?
    package let agentStatus: ArrangementPaneStatus
    package let section: ArrangementTableSection = .unsectioned

    package init(
        id: UUID,
        title: String,
        isMinimized: Bool,
        supportsZoom: Bool = false,
        paneIcon: AppEntityIcon = .pane,
        agentLine: String? = nil,
        worktreeName: String? = nil,
        branchName: String? = nil,
        worktreePath: String? = nil,
        agentStatus: ArrangementPaneStatus? = nil
    ) {
        self.id = id
        self.title = title
        self.isMinimized = isMinimized
        self.supportsZoom = supportsZoom
        self.paneIcon = paneIcon
        self.agentLine = agentLine
        self.worktreeName = worktreeName
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.agentStatus = agentStatus ?? (isMinimized ? .hidden : .unavailable)
    }

    package var statusSystemImageName: String? {
        isMinimized ? "eye.slash.fill" : nil
    }
}

package enum ArrangementPanelRole: Equatable, Sendable {
    case defaultArrangement
    case userLayout
}

package struct ArrangementInfo: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let name: String
    package let role: ArrangementPanelRole
    package let isActive: Bool

    package init(
        id: UUID,
        name: String,
        role: ArrangementPanelRole,
        isActive: Bool
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.isActive = isActive
    }

    package var isDefault: Bool {
        role == .defaultArrangement
    }
}

package struct ArrangementPanelZoomSourceIdentity: Equatable, Sendable {
    package let title: String
    package let detail: String?
    package let fullPath: String?

    package init(title: String, detail: String?, fullPath: String?) {
        self.title = title
        self.detail = detail
        self.fullPath = fullPath
    }
}

package struct ArrangementPanelZoomMode: Equatable, Sendable {
    package let label: String
    package let sourcePaneId: UUID
    package let sourceIdentity: ArrangementPanelZoomSourceIdentity?

    package init(
        label: String,
        sourcePaneId: UUID,
        sourceIdentity: ArrangementPanelZoomSourceIdentity? = nil
    ) {
        self.label = label
        self.sourcePaneId = sourcePaneId
        self.sourceIdentity = sourceIdentity
    }
}

struct ArrangementPanelDisplayState: Equatable {
    let visiblePanes: [PaneVisibilityInfo]
    let zoomMode: ArrangementPanelZoomMode?
    let arrangements: [ArrangementInfo]

    var hasVisiblePanes: Bool {
        !visiblePanes.isEmpty
    }

    var allowsArrangementCreation: Bool {
        true
    }

    var showsSaveArrangementButton: Bool {
        hasVisiblePanes
    }

    var showsPaneVisibilitySection: Bool {
        hasVisiblePanes && zoomMode == nil
    }

    var arrangementTriggerLabel: String? {
        zoomMode?.label ?? arrangements.first(where: \.isActive)?.name
    }
}

package enum ArrangementPanelPopoverPlacement {
    case tabBar
    case minimizedBar

    var sourceAttachmentPoint: UnitPoint {
        .center
    }

    package var attachmentAnchor: PopoverAttachmentAnchor {
        .point(sourceAttachmentPoint)
    }

    package var arrowEdge: Edge {
        .leading
    }
}

/// Pure decision for auto-opening the arrangement popover when a rename
/// starts from outside the popover (e.g. via the command palette). Targets
/// only renames whose arrangement belongs to the currently active tab,
/// and only when the popover is not already presented.
package enum ArrangementPopoverAutoOpen {
    package static func shouldOpen(
        editingArrangementId: UUID?,
        activeTabArrangements: [ArrangementInfo]?,
        isPresented: Bool
    ) -> Bool {
        guard let editingArrangementId,
            let activeTabArrangements,
            activeTabArrangements.contains(where: { $0.id == editingArrangementId }),
            !isPresented
        else { return false }
        return true
    }
}

/// Pure decision for whether a chip in the popover shows the rename pencil.
/// Default arrangements are not renameable, so the affordance is hidden.
enum ArrangementChipAffordance {
    static func showsRenamePencil(role: ArrangementPanelRole) -> Bool {
        role == .userLayout
    }
}
