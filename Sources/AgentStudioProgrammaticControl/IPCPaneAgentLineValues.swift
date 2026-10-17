import Foundation

package struct IPCPaneAgentLineInput: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let summary: String
    package let work: IPCPaneAgentLineWork
    package let detail: String?
    package let refs: [IPCPaneMessageAction]
    package let lifetime: IPCPaneAgentLineLifetime

    package init(
        summary: String, work: IPCPaneAgentLineWork, detail: String? = nil, refs: [IPCPaneMessageAction],
        lifetime: IPCPaneAgentLineLifetime
    ) {
        self.summary = summary
        self.work = work
        self.detail = detail
        self.refs = refs
        self.lifetime = lifetime
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "summary", description: "summary", schema: .string()),
            .init(name: "work", description: "work", schema: try IPCPaneAgentLineWork.ipcSchema()),
            .optional("detail", description: "detail", schema: .string()),
            .init(name: "refs", description: "refs", schema: .array(items: try IPCPaneMessageAction.ipcSchema())),
            .init(name: "lifetime", description: "lifetime", schema: try IPCPaneAgentLineLifetime.ipcSchema()),
        ])
    }
}

package enum IPCPaneAgentLineWork: Codable, Equatable, Sendable, IPCSchemaProviding {
    case working(progress: IPCPaneAgentLineProgress)
    case monitoring(target: String)
    case blockedOnYou(action: String)
    case done
    case failed(summary: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case progress
        case target
        case action
        case summary
    }
    private enum Kind: String, Codable {
        case working
        case monitoring
        case blockedOnYou
        case done
        case failed
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .working: self = .working(progress: try container.decode(IPCPaneAgentLineProgress.self, forKey: .progress))
        case .monitoring: self = .monitoring(target: try container.decode(String.self, forKey: .target))
        case .blockedOnYou: self = .blockedOnYou(action: try container.decode(String.self, forKey: .action))
        case .done: self = .done
        case .failed: self = .failed(summary: try container.decode(String.self, forKey: .summary))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .working(let progress):
            try container.encode(Kind.working, forKey: .kind)
            try container.encode(progress, forKey: .progress)
        case .monitoring(let target):
            try container.encode(Kind.monitoring, forKey: .kind)
            try container.encode(target, forKey: .target)
        case .blockedOnYou(let action):
            try container.encode(Kind.blockedOnYou, forKey: .kind)
            try container.encode(action, forKey: .action)
        case .done:
            try container.encode(Kind.done, forKey: .kind)
        case .failed(let summary):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(summary, forKey: .summary)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "working", schema: .string(allowedValues: ["working"])),
                .init(name: "progress", description: "progress", schema: try IPCPaneAgentLineProgress.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "monitoring", schema: .string(allowedValues: ["monitoring"])),
                .init(name: "target", description: "target", schema: .string()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "blockedOnYou", schema: .string(allowedValues: ["blockedOnYou"])),
                .init(name: "action", description: "action", schema: .string()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "done", schema: .string(allowedValues: ["done"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "failed", schema: .string(allowedValues: ["failed"])),
                .init(name: "summary", description: "summary", schema: .string()),
            ]),
        ])
    }
}

package enum IPCPaneAgentLineProgress: Codable, Equatable, Sendable, IPCSchemaProviding {
    case indeterminate
    case step(current: Int, total: Int)

    private enum CodingKeys: String, CodingKey {
        case kind
        case current
        case total
    }
    private enum Kind: String, Codable {
        case indeterminate
        case step
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .indeterminate: self = .indeterminate
        case .step:
            self = .step(
                current: try container.decode(Int.self, forKey: .current),
                total: try container.decode(Int.self, forKey: .total))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .indeterminate:
            try container.encode(Kind.indeterminate, forKey: .kind)
        case .step(let current, let total):
            try container.encode(Kind.step, forKey: .kind)
            try container.encode(current, forKey: .current)
            try container.encode(total, forKey: .total)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "indeterminate", schema: .string(allowedValues: ["indeterminate"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "step", schema: .string(allowedValues: ["step"])),
                .init(name: "current", description: "current", schema: IPCSchemaScalars.signedInteger),
                .init(name: "total", description: "total", schema: IPCSchemaScalars.signedInteger),
            ]),
        ])
    }
}

package enum IPCPaneAgentLineLifetime: Codable, Equatable, Sendable, IPCSchemaProviding {
    case untilReplaced
    case expires(at: Date)

    private enum CodingKeys: String, CodingKey {
        case kind
        case at
    }
    private enum Kind: String, Codable {
        case untilReplaced
        case expires
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .untilReplaced: self = .untilReplaced
        case .expires: self = .expires(at: try container.decode(Date.self, forKey: .at))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .untilReplaced:
            try container.encode(Kind.untilReplaced, forKey: .kind)
        case .expires(let at):
            try container.encode(Kind.expires, forKey: .kind)
            try container.encode(at, forKey: .at)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "untilReplaced", schema: .string(allowedValues: ["untilReplaced"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "expires", schema: .string(allowedValues: ["expires"])),
                .init(name: "at", description: "at", schema: .number()),
            ]),
        ])
    }
}

package struct IPCPaneAgentLineDetail: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let summary: String
    package let work: IPCPaneAgentLineWork
    package let detail: String?
    package let refs: [IPCPaneMessageAction]
    package let lifetime: IPCPaneAgentLineLifetime
    package let writer: IPCPaneMessageSender
    package let updatedAt: Date
    package let stale: Bool

    package init(
        summary: String, work: IPCPaneAgentLineWork, detail: String? = nil, refs: [IPCPaneMessageAction],
        lifetime: IPCPaneAgentLineLifetime, writer: IPCPaneMessageSender, updatedAt: Date, stale: Bool
    ) {
        self.summary = summary
        self.work = work
        self.detail = detail
        self.refs = refs
        self.lifetime = lifetime
        self.writer = writer
        self.updatedAt = updatedAt
        self.stale = stale
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "summary", description: "summary", schema: .string()),
            .init(name: "work", description: "work", schema: try IPCPaneAgentLineWork.ipcSchema()),
            .optional("detail", description: "detail", schema: .string()),
            .init(name: "refs", description: "refs", schema: .array(items: try IPCPaneMessageAction.ipcSchema())),
            .init(name: "lifetime", description: "lifetime", schema: try IPCPaneAgentLineLifetime.ipcSchema()),
            .init(name: "writer", description: "writer", schema: try IPCPaneMessageSender.ipcSchema()),
            .init(name: "updatedAt", description: "updatedAt", schema: .number()),
            .init(name: "stale", description: "stale", schema: .boolean),
        ])
    }
}
