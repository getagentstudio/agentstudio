import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@Suite("Drawer source title presentation")
struct PaneContextSourceTitlePresentationTests {
    @Test("O6 source labels share the existing Core spinner rule", arguments: ["✳ Drawer tests", "⠋ Drawer tests"])
    func sourceTitlesAreSpinnerFreeOnTheCardAndInMessages(rawTitle: String) async throws {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let message = try PaneContextPopoverShapingTests.message(
            paneId: drawer,
            shape: .ask(.question, .freeText(placeholder: "Reply"), .nonBlocking, .open), importance: .attention)
        let detail = PaneContextPopoverShapingTests.detail(
            paneId: owner,
            drawers: [.init(sourcePaneId: drawer, messages: [message])])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shaped = await PaneContextPopoverShaping.shape(detail, sourceTitles: [drawer: rawTitle], now: now)
        #expect(shaped.messages.messageRows.map(\.sourceLabel) == ["Drawer tests"])
        let key = PaneContextMessageKey(paneId: drawer, messageId: message.id)
        let counts = PaneMessageCounts(
            kinds: .init(failure: 0, needsYou: 1, done: 0, info: 0),
            newestOpenBlockingAskId: nil, oldestOpenAsk: key)
        let input = PaneManagementIdentityCapture.LineInput(
            paneId: owner.uuid, terminalTitle: "Owner",
            cwd: nil, shellExecutablePath: nil, agentTitle: nil, note: nil, isDrawer: false,
            agentLine: nil, sessionPresentation: nil,
            contextDisplay: .init(
                revision: .init(1), agentTitle: nil, agentLine: nil, own: .zero,
                includingDrawers: counts, pullRequests: .notApplicable),
            selectedAsk: .init(key: key, detail: message, generation: 1), selectedSourceTitle: rawTitle)
        let card = await CardProjection.project(input, now: now, information: .init(lines: [.title("Owner")]))
        guard case .ask(let row) = card.request else {
            Issue.record("The drawer ask must be visible")
            return
        }
        #expect(row.sourceLabel == "Drawer tests")
    }
}
