import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("FilesystemActor Watched Folders")
struct FilesystemActorWatchedFolderTests {
    @Test("one ingress batch records multiple watched overflow admissions once")
    func ingressBatchRecordsMultipleWatchedOverflowAdmissionsOnce() async throws {
        let fixture = try await WatchedFolderActorFixture(
            watchedFolderCount: 2,
            recordsLogicalDebt: true
        )
        defer { fixture.removeTemporaryRoot() }

        let initialRefresh = Task {
            await fixture.actor.refreshWatchedFolders(fixture.watchedPaths)
        }
        for _ in fixture.watchedPaths {
            await fixture.finishNextScanWithEmptyResult()
        }
        _ = await initialRefresh.value
        #expect(await fixture.waitUntilRecordedLogicalDebtEquals(0))

        let callbackRoutingIDs = fixture.fseventClient.registeredWorktreeIds
        #expect(callbackRoutingIDs.count == 2)
        let baselineRevision = await fixture.actor.logicalDebtSnapshotPublicationRevision
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

        #expect(await fixture.waitUntilAdmittedWatchedScanCount(2))
        let admittedRevision = await fixture.actor.logicalDebtSnapshotPublicationRevision
        #expect(admittedRevision == baselineRevision + 1)

        for _ in callbackRoutingIDs {
            await fixture.finishNextScanWithEmptyResult()
        }
        await fixture.actor.shutdown()
        try await fixture.performanceTraceRecorder?.drain()
    }

    @Test("logical debt reaches zero only after watched-folder result transfer")
    func logicalDebtReachesZeroAfterResultTransfer() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }

        let refresh = Task {
            await fixture.actor.refreshWatchedFolders([fixture.watchedPath])
        }
        let start = await fixture.scanner.nextStart()

        let runningSnapshot = await fixture.actor.logicalDebtSnapshot()
        #expect(runningSnapshot.watchedFolderActiveQuantumCount == 1)
        #expect(runningSnapshot.logicalDebtCount == 1)

        await fixture.scanner.finish(start, with: completeResult(entries: []))
        _ = await refresh.value
        let reachedZeroDebt = await waitUntilWatchedFolderLogicalDebt(
            fixture.actor,
            equals: 0
        )
        #expect(reachedZeroDebt)
        let finalSnapshot = await fixture.actor.logicalDebtSnapshot()
        #expect(finalSnapshot.watchedFolderReadyCount == 0)
        #expect(finalSnapshot.watchedFolderActiveQuantumCount == 0)
        #expect(finalSnapshot.watchedFolderAwaitingValidationCount == 0)
        #expect(finalSnapshot.watchedFolderPendingResultCount == 0)
        #expect(finalSnapshot.watchedFolderLeasedResultCount == 0)
        #expect(finalSnapshot.watchedFolderDirtyFollowUpCount == 0)
        #expect(finalSnapshot.logicalDebtCount == 0)

        await fixture.actor.shutdown()
    }

    @Test("binding result-drain state retains awaitable shutdown custody")
    func bindingResultDrainStateRetainsAwaitableShutdownCustody() async throws {
        let gate = ResultDrainTaskGate()
        let bindingTask = Task {
            await gate.pauseUntilReleased()
        }
        let state = FilesystemWatchedFolderResultDrainState.bindingConsumer(
            id: UUIDv7.generate(),
            task: bindingTask
        )

        await gate.waitUntilEntered()
        let shutdownCustodyTask = try #require(state.task)
        let completionProbe = ResultDrainTaskCompletionProbe()
        let shutdownWait = Task {
            await shutdownCustodyTask.value
            await completionProbe.recordCompletion()
        }

        await boundedYields()
        #expect(await completionProbe.isComplete == false)

        await gate.release()
        await shutdownWait.value
        #expect(await completionProbe.isComplete)
    }

    @Test("running result-drain state retains awaitable shutdown custody")
    func runningResultDrainStateRetainsAwaitableShutdownCustody() async throws {
        let gate = ResultDrainTaskGate()
        let runningTask = Task {
            await gate.pauseUntilReleased()
        }
        let state = FilesystemWatchedFolderResultDrainState.running(
            id: UUIDv7.generate(),
            task: runningTask
        )

        await gate.waitUntilEntered()
        let shutdownCustodyTask = try #require(state.task)
        let completionProbe = ResultDrainTaskCompletionProbe()
        let shutdownWait = Task {
            await shutdownCustodyTask.value
            await completionProbe.recordCompletion()
        }

        await boundedYields()
        #expect(await completionProbe.isComplete == false)

        await gate.release()
        await shutdownWait.value
        #expect(await completionProbe.isComplete)
    }

    @Test("manual refresh waits for the exact covered result")
    func manualRefreshWaitsForExactCoveredResult() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }

        let repoFromInitialDemand = fixture.watchedFolder.appending(path: "initial-repo")
        let repoFromManualDemand = fixture.watchedFolder.appending(path: "manual-repo")
        let initialRefresh = Task {
            await fixture.actor.refreshWatchedFolders([fixture.watchedPath])
        }
        let initialStart = await fixture.scanner.nextStart()
        let callbackRoutingID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
        #expect(initialStart.request.cause == .initialAdd)
        #expect(initialStart.request.sourceID.rootID == fixture.watchedPath.id)
        #expect(initialStart.request.sourceID.kind == .watchedParentMembership)
        #expect(callbackRoutingID != fixture.watchedPath.id)
        await fixture.scanner.finish(initialStart, with: completeResult(entries: []))
        _ = await initialRefresh.value

        fixture.fseventClient.send(
            FSEventBatch(
                worktreeId: callbackRoutingID,
                paths: [fixture.watchedFolder.appending(path: "repo/.git/HEAD").path]
            )
        )
        let callbackStart = await fixture.scanner.nextStart()
        #expect(callbackStart.request.cause == .callback)

        let refresh = Task {
            await fixture.actor.refreshWatchedFolders([fixture.watchedPath])
        }
        await fixture.scanner.finish(
            callbackStart,
            with: completeResult(entries: [cloneEntry(repoFromInitialDemand)])
        )
        let exactManualStart = await fixture.scanner.nextStart()
        #expect(exactManualStart.request.cause == .manual)

        let completionProbe = RefreshCompletionProbe()
        let observedRefresh = Task {
            let summary = await refresh.value
            await completionProbe.record(summary)
        }
        await boundedYields()
        #expect(await completionProbe.summary() == nil)

        await fixture.scanner.finish(
            exactManualStart,
            with: completeResult(entries: [cloneEntry(repoFromManualDemand)])
        )
        await observedRefresh.value

        #expect(
            await completionProbe.summary()?.repoPaths(in: fixture.watchedFolder)
                == [canonicalURL(repoFromManualDemand)]
        )
        await fixture.actor.shutdown()
    }

    @Test("a hold released while a scan's acceptance is still in flight withholds that scan")
    func staleHeldScanCannotPublishAfterRelease() async throws {
        // Arrange
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        let clone = fixture.watchedFolder.appending(path: "repo")
        let destination = fixture.watchedFolder.appending(path: "repo.feature")
        _ = await fixture.performInitialRefresh(result: completeResult(entries: [cloneEntry(clone)]))
        let holdID = await fixture.actor.holdWatchedFolderPublication(of: destination)
        await fixture.submissionGate.arm()
        let heldRefresh = Task { await fixture.actor.refreshWatchedFolders([fixture.watchedPath]) }
        let heldStart = await fixture.scanner.nextStart()

        // Act: the scan has started but its acceptance has not reached the actor when the
        // hold is released; acceptance then returns and the scan's stale evidence applies.
        await fixture.actor.releaseWatchedFolderPublicationHold(holdID)
        await fixture.submissionGate.open()
        await fixture.scanner.finish(
            heldStart,
            with: completeResult(entries: [cloneEntry(clone), linkedEntry(destination, parentClone: clone)])
        )
        let staleSummary = await heldRefresh.value
        let freshSummary = await fixture.performRefresh(
            result: completeResult(entries: [cloneEntry(clone), linkedEntry(destination, parentClone: clone)])
        )

        // Assert
        #expect(staleSummary.linkedWorktreePaths(in: fixture.watchedFolder).isEmpty)
        #expect(freshSummary.linkedWorktreePaths(in: fixture.watchedFolder) == [canonicalURL(destination)])
        await fixture.actor.shutdown()
    }

    @Test("partial and cancelled results merge positives without removing prior inventory")
    func partialAndCancelledResultsAreAdditive() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }

        let clone = fixture.watchedFolder.appending(path: "app")
        let retainedClone = fixture.watchedFolder.appending(path: "retained")
        let linkedA = fixture.watchedFolder.appending(path: "app-a")
        let linkedB = fixture.watchedFolder.appending(path: "app-b")
        let linkedC = fixture.watchedFolder.appending(path: "app-c")
        _ = await fixture.performInitialRefresh(
            result: completeResult(entries: [
                cloneEntry(clone),
                linkedEntry(linkedA, parentClone: clone),
                cloneEntry(retainedClone),
            ])
        )

        let partialSummary = await fixture.performRefresh(
            result: partialResult(entries: [
                cloneEntry(clone),
                linkedEntry(linkedB, parentClone: clone),
            ])
        )
        #expect(
            Set(partialSummary.repoPaths(in: fixture.watchedFolder))
                == Set([canonicalURL(clone), canonicalURL(retainedClone)])
        )

        let cancelledSummary = await fixture.performRefresh(
            result: cancelledResult(entries: [
                cloneEntry(clone),
                linkedEntry(linkedC, parentClone: clone),
            ])
        )
        #expect(
            Set(cancelledSummary.repoPaths(in: fixture.watchedFolder))
                == Set([canonicalURL(clone), canonicalURL(retainedClone)])
        )

        let events = await fixture.topologyEvents()
        #expect(
            events.discovered.contains(
                RepoDiscoveryEvent(
                    repoPath: canonicalURL(clone),
                    linkedWorktrees: .scanned([
                        canonicalURL(linkedA),
                        canonicalURL(linkedB),
                        canonicalURL(linkedC),
                    ])
                )
            )
        )
        #expect(events.removed.isEmpty)
        await fixture.actor.shutdown()
    }

    @Test("concurrent manual refreshes serialize into distinct tracked scans", arguments: [true, false])
    func concurrentManualRefreshesSerialize(failScan: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "held-manual-scan-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = HeldStep<WatchedFolderScanRequest>("initial scan", cancellation: .holdThroughCancellation)
        initial.release()
        let first = HeldStep<WatchedFolderScanRequest>("first manual scan", cancellation: .holdThroughCancellation)
        let second = HeldStep<WatchedFolderScanRequest>("second manual scan", cancellation: .holdThroughCancellation)
        let firstClone = canonicalURL(root.appending(path: "first"))
        let secondClone = canonicalURL(root.appending(path: "second"))
        let provider = FilesystemHeldScanProvider(
            steps: [initial, first, second],
            results: [
                completeResult(entries: []), completeResult(entries: [cloneEntry(firstClone)]),
                completeResult(entries: [cloneEntry(firstClone), cloneEntry(secondClone)]),
            ])
        let scheduler = try await provider.makeScheduler()
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(), fseventStreamClient: ControllableFSEventStreamClient(),
            watchedFolderScanScheduler: scheduler, sleepClock: TestPushClock(),
            debounceWindow: .zero, maxFlushLatency: .zero)
        let watchedPath = WatchedPath(path: root)
        let initialRefresh = Task { await actor.refreshWatchedFolders([watchedPath]) }
        _ = try await initial.firstArrival()
        #expect(await initialRefresh.value.repoPaths(in: root).isEmpty)
        let firstRefresh = Task { await actor.refreshWatchedFolders([watchedPath]) }
        let firstRequest = try await first.firstArrival()
        #expect(firstRequest.cause == .manual)
        #expect(firstRequest.sourceID.rootID == watchedPath.id)
        #expect(await provider.startedSessionCount() == 2)
        let secondRefresh = Task { await actor.refreshWatchedFolders([watchedPath]) }
        if failScan { first.fail(FilesystemHeldScanFailure.unavailable) } else { first.release() }
        let firstSummary = await firstRefresh.value
        let secondRequest = try await second.firstArrival()
        #expect(secondRequest.cause == .manual)
        #expect(secondRequest.sourceID == firstRequest.sourceID)
        #expect(await provider.startedSessionCount() == 3)
        if failScan { second.fail(FilesystemHeldScanFailure.unavailable) } else { second.release() }
        let secondSummary = await secondRefresh.value
        await actor.shutdown()
        #expect(firstSummary.repoPaths(in: root) == (failScan ? [] : [firstClone]))
        #expect(secondSummary.repoPaths(in: root) == (failScan ? [] : [firstClone, secondClone]))
    }

    @Test("exact complete result removes absent clones")
    func exactCompleteResultRemovesAbsentClones() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }

        let removedClone = fixture.watchedFolder.appending(path: "removed")
        let retainedClone = fixture.watchedFolder.appending(path: "retained")
        _ = await fixture.performInitialRefresh(
            result: completeResult(entries: [
                cloneEntry(removedClone),
                cloneEntry(retainedClone),
            ])
        )
        await fixture.resetTopologyEventRecording()

        let summary = await fixture.performRefresh(
            result: completeResult(entries: [cloneEntry(retainedClone)])
        )
        let events = await fixture.topologyEvents()

        #expect(summary.repoPaths(in: fixture.watchedFolder) == [canonicalURL(retainedClone)])
        #expect(events.discovered.isEmpty)
        #expect(events.removed == Set([canonicalURL(removedClone)]))
        await fixture.actor.shutdown()
    }

    @Test("refresh summary fingerprints repository and linked-worktree identities")
    func refreshSummaryFingerprintsCompleteDiscoveredTopology() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        let clone = fixture.watchedFolder.appending(path: "clone")
        let firstLinkedWorktree = fixture.watchedFolder.appending(path: "linked-one")
        let secondLinkedWorktree = fixture.watchedFolder.appending(path: "linked-two")

        let firstSummary = await fixture.performInitialRefresh(
            result: completeResult(entries: [
                cloneEntry(clone),
                linkedEntry(firstLinkedWorktree, parentClone: clone),
            ])
        )
        let secondSummary = await fixture.performRefresh(
            result: completeResult(entries: [
                cloneEntry(clone),
                linkedEntry(firstLinkedWorktree, parentClone: clone),
                linkedEntry(secondLinkedWorktree, parentClone: clone),
            ])
        )

        #expect(firstSummary.repoPaths(in: fixture.watchedFolder) == [canonicalURL(clone)])
        #expect(
            firstSummary.linkedWorktreePaths(in: fixture.watchedFolder)
                == [canonicalURL(firstLinkedWorktree)]
        )
        #expect(firstSummary.topologyFingerprint != nil)
        #expect(secondSummary.topologyFingerprint != firstSummary.topologyFingerprint)
        await fixture.actor.shutdown()
    }

    @Test("shutdown resumes a manual refresh with a pending scan result")
    func shutdownResumesPendingManualRefresh() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        _ = await fixture.performInitialRefresh(result: completeResult(entries: []))

        let refresh = Task {
            await fixture.actor.refreshWatchedFolders([fixture.watchedPath])
        }
        let pendingManualStart = await fixture.scanner.nextStart()
        #expect(pendingManualStart.request.cause == .manual)

        await fixture.actor.shutdown()
        let summary = await refresh.value

        #expect(summary.repoPaths(in: fixture.watchedFolder).isEmpty)
    }

    @Test("unavailable and failed results preserve prior inventory")
    func unavailableAndFailedResultsPreservePriorInventory() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }

        let clone = fixture.watchedFolder.appending(path: "preserved")
        _ = await fixture.performInitialRefresh(
            result: completeResult(entries: [cloneEntry(clone)])
        )
        await fixture.resetTopologyEventRecording()

        let unavailableSummary = await fixture.performRefresh(result: unavailableResult())
        let failedSummary = await fixture.performRefresh(result: failedResult())
        let events = await fixture.topologyEvents()

        #expect(unavailableSummary.repoPaths(in: fixture.watchedFolder) == [canonicalURL(clone)])
        #expect(failedSummary.repoPaths(in: fixture.watchedFolder) == [canonicalURL(clone)])
        #expect(events.discovered.isEmpty)
        #expect(events.removed.isEmpty)
        await fixture.actor.shutdown()
    }

    @Test("ordinary file callbacks preserve scope while Git topology requests a scan")
    func ordinaryFileCallbacksPreserveScopeWhileGitRequestsScan() async throws {
        let scenario = try await WatchedFolderCallbackScenario()
        let fixture = scenario.fixture
        defer { fixture.removeTemporaryRoot() }
        do {
            _ = await fixture.performInitialRefresh(result: completeResult(entries: []))
            let baselineCount = await fixture.scanner.startedQuantumCount()
            try await scenario.rejectScan(.path("repo/.gitignore"), closingID: 1, baselineCount: baselineCount)
            try await scenario.rejectScan(
                .overflow(paths: nil, requiresScan: false, trigger: "repo/Sources/TriggerCoarse.swift"),
                closingID: 2, baselineCount: baselineCount)
            try await scenario.rejectScan(
                .overflow(
                    paths: ["repo/Sources/Dropped.swift"], requiresScan: false, trigger: "repo/Sources/Trigger.swift"),
                closingID: 3, baselineCount: baselineCount)
            let gitStart = try await scenario.requireScan(
                .path("repo/.git/HEAD"), closingID: 4, expectedCount: baselineCount + 1)
            #expect(gitStart.request.cause == .callback)
            let refsStart = try await scenario.requireScan(
                .overflow(
                    paths: ["repo/.git/refs/heads/main"], requiresScan: false, trigger: "repo/Sources/Trigger.swift"),
                closingID: 5, expectedCount: baselineCount + 2)
            #expect(refsStart.request.cause == .callback)
            let coarseStart = try await scenario.requireScan(
                .overflow(paths: nil, requiresScan: true, trigger: "repo/Sources/TriggerCoarseGit.swift"),
                closingID: 6, expectedCount: baselineCount + 3)
            #expect(coarseStart.request.cause == .callback)
            try await scenario.shutdown()
        } catch {
            try? await scenario.shutdown()
            throw error
        }
    }

    @Test("removing a watched path retires scheduler registration and callback routing")
    func removalRetiresSchedulerRegistrationAndCallbackRouting() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        let clone = fixture.watchedFolder.appending(path: "removed-with-root")

        let initialRequest = await fixture.performInitialRefreshReturningRequest(
            result: completeResult(entries: [cloneEntry(clone)])
        )
        let callbackRoutingID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
        await fixture.resetTopologyEventRecording()

        let summary = await fixture.actor.refreshWatchedFolders([])
        let events = await fixture.topologyEvents()
        let staleSubmission = await fixture.scheduler.submit(initialRequest)

        #expect(summary.repoPathsByWatchedFolder.isEmpty)
        #expect(fixture.fseventClient.unregisteredWorktreeIds == [callbackRoutingID])
        #expect(events.removed == Set([canonicalURL(clone)]))
        guard case .rejected(.staleRegistration) = staleSubmission else {
            Issue.record("retired watched-folder registration accepted a stale scan request")
            await fixture.actor.shutdown()
            return
        }
        await fixture.actor.shutdown()
    }
}

private actor ResultDrainTaskGate {
    private enum State {
        case awaitingEntry(entryWaiters: [CheckedContinuation<Void, Never>])
        case entered(releaseWaiters: [CheckedContinuation<Void, Never>])
        case released
    }

    private var state = State.awaitingEntry(entryWaiters: [])

    func pauseUntilReleased() async {
        let entryWaiters: [CheckedContinuation<Void, Never>]
        switch state {
        case .awaitingEntry(let retainedEntryWaiters):
            entryWaiters = retainedEntryWaiters
            state = .entered(releaseWaiters: [])
        case .entered, .released:
            preconditionFailure("result-drain task gate supports exactly one entry")
        }
        for entryWaiter in entryWaiters {
            entryWaiter.resume()
        }

        await withCheckedContinuation { continuation in
            switch state {
            case .awaitingEntry:
                preconditionFailure("result-drain task gate must enter before waiting for release")
            case .entered(var releaseWaiters):
                releaseWaiters.append(continuation)
                state = .entered(releaseWaiters: releaseWaiters)
            case .released:
                continuation.resume()
            }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            switch state {
            case .awaitingEntry(var entryWaiters):
                entryWaiters.append(continuation)
                state = .awaitingEntry(entryWaiters: entryWaiters)
            case .entered, .released:
                continuation.resume()
            }
        }
    }

    func release() {
        switch state {
        case .awaitingEntry:
            preconditionFailure("result-drain task gate cannot release before entry")
        case .entered(let releaseWaiters):
            state = .released
            for releaseWaiter in releaseWaiters {
                releaseWaiter.resume()
            }
        case .released:
            return
        }
    }
}

private actor ResultDrainTaskCompletionProbe {
    private enum State {
        case pending
        case complete
    }

    private var state = State.pending

    var isComplete: Bool {
        switch state {
        case .pending:
            false
        case .complete:
            true
        }
    }

    func recordCompletion() {
        state = .complete
    }
}

actor ControlledActorWatchedFolderScanner {
    struct Start: Sendable {
        let request: WatchedFolderScanRequest
        let scanRunGeneration: UInt64
    }

    private struct ActiveQuantum {
        let continuation: CheckedContinuation<RepoScannerQuantumOutcome, Never>
    }

    private var activeBySourceID: [FilesystemSourceID: ActiveQuantum] = [:]
    private var bufferedStarts: [Start] = []
    private var startWaiters: [CheckedContinuation<Start, Never>] = []
    private var totalStarted = 0

    func makeSession(
        request: WatchedFolderScanRequest,
        scanRunGeneration: UInt64
    ) -> WatchedFolderScannerSessionPort {
        WatchedFolderScannerSessionPort(
            id: RepoScannerSessionID(rawValue: UUIDv7.generate()),
            advanceOneQuantum: {
                await self.advance(request: request, scanRunGeneration: scanRunGeneration)
            },
            cancel: {
                Task { await self.cancel(sourceID: request.sourceID) }
                return .cancellationRequested
            },
            consumeValidationCompletion: { _ in .rejected(.sessionFinished) }
        )
    }

    func nextStart() async -> Start {
        if !bufferedStarts.isEmpty { return bufferedStarts.removeFirst() }
        return await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish(_ start: Start, with result: RepoScannerResult) {
        guard let active = activeBySourceID.removeValue(forKey: start.request.sourceID) else {
            Issue.record("expected an active watched-folder scanner quantum")
            return
        }
        active.continuation.resume(returning: .finished(result))
    }

    func startedQuantumCount() -> Int { totalStarted }

    private func advance(
        request: WatchedFolderScanRequest,
        scanRunGeneration: UInt64
    ) async -> RepoScannerQuantumOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let start = Start(request: request, scanRunGeneration: scanRunGeneration)
                activeBySourceID[request.sourceID] = ActiveQuantum(continuation: continuation)
                totalStarted += 1
                if startWaiters.isEmpty {
                    bufferedStarts.append(start)
                } else {
                    startWaiters.removeFirst().resume(returning: start)
                }
            }
        } onCancel: {
            Task { await self.cancel(sourceID: request.sourceID) }
        }
    }

    private func cancel(sourceID: FilesystemSourceID) {
        guard let active = activeBySourceID.removeValue(forKey: sourceID) else { return }
        active.continuation.resume(returning: .finished(cancelledResult(entries: [])))
    }
}

struct WatchedFolderActorFixture {
    let scanner = ControlledActorWatchedFolderScanner()
    let submissionGate = WatchedFolderScanAcceptanceGate()
    let bus = EventBus<RuntimeEnvelope>()
    let fseventClient: ControllableFSEventStreamClient
    let watchedFolder: URL
    let watchedPath: WatchedPath
    let watchedPaths: [WatchedPath]
    let scheduler: WatchedFolderScanScheduler
    let actor: FilesystemActor
    let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?

    private let eventRecorder: TopologyEventRecorder
    private let eventCollectionTask: Task<Void, Never>

    init(
        watchedFolderCount: Int = 1,
        recordsLogicalDebt: Bool = false,
        fseventClient: ControllableFSEventStreamClient = ControllableFSEventStreamClient(),
        onCallbackSubmission: @escaping @Sendable (WatchedFolderScanRequest) -> Void = { _ in },
        observedStreamClient: (any FSEventStreamClient)? = nil
    ) async throws {
        precondition(watchedFolderCount > 0)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "filesystem-actor-watched-folder-\(UUIDv7.generate())")
        let watchedFolder = URL(fileURLWithPath: temporaryRoot.path)
        try FileManager.default.createDirectory(at: watchedFolder, withIntermediateDirectories: true)
        let watchedPaths =
            if watchedFolderCount == 1 {
                [WatchedPath(path: watchedFolder)]
            } else {
                try (0..<watchedFolderCount).map { index in
                    let path = watchedFolder.appending(path: "root-\(index)")
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                    return WatchedPath(path: path)
                }
            }
        let watchedPath = try #require(watchedPaths.first)
        let scanner = self.scanner
        let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? =
            if recordsLogicalDebt {
                AgentStudioPerformanceTraceRecorder(
                    traceRuntime: AgentStudioTraceRuntime(
                        configuration: AgentStudioTraceConfiguration.from(environment: [
                            "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                            "AGENTSTUDIO_TRACE_DIR": FileManager.default.temporaryDirectory.path,
                            "AGENTSTUDIO_TRACE_NAME": "watched-overflow-admission-\(UUIDv7.generate())",
                            "AGENTSTUDIO_TRACE_TAGS": "performance",
                        ])
                    ),
                    processMemorySampleWait: { false }
                )
            } else {
                nil
            }
        let scheduler = try WatchedFolderScanScheduler(
            maximumConcurrentScans: 1,
            now: { .zero },
            validationExecutor: RepoScannerValidationExecutor(
                validationClient: ActorUnusedValidationClient()
            ),
            sessionFactory: { request, generation in
                await scanner.makeSession(request: request, scanRunGeneration: generation)
            }
        )
        let gatedSubmission = self.submissionGate.port
        let observedSubmission = WatchedFolderScanSubmissionPort { scheduler, request, intent in
            if request.cause == .callback { onCallbackSubmission(request) }
            return await gatedSubmission.submit(scheduler, request, intent)
        }
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: observedStreamClient ?? fseventClient,
            watchedFolderScanScheduler: scheduler,
            watchedFolderScanSubmission: observedSubmission,
            debounceWindow: .zero,
            maxFlushLatency: .zero,
            performanceTraceRecorder: performanceTraceRecorder
        )
        let eventRecorder = TopologyEventRecorder()
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)

        self.watchedFolder = watchedFolder
        self.fseventClient = fseventClient
        self.watchedPath = watchedPath
        self.watchedPaths = watchedPaths
        self.scheduler = scheduler
        self.actor = actor
        self.performanceTraceRecorder = performanceTraceRecorder
        self.eventRecorder = eventRecorder
        eventCollectionTask = Task {
            for await envelope in stream {
                await eventRecorder.record(envelope)
            }
        }
    }

    func performInitialRefresh(result: RepoScannerResult) async -> WatchedFolderRefreshSummary {
        let (_, summary) = await runInitialRefresh(result: result)
        return summary
    }

    func performInitialRefreshReturningRequest(
        result: RepoScannerResult
    ) async -> WatchedFolderScanRequest {
        let (request, _) = await runInitialRefresh(result: result)
        return request
    }

    private func runInitialRefresh(
        result: RepoScannerResult
    ) async -> (WatchedFolderScanRequest, WatchedFolderRefreshSummary) {
        let refresh = Task { await actor.refreshWatchedFolders([watchedPath]) }
        let initialStart = await scanner.nextStart()
        await scanner.finish(initialStart, with: result)
        return (initialStart.request, await refresh.value)
    }

    func performRefresh(result: RepoScannerResult) async -> WatchedFolderRefreshSummary {
        let refresh = Task { await actor.refreshWatchedFolders([watchedPath]) }
        let start = await scanner.nextStart()
        await scanner.finish(start, with: result)
        return await refresh.value
    }

    func resetTopologyEventRecording() async {
        await boundedYields()
        await eventRecorder.reset()
    }

    func topologyEvents() async -> TopologyEventSet {
        await boundedYields()
        return await eventRecorder.snapshot()
    }

    func waitForStartedQuantumCount(_ expectedCount: Int) async throws {
        for _ in 0..<10_000 {
            if await scanner.startedQuantumCount() == expectedCount { return }
            await Task.yield()
        }
        Issue.record("scanner did not reach expected quantum count \(expectedCount)")
        throw WatchedFolderActorTestError.expectedScannerProgress
    }

    func finishNextScanWithEmptyResult() async {
        let start = await scanner.nextStart()
        await scanner.finish(start, with: completeResult(entries: []))
    }

    func waitUntilRecordedLogicalDebtEquals(_ expectedCount: Int) async -> Bool {
        for _ in 0..<10_000 {
            if await actor.lastRecordedLogicalDebtSnapshot?.logicalDebtCount == expectedCount {
                return true
            }
            await Task.yield()
        }
        return await actor.lastRecordedLogicalDebtSnapshot?.logicalDebtCount == expectedCount
    }

    func waitUntilAdmittedWatchedScanCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<10_000 {
            let snapshot = await actor.logicalDebtSnapshot()
            if snapshot.watchedFolderActiveQuantumCount + snapshot.watchedFolderReadyCount
                == expectedCount
            {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func removeTemporaryRoot() {
        eventCollectionTask.cancel()
        try? FileManager.default.removeItem(at: watchedFolder)
    }

    func shutdown() async {
        await actor.shutdown()
        eventCollectionTask.cancel()
        await eventCollectionTask.value
    }
}

private actor RefreshCompletionProbe {
    private var recordedSummary: WatchedFolderRefreshSummary?

    func record(_ summary: WatchedFolderRefreshSummary) {
        recordedSummary = summary
    }

    func summary() -> WatchedFolderRefreshSummary? { recordedSummary }
}

private struct ActorUnusedValidationClient: RepoDiscoveryReadClient {
    func validateDiscoveryCandidate(at candidateURL: URL) async -> GitRepositoryDiscoveryOutcome {
        .failure(.serviceFailed(detail: "unexpected actor test validation request"))
    }
}

private func boundedYields() async {
    for _ in 0..<200 {
        await Task.yield()
    }
}

private func waitUntilWatchedFolderLogicalDebt(
    _ actor: FilesystemActor,
    equals expectedCount: Int,
    maxTurns: Int = 10_000
) async -> Bool {
    for _ in 0..<maxTurns {
        if await actor.logicalDebtSnapshot().logicalDebtCount == expectedCount {
            return true
        }
        await Task.yield()
    }
    return await actor.logicalDebtSnapshot().logicalDebtCount == expectedCount
}

private enum WatchedFolderActorTestError: Error {
    case expectedScannerProgress
}
