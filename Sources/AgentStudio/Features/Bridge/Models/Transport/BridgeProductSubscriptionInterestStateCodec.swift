import Foundation

enum BridgeProductReviewInterestIdentity {
    static func validate(_ value: String, codingPath: [any CodingKey]) throws {
        guard
            !value.isEmpty,
            value.utf8.count <= BridgeProductWireContract.maximumIdentifierByteLength
        else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid Bridge product review interest identity",
                codingPath: codingPath
            )
        }
    }
}

struct BridgeProductReviewMetadataInterestStateGroup: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case itemIds
        case lane
    }

    let itemIds: [String]
    let lane: BridgeProductDemandLane

    init(itemIds: [String], lane: BridgeProductDemandLane) throws {
        try BridgeProductContractDecoding.validateCollectionCount(
            itemIds.count,
            maximum: BridgeProductWireContract.maximumSubscriptionInterestItemCount,
            name: "review metadata interest-state items",
            codingPath: []
        )
        for itemId in itemIds {
            try BridgeProductReviewInterestIdentity.validate(itemId, codingPath: [])
        }
        self.itemIds = itemIds
        self.lane = lane
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "review metadata interest-state group"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.itemIds = try container.decode([String].self, forKey: .itemIds)
        self.lane = try container.decode(BridgeProductDemandLane.self, forKey: .lane)
        try BridgeProductContractDecoding.validateCollectionCount(
            itemIds.count,
            maximum: BridgeProductWireContract.maximumSubscriptionInterestItemCount,
            name: "review metadata interest-state items",
            codingPath: decoder.codingPath
        )
        for itemId in itemIds {
            try BridgeProductReviewInterestIdentity.validate(itemId, codingPath: decoder.codingPath)
        }
    }
}

struct BridgeProductFileMetadataInterestStateGroup: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case lane
        case paths
    }

    let lane: BridgeProductDemandLane
    let paths: [String]

    init(lane: BridgeProductDemandLane, paths: [String]) throws {
        try BridgeProductContractDecoding.validateCollectionCount(
            paths.count,
            maximum: BridgeProductWireContract.maximumSubscriptionInterestItemCount,
            name: "file metadata interest-state paths",
            codingPath: []
        )
        for path in paths {
            try BridgeProductContractDecoding.validateDisplayPath(path, codingPath: [])
        }
        self.lane = lane
        self.paths = paths
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "file metadata interest-state group"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.lane = try container.decode(BridgeProductDemandLane.self, forKey: .lane)
        self.paths = try container.decode([String].self, forKey: .paths)
        try BridgeProductContractDecoding.validateCollectionCount(
            paths.count,
            maximum: BridgeProductWireContract.maximumSubscriptionInterestItemCount,
            name: "file metadata interest-state paths",
            codingPath: decoder.codingPath
        )
        for path in paths {
            try BridgeProductContractDecoding.validateDisplayPath(path, codingPath: decoder.codingPath)
        }
    }
}
