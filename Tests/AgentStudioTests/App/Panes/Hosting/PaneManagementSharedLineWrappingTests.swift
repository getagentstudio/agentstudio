import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer

@MainActor
@Suite(.serialized)
struct PaneManagementSharedLineWrappingTests {
    @Test(arguments: [false, true])
    func cardCanUseTwoLinesWhileExistingCallersStaySingleLine(isMessage: Bool) throws {
        let sidebar = PaneIdentityCardFixture.mountView(
            lineView(isMessage: isMessage, maximumLineCount: nil), width: 220)
        let card = PaneIdentityCardFixture.mountView(lineView(isMessage: isMessage, maximumLineCount: 2), width: 220)
        defer {
            sidebar.window.contentView = nil
            sidebar.window.close()
            card.window.contentView = nil
            card.window.close()
        }
        #expect(
            card.host.fittingSize.height > sidebar.host.fittingSize.height,
            "The card must actually wrap the shared renderer while the default remains one line")
        if isMessage {
            let oldAge = try #require(
                PaneIdentityCardFixture.elements(in: sidebar.host).first { $0.label == "2 min ago" })
            let newAge = try #require(PaneIdentityCardFixture.elements(in: card.host).first { $0.label == "2 min ago" })
            #expect(newAge.frame.height == oldAge.frame.height, "Message age must stay on one line")
        }
    }

    @Test(arguments: [false, true])
    func shortCardLinesNeverReserveABlankSecondLine(isMessage: Bool) {
        let sidebar = PaneIdentityCardFixture.mountView(
            lineView(isMessage: isMessage, maximumLineCount: nil, short: true), width: 420)
        let card = PaneIdentityCardFixture.mountView(
            lineView(isMessage: isMessage, maximumLineCount: 2, short: true), width: 420)
        defer {
            sidebar.window.contentView = nil
            sidebar.window.close()
            card.window.contentView = nil
            card.window.close()
        }
        #expect(card.host.fittingSize.height == sidebar.host.fittingSize.height)
    }

    private var shortMessage: RepoExplorerPaneContextLine {
        .init(
            text: "Ready", icon: .system(.terminal),
            tooltip: .init(text: "Message", shortcutDisplayText: nil), tone: .neutral,
            glyphMotion: .still, ageText: "2 min ago")
    }

    private func lineView(isMessage: Bool, maximumLineCount: Int?, short: Bool = false) -> AnyView {
        let loader = makeTestOcticonLoader()
        if isMessage {
            if let maximumLineCount {
                return AnyView(
                    RepoExplorerPaneContextLineView(
                        line: short ? shortMessage : PaneIdentityCardFixture.message, isAgentLine: true,
                        octiconLoader: loader,
                        maximumLineCount: maximumLineCount))
            }
            return AnyView(
                RepoExplorerPaneContextLineView(
                    line: short ? shortMessage : PaneIdentityCardFixture.message, isAgentLine: true,
                    octiconLoader: loader))
        }
        let title = short ? "Agent" : "Presentation experiments — checking the layout"
        if let maximumLineCount {
            return AnyView(
                RepoExplorerPaneTitleLineView(
                    text: title, isDrawerPane: false, octiconLoader: loader, maximumLineCount: maximumLineCount))
        }
        return AnyView(RepoExplorerPaneTitleLineView(text: title, isDrawerPane: false, octiconLoader: loader))
    }
}
