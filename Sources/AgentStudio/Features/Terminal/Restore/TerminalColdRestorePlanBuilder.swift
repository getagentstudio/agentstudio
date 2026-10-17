import AgentStudioCore
import Foundation

/// Builds a `TerminalColdRestorePlan` from a pane and configuration
/// (SR3, SR6a; Program Design item 2: "`TerminalRestoreRuntime` builds the
/// plan from the pane and configuration it already reads, and passes it to
/// the builder"). Pure and actor-independent — unlike `TerminalRestoreRuntime`
/// (`@MainActor`), this has no MainActor dependency, so the off-main restore
/// decision (`TerminalRestoreKindResolver`, App) can call it directly.
package enum TerminalColdRestorePlanBuilder {
    /// `zmxExecutablePath`, `zmxDirectoryPath` and `loginShellPath` are the
    /// same values `TerminalRestoreRuntime` already resolves for today's warm
    /// attach — passed in rather than re-resolved, so this stays a pure
    /// function of its arguments.
    package static func buildPlan(
        pane: Pane,
        sessionID: ZmxSessionID,
        zmxExecutablePath: String,
        zmxDirectoryPath: String,
        loginShellPath: String,
        repositoryMainFolder: URL?
    ) -> TerminalColdRestorePlan {
        let savedFolder = pane.metadata.cwd ?? pane.metadata.launchDirectory
        let homeFolder = FileManager.default.homeDirectoryForCurrentUser

        var folderCandidates: [URL] = []
        var noticeLines: [String] = []
        if let savedFolder {
            folderCandidates.append(savedFolder)
            noticeLines.append("Restored after restart")
        }
        if let repositoryMainFolder {
            folderCandidates.append(repositoryMainFolder)
            noticeLines.append(
                "Restored after restart (saved folder missing; using the repository's main folder)"
            )
        }
        folderCandidates.append(homeFolder)
        noticeLines.append(
            folderCandidates.count == 1
                ? "Restored after restart"
                : "Restored after restart (saved and repository folders missing; using the home folder)"
        )

        return TerminalColdRestorePlan(
            zmxExecutable: URL(fileURLWithPath: zmxExecutablePath),
            zmxDirectory: URL(fileURLWithPath: zmxDirectoryPath),
            sessionID: sessionID,
            loginShell: URL(fileURLWithPath: loginShellPath),
            folderCandidates: folderCandidates,
            notice: ColdRestoreNotice(linesByCandidateIndex: noticeLines),
            replayFile: nil,
            resume: nil,
            attemptID: .generate()
        )
    }
}
