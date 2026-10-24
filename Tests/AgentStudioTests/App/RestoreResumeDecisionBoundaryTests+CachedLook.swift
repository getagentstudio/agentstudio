import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import Foundation
import Testing

@testable import AgentStudio

extension RestoreResumeDecisionBoundaryTests {
    @Test("a cached pre-restore look remains valid after its display timestamp is serialized")
    func cachedLookSurvivesTimestampSerialization() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            let cached = PaneForegroundLook(
                paneId: pane.paneId, zmxSessionId: pane.look.zmxSessionId, sessionIdentity: pane.look.sessionIdentity,
                bindingGenerationId: pane.look.bindingGenerationId, program: .codex,
                observerLaunchId: pane.look.observerLaunchId, sequence: 2,
                observedAt: Date(timeIntervalSince1970: 11.000625))
            #expect(try await pane.repository.admit(cached) == .admitted)
            let stored = try #require(try await pane.repository.load(paneId: pane.paneId))
            print("R3_CACHED_LOOK display_timestamp_changed=\(stored.observedAt != cached.observedAt)")
            let result = await pane.decision(harness: harness).resolve(
                paneId: pane.paneId, sessionId: cached.zmxSessionId, preRestoreLook: cached,
                readiness: .ready, launchBoot: .init(previousBootId: "A", currentBootId: "B"), inventory: .complete([:])
            )
            let invocation = ResumeInvocation(
                provider: .codex, sessionId: try ProviderSessionId(rawValue: pane.sessionId))
            #expect(result.evidence == .interruptedCandidate(invocation))
        }
    }
}
