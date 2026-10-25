import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

extension E2ESerializedTests.ZmxE2ETests {
    @Test("two panes sharing one folder and one Sessions/outbox writer resume distinct exact ids")
    @MainActor
    func twoPanesInOneFolderResumeDistinctIds() async throws {
        try await withResumeEvidenceBackend { environment in
            try await proveTwoPaneResume(environment)
        }
    }
}

@MainActor
private func proveTwoPaneResume(_ environment: ResumeEvidenceZmxEnvironment) async throws {
    let data = try await ResumeEvidenceZmxData.make(environment: environment, boot: .reboot)
    do {
        let first = try await ResumeEvidenceZmxProof.make(environment: environment, data: data, provider: "codex")
        do {
            try await first.prepareCold()
            let second = try await ResumeEvidenceZmxProof.make(environment: environment, data: data, provider: "codex")
            do {
                try await second.prepareCold()
                #expect(first.sessionId != second.sessionId)
                let common = data.root.appending(path: "same folder's proof")
                try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
                for proof in [first, second] {
                    let result = try await proof.resolve()
                    let invocation = ResumeInvocation(
                        provider: .codex, sessionId: try ProviderSessionId(rawValue: proof.sessionId))
                    try await proof.prove(
                        result, expected: .interruptedCandidate(invocation), label: "two-panes-one-folder",
                        folder: common)
                }
                try await second.close()
            } catch {
                try? await second.close()
                throw error
            }
            try await first.close()
            await data.close()
        } catch {
            try? await first.close()
            throw error
        }
    } catch {
        await data.close()
        throw error
    }
}
