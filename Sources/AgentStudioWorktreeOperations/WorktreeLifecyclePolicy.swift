import Foundation

package enum WorktreeLifecyclePolicy {
    package static let squashSearchCommitLimit = 500
    package static let staleLockAge: Duration = .seconds(120)
    package static let fetchesDefaultBranch = true

    package static func archiveToMainDestination(mainWorktree: URL, worktreeFolder: String) -> URL {
        mainWorktree.standardizedFileURL
            .appending(path: "tmp", directoryHint: .isDirectory)
            .appending(path: worktreeFolder, directoryHint: .isDirectory)
            .standardizedFileURL
    }
}
