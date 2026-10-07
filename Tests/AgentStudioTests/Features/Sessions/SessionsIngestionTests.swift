import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

@Suite("Sessions ingestion")
struct SessionsIngestionTests {
    @Test("hooks share the FIFO and a full pane queue refuses without recording a loss")
    func queueCapacityIsBounded() async throws {
        let fixture = try SessionsDatabaseFixture()
        let held = HeldStep<Void>("first Sessions hook commit")
        let access = HeldHookSQLiteAccess(base: fixture.sqliteAccess, held: held)
        let ingestion = SessionsIngestion(
            repository: .init(sqliteAccess: access),
            limits: .init(maximumPendingPerPane: 1, maximumPendingGlobal: 2), probe: { _ in })
        let pane = UUIDv7.generate()
        let first = Task {
            do {
                return Result<SessionsHookOutcome, any Error>.success(
                    try await ingestion.submitHook(makeHookAdmission(paneId: pane)))
            } catch { return .failure(error) }
        }
        do {
            try await held.firstArrival()
            await #expect(throws: SessionsRepositoryError.paneQueueFull(pane)) {
                try await ingestion.submitHook(
                    makeHookAdmission(paneId: pane, eventName: .toolActivity, signal: .toolActivity(toolName: "Read")))
            }
            held.release()
            let result = await first.value
            let outcome = try result.get()
            let commit = try #require(committedHookCommit(from: outcome))
            #expect(commit.disposition == .bound)
            let count = try await fixture.sqliteAccess.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions_evidence")
            }
            let context = try await ingestion.repository.statusContext(paneId: pane)
            #expect(count == 1)
            #expect(context.evidence.map(\.recordId) == [commit.evidence.recordId])
            await ingestion.finish()
        } catch {
            held.release()
            if case .failure(let childError) = await first.value { Issue.record("Hook task failed: \(childError)") }
            await ingestion.finish()
            throw error
        }
    }

    @Test("a finished owner rejects hooks and app restart does not end an active session")
    func restartKeepsActiveBinding() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        let initial = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let outcome = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, eventName: .toolActivity, signal: .toolActivity(toolName: "Read")))
            _ = try #require(committedHookCommit(from: outcome))
            return try await ingestion.sessionSummary(paneId: pane)
        }
        let restarted = SessionsIngestion(
            repository: try fixture.makeRepository(),
            limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128), probe: { _ in })
        #expect(try await restarted.sessionSummary(paneId: pane) == initial)
        await restarted.finish()
        await #expect(throws: SessionsRepositoryError.ingestionFinished) {
            try await restarted.submitHook(makeHookAdmission(paneId: pane))
        }
    }

    @Test("commandFinished queues after an admitted hook even when hook capacity is full")
    func commandFinishedQueuesBehindHeldHook() async throws {
        let fixture = try SessionsDatabaseFixture()
        let held = HeldStep<Void>("first hook write before commandFinished")
        let access = HeldHookSQLiteAccess(base: fixture.sqliteAccess, held: held)
        let pane = UUIDv7.generate()
        let depthFacts = LocalFactSource<UUID, SessionsQueueDepthFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .pendingGlobal(0) }))
        let depthRecorder = try depthFacts.attach()
        let ingestion = SessionsIngestion(
            repository: .init(sqliteAccess: access),
            limits: .init(maximumPendingPerPane: 1, maximumPendingGlobal: 1),
            probe: { statistics in
                guard statistics.event == .depthChanged, statistics.paneId == pane else { return }
                depthFacts.sink(pane, .pendingGlobal(statistics.pendingGlobal))
            })
        let hookInstant = ContinuousClock.now
        let reportedExit = hookInstant + .milliseconds(1)
        let first = Task {
            do {
                return Result<SessionsHookOutcome, any Error>.success(
                    try await ingestion.submitHook(
                        makeHookAdmission(paneId: pane, sessionId: "A", admissionInstant: hookInstant)))
            } catch { return .failure(error) }
        }
        var commandFinishedTask: Task<SessionsBindingEndCommit?, any Error>?

        do {
            try await held.firstArrival()
            try await depthRecorder.expectNext(in: pane, .pendingGlobal(1))
            commandFinishedTask = Task {
                try await ingestion.submitCommandFinished(paneId: pane, reportedAt: reportedExit)
            }
            try await depthRecorder.expectNext(in: pane, .pendingGlobal(2))
            held.release()

            let firstOutcome = try (await first.value).get()
            let firstCommit = try #require(committedHookCommit(from: firstOutcome))
            let finishedTask = try #require(commandFinishedTask)
            let endOutcome = try await finishedTask.value
            let endCommit = try #require(endOutcome)
            #expect(endCommit.binding.bindingGenerationId == firstCommit.binding.bindingGenerationId)
            #expect(endCommit.binding.status == .ended)
            #expect(firstCommit.revision < endCommit.revision)
            let summary = try await ingestion.sessionSummary(paneId: pane)
            #expect(summary?.status == .idle(.ended))
            try await depthRecorder.expectNext(in: pane, .pendingGlobal(1))
            try await depthRecorder.expectNext(in: pane, .pendingGlobal(0))
        } catch {
            held.release()
            _ = await first.value
            if let commandFinishedTask { _ = try? await commandFinishedTask.value }
            await ingestion.finish()
            try? await depthRecorder.finish()
            throw error
        }
        await ingestion.finish()
        try await depthRecorder.finish()
    }

    @Test("a delayed exit for A cannot end B after A's end and B's later admission")
    func olderCommandExitLeavesNewerMainLive() async throws {
        let fixture = try SessionsDatabaseFixture()
        let ingestion = SessionsIngestion(
            repository: fixture.makeRepository(),
            limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128), probe: { _ in })
        let pane = UUIDv7.generate()
        let firstInstant = ContinuousClock.now
        let reportedExit = firstInstant + .milliseconds(1)
        let endInstant = reportedExit + .milliseconds(1)
        let nextMainInstant = endInstant + .milliseconds(1)
        let delayedExitGate = HeldStep<Void>("earlier source-time commandFinished held before FIFO submission")
        let delayedExit = Task {
            do {
                try await delayedExitGate.arrive(())
                return Result<SessionsBindingEndCommit?, any Error>.success(
                    try await ingestion.submitCommandFinished(paneId: pane, reportedAt: reportedExit))
            } catch { return .failure(error) }
        }

        do {
            let firstOutcome = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, sessionId: "A", admissionInstant: firstInstant))
            let first = try #require(committedHookCommit(from: firstOutcome))
            let endOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, sessionId: "A", eventName: .sessionEnd, signal: .sessionEnd,
                    admissionInstant: endInstant))
            let endedA = try #require(committedHookCommit(from: endOutcome))
            #expect(endedA.binding.bindingGenerationId == first.binding.bindingGenerationId)

            let nextMainOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, sessionId: "B", eventName: .toolActivity,
                    signal: .toolActivity(toolName: "Read"), admissionInstant: nextMainInstant))
            let nextMain = try #require(committedHookCommit(from: nextMainOutcome))
            #expect(nextMain.disposition == .bound)

            let operationCountBeforeExit = try await fixture.sqliteAccess.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions_operation")
            }
            delayedExitGate.release()
            let lateExit = try (await delayedExit.value).get()
            #expect(lateExit == nil)
            let operationCountAfterExit = try await fixture.sqliteAccess.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions_operation")
            }
            #expect(operationCountAfterExit == operationCountBeforeExit)
            let summary = try await ingestion.sessionSummary(paneId: pane)
            #expect(summary?.bindingGeneration == nextMain.binding.bindingGenerationId)
            #expect(summary?.status == .working(.active))
        } catch {
            delayedExitGate.release()
            _ = await delayedExit.value
            await ingestion.finish()
            throw error
        }
        await ingestion.finish()
    }
}

private enum SessionsQueueDepthFact: Equatable, Sendable {
    case pendingGlobal(Int)
}

private actor HeldHookSQLiteAccess: SessionsSQLiteAccess {
    let base: TestSessionsSQLiteAccess
    let held: HeldStep<Void>
    var holdsNextWrite = true
    init(base: TestSessionsSQLiteAccess, held: HeldStep<Void>) {
        self.base = base
        self.held = held
    }
    func read<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        try await base.read(operation)
    }
    func write<Output: Sendable>(_ operation: @Sendable (Database) throws -> Output) async throws -> Output {
        if holdsNextWrite {
            holdsNextWrite = false
            try await held.arrive(())
        }
        return try await base.write(operation)
    }
}
