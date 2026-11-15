import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Watched-folder scan scheduler")
struct WatchedFolderScanSchedulerTests {
    @Test("logical dirty follow-up count includes queued, pending, and leased custody")
    func logicalDirtyFollowUpCountIncludesAllRetainedCustody() async throws {
        let queuedFixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let suspended = try queuedFixture.makeRequest(name: "dirty-suspended")
        let blocker = try queuedFixture.makeRequest(name: "dirty-blocker")
        _ = await queuedFixture.scheduler.submit(suspended)
        let suspendedStart = await queuedFixture.scanner.nextStart()
        _ = await queuedFixture.scheduler.submit(blocker)
        _ = await queuedFixture.scheduler.submit(
            WatchedFolderScanRequest(canonicalRoot: suspended.canonicalRoot, cause: .callback)
        )
        await queuedFixture.scanner.suspend(suspendedStart)
        _ = await queuedFixture.scanner.nextStart()

        guard case .active(let queuedState) = await queuedFixture.scheduler.stateSnapshot() else {
            Issue.record("expected active queued-suspended dirty state")
            return
        }
        #expect(queuedState.dirtyFollowUps == 1)
        await queuedFixture.scheduler.shutdown()

        let resultFixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let resultRequest = try resultFixture.makeRequest(name: "dirty-result")
        _ = await resultFixture.scheduler.submit(resultRequest)
        let resultStart = await resultFixture.scanner.nextStart()
        _ = await resultFixture.scheduler.submit(
            WatchedFolderScanRequest(canonicalRoot: resultRequest.canonicalRoot, cause: .callback)
        )
        await resultFixture.scanner.finish(resultStart, with: completeResult())
        try await resultFixture.waitForPendingResultCount(1)

        guard case .active(let pendingState) = await resultFixture.scheduler.stateSnapshot() else {
            Issue.record("expected active pending-result dirty state")
            return
        }
        #expect(pendingState.dirtyFollowUps == 1)

        let lease = try await resultFixture.nextLease()
        guard case .active(let leasedState) = await resultFixture.scheduler.stateSnapshot() else {
            Issue.record("expected active leased-result dirty state")
            return
        }
        #expect(leasedState.dirtyFollowUps == 1)
        #expect(await resultFixture.transfer(lease) == .transferred)
        guard case .active(let transferredState) = await resultFixture.scheduler.stateSnapshot() else {
            Issue.record("expected active transferred dirty follow-up state")
            return
        }
        #expect(transferredState.dirtyFollowUps == 0)
        await resultFixture.scheduler.shutdown()
    }

    @Test("queued collapse retains exact coverage through the newest demand")
    func queuedCollapseRetainsNewestDemandCoverage() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let blocker = try fixture.makeRequest(name: "coverage-blocker")
        let queued = try fixture.makeRequest(name: "coverage-queued", cause: .initialAdd)

        _ = await fixture.scheduler.submit(blocker)
        let blockerStart = await fixture.scanner.nextStart()
        let initialReceipt = try trackedReceipt(
            from: await fixture.scheduler.submit(queued, intent: .tracked)
        )
        let callbackReceipt = try trackedReceipt(
            from: await fixture.scheduler.submit(
                WatchedFolderScanRequest(
                    canonicalRoot: queued.canonicalRoot,
                    cause: .callback
                ),
                intent: .tracked
            )
        )
        let manualReceipt = try trackedReceipt(
            from: await fixture.scheduler.submit(
                WatchedFolderScanRequest(
                    canonicalRoot: queued.canonicalRoot,
                    cause: .manual
                ),
                intent: .tracked
            )
        )

        await fixture.scanner.finish(blockerStart, with: completeResult())
        #expect(await fixture.transfer(try await fixture.nextLease()) == .transferred)
        let queuedStart = await fixture.scanner.nextStart()
        await fixture.scanner.finish(queuedStart, with: completeResult())
        let result = try await fixture.nextLease()

        #expect(result.result.demandCoverage.covers(initialReceipt))
        #expect(result.result.demandCoverage.covers(callbackReceipt))
        #expect(result.result.demandCoverage.covers(manualReceipt))
        #expect(
            result.result.demandCoverage.throughDemandGeneration
                == manualReceipt.demandGeneration
        )
        #expect(await fixture.transfer(result) == .transferred)
        await fixture.scheduler.shutdown()
    }

    @Test("tracked demand while running is covered only by the dirty follow-up")
    func runningTrackedDemandRequiresDirtyFollowUpCoverage() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let initial = try fixture.makeRequest(name: "running-coverage", cause: .initialAdd)
        _ = try trackedReceipt(
            from: await fixture.scheduler.submit(initial, intent: .tracked)
        )
        let initialStart = await fixture.scanner.nextStart()
        let manualReceipt = try trackedReceipt(
            from: await fixture.scheduler.submit(
                WatchedFolderScanRequest(
                    canonicalRoot: initial.canonicalRoot,
                    cause: .manual
                ),
                intent: .tracked
            )
        )

        await fixture.scanner.finish(initialStart, with: completeResult())
        let initialResult = try await fixture.nextLease()
        #expect(!initialResult.result.demandCoverage.covers(manualReceipt))
        #expect(await fixture.transfer(initialResult) == .transferred)

        let followUpStart = await fixture.scanner.nextStart()
        await fixture.scanner.finish(followUpStart, with: completeResult())
        let followUpResult = try await fixture.nextLease()
        #expect(followUpResult.result.demandCoverage.covers(manualReceipt))
        #expect(await fixture.transfer(followUpResult) == .transferred)
        await fixture.scheduler.shutdown()
    }

    @Test("replacement registration cannot satisfy an old demand receipt")
    func replacementRegistrationCannotSatisfyOldReceipt() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let original = try fixture.makeRequest(name: "receipt-root", registrationGeneration: 1)
        let replacement = try fixture.makeRequest(
            name: "receipt-root",
            sourceID: original.sourceID,
            registrationGeneration: 2
        )
        let originalReceipt = try trackedReceipt(
            from: await fixture.scheduler.submit(original, intent: .tracked)
        )
        let originalStart = await fixture.scanner.nextStart()
        let replacementReceipt = try trackedReceipt(
            from: await fixture.scheduler.submit(replacement, intent: .tracked)
        )

        await fixture.scanner.finish(originalStart, with: completeResult())
        let replacementStart = await fixture.scanner.nextStart()
        await fixture.scanner.finish(replacementStart, with: completeResult())
        let replacementResult = try await fixture.nextLease()

        #expect(!replacementResult.result.demandCoverage.covers(originalReceipt))
        #expect(replacementResult.result.demandCoverage.covers(replacementReceipt))
        #expect(await fixture.transfer(replacementResult) == .transferred)
        await fixture.scheduler.shutdown()
    }

    @Test("demand generation exhaustion rejects without admission or mutation")
    func demandGenerationExhaustionDoesNotMutateState() async throws {
        let root = try SchedulerFixture.makeRoot(name: "demand-exhausted")
        let fixture = try SchedulerFixture(
            maximumConcurrentScans: 1,
            initialDemandGenerations: [
                root.sourceID: WatchedFolderScanDemandGeneration(rawValue: UInt64.max)
            ]
        )
        let before = await fixture.scheduler.stateSnapshot()
        let request = WatchedFolderScanRequest(canonicalRoot: root, cause: .manual)

        #expect(
            await fixture.scheduler.submit(request, intent: .tracked)
                == .rejected(.demandGenerationExhausted(root.sourceID))
        )
        #expect(await fixture.scheduler.stateSnapshot() == before)
        #expect(await fixture.scheduler.currentRootBySourceID[root.sourceID] == nil)
        #expect(await fixture.scanner.startedQuantumCount() == 0)
        await fixture.scheduler.shutdown()
    }

    @Test("tracked demand receipt identity is UUIDv7")
    func trackedDemandReceiptUsesUUIDv7() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let request = try fixture.makeRequest(name: "receipt-identity")

        let receipt = try trackedReceipt(
            from: await fixture.scheduler.submit(request, intent: .tracked)
        )

        #expect(UUIDv7.isV7(receipt.id.rawValue))
        let start = await fixture.scanner.nextStart()
        await fixture.scanner.finish(start, with: completeResult())
        #expect(await fixture.transfer(try await fixture.nextLease()) == .transferred)
        await fixture.scheduler.shutdown()
    }

    @Test("untracked submission returns exact admitted coverage without a query")
    func untrackedSubmissionReturnsExactCoverage() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let request = try fixture.makeRequest(name: "untracked-coverage")

        let submission = await fixture.scheduler.submit(request, intent: .untracked)
        guard case .accepted(let acceptance) = submission else {
            Issue.record("expected an accepted untracked watched-folder scan demand")
            throw SchedulerTestError.expectedUntrackedAcceptance
        }
        guard case .untracked(let admittedCoverage, .started) = acceptance else {
            Issue.record("expected exact untracked coverage and started disposition")
            throw SchedulerTestError.expectedUntrackedAcceptance
        }
        let start = await fixture.scanner.nextStart()
        await fixture.scanner.finish(start, with: completeResult())
        let result = try await fixture.nextLease()

        #expect(acceptance.coverage == admittedCoverage)
        #expect(result.result.demandCoverage.covers(admittedCoverage))
        #expect(await fixture.transfer(result) == .transferred)
        await fixture.scheduler.shutdown()
    }

    @Test("terminal-result custody bounds scanning until transfer")
    func terminalResultCustodyBoundsScanning() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 2)
        let first = try fixture.makeRequest(name: "first")
        let second = try fixture.makeRequest(name: "second")
        let third = try fixture.makeRequest(name: "third")

        _ = await fixture.scheduler.submit(first)
        _ = await fixture.scheduler.submit(second)
        _ = await fixture.scheduler.submit(third)
        let firstStart = await fixture.scanner.nextStart()
        let secondStart = await fixture.scanner.nextStart()
        await fixture.scanner.finish(firstStart, with: completeResult())
        await fixture.scanner.finish(secondStart, with: completeResult())

        #expect(await fixture.scanner.startedQuantumCount() == 2)
        try await fixture.waitForState(
            .active(
                WatchedFolderScanSchedulerActiveState(
                    ready: 1,
                    activeQuanta: 0,
                    awaitingValidations: 0,
                    pendingResults: 2,
                    leasedResults: 0,
                    dirtyFollowUps: 0,
                    resultCustodyHighWater: 2
                )
            )
        )

        let firstLease = try await fixture.nextLease()
        #expect(await fixture.transfer(firstLease) == .transferred)
        let thirdStart = await fixture.scanner.nextStart()
        #expect(thirdStart.request.sourceID == third.sourceID)
        await fixture.scanner.finish(thirdStart, with: completeResult())

        try await fixture.transferAllResults(expectedCount: 2)
        await fixture.scheduler.shutdown()
        #expect(await fixture.scheduler.stateSnapshot() == .shutDown)
    }

    @Test("suspension requeues the same logical generation and dirty follow-up waits for transfer")
    func suspensionPreservesGenerationAndDefersDirtyFollowUp() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let request = try fixture.makeRequest(name: "root", cause: .initialAdd)

        _ = await fixture.scheduler.submit(request)
        let firstQuantum = await fixture.scanner.nextStart()
        _ = await fixture.scheduler.submit(
            WatchedFolderScanRequest(canonicalRoot: request.canonicalRoot, cause: .callback)
        )
        await fixture.scanner.suspend(firstQuantum)
        let secondQuantum = await fixture.scanner.nextStart()
        #expect(secondQuantum.scanRunGeneration == firstQuantum.scanRunGeneration)
        await fixture.scanner.finish(secondQuantum, with: completeResult())

        let initialLease = try await fixture.nextLease()
        #expect(initialLease.result.scanRunGeneration == 1)
        #expect(initialLease.result.schedulingMetrics.quantumSelectionCount == 2)
        #expect(initialLease.result.schedulingMetrics.followUpEvidence == .dirtyFollowUpQueued)
        #expect(await fixture.scanner.startedQuantumCount() == 2)

        #expect(await fixture.transfer(initialLease) == .transferred)
        let followUp = await fixture.scanner.nextStart()
        #expect(followUp.scanRunGeneration == 2)
        await fixture.scanner.finish(followUp, with: completeResult())
        let followUpLease = try await fixture.nextLease()
        #expect(followUpLease.result.schedulingMetrics.followUpEvidence == .startedFromDirtyFollowUp)
        #expect(await fixture.transfer(followUpLease) == .transferred)
        await fixture.scheduler.shutdown()
    }

    @Test(
        "round-robin quantum selection serves every ready root without sleeps",
        arguments: [10, 100, 300]
    )
    func roundRobinQuantumSelection(rootCount: Int) async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let requests = try (0..<rootCount).map { index in
            try fixture.makeRequest(name: "root-\(index)")
        }
        for request in requests { _ = await fixture.scheduler.submit(request) }

        var selectedSourceIDs: Set<FilesystemSourceID> = []
        for _ in 0..<rootCount {
            let selection = await fixture.scanner.nextStart()
            selectedSourceIDs.insert(selection.request.sourceID)
            await fixture.scanner.suspend(selection)
        }

        #expect(selectedSourceIDs.count == rootCount)
        await fixture.scheduler.shutdown()
    }

    @Test(
        "ready selection increments diagnostic counters once per selection across fleet sizes",
        arguments: [10, 100, 300]
    )
    func readySelectionDiagnosticCountersIncrementPerSelection(rootCount: Int) async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let requests = try (0..<rootCount).map { index in
            try fixture.makeRequest(name: "inspection-root-\(index)")
        }
        _ = await fixture.scheduler.submit(requests[0])
        var active = await fixture.scanner.nextStart()
        for request in requests.dropFirst() { _ = await fixture.scheduler.submit(request) }

        let before = await fixture.scheduler.readySelectionInspection()
        for _ in 0..<4 {
            await fixture.scanner.suspend(active)
            active = await fixture.scanner.nextStart()
        }
        let after = await fixture.scheduler.readySelectionInspection()

        #expect(after.scheduledRootCount == rootCount)
        #expect(after.selectionCount - before.selectionCount == 4)
        #expect(after.workUnitCount - before.workUnitCount == 4)
        await fixture.scheduler.shutdown()
    }

    @Test("retry re-presents the identical final result")
    func retryRepresentsIdenticalFinalResult() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let request = try fixture.makeRequest(name: "retry")
        _ = await fixture.scheduler.submit(request)
        let start = await fixture.scanner.nextStart()
        await fixture.scanner.finish(start, with: completeResult())

        let firstLease = try await fixture.nextLease()
        #expect(await fixture.retry(firstLease) == .queuedForRetry)
        let secondLease = try await fixture.nextLease()
        #expect(secondLease.result == firstLease.result)
        #expect(secondLease.leaseID != firstLease.leaseID)
        #expect(await fixture.transfer(secondLease) == .transferred)
        await fixture.scheduler.shutdown()
    }

    @Test("cancelled result waiter releases exclusive consumer for rebind")
    func cancelledWaiterAllowsConsumerRebind() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        #expect(await fixture.scheduler.bindResultConsumer(fixture.consumer) == .bound)
        let waitTask = Task {
            await fixture.scheduler.nextResultLease(for: fixture.consumer)
        }
        waitTask.cancel()
        #expect(await waitTask.value == .cancelled)
        #expect(await fixture.scheduler.unbindResultConsumer(fixture.consumer) == .unbound)

        let replacement = WatchedFolderScanResultConsumerToken.make()
        #expect(await fixture.scheduler.bindResultConsumer(replacement) == .bound)
        await fixture.scheduler.shutdown()
        #expect(await fixture.scheduler.stateSnapshot() == .shutDown)
    }

    @Test("shutdown remains draining until pending result custody transfers")
    func shutdownDrainsPendingResultCustody() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let request = try fixture.makeRequest(name: "shutdown-custody")
        _ = await fixture.scheduler.submit(request)
        let start = await fixture.scanner.nextStart()
        await fixture.scanner.finish(start, with: completeResult())

        try await fixture.waitForState(
            .active(
                WatchedFolderScanSchedulerActiveState(
                    ready: 0,
                    activeQuanta: 0,
                    awaitingValidations: 0,
                    pendingResults: 1,
                    leasedResults: 0,
                    dirtyFollowUps: 0,
                    resultCustodyHighWater: 1
                )
            )
        )
        await fixture.scheduler.shutdown()
        #expect(
            await fixture.scheduler.stateSnapshot()
                == .shuttingDown(
                    WatchedFolderScanSchedulerCustodyState(
                        activeQuanta: 0,
                        awaitingValidations: 0,
                        pendingResults: 1,
                        leasedResults: 0
                    )
                )
        )
        let lease = try await fixture.nextLease()
        #expect(await fixture.transfer(lease) == .transferred)
        #expect(await fixture.scheduler.stateSnapshot() == .shutDown)
    }

    @Test("replacement registration drops stale session and starts exact current request")
    func replacementRegistrationRejectsStaleCompletion() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let original = try fixture.makeRequest(name: "root", registrationGeneration: 1)
        let replacement = try fixture.makeRequest(
            name: "root",
            sourceID: original.sourceID,
            registrationGeneration: 2
        )

        _ = await fixture.scheduler.submit(original)
        let staleStart = await fixture.scanner.nextStart()
        _ = await fixture.scheduler.submit(replacement)
        await fixture.scanner.finish(staleStart, with: completeResult())
        let replacementStart = await fixture.scanner.nextStart()
        #expect(replacementStart.request.canonicalRoot == replacement.canonicalRoot)
        await fixture.scanner.finish(replacementStart, with: completeResult())

        let lease = try await fixture.nextLease()
        #expect(lease.result.schedulingMetrics.staleRegistrationDropCount == 1)
        #expect(await fixture.transfer(lease) == .transferred)
        await fixture.scheduler.shutdown()
    }

    @Test("replacement discards a stale pending result before lease and progresses current work")
    func replacementDiscardsStalePendingResultBeforeLease() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let original = try fixture.makeRequest(name: "pending-root", registrationGeneration: 1)
        let replacement = try fixture.makeRequest(
            name: "pending-root",
            sourceID: original.sourceID,
            registrationGeneration: 2
        )
        _ = await fixture.scheduler.submit(original)
        let originalStart = await fixture.scanner.nextStart()
        await fixture.scanner.finish(originalStart, with: completeResult())
        try await fixture.waitForPendingResultCount(1)
        _ = await fixture.scheduler.submit(replacement)

        let leaseTask = Task { try await fixture.nextLease() }
        let replacementStart = await fixture.scanner.nextStart()
        #expect(replacementStart.request.canonicalRoot == replacement.canonicalRoot)
        await fixture.scanner.finish(replacementStart, with: completeResult())
        let currentLease = try await leaseTask.value

        #expect(currentLease.result.request.canonicalRoot == replacement.canonicalRoot)
        #expect(currentLease.result.schedulingMetrics.staleRegistrationDropCount == 1)
        #expect(await fixture.transfer(currentLease) == .transferred)
        await fixture.scheduler.shutdown()
    }

    @Test("replacement makes an outstanding result lease stale before transfer")
    func replacementMakesOutstandingLeaseStale() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let original = try fixture.makeRequest(name: "leased-root", registrationGeneration: 1)
        let replacement = try fixture.makeRequest(
            name: "leased-root",
            sourceID: original.sourceID,
            registrationGeneration: 2
        )
        _ = await fixture.scheduler.submit(original)
        let originalStart = await fixture.scanner.nextStart()
        await fixture.scanner.finish(originalStart, with: completeResult())
        let staleLease = try await fixture.nextLease()
        _ = await fixture.scheduler.submit(replacement)

        #expect(await fixture.transfer(staleLease) == .staleResultDiscarded)
        let replacementStart = await fixture.scanner.nextStart()
        #expect(replacementStart.request.canonicalRoot == replacement.canonicalRoot)
        await fixture.scanner.finish(replacementStart, with: completeResult())
        let currentLease = try await fixture.nextLease()
        #expect(currentLease.result.schedulingMetrics.staleRegistrationDropCount == 1)
        #expect(await fixture.transfer(currentLease) == .transferred)
        await fixture.scheduler.shutdown()
    }

    @Test("run generation exhaustion is typed and never wraps")
    func runGenerationExhaustionIsTyped() async throws {
        let root = try SchedulerFixture.makeRoot(name: "exhausted")
        let fixture = try SchedulerFixture(
            maximumConcurrentScans: 1,
            initialRunGenerations: [root.sourceID: UInt64.max]
        )
        let request = WatchedFolderScanRequest(canonicalRoot: root, cause: .manual)

        #expect(
            await fixture.scheduler.submit(request)
                == .rejected(.scanRunGenerationExhausted(request.sourceID))
        )
        #expect(await fixture.scanner.startedQuantumCount() == 0)
        await fixture.scheduler.shutdown()
    }

    @Test("queue wait accumulates separately across quantum selections")
    func queueWaitAndQuantumCountRemainSeparate() async throws {
        let fixture = try SchedulerFixture(maximumConcurrentScans: 1)
        let request = try fixture.makeRequest(name: "metrics")
        let blocker = try fixture.makeRequest(name: "blocker")
        _ = await fixture.scheduler.submit(request)
        let first = await fixture.scanner.nextStart()
        _ = await fixture.scheduler.submit(blocker)
        await fixture.scanner.suspend(first)
        let blockerStart = await fixture.scanner.nextStart()
        fixture.clock.advance(by: .milliseconds(5))
        await fixture.scanner.finish(blockerStart, with: completeResult())
        let blockerLease = try await fixture.nextLease()
        #expect(await fixture.transfer(blockerLease) == .transferred)
        let second = await fixture.scanner.nextStart()
        await fixture.scanner.finish(second, with: completeResult())

        let lease = try await fixture.nextLease()
        #expect(lease.result.schedulingMetrics.queueWaitDuration == .milliseconds(5))
        #expect(lease.result.schedulingMetrics.quantumSelectionCount == 2)
        #expect(await fixture.transfer(lease) == .transferred)
        await fixture.scheduler.shutdown()
    }
}

private final class SchedulerTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Duration = .zero

    func now() -> Duration { lock.withLock { elapsed } }
    func advance(by duration: Duration) { lock.withLock { elapsed += duration } }
}

private actor ControlledWatchedFolderScanner {
    struct Start: Sendable {
        let sessionID: RepoScannerSessionID
        let request: WatchedFolderScanRequest
        let scanRunGeneration: UInt64
    }

    private struct ActiveQuantum {
        let start: Start
        let continuation: CheckedContinuation<RepoScannerQuantumOutcome, Never>
    }

    private var activeBySourceID: [FilesystemSourceID: ActiveQuantum] = [:]
    private var bufferedStarts: [Start] = []
    private var startWaiters: [CheckedContinuation<Start, Never>] = []
    private var totalStarted = 0
    private var totalCancelled = 0

    func makeSession(
        request: WatchedFolderScanRequest,
        scanRunGeneration: UInt64
    ) -> WatchedFolderScannerSessionPort {
        let sessionID = RepoScannerSessionID(rawValue: UUIDv7.generate())
        return WatchedFolderScannerSessionPort(
            id: sessionID,
            advanceOneQuantum: {
                await self.advance(
                    sessionID: sessionID,
                    request: request,
                    scanRunGeneration: scanRunGeneration
                )
            },
            cancel: {
                Task {
                    await self.cancel(
                        sourceID: request.sourceID,
                        sessionID: sessionID
                    )
                }
                return .cancellationRequested
            },
            consumeValidationCompletion: { _ in
                .rejected(.sessionFinished)
            }
        )
    }

    func nextStart() async -> Start {
        if !bufferedStarts.isEmpty { return bufferedStarts.removeFirst() }
        return await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish(_ start: Start, with result: RepoScannerResult) {
        complete(start, with: .finished(result))
    }

    func suspend(_ start: Start) {
        complete(
            start,
            with: .suspended(
                usage: RepoScannerQuantumUsage(
                    enumeratedItemCount: 1,
                    enumeratedPathByteCount: 1,
                    candidateValidationCount: 0,
                    failureCount: 0,
                    traversalServiceDuration: .milliseconds(1)
                )
            )
        )
    }

    func startedQuantumCount() -> Int { totalStarted }
    func cancelledQuantumCount() -> Int { totalCancelled }

    private func advance(
        sessionID: RepoScannerSessionID,
        request: WatchedFolderScanRequest,
        scanRunGeneration: UInt64
    ) async -> RepoScannerQuantumOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let start = Start(
                    sessionID: sessionID,
                    request: request,
                    scanRunGeneration: scanRunGeneration
                )
                activeBySourceID[request.sourceID] = ActiveQuantum(
                    start: start,
                    continuation: continuation
                )
                totalStarted += 1
                if startWaiters.isEmpty {
                    bufferedStarts.append(start)
                } else {
                    startWaiters.removeFirst().resume(returning: start)
                }
            }
        } onCancel: {
            Task {
                await self.cancel(
                    sourceID: request.sourceID,
                    sessionID: sessionID
                )
            }
        }
    }

    private func complete(_ start: Start, with outcome: RepoScannerQuantumOutcome) {
        guard let active = activeBySourceID[start.request.sourceID],
            active.start.sessionID == start.sessionID
        else {
            Issue.record("expected an active controlled scanner quantum")
            return
        }
        activeBySourceID.removeValue(forKey: start.request.sourceID)
        active.continuation.resume(returning: outcome)
    }

    private func cancel(
        sourceID: FilesystemSourceID,
        sessionID: RepoScannerSessionID
    ) {
        guard let active = activeBySourceID[sourceID],
            active.start.sessionID == sessionID
        else { return }
        activeBySourceID.removeValue(forKey: sourceID)
        totalCancelled += 1
        active.continuation.resume(returning: .finished(cancelledResult()))
    }
}

private struct SchedulerFixture {
    let scanner = ControlledWatchedFolderScanner()
    let clock = SchedulerTestClock()
    let consumer = WatchedFolderScanResultConsumerToken.make()
    let scheduler: WatchedFolderScanScheduler

    init(
        maximumConcurrentScans: Int,
        initialRunGenerations: [FilesystemSourceID: UInt64] = [:],
        initialDemandGenerations: [FilesystemSourceID: WatchedFolderScanDemandGeneration] = [:]
    ) throws {
        let scanner = self.scanner
        let clock = self.clock
        scheduler = try WatchedFolderScanScheduler(
            maximumConcurrentScans: maximumConcurrentScans,
            initialScanRunGenerations: initialRunGenerations,
            initialDemandGenerations: initialDemandGenerations,
            now: clock.now,
            validationExecutor: RepoScannerValidationExecutor(
                validationClient: SchedulerUnusedValidationClient()
            ),
            sessionFactory: { request, generation in
                await scanner.makeSession(request: request, scanRunGeneration: generation)
            }
        )
    }

    func makeRequest(
        name: String,
        sourceID: FilesystemSourceID? = nil,
        registrationGeneration: UInt64 = 1,
        cause: WatchedFolderScanCause = .manual
    ) throws -> WatchedFolderScanRequest {
        WatchedFolderScanRequest(
            canonicalRoot: try Self.makeRoot(
                name: name,
                sourceID: sourceID,
                registrationGeneration: registrationGeneration
            ),
            cause: cause
        )
    }

    static func makeRoot(
        name: String,
        sourceID: FilesystemSourceID? = nil,
        registrationGeneration: UInt64 = 1
    ) throws -> RegisteredRootDescriptor {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scheduler-\(name)-\(UUIDv7.generate())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceID =
            sourceID
            ?? FilesystemSourceID(kind: .watchedParentMembership, rootID: UUIDv7.generate())
        return try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                FilesystemHostAuthorizedRootInput(
                    registration: FSEventRegistrationToken(
                        sourceID: sourceID,
                        registrationGeneration: registrationGeneration,
                        rootGeneration: 1
                    ),
                    authorizedBoundary: root,
                    registeredRoot: root
                )
            )
        )
    }

    func nextLease() async throws -> WatchedFolderScanResultLease {
        _ = await scheduler.bindResultConsumer(consumer)
        guard case .leased(let lease) = await scheduler.nextResultLease(for: consumer) else {
            Issue.record("expected a leased scheduled scan result")
            throw SchedulerTestError.expectedLease
        }
        return lease
    }

    func transfer(
        _ lease: WatchedFolderScanResultLease
    ) async -> WatchedFolderScanResultLeaseResolutionResult {
        await scheduler.resolveResultLease(
            for: consumer,
            leaseID: lease.leaseID,
            submittedDiagnostics: lease.submittedDiagnostics,
            resolution: .transferred
        )
    }

    func retry(
        _ lease: WatchedFolderScanResultLease
    ) async -> WatchedFolderScanResultLeaseResolutionResult {
        await scheduler.resolveResultLease(
            for: consumer,
            leaseID: lease.leaseID,
            submittedDiagnostics: lease.submittedDiagnostics,
            resolution: .retry
        )
    }

    func transferAllResults(expectedCount: Int) async throws {
        for _ in 0..<expectedCount {
            let lease = try await nextLease()
            #expect(await transfer(lease) == .transferred)
        }
    }

    func waitForState(
        _ expectedState: WatchedFolderScanSchedulerStateSnapshot
    ) async throws {
        for _ in 0..<10_000 {
            if await scheduler.stateSnapshot() == expectedState { return }
            await Task.yield()
        }
        Issue.record(
            "scheduler did not reach expected state; current state: \(await scheduler.stateSnapshot())"
        )
        throw SchedulerTestError.expectedState
    }

    func waitForPendingResultCount(_ expectedCount: Int) async throws {
        for _ in 0..<10_000 {
            if case .active(let snapshot) = await scheduler.stateSnapshot(),
                snapshot.pendingResults == expectedCount
            {
                return
            }
            await Task.yield()
        }
        Issue.record("scheduler did not reach pending result count \(expectedCount)")
        throw SchedulerTestError.expectedState
    }
}

private struct SchedulerUnusedValidationClient: RepoDiscoveryReadClient {
    func validateDiscoveryCandidate(at candidateURL: URL) async -> GitRepositoryDiscoveryOutcome {
        .failure(.serviceFailed(detail: "unexpected scheduler validation request"))
    }
}

private func completeResult() -> RepoScannerResult {
    .completeAuthoritative(
        CompleteRepoScan(
            verifiedEntries: [],
            counts: emptyScannerCounts(),
            serviceMetrics: .zero
        )
    )
}

private func cancelledResult() -> RepoScannerResult {
    .cancelled(
        CancelledRepoScan(
            verifiedEntries: [],
            counts: emptyScannerCounts(),
            serviceMetrics: .zero
        )
    )
}

private func emptyScannerCounts() -> RepoScannerEvidenceCounts {
    RepoScannerEvidenceCounts(
        directoryVisitCount: 0,
        directoryTraversalFailureCount: 0,
        entryMetadataFailureCount: 0,
        gitCandidateCount: 0,
        validationSuccessCount: 0,
        validationAuthoritativeNegativeCount: 0,
        validationTimeoutCount: 0,
        validationCancellationCount: 0,
        validationFailureCount: 0,
        scannerServiceInvocationCount: 1
    )
}

private enum SchedulerTestError: Error {
    case expectedLease
    case expectedTrackedReceipt
    case expectedUntrackedAcceptance
    case expectedState
}

private func trackedReceipt(
    from result: WatchedFolderScanSubmissionResult
) throws -> WatchedFolderScanDemandReceipt {
    guard case .accepted(.tracked(let receipt, _)) = result else {
        Issue.record("expected an accepted tracked watched-folder scan demand")
        throw SchedulerTestError.expectedTrackedReceipt
    }
    return receipt
}
