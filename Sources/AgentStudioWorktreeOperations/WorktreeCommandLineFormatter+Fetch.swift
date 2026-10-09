import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    package static func fetchHumanLine(_ status: WorktreeFetchStatus) -> String {
        switch status {
        case .fetched(let commit, let lockResidue):
            return "fetch: fetched \(commit)\(leftoverLocksSuffix(lockResidue))"
        case .skipped(let reason):
            return "fetch: skipped (\(reason.rawValue))"
        case .failed(let reason, let lock, let lockResidue):
            return "fetch: failed (\(reason.rawValue))\(failureDetailsSuffix(lock: lock, lockResidue: lockResidue))"
        }
    }

    /// LR30's status for `new`, in the shape of LR5's line, naming the remote branch it asked about.
    package static func creationFetchHumanLine(_ status: WorktreeCreationFetchStatus) -> String {
        switch status {
        case .fetched(let remoteName, let branchName, let commit, let lockResidue):
            return "fetch: fetched \(remoteName)/\(branchName) \(commit)\(leftoverLocksSuffix(lockResidue))"
        case .notOnRemote(let remoteName, let branchName):
            return "fetch: notOnRemote \(remoteName)/\(branchName)"
        case .skipped(let reason):
            return "fetch: skipped (\(reason.rawValue))"
        case .failed(let remoteName, let branchName, let failure):
            let details = failureDetailsSuffix(lock: failure.lock, lockResidue: failure.lockResidue)
            return "fetch: failed \(remoteName)/\(branchName) (\(failure.reason.rawValue))\(details)"
        }
    }

    private static func leftoverLocksSuffix(_ lockResidue: [String]?) -> String {
        guard let lockResidue, !lockResidue.isEmpty else { return "" }
        return "; leftover lock paths \(lockResidue.joined(separator: ", "))"
    }

    private static func failureDetailsSuffix(lock: WorktreeFetchLock?, lockResidue: [String]?) -> String {
        var details: [String] = []
        if let lock {
            if let path = lock.path {
                details.append("lock path \(path) (\(lockResourceDescription(lock.resource)))")
            } else {
                details.append("lock resource \(lockResourceDescription(lock.resource))")
            }
        }
        if let lockResidue, !lockResidue.isEmpty {
            details.append("leftover lock paths \(lockResidue.joined(separator: ", "))")
        }
        return details.isEmpty ? "" : "; \(details.joined(separator: "; "))"
    }

    private static func lockResourceDescription(_ resource: GitLockResource) -> String {
        switch resource {
        case .index(let worktreePath):
            "index for \(absolutePath(worktreePath))"
        case .reference(let name):
            "reference \(name)"
        case .packedRefs:
            "packed-refs"
        case .config:
            "config"
        }
    }
}
