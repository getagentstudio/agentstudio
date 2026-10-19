import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Cursor main conversation takeover")
struct CursorMainTakeoverTests {
    @Test("only Cursor prompt start replaces its live main", arguments: ["cursor", "claude-code", "codex"])
    func repositoryElection(provider: String) async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let first = try #require(
            committedHookCommit(
                from: try await repository.applyHook(
                    admission(pane: pane, provider: provider, session: "A", signal: .turnStart))))
        _ = try await repository.applyHook(admission(pane: pane, provider: provider, session: "A", signal: .turnDone))
        let second = try await repository.applyHook(
            admission(pane: pane, provider: provider, session: "B", signal: .turnStart))
        if provider == "cursor" {
            let takeover = try #require(committedHookCommit(from: second))
            #expect(takeover.supersededBinding?.bindingGenerationId == first.binding.bindingGenerationId)
            #expect(takeover.binding.bindingGenerationId != first.binding.bindingGenerationId)
            _ = try await repository.applyHook(
                admission(pane: pane, provider: provider, session: "A", signal: .sessionEnd))
            let context = try await repository.statusContext(paneId: pane)
            #expect(context.currentBinding?.providerConversationId == "B")
            #expect(context.bindings.first { $0.providerConversationId == "A" }?.status == .ended)
            let summary = try await withSessionsIngestion(repository: repository) { ingestion in
                try await ingestion.sessionSummary(paneId: pane)
            }
            #expect(summary?.status == .working(.active))
        } else {
            #expect(second == .ignored)
            let context = try await repository.statusContext(paneId: pane)
            #expect(context.currentBinding?.bindingGenerationId == first.binding.bindingGenerationId)
        }
    }

    @Test(
        "unverified election takes only Cursor prompts and fences predecessor completion",
        arguments: ["cursor", "claude-code", "codex"])
    func unverifiedElection(provider: String) {
        let pane = UUIDv7.generate()
        var runtime = UnverifiedPaneStatusRuntime()
        func admits(_ hook: SessionsHookAdmission) -> Bool { runtime.apply(hook) }
        #expect(admits(admission(pane: pane, provider: provider, session: "A", signal: .turnStart)))
        #expect(admits(admission(pane: pane, provider: provider, session: "A", signal: .turnDone)))
        #expect(!admits(admission(pane: pane, provider: provider, session: "B", signal: .turnDone)))
        let applied = runtime.apply(admission(pane: pane, provider: provider, session: "B", signal: .turnStart))
        #expect(applied == (provider == "cursor"))
        if provider == "cursor" {
            #expect(runtime.panes[pane]?.main?.sessionId == "B")
            #expect(runtime.status(paneId: pane) == .working(.active))
            #expect(!admits(admission(pane: pane, provider: provider, session: "A", signal: .turnDone)))
            #expect(!admits(admission(pane: pane, provider: provider, session: "A", signal: .sessionEnd)))
            #expect(runtime.status(paneId: pane) == .working(.active))
            #expect(admits(admission(pane: pane, provider: provider, session: "A", signal: .turnStart)))
            #expect(runtime.panes[pane]?.main?.sessionId == "A")
        } else {
            #expect(runtime.panes[pane]?.main?.sessionId == "A")
            #expect(runtime.status(paneId: pane) == .idle(.done))
        }
    }

    @Test("Cursor cannot replace another provider main")
    func crossProviderMainIsProtected() async throws {
        let pane = UUIDv7.generate()
        let main = admission(pane: pane, provider: "claude-code", session: "A", signal: .turnStart)
        let cursor = admission(pane: pane, provider: "cursor", session: "B", signal: .turnStart)
        var runtime = UnverifiedPaneStatusRuntime()
        let mainApplied = runtime.apply(main)
        let cursorApplied = runtime.apply(cursor)
        #expect(mainApplied)
        #expect(!cursorApplied)
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        _ = try await repository.applyHook(main)
        #expect(try await repository.applyHook(cursor) == .ignored)
    }

    private func admission(pane: UUID, provider: String, session: String, signal: SessionProviderSignal)
        -> SessionsHookAdmission
    {
        makeHookAdmission(
            paneId: pane, sessionId: session, eventName: signal.name, signal: signal,
            providerIdentifier: provider)
    }
}
