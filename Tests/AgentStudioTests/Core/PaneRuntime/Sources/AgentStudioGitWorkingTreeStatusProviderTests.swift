import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite(.serialized)
struct AgentStudioGitWorkingTreeStatusProviderTests {
    @Test("SDK status snapshot maps into AgentStudio working-tree status")
    func sdkStatusSnapshotMapsIntoAgentStudioWorkingTreeStatus() async throws {
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in
                gitStatusProviderTestSnapshot(
                    head: AgentStudioGit.GitHeadSnapshot(
                        kind: .branch,
                        oid: "abc123",
                        shortName: "feature/sdk"
                    ),
                    originResolution: .resolved(
                        AgentStudioGit.GitRemoteSnapshot(
                            name: "origin",
                            url: URL(string: "git@example.com:askluna/agent-studio.git")!,
                            rawURL: "git@example.com:askluna/agent-studio.git"
                        )
                    ),
                    summary: makeSummary(
                        stagedFileCount: 2,
                        unstagedFileCount: 3,
                        untrackedFileCount: 1,
                        aheadCount: 1,
                        behindCount: 2,
                        hasUpstream: true
                    ),
                    linesAdded: 8,
                    linesDeleted: 4
                )
            }
        )

        let status = try #require(await provider.status(for: URL(fileURLWithPath: "/tmp/repo")))

        #expect(status.branch == "feature/sdk")
        #expect(status.summary.changed == 3)
        #expect(status.summary.staged == 2)
        #expect(status.summary.untracked == 1)
        #expect(status.summary.linesAdded == 8)
        #expect(status.summary.linesDeleted == 4)
        #expect(status.summary.aheadCount == 1)
        #expect(status.summary.behindCount == 2)
        #expect(status.summary.hasUpstream == true)
        #expect(status.originResolution == .resolved("git@example.com:askluna/agent-studio.git"))
    }

    @Test("scoped modified entry preserves full summary without identity ambiguity")
    func scopedModifiedEntryPreservesFullSummaryWithoutIdentityAmbiguity() async throws {
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in
                gitStatusProviderTestSnapshot(
                    summary: makeSummary(
                        unstagedFileCount: 1,
                        aheadCount: 2,
                        hasUpstream: true
                    ),
                    linesAdded: 12,
                    linesDeleted: 5,
                    entries: [
                        makeStatusEntry(path: "Sources/App.swift", worktreeState: .modified)
                    ]
                )
            }
        )

        let status = try #require(
            await provider.status(
                for: URL(fileURLWithPath: "/tmp/repo"),
                pathspecs: ["Sources/App.swift"]
            )
        )

        #expect(status.containsPathIdentityAmbiguity == false)
        #expect(status.branch == "main")
        #expect(status.summary.linesAdded == 12)
        #expect(status.summary.linesDeleted == 5)
        #expect(status.summary.aheadCount == 2)
        #expect(status.summary.hasUpstream == true)
    }

    @Test("scoped standalone added and untracked entries preserve identity ambiguity")
    func scopedStandaloneAddedAndUntrackedEntriesPreserveIdentityAmbiguity() async throws {
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in
                gitStatusProviderTestSnapshot(
                    entries: [
                        makeStatusEntry(path: "added.txt", worktreeState: .added),
                        makeStatusEntry(path: "untracked.txt", untracked: true),
                    ]
                )
            }
        )

        let status = try #require(
            await provider.status(
                for: URL(fileURLWithPath: "/tmp/repo"),
                pathspecs: ["added.txt", "untracked.txt"]
            )
        )

        #expect(status.containsPathIdentityAmbiguity)
    }

    @Test("scoped standalone deleted entry preserves identity ambiguity")
    func scopedStandaloneDeletedEntryPreservesIdentityAmbiguity() async throws {
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in
                gitStatusProviderTestSnapshot(
                    entries: [makeStatusEntry(path: "deleted.txt", indexState: .deleted)]
                )
            }
        )

        let status = try #require(
            await provider.status(
                for: URL(fileURLWithPath: "/tmp/repo"),
                pathspecs: ["deleted.txt"]
            )
        )

        #expect(status.containsPathIdentityAmbiguity)
    }

    @Test("full status does not report scoped identity ambiguity")
    func fullStatusDoesNotReportScopedIdentityAmbiguity() async throws {
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in
                gitStatusProviderTestSnapshot(
                    entries: [
                        makeStatusEntry(path: "added.txt", indexState: .added),
                        makeStatusEntry(path: "deleted.txt", worktreeState: .deleted),
                    ]
                )
            }
        )

        let status = try #require(await provider.status(for: URL(fileURLWithPath: "/tmp/repo")))

        #expect(status.containsPathIdentityAmbiguity == false)
    }

    @Test("SDK origin states preserve AgentStudio origin-resolution semantics")
    func sdkOriginStatesPreserveAgentStudioOriginResolutionSemantics() async throws {
        let awaitingProvider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in gitStatusProviderTestSnapshot(originResolution: .awaitingResolution) }
        )
        let absentProvider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in gitStatusProviderTestSnapshot(originResolution: .confirmedAbsent) }
        )
        let credentialedRemoteProvider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in
                gitStatusProviderTestSnapshot(
                    originResolution: .resolved(
                        AgentStudioGit.GitRemoteSnapshot(
                            name: "origin",
                            url: URL(string: "https://example.com/org/repo.git")!,
                            rawURL: "https://example.com/org/repo.git"
                        )
                    )
                )
            }
        )

        let awaiting = try #require(await awaitingProvider.status(for: URL(fileURLWithPath: "/tmp/repo")))
        let absent = try #require(await absentProvider.status(for: URL(fileURLWithPath: "/tmp/repo")))
        let credentialed = try #require(
            await credentialedRemoteProvider.status(for: URL(fileURLWithPath: "/tmp/repo"))
        )

        #expect(awaiting.originResolution == .awaitingResolution)
        #expect(absent.originResolution == .confirmedAbsent)
        #expect(credentialed.originResolution == .resolved("https://example.com/org/repo.git"))
    }

    @Test("detached and unborn SDK heads map to branchless sync-unknown status")
    func detachedAndUnbornSDKHeadsMapToBranchlessSyncUnknownStatus() async throws {
        let detachedProvider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in
                gitStatusProviderTestSnapshot(
                    head: AgentStudioGit.GitHeadSnapshot(kind: .detached, oid: "abc123", shortName: nil),
                    summary: makeSummary(hasUpstream: false)
                )
            }
        )
        let unbornProvider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in
                gitStatusProviderTestSnapshot(
                    head: AgentStudioGit.GitHeadSnapshot(kind: .unborn, oid: nil, shortName: "main"),
                    summary: makeSummary(hasUpstream: false)
                )
            }
        )

        let detached = try #require(await detachedProvider.status(for: URL(fileURLWithPath: "/tmp/repo")))
        let unborn = try #require(await unbornProvider.status(for: URL(fileURLWithPath: "/tmp/repo")))

        #expect(detached.branch == nil)
        #expect(detached.summary.aheadCount == nil)
        #expect(detached.summary.behindCount == nil)
        #expect(detached.summary.hasUpstream == nil)
        #expect(unborn.branch == nil)
        #expect(unborn.summary.aheadCount == nil)
        #expect(unborn.summary.behindCount == nil)
        #expect(unborn.summary.hasUpstream == nil)
    }

    @Test("SDK status failure returns nil")
    func sdkStatusFailureReturnsNil() async {
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in throw AgentStudioGit.GitDataPlaneError.unsupported(message: "boom") }
        )

        let status = await provider.status(for: URL(fileURLWithPath: "/tmp/not-a-repo"))

        #expect(status == nil)
    }

    @Test("SDK status failure reports SDK error reason")
    func sdkStatusFailureReportsSDKErrorReason() async throws {
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            statusReader: { _, _ in throw AgentStudioGit.GitDataPlaneError.unsupported(message: "boom") }
        )

        let result = await provider.statusResult(for: URL(fileURLWithPath: "/tmp/not-a-repo"))

        guard case .unavailable(let unavailable) = result else {
            Issue.record("expected unavailable result, got \(result)")
            return
        }
        #expect(unavailable.reason == .sdkError)
    }

    @Test("fact-only status uses the fact reader without complete status or line detail")
    func factOnlyStatusUsesOnlyFactReader() async throws {
        let invocationTracker = StatusReaderInvocationTracker()
        let snapshot = gitStatusProviderTestSnapshot(linesAdded: 8, linesDeleted: 4)
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: AgentStudioGitStatusPhysicalGate(),
            statusFactsReader: { _, _ in
                await invocationTracker.recordFactsRead()
                return snapshot.facts
            },
            lineDetailReader: { _ in
                await invocationTracker.recordLineDetailRead()
                return snapshot.lineCountDetail
            },
            statusReader: { _, _ in
                await invocationTracker.recordCompleteStatusRead()
                return snapshot
            }
        )

        let result = await provider.statusFactsResult(
            for: URL(fileURLWithPath: "/tmp/repo"),
            pathspecs: nil
        )

        guard case .available(let facts) = result else {
            Issue.record("expected fact-only status to be available")
            return
        }
        #expect(facts.changed == snapshot.facts.summary.unstagedFileCount)
        #expect(await invocationTracker.factsReadCount == 1)
        #expect(await invocationTracker.lineDetailReadCount == 0)
        #expect(await invocationTracker.completeStatusReadCount == 0)
    }

    @Test("verified exact clean scan returns authority without line detail")
    func verifiedExactCleanScanReturnsAuthorityWithoutLineDetail() async throws {
        let rootPath = URL(fileURLWithPath: "/tmp/repo")
        let worktreeId = UUIDv7.generate()
        let observationPlan = gitStatusProviderTestObservationPlan(rootPath: rootPath)
        let witness = TestGitCleanContinuityWitness(commitSucceeds: true)
        let invocationTracker = StatusReaderInvocationTracker()
        let snapshot = gitStatusProviderTestSnapshot()
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: AgentStudioGitStatusPhysicalGate(),
            continuityWitness: witness,
            statusObservationPlanReader: { _ in observationPlan },
            verifiedStatusFactsReader: { _, _, suppliedPlan in
                await invocationTracker.recordFactsRead()
                return AgentStudioGit.GitStatusFactsRead(
                    facts: snapshot.facts,
                    exactCleanBaseline: suppliedPlan.map {
                        AgentStudioGit.GitExactCleanBaseline(observationIdentity: $0.identity)
                    }
                )
            },
            lineDetailReader: { _ in
                await invocationTracker.recordLineDetailRead()
                return snapshot.lineCountDetail
            },
            statusReader: { _, _ in snapshot }
        )

        let result = await provider.exactCleanStatusFactsResult(
            for: worktreeId,
            rootPath: rootPath
        )

        guard case .available(let facts) = result else {
            Issue.record("expected exact clean facts, got \(result)")
            return
        }
        #expect(facts.exactCleanAuthority != nil)
        #expect(await invocationTracker.factsReadCount == 1)
        #expect(await invocationTracker.lineDetailReadCount == 0)
        #expect(witness.prepareCount == 1)
        #expect(witness.commitCount == 1)
    }

    @Test("post-scan barrier failure rejects clean facts")
    func postScanBarrierFailureRejectsCleanFacts() async throws {
        let rootPath = URL(fileURLWithPath: "/tmp/repo")
        let observationPlan = gitStatusProviderTestObservationPlan(rootPath: rootPath)
        let witness = TestGitCleanContinuityWitness(commitSucceeds: false)
        let snapshot = gitStatusProviderTestSnapshot()
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: AgentStudioGitStatusPhysicalGate(),
            continuityWitness: witness,
            statusObservationPlanReader: { _ in observationPlan },
            verifiedStatusFactsReader: { _, _, suppliedPlan in
                AgentStudioGit.GitStatusFactsRead(
                    facts: snapshot.facts,
                    exactCleanBaseline: suppliedPlan.map {
                        AgentStudioGit.GitExactCleanBaseline(observationIdentity: $0.identity)
                    }
                )
            },
            statusReader: { _, _ in snapshot }
        )

        let result = await provider.exactCleanStatusFactsResult(
            for: UUIDv7.generate(),
            rootPath: rootPath
        )

        #expect(result == .requiresExact(.mutationObserved))
    }

    @Test("slow threshold observes without completing or releasing the physical read")
    func slowThresholdObservesWithoutReleasingPhysicalRead() async throws {
        let blockedRootPath = URL(fileURLWithPath: "/tmp/slow-observation-root")
        let distinctRootPath = URL(fileURLWithPath: "/tmp/slow-observation-distinct")
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 1)
        let readGate = StatusReadGate()
        let tracker = StatusReadTracker()
        let observationScheduler = ManualStatusSlowObservationScheduler()
        let blockingProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowThreshold: .seconds(999),
            slowObservationScheduler: observationScheduler,
            physicalGate: physicalGate
        ) { _, _ in
            await tracker.recordStarted()
            await readGate.waitUntilReleased()
            await tracker.recordFinished()
            return gitStatusProviderTestSnapshot()
        }
        let distinctProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in
            gitStatusProviderTestSnapshot()
        }

        let slowRead = Task {
            await blockingProvider.statusResult(for: blockedRootPath)
        }
        await tracker.waitForStartedCount(1)
        await observationScheduler.waitUntilScheduledCount(1)
        observationScheduler.fireNextObservation()

        let capacityResult = await distinctProvider.statusResult(for: distinctRootPath)
        #expect(observationScheduler.firedObservationCount() == 1)
        #expect(observationScheduler.scheduledThresholds() == [.seconds(999)])
        #expect(await tracker.finishedCount() == 0)
        #expect(unavailableReason(capacityResult) == .readCapacityExceeded)

        await readGate.release()
        guard case .available = await slowRead.value else {
            Issue.record("expected slow read to complete after physical release")
            return
        }
        guard case .available = await distinctProvider.statusResult(for: distinctRootPath) else {
            Issue.record("expected physical capacity to recover after completion")
            return
        }
    }

    @Test("independently composed providers exclude overlapping reads for the same root")
    func independentlyComposedProvidersExcludeSameRoot() async throws {
        let rootPath = URL(fileURLWithPath: "/tmp/shared-same-root")
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 2)
        let readGate = StatusReadGate()
        let tracker = StatusReadTracker()
        let blockingProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in
            await tracker.recordStarted()
            await readGate.waitUntilReleased()
            await tracker.recordFinished()
            return gitStatusProviderTestSnapshot()
        }
        let overlappingProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in
            await tracker.recordStarted()
            return gitStatusProviderTestSnapshot()
        }

        let firstRead = Task {
            await blockingProvider.statusResult(for: rootPath)
        }
        await tracker.waitForStartedCount(1)

        let overlappingResult = await overlappingProvider.statusResult(for: rootPath)
        #expect(unavailableReason(overlappingResult) == .readAlreadyInFlight)
        #expect(await tracker.startedCount() == 1)

        await readGate.release()
        guard case .available = await firstRead.value else {
            Issue.record("expected first same-root read to complete")
            return
        }
        guard case .available = await overlappingProvider.statusResult(for: rootPath) else {
            Issue.record("expected root to become available after physical completion")
            return
        }
    }

    @Test("independently composed providers share the global physical capacity")
    func independentlyComposedProvidersShareGlobalPhysicalCapacity() async throws {
        let firstRootPath = URL(fileURLWithPath: "/tmp/shared-capacity-first")
        let secondRootPath = URL(fileURLWithPath: "/tmp/shared-capacity-second")
        let thirdRootPath = URL(fileURLWithPath: "/tmp/shared-capacity-third")
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 2)
        let readGate = StatusReadGate()
        let tracker = StatusReadTracker()
        let firstProvider = makeBlockingProvider(physicalGate: physicalGate, readGate: readGate, tracker: tracker)
        let secondProvider = makeBlockingProvider(physicalGate: physicalGate, readGate: readGate, tracker: tracker)
        let thirdProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in
            await tracker.recordStarted()
            return gitStatusProviderTestSnapshot()
        }

        let firstRead = Task { await firstProvider.statusResult(for: firstRootPath) }
        let secondRead = Task { await secondProvider.statusResult(for: secondRootPath) }
        await tracker.waitForStartedCount(2)

        let thirdResultWhileFull = await thirdProvider.statusResult(for: thirdRootPath)
        #expect(unavailableReason(thirdResultWhileFull) == .readCapacityExceeded)
        #expect(await tracker.startedCount() == 2)

        await readGate.release()
        guard case .available = await firstRead.value else {
            Issue.record("expected first shared-capacity read to complete")
            return
        }
        guard case .available = await secondRead.value else {
            Issue.record("expected second shared-capacity read to complete")
            return
        }
        guard case .available = await thirdProvider.statusResult(for: thirdRootPath) else {
            Issue.record("expected shared capacity to recover after physical completion")
            return
        }
    }

    @Test("caller cancellation does not release same-root or global physical capacity")
    func callerCancellationDoesNotReleasePhysicalCapacity() async throws {
        let cancelledRootPath = URL(fileURLWithPath: "/tmp/cancelled-physical-root")
        let distinctRootPath = URL(fileURLWithPath: "/tmp/cancelled-physical-distinct")
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 1)
        let readGate = StatusReadGate()
        let tracker = StatusReadTracker()
        let provider = makeBlockingProvider(physicalGate: physicalGate, readGate: readGate, tracker: tracker)
        let independentProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in gitStatusProviderTestSnapshot() }

        let cancelledRead = Task {
            await provider.statusResult(for: cancelledRootPath)
        }
        await tracker.waitForStartedCount(1)
        cancelledRead.cancel()

        let sameRootResult = await independentProvider.statusResult(for: cancelledRootPath)
        let distinctResult = await independentProvider.statusResult(for: distinctRootPath)
        #expect(unavailableReason(sameRootResult) == .readAlreadyInFlight)
        #expect(unavailableReason(distinctResult) == .readCapacityExceeded)
        #expect(await tracker.finishedCount() == 0)

        await readGate.release()
        #expect(unavailableReason(await cancelledRead.value) == .cancelled)
        await physicalGate.waitUntilInactive(cancelledRootPath)
        guard case .available = await independentProvider.statusResult(for: distinctRootPath) else {
            Issue.record("expected capacity to release only after cancelled operation physically completed")
            return
        }
    }

    @Test("physical capacity rejection remains distinct from SDK failure")
    func physicalCapacityRejectionRemainsDistinctFromSDKFailure() async throws {
        let blockedRootPath = URL(fileURLWithPath: "/tmp/capacity-versus-sdk-blocked")
        let failingRootPath = URL(fileURLWithPath: "/tmp/capacity-versus-sdk-failing")
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 1)
        let readGate = StatusReadGate()
        let tracker = StatusReadTracker()
        let blockingProvider = makeBlockingProvider(
            physicalGate: physicalGate,
            readGate: readGate,
            tracker: tracker
        )
        let failingProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in
            throw AgentStudioGit.GitDataPlaneError.unsupported(message: "expected SDK failure")
        }

        let blockingRead = Task {
            await blockingProvider.statusResult(for: blockedRootPath)
        }
        await tracker.waitForStartedCount(1)

        #expect(
            unavailableReason(await failingProvider.statusResult(for: failingRootPath))
                == .readCapacityExceeded
        )

        await readGate.release()
        guard case .available = await blockingRead.value else {
            Issue.record("expected blocking read to complete")
            return
        }
        #expect(unavailableReason(await failingProvider.statusResult(for: failingRootPath)) == .sdkError)
    }

    @Test("successful SDK read leaves root immediately available for another read")
    func successfulSDKReadLeavesRootImmediatelyAvailableForAnotherRead() async throws {
        let rootPath = URL(fileURLWithPath: "/tmp/successful-read-recovery-repo")
        let physicalGate = AgentStudioGitStatusPhysicalGate()
        let provider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in
            gitStatusProviderTestSnapshot()
        }

        let firstResult = await provider.statusResult(for: rootPath)
        let secondResult = await provider.statusResult(for: rootPath)

        guard case .available = firstResult else {
            Issue.record("expected first result to be available, got \(firstResult)")
            return
        }
        guard case .available = secondResult else {
            Issue.record("expected second result to be available, got \(secondResult)")
            return
        }
    }

}

private actor StatusReaderInvocationTracker {
    private(set) var factsReadCount = 0
    private(set) var lineDetailReadCount = 0
    private(set) var completeStatusReadCount = 0

    func recordFactsRead() {
        factsReadCount += 1
    }

    func recordLineDetailRead() {
        lineDetailReadCount += 1
    }

    func recordCompleteStatusRead() {
        completeStatusReadCount += 1
    }
}

private final class ManualStatusSlowObservationScheduler: AgentStudioGitStatusSlowObservationScheduler,
    @unchecked Sendable
{
    private struct ScheduledObservation {
        let id: Int
        let threshold: Duration
        let handler: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var nextId = 0
    private var scheduledObservations: [ScheduledObservation] = []
    private var thresholds: [Duration] = []
    private var firedCount = 0
    private var scheduleWaiters: [(minimumCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func scheduleObservation(
        after threshold: Duration,
        _ handler: @escaping @Sendable () -> Void
    ) -> AgentStudioGitScheduledSlowObservation {
        let id: Int
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        id = nextId
        nextId += 1
        scheduledObservations.append(
            ScheduledObservation(id: id, threshold: threshold, handler: handler)
        )
        thresholds.append(threshold)
        waiters =
            scheduleWaiters
            .filter { $0.minimumCount <= scheduledObservations.count }
            .map(\.continuation)
        scheduleWaiters.removeAll { $0.minimumCount <= scheduledObservations.count }
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }

        return AgentStudioGitScheduledSlowObservation { [weak self] in
            self?.cancelScheduledObservation(id: id)
        }
    }

    func waitUntilScheduledCount(_ count: Int) async {
        guard scheduledObservationCount() < count else { return }

        await withCheckedContinuation { continuation in
            if !appendScheduleWaiterIfNeeded(continuation, minimumCount: count) {
                continuation.resume()
            }
        }
    }

    func fireNextObservation() {
        let scheduledObservation: ScheduledObservation?
        lock.lock()
        scheduledObservation = scheduledObservations.isEmpty ? nil : scheduledObservations.removeFirst()
        if scheduledObservation != nil {
            firedCount += 1
        }
        lock.unlock()

        scheduledObservation?.handler()
    }

    func firedObservationCount() -> Int {
        lock.lock()
        let count = firedCount
        lock.unlock()
        return count
    }

    func scheduledThresholds() -> [Duration] {
        lock.lock()
        let result = thresholds
        lock.unlock()
        return result
    }

    private func cancelScheduledObservation(id: Int) {
        lock.lock()
        scheduledObservations.removeAll { $0.id == id }
        lock.unlock()
    }

    private func scheduledObservationCount() -> Int {
        lock.lock()
        let count = scheduledObservations.count
        lock.unlock()
        return count
    }

    private func appendScheduleWaiterIfNeeded(
        _ waiter: CheckedContinuation<Void, Never>,
        minimumCount: Int = 1
    ) -> Bool {
        lock.lock()
        guard scheduledObservations.count < minimumCount else {
            lock.unlock()
            return false
        }
        scheduleWaiters.append((minimumCount: minimumCount, continuation: waiter))
        lock.unlock()
        return true
    }
}

struct PassiveStatusSlowObservationScheduler: AgentStudioGitStatusSlowObservationScheduler {
    func scheduleObservation(
        after _: Duration,
        _: @escaping @Sendable () -> Void
    ) -> AgentStudioGitScheduledSlowObservation {
        AgentStudioGitScheduledSlowObservation {}
    }
}

private actor StatusReadGate {
    private var didStart = false
    private var didRelease = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        markStarted()
        guard !didRelease else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        guard !didRelease else { return }
        didRelease = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func markStarted() {
        guard !didStart else { return }
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor StatusReadTracker {
    private var startCount = 0
    private var finishCount = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordStarted() {
        startCount += 1
        let readyWaiters = startWaiters.filter { $0.count <= startCount }
        startWaiters.removeAll { $0.count <= startCount }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    func recordFinished() {
        finishCount += 1
        let readyWaiters = finishWaiters.filter { $0.count <= finishCount }
        finishWaiters.removeAll { $0.count <= finishCount }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    func startedCount() -> Int {
        startCount
    }

    func finishedCount() -> Int {
        finishCount
    }

    func waitForStartedCount(_ count: Int) async {
        guard startCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count: count, continuation: continuation))
        }
    }

    func waitForFinishedCount(_ count: Int) async {
        guard finishCount < count else { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append((count: count, continuation: continuation))
        }
    }
}

private func makeBlockingProvider(
    physicalGate: AgentStudioGitStatusPhysicalGate,
    readGate: StatusReadGate,
    tracker: StatusReadTracker
) -> AgentStudioGitWorkingTreeStatusProvider {
    AgentStudioGitWorkingTreeStatusProvider(
        slowObservationScheduler: PassiveStatusSlowObservationScheduler(),
        physicalGate: physicalGate
    ) { _, _ in
        await tracker.recordStarted()
        await readGate.waitUntilReleased()
        await tracker.recordFinished()
        return gitStatusProviderTestSnapshot()
    }
}

private func unavailableReason(
    _ result: GitWorkingTreeStatusResult
) -> GitWorkingTreeStatusUnavailableReason? {
    guard case .unavailable(let unavailable) = result else { return nil }
    return unavailable.reason
}

func gitStatusProviderTestSnapshot(
    head: AgentStudioGit.GitHeadSnapshot = AgentStudioGit.GitHeadSnapshot(
        kind: .branch,
        oid: "abc123",
        shortName: "main"
    ),
    originResolution: AgentStudioGit.GitOriginResolution = .confirmedAbsent,
    summary: AgentStudioGit.GitStatusFactSummary = makeSummary(),
    linesAdded: Int = 0,
    linesDeleted: Int = 0,
    entries: [AgentStudioGit.GitStatusEntry] = []
) -> AgentStudioGit.GitCompleteStatusSnapshot {
    let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")
    let worktreePath = URL(fileURLWithPath: "/tmp/repo")
    return AgentStudioGit.GitCompleteStatusSnapshot(
        facts: AgentStudioGit.GitStatusFactsSnapshot(
            repositoryRoot: repositoryRoot,
            worktreePath: worktreePath,
            generatedAtUnixMilliseconds: 1,
            head: head,
            originResolution: originResolution,
            summary: summary,
            entries: entries
        ),
        lineCountDetail: AgentStudioGit.GitStatusLineCountDetail(
            repositoryRoot: repositoryRoot,
            worktreePath: worktreePath,
            generatedAtUnixMilliseconds: 1,
            linesAdded: linesAdded,
            linesDeleted: linesDeleted
        )
    )
}

private func makeStatusEntry(
    path: String,
    previousPath: String? = nil,
    indexState: AgentStudioGit.GitStatusState? = nil,
    worktreeState: AgentStudioGit.GitStatusState? = nil,
    untracked: Bool = false
) -> AgentStudioGit.GitStatusEntry {
    AgentStudioGit.GitStatusEntry(
        path: path,
        previousPath: previousPath,
        indexState: indexState,
        worktreeState: worktreeState,
        ignored: false,
        untracked: untracked
    )
}

private func makeSummary(
    changedFileCount: Int = 0,
    stagedFileCount: Int = 0,
    unstagedFileCount: Int = 0,
    untrackedFileCount: Int = 0,
    ignoredFileCount: Int = 0,
    aheadCount: Int = 0,
    behindCount: Int = 0,
    hasUpstream: Bool = false
) -> AgentStudioGit.GitStatusFactSummary {
    AgentStudioGit.GitStatusFactSummary(
        changedFileCount: changedFileCount,
        stagedFileCount: stagedFileCount,
        unstagedFileCount: unstagedFileCount,
        untrackedFileCount: untrackedFileCount,
        ignoredFileCount: ignoredFileCount,
        aheadCount: aheadCount,
        behindCount: behindCount,
        hasUpstream: hasUpstream
    )
}

func gitStatusProviderTestObservationPlan(rootPath: URL) -> AgentStudioGit.GitStatusObservationPlan {
    AgentStudioGit.GitStatusObservationPlan(
        identity: AgentStudioGit.GitStatusObservationIdentity(rawValue: "test-observation-identity"),
        scopes: [
            AgentStudioGit.GitStatusObservationScope(kind: .subtree, path: rootPath)
        ],
        support: .supported
    )
}

final class TestGitCleanContinuityWitness: GitCleanContinuityWitness, @unchecked Sendable {
    private let lock = NSLock()
    private let commitSucceeds: Bool
    private let prepareFailure: GitCleanContinuityPrepareFailure?
    private var _prepareCount = 0
    private var _commitCount = 0

    init(commitSucceeds: Bool, prepareFailure: GitCleanContinuityPrepareFailure? = nil) {
        self.commitSucceeds = commitSucceeds
        self.prepareFailure = prepareFailure
    }

    var prepareCount: Int { lock.withLock { _prepareCount } }
    var commitCount: Int { lock.withLock { _commitCount } }

    func prepare(
        worktreeId: UUID,
        rootPath _: URL,
        observationPlan: AgentStudioGit.GitStatusObservationPlan
    ) async -> GitCleanContinuityPrepareOutcome {
        lock.withLock { _prepareCount += 1 }
        if let prepareFailure { return .unavailable(prepareFailure) }
        return .prepared(
            GitCleanContinuityBarrier(
                registrationId: worktreeId,
                observationIdentity: observationPlan.identity,
                registrationGeneration: 1,
                mutationEpoch: 0,
                uncertaintyEpoch: 0
            ))
    }

    func commit(
        _ barrier: GitCleanContinuityBarrier
    ) async -> GitCleanContinuityAuthorityValidation {
        lock.withLock { _commitCount += 1 }
        guard commitSucceeds else { return .requiresExact(.mutationObserved) }
        return .authoritative(
            GitCleanContinuityAuthority(
                registrationId: barrier.registrationId,
                observationIdentity: barrier.observationIdentity,
                registrationGeneration: barrier.registrationGeneration,
                mutationEpoch: barrier.mutationEpoch,
                uncertaintyEpoch: barrier.uncertaintyEpoch
            )
        )
    }

    func renew(
        _ authority: GitCleanContinuityAuthority
    ) async -> GitCleanContinuityAuthorityValidation {
        .authoritative(authority)
    }

    func retire(worktreeId _: UUID, rootPath _: URL) {}
}
