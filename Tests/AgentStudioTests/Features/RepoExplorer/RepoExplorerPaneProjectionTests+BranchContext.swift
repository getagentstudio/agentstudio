import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

extension RepoExplorerPaneProjectionTests {
    @Test(
        "worktree panes paint their prepared branch context",
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
        #expect(row.variants?.compact.lines == [.title(row.primaryText), .worktreeBranch(expectedText)])
        #expect(row.variants?.expanded.lines == [.title(row.primaryText), .worktreeBranch(expectedText)])
        #expect(row.variants?.compact.statusChips == [.clock])
        #expect(row.variants?.expanded.statusChips == [.clock])
        #expect(row.variants?.compact.fallbackLineCount == 3)
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
        let request = branchContextRequest(
            generation: 1,
            snapshot: singleWorktreePaneSnapshot(repoID: repoID, worktree: worktree),
            enrichedBranch: enrichedBranch,
            worktree: worktree
        )

        let result = try RepoExplorerProjectionWorker.project(request)
        let row = try #require(result.projection.paneRowsByGroupId.values.flatMap { $0 }.first)

        #expect(row.branchContextText == expectedText)
    }

    /// At launch enrichment arrives as a worktree-fact delta, which keeps the previous pane rows.
    /// The rows carry the branch line, so the arrival must take the full projection.
    @Test("arriving enrichment for a worktree with pane rows takes the full projection")
    func arrivingEnrichmentRebuildsPaneRows() throws {
        let repoID = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoID)
        let snapshot = singleWorktreePaneSnapshot(repoID: repoID, worktree: worktree)
        let previous = try RepoExplorerProjectionWorker.project(
            branchContextRequest(generation: 1, snapshot: snapshot, enrichedBranch: nil, worktree: worktree))
        let arrived = branchContextRequest(generation: 2, snapshot: snapshot, enrichedBranch: "", worktree: worktree)

        let scoped = RepoExplorerProjectionWorker.applyScopedChange(
            .worktreeFact(worktree.id), request: arrived, previous: previous)
        let full = try RepoExplorerProjectionWorker.project(arrived)

        #expect(scoped == nil)
        let row = try #require(full.projection.paneRowsByGroupId.values.flatMap { $0 }.first)
        #expect(row.branchContextText == "agent-studio · detached")
    }

    @Test("an unchanged branch fact keeps the worktree delta for pane rows")
    func unchangedBranchFactKeepsWorktreeDelta() throws {
        let repoID = UUIDv7.generate()
        let worktree = makeWorktree(repoId: repoID)
        let snapshot = singleWorktreePaneSnapshot(repoID: repoID, worktree: worktree)
        let previous = try RepoExplorerProjectionWorker.project(
            branchContextRequest(
                generation: 1, snapshot: snapshot, enrichedBranch: "feature/sidebar", worktree: worktree))
        let refreshed = branchContextRequest(
            generation: 2, snapshot: snapshot, enrichedBranch: "feature/sidebar", worktree: worktree)

        let scoped = RepoExplorerProjectionWorker.applyScopedChange(
            .worktreeFact(worktree.id), request: refreshed, previous: previous)

        #expect(scoped != nil)
    }

    private func branchContextRequest(
        generation: Int,
        snapshot: RepoExplorerSnapshot,
        enrichedBranch: String?,
        worktree: Worktree
    ) -> RepoExplorerProjectionRequest {
        RepoExplorerProjectionRequest(
            generation: generation,
            snapshot: snapshot,
            collapsedGroupIds: [],
            isFiltering: false,
            trigger: .dataRefresh,
            worktreeEnrichmentSnapshot: enrichedBranch.map { branch in
                [
                    worktree.id: WorktreeEnrichment(
                        worktreeId: worktree.id, repoId: worktree.repoId, branch: branch,
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(generation)))
                ]
            } ?? [:]
        )
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
