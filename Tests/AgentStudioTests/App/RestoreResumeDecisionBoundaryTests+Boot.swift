import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import Testing

@testable import AgentStudio

extension RestoreResumeDecisionBoundaryTests {
    @Test(
        "the production decision uses launch boot, including a missing previous boot",
        arguments: [Optional("old-boot"), Optional("current-boot"), nil])
    func launchBootControlsInventory(previousBoot: String?) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            let decision = pane.decision(harness: harness)
            let result = await pane.resolve(
                decision, previousBoot: previousBoot, currentBoot: "current-boot", inventory: .unavailable(.timedOut))
            if previousBoot == "old-boot" {
                #expect(
                    result.evidence
                        == .interruptedCandidate(
                            .init(provider: .codex, sessionId: try ProviderSessionId(rawValue: pane.sessionId))))
            } else {
                #expect(result.evidence == .unknown(.observationMismatch))
            }
        }
    }
}
