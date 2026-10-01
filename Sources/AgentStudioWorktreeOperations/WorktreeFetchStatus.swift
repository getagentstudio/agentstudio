import AgentStudioGit
import Foundation

package enum WorktreeFetchSkipReason: String, Codable, Sendable {
    case noFetchFlag
    case noRemote
    case noTarget
}

package enum WorktreeFetchFailureReason: String, Codable, Sendable {
    case networkFailure
    case authenticationFailure
    case gitLockHeld
    case gitLockUnidentified
    case upstreamNotOrigin
    case processFailure
    case unknown
}

package struct WorktreeFetchLock: Codable, Sendable, Equatable {
    package let path: String?
    package let resource: GitLockResource

    package init(path: String?, resource: GitLockResource) {
        self.path = path
        self.resource = resource
    }
}

package enum WorktreeFetchStatus: Codable, Sendable, Equatable {
    case fetched(commit: String)
    case skipped(reason: WorktreeFetchSkipReason)
    case failed(
        reason: WorktreeFetchFailureReason,
        lock: WorktreeFetchLock? = nil,
        lockResidue: [String]? = nil
    )

    private enum CodingKeys: String, CodingKey {
        case status
        case commit
        case reason
        case lock
        case lockResidue
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
        let lock = try container.decodeIfPresent(WorktreeFetchLock.self, forKey: .lock)
        let lockResidue = try container.decodeIfPresent([String].self, forKey: .lockResidue)

        switch status {
        case .fetched:
            guard let commit,
                lock == nil,
                lockResidue == nil,
                try container.decodeIfPresent(WorktreeFetchSkipReason.self, forKey: .reason) == nil,
                try container.decodeIfPresent(WorktreeFetchFailureReason.self, forKey: .reason) == nil
            else {
                throw Self.invalidPayload(in: container)
            }
            self = .fetched(commit: commit)
        case .skipped:
            guard commit == nil,
                lock == nil,
                lockResidue == nil,
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
            self = .failed(reason: reason, lock: lock, lockResidue: lockResidue?.isEmpty == true ? nil : lockResidue)
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
        case .failed(let reason, let lock, let lockResidue):
            try container.encode(Status.failed, forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(lock, forKey: .lock)
            if let lockResidue, !lockResidue.isEmpty {
                try container.encode(lockResidue, forKey: .lockResidue)
            }
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
