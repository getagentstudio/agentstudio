import Foundation

enum BridgeProductFileMemberStatus: String, Codable, Equatable, Sendable {
    case loading
    case ready
    case stale
    case failed
}

/// The reserved record for one File domain. A last-good summary stays present
/// when its status becomes stale or failed.
struct BridgeProductFileMemberStatusRecord: Codable, Equatable, Sendable {
    static let recordKey = "member-status"

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ahead
        case behind
        case branchName
        case kind
        case source
        case staged
        case status
        case unstaged
        case untracked
    }

    let ahead: Int?
    let behind: Int?
    let branchName: String?
    let source: BridgeProductFileSourceIdentity
    let staged: Int?
    let status: BridgeProductFileMemberStatus
    let unstaged: Int?
    let untracked: Int?

    init(source: BridgeProductFileSourceIdentity) {
        self.source = source
        status = .loading
        branchName = nil
        ahead = nil
        behind = nil
        staged = nil
        unstaged = nil
        untracked = nil
    }

    init(
        source: BridgeProductFileSourceIdentity,
        status: BridgeProductFileMemberStatus,
        branchName: String?,
        ahead: Int?,
        behind: Int?,
        staged: Int?,
        unstaged: Int?,
        untracked: Int?
    ) throws {
        self.source = source
        self.status = status
        self.branchName = branchName
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        try validate(codingPath: [])
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "File member-status record"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "memberStatus" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid File member-status kind", codingPath: decoder.codingPath)
        }
        ahead = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self, forKey: .ahead, from: container, codingPath: decoder.codingPath
        )
        behind = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self, forKey: .behind, from: container, codingPath: decoder.codingPath
        )
        branchName = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self, forKey: .branchName, from: container, codingPath: decoder.codingPath
        )
        source = try container.decode(BridgeProductFileSourceIdentity.self, forKey: .source)
        staged = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self, forKey: .staged, from: container, codingPath: decoder.codingPath
        )
        status = try container.decode(BridgeProductFileMemberStatus.self, forKey: .status)
        unstaged = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self, forKey: .unstaged, from: container, codingPath: decoder.codingPath
        )
        untracked = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self, forKey: .untracked, from: container, codingPath: decoder.codingPath
        )
        try validate(codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ahead, forKey: .ahead)
        try container.encode(behind, forKey: .behind)
        try container.encode(branchName, forKey: .branchName)
        try container.encode("memberStatus", forKey: .kind)
        try container.encode(source, forKey: .source)
        try container.encode(staged, forKey: .staged)
        try container.encode(status, forKey: .status)
        try container.encode(unstaged, forKey: .unstaged)
        try container.encode(untracked, forKey: .untracked)
    }

    private func validate(codingPath: [any CodingKey]) throws {
        if let branchName {
            try BridgeProductContractDecoding.validateSafeMessage(branchName, codingPath: codingPath)
        }
        for (name, value) in [
            ("ahead", ahead), ("behind", behind), ("staged", staged),
            ("unstaged", unstaged), ("untracked", untracked),
        ] {
            if let value {
                try BridgeProductContractDecoding.validateNonnegative(value, name: name, codingPath: codingPath)
            }
        }
    }
}

enum BridgeProductFileBatchRecord: Codable, Equatable, Sendable {
    case row(BridgeProductFileBatchRow)
    case memberStatus(BridgeProductFileMemberStatusRecord)

    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "file", "directory", "deleted": self = .row(try BridgeProductFileBatchRow(from: decoder))
        case "memberStatus": self = .memberStatus(try BridgeProductFileMemberStatusRecord(from: decoder))
        default:
            throw BridgeProductContractDecoding.invalidValue(
                "Unknown File batch record kind", codingPath: decoder.codingPath)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .row(let row): try row.encode(to: encoder)
        case .memberStatus(let status): try status.encode(to: encoder)
        }
    }
}
