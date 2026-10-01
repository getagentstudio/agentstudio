import Foundation

package enum WorktreeDirectoryEffect: String, Codable, Sendable {
    case removed
    case retained
    case partial
    case unknown
    case notApplicable
}

package enum WorktreeAdministrationEffect: String, Codable, Sendable {
    case removed
    case retained
    case partial
    case unknown
    case notApplicable
}

package enum WorktreeBranchDisposition: String, Codable, Sendable {
    case deleted
    case retained
    case unknown
}

package enum WorktreeBranchRetentionReason: String, Codable, Sendable {
    case defaultBranch
    case branchPolicyKeep
    case hasRemainingContribution
    case unknownAssessment
    case checkedOut
    case checkoutUnknown
    case movedSinceAssessment
}

package enum WorktreeBranchCleanupWarning: String, Codable, Sendable {
    case configurationLeftInPlace
    case reflogLeftInPlace
}

package struct WorktreeBranchDispositionDocument: Codable, Sendable, Equatable {
    package let name: String
    package let commit: String?
    package let disposition: WorktreeBranchDisposition
    package let reason: WorktreeBranchRetentionReason?
    package let cleanupWarnings: [WorktreeBranchCleanupWarning]

    package init(
        name: String,
        commit: String?,
        disposition: WorktreeBranchDisposition,
        reason: WorktreeBranchRetentionReason? = nil,
        cleanupWarnings: [WorktreeBranchCleanupWarning] = []
    ) {
        self.name = name
        self.commit = commit
        self.disposition = disposition
        self.reason = reason
        self.cleanupWarnings = cleanupWarnings
    }
}

package enum WorktreeIntegrationProofDocument: Codable, Sendable, Equatable {
    case sameCommit
    case ancestor
    case sameContent
    case emptyDelta
    case squash(commit: String)

    private enum CodingKeys: String, CodingKey {
        case proof
        case commit
    }

    private enum Proof: String, Codable {
        case sameCommit
        case ancestor
        case sameContent
        case emptyDelta
        case squash
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Proof.self, forKey: .proof) {
        case .sameCommit:
            self = .sameCommit
        case .ancestor:
            self = .ancestor
        case .sameContent:
            self = .sameContent
        case .emptyDelta:
            self = .emptyDelta
        case .squash:
            self = .squash(commit: try container.decode(String.self, forKey: .commit))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sameCommit:
            try container.encode(Proof.sameCommit, forKey: .proof)
        case .ancestor:
            try container.encode(Proof.ancestor, forKey: .proof)
        case .sameContent:
            try container.encode(Proof.sameContent, forKey: .proof)
        case .emptyDelta:
            try container.encode(Proof.emptyDelta, forKey: .proof)
        case .squash(let commit):
            try container.encode(Proof.squash, forKey: .proof)
            try container.encode(commit, forKey: .commit)
        }
    }
}

package enum WorktreeIntegrationUnknownReasonDocument: String, Codable, Sendable {
    case branchNotFound
    case noTarget
    case noMergeBase
    case multipleMergeBases
    case historyLimitReached
    case incompleteHistory
    case missingObjects
    case readFailed
}

package enum WorktreeIntegrationAssessmentDocument: Codable, Sendable, Equatable {
    case integrated(WorktreeIntegrationProofDocument)
    case hasRemainingContribution
    case unknown(WorktreeIntegrationUnknownReasonDocument)

    private enum CodingKeys: String, CodingKey {
        case grade
        case proof
        case reason
    }

    private enum Grade: String, Codable {
        case integrated
        case hasRemainingContribution
        case unknown
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Grade.self, forKey: .grade) {
        case .integrated:
            self = .integrated(try container.decode(WorktreeIntegrationProofDocument.self, forKey: .proof))
        case .hasRemainingContribution:
            self = .hasRemainingContribution
        case .unknown:
            self = .unknown(try container.decode(WorktreeIntegrationUnknownReasonDocument.self, forKey: .reason))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .integrated(let proof):
            try container.encode(Grade.integrated, forKey: .grade)
            try container.encode(proof, forKey: .proof)
        case .hasRemainingContribution:
            try container.encode(Grade.hasRemainingContribution, forKey: .grade)
        case .unknown(let reason):
            try container.encode(Grade.unknown, forKey: .grade)
            try container.encode(reason, forKey: .reason)
        }
    }
}

package struct WorktreePaneReferenceDocument: Codable, Sendable, Equatable {
    package let id: String
    package let displayTitle: String

    package init(id: String, displayTitle: String) {
        self.id = id
        self.displayTitle = displayTitle
    }
}

package enum WorktreeActivityDocument: Codable, Sendable, Equatable {
    case notChecked
    case noActivity
    case openPanes([WorktreePaneReferenceDocument])

    private enum CodingKeys: String, CodingKey {
        case status
        case openPanes
    }

    private enum Status: String, Codable {
        case notChecked
        case noActivity = "none"
        case openPanes
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .notChecked:
            self = .notChecked
        case .noActivity:
            self = .noActivity
        case .openPanes:
            self = .openPanes(try container.decode([WorktreePaneReferenceDocument].self, forKey: .openPanes))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notChecked:
            try container.encode(Status.notChecked, forKey: .status)
        case .noActivity:
            try container.encode(Status.noActivity, forKey: .status)
        case .openPanes(let panes):
            try container.encode(Status.openPanes, forKey: .status)
            try container.encode(panes, forKey: .openPanes)
        }
    }
}

package enum WorktreeEvidenceDispositionDocument: Codable, Sendable, Equatable {
    case archived(path: String, files: Int)
    case partialCopy(path: String)
    case discarded
    case noEvidence

    private enum CodingKeys: String, CodingKey {
        case status
        case path
        case files
    }

    private enum Status: String, Codable {
        case archived
        case partialCopy
        case discarded
        case noEvidence = "none"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .archived:
            self = .archived(
                path: try container.decode(String.self, forKey: .path),
                files: try container.decode(Int.self, forKey: .files)
            )
        case .partialCopy:
            self = .partialCopy(path: try container.decode(String.self, forKey: .path))
        case .discarded:
            self = .discarded
        case .noEvidence:
            self = .noEvidence
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .archived(let path, let files):
            try container.encode(Status.archived, forKey: .status)
            try container.encode(path, forKey: .path)
            try container.encode(files, forKey: .files)
        case .partialCopy(let path):
            try container.encode(Status.partialCopy, forKey: .status)
            try container.encode(path, forKey: .path)
        case .discarded:
            try container.encode(Status.discarded, forKey: .status)
        case .noEvidence:
            try container.encode(Status.noEvidence, forKey: .status)
        }
    }
}

package struct WorktreeRemovalEffectsDocument: Codable, Sendable, Equatable {
    package let directory: WorktreeDirectoryEffect
    package let administration: WorktreeAdministrationEffect
    package let branch: WorktreeBranchDispositionDocument?
    package let evidence: WorktreeEvidenceDispositionDocument
    package let assessment: WorktreeIntegrationAssessmentDocument?
    package let activity: WorktreeActivityDocument

    package init(
        directory: WorktreeDirectoryEffect,
        administration: WorktreeAdministrationEffect,
        branch: WorktreeBranchDispositionDocument?,
        evidence: WorktreeEvidenceDispositionDocument,
        assessment: WorktreeIntegrationAssessmentDocument?,
        activity: WorktreeActivityDocument
    ) {
        self.directory = directory
        self.administration = administration
        self.branch = branch
        self.evidence = evidence
        self.assessment = assessment
        self.activity = activity
    }
}
