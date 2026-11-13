import Foundation

package enum IPCPanePullRequestCheckStatus: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case passed, running, failed, unknown
}
package enum IPCPanePullRequestReviewStatus: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case approved, changesRequested, reviewRequired, unknown
}
package enum IPCPanePullRequestFailureReason: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case noAccess, notFound, rateLimited, offline, failed
}
package enum IPCPanePullRequestMergeability: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case mergeable, conflicting, unknown
}
package enum IPCPanePullRequestMergeState: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case clean, blocked, behind, dirty, draft, hasHooks, unstable, unknown
}

package struct IPCPanePullRequestLoadedDetails: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let title: String
    package let state: IPCPanePullRequestState
    package let checks: IPCPanePullRequestCheckStatus
    package let review: IPCPanePullRequestReviewStatus
    package let mergeability: IPCPanePullRequestMergeability
    package let mergeState: IPCPanePullRequestMergeState
    package let updatedAt: Date
    package let lastGoodReadAt: Date
    package let url: String
    package let refreshFailure: IPCPanePullRequestFailureReason?

    package init(
        title: String, state: IPCPanePullRequestState, checks: IPCPanePullRequestCheckStatus,
        review: IPCPanePullRequestReviewStatus, mergeability: IPCPanePullRequestMergeability,
        mergeState: IPCPanePullRequestMergeState, updatedAt: Date, lastGoodReadAt: Date, url: String,
        refreshFailure: IPCPanePullRequestFailureReason?
    ) {
        self.title = title
        self.state = state
        self.checks = checks
        self.review = review
        self.mergeability = mergeability
        self.mergeState = mergeState
        self.updatedAt = updatedAt
        self.lastGoodReadAt = lastGoodReadAt
        self.url = url
        self.refreshFailure = refreshFailure
    }
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "title", description: "PR title", schema: .string()),
            .init(name: "state", description: "PR state", schema: try IPCPanePullRequestState.ipcSchema()),
            .init(name: "checks", description: "Checks", schema: try IPCPanePullRequestCheckStatus.ipcSchema()),
            .init(name: "review", description: "Review", schema: try IPCPanePullRequestReviewStatus.ipcSchema()),
            .init(
                name: "mergeability", description: "Mergeability",
                schema: try IPCPanePullRequestMergeability.ipcSchema()),
            .init(name: "mergeState", description: "Merge state", schema: try IPCPanePullRequestMergeState.ipcSchema()),
            .init(name: "updatedAt", description: "GitHub update time", schema: IPCSchemaScalars.unixTimestamp),
            .init(name: "lastGoodReadAt", description: "Last good read", schema: IPCSchemaScalars.unixTimestamp),
            .init(name: "url", description: "PR URL", schema: .string()),
            .optional(
                "refreshFailure", description: "Last refresh failure",
                schema: try IPCPanePullRequestFailureReason.ipcSchema()),
        ])
    }
}

package enum IPCPanePullRequestDetailsValue: Codable, Equatable, Sendable, IPCSchemaProviding {
    case loading
    case loaded(IPCPanePullRequestLoadedDetails)
    case unavailable(IPCPanePullRequestFailureReason)

    private enum CodingKeys: String, CodingKey { case kind, value, reason }
    private enum Kind: String, Codable { case loading, loaded, unavailable }
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .loading: self = .loading
        case .loaded: self = .loaded(try container.decode(IPCPanePullRequestLoadedDetails.self, forKey: .value))
        case .unavailable:
            self = .unavailable(try container.decode(IPCPanePullRequestFailureReason.self, forKey: .reason))
        }
    }
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .loading: try container.encode(Kind.loading, forKey: .kind)
        case .loaded(let value):
            try container.encode(Kind.loaded, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .unavailable(let reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [.init(name: "kind", description: "Loading", schema: .string(allowedValues: ["loading"]))]),
            .object(fields: [
                .init(name: "kind", description: "Loaded", schema: .string(allowedValues: ["loaded"])),
                .init(
                    name: "value", description: "Last good details",
                    schema: try IPCPanePullRequestLoadedDetails.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "Unavailable", schema: .string(allowedValues: ["unavailable"])),
                .init(name: "reason", description: "Reason", schema: try IPCPanePullRequestFailureReason.ipcSchema()),
            ]),
        ])
    }
}

package struct IPCPanePullRequestPresentationRow: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let identity: IPCPanePullRequestIdentity
    package let isWorktree: Bool
    package let authors: [IPCPanePullRequestAuthor]
    package let createdAt: Date?
    package let details: IPCPanePullRequestDetailsValue
    package init(
        identity: IPCPanePullRequestIdentity, isWorktree: Bool, authors: [IPCPanePullRequestAuthor],
        createdAt: Date?, details: IPCPanePullRequestDetailsValue
    ) {
        self.identity = identity
        self.isWorktree = isWorktree
        self.authors = authors
        self.createdAt = createdAt
        self.details = details
    }
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "identity", description: "GitHub PR", schema: try IPCPanePullRequestIdentity.ipcSchema()),
            .init(name: "isWorktree", description: "Worktree source", schema: .boolean),
            .init(
                name: "authors", description: "Explicit sources",
                schema: .array(items: try IPCPanePullRequestAuthor.ipcSchema())),
            .optional("createdAt", description: "Added time", schema: IPCSchemaScalars.unixTimestamp),
            .init(name: "details", description: "Details", schema: try IPCPanePullRequestDetailsValue.ipcSchema()),
        ])
    }
}

package struct IPCPanePullRequestPresentationList: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let rows: [IPCPanePullRequestPresentationRow]
    package let worstChecks: IPCPanePullRequestCheckStatus?
    package init(rows: [IPCPanePullRequestPresentationRow] = [], worstChecks: IPCPanePullRequestCheckStatus? = nil) {
        self.rows = rows
        self.worstChecks = worstChecks
    }
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "rows", description: "PR list in display order",
                schema: .array(items: try IPCPanePullRequestPresentationRow.ipcSchema())),
            .optional(
                "worstChecks", description: "Most urgent checks", schema: try IPCPanePullRequestCheckStatus.ipcSchema()),
        ])
    }
}
