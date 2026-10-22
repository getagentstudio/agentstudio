import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@Suite("Repo Explorer pane row variants")
struct RepoExplorerPaneRowVariantTests {
    @Test("compact and expanded line sets keep notes and order chips without terminal output")
    func variantsHaveFixedLinesAndChipOrder() {
        let branchStatus = GitBranchStatus(
            isDirty: true,
            syncState: .ahead(2),
            prCount: 2,
            linesAdded: 29,
            linesDeleted: 1,
            untrackedFileCount: 0
        )

        let variants = RepoExplorerPaneRowVariants.make(
            title: "build pane",
            branchContext: "agent-studio · main",
            note: "Review the diff",
            isDrawer: true,
            branchStatus: branchStatus,
            isActive: true, now: .distantPast)

        let expectedLines: [RepoExplorerPaneRowLine] = [
            .title("build pane"),
            .worktreeBranch("agent-studio · main"),
            .note("Review the diff"),
        ]
        #expect(variants.compact.lines == expectedLines)
        #expect(variants.expanded.lines == expectedLines)
        #expect(variants.compact.chips == [.drawer, .gitPR, .clock, .active])
        #expect(variants.expanded.chips == [.drawer, .gitPR, .changes, .sync, .clock, .active])
        #expect(variants.compact.fallbackLineCount == 4)
        #expect(variants.expanded.fallbackLineCount == 4)
    }

    @Test("unknown activity still reserves one clock chip line")
    func unknownActivityKeepsStableChipLine() {
        let variants = RepoExplorerPaneRowVariants.make(
            title: "quiet pane",
            branchContext: nil,
            note: nil,
            isDrawer: false,
            branchStatus: nil,
            isActive: false, now: .distantPast)

        #expect(variants.compact.lines == [.title("quiet pane")])
        #expect(variants.compact.chips == [.clock])
        #expect(variants.expanded.chips == [.clock])
        #expect(variants.compact.fallbackLineCount == 2)
    }

    @Test("projection carries both prepared variants on each pane row")
    func projectedRowCarriesPreparedVariants() throws {
        let paneID = UUIDv7.generate()
        let snapshot = RepoExplorerSnapshot(
            repos: [],
            repoEnrichmentByRepoId: [:],
            surface: .panes,
            groupingMode: .repo,
            query: "",
            unassociatedPaneLocations: [
                WorkspacePaneLocation(
                    paneId: paneID,
                    tabId: UUIDv7.generate(),
                    tabIndex: 0,
                    paneIndexInTab: 0,
                    isActiveInTab: false
                )
            ]
        )
        let paneFacts = RepoExplorerPaneRowFacts(
            terminalTitle: "review pane",
            noteText: "Check the output",
            latestMessageText: "Private terminal line",
            recencyReferenceDate: .distantPast,
            recencyText: "—",
            isActive: false
        )

        let projection = RepoExplorerProjection.project(
            snapshot,
            paneRowFactsByPaneId: [paneID: paneFacts]
        )
        let groupID = try #require(projection.resolvedGroups.first?.id)
        let row = try #require(projection.paneRowsByGroupId[groupID]?.first)

        #expect(row.variants?.compact.lines == [.title("review pane"), .note("Check the output")])
        #expect(row.variants?.expanded.lines == [.title("review pane"), .note("Check the output")])
        #expect(row.variants?.compact.chips == [.clock])
        #expect(row.variants?.expanded.chips == [.clock])
        #expect(row.variants?.compact.fallbackLineCount == 3)
    }

    @Test("materialization uses the prepared selected variant's fallback height")
    func selectedVariantChangesFallbackHeight() {
        let destination = RepoExplorerUnassociatedPaneDestination(
            paneId: UUIDv7.generate(),
            tabId: UUIDv7.generate(),
            tabIndex: 0,
            paneIndexInTab: 0,
            isActiveInTab: false
        )
        var row = RepoExplorerProjectedPaneRow(
            groupId: "panes:panes:activity:6",
            destination: destination,
            rowId: "pane-row"
        )
        row.variants = RepoExplorerPaneRowVariants(
            compact: RepoExplorerPaneRowVariant(
                lines: [.title("pane")],
                chips: [.clock],
                fallbackLineCount: 2
            ),
            expanded: RepoExplorerPaneRowVariant(
                lines: [.title("pane"), .note("Review")],
                chips: [.clock],
                fallbackLineCount: 3
            )
        )
        let compactHeight = RepoExplorerRowLayout.make(for: .pane(row)).metrics.fallbackHeight
        row.displayVariant = .expanded
        let expandedHeight = RepoExplorerRowLayout.make(for: .pane(row)).metrics.fallbackHeight

        #expect(expandedHeight > compactHeight)
    }
}
