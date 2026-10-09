import Foundation

enum BridgeProductFileBatchRowKind: String, Codable, Equatable, Sendable {
    case file
    case directory
    case deleted
}

/// The batch part's key is the canonical absolute document location. These
/// fields describe its current position and read capability, which may change
/// without changing that key.
struct BridgeProductFileBatchRow: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case changeStatus
        case descriptorOutcome
        case depth
        case displayKey
        case fileClass
        case fileId
        case kind
        case name
        case lineCount
        case oldPath
        case parentDisplayKey
        case readDescriptor
        case rowId
        case sizeBytes
        case sortKey
    }

    let changeStatus: BridgeProductFileChangeStatus?
    let descriptorOutcome: BridgeProductFileDescriptorReadyPayload?
    let depth: Int
    let displayKey: String
    let fileClass: BridgeFileClass?
    let fileId: String?
    let kind: BridgeProductFileBatchRowKind
    let name: String
    let lineCount: Int?
    let oldPath: String?
    let parentDisplayKey: String?
    let readDescriptor: BridgeProductFileContentDescriptor?
    let rowId: String
    let sizeBytes: Int?
    let sortKey: String

    init(
        sourceRow: BridgeWorktreeTreeRowMetadata,
        descriptorOutcome: BridgeProductFileDescriptorReadyPayload?
    ) throws {
        let parsedChangeStatus = sourceRow.changeStatus.flatMap(BridgeProductFileChangeStatus.init(rawValue:))
        guard sourceRow.changeStatus == nil || parsedChangeStatus != nil else {
            throw BridgeProductContractDecoding.invalidValue("Unknown File row change status", codingPath: [])
        }
        changeStatus = parsedChangeStatus
        self.descriptorOutcome = descriptorOutcome
        depth = sourceRow.depth
        displayKey = sourceRow.path
        fileClass = sourceRow.fileClass
        fileId = sourceRow.fileId
        kind = sourceRow.isDirectory ? .directory : .file
        name = sourceRow.name
        lineCount = sourceRow.lineCount
        oldPath = nil
        parentDisplayKey = sourceRow.parentPath
        if let descriptorOutcome, case .available(let descriptor) = descriptorOutcome.availability {
            readDescriptor = descriptor
        } else {
            readDescriptor = nil
        }
        rowId = sourceRow.rowId
        sizeBytes = sourceRow.sizeBytes
        sortKey = sourceRow.name
        try validate(codingPath: [])
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "File batch row"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changeStatus = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeProductFileChangeStatus.self,
            forKey: .changeStatus,
            from: container,
            codingPath: decoder.codingPath
        )
        descriptorOutcome = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeProductFileDescriptorReadyPayload.self,
            forKey: .descriptorOutcome,
            from: container,
            codingPath: decoder.codingPath
        )
        depth = try container.decode(Int.self, forKey: .depth)
        displayKey = try container.decode(String.self, forKey: .displayKey)
        fileClass = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeFileClass.self,
            forKey: .fileClass,
            from: container,
            codingPath: decoder.codingPath
        )
        fileId = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .fileId,
            from: container,
            codingPath: decoder.codingPath
        )
        kind = try container.decode(BridgeProductFileBatchRowKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        lineCount = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self,
            forKey: .lineCount,
            from: container,
            codingPath: decoder.codingPath
        )
        oldPath = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .oldPath,
            from: container,
            codingPath: decoder.codingPath
        )
        parentDisplayKey = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .parentDisplayKey,
            from: container,
            codingPath: decoder.codingPath
        )
        readDescriptor = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeProductFileContentDescriptor.self,
            forKey: .readDescriptor,
            from: container,
            codingPath: decoder.codingPath
        )
        rowId = try container.decode(String.self, forKey: .rowId)
        sizeBytes = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self,
            forKey: .sizeBytes,
            from: container,
            codingPath: decoder.codingPath
        )
        sortKey = try container.decode(String.self, forKey: .sortKey)
        try validate(codingPath: decoder.codingPath)
    }

    private func validate(codingPath: [any CodingKey]) throws {
        try BridgeProductContractDecoding.validateNonnegative(depth, name: "depth", codingPath: codingPath)
        try BridgeProductContractDecoding.validateDisplayPath(displayKey, codingPath: codingPath)
        try BridgeProductContractDecoding.validateSafeMessage(name, codingPath: codingPath)
        try BridgeProductContractDecoding.validateIdentifier(rowId, codingPath: codingPath)
        if let fileId {
            try BridgeProductContractDecoding.validateIdentifier(fileId, codingPath: codingPath)
        }
        try BridgeProductContractDecoding.validateDisplayPath(sortKey, codingPath: codingPath)
        if let oldPath {
            try BridgeProductContractDecoding.validateDisplayPath(oldPath, codingPath: codingPath)
        }
        if let parentDisplayKey {
            try BridgeProductContractDecoding.validateDisplayPath(parentDisplayKey, codingPath: codingPath)
        }
        if let lineCount {
            try BridgeProductContractDecoding.validateNonnegative(
                lineCount, name: "lineCount", codingPath: codingPath
            )
        }
        if let sizeBytes {
            try BridgeProductContractDecoding.validateNonnegative(
                sizeBytes, name: "sizeBytes", codingPath: codingPath
            )
        }
        if kind == .file {
            guard fileClass != nil else {
                throw BridgeProductContractDecoding.invalidValue(
                    "File rows require a file class",
                    codingPath: codingPath
                )
            }
            guard fileId != nil else {
                throw BridgeProductContractDecoding.invalidValue(
                    "File rows require their source file id", codingPath: codingPath
                )
            }
        } else {
            guard fileClass == nil, fileId == nil, sizeBytes == nil, lineCount == nil,
                descriptorOutcome == nil
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Directory and ghost rows cannot carry file extent facts",
                    codingPath: codingPath
                )
            }
        }
        let currentReadDescriptor: BridgeProductFileContentDescriptor?
        if let descriptorOutcome {
            guard descriptorOutcome.fileId == fileId else {
                throw BridgeProductContractDecoding.invalidValue(
                    "File descriptor outcome id differs from its row", codingPath: codingPath
                )
            }
            guard descriptorOutcome.rowId == rowId, descriptorOutcome.path == displayKey else {
                throw BridgeProductContractDecoding.invalidValue(
                    "File descriptor outcome identity differs from its row", codingPath: codingPath
                )
            }
            if case .available(let descriptor) = descriptorOutcome.availability {
                currentReadDescriptor = descriptor
            } else {
                currentReadDescriptor = nil
            }
        } else {
            currentReadDescriptor = nil
        }
        guard readDescriptor == currentReadDescriptor else {
            throw BridgeProductContractDecoding.invalidValue(
                "File read descriptor differs from its newest outcome", codingPath: codingPath
            )
        }
        guard kind == .file || readDescriptor == nil else {
            throw BridgeProductContractDecoding.invalidValue(
                "A directory or deleted File row cannot be opened",
                codingPath: codingPath
            )
        }
        guard kind != .deleted || changeStatus == .deleted || changeStatus == .renamed else {
            throw BridgeProductContractDecoding.invalidValue(
                "A deleted File row requires deleted or renamed status",
                codingPath: codingPath
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(changeStatus, forKey: .changeStatus)
        try container.encode(descriptorOutcome, forKey: .descriptorOutcome)
        try container.encode(depth, forKey: .depth)
        try container.encode(displayKey, forKey: .displayKey)
        try container.encode(fileClass, forKey: .fileClass)
        try container.encode(fileId, forKey: .fileId)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(lineCount, forKey: .lineCount)
        try container.encode(oldPath, forKey: .oldPath)
        try container.encode(parentDisplayKey, forKey: .parentDisplayKey)
        try container.encode(readDescriptor, forKey: .readDescriptor)
        try container.encode(rowId, forKey: .rowId)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(sortKey, forKey: .sortKey)
    }
}
