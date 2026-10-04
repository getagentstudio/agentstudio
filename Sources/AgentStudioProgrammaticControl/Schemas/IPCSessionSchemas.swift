import Foundation

package enum IPCSessionSchemaLimits {
    /// One query page carries the newest messages only. Paging beyond this page
    /// belongs to the future Sessions reader, not to the model vocabulary.
    package static let maximumQueryMessageCount = 20
}

extension IPCSessionProviderIdentity: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "identifier", description: "Provider identifier such as the agent CLI name",
                schema: .string(minimumLength: 1)),
            .init(
                name: "version", description: "Exact provider version; a nearby version grants no authority",
                schema: .string(minimumLength: 1)),
            .init(
                name: "mode", description: "Provider operating mode qualified for this capability",
                schema: .string(minimumLength: 1)),
        ])
    }
}

extension IPCSessionEventIdentity: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "name", description: "Lifecycle capability this event claims",
                schema: try IPCSessionEventName.ipcSchema()),
            .init(
                name: "conversationId", description: "Provider conversation identity for the reporting source",
                schema: .string(minimumLength: 1)),
            .optional("turnId", description: "Provider turn identity when the event carries one", schema: .string()),
            .optional(
                "requestId", description: "Provider request identity for a permission, question or elicitation",
                schema: .string()),
            .optional("toolId", description: "Provider tool identity for tool activity", schema: .string()),
            .optional("subagentId", description: "Provider subagent identity for subagent activity", schema: .string()),
            .optional("toolName", description: "Recorded provider tool name", schema: .string()),
            .optional(
                "questions", description: "Recorded AskUserQuestion questions",
                schema: .array(items: try IPCSessionQuestion.ipcSchema())),
            .optional("failureSummary", description: "Provider turn failure category", schema: .string()),
            .optional("elicitationId", description: "Provider elicitation identity when present", schema: .string()),
            .optional("message", description: "Provider prompt summary", schema: .string()),
            .optional("sourceOccurredAt", description: "Source UTC time; never an ordering key", schema: .number()),
            .optional("resumeHint", description: "Provider resume command hint", schema: .string()),
            .init(
                name: "occurrenceId",
                description: "Provider occurrence UUID; equivalent reuse returns the retained outcome",
                schema: IPCSchemaScalars.uuid),
        ])
    }
}

extension IPCSessionQuestion: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "question", description: "Question text", schema: .string()),
            .init(name: "header", description: "Question header", schema: .string()),
            .init(
                name: "options", description: "Provider choices",
                schema: .array(
                    items: .object(fields: [
                        .init(name: "label", description: "Choice label", schema: .string()),
                        .init(name: "description", description: "Choice description", schema: .string()),
                    ]))),
            .init(name: "multiSelect", description: "Whether multiple choices may be selected", schema: .boolean),
        ])
    }
}

extension IPCSessionEventParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            try IPCRequestSchemaFields.paneDefaultingToSelf(),
            .init(
                name: "provider", description: "Exact provider identity claiming this capability",
                schema: try IPCSessionProviderIdentity.ipcSchema()),
            .init(
                name: "event", description: "Projected provider lifecycle event",
                schema: try IPCSessionEventIdentity.ipcSchema()),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

extension IPCSessionEventResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCSessionSchemaFields.pane,
            .init(
                name: "disposition", description: "Whether the exact provider capability was admitted",
                schema: try IPCSessionEventDisposition.ipcSchema()),
            IPCRequestSchemaFields.correlation,
        ])
    }
}

extension IPCSessionQueryParams: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [try IPCRequestSchemaFields.paneDefaultingToSelf()])
    }
}

extension IPCSessionAttentionProjection: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "requestId", description: "App-derived current attention request identity",
                schema: .string(minimumLength: 1)),
            .optional("explanation", description: "Private reason recorded with the assertion", schema: .string()),
        ])
    }
}

extension IPCSessionMessageProjection: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "occurrenceId", description: "Durable message occurrence UUID", schema: IPCSchemaScalars.uuid),
            .init(name: "text", description: "Exact retained message text", schema: .string()),
            .init(
                name: "seen", description: "Durable seen disposition; reads never change it", schema: .boolean),
            .init(
                name: "receivedAt",
                description: "Admission time in seconds since the Foundation reference date",
                schema: .number()),
        ])
    }
}

extension IPCSessionQueryResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCSessionSchemaFields.pane,
            try IPCSessionSchemaFields.state(),
            try IPCSessionSchemaFields.origin(),
            .optional(
                "needsYou", description: "Current deliberate or provider attention assertion when one is open",
                schema: try IPCSessionAttentionProjection.ipcSchema()),
            .init(
                name: "messages", description: "Newest retained messages for the pane",
                schema: .array(
                    items: try IPCSessionMessageProjection.ipcSchema(),
                    maximumCount: IPCSessionSchemaLimits.maximumQueryMessageCount)),
            .init(
                name: "sourceHealth", description: "Liveness of the pane's current binding and source generation",
                schema: try IPCSessionSourceHealth.ipcSchema()),
        ])
    }
}

enum IPCSessionSchemaFields {
    static let pane = IPCObjectField(
        name: "paneId", description: "Canonical pane UUID that owns the session state", schema: IPCSchemaScalars.uuid
    )

    static func state() throws -> IPCObjectField {
        .init(
            name: "state", description: "Reduced agent state for the pane's current conversation",
            schema: try IPCSessionAgentState.ipcSchema()
        )
    }

    static func origin() throws -> IPCObjectField {
        .init(
            name: "origin", description: "Server-assigned origin of the reported state",
            schema: try IPCSessionEvidenceOrigin.ipcSchema()
        )
    }
}
