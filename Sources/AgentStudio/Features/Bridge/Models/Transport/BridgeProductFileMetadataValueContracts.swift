import Foundation

enum BridgeProductFileChangeStatus: String, Codable, Equatable, Sendable {
    case added
    case deleted
    case modified
    case renamed
    case copied
    case typeChanged
    case unmerged
    case untracked
}

struct BridgeProductFileTreeRow: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case changeStatus
        case depth
        case fileId
        case fileClass
        case isDirectory
        case lineCount
        case name
        case parentPath
        case path
        case rowId
        case sizeBytes
    }

    let changeStatus: BridgeProductFileChangeStatus?
    let depth: Int
    let fileId: String?
    let fileClass: BridgeFileClass?
    let isDirectory: Bool
    let lineCount: Int?
    let name: String
    let parentPath: String?
    let path: String
    let rowId: String
    let sizeBytes: Int?

    init(
        changeStatus: BridgeProductFileChangeStatus?,
        depth: Int,
        fileId: String?,
        fileClass: BridgeFileClass?,
        isDirectory: Bool,
        lineCount: Int?,
        name: String,
        parentPath: String?,
        path: String,
        rowId: String,
        sizeBytes: Int?
    ) throws {
        self.changeStatus = changeStatus
        self.depth = depth
        self.fileId = fileId
        self.fileClass = fileClass
        self.isDirectory = isDirectory
        self.lineCount = lineCount
        self.name = name
        self.parentPath = parentPath
        self.path = path
        self.rowId = rowId
        self.sizeBytes = sizeBytes
        try validate(codingPath: [])
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "File metadata tree row"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.changeStatus = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeProductFileChangeStatus.self,
            forKey: .changeStatus,
            from: container,
            codingPath: decoder.codingPath
        )
        self.depth = try container.decode(Int.self, forKey: .depth)
        self.fileId = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .fileId,
            from: container,
            codingPath: decoder.codingPath
        )
        self.fileClass = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeFileClass.self,
            forKey: .fileClass,
            from: container,
            codingPath: decoder.codingPath
        )
        self.isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        self.lineCount = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self,
            forKey: .lineCount,
            from: container,
            codingPath: decoder.codingPath
        )
        self.name = try container.decode(String.self, forKey: .name)
        self.parentPath = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .parentPath,
            from: container,
            codingPath: decoder.codingPath
        )
        self.path = try container.decode(String.self, forKey: .path)
        self.rowId = try container.decode(String.self, forKey: .rowId)
        self.sizeBytes = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self,
            forKey: .sizeBytes,
            from: container,
            codingPath: decoder.codingPath
        )
        try validate(codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try validate(codingPath: encoder.codingPath)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(changeStatus, forKey: .changeStatus)
        try container.encode(depth, forKey: .depth)
        try container.encode(fileId, forKey: .fileId)
        try container.encode(fileClass, forKey: .fileClass)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encode(lineCount, forKey: .lineCount)
        try container.encode(name, forKey: .name)
        try container.encode(parentPath, forKey: .parentPath)
        try container.encode(path, forKey: .path)
        try container.encode(rowId, forKey: .rowId)
        try container.encode(sizeBytes, forKey: .sizeBytes)
    }

    private func validate(codingPath: [any CodingKey]) throws {
        try BridgeProductContractDecoding.validateNonnegative(depth, name: "depth", codingPath: codingPath)
        if let fileId {
            try BridgeProductContractDecoding.validateIdentifier(fileId, codingPath: codingPath)
        }
        if isDirectory {
            guard fileClass == nil else {
                throw BridgeProductContractDecoding.invalidValue(
                    "File metadata directory rows cannot carry a file class",
                    codingPath: codingPath
                )
            }
        } else {
            guard let fileClass, fileClass != .binary else {
                throw BridgeProductContractDecoding.invalidValue(
                    "File metadata file rows require a path-and-size-backed file class",
                    codingPath: codingPath
                )
            }
        }
        if let lineCount {
            try BridgeProductContractDecoding.validateNonnegative(
                lineCount,
                name: "lineCount",
                codingPath: codingPath
            )
        }
        try BridgeProductContractDecoding.validateDisplayPath(name, codingPath: codingPath)
        if let parentPath {
            try BridgeProductContractDecoding.validateDisplayPath(parentPath, codingPath: codingPath)
        }
        try BridgeProductContractDecoding.validateDisplayPath(path, codingPath: codingPath)
        try BridgeProductContractDecoding.validateIdentifier(rowId, codingPath: codingPath)
        if let sizeBytes {
            try BridgeProductContractDecoding.validateNonnegative(
                sizeBytes,
                name: "sizeBytes",
                codingPath: codingPath
            )
        }
    }
}
