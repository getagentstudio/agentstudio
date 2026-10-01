import Foundation

package enum WorktreeFetchSkipReason: String, Codable, Sendable {
    case noFetchFlag
    case noRemote
}

package enum WorktreeFetchFailureReason: String, Codable, Sendable {
    case networkFailure
    case authenticationFailure
    case gitLockHeld
    case gitLockUnidentified
    case processFailure
    case unknown
}

package enum WorktreeFetchStatus: Codable, Sendable, Equatable {
    case fetched(commit: String)
    case skipped(reason: WorktreeFetchSkipReason)
    case failed(reason: WorktreeFetchFailureReason)

    private enum CodingKeys: String, CodingKey {
        case status
        case commit
        case reason
    }

    private enum Status: String, Codable {
        case fetched
        case skipped
        case failed
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(Status.self, forKey: .status)
        let commit = try container.decodeIfPresent(String.self, forKey: .commit)

        switch status {
        case .fetched:
            guard let commit,
                try container.decodeIfPresent(WorktreeFetchSkipReason.self, forKey: .reason) == nil,
                try container.decodeIfPresent(WorktreeFetchFailureReason.self, forKey: .reason) == nil
            else {
                throw Self.invalidPayload(in: container)
            }
            self = .fetched(commit: commit)
        case .skipped:
            guard commit == nil,
                let reason = try container.decodeIfPresent(WorktreeFetchSkipReason.self, forKey: .reason)
            else {
                throw Self.invalidPayload(in: container)
            }
            self = .skipped(reason: reason)
        case .failed:
            guard commit == nil,
                let reason = try container.decodeIfPresent(WorktreeFetchFailureReason.self, forKey: .reason)
            else {
                throw Self.invalidPayload(in: container)
            }
            self = .failed(reason: reason)
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fetched(let commit):
            try container.encode(Status.fetched, forKey: .status)
            try container.encode(commit, forKey: .commit)
        case .skipped(let reason):
            try container.encode(Status.skipped, forKey: .status)
            try container.encode(reason, forKey: .reason)
        case .failed(let reason):
            try container.encode(Status.failed, forKey: .status)
            try container.encode(reason, forKey: .reason)
        }
    }

    private static func invalidPayload(in container: KeyedDecodingContainer<CodingKeys>) -> DecodingError {
        .dataCorruptedError(
            forKey: .status,
            in: container,
            debugDescription: "Fetch status fields do not match the status tag."
        )
    }
}
