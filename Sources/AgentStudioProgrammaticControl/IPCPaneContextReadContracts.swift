import Foundation

package struct IPCPaneLiveMessageCursor: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let rank: Int
    package let position: UInt64

    package init(rank: Int, position: UInt64) {
        self.rank = rank
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case rank
        case position
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rank = try IPCPaneNumericCoding.decodeSigned(from: container, forKey: .rank)
        position = try IPCPaneNumericCoding.decodeUnsigned(from: container, forKey: .position)
    }

    package func encode(to encoder: any Encoder) throws {
        try IPCPaneNumericCoding.requireSafe(rank)
        try IPCPaneNumericCoding.requireSafe(position)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rank, forKey: .rank)
        try container.encode(position, forKey: .position)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "rank", description: "rank", schema: IPCSchemaScalars.signedInteger),
            .init(name: "position", description: "position", schema: IPCSchemaScalars.unsignedInteger),
        ])
    }
}

package enum IPCPaneContextReadPage: Codable, Equatable, Sendable, IPCSchemaProviding {
    case first
    case more(source: UUID, after: IPCPaneLiveMessageCursor)
    case moreSources(after: UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case source
        case after
    }
    private enum Kind: String, Codable {
        case first
        case more
        case moreSources
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .first: self = .first
        case .more:
            self = .more(
                source: try container.decode(UUID.self, forKey: .source),
                after: try container.decode(IPCPaneLiveMessageCursor.self, forKey: .after))
        case .moreSources: self = .moreSources(after: try container.decode(UUID.self, forKey: .after))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .first:
            try container.encode(Kind.first, forKey: .kind)
        case .more(let source, let after):
            try container.encode(Kind.more, forKey: .kind)
            try container.encode(source, forKey: .source)
            try container.encode(after, forKey: .after)
        case .moreSources(let after):
            try container.encode(Kind.moreSources, forKey: .kind)
            try container.encode(after, forKey: .after)
        }
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(name: "kind", description: "first", schema: .string(allowedValues: ["first"]))

            ]),
            .object(fields: [
                .init(name: "kind", description: "more", schema: .string(allowedValues: ["more"])),
                .init(name: "source", description: "source", schema: IPCSchemaScalars.uuid),
                .init(name: "after", description: "after", schema: try IPCPaneLiveMessageCursor.ipcSchema()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "moreSources", schema: .string(allowedValues: ["moreSources"])),
                .init(name: "after", description: "after", schema: IPCSchemaScalars.uuid),
            ]),
        ])
    }
}

package struct IPCPaneContextGetParams: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let handle: String
    package let page: IPCPaneContextReadPage

    package init(handle: String, page: IPCPaneContextReadPage) {
        self.handle = handle
        self.page = page
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "handle", description: "handle", schema: .string()),
            .init(name: "page", description: "page", schema: try IPCPaneContextReadPage.ipcSchema()),
        ])
    }
}

package struct IPCPaneContextGetResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let paneId: UUID
    package let revision: UInt64
    package let agentTitle: String?
    package let agentLine: IPCPaneAgentLineDetail?
    package let session: IPCPaneSessionSummary?
    package let messages: [IPCPaneMessageDetail]
    package let drawerMessages: [IPCPaneDrawerMessageGroup]
    package let links: IPCPaneLinksDetail
    package let pullRequests: IPCPanePullRequestSummaryDetail
    package let truncation: IPCPaneDetailTruncation?

    package init(
        paneId: UUID, revision: UInt64, agentTitle: String? = nil, agentLine: IPCPaneAgentLineDetail? = nil,
        session: IPCPaneSessionSummary? = nil, messages: [IPCPaneMessageDetail],
        drawerMessages: [IPCPaneDrawerMessageGroup], links: IPCPaneLinksDetail,
        pullRequests: IPCPanePullRequestSummaryDetail, truncation: IPCPaneDetailTruncation? = nil
    ) {
        self.paneId = paneId
        self.revision = revision
        self.agentTitle = agentTitle
        self.agentLine = agentLine
        self.session = session
        self.messages = messages
        self.drawerMessages = drawerMessages
        self.links = links
        self.pullRequests = pullRequests
        self.truncation = truncation
    }

    private enum CodingKeys: String, CodingKey {
        case paneId
        case revision
        case agentTitle
        case agentLine
        case session
        case messages
        case drawerMessages
        case links
        case pullRequests
        case truncation
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try container.decode(UUID.self, forKey: .paneId)
        revision = try IPCPaneNumericCoding.decodeUnsigned(from: container, forKey: .revision)
        agentTitle = try container.decodeIfPresent(String.self, forKey: .agentTitle)
        agentLine = try container.decodeIfPresent(IPCPaneAgentLineDetail.self, forKey: .agentLine)
        session = try container.decodeIfPresent(IPCPaneSessionSummary.self, forKey: .session)
        messages = try container.decode([IPCPaneMessageDetail].self, forKey: .messages)
        drawerMessages = try container.decode([IPCPaneDrawerMessageGroup].self, forKey: .drawerMessages)
        links = try container.decode(IPCPaneLinksDetail.self, forKey: .links)
        pullRequests = try container.decode(IPCPanePullRequestSummaryDetail.self, forKey: .pullRequests)
        truncation = try container.decodeIfPresent(IPCPaneDetailTruncation.self, forKey: .truncation)
    }

    package func encode(to encoder: any Encoder) throws {
        try IPCPaneNumericCoding.requireSafe(revision)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paneId, forKey: .paneId)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(agentTitle, forKey: .agentTitle)
        try container.encodeIfPresent(agentLine, forKey: .agentLine)
        try container.encodeIfPresent(session, forKey: .session)
        try container.encode(messages, forKey: .messages)
        try container.encode(drawerMessages, forKey: .drawerMessages)
        try container.encode(links, forKey: .links)
        try container.encode(pullRequests, forKey: .pullRequests)
        try container.encodeIfPresent(truncation, forKey: .truncation)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "paneId", description: "paneId", schema: IPCSchemaScalars.uuid),
            .init(name: "revision", description: "revision", schema: IPCSchemaScalars.unsignedInteger),
            .optional("agentTitle", description: "agentTitle", schema: .string()),
            .optional("agentLine", description: "agentLine", schema: try IPCPaneAgentLineDetail.ipcSchema()),
            .optional("session", description: "session", schema: try IPCPaneSessionSummary.ipcSchema()),
            .init(
                name: "messages", description: "messages", schema: .array(items: try IPCPaneMessageDetail.ipcSchema())),
            .init(
                name: "drawerMessages", description: "drawerMessages",
                schema: .array(items: try IPCPaneDrawerMessageGroup.ipcSchema())),
            .init(name: "links", description: "links", schema: try IPCPaneLinksDetail.ipcSchema()),
            .init(
                name: "pullRequests", description: "pullRequests",
                schema: try IPCPanePullRequestSummaryDetail.ipcSchema()),
            .optional("truncation", description: "truncation", schema: try IPCPaneDetailTruncation.ipcSchema()),
        ])
    }
}

package struct IPCPaneDrawerMessageGroup: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let sourcePaneId: UUID
    package let messages: [IPCPaneMessageDetail]

    package init(sourcePaneId: UUID, messages: [IPCPaneMessageDetail]) {
        self.sourcePaneId = sourcePaneId
        self.messages = messages
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "sourcePaneId", description: "sourcePaneId", schema: IPCSchemaScalars.uuid),
            .init(
                name: "messages", description: "messages", schema: .array(items: try IPCPaneMessageDetail.ipcSchema())),
        ])
    }
}

package struct IPCPaneDetailTruncation: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let omitted: [IPCPaneOmittedLiveMessages]
    package let remainingLiveSources: Int
    package let nextSourcesAfter: UUID?

    package init(omitted: [IPCPaneOmittedLiveMessages], remainingLiveSources: Int, nextSourcesAfter: UUID?) {
        self.omitted = omitted
        self.remainingLiveSources = remainingLiveSources
        self.nextSourcesAfter = nextSourcesAfter
    }

    private enum CodingKeys: String, CodingKey {
        case omitted
        case remainingLiveSources
        case nextSourcesAfter
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        omitted = try container.decode([IPCPaneOmittedLiveMessages].self, forKey: .omitted)
        remainingLiveSources = try IPCPaneNumericCoding.decodeSigned(from: container, forKey: .remainingLiveSources)
        guard remainingLiveSources >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .remainingLiveSources, in: container, debugDescription: "Expected a non-negative source count")
        }
        nextSourcesAfter = try container.decodeIfPresent(UUID.self, forKey: .nextSourcesAfter)
    }

    package func encode(to encoder: any Encoder) throws {
        try IPCPaneNumericCoding.requireSafe(remainingLiveSources)
        guard remainingLiveSources >= 0 else { throw IPCPaneNumericEncodingError.aboveSafeIntegerBound }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(omitted, forKey: .omitted)
        try container.encode(remainingLiveSources, forKey: .remainingLiveSources)
        try container.encodeIfPresent(nextSourcesAfter, forKey: .nextSourcesAfter)
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "omitted", description: "omitted",
                schema: .array(items: try IPCPaneOmittedLiveMessages.ipcSchema())),
            .init(
                name: "remainingLiveSources", description: "Unrepresented live sources",
                schema: IPCSchemaScalars.unsignedInteger),
            .optional("nextSourcesAfter", description: "Last represented source cursor", schema: IPCSchemaScalars.uuid),
        ])
    }
}

package struct IPCPaneOmittedLiveMessages: Codable, Equatable, Sendable, IPCSchemaProviding {
    package let source: UUID
    package let openAsks: Int
    package let unreadNotices: Int
    package let next: IPCPaneLiveMessageCursor

    package init(source: UUID, openAsks: Int, unreadNotices: Int, next: IPCPaneLiveMessageCursor) {
        self.source = source
        self.openAsks = openAsks
        self.unreadNotices = unreadNotices
        self.next = next
    }

    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "source", description: "source", schema: IPCSchemaScalars.uuid),
            .init(name: "openAsks", description: "openAsks", schema: IPCSchemaScalars.signedInteger),
            .init(name: "unreadNotices", description: "unreadNotices", schema: IPCSchemaScalars.signedInteger),
            .init(name: "next", description: "next", schema: try IPCPaneLiveMessageCursor.ipcSchema()),
        ])
    }
}

package enum IPCPaneLinksDetail: String, Codable, CaseIterable, Equatable, Sendable, IPCSchemaProviding {
    case unknown
}
