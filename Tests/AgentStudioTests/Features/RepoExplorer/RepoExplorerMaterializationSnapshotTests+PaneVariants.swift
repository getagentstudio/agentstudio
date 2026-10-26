import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

extension RepoExplorerMaterializationSnapshotTests {
    @Test("O12 variant contents determine row height and content revision without phantom chip gaps")
    func renderedVariantOwnsHeightAndRevision() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var pane = RepoExplorerProjectedPaneRow(
            groupId: "variant",
            destination: .init(
                paneId: UUIDv7.generate(), tabId: UUIDv7.generate(), tabIndex: 0,
                paneIndexInTab: 0, isActiveInTab: false), rowId: "variant", primaryText: "Pane")
        let titleOnly = RepoExplorerPaneRowVariant(lines: [.title("Pane")])
        pane.variants = .init(compact: titleOnly, expanded: titleOnly)
        let titleRevision = RepoExplorerRowContentRevision(presentation: .pane(pane))
        let titleLayout = RepoExplorerRowLayout.make(for: .pane(pane)).metrics
        #expect(titleLayout.fallbackHeight == titleLayout.primaryLineHeight + 2 * titleLayout.verticalInset)

        pane.variants = .make(
            title: "Pane",
            agentLine: .init(summary: "Stored work", refs: [], writer: .pane(.generateUUIDv7()), updatedAt: now),
            sessionPresentation: .init(status: .working(.active), evidence: .verifiedLive),
            counts: .init(failure: 1, needsYou: 1, done: 1, info: 1), now: now)
        let fullRevision = RepoExplorerRowContentRevision(presentation: .pane(pane))
        let full = RepoExplorerRowLayout.make(for: .pane(pane)).metrics
        #expect(fullRevision != titleRevision)
        #expect(
            full.fallbackHeight == full.primaryLineHeight + 2 * full.metadataLineHeight
                + full.chipLineHeight + 3 * full.contentSpacing + 2 * full.verticalInset)

        var changed = pane
        let fullVariant = try #require(pane.variants?.compact)
        for variant in [
            RepoExplorerPaneRowVariant(
                lines: [.title("Renamed")] + fullVariant.lines.dropFirst(), chips: fullVariant.chips),
            .init(lines: fullVariant.lines, chips: [.init(kind: .info, count: 2)]),
        ] {
            changed.variants = .init(compact: variant, expanded: variant)
            #expect(RepoExplorerRowContentRevision(presentation: .pane(changed)) != fullRevision)
        }
        let activity = RepoExplorerPaneRowVariant(
            lines: titleOnly.lines, chips: fullVariant.chips,
            activityChip: .init(text: "1 min ago", nextChange: now.addingTimeInterval(60)))
        changed.variants = .init(compact: activity, expanded: activity)
        let activityRevision = RepoExplorerRowContentRevision(presentation: .pane(changed))
        let olderActivity = RepoExplorerPaneRowVariant(
            lines: titleOnly.lines, chips: fullVariant.chips,
            activityChip: .init(text: "2 min ago", nextChange: now.addingTimeInterval(120)))
        changed.variants = .init(compact: olderActivity, expanded: olderActivity)
        #expect(RepoExplorerRowContentRevision(presentation: .pane(changed)) != activityRevision)
    }
}
