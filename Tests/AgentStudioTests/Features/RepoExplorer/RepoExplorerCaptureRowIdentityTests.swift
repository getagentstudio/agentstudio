import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Sidebar capture binding identity", .serialized)
struct RepoExplorerCaptureRowIdentityTests {
    @Test("capture follows A to B to A cell reuse and clears rather than reporting stale identity")
    func sidebarCaptureFollowsCurrentBinding() {
        let cell = RepoExplorerTableRowCell(octiconLoader: makeRepoExplorerTestOcticonLoader())
        #expect(RepoExplorerCaptureRowIdentity.capture(from: cell) == nil)
        for (generation, groupID) in ["A", "B", "A"].enumerated() {
            let presentation = RepoExplorerMaterializedRowPresentation.groupHeader(
                .init(
                    groupID: groupID, icon: .repo, title: "Same visible label", organizationName: nil, colorHex: nil,
                    isExpanded: true, repoIDs: [], semanticRepoPath: nil, paneDestinations: []))
            let row = RepoExplorerMaterializedRow(
                id: .group(groupID: groupID), contentRevision: .init(presentation: presentation),
                layout: .make(for: presentation), representedRepoID: nil, representedWorktreeID: nil)
            _ = cell.bind(row: row, visibleGeneration: UInt64(generation))
            #expect(RepoExplorerCaptureRowIdentity.capture(from: cell)?.identifier == "5:group1:\(groupID)")
            #expect(RepoExplorerCaptureRowIdentity.capture(from: cell)?.paneId == nil)
        }
        cell.clearBindingForReuse()
        #expect(RepoExplorerCaptureRowIdentity.capture(from: cell) == nil)
        #expect(RepoExplorerCaptureRowIdentity.capture(from: NSView()) == nil)
    }

    @Test("row projection preserves group membership and pane identity across every row variant")
    func sidebarCaptureProjectsEveryRowVariant() {
        let repoId = UUIDv7.generate()
        let worktreeId = UUIDv7.generate()
        let paneId = UUIDv7.generate()
        let cases: [(RepoExplorerRowID, String, UUID?)] = [
            (.activitySubgroup(groupID: "a:b", bucket: .active), "16:activitySubgroup3:a:b1:0", nil),
            (.sectionHeader(.panes), "13:sectionHeader5:panes", nil),
            (.loadingSectionHeader(.panes), "20:loadingSectionHeader5:panes", nil),
            (
                .loadingRepository(section: .repositories, repoID: repoId),
                "17:loadingRepository12:repositories36:\(repoId)", nil
            ),
            (.group(groupID: "é:"), "5:group3:é:", nil),
            (
                .worktree(groupID: "g", repoID: repoId, worktreeID: worktreeId),
                "8:worktree1:g36:\(repoId)36:\(worktreeId)", nil
            ),
            (
                .associatedPane(groupID: "g", repoID: repoId, worktreeID: worktreeId, paneID: paneId),
                "14:associatedPane1:g36:\(repoId)36:\(worktreeId)36:\(paneId)", paneId
            ),
            (.tabPane(groupID: "g", paneID: paneId), "7:tabPane1:g36:\(paneId)", paneId),
            (.unassociatedPane(paneID: paneId), "16:unassociatedPane36:\(paneId)", paneId),
            (.topologyFault, "13:topologyFault", nil),
        ]
        for (row, identifier, expectedPane) in cases {
            let snapshot = RepoExplorerCaptureRowIdentity(rowID: row)
            #expect(snapshot.identifier == identifier && snapshot.paneId == expectedPane)
        }
        #expect(
            RepoExplorerCaptureRowIdentity(rowID: .tabPane(groupID: "a", paneID: paneId))
                != RepoExplorerCaptureRowIdentity(rowID: .tabPane(groupID: "b", paneID: paneId)))
    }
}
