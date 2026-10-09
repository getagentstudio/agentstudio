import Foundation

enum BridgeProductViewScopeContract {
    static func hasSameMembershipFilter(_ previous: BridgeProductJSONValue, _ next: BridgeProductJSONValue) -> Bool {
        guard case .object(let previousMembers) = previous,
            case .object(let nextMembers) = next,
            previousMembers["kind"] == nextMembers["kind"]
        else { return false }
        if previousMembers["kind"] == .string("file") {
            return previousMembers["changeFilter"] == nextMembers["changeFilter"]
                && previousMembers["pathScope"] == nextMembers["pathScope"]
        }
        if previousMembers["kind"] == .string("comment") {
            return previousMembers["worktreeId"] == nextMembers["worktreeId"]
        }
        return true
    }

    static func fileDemand(
        from scope: BridgeProductJSONValue
    ) throws -> BridgeProductFileMetadataInterestState {
        guard case .object(let members) = scope,
            case .string("file")? = members["kind"],
            let interests = members["interests"],
            let pathScope = members["pathScope"]
        else {
            throw BridgeProductContractDecoding.invalidValue("File view demand is absent", codingPath: [])
        }
        let demand = BridgeProductJSONValue.object([
            "interests": interests,
            "pathScope": pathScope,
        ])
        return try BridgeProductStrictJSON.decode(
            BridgeProductFileMetadataInterestState.self,
            from: JSONEncoder().encode(demand)
        )
    }

    static func reviewDemand(
        from scope: BridgeProductJSONValue
    ) throws -> BridgeProductReviewMetadataInterestState {
        guard case .object(let members) = scope,
            case .string("review")? = members["kind"],
            let interests = members["interests"]
        else {
            throw BridgeProductContractDecoding.invalidValue("Review view demand is absent", codingPath: [])
        }
        return try BridgeProductStrictJSON.decode(
            BridgeProductReviewMetadataInterestState.self,
            from: JSONEncoder().encode(BridgeProductJSONValue.object(["interests": interests]))
        )
    }

    static func validate(_ scope: BridgeProductJSONValue, codingPath: [any CodingKey]) throws {
        guard case .object(let members) = scope,
            case .string(let kind)? = members["kind"]
        else {
            throw BridgeProductContractDecoding.invalidValue(
                "View scope requires an object kind",
                codingPath: codingPath
            )
        }
        try BridgeProductContractDecoding.validateNonemptyString(kind, codingPath: codingPath)
        if kind == "comment" {
            guard Set(members.keys) == ["kind", "sessionIds", "worktreeId"],
                case .string(let worktreeID)? = members["worktreeId"],
                case .array(let sessionIDs)? = members["sessionIds"],
                sessionIDs.count <= 128
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Comment scope requires a worktree and bounded sessions",
                    codingPath: codingPath
                )
            }
            try BridgeProductContractDecoding.validateIdentifier(worktreeID, codingPath: codingPath)
            var seenSessions: Set<Data> = []
            for value in sessionIDs {
                guard case .string(let sessionID) = value,
                    seenSessions.insert(Data(sessionID.utf8)).inserted
                else {
                    throw BridgeProductContractDecoding.invalidValue(
                        "Comment scope session ids must be unique strings", codingPath: codingPath
                    )
                }
                try BridgeProductContractDecoding.validateIdentifier(sessionID, codingPath: codingPath)
            }
            return
        }
        if kind == "review" {
            let allowedKeys: Set<String> = ["kind", "interests", "prefix"]
            guard Set(members.keys).isSubset(of: allowedKeys),
                let interests = members["interests"]
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Review scope requires interests", codingPath: codingPath
                )
            }
            try validateInterestGroups(interests, itemKey: "itemIds", codingPath: codingPath)
            try validatePrefix(members["prefix"], codingPath: codingPath)
            return
        }
        guard kind == "file" else {
            throw BridgeProductContractDecoding.invalidValue("Unknown view scope kind", codingPath: codingPath)
        }
        let allowedKeys: Set<String> = ["kind", "changeFilter", "interests", "pathScope", "prefix"]
        guard Set(members.keys).isSubset(of: allowedKeys),
            let interests = members["interests"],
            case .array(let pathScope)? = members["pathScope"],
            pathScope.count <= BridgeProductWireContract.maximumSubscriptionInterestItemCount
        else {
            throw BridgeProductContractDecoding.invalidValue(
                "File scope requires bounded interests and path scope", codingPath: codingPath
            )
        }
        try validateInterestGroups(interests, itemKey: "paths", codingPath: codingPath)
        var seenPaths: Set<Data> = []
        for value in pathScope {
            guard case .string(let path) = value,
                seenPaths.insert(Data(path.utf8)).inserted
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "File path scope must contain unique paths", codingPath: codingPath
                )
            }
            try BridgeProductContractDecoding.validateDisplayPath(path, codingPath: codingPath)
        }
        try validatePrefix(members["prefix"], codingPath: codingPath)
        try validateFileChangeFilter(members["changeFilter"], codingPath: codingPath)
    }

    private static func validateFileChangeFilter(
        _ value: BridgeProductJSONValue?, codingPath: [any CodingKey]
    ) throws {
        guard let changeFilter = value,
            case .object(let filterMembers) = changeFilter,
            case .string(let filterKind)? = filterMembers["kind"]
        else {
            throw BridgeProductContractDecoding.invalidValue(
                "File scope requires a change filter",
                codingPath: codingPath
            )
        }
        switch filterKind {
        case "none":
            guard Set(filterMembers.keys) == ["kind"] else {
                throw BridgeProductContractDecoding.invalidValue(
                    "None change filter has no other members",
                    codingPath: codingPath
                )
            }
        case "changes":
            guard Set(filterMembers.keys) == ["kind", "baseline", "kinds"],
                case .object(let baselineMembers)? = filterMembers["baseline"],
                Set(baselineMembers.keys) == ["kind"],
                case .string(let baselineKind)? = baselineMembers["kind"],
                ["uncommitted", "originDefaultMergeBase"].contains(baselineKind),
                case .array(let kinds)? = filterMembers["kinds"]
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Invalid File change filter baseline or kinds",
                    codingPath: codingPath
                )
            }
            let allowedKinds: Set<String> = ["added", "modified", "renamed", "deleted", "copied"]
            var seenKinds: Set<String> = []
            for value in kinds {
                guard case .string(let changeKind) = value,
                    allowedKinds.contains(changeKind),
                    seenKinds.insert(changeKind).inserted
                else {
                    throw BridgeProductContractDecoding.invalidValue(
                        "Invalid or repeated File change kind",
                        codingPath: codingPath
                    )
                }
            }
        default:
            throw BridgeProductContractDecoding.invalidValue(
                "Unknown File change filter",
                codingPath: codingPath
            )
        }
    }

    private static func validatePrefix(
        _ value: BridgeProductJSONValue?, codingPath: [any CodingKey]
    ) throws {
        guard let value else { return }
        guard case .string(let prefix) = value else {
            throw BridgeProductContractDecoding.invalidValue("Invalid scope prefix", codingPath: codingPath)
        }
        try BridgeProductContractDecoding.validateDisplayPath(prefix, codingPath: codingPath)
    }

    private static func validateInterestGroups(
        _ value: BridgeProductJSONValue,
        itemKey: String,
        codingPath: [any CodingKey]
    ) throws {
        guard case .array(let groups) = value, groups.count <= 64 else {
            throw BridgeProductContractDecoding.invalidValue(
                "View interests exceed the group ceiling", codingPath: codingPath
            )
        }
        var seenItems: Set<Data> = []
        for group in groups {
            guard case .object(let members) = group,
                Set(members.keys) == ["lane", itemKey],
                case .string(let lane)? = members["lane"],
                BridgeProductDemandLane(rawValue: lane) != nil,
                case .array(let items)? = members[itemKey],
                items.count <= BridgeProductWireContract.maximumSubscriptionInterestItemCount
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Invalid view interest group", codingPath: codingPath
                )
            }
            for value in items {
                guard case .string(let item) = value, seenItems.insert(Data(item.utf8)).inserted else {
                    throw BridgeProductContractDecoding.invalidValue(
                        "View interest items must be unique strings", codingPath: codingPath
                    )
                }
                if itemKey == "paths" {
                    try BridgeProductContractDecoding.validateDisplayPath(item, codingPath: codingPath)
                } else {
                    try BridgeProductReviewInterestIdentity.validate(item, codingPath: codingPath)
                }
            }
        }
        try BridgeProductContractDecoding.validateCollectionCount(
            seenItems.count,
            maximum: BridgeProductWireContract.maximumSubscriptionInterestItemCount,
            name: "view interest items",
            codingPath: codingPath
        )
    }
}

struct BridgeProductViewScopeRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case domain
        case handle
        case incarnation
        case kind
        case scope
        case scopeRevision
        case subscriptionId
        case subscriptionKind
    }

    let correlation: BridgeProductControlCorrelation
    let domain: String
    let handle: String
    let incarnation: String
    let scope: BridgeProductJSONValue
    let scopeRevision: Int
    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductControlCorrelation.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.setScope request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.setScope" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.setScope request kind",
                codingPath: decoder.codingPath
            )
        }
        correlation = try BridgeProductControlCorrelation(from: decoder)
        domain = try container.decode(String.self, forKey: .domain)
        handle = try container.decode(String.self, forKey: .handle)
        incarnation = try container.decode(String.self, forKey: .incarnation)
        scope = try container.decode(BridgeProductJSONValue.self, forKey: .scope)
        try BridgeProductViewScopeContract.validate(scope, codingPath: decoder.codingPath)
        scopeRevision = try container.decode(Int.self, forKey: .scopeRevision)
        subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        subscriptionKind = try container.decode(BridgeProductSubscriptionKind.self, forKey: .subscriptionKind)
        guard case .object(let scopeMembers) = scope,
            case .string(let scopeKind)? = scopeMembers["kind"],
            scopeKind
                == (subscriptionKind == .fileMetadata
                    ? "file" : subscriptionKind == .reviewMetadata ? "review" : "comment")
        else {
            throw BridgeProductContractDecoding.invalidValue(
                "View scope kind differs from subscription kind", codingPath: decoder.codingPath
            )
        }
        try BridgeProductContractDecoding.validateIdentifier(domain, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(handle, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(incarnation, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            scopeRevision,
            name: "scopeRevision",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try correlation.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(handle, forKey: .handle)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode("subscription.setScope", forKey: .kind)
        try container.encode(scope, forKey: .scope)
        try container.encode(scopeRevision, forKey: .scopeRevision)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(subscriptionKind, forKey: .subscriptionKind)
    }
}

struct BridgeProductViewResnapshotRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case domain
        case handle
        case incarnation
        case kind
        case scopeRevision
        case subscriptionId
        case subscriptionKind
    }

    let correlation: BridgeProductControlCorrelation
    let domain: String
    let handle: String
    let incarnation: String
    let scopeRevision: Int
    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductControlCorrelation.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription.resnapshot request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.resnapshot" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.resnapshot request kind",
                codingPath: decoder.codingPath
            )
        }
        correlation = try BridgeProductControlCorrelation(from: decoder)
        domain = try container.decode(String.self, forKey: .domain)
        handle = try container.decode(String.self, forKey: .handle)
        incarnation = try container.decode(String.self, forKey: .incarnation)
        scopeRevision = try container.decode(Int.self, forKey: .scopeRevision)
        subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        subscriptionKind = try container.decode(BridgeProductSubscriptionKind.self, forKey: .subscriptionKind)
        try BridgeProductContractDecoding.validateIdentifier(domain, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(handle, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(incarnation, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            scopeRevision,
            name: "scopeRevision",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try correlation.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(handle, forKey: .handle)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode("subscription.resnapshot", forKey: .kind)
        try container.encode(scopeRevision, forKey: .scopeRevision)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(subscriptionKind, forKey: .subscriptionKind)
    }
}

/// Cumulative acknowledgement is keyed by view handle and advances credits as
/// soon as a part is received, independently of atomic batch installation.
struct BridgeProductViewAcknowledgementRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case domain
        case handle
        case incarnation
        case kind
        case paneSessionId
        case receivedThroughDeliverySequence
        case subscriptionId
        case wireVersion
        case workerInstanceId
    }

    let domain: String
    let handle: String
    let incarnation: String
    let paneSessionId: String
    let receivedThroughDeliverySequence: Int
    let subscriptionId: String
    let wireVersion: Int
    let workerInstanceId: String

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "subscription.acknowledge request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.acknowledge" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.acknowledge request kind",
                codingPath: decoder.codingPath
            )
        }
        domain = try container.decode(String.self, forKey: .domain)
        handle = try container.decode(String.self, forKey: .handle)
        incarnation = try container.decode(String.self, forKey: .incarnation)
        paneSessionId = try container.decode(String.self, forKey: .paneSessionId)
        receivedThroughDeliverySequence = try container.decode(Int.self, forKey: .receivedThroughDeliverySequence)
        subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        wireVersion = try container.decode(Int.self, forKey: .wireVersion)
        workerInstanceId = try container.decode(String.self, forKey: .workerInstanceId)
        try BridgeProductContractDecoding.validateIdentifier(domain, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(handle, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(incarnation, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(paneSessionId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validatePositive(
            receivedThroughDeliverySequence,
            name: "receivedThroughDeliverySequence",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateWireVersion(wireVersion, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(workerInstanceId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(handle, forKey: .handle)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode("subscription.acknowledge", forKey: .kind)
        try container.encode(paneSessionId, forKey: .paneSessionId)
        try container.encode(receivedThroughDeliverySequence, forKey: .receivedThroughDeliverySequence)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(wireVersion, forKey: .wireVersion)
        try container.encode(workerInstanceId, forKey: .workerInstanceId)
    }
}

/// E4 settlement acknowledges native acceptance of the desired view operation.
/// The batch completion remains the separate installation barrier.
struct BridgeProductViewAcceptedResponse: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case scope = "subscription.scopeAccepted"
        case resnapshot = "subscription.resnapshotAccepted"
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case domain
        case handle
        case incarnation
        case kind
        case scopeRevision
        case subscriptionId
        case subscriptionKind
    }

    let correlation: BridgeProductControlCorrelation
    let domain: String
    let handle: String
    let incarnation: String
    let kind: Kind
    let scopeRevision: Int
    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind

    init(correlating request: BridgeProductViewScopeRequest) {
        correlation = request.correlation
        domain = request.domain
        handle = request.handle
        incarnation = request.incarnation
        kind = .scope
        scopeRevision = request.scopeRevision
        subscriptionId = request.subscriptionId
        subscriptionKind = request.subscriptionKind
    }

    init(correlating request: BridgeProductViewResnapshotRequest) {
        correlation = request.correlation
        domain = request.domain
        handle = request.handle
        incarnation = request.incarnation
        kind = .resnapshot
        scopeRevision = request.scopeRevision
        subscriptionId = request.subscriptionId
        subscriptionKind = request.subscriptionKind
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductControlCorrelation.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "subscription view accepted response"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        correlation = try BridgeProductControlCorrelation(from: decoder)
        domain = try container.decode(String.self, forKey: .domain)
        handle = try container.decode(String.self, forKey: .handle)
        incarnation = try container.decode(String.self, forKey: .incarnation)
        kind = try container.decode(Kind.self, forKey: .kind)
        scopeRevision = try container.decode(Int.self, forKey: .scopeRevision)
        subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        subscriptionKind = try container.decode(BridgeProductSubscriptionKind.self, forKey: .subscriptionKind)
        try BridgeProductContractDecoding.validateIdentifier(domain, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(handle, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(incarnation, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            scopeRevision,
            name: "scopeRevision",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try correlation.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(handle, forKey: .handle)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode(kind, forKey: .kind)
        try container.encode(scopeRevision, forKey: .scopeRevision)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(subscriptionKind, forKey: .subscriptionKind)
    }
}

/// The escape reply mirrors the cumulative credit position. Repeating the
/// identical request returns the identical reply without consuming another slot.
struct BridgeProductViewAcknowledgedResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case domain
        case handle
        case incarnation
        case kind
        case paneSessionId
        case receivedThroughDeliverySequence
        case subscriptionId
        case wireVersion
        case workerInstanceId
    }

    let domain: String
    let handle: String
    let incarnation: String
    let paneSessionId: String
    let receivedThroughDeliverySequence: Int
    let subscriptionId: String
    let wireVersion: Int
    let workerInstanceId: String

    init(correlating request: BridgeProductViewAcknowledgementRequest) {
        domain = request.domain
        handle = request.handle
        incarnation = request.incarnation
        paneSessionId = request.paneSessionId
        receivedThroughDeliverySequence = request.receivedThroughDeliverySequence
        subscriptionId = request.subscriptionId
        wireVersion = request.wireVersion
        workerInstanceId = request.workerInstanceId
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "subscription.acknowledged response"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.acknowledged" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.acknowledged response kind",
                codingPath: decoder.codingPath
            )
        }
        domain = try container.decode(String.self, forKey: .domain)
        handle = try container.decode(String.self, forKey: .handle)
        incarnation = try container.decode(String.self, forKey: .incarnation)
        paneSessionId = try container.decode(String.self, forKey: .paneSessionId)
        receivedThroughDeliverySequence = try container.decode(Int.self, forKey: .receivedThroughDeliverySequence)
        subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        wireVersion = try container.decode(Int.self, forKey: .wireVersion)
        workerInstanceId = try container.decode(String.self, forKey: .workerInstanceId)
        try BridgeProductContractDecoding.validateIdentifier(domain, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(handle, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(incarnation, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(paneSessionId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validatePositive(
            receivedThroughDeliverySequence,
            name: "receivedThroughDeliverySequence",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateWireVersion(wireVersion, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(workerInstanceId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(handle, forKey: .handle)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode("subscription.acknowledged", forKey: .kind)
        try container.encode(paneSessionId, forKey: .paneSessionId)
        try container.encode(receivedThroughDeliverySequence, forKey: .receivedThroughDeliverySequence)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(wireVersion, forKey: .wireVersion)
        try container.encode(workerInstanceId, forKey: .workerInstanceId)
    }
}
