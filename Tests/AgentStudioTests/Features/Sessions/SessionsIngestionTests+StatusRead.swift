import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioSessions

extension SessionsIngestionTests {
    @Test("replacement reads B as live while A's cleanup is held, then joins that cleanup")
    func replacementStatusReadIsAtomicBeforeCleanup() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let scope = UUIDv7.generate()
        let held = HeldStep<Void>("replaced binding cleanup", cancellation: .holdThroughCancellation)
        let facts = LocalFactSource<UUID, BindingCleanupFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .submissionJoined }))
        let recorder = try facts.attach()
        let ingestion = SessionsIngestion(
            repository: fixture.makeRepository(),
            limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128), probe: { _ in },
            sessionEnded: { generation in
                facts.sink(scope, .cleanupEntered(generation))
                do { try await held.arrive(()) } catch { facts.sink(scope, .cleanupFailed) }
                facts.sink(scope, .cleanupCompleted(generation))
            })
        do {
            _ = try await ingestion.submitHook(makeHookAdmission(paneId: paneId, sessionId: "A"))
            let firstRead = try await ingestion.readSessionStatus(paneId: paneId)
            guard case .live(let first) = firstRead else {
                Issue.record("First binding must be live")
                held.retire()
                await ingestion.finish()
                try await recorder.finish()
                return
            }
            let replacement = Task {
                defer { facts.sink(scope, .submissionJoined) }
                return try await ingestion.submitHook(makeHookAdmission(paneId: paneId, sessionId: "B"))
            }
            do {
                try await recorder.expectNext(in: scope, .cleanupEntered(first.bindingGeneration))
                try await held.firstArrival()
                let duringCleanup = try await ingestion.readSessionStatus(paneId: paneId)
                guard case .live(let current) = duringCleanup else {
                    Issue.record("B must be live while A's cleanup is held")
                    held.release()
                    _ = try await replacement.value
                    try await recorder.expectNext(in: scope, .cleanupCompleted(first.bindingGeneration))
                    try await recorder.expectNext(in: scope, .submissionJoined)
                    await ingestion.finish()
                    try await recorder.finish()
                    return
                }
                #expect(current.sessionRef.value == "B")
                #expect(current.bindingGeneration != first.bindingGeneration)
                held.release()
                _ = try await replacement.value
                try await recorder.expectNext(in: scope, .cleanupCompleted(first.bindingGeneration))
                try await recorder.expectNext(in: scope, .submissionJoined)
                let afterCleanup = try await ingestion.readSessionStatus(paneId: paneId)
                #expect(afterCleanup == duringCleanup)
            } catch {
                held.retire()
                _ = try? await replacement.value
                throw error
            }
            await ingestion.finish()
            try await recorder.finish()
        } catch {
            held.retire()
            await ingestion.finish()
            try? await recorder.finish()
            throw error
        }
    }
}

private enum BindingCleanupFact: Equatable, Sendable {
    case cleanupEntered(UUID)
    case cleanupCompleted(UUID)
    case cleanupFailed
    case submissionJoined
}
