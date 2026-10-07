import Foundation

package enum IPCPaneMessageImportance: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case info
    case attention
    case done
    case failure
}

package enum IPCPaneAskReason: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case approval
    case question
    case blocked
}

package struct IPCPaneWriterClaim: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let provider: String
    package let conversationId: String

    package init(provider: String, conversationId: String) {
        self.provider = provider
        self.conversationId = conversationId
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "provider", description: "provider", schema: .string()),
            .init(name: "conversationId", description: "conversationId", schema: .string()),
        ])
    }
}
package struct IPCPaneAskChoice: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let id: String
    package let label: String

    package init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "id", description: "id", schema: .string()),
            .init(name: "label", description: "label", schema: .string()),
        ])
    }
}
package struct IPCPanePullRequestIdentity: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let host: String
    package let owner: String
    package let repository: String
    package let number: Int

    package init(host: String, owner: String, repository: String, number: Int) {
        self.host = host
        self.owner = owner
        self.repository = repository
        self.number = number
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "host", description: "host", schema: .string()),
            .init(name: "owner", description: "owner", schema: .string()),
            .init(name: "repository", description: "repository", schema: .string()),
            .init(name: "number", description: "number", schema: IPCSchemaScalars.signedInteger),
        ])
    }
}
package enum IPCPaneMessageAction: Codable, Equatable, Sendable, IPCSchemaProviding {
    case openFile(path: String, line: Int?)
    case openPullRequest(identity: IPCPanePullRequestIdentity)
    case goToPane(paneId: UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case line
        case identity
        case paneId
    }
    private enum Kind: String, Codable {
        case openFile
        case openPullRequest
        case goToPane
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .openFile:
            self = .openFile(
                path: try container.decode(String.self, forKey: .path),
                line: try container.decodeIfPresent(Int.self, forKey: .line))
        case .openPullRequest:
            self = .openPullRequest(identity: try container.decode(IPCPanePullRequestIdentity.self, forKey: .identity))
        case .goToPane: self = .goToPane(paneId: try container.decode(UUID.self, forKey: .paneId))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openFile(let path, let line):
            try container.encode(Kind.openFile, forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(line, forKey: .line)
        case .openPullRequest(let identity):
            try container.encode(Kind.openPullRequest, forKey: .kind)
            try container.encode(identity, forKey: .identity)
        case .goToPane(let paneId):
            try container.encode(Kind.goToPane, forKey: .kind)
            try container.encode(paneId, forKey: .paneId)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "openFile", schema: .string(allowedValues: ["openFile"])),
                .init(name: "path", description: "path", schema: .string()),
                .optional("line", description: "line", schema: IPCSchemaScalars.signedInteger),
            ]),
            .object(fields: [
                .init(
                    name: "kind", description: "openPullRequest", schema: .string(allowedValues: ["openPullRequest"])),
                .init(name: "identity", description: "identity", schema: try IPCPanePullRequestIdentity.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "goToPane", schema: .string(allowedValues: ["goToPane"])),
                .init(name: "paneId", description: "paneId", schema: IPCSchemaScalars.uuid),
            ]),
        ])
    }
}
package enum IPCPaneAskWaiting: Codable, Equatable, Sendable, IPCSchemaProviding {
    case nonBlocking
    case blocking(deadline: Date)

    private enum CodingKeys: String, CodingKey {
        case kind
        case deadline
    }
    private enum Kind: String, Codable {
        case nonBlocking
        case blocking
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .nonBlocking: self = .nonBlocking
        case .blocking: self = .blocking(deadline: try container.decode(Date.self, forKey: .deadline))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nonBlocking:
            try container.encode(Kind.nonBlocking, forKey: .kind)
        case .blocking(let deadline):
            try container.encode(Kind.blocking, forKey: .kind)
            try container.encode(deadline, forKey: .deadline)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "nonBlocking", schema: .string(allowedValues: ["nonBlocking"]))
            ]),
            .object(fields: [
                .init(name: "kind", description: "blocking", schema: .string(allowedValues: ["blocking"])),
                .init(name: "deadline", description: "deadline", schema: .number()),
            ]),
        ])
    }
}
/// Spec R7: send admits only a non-blocking ask; R8 owns the blocking method.
package enum IPCPaneNonBlockingWaiting: Codable, Equatable, Sendable, IPCSchemaProviding {
    case nonBlocking

    private enum CodingKeys: String, CodingKey { case kind }
    private enum Kind: String, Codable { case nonBlocking }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(Kind.self, forKey: .kind)
        self = .nonBlocking
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Kind.nonBlocking, forKey: .kind)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "kind", description: "nonBlocking", schema: .string(allowedValues: ["nonBlocking"]))
        ])
    }
}

package enum IPCPaneBlockingWaiting: Codable, Equatable, Sendable, IPCSchemaProviding {
    case blocking(deadline: Date)

    private enum CodingKeys: String, CodingKey {
        case kind
        case deadline
    }
    private enum Kind: String, Codable {
        case blocking
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .blocking: self = .blocking(deadline: try container.decode(Date.self, forKey: .deadline))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .blocking(let deadline):
            try container.encode(Kind.blocking, forKey: .kind)
            try container.encode(deadline, forKey: .deadline)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "kind", description: "blocking", schema: .string(allowedValues: ["blocking"])),
            .init(name: "deadline", description: "deadline", schema: .number()),
        ])
    }
}
