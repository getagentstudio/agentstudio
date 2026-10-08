import Foundation

package enum WorktreeCreationStop: Error, Codable, Sendable, Equatable {
    case changesOnlyNeedsFrom
    /// The branch is checked out (or being rebased or bisected) in the worktree at `path`.
    case branchCheckedOut(path: String)
    /// The branch moved after it was resolved and before the worktree was on it; nothing changed.
    case branchMoved
    case branchAlreadyExists(branch: String)
    case configInvalid(path: String, error: String)
    case sourceIndexUnreadable
    case sourceIndexUnsupported

    package var reason: WorktreeStopReason {
        switch self {
        case .changesOnlyNeedsFrom: .changesOnlyNeedsFrom
        case .branchCheckedOut: .branchCheckedOut
        case .branchMoved: .branchMoved
        case .branchAlreadyExists: .branchAlreadyExists
        case .configInvalid: .configInvalid
        case .sourceIndexUnreadable: .sourceIndexUnreadable
        case .sourceIndexUnsupported: .sourceIndexUnsupported
        }
    }

    var path: String? {
        switch self {
        case .branchCheckedOut(let path): path
        case .configInvalid(let path, _): path
        default: nil
        }
    }

    var humanDetail: String? {
        switch self {
        case .branchAlreadyExists(let branch): branch
        case .configInvalid(_, let error): error.replacingOccurrences(of: "\n", with: " ")
        default: nil
        }
    }
}
