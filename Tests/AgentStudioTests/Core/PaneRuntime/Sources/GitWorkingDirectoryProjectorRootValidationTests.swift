import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

extension GitWorkingDirectoryProjectorAdmissionTests {
    @Test("successful same-root refreshes retain validation without probing again")
    func successfulReenqueueRetainsRootValidation() async throws {
        let scenario = try await makeRootValidationScenario()
        do {
            // Arrange: accept a successful status at controlled time zero.
            _ = try await scenario.refresh(batchSeq: 1)
            #expect(await scenario.projector.validatedRootPathByWorktreeId[scenario.worktreeId] == scenario.rootPath)

            // Act: ordinary re-enqueue at the same controlled instant.
            let scope = GitProjectorScope.refresh(worktreeId: scenario.worktreeId, requestSequence: 2)
            let opening = await scenario.facts.mark(scope)
            await scenario.projector.enqueueImmediateRefresh(
                scenario.changeset(batchSeq: 2), triggerSource: .filesystemChange)
            try await scenario.facts.expectNone(
                of: unsuccessfulRootValidationFact, "unsuccessful same-root refresh",
                from: opening, closedBy: { if case .refreshClosed = $0 { true } else { false } }
            )

            // Assert: the exact completed operation paid one probe across both reads.
            #expect(scenario.probeState.withLock { $0.probedRoots } == [scenario.rootPath])
            #expect(scenario.probeState.withLock { $0.statusCallCount } == 2)
            #expect(await scenario.projector.validatedRootPathByWorktreeId[scenario.worktreeId] == scenario.rootPath)
            #expect(await scenario.projector.lastAcceptedStatusAtByWorktreeId[scenario.worktreeId] == .zero)
            await scenario.projector.shutdown()
            try await scenario.facts.finish()
        } catch {
            await scenario.projector.shutdown()
            throw error
        }
    }

    @Test(
        "every non-capacity unavailable result invalidates a previously successful root",
        arguments: [
            GitWorkingTreeStatusUnavailableReason.sdkError, .timeout, .providerReturnedNil, .cancelled,
        ]
    )
    func unavailableResultInvalidatesRootValidation(reason: GitWorkingTreeStatusUnavailableReason) async throws {
        let scenario = try await makeRootValidationScenario()
        do {
            // Arrange: the successful baseline remains present throughout the failure.
            _ = try await scenario.refresh(batchSeq: 1)
            #expect(await scenario.projector.validatedRootPathByWorktreeId[scenario.worktreeId] == scenario.rootPath)
            scenario.probeState.withLock { $0.failureReason = reason }

            // Act / Assert: failure clears validation despite the old accepted baseline.
            let outcome = try await scenario.refresh(batchSeq: 2)
            #expect(outcome == (reason == .timeout ? .timeout : .unavailable))
            #expect(await scenario.projector.validatedRootPathByWorktreeId[scenario.worktreeId] == nil)
            #expect(await scenario.projector.lastAcceptedStatusAtByWorktreeId[scenario.worktreeId] == .zero)
            #expect(scenario.probeState.withLock { $0.probedRoots } == [scenario.rootPath])
            await scenario.projector.shutdown()
            try await scenario.facts.finish()
        } catch {
            await scenario.projector.shutdown()
            throw error
        }
    }

    @Test("a vanished validated root fails status, then opens quarantine at the next admission")
    func vanishedValidatedRootOpensAndClosesQuarantine() async throws {
        let scenario = try await makeRootValidationScenario()
        do {
            // Arrange: require cached success so a broken baseline fails without awaiting a non-admitted read.
            _ = try await scenario.refresh(batchSeq: 1)
            try #require(
                await scenario.projector.validatedRootPathByWorktreeId[scenario.worktreeId] == scenario.rootPath)
            scenario.probeState.withLock { $0.rootExists = false }

            // Act: the cached admission reaches the provider, whose missing-root failure invalidates it.
            #expect(try await scenario.refresh(batchSeq: 2) == .unavailable)
            #expect(await scenario.projector.validatedRootPathByWorktreeId[scenario.worktreeId] == nil)
            #expect(scenario.probeState.withLock { $0.probedRoots } == [scenario.rootPath])
            let failureScope = try await scenario.source.expectDeadlineRegistered(
                facts: scenario.facts, worktreeId: scenario.worktreeId, kind: .failure
            )
            let opening = await scenario.facts.mark(failureScope)
            let failureDeadline = try #require(
                await scenario.projector.statusFailureDeadlineByWorktreeId[scenario.worktreeId]
            )
            let clockNow = await scenario.projector.deadlineClock.now
            let wake = scenario.clock.now.advanced(by: failureDeadline - clockNow)
            #expect(await scenario.clock.waitForPendingSleep(deadline: wake) == wake)
            scenario.clock.advance(to: wake)

            // Assert: re-admission probes, opens quarantine, and spends no status slot.
            let quarantineScope = GitProjectorScope.quarantine(worktreeId: scenario.worktreeId, episode: 1)
            try await scenario.facts.expectNext(in: quarantineScope, .quarantineOpened)
            try await scenario.facts.expectNone(
                of: { $0 == .deadlineDisposition(.admitted) }, "admission of the vanished root",
                from: opening, closedBy: { if case .deadlineDisposition = $0 { true } else { false } }
            )
            #expect(scenario.probeState.withLock { $0.probedRoots } == [scenario.rootPath, scenario.rootPath])
            #expect(scenario.probeState.withLock { $0.statusCallCount } == 2)
            #expect(await scenario.projector.quarantinedWorktreeIds == [scenario.worktreeId])

            // A filesystem fact through the bus re-arms the restored root and closes the episode.
            scenario.probeState.withLock { $0.rootExists = true }
            await scenario.bus.post(
                .worktree(
                    WorktreeEnvelope(
                        source: .system(.builtin(.filesystemWatcher)), seq: 1,
                        timestamp: ContinuousClock().now, repoId: scenario.worktreeId,
                        worktreeId: scenario.worktreeId,
                        event: .filesystem(.filesChanged(changeset: scenario.changeset(batchSeq: 3)))
                    )
                )
            )
            try await scenario.facts.expectNext(in: quarantineScope, .quarantineClosed)
            #expect(try await scenario.facts.expectHandledEnvelope(seq: 1) == .routed)
            _ = try await scenario.source.expectNextRefreshClosed(
                facts: scenario.facts, worktreeId: scenario.worktreeId
            )
            #expect(await scenario.projector.validatedRootPathByWorktreeId[scenario.worktreeId] == scenario.rootPath)
            #expect(scenario.probeState.withLock { $0.statusCallCount } == 3)
            await scenario.projector.shutdown()
            try await scenario.facts.finish()
        } catch {
            await scenario.projector.shutdown()
            throw error
        }
    }

    @Test("a superseded response cannot retain validation from an older successful baseline")
    func supersededResponseInvalidatesRootValidation() async throws {
        let heldStatus = HeldStep<Void>("second root validation status request")
        let scenario = try await makeRootValidationScenario(heldSecondStatus: heldStatus)
        do {
            // Arrange: the second read is held after a successful first read.
            _ = try await scenario.refresh(batchSeq: 1)
            try #require(
                await scenario.projector.validatedRootPathByWorktreeId[scenario.worktreeId] == scenario.rootPath)
            await scenario.projector.enqueueImmediateRefresh(
                scenario.changeset(batchSeq: 2), triggerSource: .filesystemChange)
            try await scenario.facts.expectRefreshStarted(worktreeId: scenario.worktreeId, requestSequence: 2)
            _ = try await heldStatus.firstArrival()

            // Act: a newer pending batch makes the held result unpublishable.
            await scenario.projector.enqueueImmediateRefresh(
                scenario.changeset(batchSeq: 3), triggerSource: .filesystemChange)
            heldStatus.release()
            #expect(
                try await scenario.facts.expectRefreshClosed(worktreeId: scenario.worktreeId, requestSequence: 2)
                    == .superseded
            )
            _ = try await scenario.facts.expectRefreshClosed(
                worktreeId: scenario.worktreeId, requestSequence: 3
            )

            // Assert: the successor had to validate again; only its accepted success retains the root.
            #expect(scenario.probeState.withLock { $0.probedRoots } == [scenario.rootPath, scenario.rootPath])
            #expect(await scenario.projector.validatedRootPathByWorktreeId[scenario.worktreeId] == scenario.rootPath)
            await scenario.projector.shutdown()
            try await scenario.facts.finish()
        } catch {
            heldStatus.retire()
            await scenario.projector.shutdown()
            throw error
        }
    }
}

private struct RootValidationProbeState {
    var rootExists = true
    var failureReason: GitWorkingTreeStatusUnavailableReason?
    var probedRoots: [URL] = []
    var statusCallCount = 0
}

private final class RootValidationProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var state = RootValidationProbeState()

    func withLock<TResult>(_ body: (inout RootValidationProbeState) -> TResult) -> TResult {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private struct RootValidationScenario {
    let worktreeId: UUID
    let rootPath: URL
    let bus: EventBus<RuntimeEnvelope>
    let clock: TestPushClock
    let source: GitProjectorFactSource
    let facts: FactRecorder<GitProjectorScope, GitProjectorFact>
    let probeState: RootValidationProbeRecorder
    let projector: GitWorkingDirectoryProjector

    func changeset(batchSeq: UInt64) -> FileChangeset {
        admissionFilesystemChangeset(worktreeId: worktreeId, rootPath: rootPath, batchSeq: batchSeq)
    }

    func refresh(batchSeq: UInt64) async throws -> GitProjectorRefreshOutcome {
        await projector.enqueueImmediateRefresh(changeset(batchSeq: batchSeq), triggerSource: .filesystemChange)
        let requestSequence = try await facts.expectNextRefreshStarted(worktreeId: worktreeId)
        return try await facts.expectRefreshClosed(worktreeId: worktreeId, requestSequence: requestSequence)
    }
}

private func makeRootValidationScenario(
    heldSecondStatus: HeldStep<Void>? = nil
) async throws -> RootValidationScenario {
    let worktreeId = UUIDv7.generate()
    let rootPath = URL(fileURLWithPath: "/tmp/root-validation-\(worktreeId)")
    let bus = EventBus<RuntimeEnvelope>()
    let clock = TestPushClock()
    let source = GitProjectorFactSource()
    let facts = try source.attach()
    let probeState = RootValidationProbeRecorder()
    let projector = GitWorkingDirectoryProjector(
        bus: bus,
        gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider(resultHandler: { _ in
            let (callCount, failureReason) = probeState.withLock { state in
                state.statusCallCount += 1
                return (state.statusCallCount, state.rootExists ? state.failureReason : .sdkError)
            }
            if callCount == 2, let heldSecondStatus { try? await heldSecondStatus.arrive(()) }
            if let failureReason { return .unavailable(GitWorkingTreeStatusUnavailable(reason: failureReason)) }
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main", origin: nil
                )
            )
        }),
        coalescingWindow: .zero,
        sleepClock: clock,
        refreshPolicy: AppPolicies.GitRefresh.Policy(minimumAutomaticStartInterval: .zero),
        factSink: source.sink,
        pathExistenceProbe: { rootPath in
            probeState.withLock { state in
                state.probedRoots.append(rootPath)
                return state.rootExists
            }
        }
    )
    await installRootValidationContext(projector, worktreeId: worktreeId, rootPath: rootPath)
    await projector.start()
    return RootValidationScenario(
        worktreeId: worktreeId, rootPath: rootPath, bus: bus, clock: clock,
        source: source, facts: facts, probeState: probeState, projector: projector
    )
}

private func installRootValidationContext(
    _ projector: isolated GitWorkingDirectoryProjector, worktreeId: UUID, rootPath: URL
) {
    projector.rootPathByWorktreeId[worktreeId] = rootPath
    projector.repoIdByWorktreeId[worktreeId] = worktreeId
    projector.activeWorktreeIds.insert(worktreeId)
}

private func unsuccessfulRootValidationFact(_ fact: GitProjectorFact) -> Bool {
    guard case .refreshClosed(let outcome) = fact else { return false }
    switch outcome {
    case .completed, .equal: return false
    default: return true
    }
}
