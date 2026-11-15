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
    @Test(
        "D107b a real mixed ask/provider card is compact even when detail reads would fail",
        arguments: [false, true])
    func requestTextNeverEntersCardStatus(failedDetail: Bool) async throws {
        let host = try await PaneContextCardServiceHost.make(
            form: .freeText(placeholder: "Reply"), independentPrompt: true,
            detailFailure: failedDetail ? .databaseUnavailable : nil,
            providerPrompt: .elicitation(id: "compact-card", summary: "Provider request belongs only in Messages"))
        do {
            let prompt = try #require(host.status.value(for: host.fixture.drawerId)?.compactPrompt)
            let summary = try #require(prompt.summary)
            try #require(!summary.isEmpty)
            try #require(
                host.fixture.presentationAtom.value(for: host.fixture.ownerId)?.includingDrawers.oldestOpenAsk
                    == .init(paneId: host.fixture.ownerId, messageId: host.id))
            try await host.window.open()
            try await host.window.renderedCard()
            #expect(host.window.cardValue?.card?.statusChip?.text == "Needs you · question")
            let status = try #require(host.window.native.find("paneManagement.card.status") as? NSView)
            #expect(status.accessibilityLabel() == "Needs you · question")
            #expect(host.window.native.labels().allSatisfy { !$0.contains(summary) })
            #expect(await host.reader.detailRequests.isEmpty, "Card status must not request Messages detail")
            #expect(host.window.native.find("pane-context.card-messages") != nil)
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }

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
