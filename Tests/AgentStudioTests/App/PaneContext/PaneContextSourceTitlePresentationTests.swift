import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@Suite("Drawer source title presentation")
struct PaneContextSourceTitlePresentationTests {
    @Test("O6 source labels share the existing Core spinner rule", arguments: ["✳ Drawer tests", "⠋ Drawer tests"])
    func sourceTitlesAreSpinnerFreeInMessages(rawTitle: String) async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: drawer,
            shape: .ask(.question, .freeText(placeholder: "Reply"), .nonBlocking, .open), importance: .attention)
        let detail = PaneContextPopoverShapingTests.detail(
            paneId: owner,
            drawers: [.init(sourcePaneId: drawer, messages: [message])])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shaped = await PaneContextPopoverShaping.shape(
            detail, sourceTitles: [drawer: rawTitle], counts: .zero, now: now)
        #expect(shaped.messages.messageRows.map(\.sourceLabel) == ["Drawer tests"])
    }
}
