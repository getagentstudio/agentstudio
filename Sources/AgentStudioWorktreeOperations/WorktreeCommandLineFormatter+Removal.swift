import Foundation

extension WorktreeCommandLineFormatter {
    package static func removalHumanLine(_ entry: WorktreeRemovalEntry) -> String {
        switch entry {
        case .removed(let details):
            return "removed \(details.target)"
        case .alreadyRemoved(let details):
            return "alreadyRemoved \(details.target)"
        case .refused(let details):
            return "refused: \(details.refusal.reason.rawValue) \(details.refusal.message)"
        case .failed(let details):
            return "failed: \(removalFailureName(details.failure.kind)) \(details.target)"
        case .planned(let details):
            let stop = details.plan.stopsAt.map { ": \($0.reason.rawValue)" } ?? ""
            return "planned \(details.target)\(stop)"
        }
    }

    private static func removalFailureName(_ failure: WorktreeRemovalFailureKindDocument) -> String {
        switch failure {
        case .archiveFailed:
            "archiveFailed"
        case .activityChanged:
            "activityChanged"
        case .pruneFailed:
            "pruneFailed"
        case .observationFailed:
            "observationFailed"
        case .removalIncomplete:
            "removalIncomplete"
        case .branchDeletionUncertain:
            "branchDeletionUncertain"
        case .lockCleanupIncomplete:
            "lockCleanupIncomplete"
        }
    }
}
