import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Card identity without requests", .serialized)
struct PaneContextCardNativeServiceTests {
    @Test("D107 the real card omits pending asks and forms while retaining status and Show messages")
    func pendingAsksStayOutOfTheCard() async throws {
        let host = try await PaneContextCardServiceHost.make(
            form: .freeText(placeholder: "Reply"), independentPrompt: true, omittedTarget: true)
        do {
            try await host.window.open()
            try await host.window.renderedCard()
            let title = try #require(host.window.native.find("paneManagement.card.title") as? NSView)
            #expect(title.accessibilityLabel() == "Card lifecycle")
            let status = try #require(host.window.native.find("paneManagement.card.status") as? NSView)
            #expect(status.accessibilityLabel()?.isEmpty == false)
            #expect(host.window.native.find("pane-context.card-messages") != nil)
            #expect(host.window.native.find("paneManagement.card.request") == nil)
            #expect(host.window.native.find("pane-context.message-text.\(host.scope)") == nil)
            #expect(host.window.native.find("pane-context.submit.\(host.scope)") == nil)
            #expect(host.window.native.find("pane-context.card-more") == nil)
            #expect(host.window.native.find("pane-context.go-to-pane") == nil)
            #expect(host.window.native.editableFields.isEmpty)
            #expect(!host.window.native.labels().contains("The card's request"))
            #expect(!host.window.native.labels().contains("Full explanation"))
            #expect(await host.person.answers.isEmpty)
            guard
                case .found(let pending) = await host.fixture.composition.paneContextService.readMessage(
                    source: host.fixture.ownerId, message: host.id)
            else {
                Issue.record("The pending ask must remain available to Messages")
                try await host.close()
                return
            }
            #expect(pending.shape == .ask(.question, .freeText(placeholder: "Reply"), .nonBlocking, .open))
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }

}
