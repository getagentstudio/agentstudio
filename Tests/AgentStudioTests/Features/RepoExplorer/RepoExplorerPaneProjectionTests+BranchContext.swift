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
        let snapshot = singleWorktreePaneSnapshot(repoID: repoID, worktree: worktree)

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
        let snapshot = singleWorktreePaneSnapshot(repoID: repoID, worktree: worktree)

        let projection = RepoExplorerProjection.project(snapshot, branchNameByWorktreeId: [:])
        let row = try #require(projection.paneRowsByGroupId.values.flatMap { $0 }.first)

        #expect(row.branchContextText == nil)
    }

    /// Drives the worker, which turns enrichment into branch facts, so a launch without enrichment
    /// proves the line stays out instead of flashing "unknown branch".
    @Test(
        "the worker keeps the branch line out until enrichment arrives, then names git's answer",
        arguments: [
            (nil, nil),
            ("", "agent-studio · detached"),
            ("feature/sidebar", "agent-studio · feature/sidebar"),
        ] as [(String?, String?)])
    func workerBranchLineFollowsEnrichment(enrichedBranch: String?, expectedText: String?) throws {
        let repoID = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoID)
        let request = RepoExplorerProjectionRequest(
            generation: 1,
            snapshot: singleWorktreePaneSnapshot(repoID: repoID, worktree: worktree),
            collapsedGroupIds: [],
            isFiltering: false,
            trigger: .dataRefresh,
            worktreeEnrichmentSnapshot: enrichedBranch.map { branch in
                [worktree.id: WorktreeEnrichment(worktreeId: worktree.id, repoId: repoID, branch: branch)]
            } ?? [:]
        )

        let result = try RepoExplorerProjectionWorker.project(request)
        let row = try #require(result.projection.paneRowsByGroupId.values.flatMap { $0 }.first)

        #expect(row.branchContextText == expectedText)
    }

    private func singleWorktreePaneSnapshot(repoID: UUID, worktree: Worktree) -> RepoExplorerSnapshot {
        RepoExplorerSnapshot(
            repos: [makeRepo(id: repoID, worktrees: [worktree])],
            repoEnrichmentByRepoId: [repoID: resolvedRemote(repoId: repoID)], surface: .panes, query: "",
            paneLocationsByWorktreeId: [
                worktree.id: [
                    WorkspacePaneLocation(
                        paneId: UUIDv7.generate(), tabId: UUIDv7.generate(), tabIndex: 0, paneIndexInTab: 0,
                        isActiveInTab: false)
                ]
            ])
    }
}
