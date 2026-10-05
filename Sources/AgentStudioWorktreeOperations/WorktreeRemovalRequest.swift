import Foundation

package enum WorktreeBranchPolicy: Sendable, Equatable {
    case deleteIfIntegrated
    case deleteAtObservedCommit
    case keep
}

package enum WorktreeEvidencePolicy: Sendable, Equatable {
    case requireEmpty
    case archiveToMain
    case archive(to: URL)
    case discard
}

package struct WorktreeRemovalRequest: Sendable, Equatable {
    package let start: URL
    package let callerDirectory: URL?
    package let targets: [String]
    package let discardWorkingChanges: Bool
    package let branchPolicy: WorktreeBranchPolicy
    package let evidencePolicy: WorktreeEvidencePolicy
    package let fetchPolicy: WorktreeFetchPolicy
    package let removeStaleLock: Bool
    package let closePanes: Bool
    package let removeWithOpenPanes: Bool
    package let dryRun: Bool

    package init(
        start: URL,
        callerDirectory: URL?,
        targets: [String],
        discardWorkingChanges: Bool,
        branchPolicy: WorktreeBranchPolicy,
        evidencePolicy: WorktreeEvidencePolicy,
        fetchPolicy: WorktreeFetchPolicy,
        removeStaleLock: Bool,
        closePanes: Bool,
        removeWithOpenPanes: Bool,
        dryRun: Bool
    ) {
        self.start = start
        self.callerDirectory = callerDirectory
        self.targets = targets
        self.discardWorkingChanges = discardWorkingChanges
        self.branchPolicy = branchPolicy
        self.evidencePolicy = evidencePolicy
        self.fetchPolicy = fetchPolicy
        self.removeStaleLock = removeStaleLock
        self.closePanes = closePanes
        self.removeWithOpenPanes = removeWithOpenPanes
        self.dryRun = dryRun
    }
}
