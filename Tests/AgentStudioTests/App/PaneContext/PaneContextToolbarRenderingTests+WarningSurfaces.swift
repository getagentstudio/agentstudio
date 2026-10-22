import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

extension PaneContextToolbarRenderingTests {
    @Test("both rendered sidebar variants omit the warning that the card still displays", arguments: [false, true])
    func renderedWarningStaysInCard(expanded: Bool) throws {
        let pane = PaneId.generateUUIDv7()
        let now = Date(timeIntervalSince1970: 1_800_000_125)
        let message = AgentLineDetail(
            summary: "Quiet message", refs: [], writer: .pane(pane),
            updatedAt: now.addingTimeInterval(-125))
        let variants = RepoExplorerPaneRowVariants.make(
            title: "Pane", note: nil, isDrawer: false, branchStatus: nil, isActive: false,
            agentLine: message, sessionStatus: .working(.active), connectionIssue: .credentialNotRecognized, now: now)
        let lines = expanded ? variants.expanded.lines : variants.compact.lines
        let loader = makeTestOcticonLoader()
        let row = mountCard(AnyView(warningPolicyRow(lines, expanded: expanded, loader: loader)), width: 420)
        defer { row.window.close() }
        let expectedLines: [RepoExplorerPaneRowLine] = [
            .title("Pane"), .sessionStatus(try #require(RepoExplorerPaneContextLine.session(.working(.active)))),
            .agentLine(.agent(message, now: now)),
        ]
        let expected = mountCard(
            AnyView(warningPolicyRow(expectedLines, expanded: expanded, loader: loader)), width: 420)
        defer { expected.window.close() }
        try #require(row.host.bounds == expected.host.bounds, "No warning row may change sidebar height")
        // Compare the content exactly outside the status glyph's independent animation column.
        let textStart =
            AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth + AppStyles.Shell.Sidebar.groupIconTitleSpacing
        let textRect = CGRect(
            x: textStart, y: 0, width: row.host.bounds.width - textStart, height: row.host.bounds.height)
        let actualPixels = try pixels(in: row.host, rect: textRect)
        let expectedPixels = try pixels(in: expected.host, rect: textRect)
        #expect(actualPixels == expectedPixels)
        try expectWarningSurfaceText("Working", color: .secondary, in: row.host)
        try expectWarningSurfaceText("Quiet message", color: .primary, in: row.host)
        let information = RepoExplorerPaneRowVariants.informationLines(
            title: "Pane", note: nil, agentLine: message, sessionStatus: .working(.active),
            connectionIssue: .credentialNotRecognized, now: now)
        let context = PaneManagementContext(
            paneId: pane.uuid, identityRows: [], statusChips: nil,
            targetPath: nil, showsIdentityBlock: true)
        let card = mountCard(
            AnyView(
                ManagementPaneIdentityStrip(
                    context: context, octiconLoader: loader, lines: information
                )
            ), width: 1000)
        defer { card.window.close() }

        let warning = "Messages unavailable · restart this shell to reconnect"
        let rowLabels = accessibilityLabels(in: row.host)
        let cardLabels = accessibilityLabels(in: card.host)
        #expect(!rowLabels.contains { $0.contains(warning) })
        #expect(cardLabels.contains { $0.contains(warning) })
        try expectWarningSurfaceText(warning, color: .secondary, in: card.host)
        #expect(rowLabels.contains { $0.contains("2 min ago") })
    }
    private func warningPolicyRow(
        _ lines: [RepoExplorerPaneRowLine], expanded: Bool, loader: OcticonLoader
    ) -> some View {
        RepoExplorerPaneRowContent(
            primaryText: "Pane", secondaryLine: nil, branchContextText: nil, branchStatus: nil,
            recencyText: "—", recencyTier: .grey, isActive: false, isDrawerPane: false,
            octiconLoader: loader, showsExpandedChips: expanded, preparedLines: lines)
    }

    private func expectWarningSurfaceText(_ text: String, color: Color, in host: NSView) throws {
        let reference = mountCard(
            AnyView(
                Text(text)
                    .font(.system(size: AppStyles.Shell.Sidebar.branchFontSize)).foregroundStyle(color).fixedSize()),
            width: nil)
        defer { reference.window.close() }
        let referenceInk = try ink(in: reference.host, minimumBrightness: 60)
        #expect(referenceInk.mask.contains(true))
        #expect(
            containsTextInk(referenceInk, in: try ink(in: host, minimumBrightness: 60)),
            "The complete literal text must actually paint")
    }

}
