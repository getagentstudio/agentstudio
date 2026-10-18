import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudioSessions

@Suite("Sessions unverified status")
struct SessionsUnverifiedStatusTests {
    @Test("only the elected main's applied end retires its warning, keeping refusal diagnostics")
    func electedMainEndRetiresWarning() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        let key = PaneId(existingUUID: pane)
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let mailbox = await ingestion.statusPublicationMailbox
            _ = try await Self.submit(ingestion, pane: pane, signal: .turnStart)
            _ = mailbox.takeBatch()
            _ = try await Self.submit(ingestion, pane: pane, signal: .turnDone)
            #expect(
                mailbox.takeBatch()[key] == .set(.init(status: .idle(.done), connectionIssue: .credentialNotRecognized))
            )
            #expect(
                try await Self.submit(ingestion, pane: pane, session: "B", signal: .sessionEnd)
                    == .hookAcceptedWithoutStatus)
            #expect(mailbox.takeBatch().isEmpty)

            #expect(try await Self.submit(ingestion, pane: pane, signal: .sessionEnd) == .hookApplied)

            #expect(mailbox.takeBatch()[key] == .set(.init(status: .idle(.ended))))
            #expect(await ingestion.lastRefusal(paneId: pane)?.reason == .credentialNotRecognized)
            #expect(await ingestion.lastRefusal(paneId: pane)?.count == 4)
            _ = try await Self.submit(ingestion, pane: pane, session: "B", signal: .turnStart)
            #expect(
                mailbox.takeBatch()[key]
                    == .set(.init(status: .working(.active), connectionIssue: .credentialNotRecognized)))
            #expect(try await Self.protectedCounts(fixture) == Array(repeating: 0, count: 10))
        }
    }

    @Test("status and refusal publish together, leave protected SQLite tables untouched, and verified binding wins")
    func noIdentityWritesAndVerifiedPrecedence() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        let key = PaneId(existingUUID: pane)
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let statusMailbox = await ingestion.statusPublicationMailbox
            let before = try await Self.protectedCounts(fixture)
            let applied = try await Self.submit(
                ingestion, pane: pane, signal: .permission(toolName: nil, questions: nil))
            #expect(applied == .hookApplied)
            let batch = statusMailbox.takeBatch()
            #expect(batch[key] == .set(.init(status: .needsYou(.approval), connectionIssue: .credentialNotRecognized)))
            #expect(try await ingestion.readSessionStatus(paneId: pane) == .unbound)
            #expect(try await Self.protectedCounts(fixture) == before)
            #expect(await ingestion.lastRefusal(paneId: pane)?.intent == .status)
            _ = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, sessionId: "verified",
                    eventName: .turnStart, signal: .turnStart, turnId: nil))
            #expect(statusMailbox.takeBatch()[key] == .set(.init(status: .working(.active))))
            #expect(await ingestion.lastRefusal(paneId: pane) == nil)
            #expect(try await Self.submit(ingestion, pane: pane, signal: .turnDone) == .hookAcceptedWithoutStatus)
            #expect(await ingestion.lastRefusal(paneId: pane)?.reason == .credentialNotRecognized)
            #expect(statusMailbox.takeBatch().isEmpty)
            #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .working(.active))
        }
    }

    @Test(
        "a bound pane records an unverified hook or refusal without changing verified status",
        arguments: [false, true])
    func boundPaneRecordsRefusalWithoutApplyingStatus(refusalOnly: Bool) async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, sessionId: "verified", eventName: .turnStart, signal: .turnStart, turnId: nil))
            let statusMailbox = await ingestion.statusPublicationMailbox
            #expect(statusMailbox.takeBatch()[.init(existingUUID: pane)] == .set(.init(status: .working(.active))))
            let protectedBefore = try await Self.protectedCounts(fixture)
            let outcome: SessionsUnverifiedStatusOutcome
            if refusalOnly {
                outcome = try await ingestion.recordUnverifiedStatus(
                    paneId: pane, hook: nil,
                    refusal: .init(reason: .credentialNotRecognized, event: nil, at: .distantPast, intent: .status),
                    remainsPresent: { true })
            } else {
                outcome = try await Self.submit(
                    ingestion, pane: pane, signal: .permission(toolName: nil, questions: nil))
            }
            #expect(outcome == (refusalOnly ? .refusalRecorded : .hookAcceptedWithoutStatus))
            let refusal = await ingestion.lastRefusal(paneId: pane)
            #expect(refusal?.reason == .credentialNotRecognized)
            #expect(refusal?.intent == .status)
            #expect(refusal?.count == 1)
            #expect(statusMailbox.takeBatch().isEmpty)
            #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .working(.active))
            #expect(try await Self.protectedCounts(fixture) == protectedBefore)
        }
    }

    @Test("refusal-only reports cover every closed reason and count without identity writes")
    func refusalReasonsAndCount() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let statusMailbox = await ingestion.statusPublicationMailbox
            let before = try await Self.protectedCounts(fixture)
            for (index, reason) in AgentConnectionRefusalReason.allCases.enumerated() {
                let outcome = try await ingestion.recordUnverifiedStatus(
                    paneId: pane, hook: nil,
                    refusal: .init(reason: reason, event: nil, at: .distantPast, intent: .status),
                    remainsPresent: { true })
                #expect(outcome == .refusalRecorded)
                let refusal = await ingestion.lastRefusal(paneId: pane)
                #expect(refusal?.reason == reason)
                #expect(refusal?.count == index + 1)
                #expect(
                    statusMailbox.takeBatch()[.init(existingUUID: pane)]
                        == .set(.init(status: .unknown, connectionIssue: reason)))
            }
            #expect(try await Self.protectedCounts(fixture) == before)
        }
    }

    @Test(
        "queued status rechecks membership after a held FIFO predecessor and cannot resurrect a retired pane",
        arguments: [false, true])
    func retirementDuringQueuedStatus(retire: Bool) async throws {
        let fixture = try SessionsDatabaseFixture()
        let held = HeldStep<Void>("identity predecessor before queued status")
        let access = HeldUnverifiedStatusSQLiteAccess(base: fixture.sqliteAccess, held: held)
        let pane = UUIDv7.generate()
        let other = UUIDv7.generate()
        let membership = Mutex(true)
        let depth = LocalFactSource<UUID, Int>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { "pending=\($0)" },
                isClosing: { _, value in value == 0 }))
        let recorder = try depth.attach()
        let ingestion = SessionsIngestion(
            repository: .init(sqliteAccess: access), limits: .init(maximumPendingPerPane: 4, maximumPendingGlobal: 8),
            probe: { statistics in
                if statistics.paneId == pane { depth.sink(pane, statistics.pendingForPane) }
            })
        let statusMailbox = await ingestion.statusPublicationMailbox
        let predecessor = Task { try await ingestion.submitHook(makeHookAdmission(paneId: other)) }
        var status: Task<SessionsUnverifiedStatusOutcome, any Error>?
        do {
            try await held.firstArrival()
            status = Task {
                try await Self.submit(
                    ingestion, pane: pane, signal: .turnStart,
                    remainsPresent: { membership.withLock { $0 } })
            }
            try await recorder.expectNext(in: pane, 1)
            membership.withLock { $0 = false }
            if retire { ingestion.paneViewedMailbox.retire([pane]) }
            held.release()
            _ = try await predecessor.value
            let pending = try #require(status)
            #expect(try await pending.value == .notAccepted)
            try await recorder.expectNext(in: pane, 0)
            #expect(await ingestion.lastRefusal(paneId: pane) == nil)
            let publication = statusMailbox.takeBatch()[.init(existingUUID: pane)]
            #expect(publication == (retire ? .remove : nil))
            #expect(try await ingestion.repository.statusContext(paneId: pane).bindings.isEmpty)
        } catch {
            held.release()
            _ = try? await predecessor.value
            _ = try? await status?.value
            await ingestion.finish()
            try? await recorder.finish()
            throw error
        }
        await ingestion.finish()
        try await recorder.finish()
        await #expect(throws: SessionsRepositoryError.ingestionFinished) {
            try await Self.submit(ingestion, pane: pane, signal: .turnStart)
        }
    }

    @Test("an old command exit held at ingress cannot release the newer unverified main")
    func heldOlderExitCannotReleaseNewMain() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        let origin = ContinuousClock.now
        let oldExit = HeldStep<ContinuousClock.Instant>("old terminal exit before Sessions ingress")
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let statusMailbox = await ingestion.statusPublicationMailbox
            _ = try await Self.submit(ingestion, pane: pane, signal: .turnStart, instant: origin)
            let pendingExit = Task {
                try await oldExit.arrive(origin + .seconds(1))
                return try await ingestion.submitCommandFinished(paneId: pane, reportedAt: origin + .seconds(1))
            }
            do {
                _ = try await oldExit.firstArrival()
                _ = try await Self.submit(ingestion, pane: pane, signal: .sessionEnd, instant: origin + .seconds(2))
                _ = try await Self.submit(
                    ingestion, pane: pane, session: "B", signal: .turnStart, instant: origin + .seconds(3))
                _ = statusMailbox.takeBatch()
                oldExit.release()
                #expect(try await pendingExit.value == nil)
                #expect(statusMailbox.takeBatch().isEmpty)
                let currentExit = try await ingestion.submitCommandFinished(
                    paneId: pane, reportedAt: origin + .seconds(4))
                #expect(currentExit == nil)
                #expect(statusMailbox.takeBatch()[.init(existingUUID: pane)] == .set(.init(status: .idle(.ended))))
                #expect(await ingestion.lastRefusal(paneId: pane)?.reason == .credentialNotRecognized)
                #expect(
                    try await Self.submit(ingestion, pane: pane, signal: .turnDone, instant: origin + .seconds(4))
                        == .hookAcceptedWithoutStatus)
            } catch {
                oldExit.release()
                _ = try? await pendingExit.value
                throw error
            }
        }
    }

    @Test("finish clears unverified memory and refuses later submissions")
    func quitClearsMemory() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        let ingestion = SessionsIngestion(
            repository: fixture.makeRepository(),
            limits: .init(maximumPendingPerPane: 4, maximumPendingGlobal: 8), probe: { _ in })
        do {
            _ = try await Self.submit(ingestion, pane: pane, signal: .turnStart)
            await ingestion.finish()
            #expect(await ingestion.lastRefusal(paneId: pane) == nil)
            #expect(await ingestion.unverifiedStatusRuntime.panes.isEmpty)
        } catch {
            await ingestion.finish()
            throw error
        }
    }

    @Test("a verified bind held in the FIFO wins over the queued unverified status")
    func bindingWinsQueuedStatusRace() async throws {
        let fixture = try SessionsDatabaseFixture()
        let held = HeldStep<Void>("verified bind before queued unverified status")
        let pane = UUIDv7.generate()
        let depth = LocalFactSource<UUID, Int>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { "pending=\($0)" },
                isClosing: { _, value in value == 0 }))
        let recorder = try depth.attach()
        let ingestion = SessionsIngestion(
            repository: .init(sqliteAccess: HeldUnverifiedStatusSQLiteAccess(base: fixture.sqliteAccess, held: held)),
            limits: .init(maximumPendingPerPane: 4, maximumPendingGlobal: 8),
            probe: { statistics in if statistics.paneId == pane { depth.sink(pane, statistics.pendingForPane) } })
        let statusMailbox = await ingestion.statusPublicationMailbox
        let binding = Task {
            try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, sessionId: "verified",
                    eventName: .turnStart, signal: .turnStart, turnId: nil))
        }
        var status: Task<SessionsUnverifiedStatusOutcome, any Error>?
        do {
            try await held.firstArrival()
            try await recorder.expectNext(in: pane, 1)
            status = Task {
                try await Self.submit(ingestion, pane: pane, signal: .permission(toolName: nil, questions: nil))
            }
            try await recorder.expectNext(in: pane, 2)
            held.release()
            _ = try await binding.value
            let pending = try #require(status)
            #expect(try await pending.value == .hookAcceptedWithoutStatus)
            try await recorder.expectNext(in: pane, 1)
            try await recorder.expectNext(in: pane, 0)
            #expect(await ingestion.lastRefusal(paneId: pane)?.reason == .credentialNotRecognized)
            #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .working(.active))
            #expect(
                statusMailbox.takeBatch()[.init(existingUUID: pane)]
                    == .set(.init(status: .working(.active))))
        } catch {
            held.release()
            _ = try? await binding.value
            _ = try? await status?.value
            await ingestion.finish()
            try? await recorder.finish()
            throw error
        }
        await ingestion.finish()
        try await recorder.finish()
    }

    @Test("unverified status capacity rejection publishes the real queueFull refusal")
    func capacityRefusalIsPublished() async throws {
        let fixture = try SessionsDatabaseFixture()
        let held = HeldStep<Void>("occupied Sessions queue before unverified status")
        let pane = UUIDv7.generate()
        let other = UUIDv7.generate()
        let ingestion = SessionsIngestion(
            repository: .init(sqliteAccess: HeldUnverifiedStatusSQLiteAccess(base: fixture.sqliteAccess, held: held)),
            limits: .init(maximumPendingPerPane: 1, maximumPendingGlobal: 1), probe: { _ in })
        let statusMailbox = await ingestion.statusPublicationMailbox
        let binding = Task { try await ingestion.submitHook(makeHookAdmission(paneId: other)) }
        do {
            try await held.firstArrival()
            await #expect(throws: SessionsRepositoryError.globalQueueFull) {
                try await Self.submit(ingestion, pane: pane, signal: .turnStart)
            }
            #expect(await ingestion.lastRefusal(paneId: pane)?.reason == .queueFull)
            #expect(await ingestion.lastRefusal(paneId: pane)?.intent == .status)
            #expect(
                statusMailbox.takeBatch()[.init(existingUUID: pane)]
                    == .set(.init(status: .unknown, connectionIssue: .queueFull)))
            held.release()
            _ = try await binding.value
        } catch {
            held.release()
            _ = try? await binding.value
            await ingestion.finish()
            throw error
        }
        await ingestion.finish()
    }

    static func submit(
        _ ingestion: SessionsIngestion, pane: UUID, session: String = "A",
        signal: SessionProviderSignal, instant: ContinuousClock.Instant = ContinuousClock.now,
        remainsPresent: @escaping @Sendable () -> Bool = { true }
    ) async throws -> SessionsUnverifiedStatusOutcome {
        try await ingestion.recordUnverifiedStatus(
            paneId: pane,
            hook: makeHookAdmission(
                paneId: pane, sessionId: session, eventName: signal.name, signal: signal,
                admissionInstant: instant, turnId: nil),
            refusal: .init(
                reason: .credentialNotRecognized, event: signal.name.rawValue, at: .distantPast, intent: .status),
            remainsPresent: remainsPresent)
    }

    static func protectedCounts(_ fixture: SessionsDatabaseFixture) async throws -> [Int] {
        try await fixture.sqliteAccess.read { database in
            try [
                "sessions_pane_binding", "sessions_conversation", "sessions_operation", "sessions_evidence",
                "sessions_source", "pane_state", "pane_request", "pane_event", "pane_write_order", "pane_epoch_claim",
            ].map { table in try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
        }
    }
}

private actor HeldUnverifiedStatusSQLiteAccess: SessionsSQLiteAccess {
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
