import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Open card prompt invalidation", .serialized)
struct PaneContextCardPromptRefreshTests {
    @Test("G18 the continuously open card follows second prompts, omissions, drawers, membership and last close")
    func promptOnlyChangesReachTheOpenCard() async throws {
        installTestCoreAtomsIfNeeded()
        let host = try await PromptRefreshHost.make(atoms: CoreAtomScope.store, cardMode: true)
        do {
            try await host.window.open()
            try await host.window.renderedCard()
            #expect(host.window.native.find("pane-context.card-more") != nil)
            #expect(host.window.native.labels().contains("+1 more"))
            let first = host.status.value(for: host.fixture.ownerId)?.compactPrompt
            let revision = host.fixture.presentationAtom.value(for: host.fixture.ownerId)?.revision
            try await host.submit(.elicitation(id: "b", summary: "Changed second prompt"))
            try await host.applyPublicationAndRender()
            #expect(host.prompts.map(\.summary) == ["First prompt", "Changed second prompt"])
            #expect(host.status.value(for: host.fixture.ownerId)?.compactPrompt == first)
            #expect(host.fixture.presentationAtom.value(for: host.fixture.ownerId)?.revision == revision)
            for index in 2..<17 { try await host.submit(.elicitation(id: "\(index)", summary: "Prompt \(index)")) }
            try await host.applyPublicationAndRender()
            #expect(host.prompts.count == 16)
            #expect(host.window.value?.shape?.messages.groups.first?.omittedPromptCount == 1)
            #expect(host.window.native.labels().contains("+16 more"))
            try await host.submit(.elicitation(id: "drawer", summary: "Drawer prompt"), pane: host.fixture.drawerId)
            try await host.applyPublicationAndRender()
            #expect(host.window.native.labels().contains("+17 more"))
            let member = try await host.addMember()
            try await host.submit(.elicitation(id: "member", summary: "New member prompt"), pane: member)
            try await host.applyPublicationAndRender()
            #expect(host.window.native.labels().contains("+18 more"))
            for id in ["a", "b"] + (2..<17).map(String.init) { try await host.submit(.elicitationResult(id: id)) }
            try await host.applyPublicationAndRender()
            #expect(host.window.native.labels().contains("+1 more"))
            try await host.submit(.elicitationResult(id: "drawer"), pane: host.fixture.drawerId)
            try await host.applyPublicationAndRender()
            #expect(host.window.native.find("pane-context.card-more") == nil)
            #expect(host.window.native.find("pane-context.go-to-pane") != nil)
            try host.window.native.press("pane-context.go-to-pane")
            #expect(host.window.goToPaneTargets == [member.uuid])
            try await host.submit(.elicitationResult(id: "member"), pane: member)
            try await host.applyPublicationAndRender()
            #expect(host.prompts.isEmpty)
            #expect(host.window.native.find("pane-context.go-to-pane") == nil)
            #expect(host.window.native.find("pane-context.card-more") == nil)
            try await host.close()
        } catch {
            try? await host.close()
            throw error
        }
    }
}
