import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Sessions bounded summary projection")
struct SessionsSummaryProjectionTests {
    @Test("oversized prompt text ends with an ellipsis within the UTF-8 scalar bound")
    func oversizedPromptIsBounded() throws {
        let original = String(repeating: "😀", count: 400)
        var fixture = SummaryProjectionFixture()
        fixture.addPrompt(sequence: 1, reason: .question, summary: original)
        let projected = try #require(try fixture.runtime.summary(paneId: fixture.paneId))
        let summary = try #require(projected.providerPrompts.first?.summary)
        #expect(summary == String(repeating: "😀", count: 255) + "…")
        #expect(summary.utf8.count <= 1024)
        #expect(projected.omittedPromptCount == 0)
        #expect(projected.status == .needsYou(.question))
        #expect(fixture.state.providerPrompts[.permission(1)]?.summary == original)
    }

    @Test("20 open prompts list the newest 16 and omit four without changing full-state reason")
    func listedPromptCountIsBounded() throws {
        var fixture = SummaryProjectionFixture()
        for sequence in 1...20 {
            fixture.addPrompt(
                sequence: Int64(sequence), reason: sequence == 1 ? .approval : .question, summary: "Prompt \(sequence)")
        }
        let projected = try #require(try fixture.runtime.summary(paneId: fixture.paneId))
        #expect(projected.providerPrompts.count == 16)
        #expect(projected.omittedPromptCount == 4)
        #expect(projected.providerPrompts.compactMap(\.summary) == (5...20).reversed().map { "Prompt \($0)" })
        #expect(projected.status == .needsYou(.approval))
        #expect(fixture.state.providerPrompts.count == 20)
    }

    @Test("exactly bounded and absent text stays unchanged, with no omitted prompts")
    func boundedTextIsUnchanged() throws {
        var fixture = SummaryProjectionFixture()
        let exactText = String(repeating: "é", count: 512)
        fixture.addPrompt(sequence: 1, reason: .question, summary: exactText)
        fixture.addPrompt(sequence: 2, reason: .question, summary: nil)
        let projected = try #require(try fixture.runtime.summary(paneId: fixture.paneId))
        #expect(projected.providerPrompts.map(\.summary) == [nil, exactText])
        #expect(projected.omittedPromptCount == 0)
    }

    @Test("the StopFailure error text is cut on a scalar boundary without mutating the failure")
    func oversizedFailureIsBounded() throws {
        var fixture = SummaryProjectionFixture()
        let category = String(repeating: "😀", count: 600)
        var state = fixture.state
        state.turn = .failed(.init(category: category), at: Date(timeIntervalSince1970: 1))
        fixture.runtime.states[fixture.generation] = state
        let projected = try #require(try fixture.runtime.summary(paneId: fixture.paneId))
        #expect(projected.status == .failed(.init(category: String(repeating: "😀", count: 511) + "…")))
        #expect(fixture.state.turn == .failed(.init(category: category), at: Date(timeIntervalSince1970: 1)))
        #expect(projected.omittedPromptCount == 0)
    }
}

private struct SummaryProjectionFixture {
    let paneId = UUIDv7.generate()
    let generation = UUIDv7.generate()
    var runtime = SessionsStatusRuntime()

    init() {
        runtime.currentBindingByPane[paneId] = generation
        runtime.bindings[generation] = SessionsBindingRecord(
            bindingGenerationId: generation, paneId: paneId, conversationId: UUIDv7.generate(),
            providerIdentifier: "claude-code", providerConversationId: "projection-session",
            sourceGenerationId: UUIDv7.generate(), transitionOccurrenceId: UUIDv7.generate(), origin: .reported,
            status: .active, startedAt: Date(timeIntervalSince1970: 0), endedAt: nil)
        runtime.states[generation] = SessionStatusState(binding: .bound(generation))
    }

    var state: SessionStatusState { runtime.states[generation] ?? SessionStatusState(binding: .bound(generation)) }

    mutating func addPrompt(sequence: Int64, reason: AskReason, summary: String?) {
        var state = self.state
        state.providerPrompts[.permission(sequence)] = ProviderPrompt(
            key: .permission(sequence), reason: reason, observedAt: Date(timeIntervalSince1970: Double(sequence)),
            summary: summary, turnId: "turn", questions: nil, absorbedPermission: false)
        runtime.states[generation] = state
    }
}
