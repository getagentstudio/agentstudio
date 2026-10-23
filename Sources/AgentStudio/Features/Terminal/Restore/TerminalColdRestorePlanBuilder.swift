import AgentStudioCore
import Foundation

/// The zmx executable, session directory and login shell paths resolved for a terminal launch.
package struct TerminalColdRestoreLaunchPaths: Sendable, Equatable {
    let zmxExecutablePath: String
    let zmxDirectoryPath: String
    let loginShellPath: String

    package init(zmxExecutablePath: String, zmxDirectoryPath: String, loginShellPath: String) {
        self.zmxExecutablePath = zmxExecutablePath
        self.zmxDirectoryPath = zmxDirectoryPath
        self.loginShellPath = loginShellPath
    }
}

/// Validates saved output before constructing a cold or fallback plan.
/// File work stays in ScrollbackStore; folder/notice derivation escapes
/// the caller's executor so App forwards only its existing input values.
package enum TerminalColdRestorePlanBuilder {
    @concurrent nonisolated package static func buildPlan(
        pane: Pane,
        sessionID: ZmxSessionID,
        launchPaths: TerminalColdRestoreLaunchPaths,
        repositoryMainFolder: URL?,
        scrollbackStore: ScrollbackStore
    ) async -> TerminalColdRestorePlan {
        let paneID = PaneId(existingUUID: pane.id)
        let replayFile: URL?
        switch await scrollbackStore.load(paneId: paneID) {
        case .present:
            replayFile = scrollbackStore.snapshotURL(for: paneID)
        case .absent, .unreadable:
            replayFile = nil
        }
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

        // Candidate text is composed, never replaced: R1's exact headline
        // and fallback reason remain first; R2 adds a separate line.
        if replayFile == nil {
            noticeLines = noticeLines.map { $0 + "\nno saved output" }
        }

        return TerminalColdRestorePlan(
            zmxExecutable: URL(fileURLWithPath: launchPaths.zmxExecutablePath),
            zmxDirectory: URL(fileURLWithPath: launchPaths.zmxDirectoryPath),
            sessionID: sessionID,
            loginShell: URL(fileURLWithPath: launchPaths.loginShellPath),
            folderCandidates: folderCandidates,
            notice: ColdRestoreNotice(linesByCandidateIndex: noticeLines),
            replayFile: replayFile,
            resume: nil,
            attemptID: .generate()
        )
    }
}
