import Foundation
import GRDB

extension SessionsRepositoryStorage {
    static func writeProviderQuestions(evidence: SessionsEvidenceRecord, database: Database) throws {
        guard let questions = evidence.providerSignal?.questions else { return }
        for (questionIndex, question) in questions.enumerated() {
            try database.execute(
                sql: """
                    INSERT INTO sessions_provider_question(occurrence_id, question_index, question, header, multi_select)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    evidence.occurrenceId.uuidString, questionIndex, question.question, question.header,
                    question.multiSelect ? 1 : 0,
                ])
            for (optionIndex, option) in question.options.enumerated() {
                try database.execute(
                    sql: """
                        INSERT INTO sessions_provider_question_option(occurrence_id, question_index, option_index, label, description)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        evidence.occurrenceId.uuidString, questionIndex, optionIndex, option.label, option.description,
                    ])
            }
        }
    }

    static func decodeProviderSignal(_ row: Row, database: Database) throws -> SessionProviderSignal? {
        let rawHandling: String? = row["permission_handling"]
        let handling: SessionPermissionHandling
        if let rawHandling {
            guard let storedHandling = SessionPermissionHandling(rawValue: rawHandling) else {
                throw SessionsRepositoryError.invalidStoredValue("permission_handling")
            }
            handling = storedHandling
        } else {
            handling = .reportOnly
        }
        guard let eventName: String = row["provider_event"] else { return nil }
        guard let name = SessionProviderSignalName(rawValue: eventName) else {
            throw SessionsRepositoryError.invalidStoredValue("provider_event")
        }
        let toolName: String? = row["tool_name"]
        let toolCallId: String? = row["tool_call_id"]
        let failureSummary: String? = row["failure_summary"]
        let elicitationId: String? = row["elicitation_id"]
        let summary: String? = row["prompt_summary"]
        var questions: [SessionQuestion]?
        let hasQuestions: Int = row["has_questions"]
        if hasQuestions != 0 {
            let occurrenceId: String = row["occurrence_id"]
            questions = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM sessions_provider_question WHERE occurrence_id = ? ORDER BY question_index
                    """, arguments: [occurrenceId]
            ).map { questionRow in
                let questionIndex: Int = questionRow["question_index"]
                let multiSelect: Int = questionRow["multi_select"]
                let options = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT label, description FROM sessions_provider_question_option
                        WHERE occurrence_id = ? AND question_index = ? ORDER BY option_index
                        """, arguments: [occurrenceId, questionIndex]
                ).map { optionRow in
                    SessionQuestionOption(label: optionRow["label"], description: optionRow["description"])
                }
                return SessionQuestion(
                    question: questionRow["question"], header: questionRow["header"], options: options,
                    multiSelect: multiSelect != 0)
            }
        }
        switch name {
        case .turnStart: return .turnStart
        case .turnDone: return .turnDone
        case .turnAbort: return .turnAbort
        case .turnFailed:
            guard let category = failureSummary else {
                throw SessionsRepositoryError.invalidStoredValue("failure_summary")
            }
            return .turnFailed(category: category)
        case .toolActivity: return .toolActivity(toolName: toolName)
        case .subagentActivity: return .subagentActivity
        case .permission: return .permission(toolName: toolName, questions: questions, handling: handling)
        case .question:
            guard let identifier = toolCallId, let questions else {
                throw SessionsRepositoryError.invalidStoredValue("question")
            }
            return .question(toolCallId: identifier, questions: questions)
        case .toolCompleted:
            guard let identifier = toolCallId else { throw SessionsRepositoryError.invalidStoredValue("tool_call_id") }
            return .toolCompleted(toolCallId: identifier)
        case .toolFailed:
            guard let identifier = toolCallId else { throw SessionsRepositoryError.invalidStoredValue("tool_call_id") }
            return .toolFailed(toolCallId: identifier)
        case .elicitation: return .elicitation(id: elicitationId, summary: summary)
        case .elicitationResult: return .elicitationResult(id: elicitationId)
        }
    }
}
