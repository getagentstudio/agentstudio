import AgentStudioGit
import Foundation

package enum WorktreeRemovalFailureKindDocument: Codable, Sendable, Equatable {
    case archiveFailed
    case activityChanged
    case pruneFailed(code: Int32, klass: Int32)
    case observationFailed
    case removalIncomplete
    case branchDeletionUncertain
    case branchDeletionFailed(WorktreeGitErrorKind)
    case lockCleanupIncomplete

    private enum CodingKeys: String, CodingKey {
        case kind
        case code
        case klass
        case cause
    }

    private enum Kind: String, Codable {
        case archiveFailed
        case activityChanged
        case pruneFailed
        case observationFailed
        case removalIncomplete
        case branchDeletionUncertain
        case branchDeletionFailed
        case lockCleanupIncomplete
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .archiveFailed:
            self = .archiveFailed
        case .activityChanged:
            self = .activityChanged
        case .pruneFailed:
            self = .pruneFailed(
                code: try container.decode(Int32.self, forKey: .code),
                klass: try container.decode(Int32.self, forKey: .klass)
            )
        case .observationFailed:
            self = .observationFailed
        case .removalIncomplete:
            self = .removalIncomplete
        case .branchDeletionUncertain:
            self = .branchDeletionUncertain
        case .branchDeletionFailed:
            let cause = try container.decode(WorktreeGitErrorDocument.self, forKey: .cause)
            guard let error = cause.worktreeErrorKind else {
                throw DecodingError.dataCorruptedError(
                    forKey: .cause,
                    in: container,
                    debugDescription: "Unknown worktree Git error kind."
                )
            }
            self = .branchDeletionFailed(error)
        case .lockCleanupIncomplete:
            self = .lockCleanupIncomplete
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .archiveFailed:
            try container.encode(Kind.archiveFailed, forKey: .kind)
        case .activityChanged:
            try container.encode(Kind.activityChanged, forKey: .kind)
        case .pruneFailed(let code, let klass):
            try container.encode(Kind.pruneFailed, forKey: .kind)
            try container.encode(code, forKey: .code)
            try container.encode(klass, forKey: .klass)
        case .observationFailed:
            try container.encode(Kind.observationFailed, forKey: .kind)
        case .removalIncomplete:
            try container.encode(Kind.removalIncomplete, forKey: .kind)
        case .branchDeletionUncertain:
            try container.encode(Kind.branchDeletionUncertain, forKey: .kind)
        case .branchDeletionFailed(let cause):
            try container.encode(Kind.branchDeletionFailed, forKey: .kind)
            try container.encode(WorktreeGitErrorDocument(cause), forKey: .cause)
        case .lockCleanupIncomplete:
            try container.encode(Kind.lockCleanupIncomplete, forKey: .kind)
        }
    }
}

package struct WorktreeRemovalFailureDocument: Codable, Sendable, Equatable {
    package let kind: WorktreeRemovalFailureKindDocument
    package let effects: WorktreeRemovalEffectsDocument
    package let stop: WorktreeRefusalDocument?

    package init(
        kind: WorktreeRemovalFailureKindDocument,
        effects: WorktreeRemovalEffectsDocument,
        stop: WorktreeRefusalDocument? = nil
    ) {
        self.kind = kind
        self.effects = effects
        self.stop = stop
    }
}

package struct WorktreeGitErrorDocument: Codable, Sendable, Equatable {
    package let kind: String
    package let path: String?
    package let lockPath: String?
    package let lockResource: GitLockResource?

    package init(_ error: WorktreeGitErrorKind) {
        kind = error.name
        path = error.permissionPath?.standardizedFileURL.path
        lockPath = error.lockFact?.path.standardizedFileURL.path
        lockResource = error.lockFact?.resource
    }

    package var worktreeErrorKind: WorktreeGitErrorKind? {
        switch kind {
        case "repositoryNotFound":
            .repositoryNotFound
        case "worktreeNotFound":
            .worktreeNotFound
        case "locked":
            .locked
        case "lockHeld":
            lockPath.flatMap { lockPath in
                lockResource.map { resource in
                    WorktreeGitErrorKind.lockHeld(
                        GitLockFact(path: URL(fileURLWithPath: lockPath), resource: resource)
                    )
                }
            }
        case "lockUnidentified":
            .lockUnidentified
        case "permissionDenied":
            .permissionDenied(path: path.map { URL(fileURLWithPath: $0) })
        case "worktreeNotPrunable":
            .worktreeNotPrunable
        case "unsafeWorktreeRemoval":
            .unsafeWorktreeRemoval
        case "contentTooLarge":
            .contentTooLarge
        case "pathEscapesRepository":
            .pathEscapesRepository
        case "revisionUnavailable":
            .revisionUnavailable
        case "headUnavailable":
            .headUnavailable
        case "requiredObjectNotFound":
            .requiredObjectNotFound
        case "noSharedHistory":
            .noSharedHistory
        case "multipleBestMergeBases":
            .multipleBestMergeBases
        case "processFailed":
            .processFailed
        case "processTimedOut":
            .processTimedOut
        case "processCancelled":
            .processCancelled
        case "processOutputTooLarge":
            .processOutputTooLarge
        case "remoteRefTransactionIndeterminate":
            .remoteRefTransactionIndeterminate
        case "libgit2Failure":
            .libgit2Failure
        case "unsupported":
            .unsupported
        default:
            nil
        }
    }
}

package enum WorktreeRemovalPlanStepKind: String, Codable, Sendable {
    case fetch
    case checks
    case archive
    case directoryRemoval
    case branchDisposition
}

package enum WorktreeRemovalPlanStepDisposition: String, Codable, Sendable {
    case wouldRun
    case skipped
    case wouldRemove
    case wouldDelete
}

package struct WorktreeRemovalPlanStep: Codable, Sendable, Equatable {
    package let kind: WorktreeRemovalPlanStepKind
    package let disposition: WorktreeRemovalPlanStepDisposition
    package let detail: String?

    package init(
        kind: WorktreeRemovalPlanStepKind,
        disposition: WorktreeRemovalPlanStepDisposition,
        detail: String? = nil
    ) {
        self.kind = kind
        self.disposition = disposition
        self.detail = detail
    }
}

package struct WorktreeRemovalPlanDocument: Codable, Sendable, Equatable {
    package let steps: [WorktreeRemovalPlanStep]
    package let stopsAt: WorktreeRefusalDocument?

    package init(steps: [WorktreeRemovalPlanStep], stopsAt: WorktreeRefusalDocument? = nil) {
        self.steps = steps
        self.stopsAt = stopsAt
    }
}

package struct WorktreeRefusalDocument: Codable, Sendable, Equatable {
    package let reason: WorktreeStopReason
    package let message: String
    package let details: WorktreeStopDetails
    package let options: [WorktreeStopOption]

    package init(
        reason: WorktreeStopReason,
        message: String,
        details: WorktreeStopDetails,
        options: [WorktreeStopOption]
    ) {
        self.reason = reason
        self.message = message
        self.details = details
        self.options = options
    }

    package init(details: WorktreeStopDetails) {
        let entry = WorktreeStopCatalog.entry(for: details)
        self.init(reason: entry.reason, message: entry.message, details: entry.details, options: entry.options)
    }
}

package struct WorktreeRemovedEntryDocument: Codable, Sendable, Equatable {
    package let target: String
    package let inputs: [String]
    package let effects: WorktreeRemovalEffectsDocument

    package init(target: String, inputs: [String] = [], effects: WorktreeRemovalEffectsDocument) {
        self.target = target
        self.inputs = inputs
        self.effects = effects
    }
}

package struct WorktreeAlreadyRemovedEntryDocument: Codable, Sendable, Equatable {
    package let target: String
    package let inputs: [String]

    package init(target: String, inputs: [String] = []) {
        self.target = target
        self.inputs = inputs
    }
}

package struct WorktreeRefusedEntryDocument: Codable, Sendable, Equatable {
    package let target: String
    package let inputs: [String]
    package let refusal: WorktreeRefusalDocument

    package init(target: String, inputs: [String] = [], refusal: WorktreeRefusalDocument) {
        self.target = target
        self.inputs = inputs
        self.refusal = refusal
    }
}

package struct WorktreeFailedEntryDocument: Codable, Sendable, Equatable {
    package let target: String
    package let inputs: [String]
    package let failure: WorktreeRemovalFailureDocument

    package init(target: String, inputs: [String] = [], failure: WorktreeRemovalFailureDocument) {
        self.target = target
        self.inputs = inputs
        self.failure = failure
    }
}

package struct WorktreePlannedEntryDocument: Codable, Sendable, Equatable {
    package let target: String
    package let inputs: [String]
    package let plan: WorktreeRemovalPlanDocument

    package init(target: String, inputs: [String] = [], plan: WorktreeRemovalPlanDocument) {
        self.target = target
        self.inputs = inputs
        self.plan = plan
    }
}

package enum WorktreeRemovalEntry: Codable, Sendable, Equatable {
    case removed(WorktreeRemovedEntryDocument)
    case alreadyRemoved(WorktreeAlreadyRemovedEntryDocument)
    case refused(WorktreeRefusedEntryDocument)
    case failed(WorktreeFailedEntryDocument)
    case planned(WorktreePlannedEntryDocument)

    private enum CodingKeys: String, CodingKey {
        case status
        case details
    }

    private enum Status: String, Codable {
        case removed
        case alreadyRemoved
        case refused
        case failed
        case planned
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .removed:
            self = .removed(try container.decode(WorktreeRemovedEntryDocument.self, forKey: .details))
        case .alreadyRemoved:
            self = .alreadyRemoved(
                try container.decode(WorktreeAlreadyRemovedEntryDocument.self, forKey: .details)
            )
        case .refused:
            self = .refused(try container.decode(WorktreeRefusedEntryDocument.self, forKey: .details))
        case .failed:
            self = .failed(try container.decode(WorktreeFailedEntryDocument.self, forKey: .details))
        case .planned:
            self = .planned(try container.decode(WorktreePlannedEntryDocument.self, forKey: .details))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .removed(let details):
            try container.encode(Status.removed, forKey: .status)
            try container.encode(details, forKey: .details)
        case .alreadyRemoved(let details):
            try container.encode(Status.alreadyRemoved, forKey: .status)
            try container.encode(details, forKey: .details)
        case .refused(let details):
            try container.encode(Status.refused, forKey: .status)
            try container.encode(details, forKey: .details)
        case .failed(let details):
            try container.encode(Status.failed, forKey: .status)
            try container.encode(details, forKey: .details)
        case .planned(let details):
            try container.encode(Status.planned, forKey: .status)
            try container.encode(details, forKey: .details)
        }
    }
}

package struct WorktreeRemovalReport: Codable, Sendable, Equatable {
    package let entries: [WorktreeRemovalEntry]
    package let fetch: WorktreeFetchStatus
    package let fetchingReadFailure: WorktreeFetchingReadFailure?

    package init(
        entries: [WorktreeRemovalEntry],
        fetch: WorktreeFetchStatus,
        fetchingReadFailure: WorktreeFetchingReadFailure? = nil
    ) {
        self.entries = entries
        self.fetch = fetch
        self.fetchingReadFailure = fetchingReadFailure
    }

    package var exitCode: Int32 {
        if fetchingReadFailure != nil { return 2 }
        if entries.contains(where: { if case .failed = $0 { true } else { false } }) {
            return 2
        }
        if entries.contains(where: { if case .refused = $0 { true } else { false } }) {
            return 1
        }
        if entries.contains(where: { entry in
            guard case .planned(let details) = entry else { return false }
            return details.plan.stopsAt?.reason == .notFound
        }) {
            return 1
        }
        return 0
    }

    private enum CodingKeys: String, CodingKey {
        case outcome
        case entries
        case fetch
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(String.self, forKey: .outcome)
        if outcome == "failed" {
            let failure = try WorktreeFetchingReadFailure(from: decoder)
            entries = []
            fetch = failure.fetch
            fetchingReadFailure = failure
            return
        }
        guard outcome == "removal" else {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Expected a removal outcome document."
            )
        }
        entries = try container.decode([WorktreeRemovalEntry].self, forKey: .entries)
        fetch = try container.decode(WorktreeFetchStatus.self, forKey: .fetch)
        fetchingReadFailure = nil
    }

    package func encode(to encoder: any Encoder) throws {
        if let fetchingReadFailure {
            try fetchingReadFailure.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("removal", forKey: .outcome)
        try container.encode(entries, forKey: .entries)
        try container.encode(fetch, forKey: .fetch)
    }
}
