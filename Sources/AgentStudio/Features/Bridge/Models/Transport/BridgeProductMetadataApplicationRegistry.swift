import Foundation

enum BridgeProductMetadataApplicationRegistryError: Error, Equatable {
    case duplicateKind(BridgeProductSubscriptionKind)
    case typeErasureMismatch
    case unknownKind(BridgeProductSubscriptionKind)
}

struct BridgeMetadataApplicationTelemetryDescriptor: Equatable, Sendable {
    let applicationName: String
}

/// E3 registration identifies an application and decodes its static options.
/// E4 owns changing view scope; sealed batches own metadata publication.
protocol BridgeProductMetadataApplicationProtocol: SendableMetatype {
    associatedtype SubscriptionOptions: Codable, Equatable, Sendable

    static var kind: BridgeProductSubscriptionKind { get }
    static var surface: BridgeProductSurface { get }
    static var telemetryDescriptor: BridgeMetadataApplicationTelemetryDescriptor { get }
}

struct BridgeProductMetadataApplicationValue: Equatable, Sendable {
    let applicationKind: BridgeProductSubscriptionKind
    let encodedValue: Data
}

struct AnyBridgeProductMetadataApplicationProtocol: Sendable {
    let kind: BridgeProductSubscriptionKind
    let surface: BridgeProductSurface
    let telemetryDescriptor: BridgeMetadataApplicationTelemetryDescriptor

    private let decodeSubscriptionOptionsClosure: @Sendable (Data) throws -> BridgeProductMetadataApplicationValue

    init<TApplication: BridgeProductMetadataApplicationProtocol>(_: TApplication.Type) {
        let applicationKind = TApplication.kind
        self.kind = applicationKind
        self.surface = TApplication.surface
        self.telemetryDescriptor = TApplication.telemetryDescriptor
        self.decodeSubscriptionOptionsClosure = { encodedOptions in
            let options = try JSONDecoder().decode(TApplication.SubscriptionOptions.self, from: encodedOptions)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return BridgeProductMetadataApplicationValue(
                applicationKind: applicationKind,
                encodedValue: try encoder.encode(options)
            )
        }
    }

    func decodeSubscriptionOptions(from encodedOptions: Data) throws -> BridgeProductMetadataApplicationValue {
        try decodeSubscriptionOptionsClosure(encodedOptions)
    }
}

struct BridgeProductMetadataApplicationRegistry: Sendable {
    let registrations: [AnyBridgeProductMetadataApplicationProtocol]
    private let registrationByKind: [BridgeProductSubscriptionKind: AnyBridgeProductMetadataApplicationProtocol]

    init(registrations: [AnyBridgeProductMetadataApplicationProtocol]) throws {
        var registrationByKind: [BridgeProductSubscriptionKind: AnyBridgeProductMetadataApplicationProtocol] = [:]
        for registration in registrations {
            guard registrationByKind[registration.kind] == nil else {
                throw BridgeProductMetadataApplicationRegistryError.duplicateKind(registration.kind)
            }
            registrationByKind[registration.kind] = registration
        }
        self.registrations = registrations
        self.registrationByKind = registrationByKind
    }

    func registration(
        for kind: BridgeProductSubscriptionKind
    ) throws -> AnyBridgeProductMetadataApplicationProtocol {
        guard let registration = registrationByKind[kind] else {
            throw BridgeProductMetadataApplicationRegistryError.unknownKind(kind)
        }
        return registration
    }
}

struct BridgeProductEmptySubscriptionOptions: Codable, Equatable, Sendable {
    init() {}

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: [],
            contract: "empty subscription options"
        )
        self.init()
    }
}

struct BridgeProductFileMetadataSubscriptionOptions: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case source }

    let source: BridgeProductFileSourceSpec

    init(source: BridgeProductFileSourceSpec) { self.source = source }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "file metadata subscription options"
        )
        source = try decoder.container(keyedBy: CodingKeys.self).decode(
            BridgeProductFileSourceSpec.self,
            forKey: .source
        )
    }
}

struct BridgeProductFileMetadataInterestState: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case interests, pathScope }

    let interests: [BridgeProductFileMetadataInterestStateGroup]
    let pathScope: [String]

    init(interests: [BridgeProductFileMetadataInterestStateGroup], pathScope: [String]) {
        self.interests = interests
        self.pathScope = pathScope
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "file metadata interest state"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interests = try container.decode([BridgeProductFileMetadataInterestStateGroup].self, forKey: .interests)
        pathScope = try container.decode([String].self, forKey: .pathScope)
    }
}

struct BridgeProductReviewMetadataInterestState: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case interests }

    let interests: [BridgeProductReviewMetadataInterestStateGroup]

    init(interests: [BridgeProductReviewMetadataInterestStateGroup]) { self.interests = interests }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "review metadata interest state"
        )
        interests = try decoder.container(keyedBy: CodingKeys.self).decode(
            [BridgeProductReviewMetadataInterestStateGroup].self,
            forKey: .interests
        )
    }
}

enum BridgeProductFileAnnotationsMetadataApplication: BridgeProductMetadataApplicationProtocol {
    typealias SubscriptionOptions = BridgeProductEmptySubscriptionOptions
    static let kind = BridgeProductSubscriptionKind.fileAnnotations
    static let surface = BridgeProductSurface.file
    static let telemetryDescriptor = BridgeMetadataApplicationTelemetryDescriptor(
        applicationName: "worktree-annotations")
}

enum BridgeProductFileMetadataApplication: BridgeProductMetadataApplicationProtocol {
    typealias SubscriptionOptions = BridgeProductFileMetadataSubscriptionOptions
    static let kind = BridgeProductSubscriptionKind.fileMetadata
    static let surface = BridgeProductSurface.file
    static let telemetryDescriptor = BridgeMetadataApplicationTelemetryDescriptor(applicationName: "worktree-file")
}

enum BridgeProductReviewAnnotationsMetadataApplication: BridgeProductMetadataApplicationProtocol {
    typealias SubscriptionOptions = BridgeProductEmptySubscriptionOptions
    static let kind = BridgeProductSubscriptionKind.reviewAnnotations
    static let surface = BridgeProductSurface.review
    static let telemetryDescriptor = BridgeMetadataApplicationTelemetryDescriptor(
        applicationName: "worktree-annotations")
}

enum BridgeProductReviewMetadataApplication: BridgeProductMetadataApplicationProtocol {
    typealias SubscriptionOptions = BridgeProductEmptySubscriptionOptions
    static let kind = BridgeProductSubscriptionKind.reviewMetadata
    static let surface = BridgeProductSurface.review
    static let telemetryDescriptor = BridgeMetadataApplicationTelemetryDescriptor(applicationName: "review")
}
