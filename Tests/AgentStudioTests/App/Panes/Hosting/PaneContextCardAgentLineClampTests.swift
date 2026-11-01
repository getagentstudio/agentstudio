import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Card Agent Line clamp", .serialized)
struct PaneContextCardAgentLineClampTests {
    @Test(
        "D23/O30 inherits O12: one 220 pt text line, adjacent whole bracketed age", arguments: [390.0, 520.0, 1400.0])
    func longLineKeepsItsCapAndWholeAge(width: CGFloat) throws {
        let summary = String(repeating: "W", count: 200)
        let age = "[123 days ago]"
        let line = RepoExplorerPaneContextLine(
            text: summary, icon: .system(.terminal),
            tooltip: .init(text: summary, shortcutDisplayText: nil), tone: .neutral, glyphMotion: .still, ageText: age)
        let strip = ManagementPaneIdentityStrip(
            context: try PaneIdentityCardFixture.context(hasGitChanges: false),
            octiconLoader: makeTestOcticonLoader(), lines: [.title("Clamped card"), .agentLine(line)])
        let mounted = PaneIdentityCardFixture.mount(strip, width: width)
        let reference = PaneIdentityCardFixture.mountView(
            AnyView(
                HStack(spacing: 0) {
                    Text(summary).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        .background {
                            AccessibilityLabelBridge(identifier: "paneManagement.card.clamped-reference", label: "")
                        }
                        .frame(width: 220)
                    Text("W").font(.system(size: 12)).fixedSize()
                        .background { AccessibilityLabelBridge(identifier: "paneManagement.card.one-line", label: "") }
                    Text(" " + age).font(.system(size: 12)).fixedSize()
                        .background {
                            AccessibilityLabelBridge(identifier: "paneManagement.card.age-reference", label: "")
                        }
                }), width: 2000)
        defer {
            mounted.window.contentView = nil
            mounted.window.close()
            reference.window.contentView = nil
            reference.window.close()
        }
        let textFrame = try #require(PaneIdentityCardFixture.frame(of: "paneContext.agentLine.text", in: mounted.host))
        let ageFrame = try #require(PaneIdentityCardFixture.frame(of: "paneContext.agentLine.age", in: mounted.host))
        let references = PaneIdentityCardFixture.frames(in: reference.host)
        let oneLine = try #require(references["one-line"])
        let wholeAge = try #require(references["age-reference"])
        let clampedText = try #require(references["clamped-reference"])
        try recordPaneLineDiagnosticFrame(mounted.host, name: "card-clamp-\(Int(width))")
        #expect(textFrame.width <= 220)
        #expect(textFrame.width == clampedText.width)
        #expect(textFrame.height == oneLine.height)
        #expect(ageFrame.width == wholeAge.width)
        #expect(ageFrame.minX == textFrame.maxX)
        try PaneIdentityCardFixture.expectContained(in: mounted.host)
    }
}
