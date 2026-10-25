import AgentStudioCore
import Foundation

extension TerminalActivationScheduler {
    /// Placement-aware admission order (SPEC R2 initial order, R3 promotion),
    /// low value admitted first. Ranks 0-3 are the promoted tiers a complete
    /// current visible queued set assigns; 4-9 are this scheduler's initial,
    /// pre-observation order. Stays private: the public
    /// `TerminalActivationMemberState.queued` case continues to expose only
    /// `TerminalActivationVisibilityPriority`, per the program design's
    /// selected queue-authority tradeoff.
    enum QueueRank: Int, Comparable {
        case promotedActiveMain = 0
        case promotedMainSibling = 1
        case promotedActiveDrawer = 2
        case promotedDrawerSibling = 3
        case initialVisibleMainActive = 4
        case initialVisibleMainSibling = 5
        case initialVisibleDrawerActive = 6
        case initialVisibleDrawerSibling = 7
        case backgroundMain = 8
        case backgroundDrawer = 9

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        init(placement: TerminalHostPlacementIdentity, priority: TerminalActivationVisibilityPriority) {
            let isDrawer: Bool
            switch placement {
            case .drawer:
                isDrawer = true
            case .tab:
                isDrawer = false
            }
            switch (isDrawer, priority) {
            case (false, .activeVisible):
                self = .initialVisibleMainActive
            case (false, .visible):
                self = .initialVisibleMainSibling
            case (false, .hidden):
                self = .backgroundMain
            case (true, .activeVisible):
                self = .initialVisibleDrawerActive
            case (true, .visible):
                self = .initialVisibleDrawerSibling
            case (true, .hidden):
                self = .backgroundDrawer
            }
        }

        static func backgroundRank(for placement: TerminalHostPlacementIdentity) -> Self {
            switch placement {
            case .tab:
                return .backgroundMain
            case .drawer:
                return .backgroundDrawer
            }
        }
    }

    struct QueuedCandidate {
        let paneID: PaneId
        let priority: TerminalActivationVisibilityPriority
        let rank: QueueRank
        let attempt: Int
        let originalOrdinal: Int
    }

}
