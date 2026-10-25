import AgentStudioCLIStore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

extension E2ESerializedTests.ZmxE2ETests {
    @Test("Y resumes its exact id after X's history loss and unchanged store adoption")
    @MainActor
    func newObservedBindingResumesAfterOutboxHistoryLoss() async throws {
        try await withResumeEvidenceBackend { environment in
            let data = try await ResumeEvidenceZmxData.make(environment: environment)
            do {
                let old = try await ResumeEvidenceZmxProof.make(environment: environment, data: data, provider: "codex")
                do {
                    try await old.prepareCold()
                    try await old.replaceStore(missing: false)
                    let lost = try await old.resolve()
                    try await old.prove(lost, expected: .unknown(.historyLost), label: "history-lost-X")
                    try await old.close()
                    let next = try await ResumeEvidenceZmxProof.make(
                        environment: environment, data: data, provider: "codex",
                        paneId: old.binding.paneId, restoredSessionId: old.binding.sessionId)
                    do {
                        #expect(next.sessionId != old.sessionId)
                        #expect(next.binding.generationId != old.binding.generationId)
                        #expect(next.binding.sessionId == old.binding.sessionId)
                        try await next.prepareCold()
                        let result = try await next.resolve()
                        let invocation = ResumeInvocation(
                            provider: .codex, sessionId: try ProviderSessionId(rawValue: next.sessionId))
                        try await next.prove(
                            result, expected: .interruptedCandidate(invocation), label: "history-recovered-Y")
                        try await next.close()
                        await data.close()
                    } catch {
                        try? await next.close()
                        throw error
                    }
                } catch {
                    try? await old.close()
                    throw error
                }
            } catch {
                await data.close()
                throw error
            }
        }
    }

    @Test("a lifecycle row surviving purge prevents the actual resume")
    @MainActor
    func purgedStoreStillHonorsUnreadLifecycle() async throws {
        try await withResumeEvidenceBackend { environment in
            let data = try await ResumeEvidenceZmxData.make(environment: environment)
            do {
                let proof = try await ResumeEvidenceZmxProof.make(
                    environment: environment, data: data, provider: "codex")
                do {
                    try await proof.prepareCold()
                    try await data.append(pane: proof.binding.paneId, session: proof.sessionId, provider: "codex")
                    let writer = data.writer
                    let observation = try await valueFromDedicatedThread {
                        let before = try writer.readOutbox(after: 0).get().entries
                        _ = try writer.purgeHandledOutbox(
                            expectedStoreID: writer.identity.storeID, through: 0,
                            now: Date(timeIntervalSince1970: 100_000_000)
                        ).get()
                        return (before: before, after: try writer.readOutbox(after: 0).get().entries)
                    }
                    #expect(observation.before.count == 1)
                    #expect(observation.after == observation.before)
                    let result = try await proof.resolve()
                    try await proof.prove(result, expected: .knownExited, label: "unread-end-survived-purge")
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
    }
}
