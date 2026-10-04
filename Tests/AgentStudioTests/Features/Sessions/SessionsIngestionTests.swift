import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

@Suite("Sessions ordered ingestion")
struct SessionsIngestionTests {
    @Test("loss disclosure stays inside the configured live queue bounds")
    func lossDisclosureStaysInsideConfiguredQueueBounds() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let sourceGenerationId = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-overload",
                        sourceGenerationId: sourceGenerationId,
                        reportedAt: 1
                    )
                )
            )
        }

        let barrierAccess = FirstWriteBarrierSessionsSQLiteAccess(base: fixture.sqliteAccess)
        let probeRecorder = SessionsIngestionProbeRecorder()
        let probeEvents = AsyncStream.makeStream(
            of: SessionsIngestionStatistics.self, bufferingPolicy: .bufferingNewest(32))
        let ingestion = SessionsIngestion(
            repository: SessionsRepository(sqliteAccess: barrierAccess),
            limits: SessionsIngestionLimits(
                maximumPendingPerPane: 1,
                maximumPendingGlobal: 2
            ),
            probe: { statistics in
                probeRecorder.record(statistics)
                probeEvents.continuation.yield(statistics)
            }
        )

        try await withOwnedSessionsIngestion(ingestion) { ingestion in
            let firstSubmission = Task {
                try await ingestion.submit(
                    correlationId: UUIDv7.generate(),
                    mutation: .recordEvidence(
                        SessionsEvidenceMutation(
                            context: .sourceGeneration(
                                paneId: paneId,
                                sourceGenerationId: sourceGenerationId
                            ),
                            occurrenceId: UUIDv7.generate(),
                            turnId: "turn-overload",
                            subject: .root,
                            kind: .activityStarted,
                            origin: .reported,
                            freshness: .live,
                            occurredAt: Date(timeIntervalSince1970: 2),
                            sourceCursor: "cursor-1"
                        )
                    )
                )
            }
            await barrierAccess.waitUntilFirstWriteStarts()
            let rejectedSubmission = Task {
                try await ingestion.submit(
                    correlationId: UUIDv7.generate(),
                    mutation: .recordEvidence(
                        SessionsEvidenceMutation(
                            context: .sourceGeneration(
                                paneId: paneId,
                                sourceGenerationId: sourceGenerationId
                            ),
                            occurrenceId: UUIDv7.generate(),
                            turnId: "turn-overload",
                            subject: .root,
                            kind: .completed,
                            origin: .reported,
                            freshness: .live,
                            occurredAt: Date(timeIntervalSince1970: 3),
                            sourceCursor: "cursor-2"
                        )
                    )
                )
            }
            for await statistics in probeEvents.stream {
                if statistics.event == .capacityRejected(.paneQueueFull) { break }
            }
            await barrierAccess.releaseFirstWrite()
            _ = try await firstSubmission.value
            await #expect(throws: SessionsRepositoryError.paneQueueFull(paneId)) {
                try await rejectedSubmission.value
            }
            let snapshot = try await ingestion.snapshot(makeSessionsSnapshotQuery(paneId: paneId))
            #expect(snapshot.losses.count == 1)
            #expect(snapshot.losses.first?.reason == .paneQueueFull)
            #expect(probeRecorder.maximumPaneDepth <= 1)
            #expect(probeRecorder.maximumGlobalDepth <= 2)
            probeEvents.continuation.finish()
        }
    }

    @Test("loss persistence failure returns database failure without accepting the dropped fact")
    func lossPersistenceFailureHasNoFalseDurableReceipt() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let sourceGenerationId = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-loss-failure",
                        sourceGenerationId: sourceGenerationId,
                        reportedAt: 1
                    )
                )
            )
        }
        try await fixture.rejectLossWrites()
        let barrierAccess = FirstWriteBarrierSessionsSQLiteAccess(base: fixture.sqliteAccess)
        let probeEvents = AsyncStream.makeStream(
            of: SessionsIngestionStatistics.self, bufferingPolicy: .bufferingNewest(32))
        let ingestion = SessionsIngestion(
            repository: SessionsRepository(sqliteAccess: barrierAccess),
            limits: SessionsIngestionLimits(
                maximumPendingPerPane: 1,
                maximumPendingGlobal: 2
            ),
            probe: { statistics in probeEvents.continuation.yield(statistics) }
        )
        let droppedOccurrenceId = UUIDv7.generate()

        try await withOwnedSessionsIngestion(ingestion) { ingestion in
            let firstSubmission = Task {
                try await ingestion.submit(
                    correlationId: UUIDv7.generate(),
                    mutation: .recordEvidence(
                        SessionsEvidenceMutation(
                            context: .sourceGeneration(
                                paneId: paneId,
                                sourceGenerationId: sourceGenerationId
                            ),
                            occurrenceId: UUIDv7.generate(),
                            turnId: "turn-loss-failure",
                            subject: .root,
                            kind: .activityStarted,
                            origin: .reported,
                            freshness: .live,
                            occurredAt: Date(timeIntervalSince1970: 2),
                            sourceCursor: "cursor-1"
                        )
                    )
                )
            }
            await barrierAccess.waitUntilFirstWriteStarts()
            let rejectedSubmission = Task {
                try await ingestion.submit(
                    correlationId: UUIDv7.generate(),
                    mutation: .recordEvidence(
                        SessionsEvidenceMutation(
                            context: .sourceGeneration(
                                paneId: paneId,
                                sourceGenerationId: sourceGenerationId
                            ),
                            occurrenceId: droppedOccurrenceId,
                            turnId: "turn-loss-failure",
                            subject: .root,
                            kind: .completed,
                            origin: .reported,
                            freshness: .live,
                            occurredAt: Date(timeIntervalSince1970: 3),
                            sourceCursor: "cursor-2"
                        )
                    )
                )
            }
            for await statistics in probeEvents.stream {
                if statistics.event == .capacityRejected(.paneQueueFull) { break }
            }
            await barrierAccess.releaseFirstWrite()
            _ = try await firstSubmission.value
            await #expect(throws: DatabaseError.self) {
                try await rejectedSubmission.value
            }
            let persistedCounts = try await fixture.sqliteAccess.read { database in
                (
                    loss: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_loss") ?? -1,
                    evidence: try Int.fetchOne(
                        database,
                        sql: "SELECT COUNT(*) FROM sessions_evidence WHERE occurrence_id = ?",
                        arguments: [droppedOccurrenceId.uuidString]
                    ) ?? -1
                )
            }
            #expect(persistedCounts.loss == 0)
            #expect(persistedCounts.evidence == 0)
            probeEvents.continuation.finish()
        }
    }

    @Test("finish joins admitted work and rejects overload work still waiting for capacity")
    func finishJoinsAdmittedWorkAndRejectsWaitingOverload() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let sourceGenerationId = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-finish",
                        sourceGenerationId: sourceGenerationId,
                        reportedAt: 1
                    )
                )
            )
        }
        let barrierAccess = FirstWriteBarrierSessionsSQLiteAccess(base: fixture.sqliteAccess)
        let probeEvents = AsyncStream.makeStream(
            of: SessionsIngestionStatistics.self, bufferingPolicy: .bufferingNewest(32))
        let ingestion = SessionsIngestion(
            repository: SessionsRepository(sqliteAccess: barrierAccess),
            limits: SessionsIngestionLimits(
                maximumPendingPerPane: 1,
                maximumPendingGlobal: 2
            ),
            probe: { statistics in probeEvents.continuation.yield(statistics) }
        )
        let firstSubmission = Task {
            try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .recordEvidence(
                    SessionsEvidenceMutation(
                        context: .sourceGeneration(
                            paneId: paneId,
                            sourceGenerationId: sourceGenerationId
                        ),
                        occurrenceId: UUIDv7.generate(),
                        turnId: "turn-finish",
                        subject: .root,
                        kind: .activityStarted,
                        origin: .reported,
                        freshness: .live,
                        occurredAt: Date(timeIntervalSince1970: 2),
                        sourceCursor: "cursor-1"
                    )
                )
            )
        }
        await barrierAccess.waitUntilFirstWriteStarts()
        let unacceptedOccurrenceId = UUIDv7.generate()
        let waitingSubmission = Task {
            try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .recordEvidence(
                    SessionsEvidenceMutation(
                        context: .sourceGeneration(
                            paneId: paneId,
                            sourceGenerationId: sourceGenerationId
                        ),
                        occurrenceId: unacceptedOccurrenceId,
                        turnId: "turn-finish",
                        subject: .root,
                        kind: .completed,
                        origin: .reported,
                        freshness: .live,
                        occurredAt: Date(timeIntervalSince1970: 3),
                        sourceCursor: "cursor-2"
                    )
                )
            )
        }
        for await statistics in probeEvents.stream {
            if statistics.event == .capacityRejected(.paneQueueFull) { break }
        }
        let finishTask = Task { await ingestion.finish() }
        for await statistics in probeEvents.stream {
            if statistics.event == .finishing { break }
        }
        await barrierAccess.releaseFirstWrite()
        _ = try await firstSubmission.value
        await #expect(throws: SessionsRepositoryError.ingestionFinished) {
            try await waitingSubmission.value
        }
        await finishTask.value
        let persistedCounts = try await fixture.sqliteAccess.read { database in
            (
                loss: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_loss") ?? -1,
                evidence: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM sessions_evidence WHERE occurrence_id = ?",
                    arguments: [unacceptedOccurrenceId.uuidString]
                ) ?? -1
            )
        }
        #expect(persistedCounts.loss == 0)
        #expect(persistedCounts.evidence == 0)
        probeEvents.continuation.finish()
    }

    @Test("A to B replacement rejects delayed A as current and repeated B is idempotent")
    func bindingGenerationOrdering() async throws {
        let fixture = try SessionsDatabaseFixture()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let paneId = UUIDv7.generate()
            let sourceGenerationA = UUIDv7.generate()
            let sourceGenerationB = UUIDv7.generate()
            let bindA = makeQualifiedBindMutation(
                paneId: paneId,
                providerConversationId: "conversation-A",
                sourceGenerationId: sourceGenerationA,
                reportedAt: 1
            )
            let bindB = makeQualifiedBindMutation(
                paneId: paneId,
                providerConversationId: "conversation-B",
                sourceGenerationId: sourceGenerationB,
                reportedAt: 2
            )

            let establishedA = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(bindA)
            )
            guard case .binding(.established(let bindingA)) = establishedA else {
                Issue.record("Expected binding A to establish, got \(establishedA)")
                return
            }
            let replacedByB = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(bindB)
            )
            guard case .binding(.replaced(let previousBinding, let bindingB)) = replacedByB else {
                Issue.record("Expected binding B to replace A, got \(replacedByB)")
                return
            }
            #expect(previousBinding.bindingGenerationId == bindingA.bindingGenerationId)
            #expect(bindingB.providerConversationId == "conversation-B")

            let delayedAOccurrenceId = UUIDv7.generate()
            let delayedA = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .recordEvidence(
                    SessionsEvidenceMutation(
                        context: .sourceGeneration(
                            paneId: paneId,
                            sourceGenerationId: sourceGenerationA
                        ),
                        occurrenceId: delayedAOccurrenceId,
                        turnId: "turn-A",
                        subject: .root,
                        kind: .completed,
                        origin: .reported,
                        freshness: .late,
                        occurredAt: Date(timeIntervalSince1970: 3),
                        sourceCursor: nil
                    )
                )
            )
            #expect(delayedA == .historical(occurrenceId: delayedAOccurrenceId))

            let repeatedB = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-B",
                        sourceGenerationId: sourceGenerationB,
                        reportedAt: 4
                    )
                )
            )
            #expect(repeatedB == .binding(.unchanged(bindingB)))

            let snapshot = try await ingestion.snapshot(makeSessionsSnapshotQuery(paneId: paneId))
            #expect(snapshot.currentBinding == bindingB)
            #expect(try await ingestion.sessionSummary(paneId: paneId)?.status == .unknown)
            #expect(snapshot.historicalOccurrenceIds.contains(delayedAOccurrenceId))
        }
    }

    @Test("source end and app restart require a fresh generation")
    func sourceEndAndRestartRequireFreshGeneration() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let firstSourceGenerationId = UUIDv7.generate()
        let firstBinding = try await withSessionsIngestion(
            repository: fixture.makeRepository()
        ) { firstIngestion in
            let firstBind = try await firstIngestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-restart",
                        sourceGenerationId: firstSourceGenerationId,
                        reportedAt: 1
                    )
                )
            )
            guard case .binding(.established(let firstBinding)) = firstBind else {
                throw SessionsTestError.unexpectedOutcome("Expected initial binding, got \(firstBind)")
            }
            _ = try await firstIngestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .sourceEnded(
                    SessionsSourceEndMutation(
                        paneId: paneId,
                        sourceGenerationId: firstSourceGenerationId,
                        endedAt: Date(timeIntervalSince1970: 2)
                    )
                )
            )
            let endedSnapshot = try await firstIngestion.snapshot(
                makeSessionsSnapshotQuery(paneId: paneId)
            )
            #expect(endedSnapshot.currentBinding?.status == .ended)
            #expect(try await firstIngestion.sessionSummary(paneId: paneId)?.status == .idle(.ended))
            return firstBinding
        }

        try await withSessionsIngestion(repository: fixture.makeRepository()) { restartedIngestion in
            let launchOutcome = try await restartedIngestion.prepareForLaunch(
                at: Date(timeIntervalSince1970: 3)
            )
            #expect(launchOutcome.activeSourcesEnded == 0)
            let nextSourceGenerationId = UUIDv7.generate()
            let rebound = try await restartedIngestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-restart",
                        sourceGenerationId: nextSourceGenerationId,
                        reportedAt: 4
                    )
                )
            )
            guard case .binding(.established(let freshBinding)) = rebound else {
                Issue.record("Expected a fresh post-restart generation, got \(rebound)")
                return
            }
            #expect(freshBinding.bindingGenerationId != firstBinding.bindingGenerationId)
            #expect(freshBinding.sourceGenerationId == nextSourceGenerationId)
            #expect(freshBinding.status == .active)
        }
    }

}
