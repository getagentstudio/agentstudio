import Foundation

enum BridgeProductDemandLane: String, Codable, Equatable, Sendable {
    case foreground
    case active
    case visible
    case nearby
    case speculative
    case idle
}

struct BridgeProductSubscriptionKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    static let fileAnnotations = Self(uncheckedRawValue: "file.annotations")
    static let fileMetadata = Self(uncheckedRawValue: "file.metadata")
    static let reviewAnnotations = Self(uncheckedRawValue: "review.annotations")
    static let reviewMetadata = Self(uncheckedRawValue: "review.metadata")

    let rawValue: String

    init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid Bridge product subscription kind",
                codingPath: []
            )
        }
        self.rawValue = rawValue
    }

    init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var surface: BridgeProductSurface? {
        try? BridgeProductMetadataApplicationRegistry.product.registration(for: self).surface
    }

    private init(uncheckedRawValue: String) {
        self.rawValue = uncheckedRawValue
    }

    private static func isValid(_ rawValue: String) -> Bool {
        guard
            !rawValue.isEmpty,
            rawValue.utf8.count <= BridgeProductWireContract.maximumIdentifierByteLength
        else { return false }
        let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            guard let first = segment.utf8.first, first >= 97, first <= 122 else { return false }
            return segment.utf8.dropFirst().allSatisfy { byte in
                (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
            }
        }
    }
}

struct BridgeProductFileSourceSpec: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cwdScope
        case freshness
        case includeStatuses
        case repoId
        case rootPathToken
        case worktreeId
    }

    let cwdScope: String?
    let includeStatuses: Bool
    let repoId: String
    let rootPathToken: String
    let worktreeId: String

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "file source spec"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cwdScope = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .cwdScope,
            from: container,
            codingPath: decoder.codingPath
        )
        guard try container.decode(String.self, forKey: .freshness) == "live" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Bridge product file source freshness must be live",
                codingPath: decoder.codingPath
            )
        }
        self.includeStatuses = try container.decode(Bool.self, forKey: .includeStatuses)
        self.repoId = try container.decode(String.self, forKey: .repoId)
        self.rootPathToken = try container.decode(String.self, forKey: .rootPathToken)
        self.worktreeId = try container.decode(String.self, forKey: .worktreeId)

        if let cwdScope {
            try BridgeProductContractDecoding.validateDisplayPath(cwdScope, codingPath: decoder.codingPath)
        }
        try BridgeProductContractDecoding.validateUUID(repoId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateOpaqueReference(rootPathToken, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateUUID(worktreeId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cwdScope, forKey: .cwdScope)
        try container.encode("live", forKey: .freshness)
        try container.encode(includeStatuses, forKey: .includeStatuses)
        try container.encode(repoId, forKey: .repoId)
        try container.encode(rootPathToken, forKey: .rootPathToken)
        try container.encode(worktreeId, forKey: .worktreeId)
    }
}

struct BridgeProductSubscriptionRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey { case subscriptionKind }

    let subscriptionKind: BridgeProductSubscriptionKind
    private let options: BridgeProductMetadataApplicationValue
    private let registeredSurface: BridgeProductSurface

    private init(
        subscriptionKind: BridgeProductSubscriptionKind,
        options: BridgeProductMetadataApplicationValue,
        registeredSurface: BridgeProductSurface
    ) {
        self.subscriptionKind = subscriptionKind
        self.options = options
        self.registeredSurface = registeredSurface
    }

    var surface: BridgeProductSurface { registeredSurface }

    var fileMetadataSource: BridgeProductFileSourceSpec? {
        guard subscriptionKind == .fileMetadata,
            let decoded = try? JSONDecoder().decode(
                BridgeProductFileMetadataSubscriptionOptions.self,
                from: options.encodedValue
            )
        else { return nil }
        return decoded.source
    }

    init(from decoder: Decoder) throws {
        let rawValue = try BridgeProductJSONValue(from: decoder)
        guard case .object(var members) = rawValue,
            case .string(let rawKind)? = members.removeValue(forKey: CodingKeys.subscriptionKind.rawValue),
            let kind = BridgeProductSubscriptionKind(rawValue: rawKind)
        else {
            throw BridgeProductContractDecoding.invalidValue(
                "Bridge product subscription request requires a valid subscriptionKind",
                codingPath: decoder.codingPath
            )
        }
        let registration = try BridgeProductMetadataApplicationRegistry.product.registration(for: kind)
        let encodedOptions = try JSONEncoder.bridgeProductSorted.encode(BridgeProductJSONValue.object(members))
        self.subscriptionKind = kind
        self.options = try registration.decodeSubscriptionOptions(from: encodedOptions)
        self.registeredSurface = registration.surface
    }

    func encode(to encoder: Encoder) throws {
        guard
            case .object(var members) = try JSONDecoder().decode(
                BridgeProductJSONValue.self,
                from: options.encodedValue
            )
        else {
            throw BridgeProductMetadataApplicationRegistryError.typeErasureMismatch
        }
        members[CodingKeys.subscriptionKind.rawValue] = .string(subscriptionKind.rawValue)
        try BridgeProductJSONValue.object(members).encode(to: encoder)
    }

    static let fileAnnotations = try! registered(
        kind: .fileAnnotations,
        options: BridgeProductEmptySubscriptionOptions()
    )

    static func fileMetadata(_ source: BridgeProductFileSourceSpec) -> Self {
        try! registered(
            kind: .fileMetadata,
            options: BridgeProductFileMetadataSubscriptionOptions(source: source)
        )
    }

    static let reviewAnnotations = try! registered(
        kind: .reviewAnnotations,
        options: BridgeProductEmptySubscriptionOptions()
    )

    static let reviewMetadata = try! registered(
        kind: .reviewMetadata,
        options: BridgeProductEmptySubscriptionOptions()
    )

    private static func registered<TOptions: Encodable>(
        kind: BridgeProductSubscriptionKind,
        options: TOptions
    ) throws -> Self {
        let registration = try BridgeProductMetadataApplicationRegistry.product.registration(for: kind)
        return try registered(registration: registration, options: options)
    }

    static func registered<TOptions: Encodable>(
        registration: AnyBridgeProductMetadataApplicationProtocol,
        options: TOptions
    ) throws -> Self {
        let erasedOptions = try registration.decodeSubscriptionOptions(
            from: JSONEncoder.bridgeProductSorted.encode(options)
        )
        return Self(
            subscriptionKind: registration.kind,
            options: erasedOptions,
            registeredSurface: registration.surface
        )
    }
}

struct BridgeProductFileSourceIdentity: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case repoId
        case rootRevisionToken
        case sourceCursor
        case sourceId
        case subscriptionGeneration
        case worktreeId
    }

    let repoId: String
    let rootRevisionToken: String?
    let sourceCursor: String
    let sourceId: String
    let subscriptionGeneration: Int
    let worktreeId: String

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "file source identity"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.repoId = try container.decode(String.self, forKey: .repoId)
        self.rootRevisionToken = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .rootRevisionToken,
            from: container,
            codingPath: decoder.codingPath
        )
        self.sourceCursor = try container.decode(String.self, forKey: .sourceCursor)
        self.sourceId = try container.decode(String.self, forKey: .sourceId)
        self.subscriptionGeneration = try container.decode(Int.self, forKey: .subscriptionGeneration)
        self.worktreeId = try container.decode(String.self, forKey: .worktreeId)

        try validate(codingPath: decoder.codingPath)
    }

    private func validate(codingPath: [any CodingKey]) throws {
        try BridgeProductContractDecoding.validateUUID(repoId, codingPath: codingPath)
        if let rootRevisionToken {
            try BridgeProductContractDecoding.validateOpaqueReference(
                rootRevisionToken,
                codingPath: codingPath
            )
        }
        try BridgeProductContractDecoding.validateOpaqueReference(sourceCursor, codingPath: codingPath)
        try BridgeProductContractDecoding.validateIdentifier(sourceId, codingPath: codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            subscriptionGeneration,
            name: "subscriptionGeneration",
            codingPath: codingPath
        )
        try BridgeProductContractDecoding.validateUUID(worktreeId, codingPath: codingPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repoId, forKey: .repoId)
        try container.encode(rootRevisionToken, forKey: .rootRevisionToken)
        try container.encode(sourceCursor, forKey: .sourceCursor)
        try container.encode(sourceId, forKey: .sourceId)
        try container.encode(subscriptionGeneration, forKey: .subscriptionGeneration)
        try container.encode(worktreeId, forKey: .worktreeId)
    }
}

extension JSONEncoder {
    static var bridgeProductSorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
