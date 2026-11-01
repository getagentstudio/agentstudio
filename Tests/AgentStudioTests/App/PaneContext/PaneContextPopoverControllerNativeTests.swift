import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AppKit
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Prepared native answer boundary", .serialized)
struct PaneContextPopoverControllerNativeTests {
    @Test
    func nativeAnswerPressReachesPersonSeamAndShowsTheCommittedReceipt() async throws {
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let initial = try PaneContextMessageFixtures.askDetail(pane: pane, id: id, state: .open, revision: 1)
        let ports = PaneContextPopoverTestPorts(initial)
        let adapter = PaneContextUIAdapter(reader: ports, person: ports)
        let owners = PaneContextTestSourceOwners(
            sessionStatus: .init(), presentation: .init(), pane: { _ in nil },
            serviceProvider: { adapter })
        let host = owners.makeNativeHost(
            paneId: pane,
            entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
            wallNow: Date(timeIntervalSince1970: 2))
        do {
            try await host.open()
            try await host.rendered()
            await ports.setDetail(
                try PaneContextMessageFixtures.askDetail(
                    pane: pane, id: id,
                    state: .answered(by: .localUser, value: .text(""), receipt: .confirmed(at: .distantPast)),
                    revision: 2))
            let controls = PaneContextPopoverControlProjection.controls()
            let identifier = controls.submit.identifier(in: pane.uuid.uuidString + "." + id.uuid.uuidString)
            let button = try #require(host.native.find(identifier) as? any NSAccessibilityProtocol)
            #expect(button.accessibilityLabel() == LocalActionSpec.submitPaneMessageAnswer.actionSpec.label)
            try host.native.press(identifier)
            try await host.actionCompleted()
            try await host.rendered()
            #expect(await ports.answers == [.init(messageId: id, paneId: pane, by: .localUser, value: .text(""))])
            #expect(host.value?.content.feedback == "Answered")
            #expect(
                host.value?.shape?.messages.messageRows.first?.shape
                    == .ask(
                        reason: .question,
                        form: .freeText(placeholder: "Reply"), waiting: .nonBlocking,
                        state: .answered(by: .localUser, value: .text(""), receipt: .confirmed(at: .distantPast))))
            #expect(host.native.find(identifier) == nil)
            try await host.close()
            try await ports.finish()
        } catch {
            try? await host.close()
            try? await ports.finish()
            throw error
        }
    }
}
