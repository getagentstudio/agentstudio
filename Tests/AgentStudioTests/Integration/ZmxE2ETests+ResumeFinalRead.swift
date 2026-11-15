import AgentStudioCLIStore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

extension E2ESerializedTests.ZmxE2ETests {
    @Test(
        "the held final reread blocks actual invocation on every global veto", arguments: NativeFinalReadChange.allCases
    )
    @MainActor
    func finalRereadVetoesRealInvocation(change: NativeFinalReadChange) async throws {
        try await withResumeEvidenceBackend { environment in
            try await proveNativeFinalRead(environment, change: change)
        }
    }
}

enum NativeFinalReadChange: CaseIterable, Sendable { case clean, replacement, refused, undecodable, heldNotice }

@MainActor
private func proveNativeFinalRead(_ environment: ResumeEvidenceZmxEnvironment, change: NativeFinalReadChange)
    async throws
{
    let data = try await ResumeEvidenceZmxData.make(environment: environment)
    do {
        let proof = try await ResumeEvidenceZmxProof.make(environment: environment, data: data, provider: "codex")
        do {
            try await proof.prepareCold()
            let result = try await heldNativeResumeDecision(proof, heldRead: 1) {
                switch change {
                case .clean: break
                case .replacement: try await proof.replaceStore(missing: false)
                case .refused, .undecodable:
                    let writer = data.writer
                    let pane = proof.binding.paneId
                    let payload = change == .undecodable ? "not JSON" : "{}"
                    _ = try await valueFromDedicatedThread {
                        try writer.appendSessionLifecycle(
                            paneID: pane, messageID: UUIDv7.generate(), payloadJSON: payload,
                            reportedAt: Date(timeIntervalSince1970: 30)
                        ).get()
                    }
                case .heldNotice:
                    try await data.appendNotice(pane: proof.binding.paneId)
                    try await data.append(pane: proof.binding.paneId, session: proof.sessionId, provider: "codex")
                    await data.access.setRejectsWrites(true)
                }
            }
            await data.access.setRejectsWrites(false)
            let expected: ResumeEvidence
            switch change {
            case .clean:
                expected = .interruptedCandidate(
                    .init(provider: .codex, sessionId: try ProviderSessionId(rawValue: proof.sessionId)))
            case .replacement: expected = .unknown(.historyLost)
            case .refused, .undecodable: expected = .unknown(.reportRefused)
            case .heldNotice: expected = .unknown(.reportsNotRead)
            }
            try await proof.prove(result, expected: expected, label: "final-reread-\(change)")
            try await proof.close()
            await data.close()
        } catch {
            try? await proof.close()
            throw error
        }
    } catch {
        await data.close()
        throw error
    }
}
