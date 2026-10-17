import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

extension RepoExplorerPaneProjectionTests {
    @Test(
        "worktree panes retain detached, unknown and normal branch context",
        arguments: [
            ("detached HEAD", "agent-studio · detached"),
            (" detached HEAD\n", "agent-studio · detached"),
            ("Unknown branch", "agent-studio · unknown branch"),
            ("", "agent-studio · unknown branch"),
            (" \n", "agent-studio · unknown branch"),
            ("feature/sidebar", "agent-studio · feature/sidebar"),
        ] as [(String?, String)])
    func associatedPaneAlwaysShowsBranchContext(branchName: String?, expectedText: String) throws {
        let repoID = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoID)
        let paneID = UUIDv7.generate()
        let snapshot = RepoExplorerSnapshot(
            repos: [makeRepo(id: repoID, worktrees: [worktree])],
            repoEnrichmentByRepoId: [repoID: resolvedRemote(repoId: repoID)], surface: .panes, query: "",
            paneLocationsByWorktreeId: [
                worktree.id: [
                    WorkspacePaneLocation(
                        paneId: paneID, tabId: UUIDv7.generate(), tabIndex: 0, paneIndexInTab: 0, isActiveInTab: false)
                ]
            ])

        let projection = RepoExplorerProjection.project(
            snapshot, branchNameByWorktreeId: branchName.map { [worktree.id: $0] } ?? [:])
        let row = try #require(projection.paneRowsByGroupId.values.flatMap { $0 }.first)

        #expect(row.branchContextText == expectedText)
        #expect(row.variants?.compact.lines.contains(.worktreeBranch(expectedText)) == true)
        #expect(row.variants?.expanded.lines.contains(.worktreeBranch(expectedText)) == true)
    }

    @Test("a worktree pane shows no branch line until its branch facts arrive")
    func associatedPaneWaitsForBranchFacts() throws {
        let repoID = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoID)
        let snapshot = RepoExplorerSnapshot(
            repos: [makeRepo(id: repoID, worktrees: [worktree])],
            repoEnrichmentByRepoId: [repoID: resolvedRemote(repoId: repoID)], surface: .panes, query: "",
            paneLocationsByWorktreeId: [
                worktree.id: [
                    WorkspacePaneLocation(
                        paneId: UUIDv7.generate(), tabId: UUIDv7.generate(), tabIndex: 0, paneIndexInTab: 0,
                        isActiveInTab: false)
                ]
            ])

        let projection = RepoExplorerProjection.project(snapshot, branchNameByWorktreeId: [:])
        let row = try #require(projection.paneRowsByGroupId.values.flatMap { $0 }.first)

        #expect(row.branchContextText == nil)
    }
}
