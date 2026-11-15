import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension FilesystemActorWatchedFolderTests {
    @Test("one ingress batch records multiple watched overflow admissions once")
    func ingressBatchRecordsMultipleWatchedOverflowAdmissionsOnce() async throws {
        let telemetry = WatchedScanRecordingTelemetry()
        let fixture = try await WatchedFolderActorFixture(
            watchedFolderCount: 2,
            recordsLogicalDebt: true,
            performanceTraceRecorder: telemetry.recorder
        )
        defer { fixture.removeTemporaryRoot() }

        let initialRefresh = Task {
            await fixture.actor.refreshWatchedFolders(fixture.watchedPaths)
        }
        for _ in fixture.watchedPaths {
            try await fixture.finishNextScanWithEmptyResult()
        }
        _ = await initialRefresh.value
        #expect(await fixture.waitUntilRecordedLogicalDebtEquals(0))

        let callbackRoutingIDs = fixture.fseventClient.registeredWorktreeIds
        #expect(callbackRoutingIDs.count == 2)
        for callbackRoutingID in callbackRoutingIDs {
            fixture.fseventClient.sendOverflowRecovery(
                worktreeId: callbackRoutingID,
                paths: nil,
                requiresWatchedFolderScan: true
            )
        }
        fixture.fseventClient.send(
            FSEventBatch(
                worktreeId: try #require(callbackRoutingIDs.first),
                paths: [fixture.watchedFolder.appending(path: "ordinary-trigger").path]
            )
        )
        try await fixture.consumeIngressThroughFence()
        let baselineRevision = await fixture.actor.logicalDebtSnapshotPublicationRevision
        _ = try await fixture.advancePacingDeadline()

        #expect(await fixture.waitUntilAdmittedWatchedScanCount(2))
        let admittedRevision = await fixture.actor.logicalDebtSnapshotPublicationRevision
        #expect(admittedRevision == baselineRevision + 1)

        for _ in callbackRoutingIDs {
            try await fixture.finishNextScanWithEmptyResult()
        }
        await fixture.shutdown()
        try await fixture.performanceTraceRecorder?.drain()
        let records = await telemetry.sink.overflowRecords()
        #expect(records.count == 2)
        for record in records {
            #expect(
                record.attributes["agentstudio.performance.filesystem.registration_kind"] == .string("watched_folder"))
            let projected = AgentStudioOTLPTraceProjection.project(record)
            #expect(
                projected.attributes["agentstudio.performance.filesystem.registration_kind"]
                    == .string("watched_folder"))
            let metrics = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projected))
            #expect(metrics.dimensionTuples.contains { $0 == ("registration_kind", "watched_folder") })
        }
    }

    @Test("ordinary file callbacks preserve scope while Git topology requests a scan")
    func ordinaryFileCallbacksPreserveScopeWhileGitRequestsScan() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))

        let callbackRoutingID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
        let scanCountBeforeCallbacks = await fixture.scanner.startedQuantumCount()
        fixture.fseventClient.send(
            FSEventBatch(
                worktreeId: callbackRoutingID,
                paths: [fixture.watchedFolder.appending(path: "repo/.gitignore").path]
            )
        )
        try await fixture.consumeIngressThroughFence()
        #expect(await fixture.scanner.startedQuantumCount() == scanCountBeforeCallbacks)

        fixture.fseventClient.sendOverflowRecovery(
            worktreeId: callbackRoutingID,
            paths: nil,
            requiresWatchedFolderScan: false
        )
        fixture.fseventClient.send(
            FSEventBatch(
                worktreeId: callbackRoutingID,
                paths: [fixture.watchedFolder.appending(path: "repo/Sources/TriggerCoarse.swift").path]
            )
        )
        try await fixture.consumeIngressThroughFence()
        #expect(await fixture.scanner.startedQuantumCount() == scanCountBeforeCallbacks)

        fixture.fseventClient.sendOverflowRecovery(
            worktreeId: callbackRoutingID,
            paths: [fixture.watchedFolder.appending(path: "repo/Sources/Dropped.swift").path]
        )
        fixture.fseventClient.send(
            FSEventBatch(
                worktreeId: callbackRoutingID,
                paths: [fixture.watchedFolder.appending(path: "repo/Sources/Trigger.swift").path]
            )
        )
        try await fixture.consumeIngressThroughFence()
        #expect(await fixture.scanner.startedQuantumCount() == scanCountBeforeCallbacks)

        fixture.fseventClient.send(
            FSEventBatch(
                worktreeId: callbackRoutingID,
                paths: [fixture.watchedFolder.appending(path: "repo/.git/HEAD").path]
            )
        )
        try await fixture.consumeIngressThroughFence()
        _ = try await fixture.advancePacingDeadline()
        let callbackStart = try await fixture.scanner.nextStart()
        #expect(callbackStart.request.cause == .callback)
        #expect(callbackStart.request.sourceID.rootID == fixture.watchedPath.id)
        await fixture.scanner.finish(callbackStart, with: completeResult(entries: []))
        try await fixture.waitForStartedQuantumCount(scanCountBeforeCallbacks + 1)

        fixture.fseventClient.sendOverflowRecovery(
            worktreeId: callbackRoutingID,
            paths: [fixture.watchedFolder.appending(path: "repo/.git/refs/heads/main").path]
        )
        fixture.fseventClient.send(
            FSEventBatch(
                worktreeId: callbackRoutingID,
                paths: [fixture.watchedFolder.appending(path: "repo/Sources/Trigger.swift").path]
            )
        )
        try await fixture.consumeIngressThroughFence()
        _ = try await fixture.advancePacingDeadline()
        let overflowRecoveryStart = try await fixture.scanner.nextStart()
        #expect(overflowRecoveryStart.request.cause == .callback)
        await fixture.scanner.finish(overflowRecoveryStart, with: completeResult(entries: []))
        try await fixture.waitForStartedQuantumCount(scanCountBeforeCallbacks + 2)

        fixture.fseventClient.sendOverflowRecovery(
            worktreeId: callbackRoutingID,
            paths: nil,
            requiresWatchedFolderScan: true
        )
        fixture.fseventClient.send(
            FSEventBatch(
                worktreeId: callbackRoutingID,
                paths: [fixture.watchedFolder.appending(path: "repo/Sources/TriggerCoarseGit.swift").path]
            )
        )
        try await fixture.consumeIngressThroughFence()
        _ = try await fixture.advancePacingDeadline()
        let coarseGitRecoveryStart = try await fixture.scanner.nextStart()
        #expect(coarseGitRecoveryStart.request.cause == .callback)
        await fixture.scanner.finish(coarseGitRecoveryStart, with: completeResult(entries: []))
        try await fixture.waitForStartedQuantumCount(scanCountBeforeCallbacks + 3)
        await fixture.shutdown()
    }

}
