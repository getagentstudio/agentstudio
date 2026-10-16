import Foundation

package enum IPCPanePullRequestCheckStatus: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case passed
    case running
    case failed
    case unknown
}

package enum IPCPanePullRequestReviewStatus: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case approved
    case changesRequested
    case reviewRequired
    case unknown
}

package enum IPCPanePullRequestSummaryState: Codable, Equatable, Sendable, IPCSchemaProviding {
    case needsAttention(count: Int)
    case running
    case allGood
    case noInfo

    private enum CodingKeys: String, CodingKey {
        case kind
        case count
    }
    private enum Kind: String, Codable {
        case needsAttention
        case running
        case allGood
        case noInfo
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .needsAttention: self = .needsAttention(count: try container.decode(Int.self, forKey: .count))
        case .running: self = .running
        case .allGood: self = .allGood
        case .noInfo: self = .noInfo
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .needsAttention(let count):
            try container.encode(Kind.needsAttention, forKey: .kind)
            try container.encode(count, forKey: .count)
        case .running:
            try container.encode(Kind.running, forKey: .kind)
        case .allGood:
            try container.encode(Kind.allGood, forKey: .kind)
        case .noInfo:
            try container.encode(Kind.noInfo, forKey: .kind)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "needsAttention", schema: .string(allowedValues: ["needsAttention"])),
                .init(name: "count", description: "count", schema: IPCSchemaScalars.signedInteger),
            ]),
            .object(fields: [
                .init(name: "kind", description: "running", schema: .string(allowedValues: ["running"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "allGood", schema: .string(allowedValues: ["allGood"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "noInfo", schema: .string(allowedValues: ["noInfo"]))

            ]),
        ])
    }
}

package enum IPCPanePullRequestMemberRow: Codable, Equatable, Sendable, IPCSchemaProviding {
    case noPullRequest(worktreeId: UUID)
    case unknown(worktreeId: UUID)
    case pullRequest(
        worktreeId: UUID, number: Int, checks: IPCPanePullRequestCheckStatus, review: IPCPanePullRequestReviewStatus)

    private enum CodingKeys: String, CodingKey {
        case kind
        case worktreeId
        case number
        case checks
        case review
    }
    private enum Kind: String, Codable {
        case noPullRequest
        case unknown
        case pullRequest
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .noPullRequest: self = .noPullRequest(worktreeId: try container.decode(UUID.self, forKey: .worktreeId))
        case .unknown: self = .unknown(worktreeId: try container.decode(UUID.self, forKey: .worktreeId))
        case .pullRequest:
            self = .pullRequest(
                worktreeId: try container.decode(UUID.self, forKey: .worktreeId),
                number: try container.decode(Int.self, forKey: .number),
                checks: try container.decode(IPCPanePullRequestCheckStatus.self, forKey: .checks),
                review: try container.decode(IPCPanePullRequestReviewStatus.self, forKey: .review))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noPullRequest(let worktreeId):
            try container.encode(Kind.noPullRequest, forKey: .kind)
            try container.encode(worktreeId, forKey: .worktreeId)
        case .unknown(let worktreeId):
            try container.encode(Kind.unknown, forKey: .kind)
            try container.encode(worktreeId, forKey: .worktreeId)
        case .pullRequest(let worktreeId, let number, let checks, let review):
            try container.encode(Kind.pullRequest, forKey: .kind)
            try container.encode(worktreeId, forKey: .worktreeId)
            try container.encode(number, forKey: .number)
            try container.encode(checks, forKey: .checks)
            try container.encode(review, forKey: .review)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "noPullRequest", schema: .string(allowedValues: ["noPullRequest"])),
                .init(name: "worktreeId", description: "worktreeId", schema: IPCSchemaScalars.uuid),
            ]),
            .object(fields: [
                .init(name: "kind", description: "unknown", schema: .string(allowedValues: ["unknown"])),
                .init(name: "worktreeId", description: "worktreeId", schema: IPCSchemaScalars.uuid),
            ]),
            .object(fields: [
                .init(name: "kind", description: "pullRequest", schema: .string(allowedValues: ["pullRequest"])),
                .init(name: "worktreeId", description: "worktreeId", schema: IPCSchemaScalars.uuid),
                .init(name: "number", description: "number", schema: IPCSchemaScalars.signedInteger),
                .init(name: "checks", description: "checks", schema: try IPCPanePullRequestCheckStatus.ipcSchema()),
                .init(name: "review", description: "review", schema: try IPCPanePullRequestReviewStatus.ipcSchema()),
            ]),
        ])
    }
}

package struct IPCPanePullRequestSummary: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let state: IPCPanePullRequestSummaryState
    package let members: [IPCPanePullRequestMemberRow]

    package init(state: IPCPanePullRequestSummaryState, members: [IPCPanePullRequestMemberRow]) {
        self.state = state
        self.members = members
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "state", description: "state", schema: try IPCPanePullRequestSummaryState.ipcSchema()),
            .init(
                name: "members", description: "members",
                schema: .array(items: try IPCPanePullRequestMemberRow.ipcSchema())),
        ])
    }
}

package enum IPCPanePullRequestSummaryDetail: Codable, Equatable, Sendable, IPCSchemaProviding {
    case notApplicable
    case summary(value: IPCPanePullRequestSummary)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }
    private enum Kind: String, Codable {
        case notApplicable
        case summary
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .notApplicable: self = .notApplicable
        case .summary: self = .summary(value: try container.decode(IPCPanePullRequestSummary.self, forKey: .value))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notApplicable:
            try container.encode(Kind.notApplicable, forKey: .kind)
        case .summary(let value):
            try container.encode(Kind.summary, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "notApplicable", schema: .string(allowedValues: ["notApplicable"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "summary", schema: .string(allowedValues: ["summary"])),
                .init(name: "value", description: "value", schema: try IPCPanePullRequestSummary.ipcSchema()),
            ]),
        ])
    }
}
