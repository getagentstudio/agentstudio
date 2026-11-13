import Foundation

/// Forge identity is independent of any local repository registration.
package struct ForgePullRequestIdentity: Hashable, Sendable, Codable {
    package let host: String
    package let owner: String
    package let repository: String
    package let number: Int

    package init(host: String, owner: String, repository: String, number: Int) throws {
        let normalizedHost = host.lowercased()
        for value in [normalizedHost, owner, repository] {
            guard !value.isEmpty else { throw BridgeLinkIdentityError.emptyValue }
            guard value.utf8.count <= 255 else { throw BridgeLinkIdentityError.valueTooLong }
            guard !value.contains("/"), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            else { throw BridgeLinkIdentityError.invalidEncoding }
        }
        guard number > 0, number <= Int(Int32.max) else { throw BridgeLinkIdentityError.invalidPullRequestNumber }
        self.host = normalizedHost
        self.owner = owner
        self.repository = repository
        self.number = number
    }

    package init(from decoder: Decoder) throws {
        let container = try BridgeContractWire.decodeFields(
            decoder, required: ["host", "owner", "repository", "number"]
        )
        try self.init(
            host: container.decode(String.self, forKey: .host),
            owner: container.decode(String.self, forKey: .owner),
            repository: container.decode(String.self, forKey: .repository),
            number: container.decode(Int.self, forKey: .number)
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: BridgeContractWire.Key.self)
        try container.encode(host, forKey: .host)
        try container.encode(owner, forKey: .owner)
        try container.encode(repository, forKey: .repository)
        try container.encode(number, forKey: .number)
    }
}

package enum BridgeLinkItem: Hashable, Sendable, Codable {
    case worktree(WorktreeId)
    case pullRequest(ForgePullRequestIdentity)

    package init(from decoder: Decoder) throws {
        let container = try BridgeContractWire.decode(
            decoder,
            fieldsByKind: ["worktree": ["worktreeId"], "pullRequest": ["pullRequest"]]
        )
        switch try container.decode(String.self, forKey: .kind) {
        case "worktree": self = .worktree(try container.decode(WorktreeId.self, forKey: .worktreeId))
        case "pullRequest":
            self = .pullRequest(
                try container.decode(ForgePullRequestIdentity.self, forKey: .pullRequest)
            )
        default: throw BridgeContractWire.invalidKind(decoder)
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: BridgeContractWire.Key.self)
        switch self {
        case .worktree(let worktreeId):
            try container.encode("worktree", forKey: .kind)
            try container.encode(worktreeId, forKey: .worktreeId)
        case .pullRequest(let identity):
            try container.encode("pullRequest", forKey: .kind)
            try container.encode(identity, forKey: .pullRequest)
        }
    }
}
