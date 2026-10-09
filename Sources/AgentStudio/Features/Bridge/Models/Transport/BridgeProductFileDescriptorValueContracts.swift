import Foundation

enum BridgeProductFileVirtualizedExtentKind: String, Codable, Equatable, Sendable {
    case exactLineCount
    case estimatedHeight
    case previewBounded
    case unavailable
}

enum BridgeProductFileDescriptorUnavailableReason: String, Codable, Equatable, Sendable {
    case unreadable
    case unsupportedEncoding = "unsupported_encoding"
    case outsideScope = "outside_scope"
}

enum BridgeProductFileEncoding: String, Codable, Equatable, Sendable {
    case utf8 = "utf-8"
}

enum BridgeProductFileTruncationKind: String, Codable, Equatable, Sendable {
    case complete = "none"
    case byteLimit
    case lineLimit
    case both
}

enum BridgeProductFileDescriptorAvailability: Codable, Equatable, Sendable {
    case available(BridgeProductFileContentDescriptor)
    case binary
    case unavailable(BridgeProductFileDescriptorUnavailableReason)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case availabilityKind
        case contentDescriptor
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .availabilityKind) {
        case "available":
            try Self.rejectUnknownKeys(from: decoder, allowedKeys: [.availabilityKind, .contentDescriptor])
            self = .available(
                try container.decode(BridgeProductFileContentDescriptor.self, forKey: .contentDescriptor)
            )
        case "binary":
            try Self.rejectUnknownKeys(from: decoder, allowedKeys: [.availabilityKind])
            self = .binary
        case "unavailable":
            try Self.rejectUnknownKeys(from: decoder, allowedKeys: [.availabilityKind, .reason])
            self = .unavailable(
                try container.decode(BridgeProductFileDescriptorUnavailableReason.self, forKey: .reason)
            )
        default:
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid File metadata descriptor availability",
                codingPath: decoder.codingPath
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let descriptor):
            try container.encode("available", forKey: .availabilityKind)
            try container.encode(descriptor, forKey: .contentDescriptor)
        case .binary:
            try container.encode("binary", forKey: .availabilityKind)
        case .unavailable(let reason):
            try container.encode("unavailable", forKey: .availabilityKind)
            try container.encode(reason, forKey: .reason)
        }
    }

    private static func rejectUnknownKeys(from decoder: Decoder, allowedKeys: Set<CodingKeys>) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(allowedKeys.map(\.rawValue)),
            contract: "File metadata descriptor availability"
        )
    }
}

struct BridgeProductFileDescriptorReadyPayload: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case availability
        case encoding
        case endsMidLine
        case endsWithNewline
        case estimatedContentHeightPixels
        case fileExtension
        case fileId
        case language
        case modifiedAtUnixMilliseconds
        case path
        case payloadByteCount
        case payloadLineCount
        case rowId
        case sizeBytes
        case source
        case totalLineCount
        case truncationKind
        case virtualizedExtentKind
    }

    static let codingKeyNames = Set(CodingKeys.allCases.map(\.rawValue))

    let availability: BridgeProductFileDescriptorAvailability
    let encoding: BridgeProductFileEncoding?
    let endsMidLine: Bool
    let endsWithNewline: Bool
    let estimatedContentHeightPixels: Double?
    let fileExtension: String?
    let fileId: String
    let language: String?
    let modifiedAtUnixMilliseconds: Int?
    let path: String
    let payloadByteCount: Int
    let payloadLineCount: Int
    let rowId: String
    let sizeBytes: Int
    let source: BridgeProductFileSourceIdentity
    let totalLineCount: Int?
    let truncationKind: BridgeProductFileTruncationKind
    let virtualizedExtentKind: BridgeProductFileVirtualizedExtentKind

    init(
        availability: BridgeProductFileDescriptorAvailability,
        encoding: BridgeProductFileEncoding?,
        endsMidLine: Bool,
        endsWithNewline: Bool,
        estimatedContentHeightPixels: Double?,
        fileExtension: String?,
        fileId: String,
        language: String?,
        modifiedAtUnixMilliseconds: Int?,
        path: String,
        payloadByteCount: Int,
        payloadLineCount: Int,
        rowId: String,
        sizeBytes: Int,
        source: BridgeProductFileSourceIdentity,
        totalLineCount: Int?,
        truncationKind: BridgeProductFileTruncationKind,
        virtualizedExtentKind: BridgeProductFileVirtualizedExtentKind
    ) throws {
        self.availability = availability
        self.encoding = encoding
        self.endsMidLine = endsMidLine
        self.endsWithNewline = endsWithNewline
        self.estimatedContentHeightPixels = estimatedContentHeightPixels
        self.fileExtension = fileExtension
        self.fileId = fileId
        self.language = language
        self.modifiedAtUnixMilliseconds = modifiedAtUnixMilliseconds
        self.path = path
        self.payloadByteCount = payloadByteCount
        self.payloadLineCount = payloadLineCount
        self.rowId = rowId
        self.sizeBytes = sizeBytes
        self.source = source
        self.totalLineCount = totalLineCount
        self.truncationKind = truncationKind
        self.virtualizedExtentKind = virtualizedExtentKind
        try validate(codingPath: [])
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Self.codingKeyNames,
            contract: "File metadata descriptor-ready payload"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.availability = try container.decode(
            BridgeProductFileDescriptorAvailability.self,
            forKey: .availability
        )
        self.encoding = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeProductFileEncoding.self,
            forKey: .encoding,
            from: container,
            codingPath: decoder.codingPath
        )
        self.endsMidLine = try container.decode(Bool.self, forKey: .endsMidLine)
        self.endsWithNewline = try container.decode(Bool.self, forKey: .endsWithNewline)
        self.estimatedContentHeightPixels = try Self.decodeNullableDouble(
            .estimatedContentHeightPixels,
            from: container,
            codingPath: decoder.codingPath
        )
        self.fileExtension = try Self.decodeNullableIdentifier(
            .fileExtension,
            from: container,
            codingPath: decoder.codingPath
        )
        self.fileId = try container.decode(String.self, forKey: .fileId)
        self.language = try Self.decodeNullableIdentifier(
            .language,
            from: container,
            codingPath: decoder.codingPath
        )
        self.modifiedAtUnixMilliseconds = try Self.decodeNullableInt(
            .modifiedAtUnixMilliseconds,
            from: container,
            codingPath: decoder.codingPath
        )
        self.path = try container.decode(String.self, forKey: .path)
        self.payloadByteCount = try container.decode(Int.self, forKey: .payloadByteCount)
        self.payloadLineCount = try container.decode(Int.self, forKey: .payloadLineCount)
        self.rowId = try container.decode(String.self, forKey: .rowId)
        self.sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
        self.source = try container.decode(BridgeProductFileSourceIdentity.self, forKey: .source)
        self.totalLineCount = try Self.decodeNullableInt(
            .totalLineCount,
            from: container,
            codingPath: decoder.codingPath
        )
        self.truncationKind = try container.decode(
            BridgeProductFileTruncationKind.self,
            forKey: .truncationKind
        )
        self.virtualizedExtentKind = try container.decode(
            BridgeProductFileVirtualizedExtentKind.self,
            forKey: .virtualizedExtentKind
        )
        try validate(codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(availability, forKey: .availability)
        try container.encode(encoding, forKey: .encoding)
        try container.encode(endsMidLine, forKey: .endsMidLine)
        try container.encode(endsWithNewline, forKey: .endsWithNewline)
        try container.encode(estimatedContentHeightPixels, forKey: .estimatedContentHeightPixels)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encode(fileId, forKey: .fileId)
        try container.encode(language, forKey: .language)
        try container.encode(modifiedAtUnixMilliseconds, forKey: .modifiedAtUnixMilliseconds)
        try container.encode(path, forKey: .path)
        try container.encode(payloadByteCount, forKey: .payloadByteCount)
        try container.encode(payloadLineCount, forKey: .payloadLineCount)
        try container.encode(rowId, forKey: .rowId)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(source, forKey: .source)
        try container.encode(totalLineCount, forKey: .totalLineCount)
        try container.encode(truncationKind, forKey: .truncationKind)
        try container.encode(virtualizedExtentKind, forKey: .virtualizedExtentKind)
    }

    private func validate(codingPath: [any CodingKey]) throws {
        if let estimatedContentHeightPixels,
            !estimatedContentHeightPixels.isFinite || estimatedContentHeightPixels < 0
        {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid nonnegative File metadata extent",
                codingPath: codingPath
            )
        }
        if let fileExtension {
            try BridgeProductContractDecoding.validateSafeMessage(fileExtension, codingPath: codingPath)
        }
        try BridgeProductContractDecoding.validateIdentifier(fileId, codingPath: codingPath)
        if let language {
            try BridgeProductContractDecoding.validateSafeMessage(language, codingPath: codingPath)
        }
        if let modifiedAtUnixMilliseconds {
            try BridgeProductContractDecoding.validateNonnegative(
                modifiedAtUnixMilliseconds,
                name: "modifiedAtUnixMilliseconds",
                codingPath: codingPath
            )
        }
        try BridgeProductContractDecoding.validateDisplayPath(path, codingPath: codingPath)
        try BridgeProductContractDecoding.validateIdentifier(rowId, codingPath: codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            sizeBytes,
            name: "sizeBytes",
            codingPath: codingPath
        )
        try validatePrefixFacts(codingPath: codingPath)
        try validateAvailability(codingPath: codingPath)
        try validateExtent(codingPath: codingPath)
    }

    private func validatePrefixFacts(codingPath: [any CodingKey]) throws {
        for (value, name, maximum) in [
            (
                payloadByteCount,
                "payloadByteCount",
                BridgeProductWireContract.maximumContentStreamBytes
            ),
            (payloadLineCount, "payloadLineCount", BridgeProductWireContract.maximumSafeInteger),
        ] {
            try BridgeProductContractDecoding.validateNonnegative(
                value,
                name: name,
                codingPath: codingPath
            )
            try BridgeProductContractDecoding.validateMaximum(
                value,
                maximum: maximum,
                name: name,
                codingPath: codingPath
            )
        }
        guard payloadByteCount <= sizeBytes,
            (payloadByteCount == 0) == (payloadLineCount == 0),
            totalLineCount.map({ $0 >= payloadLineCount }) ?? true,
            !(endsMidLine && endsWithNewline),
            payloadByteCount > 0 || (!endsMidLine && !endsWithNewline)
        else {
            throw BridgeProductContractDecoding.invalidValue(
                "File metadata prefix facts are inconsistent",
                codingPath: codingPath
            )
        }
        guard case .available(let descriptor) = availability else { return }
        switch truncationKind {
        case .complete:
            guard payloadByteCount == sizeBytes,
                !endsMidLine,
                totalLineCount.map({ $0 == payloadLineCount }) ?? true
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Untruncated File metadata must describe the complete source",
                    codingPath: codingPath
                )
            }
        case .byteLimit:
            guard sizeBytes > descriptor.window.maximumBytes,
                payloadByteCount < sizeBytes,
                payloadLineCount < descriptor.window.maximumLines
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Byte-limited File metadata must bind only the byte ceiling",
                    codingPath: codingPath
                )
            }
        case .lineLimit:
            guard payloadByteCount < sizeBytes,
                payloadLineCount == descriptor.window.maximumLines,
                endsWithNewline,
                !endsMidLine
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Line-limited File metadata must end at the line ceiling",
                    codingPath: codingPath
                )
            }
        case .both:
            guard sizeBytes > descriptor.window.maximumBytes,
                payloadByteCount < sizeBytes,
                payloadLineCount == descriptor.window.maximumLines
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Doubly truncated File metadata must bind both ceilings",
                    codingPath: codingPath
                )
            }
        }
    }

    private func validateAvailability(codingPath: [any CodingKey]) throws {
        switch availability {
        case .available(let descriptor):
            guard encoding == .utf8,
                descriptor.fileId == fileId,
                descriptor.source == source,
                descriptor.declaredByteLength == payloadByteCount,
                payloadByteCount <= descriptor.window.maximumBytes,
                payloadLineCount <= descriptor.window.maximumLines
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Available File metadata must bind its canonical UTF-8 descriptor",
                    codingPath: codingPath
                )
            }
        case .binary, .unavailable:
            guard encoding == nil,
                payloadByteCount == 0,
                payloadLineCount == 0,
                totalLineCount == nil,
                truncationKind == .complete,
                !endsMidLine,
                !endsWithNewline
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Unavailable File metadata cannot expose content facts",
                    codingPath: codingPath
                )
            }
        }
    }

    private func validateExtent(codingPath: [any CodingKey]) throws {
        guard estimatedContentHeightPixels == nil else {
            throw BridgeProductContractDecoding.invalidValue(
                "File metadata cannot fabricate estimated layout height",
                codingPath: codingPath
            )
        }
        switch availability {
        case .available:
            let expectedExtent: BridgeProductFileVirtualizedExtentKind =
                truncationKind == .complete ? .exactLineCount : .previewBounded
            guard virtualizedExtentKind == expectedExtent,
                expectedExtent != .exactLineCount || totalLineCount != nil
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Available File extent must agree with canonical truncation facts",
                    codingPath: codingPath
                )
            }
        case .binary, .unavailable:
            guard virtualizedExtentKind == .unavailable else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Bodyless File metadata requires an unavailable extent",
                    codingPath: codingPath
                )
            }
        }
    }

    private static func decodeNullableIdentifier(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>,
        codingPath: [any CodingKey]
    ) throws -> String? {
        let value = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: key,
            from: container,
            codingPath: codingPath
        )
        if let value {
            try BridgeProductContractDecoding.validateSafeMessage(value, codingPath: codingPath)
        }
        return value
    }

    private static func decodeNullableInt(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>,
        codingPath: [any CodingKey]
    ) throws -> Int? {
        let value = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self,
            forKey: key,
            from: container,
            codingPath: codingPath
        )
        if let value {
            try BridgeProductContractDecoding.validateNonnegative(
                value,
                name: key.rawValue,
                codingPath: codingPath
            )
        }
        return value
    }

    private static func decodeNullableDouble(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>,
        codingPath: [any CodingKey]
    ) throws -> Double? {
        let value = try BridgeProductContractDecoding.decodeRequiredNullable(
            Double.self,
            forKey: key,
            from: container,
            codingPath: codingPath
        )
        if let value, !value.isFinite || value < 0 {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid nonnegative File metadata extent",
                codingPath: codingPath
            )
        }
        return value
    }
}
