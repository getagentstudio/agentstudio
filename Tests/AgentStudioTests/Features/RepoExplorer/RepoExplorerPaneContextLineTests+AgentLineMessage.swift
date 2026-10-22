import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioRepoExplorer

extension RepoExplorerPaneContextLineTests {
    @Test("Agent Line has one spec-owned message glyph with neutral, still paint")
    func agentLineMessageUsesFixedMessageIcon() {
        let message = AgentLineDetail(
            summary: "A message", refs: [],
            writer: .pane(.generateUUIDv7()), updatedAt: .distantPast)

        let line = RepoExplorerPaneContextLine.agent(message)

        guard case .system(let glyph) = line.icon else {
            Issue.record("Agent Line must use the catalog's message symbol")
            return
        }
        #expect(glyph.rawValue == "text.bubble")
        #expect(line.text == message.summary)
        #expect(line.tone == .neutral)
        #expect(line.glyphMotion == .still)
    }
}
