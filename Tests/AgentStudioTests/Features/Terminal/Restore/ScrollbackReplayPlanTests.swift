import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioTerminal

@Suite("Validated scrollback replay plans")
struct ScrollbackReplayPlanTests {
    @Test("a validated snapshot is replayed for the exact pane before the restart notice")
    func presentSnapshotSetsReplayFile() async throws {
        try await withStore { store, _ in
            let pane = makePane()
            let paneID = PaneId(existingUUID: pane.id)
            _ = try await store.store(paneId: paneID, capture: Data("  saved output\r\n".utf8))
            let plan = await buildPlan(pane: pane, store: store)
            #expect(plan.replayFile == store.snapshotURL(for: paneID))
            #expect(plan.notice.linesByCandidateIndex == originalCandidateNotices)
            #expect(plan.notice.linesByCandidateIndex.allSatisfy { $0.lowercased().contains("restored after restart") })
            #expect(plan.notice.linesByCandidateIndex.allSatisfy { !$0.contains("no saved output") })
            #expect(plan.sessionID == pane.terminalState?.zmxSessionID)
            #expect(plan.resume == nil)
        }
    }

    @Test("an absent snapshot supplies no replay file and explains every folder fallback")
    func absentSnapshotExplainsNoSavedOutput() async throws {
        try await withStore { store, _ in
            let pane = makePane()
            let plan = await buildPlan(pane: pane, store: store)
            #expect(plan.replayFile == nil)
            #expect(plan.notice.linesByCandidateIndex.allSatisfy { $0.contains("no saved output") })
            expectComposedNoOutputNotice(plan)
            #expect(plan.notice.linesByCandidateIndex.count == plan.folderCandidates.count)
        }
    }

    @Test("unreadable snapshots are never replayed", arguments: InvalidSnapshot.allCases)
    func invalidSnapshotExplainsNoSavedOutput(invalid: InvalidSnapshot) async throws {
        try await withStore { store, _ in
            let pane = makePane()
            let snapshotURL = store.snapshotURL(for: PaneId(existingUUID: pane.id))
            try await withoutBlockingCooperativePool {
                try FileManager.default.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch invalid {
                case .empty: try Data().write(to: snapshotURL)
                case .oversized:
                    try Data(repeating: 0x61, count: AppPolicies.Restore.snapshotByteCap + 1).write(to: snapshotURL)
                case .invalidUTF8: try Data([0xFF]).write(to: snapshotURL)
                case .directory:
                    try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
                }
            }
            guard case .unreadable = await store.load(paneId: PaneId(existingUUID: pane.id)) else {
                Issue.record("fixture must exercise a rejected snapshot")
                return
            }
            let plan = await buildPlan(pane: pane, store: store)
            #expect(plan.replayFile == nil)
            #expect(plan.notice.linesByCandidateIndex.allSatisfy { $0.contains("no saved output") })
            expectComposedNoOutputNotice(plan)
        }
    }

    @Test("two panes cannot replay each other's snapshot")
    func replayPathsArePaneScoped() async throws {
        try await withStore { store, _ in
            let firstPane = makePane()
            let secondPane = makePane()
            let firstID = PaneId(existingUUID: firstPane.id)
            let secondID = PaneId(existingUUID: secondPane.id)
            _ = try await store.store(paneId: firstID, capture: Data("first pane".utf8))
            _ = try await store.store(paneId: secondID, capture: Data("second pane".utf8))
            let firstPlan = await buildPlan(pane: firstPane, store: store)
            let secondPlan = await buildPlan(pane: secondPane, store: store)
            #expect(firstPlan.replayFile == store.snapshotURL(for: firstID))
            #expect(secondPlan.replayFile == store.snapshotURL(for: secondID))
            #expect(firstPlan.replayFile != secondPlan.replayFile)
        }
    }

    enum InvalidSnapshot: CaseIterable, Sendable { case empty, oversized, invalidUTF8, directory }

    private func makePane() -> Pane {
        Pane(
            id: UUIDv7.generate(),
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata(launchDirectory: URL(fileURLWithPath: "/tmp/saved-folder"), title: "Replay plan"))
    }

    private func buildPlan(pane: Pane, store: ScrollbackStore) async -> TerminalColdRestorePlan {
        guard let sessionID = pane.terminalState?.zmxSessionID else {
            preconditionFailure("fixture requires a terminal pane")
        }
        return await TerminalColdRestorePlanBuilder.buildPlan(
            pane: pane, sessionID: sessionID,
            launchPaths: TerminalColdRestoreLaunchPaths(
                zmxExecutablePath: "/usr/local/bin/zmx", zmxDirectoryPath: "/tmp/zmx-dir", loginShellPath: "/bin/zsh"),
            repositoryMainFolder: URL(fileURLWithPath: "/tmp/repository-main-folder"), scrollbackStore: store)
    }

    // Independent R1 expectation: the async builder no longer exposes a
    // separate unvalidated construction path for deriving expected text.
    private var originalCandidateNotices: [String] {
        [
            "Restored after restart",
            "Restored after restart (saved folder missing; using the repository's main folder)",
            "Restored after restart (saved and repository folders missing; using the home folder)",
        ]
    }

    private func expectComposedNoOutputNotice(_ plan: TerminalColdRestorePlan) {
        let baseLines = originalCandidateNotices
        #expect(plan.notice.linesByCandidateIndex.count == baseLines.count)
        for (line, baseLine) in zip(plan.notice.linesByCandidateIndex, baseLines) {
            let components = line.components(separatedBy: "\n")
            #expect(components.first == baseLine, "R1's headline and folder-fallback reason must remain the first line")
            #expect(components.dropFirst().contains("no saved output"), "R2 adds a separate line after the R1 notice")
        }
    }

    private func withStore(_ body: (ScrollbackStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "scrollback-replay-plan-\(UUIDv7.generate().uuidString)")
        let store = ScrollbackStore(directoryURL: root)
        var bodyError: (any Error)?
        do { try await body(store, root) } catch { bodyError = error }
        try await withoutBlockingCooperativePool {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        if let bodyError { throw bodyError }
    }
}
