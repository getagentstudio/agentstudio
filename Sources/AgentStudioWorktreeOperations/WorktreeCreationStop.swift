import Foundation

package enum WorktreeCreationStop: Error, Codable, Sendable, Equatable {
    case changesOnlyNeedsFrom
    /// The branch is checked out (or being rebased or bisected) in the worktree at `path`.
    case branchCheckedOut(path: String)
    /// The branch moved after it was resolved and before the worktree was on it; nothing changed.
    case branchMoved
    /// `-c` names a branch that exists: locally when `remoteName` is nil, else on that remote (D23).
    case branchAlreadyExists(branch: String, remoteName: String? = nil)
    /// `new` without `-c` names a branch that exists neither locally nor on origin (D23).
    case noSuchBranch(branch: String)
    /// `-c` couldn't ask the remote whether its name exists there, so it created nothing (D23, fails closed).
    case originCheckFailed(branch: String, remoteName: String, reason: WorktreeFetchFailureReason)
    case configInvalid(path: String, error: String)
    case sourceIndexUnreadable
    case sourceIndexUnsupported

    package var reason: WorktreeStopReason {
        switch self {
        case .changesOnlyNeedsFrom: .changesOnlyNeedsFrom
        case .branchCheckedOut: .branchCheckedOut
        case .branchMoved: .branchMoved
        case .branchAlreadyExists: .branchAlreadyExists
        case .noSuchBranch: .noSuchBranch
        case .originCheckFailed: .originCheckFailed
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
        case .branchAlreadyExists(let branch, let remoteName): remoteName.map { "\($0)/\(branch)" } ?? branch
        case .noSuchBranch(let branch): branch
        case .originCheckFailed(let branch, let remoteName, let reason): "\(remoteName)/\(branch) (\(reason.rawValue))"
        case .configInvalid(_, let error): error.replacingOccurrences(of: "\n", with: " ")
        default: nil
        }
    }
}
