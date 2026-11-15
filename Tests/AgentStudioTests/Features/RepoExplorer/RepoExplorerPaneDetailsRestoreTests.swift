import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@Suite("Pane row details restoration")
struct RepoExplorerPaneDetailsRestoreTests {
    @Test(
        "Each legacy chip reaches the prepared row",
        arguments: [
            RepoExplorerPaneChipKind.drawer, .gitPR, .changes, .sync, .messages, .clock, .active,
        ])
    func eachChipSurvivesProjection(kind: RepoExplorerPaneChipKind) throws {
        let row = try restoredDetailsRow()
        let variant = try #require(row.variants?.expanded)
        #expect(variant.statusChips.contains(kind), "Missing prepared pane chip: \(kind)")
    }

    @Test(
        "Each legacy line remains in the prepared stack",
        arguments: [
            RepoExplorerPaneLineKind.title, .worktreeBranch, .note, .sessionStatus, .agentLine,
        ])
    func eachLineSurvivesProjection(kind: RepoExplorerPaneLineKind) throws {
        let row = try restoredDetailsRow()
        #expect(row.variants?.compact.lines.contains { $0.kind == kind } == true)
        #expect(row.variants?.expanded.lines.contains { $0.kind == kind } == true)
    }

    @Test("Absent Git, drawer, active and message facts leave only the legacy clock")
    func absentFactsDoNotInventDetails() {
        let row = RepoExplorerPaneRowVariants.make(title: "Quiet", now: .distantPast)
        #expect(row.compact.statusChips == [.clock])
        #expect(row.expanded.statusChips == [.clock])
        #expect(row.compact.lines.map(\.kind) == [.title])
        #expect(row.compact.chipModels.isEmpty)
    }

    @Test("Loading PR facts remain visible while unavailable PR facts stay hidden", arguments: [false, true])
    func pullRequestAvailability(unavailable: Bool) {
        let status = GitBranchStatus(
            isDirty: false, syncState: .synced, prCount: nil, pullRequestIsLoading: true,
            pullRequestDataUnavailable: unavailable, linesAdded: 0, linesDeleted: 0, untrackedFileCount: 0)
        let row = RepoExplorerPaneRowVariants.make(title: "Loading", branchStatus: status, now: .distantPast)
        #expect(row.compact.statusChips == (unavailable ? [.clock] : [.gitPR, .clock]))
        #expect(row.expanded.statusChips == row.compact.statusChips)
    }

    @Test("Compact and expanded rows preserve legacy order plus typed messages")
    func exactVariantOrder() throws {
        let row = try restoredDetailsRow()
        let compact = try #require(row.variants?.compact)
        let expanded = try #require(row.variants?.expanded)
        #expect(compact.statusChips == [.drawer, .gitPR, .messages, .clock, .active])
        #expect(expanded.statusChips == [.drawer, .gitPR, .changes, .sync, .messages, .clock, .active])
        #expect(compact.lines.map(\.kind) == [.title, .worktreeBranch, .note, .sessionStatus, .agentLine])
        #expect(expanded.lines.map(\.kind) == compact.lines.map(\.kind))
        #expect(compact.fallbackLineCount == 6)
        #expect(expanded.fallbackLineCount == 6)
        #expect(expanded.chipModels == [.init(kind: .needsYou, count: 1)])
        #expect(row.branchStatus?.linesAdded == 19, "Git facts already reached the projected row")
    }
}

func restoredDetailsRow() throws -> RepoExplorerProjectedPaneRow {
    let repo = UUIDv7.generate()
    let worktree = Worktree(id: UUIDv7.generate(), repoId: repo, name: "fixture", path: URL(filePath: "/tmp/fixture"))
    let pane = UUIDv7.generate()
    let tab = UUIDv7.generate()
    let counts = PaneMessageCounts(
        kinds: .init(failure: 0, needsYou: 1, done: 0, info: 0), newestOpenBlockingAskId: nil)
    let display = PaneContextDisplay(
        revision: .init(1), agentTitle: nil,
        agentLine: .init(
            summary: "Running tests", refs: [], writer: .pane(.init(existingUUID: pane)),
            updatedAt: Date(timeIntervalSince1970: 1000)),
        own: counts, includingDrawers: counts, pullRequests: .notApplicable)
    let snapshot = RepoExplorerSnapshot(
        repos: [RepoExplorerPaneProjectionTests().makeRepo(id: repo, worktrees: [worktree])],
        repoEnrichmentByRepoId: [repo: RepoExplorerPaneProjectionTests().resolvedRemote(repoId: repo)],
        surface: .panes, groupingMode: .repo, referenceDate: Date(timeIntervalSince1970: 1120), query: "",
        paneLocationsByWorktreeId: [
            worktree.id: [.init(paneId: pane, tabId: tab, tabIndex: 0, paneIndexInTab: 0, isActiveInTab: true)]
        ])
    let facts = RepoExplorerPaneRowFacts(
        terminalTitle: "Restore pane details",
        sessionPresentation: .init(status: .working(.active), evidence: .verifiedLive),
        contextDisplay: display, noteText: "Review the result", latestMessageText: nil,
        recencyReferenceDate: Date(timeIntervalSince1970: 1120), recencyText: "Now", isActive: true,
        isDrawerPane: true)
    let status = GitBranchStatus(
        isDirty: true, syncState: .diverged(ahead: 5, behind: 3), prCount: 2,
        linesAdded: 19, linesDeleted: 7, untrackedFileCount: 1)
    let projection = RepoExplorerProjection.project(
        snapshot, paneRowFactsByPaneId: [pane: facts], branchNameByWorktreeId: [worktree.id: "feature/restore"],
        branchStatusByWorktreeId: [worktree.id: status])
    return try #require(projection.paneRowsByGroupId.values.flatMap { $0 }.first)
}
