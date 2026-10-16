import Foundation

struct BridgeProductAnnotationOutputResultDTO: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case attemptId
        case destinationFilename
        case messageCount
        case outputKind
        case sessionId
    }

    let attemptId: UUID
    let destinationFilename: String?
    let messageCount: Int
    let outputKind: WorktreeAnnotationOutputKind
    let sessionId: UUID

    init(_ summary: WorktreeAnnotationOutputResultSummary) {
        attemptId = summary.attemptID.rawValue
        destinationFilename = summary.destinationFilename
        messageCount = summary.messageCount
        outputKind = summary.outputKind
        sessionId = summary.sessionID.rawValue
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "annotation output result summary"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attemptId = try container.decode(UUID.self, forKey: .attemptId)
        destinationFilename = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .destinationFilename,
            from: container,
            codingPath: decoder.codingPath
        )
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        outputKind = try container.decode(WorktreeAnnotationOutputKind.self, forKey: .outputKind)
        sessionId = try container.decode(UUID.self, forKey: .sessionId)
        guard messageCount > 0 else {
            throw BridgeProductContractDecoding.invalidValue(
                "Annotation output message count must be positive",
                codingPath: decoder.codingPath
            )
        }
        if let destinationFilename {
            guard !destinationFilename.isEmpty,
                destinationFilename.utf8.count <= 4096,
                !destinationFilename.contains("/"),
                !destinationFilename.contains("\\")
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Annotation output destination filename is invalid",
                    codingPath: decoder.codingPath
                )
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(attemptId),
            forKey: .attemptId
        )
        try container.encode(destinationFilename, forKey: .destinationFilename)
        try container.encode(messageCount, forKey: .messageCount)
        try container.encode(outputKind, forKey: .outputKind)
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(sessionId),
            forKey: .sessionId
        )
    }
}

enum BridgeProductAnnotationOutputOutcomeDTO: Codable, Equatable, Sendable {
    case destinationCancelled
    case destinationSelectionFailed(String)
    case succeeded(BridgeProductAnnotationOutputResultDTO)
    case effectFailed(
        summary: BridgeProductAnnotationOutputResultDTO,
        effectError: String,
        effectCode: WorktreeAnnotationOutputFileFailureCode?
    )
    case effectAndCleanupFailed(
        summary: BridgeProductAnnotationOutputResultDTO,
        effectError: String,
        effectCode: WorktreeAnnotationOutputFileFailureCode?,
        cleanupError: String
    )
    case partialSuccess(
        summary: BridgeProductAnnotationOutputResultDTO,
        finalizationError: String
    )

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cleanupError
        case effectError
        case effectCode
        case finalizationError
        case kind
        case selectionError
        case summary
    }

    init(_ outcome: WorktreeAnnotationOutputCommandOutcome) {
        switch outcome {
        case .destinationCancelled:
            self = .destinationCancelled
        case .destinationSelectionFailed(let error):
            self = .destinationSelectionFailed(error)
        case .succeeded(let summary):
            self = .succeeded(.init(summary))
        case .effectFailed(let summary, let effectError, let effectCode):
            self = .effectFailed(summary: .init(summary), effectError: effectError, effectCode: effectCode)
        case .effectAndCleanupFailed(let summary, let effectError, let effectCode, let cleanupError):
            self = .effectAndCleanupFailed(
                summary: .init(summary),
                effectError: effectError,
                effectCode: effectCode,
                cleanupError: cleanupError
            )
        case .partialSuccess(let summary, let finalizationError):
            self = .partialSuccess(
                summary: .init(summary),
                finalizationError: finalizationError
            )
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let allowedKeys: Set<String>
        switch kind {
        case "destination_cancelled":
            allowedKeys = [CodingKeys.kind.rawValue]
        case "destination_selection_failed":
            allowedKeys = [CodingKeys.kind.rawValue, CodingKeys.selectionError.rawValue]
        case "succeeded":
            allowedKeys = [CodingKeys.kind.rawValue, CodingKeys.summary.rawValue]
        case "effect_failed":
            allowedKeys = [
                CodingKeys.effectError.rawValue,
                CodingKeys.effectCode.rawValue,
                CodingKeys.kind.rawValue,
                CodingKeys.summary.rawValue,
            ]
        case "effect_and_cleanup_failed":
            allowedKeys = [
                CodingKeys.cleanupError.rawValue,
                CodingKeys.effectError.rawValue,
                CodingKeys.effectCode.rawValue,
                CodingKeys.kind.rawValue,
                CodingKeys.summary.rawValue,
            ]
        case "partial_success":
            allowedKeys = [
                CodingKeys.finalizationError.rawValue,
                CodingKeys.kind.rawValue,
                CodingKeys.summary.rawValue,
            ]
        default:
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid annotation output command outcome",
                codingPath: decoder.codingPath
            )
        }
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: allowedKeys,
            contract: "annotation output command outcome"
        )
        switch kind {
        case "destination_cancelled":
            self = .destinationCancelled
        case "destination_selection_failed":
            self = .destinationSelectionFailed(
                try Self.nonemptyString(container, .selectionError, decoder)
            )
        case "succeeded":
            self = .succeeded(try Self.summary(container))
        case "effect_failed":
            self = .effectFailed(
                summary: try Self.summary(container),
                effectError: try Self.nonemptyString(container, .effectError, decoder),
                effectCode: try container.decodeIfPresent(
                    WorktreeAnnotationOutputFileFailureCode.self,
                    forKey: .effectCode
                )
            )
        case "effect_and_cleanup_failed":
            self = .effectAndCleanupFailed(
                summary: try Self.summary(container),
                effectError: try Self.nonemptyString(container, .effectError, decoder),
                effectCode: try container.decodeIfPresent(
                    WorktreeAnnotationOutputFileFailureCode.self,
                    forKey: .effectCode
                ),
                cleanupError: try Self.nonemptyString(container, .cleanupError, decoder)
            )
        case "partial_success":
            self = .partialSuccess(
                summary: try Self.summary(container),
                finalizationError: try Self.nonemptyString(container, .finalizationError, decoder)
            )
        default:
            preconditionFailure("Outcome kind was validated above")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .destinationCancelled:
            try container.encode("destination_cancelled", forKey: .kind)
        case .destinationSelectionFailed(let error):
            try container.encode("destination_selection_failed", forKey: .kind)
            try container.encode(error, forKey: .selectionError)
        case .succeeded(let summary):
            try container.encode("succeeded", forKey: .kind)
            try container.encode(summary, forKey: .summary)
        case .effectFailed(let summary, let effectError, let effectCode):
            try container.encode(effectError, forKey: .effectError)
            try container.encodeIfPresent(effectCode, forKey: .effectCode)
            try container.encode("effect_failed", forKey: .kind)
            try container.encode(summary, forKey: .summary)
        case .effectAndCleanupFailed(let summary, let effectError, let effectCode, let cleanupError):
            try container.encode(cleanupError, forKey: .cleanupError)
            try container.encode(effectError, forKey: .effectError)
            try container.encodeIfPresent(effectCode, forKey: .effectCode)
            try container.encode("effect_and_cleanup_failed", forKey: .kind)
            try container.encode(summary, forKey: .summary)
        case .partialSuccess(let summary, let finalizationError):
            try container.encode(finalizationError, forKey: .finalizationError)
            try container.encode("partial_success", forKey: .kind)
            try container.encode(summary, forKey: .summary)
        }
    }

    private static func nonemptyString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        _ decoder: Decoder
    ) throws -> String {
        let value = try container.decode(String.self, forKey: key)
        guard !value.isEmpty else {
            throw BridgeProductContractDecoding.invalidValue(
                "Annotation output error must be nonempty",
                codingPath: decoder.codingPath + [key]
            )
        }
        return value
    }

    private static func summary(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws -> BridgeProductAnnotationOutputResultDTO {
        try container.decode(
            BridgeProductAnnotationOutputResultDTO.self,
            forKey: .summary
        )
    }
}
