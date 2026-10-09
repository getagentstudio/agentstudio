import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("AppDelegate repository fact update", .serialized)
struct AppDelegateRepositoryFactUpdateTests {
    @Test("composite telemetry never reports incomplete source coverage as complete")
    func compositeTelemetryRejectsIncompleteSourceCoverage() {
        let progress = RepositoryFactUpdateProgress.admitted(
            repoId: UUIDv7.generate(),
            attemptId: UUIDv7.generate(),
            applicableSources: [.localGit],
            terminalResultsBySource: [:]
        ).settled([:])

        #expect(AppDelegate.repositoryFactUpdateSettlementOutcome(progress) == "incomplete")
    }

    @Test("real dispatcher drives targeted capability and App-owned update join")
    func dispatcherDrivesTargetedRepositoryFactUpdate() async throws {
        let admissionGate = AppDelegateRepositoryFactUpdateGate()
        let fixture = makeFixture(
            admissionGate: admissionGate,
            admissions: [
                .localGit: .notApplicable,
                .remoteReferences: .notApplicable,
                .forge: .notApplicable,
            ]
        )

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = nil
                configuration.shellOwner = fixture.delegate
            },
            body: { dispatcher in
                let dispatcher = dispatcher
                #expect(
                    dispatcher.canDispatch(
                        .updateRepositoryFacts,
                        target: fixture.repository.id,
                        targetType: .repo
                    )
                )
                #expect(
                    dispatcher.dispatch(
                        .updateRepositoryFacts,
                        target: fixture.repository.id,
                        targetType: .repo,
                        executionContext: .interactive
                    )
                )
                #expect(
                    fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)?.phase
                        == .captured
                )
                #expect(
                    !dispatcher.canDispatch(
                        .updateRepositoryFacts,
                        target: fixture.repository.id,
                        targetType: .repo
                    )
                )

                await admissionGate.release()
                #expect(
                    await repositoryFactUpdateEventually {
                        fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)?.phase
                            == .settled
                    }
                )
            }
        )
    }

    @Test("dispatch preserves launcher recency and captures progress before source admission")
    func dispatchPreservesRecencyAndCapturesProgressBeforeAdmission() async throws {
        let admissionGate = AppDelegateRepositoryFactUpdateGate()
        let localSettlementGate = AppDelegateRepositoryFactUpdateOutcomeGate(outcome: .completed)
        let remoteSettlementGate = AppDelegateRepositoryFactUpdateOutcomeGate(outcome: .failed)
        let fixture = makeFixture(
            admissionGate: admissionGate,
            admissions: [
                .localGit: .accepted(localSettlementGate.lease(source: .localGit)),
                .remoteReferences: .accepted(remoteSettlementGate.lease(source: .remoteReferences)),
                .forge: .notApplicable,
            ]
        )

        #expect(fixture.delegate.execute(.updateRepositoryFacts, target: fixture.repository.id, targetType: .repo))

        let capturedProgress = try #require(
            fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)
        )
        #expect(capturedProgress.phase == .captured)
        #expect(capturedProgress.unsettledSources.isEmpty)
        let recordedStableKeys = Set(
            fixture.delegate.atomStore.core.applicationEntityRecency.recentEntities.map(\.entity.storageKey)
        )
        #expect(recordedStableKeys.isEmpty)
        #expect(!fixture.delegate.execute(.updateRepositoryFacts, target: fixture.repository.id, targetType: .repo))

        await admissionGate.release()
        #expect(
            await repositoryFactUpdateEventually {
                fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)?.phase
                    == .inProgress
            }
        )
        let admittedProgress = try #require(
            fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)
        )
        #expect(admittedProgress.applicableSources == [.localGit, .remoteReferences])
        #expect(admittedProgress.unsettledSources == [.localGit, .remoteReferences])
        #expect(admittedProgress.settledResultsBySource[.forge] == .notApplicable)

        await localSettlementGate.release()
        await remoteSettlementGate.release()
        #expect(
            await repositoryFactUpdateEventually {
                fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)?.phase
                    == .settled
            }
        )
        let settledProgress = try #require(
            fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)
        )
        #expect(settledProgress.unsettledSources.isEmpty)
        #expect(settledProgress.settledResultsBySource[.localGit] == .completed)
        #expect(settledProgress.settledResultsBySource[.remoteReferences] == .failed)
        #expect(await fixture.source.callCount == 1)
    }

    @Test("missing repository rejects without recency progress or source calls")
    func missingRepositoryRejectsWithoutSideEffects() async {
        let fixture = makeFixture(admissions: [:])
        let missingRepositoryID = UUIDv7.generate()

        #expect(!fixture.delegate.execute(.updateRepositoryFacts, target: missingRepositoryID, targetType: .repo))

        #expect(fixture.delegate.atomStore.core.applicationEntityRecency.recentEntities.isEmpty)
        #expect(fixture.delegate.repoCache.repositoryFactUpdateProgress(for: missingRepositoryID) == nil)
        #expect(await fixture.source.callCount == 0)
    }

    @Test("all not-applicable sources settle without false loading")
    func allNotApplicableSourcesSettleWithoutLoading() async throws {
        let fixture = makeFixture(
            admissions: [
                .localGit: .notApplicable,
                .remoteReferences: .notApplicable,
                .forge: .notApplicable,
            ]
        )

        #expect(fixture.delegate.execute(.updateRepositoryFacts, target: fixture.repository.id, targetType: .repo))
        #expect(
            await repositoryFactUpdateEventually {
                fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)?.phase
                    == .settled
            }
        )

        let progress = try #require(
            fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)
        )
        #expect(progress.applicableSources.isEmpty)
        #expect(progress.unsettledSources.isEmpty)
        #expect(!progress.isLoading)
        #expect(fixture.delegate.repositoryFactUpdateTasksByRepoId[fixture.repository.id] == nil)

        fixture.delegate.acknowledgePresentedRepositoryFactUpdate(
            repoId: fixture.repository.id,
            attemptId: progress.attemptId
        )
        #expect(
            fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)
                == nil
        )
    }

    @Test("presentation acknowledgement clears only the exact settled attempt after task custody ends")
    func presentationAcknowledgementValidatesAttemptPhaseAndTaskCustody() async {
        let fixture = makeFixture(admissions: [:])
        let repoID = fixture.repository.id
        let settledAttemptID = UUIDv7.generate()
        let newerAttemptID = UUIDv7.generate()
        let settledProgress = RepositoryFactUpdateProgress.captured(
            repoId: repoID,
            attemptId: settledAttemptID
        ).settled([:])

        fixture.delegate.repoCache.setRepositoryFactUpdateProgress(settledProgress)
        fixture.delegate.repositoryFactUpdateTasksByRepoId[repoID] = Task {}
        fixture.delegate.acknowledgePresentedRepositoryFactUpdate(
            repoId: repoID,
            attemptId: settledAttemptID
        )
        #expect(fixture.delegate.repoCache.repositoryFactUpdateProgress(for: repoID) == settledProgress)

        fixture.delegate.repositoryFactUpdateTasksByRepoId.removeValue(forKey: repoID)
        fixture.delegate.repoCache.setRepositoryFactUpdateProgress(
            .captured(repoId: repoID, attemptId: newerAttemptID)
        )
        fixture.delegate.acknowledgePresentedRepositoryFactUpdate(
            repoId: repoID,
            attemptId: settledAttemptID
        )
        #expect(
            fixture.delegate.repoCache.repositoryFactUpdateProgress(for: repoID)?.attemptId
                == newerAttemptID
        )

        fixture.delegate.repoCache.setRepositoryFactUpdateProgress(settledProgress)
        fixture.delegate.acknowledgePresentedRepositoryFactUpdate(
            repoId: repoID,
            attemptId: settledAttemptID
        )
        #expect(fixture.delegate.repoCache.repositoryFactUpdateProgress(for: repoID) == nil)

        fixture.delegate.acknowledgePresentedRepositoryFactUpdate(
            repoId: repoID,
            attemptId: settledAttemptID
        )
        #expect(fixture.delegate.repoCache.repositoryFactUpdateProgress(for: repoID) == nil)
    }

    @Test("repository removal clears progress and rejects late settlement")
    func repositoryRemovalRejectsLateSettlement() async throws {
        let localSettlementGate = AppDelegateRepositoryFactUpdateOutcomeGate(outcome: .completed)
        let fixture = makeFixture(
            admissions: [
                .localGit: .accepted(localSettlementGate.lease(source: .localGit)),
                .remoteReferences: .notApplicable,
                .forge: .notApplicable,
            ]
        )
        #expect(fixture.delegate.execute(.updateRepositoryFacts, target: fixture.repository.id, targetType: .repo))
        #expect(
            await repositoryFactUpdateEventually {
                fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)?.phase
                    == .inProgress
            }
        )

        fixture.delegate.cancelRepositoryFactUpdate(repoId: fixture.repository.id)
        #expect(fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id) == nil)

        await localSettlementGate.release()
        await Task.yield()
        #expect(fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id) == nil)
    }

    @Test("shutdown waits for source custody after clearing update progress")
    func shutdownWaitsForSourceCustody() async throws {
        let localSettlementGate = AppDelegateRepositoryFactUpdateOutcomeGate(outcome: .cancelled)
        let fixture = makeFixture(
            admissions: [
                .localGit: .accepted(localSettlementGate.lease(source: .localGit)),
                .remoteReferences: .notApplicable,
                .forge: .notApplicable,
            ]
        )
        #expect(fixture.delegate.execute(.updateRepositoryFacts, target: fixture.repository.id, targetType: .repo))
        #expect(
            await repositoryFactUpdateEventually {
                fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id)?.phase
                    == .inProgress
            }
        )

        fixture.delegate.cancelAllRepositoryFactUpdates()
        #expect(fixture.delegate.repoCache.repositoryFactUpdateProgress(for: fixture.repository.id) == nil)
        let settlementRecorder = AppDelegateRepositoryFactUpdateSettlementRecorder()
        let waitTask = Task { @MainActor in
            await fixture.delegate.waitForRepositoryFactUpdatesToSettle()
            await settlementRecorder.recordCompletion()
        }
        for _ in 0..<300 { await Task.yield() }
        #expect(await !settlementRecorder.didComplete)

        await localSettlementGate.release()
        await waitTask.value
        #expect(await settlementRecorder.didComplete)
    }

    private func makeFixture(
        admissionGate: AppDelegateRepositoryFactUpdateGate? = nil,
        admissions: [RepositoryFactSource: RepositoryFactSourceUpdateAdmission]
    ) -> AppDelegateRepositoryFactUpdateFixture {
        let delegate = AppDelegate()
        delegate.atomStore = AtomRegistry()
        let store = WorkspaceStore()
        let repository = store.addRepo(at: URL(filePath: "/tmp/repository-fact-update"))
        let linkedWorktree = Worktree(
            id: UUIDv7.generate(),
            repoId: repository.id,
            name: "feature/update",
            path: URL(filePath: "/tmp/repository-fact-update-feature")
        )
        store.reconcileDiscoveredWorktrees(
            repository.id,
            worktrees: repository.worktrees + [linkedWorktree]
        )
        delegate.store = store
        let source = AppDelegateRepositoryFactUpdateSourceFake(
            admissionGate: admissionGate,
            admissions: admissions
        )
        delegate.repositoryFactUpdateSource = source
        return AppDelegateRepositoryFactUpdateFixture(
            delegate: delegate,
            repository: store.repositoryTopologyAtom.repo(repository.id)!,
            source: source
        )
    }
}

private struct AppDelegateRepositoryFactUpdateFixture {
    let delegate: AppDelegate
    let repository: Repo
    let source: AppDelegateRepositoryFactUpdateSourceFake
}

private actor AppDelegateRepositoryFactUpdateSourceFake: RepositoryFactUpdateStarting {
    private let admissionGate: AppDelegateRepositoryFactUpdateGate?
    private let admissions: [RepositoryFactSource: RepositoryFactSourceUpdateAdmission]
    private(set) var callCount = 0

    init(
        admissionGate: AppDelegateRepositoryFactUpdateGate?,
        admissions: [RepositoryFactSource: RepositoryFactSourceUpdateAdmission]
    ) {
        self.admissionGate = admissionGate
        self.admissions = admissions
    }

    func startRepositoryFactUpdate(
        repoId _: UUID,
        attemptId _: UUID
    ) async -> RepositoryFactUpdateAdmissionBatch {
        callCount += 1
        await admissionGate?.wait()
        return RepositoryFactUpdateAdmissionBatch(admissionsBySource: admissions)
    }
}

private actor AppDelegateRepositoryFactUpdateGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters { waiter.resume() }
    }
}

private final class AppDelegateRepositoryFactUpdateOutcomeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: RepositoryFactSourceUpdateOutcome
    private var continuation: CheckedContinuation<RepositoryFactSourceUpdateOutcome, Never>?
    private var isReleased = false

    init(outcome: RepositoryFactSourceUpdateOutcome) {
        self.outcome = outcome
    }

    func lease(source: RepositoryFactSource) -> RepositoryFactSourceUpdateLease {
        RepositoryFactSourceUpdateLease(
            source: source,
            attemptId: UUIDv7.generate(),
            settlementTask: Task {
                await withCheckedContinuation { continuation in
                    let shouldResume = self.lock.withLock { () -> Bool in
                        guard !self.isReleased else { return true }
                        self.continuation = continuation
                        return false
                    }
                    if shouldResume {
                        continuation.resume(returning: self.outcome)
                    }
                }
            }
        )
    }

    func release() async {
        let continuation = lock.withLock { () -> CheckedContinuation<RepositoryFactSourceUpdateOutcome, Never>? in
            isReleased = true
            let captured = self.continuation
            self.continuation = nil
            return captured
        }
        continuation?.resume(returning: outcome)
    }
}

private actor AppDelegateRepositoryFactUpdateSettlementRecorder {
    private(set) var didComplete = false

    func recordCompletion() {
        didComplete = true
    }
}

private func repositoryFactUpdateEventually(
    maxTurns: Int = 20_000,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<maxTurns {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}
