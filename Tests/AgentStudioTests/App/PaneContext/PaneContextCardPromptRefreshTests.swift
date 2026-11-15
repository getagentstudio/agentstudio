import AgentStudioTestSupport
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Card provider prompts stay in status", .serialized)
struct PaneContextCardPromptRefreshTests {
    @Test("D107 real provider prompts retain status without a request block or terminal action")
    func providerPromptsStayInStatus() async throws {
        installTestCoreAtomsIfNeeded()
        let host = try await PromptRefreshHost.make(atoms: CoreAtomScope.store, cardMode: true)
        do {
            try await host.window.open()
            try await host.window.renderedCard()
            let status = try #require(host.window.native.find("paneManagement.card.status") as? NSView)
            #expect(status.accessibilityLabel() == "Needs you · question")
            #expect(host.window.native.find("paneManagement.card.request") == nil)
            #expect(host.window.native.find("pane-context.card-more") == nil)
            #expect(host.window.native.find("pane-context.go-to-pane") == nil)
            #expect(!host.window.native.labels().contains("First prompt"))
            #expect(!host.window.native.labels().contains("Answer in the agent's terminal"))
            #expect(host.window.native.editableFields.isEmpty)
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }
}
