import AppKit
import Foundation

/// A snapshot of the cell's current binding, without its materialized row or hosting root.
package struct RepoExplorerCaptureRowIdentity: Equatable, Sendable {
    package let identifier: String
    package let paneId: UUID?

    @MainActor package static func capture(from view: NSView) -> Self? {
        guard let cell = view as? RepoExplorerTableRowCell, let binding = cell.currentBindingIdentity else {
            return nil
        }
        return Self(rowID: binding.rowID)
    }

    init(rowID: RepoExplorerRowID) {
        let components: [String]
        switch rowID {
        case .activitySubgroup(let groupID, let bucket):
            components = ["activitySubgroup", groupID, String(bucket.rawValue)]
            paneId = nil
        case .sectionHeader(let section):
            components = ["sectionHeader", section.rawValue]
            paneId = nil
        case .loadingSectionHeader(let section):
            components = ["loadingSectionHeader", section.rawValue]
            paneId = nil
        case .loadingRepository(let section, let repoID):
            components = ["loadingRepository", section.rawValue, repoID.uuidString]
            paneId = nil
        case .group(let groupID):
            components = ["group", groupID]
            paneId = nil
        case .worktree(let groupID, let repoID, let worktreeID):
            components = ["worktree", groupID, repoID.uuidString, worktreeID.uuidString]
            paneId = nil
        case .associatedPane(let groupID, let repoID, let worktreeID, let paneID):
            components = ["associatedPane", groupID, repoID.uuidString, worktreeID.uuidString, paneID.uuidString]
            paneId = paneID
        case .tabPane(let groupID, let paneID):
            components = ["tabPane", groupID, paneID.uuidString]
            paneId = paneID
        case .unassociatedPane(let paneID):
            components = ["unassociatedPane", paneID.uuidString]
            paneId = paneID
        case .topologyFault:
            components = ["topologyFault"]
            paneId = nil
        }
        // UTF-8 length prefixes preserve arbitrary group IDs without delimiter collisions.
        identifier = components.map { "\($0.utf8.count):\($0)" }.joined()
    }
}
