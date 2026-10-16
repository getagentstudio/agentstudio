import Foundation

enum BridgeProductReviewBatchContentRole: Codable, Equatable, Sendable {
    case available(BridgeProductReviewContentSourceDescriptor)
    case unavailable
    case absent

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        switch state {
        case "available":
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder, allowedKeys: ["source", "state"], contract: "Review available role"
            )
            self = .available(try container.decode(BridgeProductReviewContentSourceDescriptor.self, forKey: .source))
        case "unavailable", "absent":
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder, allowedKeys: ["state"], contract: "Review unavailable role"
            )
            self = state == "unavailable" ? .unavailable : .absent
        default:
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid Review content role state", codingPath: decoder.codingPath)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let source):
            try container.encode("available", forKey: .state)
            try container.encode(source, forKey: .source)
        case .unavailable:
            try container.encode("unavailable", forKey: .state)
        case .absent:
            try container.encode("absent", forKey: .state)
        }
    }
}

struct BridgeProductReviewBatchContentByRole: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case base, diff, file, head }

    let base: BridgeProductReviewBatchContentRole
    let diff: BridgeProductReviewBatchContentRole
    let file: BridgeProductReviewBatchContentRole
    let head: BridgeProductReviewBatchContentRole

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)), contract: "Review content roles"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        base = try container.decode(BridgeProductReviewBatchContentRole.self, forKey: .base)
        diff = try container.decode(BridgeProductReviewBatchContentRole.self, forKey: .diff)
        file = try container.decode(BridgeProductReviewBatchContentRole.self, forKey: .file)
        head = try container.decode(BridgeProductReviewBatchContentRole.self, forKey: .head)
    }

    func validate(itemID: String, codingPath: [any CodingKey]) throws {
        for (role, value) in [("base", base), ("diff", diff), ("file", file), ("head", head)] {
            guard case .available(let source) = value else { continue }
            guard source.itemId == itemID, source.role.rawValue == role else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Review content source must match its item and role", codingPath: codingPath
                )
            }
        }
    }
}

struct BridgeProductReviewBatchExtentByRole: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case base, diff, file, head }

    let base: Int?
    let diff: Int?
    let file: Int?
    let head: Int?

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)), contract: "Review extents"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        base = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self, forKey: .base, from: container, codingPath: decoder.codingPath)
        diff = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self, forKey: .diff, from: container, codingPath: decoder.codingPath)
        file = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self, forKey: .file, from: container, codingPath: decoder.codingPath)
        head = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self, forKey: .head, from: container, codingPath: decoder.codingPath)
        for value in [base, diff, file, head].compactMap({ $0 }) {
            try BridgeProductContractDecoding.validateNonnegative(
                value, name: "Review role line count", codingPath: decoder.codingPath)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(base, forKey: .base)
        try container.encode(diff, forKey: .diff)
        try container.encode(file, forKey: .file)
        try container.encode(head, forKey: .head)
    }
}

struct BridgeProductReviewBatchItemRecord: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case additions, basePath, changeKind, contentByRole, contentHashesByRole, deletions, extentByRole
        case fileExtension = "extension"
        case fileClass, headPath, isHiddenByDefault, itemId, lane, language, loadedBy
        case mimeTypes, parentPath, provenance, recordKind, reviewPriority, reviewState, sortKey
    }

    let additions: Int
    let basePath: String?
    let changeKind: BridgeFileChangeKind
    let contentByRole: BridgeProductReviewBatchContentByRole
    let contentHashesByRole: BridgeProductReviewContentHashesByRole
    let deletions: Int
    let extentByRole: BridgeProductReviewBatchExtentByRole
    let fileExtension: String?
    let fileClass: BridgeFileClass
    let headPath: String?
    let isHiddenByDefault: Bool
    let itemId: String
    let lane: BridgeProductDemandLane?
    let language: String?
    let loadedBy: BridgeProductReviewMetadataLoadedBy?
    let mimeTypes: [String]
    let parentPath: String?
    let provenance: BridgeProductReviewItemProvenanceValue
    let recordKind: String
    let reviewPriority: BridgeReviewPriority
    let reviewState: BridgeFileReviewState
    let sortKey: Int

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)), contract: "Review batch item"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        additions = try container.decode(Int.self, forKey: .additions)
        basePath = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self, forKey: .basePath, from: container, codingPath: decoder.codingPath)
        changeKind = try container.decode(BridgeFileChangeKind.self, forKey: .changeKind)
        contentByRole = try container.decode(BridgeProductReviewBatchContentByRole.self, forKey: .contentByRole)
        contentHashesByRole = try container.decode(
            BridgeProductReviewContentHashesByRole.self, forKey: .contentHashesByRole)
        deletions = try container.decode(Int.self, forKey: .deletions)
        extentByRole = try container.decode(BridgeProductReviewBatchExtentByRole.self, forKey: .extentByRole)
        fileExtension = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self, forKey: .fileExtension, from: container, codingPath: decoder.codingPath)
        fileClass = try container.decode(BridgeFileClass.self, forKey: .fileClass)
        headPath = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self, forKey: .headPath, from: container, codingPath: decoder.codingPath)
        isHiddenByDefault = try container.decode(Bool.self, forKey: .isHiddenByDefault)
        itemId = try container.decode(String.self, forKey: .itemId)
        lane = try container.decodeIfPresent(BridgeProductDemandLane.self, forKey: .lane)
        language = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self, forKey: .language, from: container, codingPath: decoder.codingPath)
        loadedBy = try container.decodeIfPresent(BridgeProductReviewMetadataLoadedBy.self, forKey: .loadedBy)
        mimeTypes = try container.decode([String].self, forKey: .mimeTypes)
        parentPath = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self, forKey: .parentPath, from: container, codingPath: decoder.codingPath)
        provenance = try container.decode(BridgeProductReviewItemProvenanceValue.self, forKey: .provenance)
        recordKind = try container.decode(String.self, forKey: .recordKind)
        reviewPriority = try container.decode(BridgeReviewPriority.self, forKey: .reviewPriority)
        reviewState = try container.decode(BridgeFileReviewState.self, forKey: .reviewState)
        sortKey = try container.decode(Int.self, forKey: .sortKey)
        guard recordKind == "item" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid Review batch item kind", codingPath: decoder.codingPath)
        }
        for (value, name) in [(additions, "additions"), (deletions, "deletions"), (sortKey, "sortKey")] {
            try BridgeProductContractDecoding.validateNonnegative(value, name: name, codingPath: decoder.codingPath)
        }
        try BridgeProductContractDecoding.validateIdentifier(itemId, codingPath: decoder.codingPath)
        for path in [basePath, headPath, parentPath].compactMap({ $0 }) {
            try BridgeProductContractDecoding.validateDisplayPath(path, codingPath: decoder.codingPath)
        }
        for reference in [fileExtension, language].compactMap({ $0 }) {
            try BridgeProductContractDecoding.validateOpaqueReference(reference, codingPath: decoder.codingPath)
        }
        try BridgeProductContractDecoding.validateCollectionCount(
            mimeTypes.count, maximum: 4, name: "mimeTypes", codingPath: decoder.codingPath)
        for mimeType in mimeTypes {
            try BridgeProductContractDecoding.validateOpaqueReference(mimeType, codingPath: decoder.codingPath)
        }
        try contentByRole.validate(itemID: itemId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(additions, forKey: .additions)
        try container.encode(basePath, forKey: .basePath)
        try container.encode(changeKind, forKey: .changeKind)
        try container.encode(contentByRole, forKey: .contentByRole)
        try container.encode(contentHashesByRole, forKey: .contentHashesByRole)
        try container.encode(deletions, forKey: .deletions)
        try container.encode(extentByRole, forKey: .extentByRole)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encode(fileClass, forKey: .fileClass)
        try container.encode(headPath, forKey: .headPath)
        try container.encode(isHiddenByDefault, forKey: .isHiddenByDefault)
        try container.encode(itemId, forKey: .itemId)
        try container.encodeIfPresent(lane, forKey: .lane)
        try container.encode(language, forKey: .language)
        try container.encodeIfPresent(loadedBy, forKey: .loadedBy)
        try container.encode(mimeTypes, forKey: .mimeTypes)
        try container.encode(parentPath, forKey: .parentPath)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(recordKind, forKey: .recordKind)
        try container.encode(reviewPriority, forKey: .reviewPriority)
        try container.encode(reviewState, forKey: .reviewState)
        try container.encode(sortKey, forKey: .sortKey)
    }
}

struct BridgeProductReviewBatchDisplayedPublication: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case baseEndpoint, comparisonOrigin, generation, headEndpoint, packageId, publicationId
        case query, reviewComparison, reviewedSubjectLabel, revision, summary
    }

    let baseEndpoint: BridgeProductReviewSourceEndpointValue
    let comparisonOrigin: BridgeReviewComparisonOrigin?
    let generation: Int
    let headEndpoint: BridgeProductReviewSourceEndpointValue
    let packageId: String
    let publicationId: UUID
    let query: BridgeProductReviewQueryValue
    let reviewComparison: BridgePaneReviewComparisonPresentation?
    let reviewedSubjectLabel: String?
    let revision: Int
    let summary: BridgeProductReviewPackageSummaryValue

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "Review displayed publication"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseEndpoint = try container.decode(BridgeProductReviewSourceEndpointValue.self, forKey: .baseEndpoint)
        comparisonOrigin = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeReviewComparisonOrigin.self, forKey: .comparisonOrigin, from: container,
            codingPath: decoder.codingPath)
        generation = try container.decode(Int.self, forKey: .generation)
        headEndpoint = try container.decode(BridgeProductReviewSourceEndpointValue.self, forKey: .headEndpoint)
        packageId = try container.decode(String.self, forKey: .packageId)
        publicationId = try BridgeProductReviewPublicationIdContract.decode(
            container.decode(String.self, forKey: .publicationId), codingPath: decoder.codingPath)
        query = try container.decode(BridgeProductReviewQueryValue.self, forKey: .query)
        reviewComparison = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgePaneReviewComparisonPresentation.self, forKey: .reviewComparison, from: container,
            codingPath: decoder.codingPath)
        reviewedSubjectLabel = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self, forKey: .reviewedSubjectLabel, from: container, codingPath: decoder.codingPath)
        revision = try container.decode(Int.self, forKey: .revision)
        summary = try container.decode(BridgeProductReviewPackageSummaryValue.self, forKey: .summary)
        try BridgeProductContractDecoding.validateNonnegative(
            generation, name: "generation", codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(packageId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            revision, name: "revision", codingPath: decoder.codingPath
        )
        if let reviewedSubjectLabel {
            try BridgeProductContractDecoding.validateSafeMessage(reviewedSubjectLabel, codingPath: decoder.codingPath)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseEndpoint, forKey: .baseEndpoint)
        try container.encode(comparisonOrigin, forKey: .comparisonOrigin)
        try container.encode(generation, forKey: .generation)
        try container.encode(headEndpoint, forKey: .headEndpoint)
        try container.encode(packageId, forKey: .packageId)
        try container.encode(BridgeProductReviewPublicationIdContract.encode(publicationId), forKey: .publicationId)
        try container.encode(query, forKey: .query)
        try container.encode(reviewComparison, forKey: .reviewComparison)
        try container.encode(reviewedSubjectLabel, forKey: .reviewedSubjectLabel)
        try container.encode(revision, forKey: .revision)
        try container.encode(summary, forKey: .summary)
    }
}

struct BridgeProductReviewBatchDesiredPublication: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case ready, updating, failedRetryable, failedPermanent
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case reviewComparison, status }

    let reviewComparison: BridgePaneReviewComparisonPresentation?
    let status: Status

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)), contract: "Review desired publication"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reviewComparison = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgePaneReviewComparisonPresentation.self, forKey: .reviewComparison, from: container,
            codingPath: decoder.codingPath)
        status = try container.decode(Status.self, forKey: .status)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reviewComparison, forKey: .reviewComparison)
        try container.encode(status, forKey: .status)
    }
}

struct BridgeProductReviewBatchPublicationRecord: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case classifiedRefreshImpact, desired, displayed, publicationId, recordKind, revision
    }

    let classifiedRefreshImpact: BridgeReviewRefreshImpact?
    let desired: BridgeProductReviewBatchDesiredPublication
    let displayed: BridgeProductReviewBatchDisplayedPublication?
    let publicationId: UUID
    let recordKind: String
    let revision: Int

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)), contract: "Review publication record"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        classifiedRefreshImpact = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeReviewRefreshImpact.self, forKey: .classifiedRefreshImpact, from: container,
            codingPath: decoder.codingPath)
        desired = try container.decode(BridgeProductReviewBatchDesiredPublication.self, forKey: .desired)
        displayed = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeProductReviewBatchDisplayedPublication.self, forKey: .displayed, from: container,
            codingPath: decoder.codingPath)
        publicationId = try BridgeProductReviewPublicationIdContract.decode(
            container.decode(String.self, forKey: .publicationId), codingPath: decoder.codingPath
        )
        recordKind = try container.decode(String.self, forKey: .recordKind)
        revision = try container.decode(Int.self, forKey: .revision)
        guard recordKind == "publication" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid Review publication record kind", codingPath: decoder.codingPath)
        }
        try BridgeProductContractDecoding.validatePositive(
            revision, name: "Review publication revision", codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(classifiedRefreshImpact, forKey: .classifiedRefreshImpact)
        try container.encode(desired, forKey: .desired)
        try container.encode(displayed, forKey: .displayed)
        try container.encode(BridgeProductReviewPublicationIdContract.encode(publicationId), forKey: .publicationId)
        try container.encode(recordKind, forKey: .recordKind)
        try container.encode(revision, forKey: .revision)
    }
}

extension BridgeReviewRefreshImpact: Codable {
    init(from decoder: Decoder) throws {
        self = try BridgeReviewRefreshImpactWireContract.decodeRequired(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try BridgeReviewRefreshImpactWireContract.encode(self, to: encoder)
    }
}

enum BridgeProductReviewBatchRecord: Codable, Equatable, Sendable {
    case item(BridgeProductReviewBatchItemRecord)
    case publication(BridgeProductReviewBatchPublicationRecord)

    private enum CodingKeys: String, CodingKey { case recordKind }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .recordKind) {
        case "item": self = .item(try .init(from: decoder))
        case "publication": self = .publication(try .init(from: decoder))
        default:
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid Review batch record kind", codingPath: decoder.codingPath)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .item(let record): try record.encode(to: encoder)
        case .publication(let record): try record.encode(to: encoder)
        }
    }
}
