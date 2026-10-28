import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

@Suite("Repo Explorer pane row variants")
struct RepoExplorerPaneRowVariantTests {
    @Test("sidebar lines omit card metadata and duplicate drawer, Git and active marks")
    func variantsHaveFixedLinesAndChipOrder() {
        let variants = RepoExplorerPaneRowVariants.make(
            title: "build pane",
            now: .distantPast)

        let expectedLines: [RepoExplorerPaneRowLine] = [
            .title("build pane")
        ]
        #expect(variants.compact.lines == expectedLines)
        #expect(variants.expanded.lines == expectedLines)
        #expect(variants.compact.chips.isEmpty)
        #expect(variants.expanded.chips.isEmpty)
        #expect(variants.compact.fallbackLineCount == 1)
        #expect(variants.expanded.fallbackLineCount == 1)
    }

    @Test("unknown activity leaves no empty chip line")
    func unknownActivityKeepsStableChipLine() {
        let variants = RepoExplorerPaneRowVariants.make(
            title: "quiet pane",
            now: .distantPast)

        #expect(variants.compact.lines == [.title("quiet pane")])
        #expect(variants.compact.chips.isEmpty)
        #expect(variants.expanded.chips.isEmpty)
        #expect(variants.compact.fallbackLineCount == 1)
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

        #expect(row.variants?.compact.lines == [.title("review pane")])
        #expect(row.variants?.expanded.lines == [.title("review pane")])
        #expect(row.variants?.compact.chips.isEmpty == true)
        #expect(row.variants?.expanded.chips.isEmpty == true)
        #expect(row.variants?.compact.fallbackLineCount == 1)
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
                lines: [.title("pane")]
            ),
            expanded: RepoExplorerPaneRowVariant(
                lines: [.title("pane"), .worktreeBranch("repo · main"), .note("Review")]
            )
        )
        let compactHeight = RepoExplorerRowLayout.make(for: .pane(row)).metrics.fallbackHeight
        row.displayVariant = .expanded
        let expandedHeight = RepoExplorerRowLayout.make(for: .pane(row)).metrics.fallbackHeight

        #expect(expandedHeight > compactHeight)
    }
}
