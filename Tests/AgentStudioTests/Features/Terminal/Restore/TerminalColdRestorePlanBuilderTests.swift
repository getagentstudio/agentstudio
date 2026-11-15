import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioTerminal

/// SR3, SR6a; Program Design item 2. Complements the quoting/structure proof
/// in `ZmxBackendTests` (`buildColdRestoreCommand`) with proof of the plan
/// itself: the folder fallback chain and per-attempt id freshness.
@Suite
struct TerminalColdRestorePlanBuilderTests {
    @Test("the folder fallback chain is saved, then repository main, then home, in that order")
    func fallbackChainOrder() async throws {
        // Arrange
        let savedFolder = URL(fileURLWithPath: "/tmp/saved-folder")
        let repoMainFolder = URL(fileURLWithPath: "/tmp/repo-main-folder")
        let pane = makeTerminalPane(
            sessionID: try makeRestoredZmxSessionID("as-plan-builder-fallback"),
            launchDirectory: savedFolder
        )

        // Act
        let plan = await TerminalColdRestorePlanBuilder.buildPlan(
            pane: pane,
            sessionID: try makeRestoredZmxSessionID("as-plan-builder-fallback"),
            launchPaths: TerminalColdRestoreLaunchPaths(
                zmxExecutablePath: "/usr/local/bin/zmx",
                zmxDirectoryPath: "/tmp/zmx-dir",
                loginShellPath: "/bin/zsh"),
            repositoryMainFolder: repoMainFolder, scrollbackStore: emptyScrollbackStore()
        )

        // Assert — saved, repository main, then home last
        #expect(plan.folderCandidates.count == 3)
        #expect(plan.folderCandidates[0] == savedFolder)
        #expect(plan.folderCandidates[1] == repoMainFolder)
        #expect(plan.folderCandidates[2] == FileManager.default.homeDirectoryForCurrentUser)
        #expect(plan.notice.linesByCandidateIndex.count == 3)
    }

    @Test("a missing saved folder skips straight to the repository main folder, then home")
    func skipsMissingSavedFolder() async throws {
        // Arrange
        let pane = makeTerminalPane(
            sessionID: try makeRestoredZmxSessionID("as-plan-builder-no-saved"),
            launchDirectory: nil
        )
        let repoMainFolder = URL(fileURLWithPath: "/tmp/repo-main-only")

        // Act
        let plan = await TerminalColdRestorePlanBuilder.buildPlan(
            pane: pane,
            sessionID: try makeRestoredZmxSessionID("as-plan-builder-no-saved"),
            launchPaths: TerminalColdRestoreLaunchPaths(
                zmxExecutablePath: "/usr/local/bin/zmx",
                zmxDirectoryPath: "/tmp/zmx-dir",
                loginShellPath: "/bin/zsh"),
            repositoryMainFolder: repoMainFolder, scrollbackStore: emptyScrollbackStore()
        )

        // Assert
        #expect(plan.folderCandidates == [repoMainFolder, FileManager.default.homeDirectoryForCurrentUser])
    }

    @Test("no saved folder and no repository main folder leaves only home")
    func fallsAllTheWayToHomeAlone() async throws {
        // Arrange
        let pane = makeTerminalPane(
            sessionID: try makeRestoredZmxSessionID("as-plan-builder-home-only"),
            launchDirectory: nil
        )

        // Act
        let plan = await TerminalColdRestorePlanBuilder.buildPlan(
            pane: pane,
            sessionID: try makeRestoredZmxSessionID("as-plan-builder-home-only"),
            launchPaths: TerminalColdRestoreLaunchPaths(
                zmxExecutablePath: "/usr/local/bin/zmx",
                zmxDirectoryPath: "/tmp/zmx-dir",
                loginShellPath: "/bin/zsh"),
            repositoryMainFolder: nil, scrollbackStore: emptyScrollbackStore()
        )

        // Assert
        #expect(plan.folderCandidates == [FileManager.default.homeDirectoryForCurrentUser])
        #expect(plan.notice.linesByCandidateIndex.count == 1)
    }

    @Test("two panes each get their own, distinct stored attempt id")
    func twoPanesProduceTwoDistinctAttemptIDs() async throws {
        // Arrange
        let firstPane = makeTerminalPane(sessionID: try makeRestoredZmxSessionID("as-plan-builder-pane-one"))
        let secondPane = makeTerminalPane(sessionID: try makeRestoredZmxSessionID("as-plan-builder-pane-two"))

        // Act
        let firstPlan = await TerminalColdRestorePlanBuilder.buildPlan(
            pane: firstPane,
            sessionID: try makeRestoredZmxSessionID("as-plan-builder-pane-one"),
            launchPaths: TerminalColdRestoreLaunchPaths(
                zmxExecutablePath: "/usr/local/bin/zmx",
                zmxDirectoryPath: "/tmp/zmx-dir",
                loginShellPath: "/bin/zsh"),
            repositoryMainFolder: nil, scrollbackStore: emptyScrollbackStore()
        )
        let secondPlan = await TerminalColdRestorePlanBuilder.buildPlan(
            pane: secondPane,
            sessionID: try makeRestoredZmxSessionID("as-plan-builder-pane-two"),
            launchPaths: TerminalColdRestoreLaunchPaths(
                zmxExecutablePath: "/usr/local/bin/zmx",
                zmxDirectoryPath: "/tmp/zmx-dir",
                loginShellPath: "/bin/zsh"),
            repositoryMainFolder: nil, scrollbackStore: emptyScrollbackStore()
        )

        // Assert — each pane keeps its own stored session id, and each
        // attempt mints its own fresh, distinct attempt id.
        #expect(firstPlan.sessionID != secondPlan.sessionID)
        #expect(firstPlan.attemptID != secondPlan.attemptID)
    }

    private func emptyScrollbackStore() -> ScrollbackStore {
        ScrollbackStore(
            directoryURL: FileManager.default.temporaryDirectory.appending(
                path: "cold-plan-empty-\(UUIDv7.generate().uuidString)"))
    }

    private func makeTerminalPane(
        sessionID: ZmxSessionID,
        launchDirectory: URL? = URL(filePath: "/tmp")
    ) -> Pane {
        Pane(
            content: .terminal(
                TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: sessionID)
            ),
            metadata: PaneMetadata(
                launchDirectory: launchDirectory,
                title: "Terminal"
            )
        )
    }
}
