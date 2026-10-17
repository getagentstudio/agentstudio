import Foundation

package struct WorktreePruneRequest: Sendable, Equatable {
    package let start: URL
    package let callerDirectory: URL?
    package let apply: Bool
    package let evidencePolicy: WorktreeEvidencePolicy
    package let fetchPolicy: WorktreeFetchPolicy

    package init(
        start: URL,
        callerDirectory: URL?,
        apply: Bool,
        evidencePolicy: WorktreeEvidencePolicy,
        fetchPolicy: WorktreeFetchPolicy
    ) {
        self.start = start
        self.callerDirectory = callerDirectory
        self.apply = apply
        self.evidencePolicy = evidencePolicy
        self.fetchPolicy = fetchPolicy
    }
}
