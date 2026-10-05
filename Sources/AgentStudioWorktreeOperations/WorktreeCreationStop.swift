import Foundation

package enum WorktreeCreationStop: Error, Codable, Sendable, Equatable {
    case fromBranchNeedsTrackedOnly
    case changesOnlyNeedsFrom
    case trackedOnlyExcludesSource
    case sourceDirty(WorktreeDirtyStopDetails)
    case sourceNotOnDefaultBranch(actual: String?, expected: String)
    case configInvalid(path: String, error: String)
    case sourceIndexUnreadable
    case sourceIndexUnsupported

    package var reason: WorktreeStopReason {
        switch self {
        case .fromBranchNeedsTrackedOnly: .fromBranchNeedsTrackedOnly
        case .changesOnlyNeedsFrom: .changesOnlyNeedsFrom
        case .trackedOnlyExcludesSource: .trackedOnlyExcludesSource
        case .sourceDirty: .sourceDirty
        case .sourceNotOnDefaultBranch: .sourceNotOnDefaultBranch
        case .configInvalid: .configInvalid
        case .sourceIndexUnreadable: .sourceIndexUnreadable
        case .sourceIndexUnsupported: .sourceIndexUnsupported
        }
    }

    var path: String? {
        switch self {
        case .configInvalid(let path, _): path
        default: nil
        }
    }

    var humanDetail: String? {
        switch self {
        case .sourceDirty(let changes):
            "staged=\(changes.staged) unstaged=\(changes.unstaged) untracked=\(changes.untracked) conflicted=\(changes.conflicted) paths=[\(changes.firstPaths.joined(separator: ", "))]"
        case .sourceNotOnDefaultBranch(let actual, let expected):
            "branch=\(actual ?? "detached") default=\(expected)"
        case .configInvalid(_, let error): error.replacingOccurrences(of: "\n", with: " ")
        default: nil
        }
    }
}
