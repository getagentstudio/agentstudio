import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

extension RepoExplorerPaneContextLineTests {
    struct WarningSurfaceOracle: Sendable {
        let reason: AgentConnectionRefusalReason
        let copy: String
        let includesMessage: Bool
    }

    static let warningSurfaceOracles: [WarningSurfaceOracle] = connectionCopy.flatMap { reason, copy in
        [false, true].map { WarningSurfaceOracle(reason: reason, copy: copy, includesMessage: $0) }
    }

    @Test(
        "sidebar rows show hook status before message while every warning remains in the card",
        arguments: warningSurfaceOracles)
    func warningsHaveCardOnlyPlacement(_ oracle: WarningSurfaceOracle) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let message =
            oracle.includesMessage
            ? AgentLineDetail(
                summary: "A quiet message", refs: [], writer: .pane(.generateUUIDv7()), updatedAt: now) : nil

        let variants = RepoExplorerPaneRowVariants.make(
            title: "Pane", note: nil, isDrawer: false, branchStatus: nil, isActive: true,
            agentLine: message, sessionStatus: .working(.active), connectionIssue: oracle.reason, now: now)
        let card = RepoExplorerPaneRowVariants.informationLines(
            title: "Pane", note: nil, agentLine: message, sessionStatus: .working(.active),
            connectionIssue: oracle.reason, now: now)

        let sidebarKinds: [RepoExplorerPaneLineKind] =
            oracle.includesMessage
            ? [.title, .sessionStatus, .agentLine] : [.title, .sessionStatus]
        #expect(variants.compact.lines.map(\.kind) == sidebarKinds)
        #expect(variants.expanded.lines.map(\.kind) == sidebarKinds)
        #expect(card.map(\.kind) == sidebarKinds + [.connectionIssue])
        guard case .connectionIssue(let warning)? = card.last else {
            Issue.record("The information card lost the connection warning")
            return
        }
        #expect(warning.text == oracle.copy)
        #expect(warning.tone == .warning)
        let rowValues = variants.compact.lines.compactMap { row -> RepoExplorerPaneContextLine? in
            switch row {
            case .sessionStatus(let value), .agentLine(let value), .connectionIssue(let value): value
            default: nil
            }
        }
        #expect(rowValues.filter { $0.icon == .system(.circleFill) }.count == 1)
        if oracle.includesMessage {
            let value = try #require(rowValues.last)
            #expect(value.text == "A quiet message")
            #expect(value.icon == .system(.textBubble))
            #expect(value.glyphMotion == .still)
        }
    }
}
