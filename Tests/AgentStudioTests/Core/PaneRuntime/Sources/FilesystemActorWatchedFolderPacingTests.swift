import AgentStudioTestHarness
import AgentStudioTestSupport
import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension FilesystemActorWatchedFolderTests {
    enum IrrelevantPacingScenario: CaseIterable, Sendable { case checkoutDirectories, checkoutFiles, tooDeep, hidden }

    @Test(
        "irrelevant large batches leave no actor scan obligation or run", arguments: IrrelevantPacingScenario.allCases)
    func irrelevantLargeBatchesStartNoActorRun(scenario: IrrelevantPacingScenario) async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        do {
            let checkout = fixture.watchedFolder.appending(path: "known")
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: [cloneEntry(checkout)]))
            fixture.submissionLog.reset()
            let callbackID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
            let paths = (0..<300).map { index -> String in
                switch scenario {
                case .checkoutDirectories: checkout.appending(path: "Sources/generated-\(index)").path
                case .checkoutFiles: checkout.appending(path: "Sources/file-\(index).swift").path
                case .tooDeep: fixture.watchedFolder.appending(path: "one/two/three/four/five/new-\(index)").path
                case .hidden: fixture.watchedFolder.appending(path: ".hidden/new-\(index)").path
                }
            }
            let flags =
                scenario == .checkoutFiles
                ? UInt32(kFSEventStreamEventFlagItemModified)
                : UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
            await fixture.actor.handleWatchedFolderFSEvent(
                .init(
                    worktreeId: callbackID, paths: paths,
                    observations: paths.map { .init(path: $0, eventID: 1, flags: flags) }))
            #expect(fixture.submissionLog.entries.isEmpty)
            #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.isEmpty)
            #expect(await fixture.scanner.startedQuantumCount() == 1)
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
    }

    @Test("native loss and coarse intake loss each produce one paced reconciliation", arguments: [false, true])
    func coverageLossAlwaysProducesOnePacedRun(coarse: Bool) async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        do {
            let checkout = fixture.watchedFolder.appending(path: "known")
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: [cloneEntry(checkout)]))
            fixture.submissionLog.reset()
            let callbackID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
            if coarse {
                await fixture.actor.handleCoarseWatchedFolderFSEvent(worktreeId: callbackID)
            } else {
                let path = checkout.appending(path: "Sources/ordinary.swift").path
                await fixture.actor.handleWatchedFolderFSEvent(
                    .init(
                        worktreeId: callbackID, paths: [path],
                        observations: [.init(path: path, eventID: 1, flags: UInt32(kFSEventStreamEventFlagUserDropped))]
                    ))
            }
            #expect(fixture.submissionLog.entries.isEmpty)
            #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.count == 1)
            #expect(await fixture.actor.watchedFolderScanState.latestDemandCoverageBySourceID.isEmpty)
            _ = try await fixture.advancePacingDeadline()
            #expect(fixture.submissionLog.entries.count == 1)
            #expect(fixture.submissionLog.entries.first?.submittedAt == .seconds(2))
            let start = try await fixture.scanner.nextStart()
            let sequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(start, with: completeResult(entries: []))
            let observation = try await fixture.consumeTopologyObservation(sequence: sequence)
            #expect(await fixture.actor.areCurrentWatchedFolderObservations([observation]))
            #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.isEmpty)
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
    }

    @Test("actor submits after two seconds of quiet, extended by a later trigger", arguments: [false, true])
    func actorQuietDeadlineFollowsLatestTrigger(repeated: Bool) async throws {
        let probe = try WatchedFolderScanPacingProbe()
        let fixture = try await WatchedFolderActorFixture(clock: probe.clock)
        defer { fixture.removeTemporaryRoot() }
        do {
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
            fixture.submissionLog.reset()
            let origin = probe.clock.now
            try await triggerWatchedFolderChange(fixture)
            let task = try #require(await fixture.actor.watchedFolderScanState.pacingDeadlineTask)
            let deadline = try await probe.nextSleep(producedBy: task)
            #expect(deadline == origin.advanced(by: .seconds(2)))
            #expect(fixture.submissionLog.entries.isEmpty)
            if repeated {
                probe.clock.advance(to: origin.advanced(by: .milliseconds(1500)))
                try await triggerWatchedFolderChange(fixture)
                probe.clock.advance(to: deadline)
                let extended = try await probe.nextSleep(producedBy: task)
                #expect(extended == origin.advanced(by: .milliseconds(3500)))
                #expect(fixture.submissionLog.entries.isEmpty)
                probe.clock.advance(to: origin.advanced(by: .milliseconds(3499)))
                #expect(fixture.submissionLog.entries.isEmpty)
                probe.clock.advance(to: extended)
            } else {
                probe.clock.advance(to: origin.advanced(by: .milliseconds(1999)))
                #expect(fixture.submissionLog.entries.isEmpty)
                probe.clock.advance(to: deadline)
            }
            try #require(await probe.nextDisposition(producedBy: task) == .producerEnded)
            await task.value
            #expect(fixture.submissionLog.entries.count == 1)
            #expect(fixture.submissionLog.entries.first?.submittedAt == (repeated ? .milliseconds(3500) : .seconds(2)))
            let start = try await fixture.scanner.nextStart()
            let sequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(start, with: completeResult(entries: []))
            _ = try await fixture.consumeTopologyObservation(sequence: sequence)
            #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.isEmpty)
        } catch {
            await fixture.shutdown()
            try? await probe.finish()
            throw error
        }
        await fixture.shutdown()
        try await probe.finish()
    }

    @Test("fifty actor triggers across ten groups retain one outstanding obligation")
    func fiftyActorTriggersRetainOneObligation() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        do {
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
            fixture.submissionLog.reset()
            for _ in 0..<10 { for _ in 0..<5 { try await triggerWatchedFolderChange(fixture) } }
            let obligations = await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID
            #expect(obligations.count == 1)
            #expect(obligations.values.first?.pendingInterval?.foldedTriggerCount == 50)
            #expect(fixture.submissionLog.entries.isEmpty)
            _ = try await fixture.advancePacingDeadline()
            #expect(fixture.submissionLog.entries.count == 1)
            let start = try await fixture.scanner.nextStart()
            let sequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(start, with: completeResult(entries: []))
            _ = try await fixture.consumeTopologyObservation(sequence: sequence)
            #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.isEmpty)
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
    }

    @Test("a held traversal does not delay ten-second submission eligibility during a minute burst")
    func actorMaximumWaitSurvivesHeldTraversal() async throws {
        let probe = try WatchedFolderScanPacingProbe()
        let fixture = try await WatchedFolderActorFixture(clock: probe.clock)
        defer { fixture.removeTemporaryRoot() }
        do {
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
            fixture.submissionLog.reset()
            let entries = try await driveSustainedWatchedFolderBurst(fixture, probe: probe)
            #expect(entries.map(\.submittedAt) == [10, 20, 30, 40, 50, 60].map { .seconds($0) })
            #expect(entries.count <= 7)
            #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.count == 1)
            // The real scheduler kept one active run and merged the five later demands into its dirty follow-up.
            let old = try await fixture.scanner.nextStart()
            let oldSequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(old, with: completeResult(entries: []))
            let oldObservation = try await fixture.consumeTopologyObservation(sequence: oldSequence)
            #expect(!watchedFolderObservationIsAuthoritative(oldObservation))
            #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.count == 1)
            let covering = try await fixture.scanner.nextStart()
            #expect(covering.request.submissionSequence == entries.last?.request.submissionSequence)
            let closingSequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(covering, with: completeResult(entries: []))
            let observation = try await fixture.consumeTopologyObservation(sequence: closingSequence)
            #expect(await fixture.actor.areCurrentWatchedFolderObservations([observation]))
            #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.isEmpty)
        } catch {
            await fixture.shutdown()
            try? await probe.finish()
            throw error
        }
        await fixture.shutdown()
        try await probe.finish()
    }

    @Test(
        "covering results close an open obligation in either arrival order",
        arguments: [(true, false), (false, false), (true, true), (false, true)])
    func coveringRunClosesOnlyItsCoveredObligation(resultFirst: Bool, laterTrigger: Bool) async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
        try await triggerWatchedFolderChange(fixture)
        await fixture.submissionGate.arm()
        let sourceID = FilesystemSourceID(kind: .watchedParentMembership, rootID: fixture.watchedPath.id)
        let submission = Task { await fixture.actor.submitWatchedFolderScan(sourceID: sourceID, cause: .fallback) }
        do {
            _ = try await fixture.submissionGate.waitForHeldSubmission()
            let start = try await fixture.scanner.nextStart()
            if laterTrigger { try await triggerWatchedFolderChange(fixture) }
            if !resultFirst {
                await fixture.submissionGate.open()
                await submission.value
            }
            let sequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(start, with: completeResult(entries: []))
            let observation = try await fixture.consumeTopologyObservation(sequence: sequence)
            if resultFirst {
                await fixture.submissionGate.open()
                await submission.value
            }
            #expect(await fixture.actor.areCurrentWatchedFolderObservations([observation]) == !laterTrigger)
            #expect(
                await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.count == (laterTrigger ? 1 : 0))
            if laterTrigger {
                _ = try await fixture.advancePacingDeadline()
                let covering = try await fixture.scanner.nextStart()
                let next = await fixture.actor.nextEnvelopeSequence + 1
                await fixture.scanner.finish(covering, with: completeResult(entries: []))
                _ = try await fixture.consumeTopologyObservation(sequence: next)
                #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.isEmpty)
            }
        } catch {
            await fixture.submissionGate.open()
            await fixture.shutdown()
            await submission.value
            throw error
        }
        await fixture.shutdown()
        await submission.value
    }

    @Test("an older result at the same revision cannot regain authority over a newer accepted demand")
    func sameRevisionOlderResultCannotRegressCoverage() async throws {
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        do {
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
            try await triggerWatchedFolderChange(fixture)
            _ = try await fixture.advancePacingDeadline()
            let old = try await fixture.scanner.nextStart()
            let sourceID = old.request.sourceID
            await fixture.actor.submitWatchedFolderScan(sourceID: sourceID, cause: .fallback)
            let newerMarker = await fixture.actor.watchedFolderScanState.latestDemandCoverageBySourceID[sourceID]
            let sequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(old, with: completeResult(entries: []))
            let oldObservation = try await fixture.consumeTopologyObservation(sequence: sequence)
            #expect(!watchedFolderObservationIsAuthoritative(oldObservation))
            #expect(await fixture.actor.watchedFolderScanState.latestDemandCoverageBySourceID[sourceID] == newerMarker)
            #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.count == 1)
            let newer = try await fixture.scanner.nextStart()
            #expect(newer.request.submissionSequence > old.request.submissionSequence)
            let closing = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(newer, with: completeResult(entries: []))
            let observation = try await fixture.consumeTopologyObservation(sequence: closing)
            #expect(await fixture.actor.areCurrentWatchedFolderObservations([observation]))
            #expect(await fixture.actor.watchedFolderScanState.pacing.obligationsBySourceID.isEmpty)
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
    }

    @Test("shutdown cancels a registered deadline and prevents later scan submission")
    func shutdownRetiresPendingPacingDeadline() async throws {
        let probe = try WatchedFolderScanPacingProbe()
        let fixture = try await WatchedFolderActorFixture(clock: probe.clock)
        defer { fixture.removeTemporaryRoot() }
        do {
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
            fixture.submissionLog.reset()
            try await triggerWatchedFolderChange(fixture)
            let producer = try #require(await fixture.actor.watchedFolderScanState.pacingDeadlineTask)
            _ = try await probe.nextSleep(producedBy: producer)
            await fixture.shutdown()
            probe.clock.advance(by: .seconds(60))
            #expect(fixture.submissionLog.entries.isEmpty)
            #expect(probe.clock.pendingSleepCount == 0)
        } catch {
            await fixture.shutdown()
            try? await probe.finish()
            throw error
        }
        await fixture.shutdown()
        try await probe.finish()
    }

    @Test("shutdown before clock registration terminates the wait and submits no deferred scan")
    func shutdownBeforePacingSleepEndsObservation() async throws {
        let registration = HeldStep<TestPushClock.Instant>("pacing sleep before registration")
        let probe = try WatchedFolderScanPacingProbe(beforeRegistration: { try await registration.arrive($0) })
        let fixture = try await WatchedFolderActorFixture(clock: probe.clock)
        defer { fixture.removeTemporaryRoot() }
        var waiting: Task<TestPushClock.Instant, Error>?
        var retirement: Task<Void, Never>?
        do {
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
            fixture.submissionLog.reset()
            try await triggerWatchedFolderChange(fixture)
            let producer = try #require(await fixture.actor.watchedFolderScanState.pacingDeadlineTask)
            retirement = Task {
                await producer.value
                registration.retire()
            }
            let nextSleep = Task { try await probe.nextSleep(producedBy: producer) }
            waiting = nextSleep
            _ = try await registration.firstArrival()
            await fixture.shutdown()
            await #expect(throws: WatchedFolderScanPacingProbe.Failure.self) { try await nextSleep.value }
            #expect(fixture.submissionLog.entries.isEmpty)
        } catch {
            registration.release()
            await fixture.shutdown()
            _ = await waiting?.result
            await retirement?.value
            try? await probe.finish()
            throw error
        }
        registration.release()
        await fixture.shutdown()
        _ = await waiting?.result
        await retirement?.value
        try await probe.finish()
    }

    @Test(
        "tracked and untracked explicit acceptance preserves a newer trigger's invalidation",
        arguments: [(true, true), (true, false), (false, true), (false, false)])
    func explicitAcceptancePreservesTriggerRevision(tracked: Bool, laterTrigger: Bool) async throws {
        // Arrange: the real scheduler accepts, then the existing gate holds its reply.
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
        fixture.submissionLog.reset()
        await fixture.submissionGate.arm()
        let sourceID = FilesystemSourceID(kind: .watchedParentMembership, rootID: fixture.watchedPath.id)
        let submission = Task<Void, Never> {
            if tracked {
                _ = await fixture.actor.refreshWatchedFolders([fixture.watchedPath])
            } else {
                await fixture.actor.submitWatchedFolderScan(sourceID: sourceID, cause: .fallback)
            }
        }
        do {
            _ = try await fixture.submissionGate.waitForHeldSubmission()
            let start = try await fixture.scanner.nextStart()
            #expect(fixture.submissionLog.entries.first?.submittedAt == .zero)
            // Act: relevant evidence arrives after reserve but before explicit acceptance.
            if laterTrigger {
                let callbackID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
                await fixture.actor.handleWatchedFolderFSEvent(
                    .init(
                        worktreeId: callbackID, paths: [fixture.watchedFolder.appending(path: "new/.git/HEAD").path]))
            }
            let sequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(start, with: completeResult(entries: []))
            _ = try await fixture.consumeTopologyObservation(sequence: sequence)
            await fixture.submissionGate.open()
            await submission.value
            // Assert: both causes have the same revision rule; the no-trigger case is its control.
            let marker = await fixture.actor.watchedFolderScanState.latestDemandCoverageBySourceID[sourceID]
            #expect((marker == nil) == laterTrigger)
        } catch {
            await fixture.submissionGate.open()
            await fixture.shutdown()
            await submission.value
            throw error
        }
        await fixture.shutdown()
        await submission.value
    }

    @Test(
        "result and acceptance order agree on currency with or without a later trigger",
        arguments: [(true, false), (false, false), (true, true), (false, true)])
    func resultAndAcceptanceOrderPreserveCurrency(resultFirst: Bool, laterTrigger: Bool) async throws {
        // Arrange
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
        await fixture.submissionGate.arm()
        let sourceID = FilesystemSourceID(kind: .watchedParentMembership, rootID: fixture.watchedPath.id)
        let submission = Task { await fixture.actor.submitWatchedFolderScan(sourceID: sourceID, cause: .fallback) }
        do {
            _ = try await fixture.submissionGate.waitForHeldSubmission()
            let start = try await fixture.scanner.nextStart()
            if laterTrigger {
                let callbackID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
                await fixture.actor.handleWatchedFolderFSEvent(
                    .init(
                        worktreeId: callbackID, paths: [fixture.watchedFolder.appending(path: "new/.git").path]))
            }
            if !resultFirst {
                await fixture.submissionGate.open()
                await submission.value
            }
            let sequence = await fixture.actor.nextEnvelopeSequence + 1
            // Act
            await fixture.scanner.finish(start, with: completeResult(entries: []))
            let observation = try await fixture.consumeTopologyObservation(sequence: sequence)
            if resultFirst {
                await fixture.submissionGate.open()
                await submission.value
            }
            // Assert
            let authoritative: Bool
            switch observation.coverage {
            case .authoritative: authoritative = true
            case .additive: authoritative = false
            }
            #expect(authoritative == !laterTrigger)
            #expect(await fixture.actor.areCurrentWatchedFolderObservations([observation]) == !laterTrigger)
        } catch {
            await fixture.submissionGate.open()
            await fixture.shutdown()
            await submission.value
            throw error
        }
        await fixture.shutdown()
        await submission.value
    }

    @Test("membership trigger clears authority before its deferred submission")
    func callbackTriggerClearsAuthorityBeforeSubmission() async throws {
        // Arrange
        let fixture = try await WatchedFolderActorFixture()
        defer { fixture.removeTemporaryRoot() }
        _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
        fixture.submissionLog.reset()
        do {
            let callbackID = try #require(fixture.fseventClient.registeredWorktreeIds.first)
            let sourceID = FilesystemSourceID(kind: .watchedParentMembership, rootID: fixture.watchedPath.id)
            #expect(await fixture.actor.watchedFolderScanState.latestDemandCoverageBySourceID[sourceID] != nil)
            // Act: the actual ingress owner receives relevant evidence at controlled t=0.
            await fixture.actor.handleWatchedFolderFSEvent(
                .init(
                    worktreeId: callbackID, paths: [fixture.watchedFolder.appending(path: "repo/.git/HEAD").path]))
            // Assert: old code submits immediately and restores authority, failing both assertions.
            #expect(fixture.submissionLog.entries.isEmpty)
            #expect(await fixture.actor.watchedFolderScanState.latestDemandCoverageBySourceID[sourceID] == nil)
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
    }
}
