import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("FilesystemActor Watched Folders")
struct FilesystemActorWatchedFolderTests {

    @Test("logical debt reaches zero only after watched-folder result transfer")
    func logicalDebtReachesZeroAfterResultTransfer() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }

        let refresh = Task {
            await fixture.actor.refreshWatchedFolders([fixture.watchedPath])
        }
        let start = try await fixture.scanner.nextStart()

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

        await fixture.shutdown()
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
        let initialStart = try await fixture.scanner.nextStart()
        let callbackRoutingID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
        #expect(initialStart.request.cause == .initialAdd)
        #expect(initialStart.request.sourceID.rootID == fixture.watchedPath.id)
        #expect(initialStart.request.sourceID.kind == .watchedParentMembership)
        #expect(callbackRoutingID != fixture.watchedPath.id)
        await fixture.scanner.finish(initialStart, with: completeResult(entries: []))
        _ = await initialRefresh.value

        await fixture.actor.handleWatchedFolderFSEvent(
            FSEventBatch(
                worktreeId: callbackRoutingID,
                paths: [fixture.watchedFolder.appending(path: "repo/.git/HEAD").path]
            )
        )
        _ = try await fixture.advancePacingDeadline()
        let callbackStart = try await fixture.scanner.nextStart()
        #expect(callbackStart.request.cause == .callback)

        let refresh = Task {
            await fixture.actor.refreshWatchedFolders([fixture.watchedPath])
        }
        await fixture.scanner.finish(
            callbackStart,
            with: completeResult(entries: [cloneEntry(repoFromInitialDemand)])
        )
        let exactManualStart = try await fixture.scanner.nextStart()
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
        await fixture.shutdown()
    }

    @Test("a hold released while a scan's acceptance is still in flight withholds that scan")
    func staleHeldScanCannotPublishAfterRelease() async throws {
        // Arrange
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        let clone = fixture.watchedFolder.appending(path: "repo")
        let destination = fixture.watchedFolder.appending(path: "repo.feature")
        _ = try await fixture.performInitialRefresh(result: completeResult(entries: [cloneEntry(clone)]))
        let holdID = await fixture.actor.holdWatchedFolderPublication(of: destination)
        await fixture.submissionGate.arm()
        let heldRefresh = Task { await fixture.actor.refreshWatchedFolders([fixture.watchedPath]) }
        let heldStart = try await fixture.scanner.nextStart()

        // Act: the scan has started but its acceptance has not reached the actor when the
        // hold is released; acceptance then returns and the scan's stale evidence applies.
        await fixture.actor.releaseWatchedFolderPublicationHold(holdID)
        await fixture.submissionGate.open()
        await fixture.scanner.finish(
            heldStart,
            with: completeResult(entries: [cloneEntry(clone), linkedEntry(destination, parentClone: clone)])
        )
        let staleSummary = await heldRefresh.value
        let freshSummary = try await fixture.performRefresh(
            result: completeResult(entries: [cloneEntry(clone), linkedEntry(destination, parentClone: clone)])
        )

        // Assert
        #expect(staleSummary.linkedWorktreePaths(in: fixture.watchedFolder).isEmpty)
        #expect(freshSummary.linkedWorktreePaths(in: fixture.watchedFolder) == [canonicalURL(destination)])
        await fixture.shutdown()
    }

    @Test("partial and cancelled results merge positives without removing prior inventory")
    func partialAndCancelledResultsAreAdditive() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }

        do {
            let clone = fixture.watchedFolder.appending(path: "app")
            let retainedClone = fixture.watchedFolder.appending(path: "retained")
            let linkedA = fixture.watchedFolder.appending(path: "app-a")
            let linkedB = fixture.watchedFolder.appending(path: "app-b")
            let linkedC = fixture.watchedFolder.appending(path: "app-c")
            _ = try await fixture.performInitialRefresh(
                result: completeResult(entries: [
                    cloneEntry(clone),
                    linkedEntry(linkedA, parentClone: clone),
                    cloneEntry(retainedClone),
                ])
            )

            try await fixture.consumeLatestTopologyObservation()

            let partialSummary = try await fixture.performRefresh(
                result: partialResult(entries: [
                    cloneEntry(clone),
                    linkedEntry(linkedB, parentClone: clone),
                ])
            )
            try await fixture.consumeLatestTopologyObservation()
            #expect(
                Set(partialSummary.repoPaths(in: fixture.watchedFolder))
                    == Set([canonicalURL(clone), canonicalURL(retainedClone)])
            )

            let cancelledSummary = try await fixture.performRefresh(
                result: cancelledResult(entries: [
                    cloneEntry(clone),
                    linkedEntry(linkedC, parentClone: clone),
                ])
            )
            #expect(
                Set(cancelledSummary.repoPaths(in: fixture.watchedFolder))
                    == Set([canonicalURL(clone), canonicalURL(retainedClone)])
            )

            try await fixture.consumeLatestTopologyObservation()
            let events = await fixture.consumedTopologyEvents()
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
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
    }

    @Test("concurrent manual refreshes serialize into distinct tracked scans")
    func concurrentManualRefreshesSerialize() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))

        let firstRefresh = Task {
            await fixture.actor.refreshWatchedFolders([fixture.watchedPath])
        }
        let firstManualStart = try await fixture.scanner.nextStart()
        #expect(firstManualStart.request.cause == .manual)

        let secondRefreshProbe = RefreshCompletionProbe()
        let secondRefresh = Task {
            let summary = await fixture.actor.refreshWatchedFolders([fixture.watchedPath])
            await secondRefreshProbe.record(summary)
        }
        await boundedYields()
        #expect(await fixture.scanner.startedQuantumCount() == 2)

        await fixture.scanner.finish(firstManualStart, with: completeResult(entries: []))
        _ = await firstRefresh.value
        let secondManualStart = try await fixture.scanner.nextStart()
        #expect(secondManualStart.request.cause == .manual)
        #expect(await secondRefreshProbe.summary() == nil)

        await fixture.scanner.finish(secondManualStart, with: completeResult(entries: []))
        await secondRefresh.value
        #expect(await secondRefreshProbe.summary() != nil)
        await fixture.shutdown()
    }

    @Test("exact complete result removes absent clones")
    func exactCompleteResultRemovesAbsentClones() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }

        do {
            let removedClone = fixture.watchedFolder.appending(path: "removed")
            let retainedClone = fixture.watchedFolder.appending(path: "retained")
            _ = try await fixture.performInitialRefresh(
                result: completeResult(entries: [
                    cloneEntry(removedClone),
                    cloneEntry(retainedClone),
                ])
            )
            try await fixture.consumeLatestTopologyObservation()
            await fixture.resetConsumedTopologyEvents()

            let summary = try await fixture.performRefresh(
                result: completeResult(entries: [cloneEntry(retainedClone)])
            )
            try await fixture.consumeLatestTopologyObservation()
            let events = await fixture.consumedTopologyEvents()

            #expect(summary.repoPaths(in: fixture.watchedFolder) == [canonicalURL(retainedClone)])
            #expect(events.discovered.isEmpty)
            #expect(events.removed == Set([canonicalURL(removedClone)]))
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
    }

    @Test("refresh summary fingerprints repository and linked-worktree identities")
    func refreshSummaryFingerprintsCompleteDiscoveredTopology() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        let clone = fixture.watchedFolder.appending(path: "clone")
        let firstLinkedWorktree = fixture.watchedFolder.appending(path: "linked-one")
        let secondLinkedWorktree = fixture.watchedFolder.appending(path: "linked-two")

        let firstSummary = try await fixture.performInitialRefresh(
            result: completeResult(entries: [
                cloneEntry(clone),
                linkedEntry(firstLinkedWorktree, parentClone: clone),
            ])
        )
        let secondSummary = try await fixture.performRefresh(
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
        await fixture.shutdown()
    }

    @Test("shutdown resumes a manual refresh with a pending scan result")
    func shutdownResumesPendingManualRefresh() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))

        let refresh = Task {
            await fixture.actor.refreshWatchedFolders([fixture.watchedPath])
        }
        let pendingManualStart = try await fixture.scanner.nextStart()
        #expect(pendingManualStart.request.cause == .manual)

        await fixture.shutdown()
        let summary = await refresh.value

        #expect(summary.repoPaths(in: fixture.watchedFolder).isEmpty)
    }

    @Test("unavailable and failed results preserve prior inventory")
    func unavailableAndFailedResultsPreservePriorInventory() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }

        let clone = fixture.watchedFolder.appending(path: "preserved")
        _ = try await fixture.performInitialRefresh(
            result: completeResult(entries: [cloneEntry(clone)])
        )
        await fixture.resetTopologyEventRecording()

        let unavailableSummary = try await fixture.performRefresh(result: unavailableResult())
        let failedSummary = try await fixture.performRefresh(result: failedResult())
        let events = await fixture.topologyEvents()

        #expect(unavailableSummary.repoPaths(in: fixture.watchedFolder) == [canonicalURL(clone)])
        #expect(failedSummary.repoPaths(in: fixture.watchedFolder) == [canonicalURL(clone)])
        #expect(events.discovered.isEmpty)
        #expect(events.removed.isEmpty)
        await fixture.shutdown()
    }

    @Test("removing a watched path retires scheduler registration and callback routing")
    func removalRetiresSchedulerRegistrationAndCallbackRouting() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        let clone = fixture.watchedFolder.appending(path: "removed-with-root")

        let initialRequest = try await fixture.performInitialRefreshReturningRequest(
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
            await fixture.shutdown()
            return
        }
        await fixture.shutdown()
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
    private enum StartFact: Sendable {
        case started(Start)
        case rejected(FilesystemSourceID)
    }
    enum StartFailure: Error { case rejectedSubmission(FilesystemSourceID) }

    private struct ActiveQuantum {
        let scanRunGeneration: UInt64
        let continuation: CheckedContinuation<RepoScannerQuantumOutcome, Never>
    }

    private struct SessionKey: Hashable {
        let sourceID: FilesystemSourceID
        let generation: UInt64
    }

    private var activeBySourceID: [FilesystemSourceID: ActiveQuantum] = [:]
    private var announcedSessions = Set<SessionKey>()
    private var nextReadOrdinal = 0
    private var isStopping = false
    private let cancellationTasks = WatchedFolderObservationTasks()
    private let startFacts = FactRecorder<Int, StartFact>(
        vocabulary: .init(
            describeScope: { "watched-folder scan start \($0)" },
            describeFact: { String(describing: $0) },
            isClosing: { _, _ in true }))
    private var totalStarted = 0
    private var nextFactOrdinal = 0

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
                let task = Task { await self.cancel(sourceID: request.sourceID, generation: scanRunGeneration) }
                self.cancellationTasks.retainObservation(task)
                return .cancellationRequested
            },
            consumeValidationCompletion: { _ in .rejected(.sessionFinished) }
        )
    }

    func nextStart(for sourceID: FilesystemSourceID? = nil) async throws -> Start {
        while true {
            nextReadOrdinal += 1
            let fact = try await startFacts.expectNext(
                in: nextReadOrdinal, where: { _ in true },
                "the next real scheduler scanner quantum or its source rejection")
            switch fact {
            case .started(let start):
                if let sourceID { #expect(start.request.sourceID == sourceID) }
                return start
            case .rejected(let rejectedSourceID):
                if let sourceID, sourceID != rejectedSourceID { continue }
                throw StartFailure.rejectedSubmission(rejectedSourceID)
            }
        }
    }

    func nextStart<Success: Sendable>(producedBy producer: Task<Success, Never>) async throws -> Start {
        let ordinal = nextReadOrdinal + 1
        let observer = Task {
            _ = await producer.value
            guard !Task.isCancelled else { return }
            self.retireMissingStart(ordinal)
        }
        cancellationTasks.retainObservation(observer)
        defer { observer.cancel() }
        return try await nextStart()
    }

    private func retireMissingStart(_ ordinal: Int) {
        if nextFactOrdinal < ordinal { startFacts.receive(.ended) }
    }

    func retireExpectedWatchSet() { startFacts.receive(.ended) }
    func rejectStart(sourceID: FilesystemSourceID) {
        nextFactOrdinal += 1
        startFacts.append(scope: nextFactOrdinal, fact: .rejected(sourceID))
    }
    func beginStopping() { isStopping = true }
    func finishStartObservations() async throws {
        await cancellationTasks.join()
        startFacts.receive(.ended)
        try await startFacts.finish()
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
        if isStopping || Task.isCancelled {
            startFacts.receive(.ended)
            return .finished(cancelledResult(entries: []))
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let start = Start(request: request, scanRunGeneration: scanRunGeneration)
                announcedSessions.insert(.init(sourceID: request.sourceID, generation: scanRunGeneration))
                activeBySourceID[request.sourceID] = ActiveQuantum(
                    scanRunGeneration: scanRunGeneration, continuation: continuation)
                totalStarted += 1
                nextFactOrdinal += 1
                startFacts.append(scope: nextFactOrdinal, fact: .started(start))
            }
        } onCancel: {
            let task = Task { await self.cancel(sourceID: request.sourceID, generation: scanRunGeneration) }
            self.cancellationTasks.retainObservation(task)
        }
    }

    private func cancel(sourceID: FilesystemSourceID, generation: UInt64) {
        if !announcedSessions.contains(.init(sourceID: sourceID, generation: generation)) {
            startFacts.receive(.ended)
        }
        guard let active = activeBySourceID[sourceID], active.scanRunGeneration == generation else { return }
        activeBySourceID.removeValue(forKey: sourceID)
        active.continuation.resume(returning: .finished(cancelledResult(entries: [])))
    }
}

struct WatchedFolderActorFixture {
    let clock: TestPushClock
    let submissionLog = WatchedFolderScanSubmissionLog()
    private let clockProbe: WatchedFolderScanPacingProbe?
    private let producerObservations = WatchedFolderObservationTasks()
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
    private let consumedObservations: FactRecorder<UInt64, WatchedFolderTopologyObservation>
    private let eventCollectionTask: Task<Void, Never>
    private let ingressTerminalTask: Task<Void, Never>
    private let ingressFenceFacts = FactRecorder<UInt64, Bool>(
        vocabulary: .init(
            describeScope: { "ingress fence \($0)" }, describeFact: { String($0) }, isClosing: { _, _ in true }))

    init(
        watchedFolderCount: Int = 1,
        recordsLogicalDebt: Bool = false,
        retentionNow: @escaping @Sendable () async throws -> RepositoryRetentionTime = {
            try await RepositoryRetentionTime.current()
        },
        performanceTraceRecorder suppliedRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        fseventClient: ControllableFSEventStreamClient = ControllableFSEventStreamClient(),
        clock: TestPushClock? = nil,
        onCallbackSubmission: @escaping @Sendable (WatchedFolderScanRequest) -> Void = { _ in }
    ) async throws {
        let paths = try makeWatchedFolderFixturePaths(count: watchedFolderCount)
        let watchedFolder = paths.root
        let watchedPaths = paths.paths
        let clockProbe = try WatchedFolderScanPacingProbe()
        let sleepClock = clock ?? clockProbe.clock
        let origin = sleepClock.now
        self.clock = sleepClock
        self.clockProbe = clock == nil ? clockProbe : nil
        let watchedPath = try #require(watchedPaths.first)
        let scanner = self.scanner
        let producerObservations = self.producerObservations
        fseventClient.setWatchRetirementObserver { _ in
            producerObservations.retainObservation(Task { await scanner.retireExpectedWatchSet() })
        }
        let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? =
            if let suppliedRecorder { suppliedRecorder } else if recordsLogicalDebt {
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
            now: { origin.duration(to: sleepClock.now) },
            validationExecutor: RepoScannerValidationExecutor(
                validationClient: ActorUnusedValidationClient()
            ),
            sessionFactory: { request, generation in
                await scanner.makeSession(request: request, scanRunGeneration: generation)
            }
        )
        let gatedSubmission = self.submissionGate.port
        let submissionLog = self.submissionLog
        let observedSubmission = WatchedFolderScanSubmissionPort { scheduler, request, intent in
            submissionLog.record(request, at: origin.duration(to: sleepClock.now))
            if request.cause == .callback { onCallbackSubmission(request) }
            let result = await gatedSubmission.submit(scheduler, request, intent)
            if case .rejected = result { await scanner.rejectStart(sourceID: request.sourceID) }
            return result
        }
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: fseventClient,
            watchedFolderScanScheduler: scheduler,
            watchedFolderScanSubmission: observedSubmission,
            sleepClock: sleepClock,
            debounceWindow: .zero,
            maxFlushLatency: .zero,
            retentionNow: retentionNow,
            performanceTraceRecorder: performanceTraceRecorder
        )
        let eventRecorder = TopologyEventRecorder()
        let consumedObservations = FactRecorder<UInt64, WatchedFolderTopologyObservation>(
            vocabulary: FactVocabulary(
                describeScope: { "observation sequence \($0)" },
                describeFact: { String(describing: $0.demandCoverage) },
                isClosing: { _, _ in true }
            ))
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)

        self.watchedFolder = watchedFolder
        self.fseventClient = fseventClient
        self.watchedPath = watchedPath
        self.watchedPaths = watchedPaths
        self.scheduler = scheduler
        self.actor = actor
        self.performanceTraceRecorder = performanceTraceRecorder
        self.eventRecorder = eventRecorder
        self.consumedObservations = consumedObservations
        let ingressFenceFacts = self.ingressFenceFacts
        let terminals = await actor.runtimeTerminals()
        fseventClient.setProcessingFenceObserver { ingressFenceFacts.append(scope: $0.rawValue, fact: true) }
        ingressTerminalTask = Task {
            for await _ in terminals {
                ingressFenceFacts.append(scope: 0, fact: true)
                ingressFenceFacts.receive(.ended)
                return
            }
            ingressFenceFacts.receive(.ended)
        }
        eventCollectionTask = Task {
            for await envelope in stream {
                await eventRecorder.record(envelope)
                if case .system(let system) = envelope,
                    case .topology(.watchedFolderReconciled(let observation)) = system.event
                {
                    consumedObservations.append(scope: system.seq, fact: observation)
                }
            }
            consumedObservations.receive(.ended)
        }
    }

    func performInitialRefresh(result: RepoScannerResult) async throws -> WatchedFolderRefreshSummary {
        let (_, summary) = try await runInitialRefresh(result: result)
        return summary
    }

    func performInitialRefreshReturningRequest(
        result: RepoScannerResult
    ) async throws -> WatchedFolderScanRequest {
        let (request, _) = try await runInitialRefresh(result: result)
        return request
    }

    private func runInitialRefresh(
        result: RepoScannerResult
    ) async throws -> (WatchedFolderScanRequest, WatchedFolderRefreshSummary) {
        let refresh = Task { await actor.refreshWatchedFolders([watchedPath]) }
        do {
            let initialStart = try await scanner.nextStart(producedBy: refresh)
            await scanner.finish(initialStart, with: result)
            return (initialStart.request, await refresh.value)
        } catch {
            await shutdown()
            _ = await refresh.value
            throw error
        }
    }

    func performRefresh(result: RepoScannerResult) async throws -> WatchedFolderRefreshSummary {
        let refresh = Task { await actor.refreshWatchedFolders([watchedPath]) }
        do {
            let start = try await scanner.nextStart(producedBy: refresh)
            await scanner.finish(start, with: result)
            return await refresh.value
        } catch {
            await shutdown()
            _ = await refresh.value
            throw error
        }
    }

    func consumeLatestTopologyObservation() async throws {
        let receipts = await actor.currentWatchedFolderObservationReceipts()
        let receipt = try #require(receipts.first { $0.observation.root == watchedFolder })
        let coverage = try #require(receipt.observation.demandCoverage)
        _ = try await consumedObservations.expectNext(
            in: receipt.sequence,
            where: { $0.root == receipt.observation.root && $0.demandCoverage == coverage },
            "collector consumed the refresh's covered observation"
        )
    }

    func resetConsumedTopologyEvents() async {
        await eventRecorder.reset()
    }

    func consumedTopologyEvents() async -> TopologyEventSet {
        await eventRecorder.snapshot()
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

    func finishNextScanWithEmptyResult() async throws {
        let start = try await scanner.nextStart()
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
        await scanner.beginStopping()
        producerObservations.cancelAll()
        await actor.shutdown()
        ingressTerminalTask.cancel()
        await ingressTerminalTask.value
        fseventClient.setProcessingFenceObserver(nil)
        eventCollectionTask.cancel()
        await eventCollectionTask.value
        await producerObservations.join()
        do { try await scanner.finishStartObservations() } catch { Issue.record(error) }
        do { try await clockProbe?.finish() } catch { Issue.record(error) }
        do { try await ingressFenceFacts.finish() } catch { Issue.record(error) }
    }

    func advancePacingDeadline() async throws -> [WatchedFolderScanSubmissionLog.Entry] {
        do {
            let task = try #require(await actor.watchedFolderScanState.pacingDeadlineTask)
            let probe = try #require(clockProbe)
            let deadline = try await probe.nextSleep(producedBy: task)
            clock.advance(to: deadline)
            await task.value
            return submissionLog.entries
        } catch {
            await shutdown()
            throw error
        }
    }

    /// The existing ingress protocol acknowledges this fence after all preceding batches and recoveries.
    func consumeIngressThroughFence() async throws {
        let fence = FSEventActivityProcessingFenceID(
            rawValue: UInt64(fseventClient.acknowledgedActivityProcessingFenceIDs.count + 1))
        fseventClient.sendActivityProcessingFence(fence)
        _ = try await ingressFenceFacts.expectNext(in: fence.rawValue, where: { $0 }, "preceding ingress was consumed")
    }

    func consumeIngressEnd() async throws {
        _ = try await ingressFenceFacts.expectNext(in: 0, where: { $0 }, "the ingress owner's events-ended fact")
    }

    func consumeTopologyObservation(sequence: UInt64) async throws -> WatchedFolderTopologyObservation {
        let producer = try #require(await actor.watchedFolderScanState.resultDrainState.task)
        let recorder = consumedObservations
        let observer = Task {
            await producer.value
            guard !Task.isCancelled else { return }
            recorder.receive(.lost(description: "watched-folder result producer ended before observation \(sequence)"))
        }
        producerObservations.retainObservation(observer)
        defer { observer.cancel() }
        return try await recorder.expectNext(
            in: sequence, where: { _ in true }, "applied watched-folder result \(sequence)")
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
