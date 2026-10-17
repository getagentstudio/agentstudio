import AgentStudioGit
import Foundation

package enum WorktreePruneSkipReason: Codable, Sendable, Equatable {
    case stop(WorktreeStopReason)
    case notIntegrated
    case assessmentUnknown(WorktreeIntegrationUnknownReasonDocument)
    case detached
    case defaultBranch

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    private enum Kind: String, Codable {
        case stop
        case notIntegrated
        case assessmentUnknown
        case detached
        case defaultBranch
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .stop:
            self = .stop(try container.decode(WorktreeStopReason.self, forKey: .reason))
        case .notIntegrated:
            self = .notIntegrated
        case .assessmentUnknown:
            self = .assessmentUnknown(
                try container.decode(WorktreeIntegrationUnknownReasonDocument.self, forKey: .reason)
            )
        case .detached:
            self = .detached
        case .defaultBranch:
            self = .defaultBranch
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stop(let reason):
            try container.encode(Kind.stop, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .notIntegrated:
            try container.encode(Kind.notIntegrated, forKey: .kind)
        case .assessmentUnknown(let reason):
            try container.encode(Kind.assessmentUnknown, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .detached:
            try container.encode(Kind.detached, forKey: .kind)
        case .defaultBranch:
            try container.encode(Kind.defaultBranch, forKey: .kind)
        }
    }
}

package struct WorktreePruneSkip: Codable, Sendable, Equatable {
    package let reason: WorktreePruneSkipReason
    package let details: WorktreeStopDetails?
    package let options: [String]

    package init(
        reason: WorktreePruneSkipReason,
        details: WorktreeStopDetails? = nil,
        options: [String]
    ) {
        self.reason = reason
        self.details = details
        self.options = options
    }
}

package struct WorktreePruneWouldRemoveDocument: Codable, Sendable, Equatable {
    package let target: String
    package let branch: String
    package let assessment: WorktreeIntegrationAssessmentDocument

    package init(target: String, branch: String, assessment: WorktreeIntegrationAssessmentDocument) {
        self.target = target
        self.branch = branch
        self.assessment = assessment
    }
}

package struct WorktreePruneSkippedDocument: Codable, Sendable, Equatable {
    package let target: String
    package let skip: WorktreePruneSkip

    package init(target: String, skip: WorktreePruneSkip) {
        self.target = target
        self.skip = skip
    }
}

package enum WorktreePruneEntry: Codable, Sendable, Equatable {
    case removed(WorktreeRemovedEntryDocument)
    case wouldRemove(WorktreePruneWouldRemoveDocument)
    case skipped(WorktreePruneSkippedDocument)
    case failed(WorktreeFailedEntryDocument)

    private enum CodingKeys: String, CodingKey {
        case status
        case details
    }

    private enum Status: String, Codable {
        case removed
        case wouldRemove
        case skipped
        case failed
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .removed:
            self = .removed(try container.decode(WorktreeRemovedEntryDocument.self, forKey: .details))
        case .wouldRemove:
            self = .wouldRemove(try container.decode(WorktreePruneWouldRemoveDocument.self, forKey: .details))
        case .skipped:
            self = .skipped(try container.decode(WorktreePruneSkippedDocument.self, forKey: .details))
        case .failed:
            self = .failed(try container.decode(WorktreeFailedEntryDocument.self, forKey: .details))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .removed(let details):
            try container.encode(Status.removed, forKey: .status)
            try container.encode(details, forKey: .details)
        case .wouldRemove(let details):
            try container.encode(Status.wouldRemove, forKey: .status)
            try container.encode(details, forKey: .details)
        case .skipped(let details):
            try container.encode(Status.skipped, forKey: .status)
            try container.encode(details, forKey: .details)
        case .failed(let details):
            try container.encode(Status.failed, forKey: .status)
            try container.encode(details, forKey: .details)
        }
    }
}

package struct WorktreePruneSummary: Codable, Sendable, Equatable {
    package let target: WorktreeListingTargetDocument?
    package let fetch: WorktreeFetchStatus
    package let applied: Bool
    package let entries: [WorktreePruneEntry]

    package init(
        target: WorktreeListingTargetDocument?,
        fetch: WorktreeFetchStatus,
        applied: Bool,
        entries: [WorktreePruneEntry]
    ) {
        self.target = target
        self.fetch = fetch
        self.applied = applied
        self.entries = entries
    }

    package var exitCode: Int32 {
        entries.contains { entry in
            if case .failed = entry { true } else { false }
        } ? 2 : 0
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case target
        case fetch
        case applied
        case entries
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(String.self, forKey: .outcome)
        guard outcome == "pruned" else {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Expected a pruned worktree outcome document."
            )
        }
        target = try container.decodeIfPresent(WorktreeListingTargetDocument.self, forKey: .target)
        fetch = try container.decode(WorktreeFetchStatus.self, forKey: .fetch)
        applied = try container.decode(Bool.self, forKey: .applied)
        entries = try container.decode([WorktreePruneEntry].self, forKey: .entries)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("pruned", forKey: .outcome)
        try container.encode(target, forKey: .target)
        try container.encode(fetch, forKey: .fetch)
        try container.encode(applied, forKey: .applied)
        try container.encode(entries, forKey: .entries)
    }
}
