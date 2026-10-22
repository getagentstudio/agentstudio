import Foundation

extension BridgeProductWorktreeAnnotationOperation {
    enum OutputKind: String, Codable, Equatable, Sendable {
        case clipboardMarkdown
        case jsonFile
    }

    enum OutputScope: String, Codable, Equatable, Sendable {
        case pending
        case all
    }

    enum OutputDestination: String, Codable, Equatable, Sendable {
        case remembered
        case choose
    }

    struct OutputMessage: Codable, Equatable, Sendable {
        let messageId: UUID
        let savedRevision: Int

        private enum CodingKeys: String, CodingKey {
            case messageId
            case savedRevision
        }

        init(messageId: UUID, savedRevision: Int) {
            self.messageId = messageId
            self.savedRevision = savedRevision
        }

        init(from decoder: Decoder) throws {
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: ["messageId", "savedRevision"],
                contract: "output comment"
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            messageId = try BridgeProductReviewPublicationIdContract.decode(
                container.decode(String.self, forKey: .messageId),
                codingPath: decoder.codingPath
            )
            savedRevision = try container.decode(Int.self, forKey: .savedRevision)
            guard savedRevision > 0 else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Output saved revision must be positive",
                    codingPath: decoder.codingPath
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                BridgeProductReviewPublicationIdContract.encode(messageId),
                forKey: .messageId
            )
            try container.encode(savedRevision, forKey: .savedRevision)
        }
    }

    struct OutputScopeCommitBody: Codable, Equatable, Sendable {
        let messages: [OutputMessage]
        let outputKind: OutputKind
        let destination: OutputDestination?
        let scope: OutputScope
        let sessionId: UUID

        init(
            messages: [OutputMessage],
            outputKind: OutputKind,
            destination: OutputDestination? = nil,
            scope: OutputScope,
            sessionId: UUID
        ) {
            self.messages = messages
            self.outputKind = outputKind
            self.destination = destination
            self.scope = scope
            self.sessionId = sessionId
        }
    }

    struct OutputHandledClearBody: Codable, Equatable, Sendable {
        let attemptId: UUID
        let expectedSessionRevision: Int
    }
}
