import AgentStudioGit
import Foundation

package struct WorktreeLockObservation: Codable, Sendable, Equatable {
    package let path: String
    package let resource: GitLockResource
    package let ageSeconds: Int64
    package let gitProcessFound: Bool
    package let looksStale: Bool

    package init(
        path: String,
        resource: GitLockResource,
        ageSeconds: Int64,
        gitProcessFound: Bool,
        looksStale: Bool
    ) {
        self.path = path
        self.resource = resource
        self.ageSeconds = ageSeconds
        self.gitProcessFound = gitProcessFound
        self.looksStale = looksStale
    }
}

package struct WorktreeStopPaneDetails: Codable, Sendable, Equatable {
    package let paneId: String
    package let title: String?

    package init(paneId: String, title: String?) {
        self.paneId = paneId
        self.title = title
    }
}

package struct WorktreeDirtyStopDetails: Codable, Sendable, Equatable {
    package let staged: Int
    package let unstaged: Int
    package let untracked: Int
    package let conflicted: Int
    package let firstPaths: [String]

    package init(staged: Int, unstaged: Int, untracked: Int, conflicted: Int, firstPaths: [String]) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        self.firstPaths = firstPaths
    }
}

package enum WorktreeStopDetails: Codable, Sendable, Equatable {
    case defaultBranch
    case defaultBranchUnverified
    case mainWorktree
    case gitLockUnidentified(resource: GitLockResource)
    case notFound(target: String)
    case alreadyRemoved(target: String)
    case startBranchNotFound(branch: String)
    case unsupportedWorkingState(GitWorktreeWorkingStateRefusal)
    case targetIsCurrent(path: String)
    case worktreeLocked(reason: String?)
    case dirty(WorktreeDirtyStopDetails)
    case changesUnknown
    case evidenceInTmp(fileCount: Int, byteCount: Int64, firstPaths: [String])
    case evidenceUnknown(path: String)
    case openInPane(panes: [WorktreeStopPaneDetails])
    case gitLockHeld(WorktreeLockObservation)
    case archiveDestinationExists(path: String)
    case archiveDestinationInsideWorktree(path: String)
    case forkUnavailable(GitWorktreeForkRejectionReason)

    private enum CodingKeys: String, CodingKey {
        case defaultBranch
        case defaultBranchUnverified
        case mainWorktree
        case gitLockUnidentified
        case notFound
        case alreadyRemoved
        case startBranchNotFound
        case unsupportedWorkingState
        case targetIsCurrent
        case worktreeLocked
        case dirty
        case changesUnknown
        case evidenceInTmp
        case evidenceUnknown
        case openInPane
        case gitLockHeld
        case archiveDestinationExists
        case archiveDestinationInsideWorktree
        case forkUnavailable
    }

    private struct EmptyPayload: Codable {}

    private struct ResourcePayload: Codable {
        let resource: GitLockResource
    }

    private struct TargetPayload: Codable {
        let target: String
    }

    private struct BranchPayload: Codable {
        let branch: String
    }

    private struct PathPayload: Codable {
        let path: String
    }

    private struct WorktreeLockedPayload: Codable {
        let reason: String?

        private enum CodingKeys: String, CodingKey {
            case reason
        }

        init(reason: String?) {
            self.reason = reason
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }

    private struct EvidencePayload: Codable {
        let fileCount: Int
        let byteCount: Int64
        let firstPaths: [String]
    }

    private struct EvidenceUnknownPayload: Codable {
        let path: String
    }

    private struct PanesPayload: Codable {
        let panes: [WorktreeStopPaneDetails]
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "A worktree stop detail must contain exactly one reason."
                ))
        }
        switch key {
        case .defaultBranch:
            _ = try container.decode(EmptyPayload.self, forKey: key)
            self = .defaultBranch
        case .defaultBranchUnverified:
            _ = try container.decode(EmptyPayload.self, forKey: key)
            self = .defaultBranchUnverified
        case .mainWorktree:
            _ = try container.decode(EmptyPayload.self, forKey: key)
            self = .mainWorktree
        case .gitLockUnidentified:
            self = .gitLockUnidentified(resource: try container.decode(ResourcePayload.self, forKey: key).resource)
        case .notFound:
            self = .notFound(target: try container.decode(TargetPayload.self, forKey: key).target)
        case .alreadyRemoved:
            self = .alreadyRemoved(target: try container.decode(TargetPayload.self, forKey: key).target)
        case .startBranchNotFound:
            self = .startBranchNotFound(branch: try container.decode(BranchPayload.self, forKey: key).branch)
        case .unsupportedWorkingState:
            self = .unsupportedWorkingState(try container.decode(GitWorktreeWorkingStateRefusal.self, forKey: key))
        case .targetIsCurrent:
            self = .targetIsCurrent(path: try container.decode(PathPayload.self, forKey: key).path)
        case .worktreeLocked:
            self = .worktreeLocked(reason: try container.decode(WorktreeLockedPayload.self, forKey: key).reason)
        case .dirty:
            self = .dirty(try container.decode(WorktreeDirtyStopDetails.self, forKey: key))
        case .changesUnknown:
            _ = try container.decode(EmptyPayload.self, forKey: key)
            self = .changesUnknown
        case .evidenceInTmp:
            let details = try container.decode(EvidencePayload.self, forKey: key)
            self = .evidenceInTmp(
                fileCount: details.fileCount,
                byteCount: details.byteCount,
                firstPaths: details.firstPaths
            )
        case .evidenceUnknown:
            self = .evidenceUnknown(path: try container.decode(EvidenceUnknownPayload.self, forKey: key).path)
        case .openInPane:
            self = .openInPane(panes: try container.decode(PanesPayload.self, forKey: key).panes)
        case .gitLockHeld:
            self = .gitLockHeld(try container.decode(WorktreeLockObservation.self, forKey: key))
        case .archiveDestinationExists:
            self = .archiveDestinationExists(path: try container.decode(PathPayload.self, forKey: key).path)
        case .archiveDestinationInsideWorktree:
            self = .archiveDestinationInsideWorktree(path: try container.decode(PathPayload.self, forKey: key).path)
        case .forkUnavailable:
            self = .forkUnavailable(try container.decode(GitWorktreeForkRejectionReason.self, forKey: key))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .defaultBranch:
            try container.encode(EmptyPayload(), forKey: .defaultBranch)
        case .defaultBranchUnverified:
            try container.encode(EmptyPayload(), forKey: .defaultBranchUnverified)
        case .mainWorktree:
            try container.encode(EmptyPayload(), forKey: .mainWorktree)
        case .gitLockUnidentified(let resource):
            try container.encode(ResourcePayload(resource: resource), forKey: .gitLockUnidentified)
        case .notFound(let target):
            try container.encode(TargetPayload(target: target), forKey: .notFound)
        case .alreadyRemoved(let target):
            try container.encode(TargetPayload(target: target), forKey: .alreadyRemoved)
        case .startBranchNotFound(let branch):
            try container.encode(BranchPayload(branch: branch), forKey: .startBranchNotFound)
        case .unsupportedWorkingState(let refusal):
            try container.encode(refusal, forKey: .unsupportedWorkingState)
        case .targetIsCurrent(let path):
            try container.encode(PathPayload(path: path), forKey: .targetIsCurrent)
        case .worktreeLocked(let reason):
            try container.encode(WorktreeLockedPayload(reason: reason), forKey: .worktreeLocked)
        case .dirty(let details):
            try container.encode(details, forKey: .dirty)
        case .changesUnknown:
            try container.encode(EmptyPayload(), forKey: .changesUnknown)
        case .evidenceInTmp(let fileCount, let byteCount, let firstPaths):
            try container.encode(
                EvidencePayload(fileCount: fileCount, byteCount: byteCount, firstPaths: firstPaths),
                forKey: .evidenceInTmp
            )
        case .evidenceUnknown(let path):
            try container.encode(EvidenceUnknownPayload(path: path), forKey: .evidenceUnknown)
        case .openInPane(let panes):
            try container.encode(PanesPayload(panes: panes), forKey: .openInPane)
        case .gitLockHeld(let observation):
            try container.encode(observation, forKey: .gitLockHeld)
        case .archiveDestinationExists(let path):
            try container.encode(PathPayload(path: path), forKey: .archiveDestinationExists)
        case .archiveDestinationInsideWorktree(let path):
            try container.encode(PathPayload(path: path), forKey: .archiveDestinationInsideWorktree)
        case .forkUnavailable(let reason):
            try container.encode(reason, forKey: .forkUnavailable)
        }
    }

    package var reason: WorktreeStopReason {
        switch self {
        case .defaultBranch:
            .defaultBranch
        case .defaultBranchUnverified:
            .defaultBranchUnverified
        case .mainWorktree:
            .mainWorktree
        case .gitLockUnidentified:
            .gitLockUnidentified
        case .notFound:
            .notFound
        case .alreadyRemoved:
            .alreadyRemoved
        case .startBranchNotFound:
            .startBranchNotFound
        case .unsupportedWorkingState:
            .unsupportedWorkingState
        case .targetIsCurrent:
            .targetIsCurrent
        case .worktreeLocked:
            .worktreeLocked
        case .dirty:
            .dirty
        case .changesUnknown:
            .changesUnknown
        case .evidenceInTmp:
            .evidenceInTmp
        case .evidenceUnknown:
            .evidenceUnknown
        case .openInPane:
            .openInPane
        case .gitLockHeld:
            .gitLockHeld
        case .archiveDestinationExists:
            .archiveDestinationExists
        case .archiveDestinationInsideWorktree:
            .archiveDestinationInsideWorktree
        case .forkUnavailable:
            .forkUnavailable
        }
    }

    package var offersStaleLockRemoval: Bool {
        guard case .gitLockHeld(let observation) = self else { return false }
        return observation.looksStale
    }
}
