import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioSessions

extension SessionsIngestionTests {
    @Test("SessionEnd publishes ended status while its callback is held, then admits a new main")
    func sessionEndStatusReadPrecedesCallbackAndNextMain() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let cleanupScope = UUIDv7.generate()
        let submissionScope = UUIDv7.generate()
        let held = HeldStep<Void>("SessionEnd status callback", cancellation: .holdThroughCancellation)
        let facts = LocalFactSource<UUID, BindingCleanupFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { observedScope, fact in
                    (observedScope == cleanupScope && fact == .cleanupCompleted)
                        || (observedScope == submissionScope && fact == .submissionJoined)
                }))
        let recorder = try facts.attach()
        let ingestion = SessionsIngestion(
            repository: fixture.makeRepository(),
            limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128), probe: { _ in },
            sessionEnded: { generation in
                facts.sink(cleanupScope, .cleanupEntered(generation))
                do { try await held.arrive(()) } catch { facts.sink(cleanupScope, .cleanupFailed) }
                facts.sink(cleanupScope, .cleanupCompleted)
            })
        let firstInstant = ContinuousClock.now
        let nextMainInstant = firstInstant + .milliseconds(1)
        let newMainGate = HeldStep<Void>("new main submitted behind SessionEnd callback")
        var endOutcomeTask: Task<SessionsHookOutcome, any Error>?
        var newMainTask: Task<SessionsHookOutcome, any Error>?
        do {
            let firstOutcome = try await ingestion.submitHook(
                makeHookAdmission(paneId: paneId, sessionId: "A", admissionInstant: firstInstant))
            let first = try #require(committedHookCommit(from: firstOutcome))
            endOutcomeTask = Task {
                try await ingestion.submitHook(
                    makeHookAdmission(
                        paneId: paneId, sessionId: "A", eventName: .sessionEnd, signal: .sessionEnd,
                        admissionInstant: firstInstant))
            }
            newMainTask = Task {
                try await newMainGate.arrive(())
                defer { facts.sink(submissionScope, .submissionJoined) }
                return try await ingestion.submitHook(
                    makeHookAdmission(
                        paneId: paneId, sessionId: "B", eventName: .sessionStart, signal: .sessionStart,
                        admissionInstant: nextMainInstant))
            }
            try await recorder.expectNext(in: cleanupScope, .cleanupEntered(first.binding.bindingGenerationId))
            try await held.firstArrival()

            let duringCleanup = try await ingestion.sessionSummary(paneId: paneId)
            #expect(duringCleanup?.status == .idle(.ended))

            try await newMainGate.firstArrival()
            newMainGate.release()
            held.release()
            let endTask = try #require(endOutcomeTask)
            let endOutcome = try await endTask.value
            let ended = try #require(committedHookCommit(from: endOutcome))
            #expect(ended.disposition == .applied)
            #expect(ended.binding.bindingGenerationId == first.binding.bindingGenerationId)
            #expect(ended.binding.status == .ended)
            try await recorder.expectNext(in: cleanupScope, .cleanupCompleted)

            let queuedNewMainTask = try #require(newMainTask)
            let newMainOutcome = try await queuedNewMainTask.value
            let newMain = try #require(committedHookCommit(from: newMainOutcome))
            #expect(newMain.disposition == .bound)
            #expect(newMain.binding.providerConversationId == "B")
            #expect(ended.revision < newMain.revision)
            try await recorder.expectNext(in: submissionScope, .submissionJoined)
            let afterCleanup = try await ingestion.sessionSummary(paneId: paneId)
            #expect(afterCleanup?.status == .unknown)
            #expect(afterCleanup?.bindingGeneration == newMain.binding.bindingGenerationId)
        } catch {
            newMainGate.release()
            held.retire()
            if let endOutcomeTask { _ = try? await endOutcomeTask.value }
            if let newMainTask { _ = try? await newMainTask.value }
            await ingestion.finish()
            try? await recorder.finish()
            throw error
        }
        await ingestion.finish()
        try await recorder.finish()
    }
}

private enum BindingCleanupFact: Equatable, Sendable {
    case cleanupEntered(UUID)
    case cleanupCompleted
    case cleanupFailed
    case submissionJoined
}
