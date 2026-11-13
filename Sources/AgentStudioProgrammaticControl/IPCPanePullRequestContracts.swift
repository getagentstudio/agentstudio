import Foundation

package struct IPCPanePullRequestMutationParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let targetPaneHandle: String
    package let pullRequest: IPCPanePullRequestIdentity
    package let writer: IPCPaneWriterClaim?
    package let correlationId: UUID

    package init(
        targetPaneHandle: String, pullRequest: IPCPanePullRequestIdentity, writer: IPCPaneWriterClaim? = nil,
        correlationId: UUID
    ) {
        self.targetPaneHandle = targetPaneHandle
        self.pullRequest = pullRequest
        self.writer = writer
        self.correlationId = correlationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "targetPaneHandle", description: "Main pane receiving the PR", schema: .string()),
            .init(
                name: "pullRequest", description: "GitHub PR identity",
                schema: try IPCPanePullRequestIdentity.ipcSchema()),
            .optional(
                "writer", description: "Conversation claim checked against the credential source pane",
                schema: try IPCPaneWriterClaim.ipcSchema()),
            .init(name: "correlationId", description: "Call correlation", schema: IPCSchemaScalars.uuid),
        ])
    }
}

package struct IPCPanePullRequestListParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let targetPaneHandle: String
    package init(targetPaneHandle: String) { self.targetPaneHandle = targetPaneHandle }
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "targetPaneHandle", description: "Main pane whose PRs are read", schema: .string())
        ])
    }
}

package enum IPCPanePullRequestAddResult: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case added
    case alreadyPresent
    case paneFull
}

package enum IPCPanePullRequestRemoveResult: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case removed
    case notOnPane
    case addedBySomeoneElse
}

package enum IPCPanePullRequestState: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case open
    case draft
    case merged
    case closed
}

package struct IPCPanePullRequestListRow: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let identity: IPCPanePullRequestIdentity
    package let isWorktree: Bool
    package let authors: [IPCPanePullRequestAuthor]
    package let state: IPCPanePullRequestState?

    package init(
        identity: IPCPanePullRequestIdentity, isWorktree: Bool, authors: [IPCPanePullRequestAuthor],
        state: IPCPanePullRequestState?
    ) {
        self.identity = identity
        self.isWorktree = isWorktree
        self.authors = authors
        self.state = state
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "identity", description: "GitHub PR", schema: try IPCPanePullRequestIdentity.ipcSchema()),
            .init(name: "isWorktree", description: "The worktree is a source", schema: .boolean),
            .init(
                name: "authors", description: "Explicit contributors",
                schema: .array(items: try IPCPanePullRequestAuthor.ipcSchema())),
            .optional("state", description: "Last known PR state", schema: try IPCPanePullRequestState.ipcSchema()),
        ])
    }
}

package struct IPCPanePullRequestListResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let rows: [IPCPanePullRequestListRow]
    package init(rows: [IPCPanePullRequestListRow]) { self.rows = rows }
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "rows", description: "PRs in popover order",
                schema: .array(items: try IPCPanePullRequestListRow.ipcSchema()))
        ])
    }
}
