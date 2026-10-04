import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

@Suite("Sessions remaining S2 contracts")
struct SessionsRemainingContractTests {
    @Test("evidence replay ignores later server receipt metadata and returns its original occurrence")
    func scalarReplayUsesCallerIntentFingerprint() async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let paneId = UUIDv7.generate()
        let source = UUIDv7.generate()
        let occurrence = UUIDv7.generate()
        try await withSessionsIngestion(repository: repository) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId, providerConversationId: "scalar-replay", sourceGenerationId: source,
                        reportedAt: 1)))
            let correlation = UUIDv7.generate()
            let first = try await ingestion.submit(
                correlationId: correlation,
                mutation: .recordEvidence(
                    makeSessionsEvidenceMutation(
                        paneId: paneId, sourceGenerationId: source, kind: .activityStarted, occurrenceId: occurrence,
                        at: 2)))
            let replay = try await ingestion.submit(
                correlationId: correlation,
                mutation: .recordEvidence(
                    makeSessionsEvidenceMutation(
                        paneId: paneId, sourceGenerationId: source, kind: .activityStarted, occurrenceId: occurrence,
                        at: 20)))
            #expect(replay == first)
            #expect(first == .evidenceRecorded(occurrenceId: occurrence))
            let context = try await repository.statusContext(paneId: paneId)
            #expect(context.evidence.count == 1)
            #expect(context.evidence.first?.occurrenceId == occurrence)
            #expect(context.evidence.first?.kind == .activityStarted)
            #expect(context.evidence.first?.occurredAt == Date(timeIntervalSince1970: 2))
        }
    }

    @Test("delayed bind and original replay never retarget a newer current binding")
    func delayedBindAndOriginalReplayPreserveCurrentBinding() async throws {
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
            let correlationA = UUIDv7.generate()
            let establishedA = try await ingestion.submit(
                correlationId: correlationA,
                mutation: .bind(bindA)
            )
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-B",
                        sourceGenerationId: sourceGenerationB,
                        reportedAt: 2
                    )
                )
            )

            let delayedBindOccurrenceId = UUIDv7.generate()
            let delayedBind = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-A",
                        sourceGenerationId: sourceGenerationA,
                        occurrenceId: delayedBindOccurrenceId,
                        reportedAt: 3
                    )
                )
            )
            #expect(delayedBind == .historical(occurrenceId: delayedBindOccurrenceId))

            let replayedA = try await ingestion.submit(
                correlationId: correlationA,
                mutation: .bind(bindA)
            )
            #expect(replayedA == establishedA)
            let snapshot = try await ingestion.snapshot(makeSessionsSnapshotQuery(paneId: paneId))
            #expect(snapshot.currentBinding?.providerConversationId == "conversation-B")
            #expect(snapshot.currentBinding?.sourceGenerationId == sourceGenerationB)
        }
    }

    @Test(
        "unseen non-live provider binds remain historical without replacing the current generation",
        arguments: [SessionsEvidenceFreshness.late, .historical]
    )
    func unseenNonLiveProviderBindPreservesCurrentGeneration(
        freshness: SessionsEvidenceFreshness
    ) async throws {
        let fixture = try SessionsDatabaseFixture()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let paneId = UUIDv7.generate()
            let sourceGenerationA = UUIDv7.generate()
            let sourceGenerationC = UUIDv7.generate()
            let establishedA = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-A",
                        sourceGenerationId: sourceGenerationA,
                        reportedAt: 1
                    )
                )
            )
            guard case .binding(.established(let bindingA)) = establishedA else {
                Issue.record("Expected binding A to establish, got \(establishedA)")
                return
            }
            let historicalOccurrenceId = UUIDv7.generate()

            let outcome = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-C",
                        sourceGenerationId: sourceGenerationC,
                        occurrenceId: historicalOccurrenceId,
                        freshness: freshness,
                        reportedAt: 2
                    )
                )
            )

            #expect(outcome == .historical(occurrenceId: historicalOccurrenceId))
            let snapshot = try await ingestion.snapshot(makeSessionsSnapshotQuery(paneId: paneId))
            #expect(snapshot.currentBinding == bindingA)
            let persistenceCounts = try await loadGenerationPersistenceCounts(
                fixture.sqliteAccess,
                currentSourceGenerationId: sourceGenerationA,
                rejectedSourceGenerationId: sourceGenerationC
            )
            #expect(persistenceCounts.currentBindings == 1)
            #expect(persistenceCounts.currentSources == 1)
            #expect(persistenceCounts.rejectedBindings == 0)
            #expect(persistenceCounts.rejectedSources == 0)
        }
    }

    @Test("explicit model bind retains authority to replace the current provider generation")
    func explicitModelBindReplacesCurrentProviderGeneration() async throws {
        let fixture = try SessionsDatabaseFixture()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let paneId = UUIDv7.generate()
            let establishedA = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-A",
                        sourceGenerationId: UUIDv7.generate(),
                        reportedAt: 1
                    )
                )
            )
            guard case .binding(.established(let bindingA)) = establishedA else {
                Issue.record("Expected binding A to establish, got \(establishedA)")
                return
            }
            let modelSourceGenerationId = UUIDv7.generate()
            let modelBind = SessionsBindMutation.explicitModelBind(
                SessionsExplicitModelBindInput(
                    provider: SessionsProviderIdentity(
                        providerIdentifier: "model-selected-provider",
                        exactVersion: "1.0.0",
                        operatingMode: "model"
                    ),
                    source: SessionsBindingSourceIdentity(
                        paneId: paneId,
                        providerConversationId: "conversation-model",
                        sourceId: "model-selected-source",
                        sourceGenerationId: modelSourceGenerationId,
                        occurrenceId: UUIDv7.generate()
                    ),
                    reportedAt: Date(timeIntervalSince1970: 2)
                )
            )

            let outcome = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(modelBind)
            )

            guard case .binding(.replaced(let endedA, let modelBinding)) = outcome else {
                Issue.record("Expected explicit model bind to replace A, got \(outcome)")
                return
            }
            #expect(endedA.bindingGenerationId == bindingA.bindingGenerationId)
            #expect(modelBinding.sourceGenerationId == modelSourceGenerationId)
            #expect(modelBinding.origin == .agentReported)
            let snapshot = try await ingestion.snapshot(makeSessionsSnapshotQuery(paneId: paneId))
            #expect(snapshot.currentBinding == modelBinding)
        }
    }

    @Test("competing identity without a qualified transition returns binding conflict")
    func competingUnqualifiedBindReturnsConflict() async throws {
        let fixture = try SessionsDatabaseFixture()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let paneId = UUIDv7.generate()
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-current",
                        sourceGenerationId: UUIDv7.generate(),
                        reportedAt: 1
                    )
                )
            )
            let unqualifiedBind = SessionsBindMutation(
                paneId: paneId,
                providerIdentifier: "unqualified-provider",
                providerVersion: "unknown",
                providerMode: "unknown",
                providerConversationId: "conversation-competing",
                sourceId: "unqualified-source",
                sourceGenerationId: UUIDv7.generate(),
                transition: .unqualified(occurrenceId: UUIDv7.generate()),
                freshness: .live,
                reportedAt: Date(timeIntervalSince1970: 2)
            )

            await #expect(throws: SessionsRepositoryError.bindingConflict(paneId)) {
                try await ingestion.submit(
                    correlationId: UUIDv7.generate(),
                    mutation: .bind(unqualifiedBind)
                )
            }
            let snapshot = try await ingestion.snapshot(makeSessionsSnapshotQuery(paneId: paneId))
            #expect(snapshot.currentBinding?.providerConversationId == "conversation-current")
        }
    }

    @Test("source cursor and evidence roll back together then advance together")
    func sourceCursorSharesEvidenceTransaction() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let sourceGenerationId = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-cursor",
                        sourceGenerationId: sourceGenerationId,
                        reportedAt: 1
                    )
                )
            )
            let rejectedOccurrenceId = UUIDv7.generate()
            try await fixture.sqliteAccess.write { database in
                try database.execute(
                    sql: """
                        CREATE TRIGGER reject_cursor_evidence
                        BEFORE INSERT ON sessions_evidence
                        WHEN NEW.occurrence_id = '\(rejectedOccurrenceId.uuidString)'
                        BEGIN
                            SELECT RAISE(ABORT, 'forced cursor rollback');
                        END
                        """
                )
            }
            await #expect(throws: DatabaseError.self) {
                try await ingestion.submit(
                    correlationId: UUIDv7.generate(),
                    mutation: .recordEvidence(
                        SessionsEvidenceMutation(
                            context: .sourceGeneration(
                                paneId: paneId,
                                sourceGenerationId: sourceGenerationId
                            ),
                            occurrenceId: rejectedOccurrenceId,
                            turnId: "turn-cursor",
                            subject: .root,
                            kind: .activityStarted,
                            origin: .reported,
                            freshness: .live,
                            occurredAt: Date(timeIntervalSince1970: 2),
                            sourceCursor: "cursor-rejected"
                        )
                    )
                )
            }
            let cursorAfterFailure = try await loadSourceCursor(
                fixture.sqliteAccess,
                sourceGenerationId: sourceGenerationId
            )
            #expect(cursorAfterFailure == nil)

            let acceptedOccurrenceId = UUIDv7.generate()
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .recordEvidence(
                    SessionsEvidenceMutation(
                        context: .sourceGeneration(
                            paneId: paneId,
                            sourceGenerationId: sourceGenerationId
                        ),
                        occurrenceId: acceptedOccurrenceId,
                        turnId: "turn-cursor",
                        subject: .root,
                        kind: .activityStarted,
                        origin: .reported,
                        freshness: .live,
                        occurredAt: Date(timeIntervalSince1970: 3),
                        sourceCursor: "cursor-accepted"
                    )
                )
            )
            let cursorAfterCommit = try await loadSourceCursor(
                fixture.sqliteAccess,
                sourceGenerationId: sourceGenerationId
            )
            #expect(cursorAfterCommit == "cursor-accepted")
        }
    }

    @Test("stronger matching completion upgrades one seen result")
    func strongerCompletionPreservesSeenResultDisposition() async throws {
        let fixture = try SessionsDatabaseFixture()
        let paneId = UUIDv7.generate()
        let sourceGenerationId = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId,
                        providerConversationId: "conversation-result-upgrade",
                        sourceGenerationId: sourceGenerationId,
                        reportedAt: 1
                    )
                )
            )
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .recordEvidence(
                    SessionsEvidenceMutation(
                        context: .sourceGeneration(
                            paneId: paneId,
                            sourceGenerationId: sourceGenerationId
                        ),
                        occurrenceId: UUIDv7.generate(),
                        turnId: "turn-result",
                        subject: .root,
                        kind: .completed,
                        origin: .agentReported,
                        freshness: .live,
                        occurredAt: Date(timeIntervalSince1970: 2),
                        sourceCursor: "cursor-agent"
                    )
                )
            )
            try await fixture.sqliteAccess.write { database in
                try database.execute(
                    sql: "UPDATE sessions_result SET is_seen = 1, seen_at = 2 WHERE turn_id = 'turn-result'"
                )
            }
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .recordEvidence(
                    SessionsEvidenceMutation(
                        context: .sourceGeneration(
                            paneId: paneId,
                            sourceGenerationId: sourceGenerationId
                        ),
                        occurrenceId: UUIDv7.generate(),
                        turnId: "turn-result",
                        subject: .root,
                        kind: .completed,
                        origin: .reported,
                        freshness: .live,
                        occurredAt: Date(timeIntervalSince1970: 3),
                        sourceCursor: "cursor-provider"
                    )
                )
            )

            let snapshot = try await ingestion.snapshot(makeSessionsSnapshotQuery(paneId: paneId))
            #expect(snapshot.results.count == 1)
            #expect(snapshot.results.first?.origin == .reported)
            #expect(snapshot.results.first?.disposition == .seen)
            #expect(snapshot.results.first?.seenAt == Date(timeIntervalSince1970: 2))
        }
    }

    @Test("nonpaged snapshots preserve binding, revision and complete evidence history without writes")
    func nonpagedSnapshotIsReadOnly() async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let paneId = UUIDv7.generate()
        let source = UUIDv7.generate()
        try await withSessionsIngestion(repository: repository) { ingestion in
            _ = try await ingestion.submit(
                correlationId: UUIDv7.generate(),
                mutation: .bind(
                    makeQualifiedBindMutation(
                        paneId: paneId, providerConversationId: "snapshot", sourceGenerationId: source, reportedAt: 1)))
            var occurrences: Set<UUID> = []
            for ordinal in 1...3 {
                let occurrence = UUIDv7.generate()
                occurrences.insert(occurrence)
                let mutation = SessionsEvidenceMutation(
                    context: .sourceGeneration(paneId: paneId, sourceGenerationId: source),
                    occurrenceId: occurrence, turnId: "turn-snapshot", subject: .root, kind: .activityStarted,
                    origin: .reported, freshness: .late, occurredAt: Date(timeIntervalSince1970: Double(ordinal + 1)),
                    sourceCursor: nil)
                _ = try await ingestion.submit(correlationId: UUIDv7.generate(), mutation: .recordEvidence(mutation))
            }
            let before = try await repository.statusContext(paneId: paneId)
            let first = try await ingestion.snapshot(.pane(paneId))
            let second = try await ingestion.snapshot(.pane(paneId))
            let after = try await repository.statusContext(paneId: paneId)
            #expect(first == second)
            #expect(first.revision == before.revision)
            #expect(first.currentBinding == before.currentBinding)
            #expect(Set(first.historicalOccurrenceIds) == occurrences)
            #expect(after == before)
        }
    }

    @Test("only an exact profile capability can create reported authority")
    func exactProfileQualificationIsRequired() throws {
        let profile = SessionsProviderProfile(
            providerIdentifier: "provider",
            exactVersion: "1.2.3",
            operatingMode: "interactive",
            qualifiedCapabilities: [.sessionStart]
        )
        let registry = SessionsProviderAdapterRegistry(profiles: [profile])
        let paneId = UUIDv7.generate()
        let sourceGenerationId = UUIDv7.generate()

        #expect(
            registry.qualification(
                providerIdentifier: "provider",
                exactVersion: "1.2.4",
                operatingMode: "interactive",
                capability: .sessionStart
            ) == .unverified
        )
        #expect(
            registry.qualification(
                providerIdentifier: "provider",
                exactVersion: "1.2.3",
                operatingMode: "interactive",
                capability: .turnDone
            ) == .unavailable
        )
        #expect(
            registry.admitProviderEvidence(
                SessionsProviderEvidenceAdmission(
                    provider: SessionsProviderIdentity(
                        providerIdentifier: "provider",
                        exactVersion: "1.2.4",
                        operatingMode: "interactive"
                    ),
                    capability: .sessionStart,
                    paneId: paneId,
                    sourceGenerationId: sourceGenerationId,
                    freshness: .live
                )
            ) == nil
        )
        #expect(
            registry.admitProviderEvidence(
                SessionsProviderEvidenceAdmission(
                    provider: SessionsProviderIdentity(
                        providerIdentifier: "provider",
                        exactVersion: "1.2.3",
                        operatingMode: "interactive"
                    ),
                    capability: .turnDone,
                    paneId: paneId,
                    sourceGenerationId: sourceGenerationId,
                    freshness: .live
                )
            ) == nil
        )
    }
}

private func loadSourceCursor(
    _ sqliteAccess: TestSessionsSQLiteAccess,
    sourceGenerationId: UUID
) async throws -> String? {
    try await sqliteAccess.read { database in
        try String.fetchOne(
            database,
            sql: "SELECT last_cursor FROM sessions_source WHERE source_generation_id = ?",
            arguments: [sourceGenerationId.uuidString]
        )
    }
}

private struct SessionsGenerationPersistenceCounts: Sendable {
    let currentBindings: Int
    let currentSources: Int
    let rejectedBindings: Int
    let rejectedSources: Int
}

private func loadGenerationPersistenceCounts(
    _ sqliteAccess: TestSessionsSQLiteAccess,
    currentSourceGenerationId: UUID,
    rejectedSourceGenerationId: UUID
) async throws -> SessionsGenerationPersistenceCounts {
    try await sqliteAccess.read { database in
        func countRows(table: String, sourceGenerationId: UUID) throws -> Int {
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM \(table) WHERE source_generation_id = ?",
                arguments: [sourceGenerationId.uuidString]
            ) ?? 0
        }
        return try SessionsGenerationPersistenceCounts(
            currentBindings: countRows(
                table: "sessions_pane_binding",
                sourceGenerationId: currentSourceGenerationId
            ),
            currentSources: countRows(
                table: "sessions_source",
                sourceGenerationId: currentSourceGenerationId
            ),
            rejectedBindings: countRows(
                table: "sessions_pane_binding",
                sourceGenerationId: rejectedSourceGenerationId
            ),
            rejectedSources: countRows(
                table: "sessions_source",
                sourceGenerationId: rejectedSourceGenerationId
            )
        )
    }
}
