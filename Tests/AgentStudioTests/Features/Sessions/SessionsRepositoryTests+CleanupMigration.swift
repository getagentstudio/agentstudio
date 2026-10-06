import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

extension SessionsRepositoryTests {
    @Test("populated pre-cut upgrade preserves evidence/questions and repairs only the latest launch-ended binding")
    func populatedCleanupMigrationPreservesStatus() async throws {
        let fixture = try SessionsCleanupUpgradeFixture()
        let before = try await fixture.access.read { database in
            try Row.fetchAll(database, sql: fixture.retainedProjection(beforeMigration: true)).map { row in
                row.map { $0.1 }
            }
        }
        try WorkspaceLocalMigrations.migrate(fixture.queue)
        try WorkspaceLocalMigrations.migrate(fixture.queue)
        let after = try await fixture.access.read { database in
            #expect(try Int.fetchOne(database, sql: "PRAGMA foreign_keys") == 1)
            #expect(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
            for table in ["sessions_message", "sessions_result", "sessions_loss", "sessions_attention"] {
                #expect(try !database.tableExists(table))
            }
            #expect(try database.tableExists("sessions_operation"))
            #expect(try database.tableExists("sessions_source"))
            #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_provider_question") == 1)
            #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessions_provider_question_option") == 1)
            let columns = try String.fetchAll(database, sql: "SELECT name FROM pragma_table_info('sessions_evidence')")
            #expect(Set(columns) == Set(fixture.retainedColumns))
            return try Row.fetchAll(database, sql: fixture.retainedProjection(beforeMigration: false)).map { row in
                row.map { $0.1 }
            }
        }
        #expect(after == before)
        let repository = SessionsRepository(sqliteAccess: fixture.access)
        let launch = try await repository.statusContext(paneId: fixture.launchPane)
        #expect(launch.currentBinding?.status == .active)
        #expect(launch.currentBinding?.endedAt == nil)
        #expect(launch.sources.first?.status == .active)
        #expect(launch.sources.first?.endedAt == nil)
        let ended = try await repository.statusContext(paneId: fixture.endedPane)
        #expect(ended.currentBinding?.status == .ended)
        #expect(ended.sources.first?.status == .ended)
        let replacement = try await repository.statusContext(paneId: fixture.replacedPane)
        #expect(replacement.currentBinding?.bindingGenerationId == fixture.newBinding)
        #expect(replacement.currentBinding?.status == .active)
        #expect(replacement.bindings.first { $0.bindingGenerationId == fixture.oldBinding }?.status == .ended)
        #expect(replacement.sources.first { $0.bindingGenerationId == fixture.oldBinding }?.status == .ended)
        #expect(launch.evidence.filter { $0.statusEffect == .recordedOnly }.count == 2)
        let question = try #require(launch.evidence.first { $0.recordId == fixture.questionRecord })
        #expect(question.statusEffect == .applied)
        guard case .question(let call, let questions)? = question.providerSignal else {
            Issue.record("Retained provider question must decode after the parent rebuild")
            return
        }
        #expect(call == "question-call")
        #expect(questions == fixture.questions)
        try await withSessionsIngestion(repository: repository) { ingestion in
            // No hook is submitted: demand-driven reload alone establishes this status.
            let summary = try await ingestion.sessionSummary(paneId: fixture.launchPane)
            #expect(summary?.status == .needsYou(.question))
            #expect(summary?.providerPrompts.count == 1)
        }
        // A fresh owner repeats the retained read; recorded-only approval/failure must stay out.
        try await withSessionsIngestion(repository: repository) { ingestion in
            let summary = try await ingestion.sessionSummary(paneId: fixture.launchPane)
            #expect(summary?.status == .needsYou(.question))
            #expect(summary?.providerPrompts.count == 1)
        }
        try await fixture.access.write { database in
            // Enum text is parsed by Swift, never constrained by a SQLite enum CHECK.
            try database.execute(
                sql: "UPDATE sessions_evidence SET status_effect = 'unknown' WHERE occurrence_id = ?",
                arguments: [fixture.questionRecord.uuidString])
        }
        await #expect(throws: SessionsRepositoryError.self) {
            try await repository.statusContext(paneId: fixture.launchPane)
        }
    }

    @Test(
        "SessionStart ends every pre-cut active binding for its session and old-pane prompts stay record-only after reload",
        arguments: DuplicateSessionStartPlacement.allCases)
    private func sessionStartEndsEveryPreCutSessionBinding(placement: DuplicateSessionStartPlacement) async throws {
        let scenario = try makeDuplicateSessionStartScenario(placement: placement)
        let fixture = scenario.fixture
        let repository = SessionsRepository(sqliteAccess: fixture.access)
        let destinationPane = scenario.destinationPane
        let oldPanes = scenario.oldPanes
        let expectedDisposition = scenario.expectedDisposition

        let preCutActivePanes = try await fixture.access.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT binding.pane_id
                    FROM sessions_pane_binding AS binding
                    JOIN sessions_conversation AS conversation ON conversation.id = binding.conversation_id
                    WHERE conversation.provider_identifier = 'claude-code'
                      AND conversation.provider_conversation_id = ?
                      AND binding.status = 'active'
                    ORDER BY binding.pane_id
                    """,
                arguments: [fixture.duplicateSessionId])
        }
        #expect(
            Set(preCutActivePanes) == Set([fixture.duplicatePaneOne.uuidString, fixture.duplicatePaneTwo.uuidString]))

        let delayedPromptRecordIds = try await withSessionsIngestion(repository: repository) { ingestion in
            for pane in [fixture.duplicatePaneOne, fixture.duplicatePaneTwo] {
                let status = try await ingestion.readSessionStatus(paneId: pane)
                if case .live = status {} else { Issue.record("Both duplicate pre-cut bindings must start live") }
            }

            let start = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: destinationPane, sessionId: fixture.duplicateSessionId,
                    eventName: .sessionStart, signal: .sessionStart, providerIdentifier: "claude-code"))
            #expect(start.disposition == expectedDisposition)
            #expect(Set(start.endedBindings.map(\.paneId)) == Set(oldPanes))

            let activePanes = try await fixture.access.read { database in
                try String.fetchAll(
                    database,
                    sql: """
                        SELECT binding.pane_id
                        FROM sessions_pane_binding AS binding
                        JOIN sessions_conversation AS conversation ON conversation.id = binding.conversation_id
                        WHERE conversation.provider_identifier = 'claude-code'
                          AND conversation.provider_conversation_id = ?
                          AND binding.status = 'active'
                        ORDER BY binding.pane_id
                        """,
                    arguments: [fixture.duplicateSessionId])
            }
            #expect(activePanes == [destinationPane.uuidString])

            for pane in oldPanes {
                let status = try await ingestion.readSessionStatus(paneId: pane)
                if case .ended = status {
                } else {
                    Issue.record("Every old pane must be ended before its delayed prompt")
                }
            }

            var recordIds: [UUID] = []
            let questions = [
                SessionQuestion(question: "Allow this?", header: "Permission", options: [], multiSelect: false)
            ]
            for pane in oldPanes {
                let prompt = makeHookAdmission(
                    paneId: pane, sessionId: fixture.duplicateSessionId,
                    eventName: .question,
                    signal: .question(toolCallId: "late-question-\(pane.uuidString)", questions: questions),
                    providerIdentifier: "claude-code", kind: .needsYouOpened)
                recordIds.append(prompt.recordId)
                let committedPrompt = try await ingestion.submitHook(prompt)
                #expect(committedPrompt.disposition == .recordedOnly)
                #expect(committedPrompt.evidence.statusEffect == .recordedOnly)
                #expect(committedPrompt.evidence.providerSignal?.name == .question)

                let summary = try await ingestion.sessionSummary(paneId: pane)
                #expect(summary?.status == .idle(.ended))
                #expect(summary?.providerPrompts.isEmpty == true)

                let destinationSummary = try await ingestion.sessionSummary(paneId: destinationPane)
                #expect(destinationSummary?.providerPrompts.isEmpty == true)
            }
            return recordIds
        }

        try await withSessionsIngestion(repository: repository) { restored in
            for pane in oldPanes {
                let summary = try await restored.sessionSummary(paneId: pane)
                #expect(summary?.status == .idle(.ended))
                #expect(summary?.providerPrompts.isEmpty == true)
            }
            let destinationSummary = try await restored.sessionSummary(paneId: destinationPane)
            #expect(destinationSummary?.providerPrompts.isEmpty == true)

            let destinationContext = try await repository.statusContext(paneId: destinationPane)
            let delayedPrompts = destinationContext.evidence.filter { delayedPromptRecordIds.contains($0.recordId) }
            #expect(delayedPrompts.count == delayedPromptRecordIds.count)
            #expect(delayedPrompts.allSatisfy { $0.statusEffect == .recordedOnly })
            #expect(delayedPrompts.allSatisfy { $0.providerSignal?.name == .question })
        }
    }
}

private struct DuplicateSessionStartScenario: Sendable {
    let fixture: SessionsCleanupUpgradeFixture
    let destinationPane: UUID
    let oldPanes: [UUID]
    let expectedDisposition: SessionsHookDisposition
}

private func makeDuplicateSessionStartScenario(placement: DuplicateSessionStartPlacement) throws
    -> DuplicateSessionStartScenario
{
    let fixture = try SessionsCleanupUpgradeFixture()
    try WorkspaceLocalMigrations.migrate(fixture.queue)
    switch placement {
    case .ownActivePane:
        return .init(
            fixture: fixture, destinationPane: fixture.duplicatePaneOne,
            oldPanes: [fixture.duplicatePaneTwo], expectedDisposition: .applied)
    case .newThirdPane:
        return .init(
            fixture: fixture, destinationPane: UUIDv7.generate(),
            oldPanes: [fixture.duplicatePaneOne, fixture.duplicatePaneTwo], expectedDisposition: .bound)
    }
}

private enum DuplicateSessionStartPlacement: CaseIterable, Equatable, Sendable {
    case ownActivePane
    case newThirdPane
}

private struct SessionsCleanupUpgradeFixture: Sendable {
    let queue: DatabaseQueue
    let access: TestSessionsSQLiteAccess
    let launchPane = UUIDv7.generate()
    let endedPane = UUIDv7.generate()
    let replacedPane = UUIDv7.generate()
    let launchBinding = UUIDv7.generate()
    let oldBinding = UUIDv7.generate()
    let newBinding = UUIDv7.generate()
    let duplicatePaneOne = UUIDv7.generate()
    let duplicatePaneTwo = UUIDv7.generate()
    let duplicateBindingOne = UUIDv7.generate()
    let duplicateBindingTwo = UUIDv7.generate()
    let duplicateConversation = UUIDv7.generate()
    let duplicateSessionId = "pre-cut-shared-session"
    let questionRecord = UUIDv7.generate()
    let questions = [
        SessionQuestion(
            question: "Choose 漢字😀?", header: "Choice",
            options: [.init(label: "One", description: "Retained option")], multiSelect: true)
    ]

    let retainedColumns = [
        "occurrence_id", "conversation_id", "binding_generation_id", "source_id", "source_generation_id",
        "turn_id", "subject_kind", "subject_identifier", "evidence_kind", "origin", "status_effect", "occurred_at",
        "committed_revision", "admission_sequence", "provider_event", "tool_name", "tool_call_id",
        "failure_summary", "elicitation_id", "prompt_summary", "has_questions",
    ]

    init() throws {
        queue = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "AgentStudio.sqlite.sessions-pre-cut-upgrade")
        access = TestSessionsSQLiteAccess(databaseQueue: queue)
        try WorkspaceLocalMigrations.migrator.migrate(queue, upTo: "026_sessions_permission_handling")
        try queue.write { database in
            for (revision, kind) in [
                (9, "evidence"), (10, "prepareForLaunch"), (11, "evidence"),
                (12, "evidence"), (20, "sourceEnded"), (30, "prepareForLaunch"), (31, "bind"),
                (40, "bind"), (41, "bind"),
            ] {
                try database.execute(
                    sql: """
                        INSERT INTO sessions_operation(commit_revision, operation_scope, correlation_id,
                            operation_kind, semantic_fingerprint, outcome_kind, created_at)
                        VALUES (?, 'upgrade-fixture', ?, ?, '', 'fixture', 100)
                        """, arguments: [revision, UUIDv7.generate().uuidString, kind])
            }
            try seedBinding(database, pane: launchPane, binding: launchBinding, revision: 10, ended: true)
            try seedBinding(database, pane: endedPane, binding: UUIDv7.generate(), revision: 20, ended: true)
            try seedBinding(database, pane: replacedPane, binding: oldBinding, revision: 30, ended: true)
            try seedBinding(database, pane: replacedPane, binding: newBinding, revision: 31, ended: false)
            try seedBinding(
                database, pane: duplicatePaneOne, binding: duplicateBindingOne, revision: 40, ended: false,
                conversationId: duplicateConversation, providerIdentifier: "claude-code",
                providerConversationId: duplicateSessionId)
            try seedBinding(
                database, pane: duplicatePaneTwo, binding: duplicateBindingTwo, revision: 41, ended: false,
                conversationId: duplicateConversation, providerIdentifier: "claude-code",
                providerConversationId: duplicateSessionId, insertConversation: false)
            let attention = UUIDv7.generate().uuidString
            try database.execute(
                sql: """
                    INSERT INTO sessions_attention(id, conversation_id, binding_generation_id, source_id, source_generation_id,
                        source_kind, turn_id, subject_key, request_id, attention_kind, origin, freshness,
                        explanation_text, disposition, opened_occurrence_id, opened_at, committed_revision)
                    VALUES (?, ?, ?, ?, ?, 'provider', 'A', 'tool:question-call', 'request-q', 'question', 'reported', 'live',
                        'Retired audit text', 'current', ?, 99.5, 9)
                    """,
                arguments: [
                    attention, launchBinding.uuidString, launchBinding.uuidString, launchBinding.uuidString,
                    launchBinding.uuidString, questionRecord.uuidString,
                ])
            for (record, freshness, event, revision) in [
                (questionRecord, "live", "question", 9),
                (UUIDv7.generate(), "historical", "permission", 11),
                (UUIDv7.generate(), "late", "turnFailed", 12),
            ] {
                try database.execute(
                    sql: """
                        INSERT INTO sessions_evidence(occurrence_id, conversation_id, binding_generation_id, source_id,
                            source_generation_id, turn_id, subject_kind, subject_identifier, evidence_kind, attention_id,
                            origin, freshness, occurred_at, committed_revision, admission_sequence, source_occurred_at,
                            provider_event, tool_name, tool_call_id, failure_summary, elicitation_id, prompt_summary,
                            has_questions, permission_handling)
                        VALUES (?, ?, ?, ?, ?, 'A', 'tool', 'question-call', 'needsYouOpened', ?, 'reported', ?, 99.5, ?, ?, 98.5,
                            ?, 'AskUserQuestion', 'question-call', 'historical failure', 'elicitation-label', 'Retained summary', ?, 'reportOnly')
                        """,
                    arguments: [
                        record.uuidString, launchBinding.uuidString, launchBinding.uuidString,
                        launchBinding.uuidString, launchBinding.uuidString, attention,
                        freshness, revision, revision, event, event == "question" ? 1 : 0,
                    ])
            }
            try database.execute(
                sql: """
                    INSERT INTO sessions_provider_question VALUES (?, 0, 'Choose 漢字😀?', 'Choice', 1)
                    """, arguments: [questionRecord.uuidString])
            try database.execute(
                sql: """
                    INSERT INTO sessions_provider_question_option VALUES (?, 0, 0, 'One', 'Retained option')
                    """, arguments: [questionRecord.uuidString])
            try database.execute(
                sql: """
                    INSERT INTO sessions_message(occurrence_id, pane_id, conversation_id, binding_generation_id,
                        notification_kind, exact_text, attribution, freshness, attention_id, reported_at, committed_revision)
                    VALUES (?, ?, ?, ?, 'message', 'Legacy message', 'attributed', 'live', ?, 99.5, 9)
                    """,
                arguments: [
                    UUIDv7.generate().uuidString, launchPane.uuidString, launchBinding.uuidString,
                    launchBinding.uuidString, attention,
                ])
            try database.execute(
                sql: """
                    INSERT INTO sessions_result(id, conversation_id, binding_generation_id, source_generation_id,
                        turn_id, subject_key, completion_occurrence_id, origin, freshness, created_at, updated_at, committed_revision)
                    VALUES (?, ?, ?, ?, 'A', 'root', ?, 'reported', 'live', 99.5, 99.5, 9)
                    """,
                arguments: [
                    UUIDv7.generate().uuidString, launchBinding.uuidString, launchBinding.uuidString,
                    launchBinding.uuidString, questionRecord.uuidString,
                ])
            try database.execute(
                sql: """
                    INSERT INTO sessions_loss(id, pane_id, event_kind, outcome_kind, reason_code, lost_count, occurred_at, committed_revision)
                    VALUES (?, ?, 'toolActivity', 'throttled', 'paneQueueFull', 1, 99.5, 9)
                    """, arguments: [UUIDv7.generate().uuidString, launchPane.uuidString])
            #expect(try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func retainedProjection(beforeMigration: Bool) -> String {
        let columns = retainedColumns.map {
            $0 == "status_effect" && beforeMigration
                ? "CASE freshness WHEN 'live' THEN 'applied' ELSE 'recordedOnly' END AS status_effect" : $0
        }.joined(separator: ", ")
        return "SELECT \(columns) FROM sessions_evidence ORDER BY occurrence_id"
    }

    func seedBinding(
        _ database: Database,
        pane: UUID,
        binding: UUID,
        revision: Int,
        ended: Bool,
        conversationId: UUID? = nil,
        providerIdentifier: String = "claude-code",
        providerConversationId: String? = nil,
        insertConversation: Bool = true
    ) throws {
        let conversationId = conversationId ?? binding
        if insertConversation {
            try database.execute(
                sql: """
                    INSERT INTO sessions_conversation VALUES (?, ?, ?, 1, 99.5)
                    """,
                arguments: [
                    conversationId.uuidString, providerIdentifier,
                    providerConversationId ?? "session-\(binding.uuidString)",
                ])
        }
        try database.execute(
            sql: """
                INSERT INTO sessions_pane_binding(binding_generation_id, pane_id, conversation_id, source_generation_id,
                    origin, status, transition_occurrence_id, started_at, ended_at, committed_revision, resume_hint, owner_pane_id)
                VALUES (?, ?, ?, ?, 'reported', ?, ?, 1, ?, ?, 'claude --resume retained', NULL)
                """,
            arguments: [
                binding.uuidString, pane.uuidString, conversationId.uuidString, binding.uuidString,
                ended ? "ended" : "active", UUIDv7.generate().uuidString, ended ? 100.0 : nil, revision,
            ])
        try database.execute(
            sql: """
                INSERT INTO sessions_source(id, binding_generation_id, source_identifier, source_generation_id,
                    provider_identifier, provider_version, provider_mode, qualification, status, last_cursor,
                    started_at, ended_at, committed_revision)
                VALUES (?, ?, ?, ?, ?, '2.1.289', 'interactive', 'qualified', ?, 'retained-cursor', 1, ?, ?)
                """,
            arguments: [
                binding.uuidString, binding.uuidString, "source-\(binding.uuidString)", binding.uuidString,
                providerIdentifier,
                ended ? "ended" : "active", ended ? 100.0 : nil, revision,
            ])
    }
}
