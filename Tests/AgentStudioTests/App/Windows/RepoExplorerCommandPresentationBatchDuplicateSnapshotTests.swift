import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

extension RepoExplorerCommandPresentationBatchTests {
    @Test("duplicate visible snapshot skips capture while changed membership and target refresh")
    func duplicateVisibleSnapshotSkipsCaptureWhileChangesRefresh() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let traceDirectory = FileManager.default.temporaryDirectory.appending(
                path: "repo-command-duplicate-capture-\(UUIDv7.generate().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: traceDirectory) }
            let runtime = AgentStudioTraceRuntime(
                configuration: AgentStudioTraceConfiguration.from(environment: [
                    "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                    "AGENTSTUDIO_TRACE_DIR": traceDirectory.path,
                    "AGENTSTUDIO_TRACE_NAME": "repo-command-duplicate-capture",
                    "AGENTSTUDIO_TRACE_TAGS": "performance",
                ]),
                processIdentifier: 932,
                timeUnixNano: { 932 }
            )
            let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: runtime)
            let store = WorkspaceStore()
            let firstRepo = store.addRepo(
                at: FileManager.default.temporaryDirectory.appending(
                    path: "repo-command-duplicate-first-\(UUIDv7.generate().uuidString)"
                )
            )
            let secondRepo = store.addRepo(
                at: FileManager.default.temporaryDirectory.appending(
                    path: "repo-command-duplicate-second-\(UUIDv7.generate().uuidString)"
                )
            )
            let firstWorktree = try #require(firstRepo.worktrees.first)
            let secondWorktree = try #require(secondRepo.worktrees.first)
            let hostLifetimeID = RepoExplorerMaterializationHostLifetimeID(
                rawValue: UUIDv7.generate()
            )
            let initialVisibleSnapshot = makeVisibleWorktreeSnapshot(
                hostLifetimeID: hostLifetimeID,
                worktreeIDs: [firstWorktree.id, secondWorktree.id]
            )
            let dispatcher = CommandDispatcherFixtureConfiguration().makeDispatcher()
            let batch = RepoExplorerCommandPresentationBatch(
                store: store,
                repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(),
                resolveCommandCapabilities: {
                    dispatcher.repoExplorerCommandPresentationSnapshot(requests: $0, generation: $1)
                },
                executionOwnerIdentities: dispatcher.executionOwnerIdentities,
                performanceTraceRecorder: recorder
            )
            batch.start()
            defer { batch.stop() }

            batch.acceptVisibleWorktreeSnapshot(initialVisibleSnapshot)
            let initialDelta = try #require(batch.latestDelta)

            batch.acceptVisibleWorktreeSnapshot(
                RepoExplorerVisibleWorktreeSnapshot(
                    target: initialVisibleSnapshot.target,
                    worktreeIDs: [secondWorktree.id, firstWorktree.id]
                )
            )
            #expect(batch.latestDelta == initialDelta)

            batch.acceptVisibleWorktreeSnapshot(
                RepoExplorerVisibleWorktreeSnapshot(
                    target: initialVisibleSnapshot.target,
                    worktreeIDs: [firstWorktree.id]
                )
            )
            let membershipDelta = try #require(batch.latestDelta)
            #expect(membershipDelta.commandGeneration > initialDelta.commandGeneration)
            #expect(membershipDelta.affectedWorktreeIDs.contains(secondWorktree.id))

            let refreshedTarget = RepoExplorerCommandPresentationTarget(
                materializationHostLifetimeID: hostLifetimeID,
                materializationGeneration: 2,
                visibleRevision: 2
            )
            batch.acceptVisibleWorktreeSnapshot(
                RepoExplorerVisibleWorktreeSnapshot(
                    target: refreshedTarget,
                    worktreeIDs: [firstWorktree.id]
                )
            )
            #expect(batch.latestDelta?.target == refreshedTarget)
            try await recorder.drain()

            let outputFileURL = try #require(runtime.outputFileURL)
            let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
            let captureCount = contents.split(separator: "\n").count { line in
                line.contains("\"body\":\"performance.repo_explorer.command_presentation\"")
            }
            #expect(captureCount == 3)

            let visibleSnapshotTriggerCount = contents.split(separator: "\n").count { line in
                line.contains("\"body\":\"performance.repo_explorer.command_presentation\"")
                    && line.contains(
                        "\"agentstudio.performance.repo_explorer.wake_trigger\":\"visible_snapshot\""
                    )
            }
            #expect(visibleSnapshotTriggerCount == 3)
        }
    }

    private func makeVisibleWorktreeSnapshot(
        hostLifetimeID: RepoExplorerMaterializationHostLifetimeID,
        worktreeIDs: Set<UUID>
    ) -> RepoExplorerVisibleWorktreeSnapshot {
        RepoExplorerVisibleWorktreeSnapshot(
            target: RepoExplorerCommandPresentationTarget(
                materializationHostLifetimeID: hostLifetimeID,
                materializationGeneration: 1,
                visibleRevision: 1
            ),
            worktreeIDs: worktreeIDs
        )
    }
}
