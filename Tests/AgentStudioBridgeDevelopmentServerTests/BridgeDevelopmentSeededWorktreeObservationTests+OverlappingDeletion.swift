import AgentStudioCore
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgeDevelopmentSeededWorktreeObservationTests {
    @Test("a refresh reserved before deletion observes and commits the later real Git deletion")
    func earlierRefreshReservationCommitsPostOpeningDeletion() async throws {
        // Arrange a real host and Git provider; hold after reservation, before construction.
        let root = try await FilesystemTestGitRepo.create(named: "seeded-overlapping-deletion")
        defer { FilesystemTestGitRepo.destroy(root) }
        let trackedFile = root.appending(path: "tracked.txt")
        try "initial\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: root, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: root, args: ["commit", "-m", "Initial"])
        try "initial\nupdated\n".write(to: trackedFile, atomically: false, encoding: .utf8)
        let preparation = HeldStep<String>("earlier Review refresh before real Git construction")
        let terminal = HeldStep<BridgeOperationLifecycleTraceEvent>("earlier Review refresh terminal after commit")
        let recorder = SeededReviewLifecycleRecorder(
            reviewPreparationStep: preparation, reviewTerminalStep: terminal)
        let source = BridgeDevelopmentObservationFixture.makeSource(root: root)
        let host = try await makeReviewCommitObservedHost(
            source: source, statusPhysicalGate: AgentStudioGitStatusPhysicalGate(), lifecycle: recorder)
        do {
            _ = try await host.issueBootstrap(for: seededReviewBootstrapRequest())
            let baseline = try await recorder.nextCommittedPublication()
            #expect(baseline.package.itemsById.values.contains { $0.headPath == "tracked.txt" })
            await host.handleObservedWorktreeInvalidation(
                .statusChanged(
                    GitWorkingTreeStatus(
                        summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                        branch: nil, origin: nil)))
            let earlierCorrelation = try await preparation.firstArrival()
            let opening = recorder.openDeletionObservation()

            // Act: the already-reserved operation reads only after deletion.
            try FileManager.default.removeItem(at: trackedFile)
            preparation.release()
            let operationTerminal = try await terminal.firstArrival()
            #expect(operationTerminal.operationCorrelationID == earlierCorrelation)
            #expect(operationTerminal.result == .success)
            let committed = try #require(await host.diagnosticCommittedReviewPublication())
            #expect(committed.operationCorrelationID == earlierCorrelation)
            #expect(committed.package.revision > baseline.package.revision)
            #expect(committed.package.itemsById.values.contains { $0.basePath == "tracked.txt" && $0.headPath == nil })
            terminal.release()
            #expect(await host.shutdown() == .completed)
            let shutdown = await host.shutdownSnapshot()
            #expect(shutdown.cleanupCompleted)
            #expect(shutdown.unfinishedDrainCount == 0)
            try await recorder.finish()

            // The actual operation ended and its source was shut down. No successor is owed.
            let observed = try await recorder.requireCommittedDeletion(
                path: "tracked.txt", after: opening, baseline: baseline)
            #expect(observed == committed)
        } catch {
            preparation.release()
            terminal.release()
            await host.shutdown()
            try await recorder.finish()
            throw error
        }
    }
}
