import Foundation

package enum BridgeProductWireContract {
    static let version = 2
    package static let capabilityByteLength = 32
    static let requestMethod = "POST"
    static let commandRoute = "agentstudio://rpc/command"
    static let streamRoute = "agentstudio://rpc/stream"
    static let contentRoute = "agentstudio://rpc/content"
    package static let capabilityHeaderName = "X-AgentStudio-Bridge-Product-Capability"

    static let maximumIdentifierByteLength = 128
    static let maximumOpaqueReferenceByteLength = 256
    static let maximumDisplayPathByteLength = 4096
    static let maximumSafeMessageByteLength = 256
    static let maximumSafeInteger = 9_007_199_254_740_991
    static let maximumControlRequestSequence = maximumSafeInteger - 1
    static let maximumResumableStreamSequence = maximumSafeInteger - 2

    static let maximumActiveSubscriptionCount = 64
    static let maximumSubscriptionInterestCount = 64
    static let maximumSubscriptionInterestItemCount = 10_000
    static let maximumSubscriptionDeltaItemCount = 40_000
    static let maximumFileMetadataTreeWindowRowCount = 256
    static let maximumFileMetadataDeltaMemberCount = 256

    package static let maximumRequestBodyBytes = 256 * 1024
    static let maximumMetadataFrameBytes = 128 * 1024
    static let maximumContentControlBodyBytes = 16 * 1024
    static let maximumContentFrameBytes = 256 * 1024
    // Frame-body budget minus tag, sequence, offset, and correlation envelope.
    static let maximumContentDataPayloadBytes = maximumContentFrameBytes - (1 + 4 + 4 + 33)
    static let maximumQueuedStreamFrames = 64
    static let maximumQueuedStreamBytes = 4 * 1024 * 1024
    static let maximumContentStreamBytes = Int(UInt32.max)
    static let maximumContentBytes = 2 * 1024 * 1024
    static let maximumContentLines = 10_000
    static let terminalFrameReserve = 1
}

package enum BridgeProductSurface: String, Codable, Equatable, Hashable, Sendable {
    case review
    case file
}

enum BridgeProductRequestErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest = "invalid_request"
    case unauthorized
    case staleWorker = "stale_worker"
    case sequenceConflict = "sequence_conflict"
    case resyncRequired = "resync_required"
    case staleSource = "stale_source"
    case superseded
    case resultCapacityExhausted = "result_capacity_exhausted"
    case mutationWatchCapacityExhausted = "mutation_watch_capacity_exhausted"
    case payloadTooLarge = "payload_too_large"
    case unsupportedCall = "unsupported_call"
    case unsupportedSubscription = "unsupported_subscription"
    case unknownSubscription = "unknown_subscription"
    case unsupportedContent = "unsupported_content"
    case `internal`
}

enum BridgeProductResetReason: String, Codable, Equatable, Sendable {
    case producerOverflow = "producer_overflow"
    case sequenceGap = "sequence_gap"
    case staleSource = "stale_source"
    case snapshotRequired = "snapshot_required"
    /// Native ended the subscription because its surface floor advanced past the
    /// epoch it was admitted at; the worker already serves that surface at a newer
    /// epoch.
    case epochRetired = "epoch_retired"
}

struct BridgeProductControlCorrelation: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case paneSessionId
        case requestId
        case requestSequence
        case wireVersion
        case workerInstanceId
    }

    static let codingKeyNames = Set(CodingKeys.allCases.map(\.rawValue))

    let paneSessionId: String
    let requestId: String
    let requestSequence: Int
    let wireVersion: Int
    let workerInstanceId: String

    init(
        paneSessionId: String,
        requestId: String,
        requestSequence: Int,
        wireVersion: Int = BridgeProductWireContract.version,
        workerInstanceId: String
    ) throws {
        self.paneSessionId = paneSessionId
        self.requestId = requestId
        self.requestSequence = requestSequence
        self.wireVersion = wireVersion
        self.workerInstanceId = workerInstanceId
        try validate(codingPath: [])
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let paneSessionId = try container.decode(String.self, forKey: .paneSessionId)
        let requestId = try container.decode(String.self, forKey: .requestId)
        let requestSequence = try container.decode(Int.self, forKey: .requestSequence)
        let wireVersion = try container.decode(Int.self, forKey: .wireVersion)
        let workerInstanceId = try container.decode(String.self, forKey: .workerInstanceId)
        self.paneSessionId = paneSessionId
        self.requestId = requestId
        self.requestSequence = requestSequence
        self.wireVersion = wireVersion
        self.workerInstanceId = workerInstanceId
        try validate(codingPath: decoder.codingPath)
    }

    private func validate(codingPath: [any CodingKey]) throws {
        try BridgeProductContractDecoding.validateIdentifier(paneSessionId, codingPath: codingPath)
        try BridgeProductContractDecoding.validateIdentifier(requestId, codingPath: codingPath)
        try BridgeProductContractDecoding.validatePositive(
            requestSequence,
            name: "requestSequence",
            codingPath: codingPath
        )
        try BridgeProductContractDecoding.validateMaximum(
            requestSequence,
            maximum: BridgeProductWireContract.maximumControlRequestSequence,
            name: "requestSequence",
            codingPath: codingPath
        )
        try BridgeProductContractDecoding.validateWireVersion(wireVersion, codingPath: codingPath)
        try BridgeProductContractDecoding.validateIdentifier(workerInstanceId, codingPath: codingPath)
    }
}

struct BridgeProductSurfaceRequestIdentity: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case workerDerivationEpoch
    }

    static let codingKeyNames = BridgeProductControlCorrelation.codingKeyNames.union(
        CodingKeys.allCases.map(\.rawValue)
    )

    let correlation: BridgeProductControlCorrelation
    let workerDerivationEpoch: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.correlation = try BridgeProductControlCorrelation(from: decoder)
        self.workerDerivationEpoch = try container.decode(
            Int.self,
            forKey: .workerDerivationEpoch
        )
        try BridgeProductContractDecoding.validateNonnegative(
            workerDerivationEpoch,
            name: "workerDerivationEpoch",
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        try correlation.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workerDerivationEpoch, forKey: .workerDerivationEpoch)
    }
}

struct BridgeProductAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum BridgeProductContractDecoding {
    static func rejectUnknownKeys(
        from decoder: Decoder,
        allowedKeys: Set<String>,
        contract: String
    ) throws {
        let container = try decoder.container(keyedBy: BridgeProductAnyCodingKey.self)
        for key in container.allKeys where !allowedKeys.contains(key.stringValue) {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Unexpected \(contract) key"
            )
        }
    }

    static func decodeRequiredNullable<DecodedValue: Decodable, Key: CodingKey>(
        _ type: DecodedValue.Type,
        forKey key: Key,
        from container: KeyedDecodingContainer<Key>,
        codingPath: [any CodingKey]
    ) throws -> DecodedValue? {
        guard container.contains(key) else {
            throw DecodingError.keyNotFound(
                key,
                .init(codingPath: codingPath, debugDescription: "Missing required nullable field")
            )
        }
        guard try !container.decodeNil(forKey: key) else { return nil }
        return try container.decode(type, forKey: key)
    }

    static func decodeRequiredNull<Key: CodingKey>(
        forKey key: Key,
        from container: KeyedDecodingContainer<Key>,
        codingPath: [any CodingKey]
    ) throws {
        guard container.contains(key), try container.decodeNil(forKey: key) else {
            throw invalidValue("Bridge product empty value must be literal null", codingPath: codingPath)
        }
    }

    static func validateWireVersion(_ value: Int, codingPath: [any CodingKey]) throws {
        guard value == BridgeProductWireContract.version else {
            throw invalidValue("Bridge product wireVersion must be 2", codingPath: codingPath)
        }
    }

    static func validateIdentifier(_ value: String, codingPath: [any CodingKey]) throws {
        let identifierCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        guard
            !value.isEmpty,
            value.utf8.count <= BridgeProductWireContract.maximumIdentifierByteLength,
            value.unicodeScalars.allSatisfy(identifierCharacters.contains)
        else {
            throw invalidValue("Invalid Bridge product identifier", codingPath: codingPath)
        }
    }

    static func validateOpaqueReference(_ value: String, codingPath: [any CodingKey]) throws {
        guard
            !value.isEmpty,
            value.utf8.count <= BridgeProductWireContract.maximumOpaqueReferenceByteLength,
            value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e })
        else {
            throw invalidValue("Invalid Bridge product opaque reference", codingPath: codingPath)
        }
    }

    static func validateDisplayPath(_ value: String, codingPath: [any CodingKey]) throws {
        guard
            !value.isEmpty,
            value.utf8.count <= BridgeProductWireContract.maximumDisplayPathByteLength
        else {
            throw invalidValue("Invalid Bridge product display path", codingPath: codingPath)
        }
    }

    static func validateUUID(_ value: String, codingPath: [any CodingKey]) throws {
        let lowercaseValue = value.lowercased()
        let specialUUIDs = [
            "00000000-0000-0000-0000-000000000000",
            "ffffffff-ffff-ffff-ffff-ffffffffffff",
        ]
        if specialUUIDs.contains(lowercaseValue) { return }

        let bytes = Array(lowercaseValue.utf8)
        let hyphenOffsets: Set<Int> = [8, 13, 18, 23]
        let usesCanonicalHexAndHyphens = bytes.enumerated().allSatisfy { offset, byte in
            if hyphenOffsets.contains(offset) { return byte == 0x2d }
            return (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
        guard
            bytes.count == 36,
            usesCanonicalHexAndHyphens,
            (0x31...0x38).contains(bytes[14]),
            [UInt8(0x38), 0x39, 0x61, 0x62].contains(bytes[19])
        else {
            throw invalidValue("Invalid Bridge product UUID", codingPath: codingPath)
        }
    }

    static func validateSafeMessage(_ value: String, codingPath: [any CodingKey]) throws {
        guard
            !value.isEmpty,
            value.utf8.count <= BridgeProductWireContract.maximumSafeMessageByteLength
        else {
            throw invalidValue("Invalid Bridge product safe message", codingPath: codingPath)
        }
    }

    static func validateSHA256(_ value: String, codingPath: [any CodingKey]) throws {
        let lowercaseHexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        guard
            value.utf8.count == 64,
            value.unicodeScalars.allSatisfy(lowercaseHexCharacters.contains)
        else {
            throw invalidValue("Invalid Bridge product SHA-256 digest", codingPath: codingPath)
        }
    }

    static func validateNonemptyString(_ value: String, codingPath: [any CodingKey]) throws {
        guard !value.isEmpty else {
            throw invalidValue("Bridge product string must not be empty", codingPath: codingPath)
        }
    }

    static func validatePositive(_ value: Int, name: String, codingPath: [any CodingKey]) throws {
        guard value > 0, value <= BridgeProductWireContract.maximumSafeInteger else {
            throw invalidValue(
                "Bridge product \(name) must be a positive safe integer",
                codingPath: codingPath
            )
        }
    }

    static func validateNonnegative(_ value: Int, name: String, codingPath: [any CodingKey]) throws {
        guard value >= 0, value <= BridgeProductWireContract.maximumSafeInteger else {
            throw invalidValue(
                "Bridge product \(name) must be a nonnegative safe integer",
                codingPath: codingPath
            )
        }
    }

    static func validateMaximum(
        _ value: Int,
        maximum: Int,
        name: String,
        codingPath: [any CodingKey]
    ) throws {
        guard value <= maximum else {
            throw invalidValue("Bridge product \(name) exceeds its wire ceiling", codingPath: codingPath)
        }
    }

    static func validateCollectionCount(
        _ count: Int,
        maximum: Int,
        name: String,
        codingPath: [any CodingKey]
    ) throws {
        guard count <= maximum else {
            throw invalidValue("Bridge product \(name) exceeds its item ceiling", codingPath: codingPath)
        }
    }

    static func invalidValue(_ description: String, codingPath: [any CodingKey]) -> DecodingError {
        .dataCorrupted(.init(codingPath: codingPath, debugDescription: description))
    }
}
