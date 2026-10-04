import Foundation

package enum WorktreeCreationStop: Error, Codable, Sendable, Equatable {
    case fromBranchNeedsTrackedOnly
    case changesOnlyNeedsFrom
    case trackedOnlyExcludesSource
    case sourceDirty(WorktreeDirtyStopDetails)
    case sourceNotOnDefaultBranch(actual: String?, expected: String)
    case sourceBusy(path: String)
    case sourceBusyUnknown(path: String, errno: Int32)
    case configInvalid(path: String, error: String)
    case sourceIndexUnreadable

    package var reason: WorktreeStopReason {
        switch self {
        case .fromBranchNeedsTrackedOnly: .fromBranchNeedsTrackedOnly
        case .changesOnlyNeedsFrom: .changesOnlyNeedsFrom
        case .trackedOnlyExcludesSource: .trackedOnlyExcludesSource
        case .sourceDirty: .sourceDirty
        case .sourceNotOnDefaultBranch: .sourceNotOnDefaultBranch
        case .sourceBusy: .sourceBusy
        case .sourceBusyUnknown: .sourceBusyUnknown
        case .configInvalid: .configInvalid
        case .sourceIndexUnreadable: .sourceIndexUnreadable
        }
    }

    var path: String? {
        switch self {
        case .sourceBusy(let path), .sourceBusyUnknown(let path, _), .configInvalid(let path, _): path
        default: nil
        }
    }

    var humanDetail: String? {
        switch self {
        case .sourceDirty(let changes):
            "staged=\(changes.staged) unstaged=\(changes.unstaged) untracked=\(changes.untracked) conflicted=\(changes.conflicted) paths=[\(changes.firstPaths.joined(separator: ", "))]"
        case .sourceNotOnDefaultBranch(let actual, let expected):
            "branch=\(actual ?? "detached") default=\(expected)"
        case .sourceBusyUnknown(_, let code): "errno \(code)"
        case .configInvalid(_, let error): error.replacingOccurrences(of: "\n", with: " ")
        default: nil
        }
    }
}
