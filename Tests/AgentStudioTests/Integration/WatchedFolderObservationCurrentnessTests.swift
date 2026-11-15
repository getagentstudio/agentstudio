import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@Suite("Watched folder observation currentness")
struct WatchedFolderObservationCurrentnessTests {
    @Test("real traversal's stale absence and late acceptance cannot restore overlapping authority")
    func realTraversalPreservesImmediateOverlapInvalidation() async throws {
        let fixture = try await TraversalCurrentnessFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var heldSubmission: Task<Void, Never>?
        do {
            _ = await fixture.filesystem.refreshWatchedFolders(fixture.watches)
            for watch in fixture.watches { _ = try await fixture.nextObservation(for: watch) }
            let ownInitial = try #require(
                await fixture.filesystem.currentWatchedFolderObservationReceipts()
                    .first { $0.observation.registration.sourceID.rootID == fixture.watches[0].id })
            let disjoint = try #require(
                await fixture.filesystem.currentWatchedFolderObservationReceipts()
                    .first { $0.observation.registration.sourceID.rootID == fixture.watches[2].id })
            fixture.gates.arm()
            let submission = Task {
                await fixture.filesystem.submitWatchedFolderScan(sourceID: fixture.sourceID(0), cause: .fallback)
            }
            heldSubmission = submission
            let staleScan = try await fixture.gates.traversal.firstArrival()
            if case .completeAuthoritative(let complete) = staleScan {
                #expect(complete.verifiedEntries.isEmpty)
            } else {
                Issue.record("the real traversal must complete after visiting the empty candidate")
            }
            _ = try await fixture.gates.acceptance.firstArrival()
            await fixture.filesystem.submitWatchedFolderScan(sourceID: fixture.sourceID(1), cause: .fallback)
            let dependent = try await fixture.nextObservation(for: fixture.watches[1])
            #expect(await fixture.filesystem.areCurrentWatchedFolderObservations([dependent]))

            // The real scanner has passed this directory. Git appears before any paced submission.
            try await FilesystemTestGitRepo.runGit(at: fixture.watches[0].path, args: ["init"])
            let registration = try #require(
                await fixture.filesystem.watchedFolderScanState
                    .registrationsBySourceID[fixture.sourceID(0)])
            await fixture.filesystem.handleWatchedFolderFSEvent(
                .init(
                    worktreeId: registration.legacyCallbackRoutingID,
                    paths: [fixture.watches[0].path.appending(path: ".git/HEAD").path]))
            #expect(!(await fixture.filesystem.areCurrentWatchedFolderObservations([dependent])))
            #expect(!(await fixture.filesystem.areCurrentWatchedFolderObservations([ownInitial.observation])))
            #expect(await fixture.filesystem.areCurrentWatchedFolderObservations([disjoint.observation]))

            fixture.gates.traversal.release()
            let stale = try await fixture.nextObservation(for: fixture.watches[0])
            if case .additive = stale.coverage {} else { Issue.record("stale absence must be positive-only") }
            #expect(!(await fixture.filesystem.areCurrentWatchedFolderObservations([stale])))
            #expect(!(await fixture.filesystem.areCurrentWatchedFolderObservations([dependent])))
            #expect(await fixture.filesystem.areCurrentWatchedFolderObservations([disjoint.observation]))
            fixture.gates.acceptance.release()
            await submission.value
            #expect(
                await fixture.filesystem.watchedFolderScanState.latestDemandCoverageBySourceID[fixture.sourceID(0)]
                    == nil)
            #expect(!(await fixture.filesystem.areCurrentWatchedFolderObservations([dependent])))

            let producer = try #require(await fixture.filesystem.watchedFolderScanState.pacingDeadlineTask)
            let deadline = try await fixture.probe.nextSleep(producedBy: producer)
            fixture.probe.clock.advance(to: deadline)
            await producer.value
            let fresh = try await fixture.nextObservation(for: fixture.watches[0])
            if case .authoritative = fresh.coverage {} else { Issue.record("covering real scan must be authoritative") }
            #expect(fresh.entries.contains { $0.path.path == fixture.watches[0].path.path })
            #expect(await fixture.filesystem.areCurrentWatchedFolderObservations([fresh]))
            #expect(!(await fixture.filesystem.areCurrentWatchedFolderObservations([dependent])))
            #expect(await fixture.filesystem.areCurrentWatchedFolderObservations([disjoint.observation]))
            await fixture.filesystem.submitWatchedFolderScan(sourceID: fixture.sourceID(1), cause: .fallback)
            let refreshedDependent = try await fixture.nextObservation(for: fixture.watches[1])
            #expect(
                await fixture.filesystem.areCurrentWatchedFolderObservations([refreshedDependent, disjoint.observation])
            )
        } catch {
            fixture.gates.releaseAll()
            await heldSubmission?.value
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
    }

    @Test("only overlapping source supersession invalidates a dependent observation", arguments: [true, false])
    func otherSourceSupersessionRequiresOverlappingCoverage(overlaps: Bool) async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "watched-observation-currentness-\(UUIDv7.generate())")
        let firstRoot = temporaryRoot.appending(path: "first")
        let secondRoot = overlaps ? firstRoot.appending(path: "nested") : temporaryRoot.appending(path: "second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let firstWatch = WatchedPath(path: firstRoot)
        let secondWatch = WatchedPath(path: secondRoot)
        let scans = ControllableWatchedFolderScanSchedulerResults()
        scans.setResults([firstWatch: [], secondWatch: []])
        let filesystem = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(), fseventStreamClient: ControllableFSEventStreamClient(),
            watchedFolderScanScheduler: scans.makeScheduler())
        do {
            _ = await filesystem.refreshWatchedFolders([firstWatch, secondWatch])
            let receipts = await filesystem.currentWatchedFolderObservationReceipts()
            #expect(receipts.count == 2)
            // The last result captured the other source after its initial authoritative result.
            let retained = try #require(receipts.max { $0.sequence < $1.sequence })
            let other = try #require(receipts.first { $0.sequence != retained.sequence })
            let registrations = await filesystem.watchedFolderScanState.registrationsBySourceID
            let registration = try #require(registrations[other.observation.registration.sourceID])

            await filesystem.handleWatchedFolderFSEvent(
                FSEventBatch(
                    worktreeId: registration.legacyCallbackRoutingID,
                    paths: [registration.watchedPath.path.appending(path: ".git/index").path]))

            let remainsCurrent = await filesystem.areCurrentWatchedFolderObservations([retained.observation])
            #expect(remainsCurrent == !overlaps)
        } catch {
            await filesystem.shutdown()
            throw error
        }
        await filesystem.shutdown()
    }
}

private final class TraversalCurrentnessGates: @unchecked Sendable {
    let traversal = HeldStep<RepoScannerResult>(
        "real traversal passed candidate", cancellation: .holdThroughCancellation)
    let acceptance = HeldStep<WatchedFolderScanRequest>("explicit acceptance", cancellation: .holdThroughCancellation)
    private let lock = NSLock()
    private var traversalArmed = false
    private var acceptanceArmed = false
    func arm() {
        lock.withLock {
            traversalArmed = true
            acceptanceArmed = true
        }
    }
    func holdTraversal(_ result: RepoScannerResult) async {
        guard
            lock.withLock({
                let armed = traversalArmed
                traversalArmed = false
                return armed
            })
        else { return }
        try? await traversal.arrive(result)
    }
    func holdAcceptance(_ request: WatchedFolderScanRequest) async {
        guard
            lock.withLock({
                let armed = acceptanceArmed
                acceptanceArmed = false
                return armed
            })
        else { return }
        try? await acceptance.arrive(request)
    }
    func releaseAll() {
        traversal.release()
        acceptance.release()
    }
    func retire() {
        traversal.retire()
        acceptance.retire()
    }
}

private struct CurrentnessDiscoveryDeadline: RepoDiscoveryDeadlineScheduler {
    func scheduleDeadline(after _: Duration, _ handler: @escaping @Sendable () -> Void)
        -> RepoDiscoveryScheduledDeadline
    {
        .init(cancel: {})
    }
}

private struct TraversalCurrentnessFixture {
    let root: URL
    let watches: [WatchedPath]
    let filesystem: FilesystemActor
    let probe: WatchedFolderScanPacingProbe
    let gates: TraversalCurrentnessGates
    let observations: FactRecorder<UUID, WatchedFolderTopologyObservation>
    let collector: Task<Void, Never>
    let observers: WatchedFolderObservationTasks

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "real-scan-currentness-\(UUIDv7.generate())")
            .resolvingSymlinksInPath()
        let parent = root.appending(path: "parent")
        let candidate = parent.appending(path: "candidate")
        let disjoint = root.appending(path: "disjoint")
        for path in [candidate, disjoint] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let watches = [candidate, parent, disjoint].map { WatchedPath(path: $0) }
        let gates = TraversalCurrentnessGates()
        let probe = try WatchedFolderScanPacingProbe()
        let origin = probe.clock.now
        let executor = try RepoScannerValidationExecutor(
            validationClient: RepoScannerGitDiscoveryClient(), deadlineScheduler: CurrentnessDiscoveryDeadline())
        let scheduler = try WatchedFolderScanScheduler(
            maximumConcurrentScans: 2, now: { origin.duration(to: probe.clock.now) }, validationExecutor: executor,
            sessionFactory: { request, _ in
                let session = RepoScanner().makeSession(
                    in: URL(fileURLWithPath: request.canonicalRoot.aliases.onceResolvedCanonical.path))
                return .init(
                    id: session.id,
                    advanceOneQuantum: {
                        let outcome = await session.advanceOneQuantum()
                        if request.sourceID.rootID == watches[0].id, case .finished(let result) = outcome {
                            await gates.holdTraversal(result)
                        }
                        return outcome
                    },
                    cancel: {
                        gates.retire()
                        return session.cancel()
                    }, consumeValidationCompletion: session.consumeValidationCompletion)
            })
        let bus = EventBus<RuntimeEnvelope>()
        let filesystem = FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(), watchedFolderScanScheduler: scheduler,
            watchedFolderScanSubmission: .init { scheduler, request, intent in
                let result = await scheduler.submit(request, intent: intent)
                if request.sourceID.rootID == watches[0].id {
                    switch result {
                    case .accepted: await gates.holdAcceptance(request)
                    case .rejected: gates.retire()
                    }
                }
                return result
            }, sleepClock: probe.clock)
        let observations = FactRecorder<UUID, WatchedFolderTopologyObservation>(
            vocabulary: .init(
                describeScope: { "real scanner root \($0)" }, describeFact: { String(describing: $0.demandCoverage) },
                isClosing: { _, _ in false }))
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        let collector = Task {
            for await envelope in stream {
                if case .system(let system) = envelope,
                    case .topology(.watchedFolderReconciled(let observation)) = system.event
                {
                    observations.append(scope: observation.registration.sourceID.rootID, fact: observation)
                }
            }
            observations.receive(.ended)
        }
        return .init(
            root: root, watches: watches, filesystem: filesystem, probe: probe, gates: gates,
            observations: observations, collector: collector, observers: .init())
    }

    func sourceID(_ index: Int) -> FilesystemSourceID {
        .init(kind: .watchedParentMembership, rootID: watches[index].id)
    }

    func nextObservation(for watch: WatchedPath) async throws -> WatchedFolderTopologyObservation {
        let producer = try #require(await filesystem.watchedFolderScanState.resultDrainState.task)
        let observer = Task {
            await producer.value
            if !Task.isCancelled { observations.receive(.ended) }
        }
        observers.retainObservation(observer)
        defer { observer.cancel() }
        return try await observations.expectNext(
            in: watch.id, where: { _ in true }, "real scanner observation or result owner retirement")
    }

    func shutdown() async {
        gates.releaseAll()
        observers.cancelAll()
        await filesystem.shutdown()
        collector.cancel()
        await collector.value
        await observers.join()
        do {
            try await observations.finish()
            try await probe.finish()
        } catch { Issue.record(error) }
    }
}
