import Foundation

package struct IPCPaneClaim: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let paneId: UUID
    package let workspaceId: UUID

    package init(paneId: UUID, workspaceId: UUID) {
        self.paneId = paneId
        self.workspaceId = workspaceId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "paneId", description: "Exact reporting pane", schema: IPCSchemaScalars.uuid),
            .init(name: "workspaceId", description: "Claimed workspace", schema: IPCSchemaScalars.uuid),
        ])
    }
}

package enum IPCAgentConnectionRefusalReason: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case credentialNotRecognized, paneNotFound, paneRetired, otherWorkspace, intentRequiresToken
    case noSessionId, undecodablePayload, queueFull, appUnavailable, deadlineExceeded, orderingStoreUnavailable
}

package enum IPCSessionTokenOutcome: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case rejected, absent
}

package enum IPCSessionStatusReport: Codable, Equatable, Sendable, IPCSchemaProviding {
    case hook(event: IPCSessionEventIdentity, provider: IPCSessionProviderIdentity, providerSessionId: String)
    case refusal(reason: IPCAgentConnectionRefusalReason)

    private enum CodingKeys: String, CodingKey { case kind, event, provider, providerSessionId, reason }
    private enum Kind: String, Codable { case hook, refusal }

    package init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        switch try fields.decode(Kind.self, forKey: .kind) {
        case .hook:
            self = .hook(
                event: try fields.decode(IPCSessionEventIdentity.self, forKey: .event),
                provider: try fields.decode(IPCSessionProviderIdentity.self, forKey: .provider),
                providerSessionId: try fields.decode(String.self, forKey: .providerSessionId))
        case .refusal:
            self = .refusal(reason: try fields.decode(IPCAgentConnectionRefusalReason.self, forKey: .reason))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hook(let event, let provider, let providerSessionId):
            try fields.encode(Kind.hook, forKey: .kind)
            try fields.encode(event, forKey: .event)
            try fields.encode(provider, forKey: .provider)
            try fields.encode(providerSessionId, forKey: .providerSessionId)
        case .refusal(let reason):
            try fields.encode(Kind.refusal, forKey: .kind)
            try fields.encode(reason, forKey: .reason)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "Status hook", schema: .string(allowedValues: ["hook"])),
                .init(name: "event", description: "Status transition", schema: try IPCSessionEventIdentity.ipcSchema()),
                .init(name: "provider", description: "Provider", schema: try IPCSessionProviderIdentity.ipcSchema()),
                .init(
                    name: "providerSessionId", description: "Unverified main candidate",
                    schema: .string(minimumLength: 1)),
            ]),
            .object(fields: [
                .init(name: "kind", description: "Refusal report", schema: .string(allowedValues: ["refusal"])),
                .init(
                    name: "reason", description: "Closed refusal reason",
                    schema: try IPCAgentConnectionRefusalReason.ipcSchema()),
            ]),
        ])
    }
}

package struct IPCSessionStatusParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let paneClaim: IPCPaneClaim
    package let tokenOutcome: IPCSessionTokenOutcome
    package let report: IPCSessionStatusReport
    package let correlationId: UUID

    package init(
        paneClaim: IPCPaneClaim, tokenOutcome: IPCSessionTokenOutcome, report: IPCSessionStatusReport,
        correlationId: UUID
    ) {
        self.paneClaim = paneClaim
        self.tokenOutcome = tokenOutcome
        self.report = report
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "paneClaim", description: "Exact pane membership", schema: try IPCPaneClaim.ipcSchema()),
            .init(
                name: "tokenOutcome", description: "Why identity admission was unavailable",
                schema: try IPCSessionTokenOutcome.ipcSchema()),
            .init(
                name: "report", description: "Status or refusal without identity effects",
                schema: try IPCSessionStatusReport.ipcSchema()),
            IPCRequestSchemaFields.correlation,
        ])
    }
}
