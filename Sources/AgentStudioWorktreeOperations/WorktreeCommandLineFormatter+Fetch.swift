import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    package static func fetchHumanLine(_ status: WorktreeFetchStatus) -> String {
        switch status {
        case .fetched(let commit):
            return "fetch: fetched \(commit)"
        case .skipped(let reason):
            return "fetch: skipped (\(reason.rawValue))"
        case .failed(let reason, let lock, let lockResidue):
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
            let detailsText = details.isEmpty ? "" : "; \(details.joined(separator: "; "))"
            return "fetch: failed (\(reason.rawValue))\(detailsText)"
        }
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
