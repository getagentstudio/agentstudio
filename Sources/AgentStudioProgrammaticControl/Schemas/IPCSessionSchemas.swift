import Foundation

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
            .optional(
                "sourceOccurredAt", description: "Hook source UTC time; admission order resolves ties or missing time",
                schema: .number()),
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
            .optional(
                "permissionHandling",
                description:
                    "Permission events only: reportOnly opens a provider prompt (the default); blockingAsk leaves attention to the ask",
                schema: try IPCSessionPermissionHandling.ipcSchema()),
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

enum IPCSessionSchemaFields {
    static let pane = IPCObjectField(
        name: "paneId", description: "Canonical pane UUID that owns the session state", schema: IPCSchemaScalars.uuid
    )

}

extension IPCSessionQueryResult: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            IPCSessionSchemaFields.pane,
            .init(
                name: "sourceHealth", description: "Health of the current status binding",
                schema: try IPCSessionSourceHealth.ipcSchema()),
            .init(
                name: "session",
                description: "The same status-engine summary as pane.context.get; null exactly when unbound",
                schema: .oneOf([.null, try IPCPaneSessionSummary.ipcSchema()])),
        ])
    }
}
