import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Worktree annotation Store demand and source refresh")
struct WorktreeAnnotationStoreSourceRefreshTests {
    @Test("reacquired demand accepts a restarted viewer source epoch")
    func reacquiredDemandAcceptsRestartedViewerSourceEpoch() async throws {
        let repository = try makeAnnotationRepository()
        let store = WorktreeAnnotationServiceActor(
            repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(repository: repository)
        )
        let detail = try await store.createRootDraft(makeLocatedRootDraftProps())

        let initialDemandGeneration = try await store.acquireDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )
        _ = try await store.refreshSource(
            .init(
                contextID: "pane-a",
                demandGeneration: initialDemandGeneration,
                sessionID: detail.session.id,
                surface: .file,
                sourceEpoch: 2,
                expectedSnapshot: try await store.sourceRefreshSnapshot(
                    sessionID: detail.session.id
                ),
                currentFingerprint: makeSourceFingerprint(identity: "source-a"),
                material: .available([
                    .init(
                        path: "Sources/Feature.swift",
                        sourceRole: .file,
                        sourceIdentity: "source-a",
                        body: "before\nselected line\nafter\n"
                    )
                ]),
                now: Date(timeIntervalSince1970: 3)
            )
        )
        await store.releaseDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )

        let restartedDemandGeneration = try await store.acquireDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )
        let restartedRefreshDetail = try await store.refreshSource(
            .init(
                contextID: "pane-a",
                demandGeneration: restartedDemandGeneration,
                sessionID: detail.session.id,
                surface: .file,
                sourceEpoch: 1,
                expectedSnapshot: try await store.sourceRefreshSnapshot(
                    sessionID: detail.session.id
                ),
                currentFingerprint: makeSourceFingerprint(identity: "source-a"),
                material: .available([
                    .init(
                        path: "Sources/Feature.swift",
                        sourceRole: .file,
                        sourceIdentity: "source-a",
                        body: "before\nselected line\nafter\n"
                    )
                ]),
                now: Date(timeIntervalSince1970: 4)
            )
        )

        #expect(restartedRefreshDetail.session.acceptedSourceFingerprint.fileSourceIdentity == "source-a")
        #expect(
            try repository.fetchSessionDetail(sessionID: detail.session.id)
                .session.acceptedSourceFingerprint.fileSourceIdentity == "source-a"
        )
    }

    @Test("new demand generation prevents delayed earlier refresh publication")
    func newDemandGenerationRejectsDelayedEarlierRefresh() async throws {
        let initialDetail = try makeLocatedCommittedDetail()
        let access = ControllableSourceRefreshAnnotationAccess(
            initialDetail: initialDetail,
            committedDetail: makeSourceUpdatedDetail(
                from: initialDetail,
                fingerprint: makeSourceFingerprint(identity: "source-stale")
            )
        )
        let store = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let earlierDemandGeneration = try await store.acquireDemand(
            worktreeID: initialDetail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: initialDetail.session.id
        )
        let earlierSnapshot = try await store.sourceRefreshSnapshot(
            sessionID: initialDetail.session.id
        )

        let delayedRefresh = Task {
            try await store.refreshSource(
                .init(
                    contextID: "pane-a",
                    demandGeneration: earlierDemandGeneration,
                    sessionID: initialDetail.session.id,
                    surface: .file,
                    sourceEpoch: 2,
                    expectedSnapshot: earlierSnapshot,
                    currentFingerprint: makeSourceFingerprint(identity: "source-stale"),
                    material: .available([
                        .init(
                            path: "Sources/Feature.swift",
                            sourceRole: .file,
                            sourceIdentity: "source-stale",
                            body: "before\nselected line\nafter\n"
                        )
                    ]),
                    now: Date(timeIntervalSince1970: 3)
                )
            )
        }
        await access.waitForSourceCommit()

        let currentDemandGeneration = try await store.acquireDemand(
            worktreeID: initialDetail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: initialDetail.session.id
        )
        await access.completeSourceCommit()

        await #expect(throws: WorktreeAnnotationServiceError.staleSourceEpoch) {
            _ = try await delayedRefresh.value
        }

        let currentDetail = try await store.refreshSource(
            .init(
                contextID: "pane-a",
                demandGeneration: currentDemandGeneration,
                sessionID: initialDetail.session.id,
                surface: .file,
                sourceEpoch: 1,
                expectedSnapshot: try await store.sourceRefreshSnapshot(
                    sessionID: initialDetail.session.id
                ),
                currentFingerprint: makeSourceFingerprint(identity: "source-original"),
                material: .available([
                    .init(
                        path: "Sources/Feature.swift",
                        sourceRole: .file,
                        sourceIdentity: "source-original",
                        body: "before\nselected line\nafter\n"
                    )
                ]),
                now: Date(timeIntervalSince1970: 4)
            )
        )
        #expect(currentDetail == initialDetail)
        await store.releaseDemand(
            worktreeID: initialDetail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: initialDetail.session.id
        )
    }

    @Test("superseded refresh cannot enter a durable source commit after its detail read")
    func supersededRefreshCannotEnterDurableSourceCommitAfterDetailRead() async throws {
        let detail = try makeLocatedCommittedDetail()
        let access = ControllableSourceRefreshDetailLoadAccess(detail: detail)
        let store = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let earlierDemandGeneration = try await store.acquireDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )
        let expectedSnapshot = try await store.sourceRefreshSnapshot(sessionID: detail.session.id)

        let delayedRefresh = Task {
            try await store.refreshSource(
                .init(
                    contextID: "pane-a",
                    demandGeneration: earlierDemandGeneration,
                    sessionID: detail.session.id,
                    surface: .file,
                    sourceEpoch: 1,
                    expectedSnapshot: expectedSnapshot,
                    currentFingerprint: makeSourceFingerprint(identity: "source-new"),
                    material: .available([
                        .init(
                            path: "Sources/Feature.swift",
                            sourceRole: .file,
                            sourceIdentity: "source-new",
                            body: "before\nselected line\nafter\n"
                        )
                    ]),
                    now: Date(timeIntervalSince1970: 3)
                )
            )
        }
        await access.waitForDetailLoad()

        _ = try await store.acquireDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )
        await access.completeDetailLoad()

        await #expect(throws: WorktreeAnnotationServiceError.staleSourceEpoch) {
            _ = try await delayedRefresh.value
        }
        #expect(await access.sourceCommitCount == 0)
    }

    @Test("replacement demand completes detail hydration while the earlier load is delayed")
    func replacementDemandCompletesDetailHydrationWhileEarlierLoadIsDelayed() async throws {
        let detail = try makeLocatedCommittedDetail()
        let access = ControllableDemandDetailLoadAccess(detail: detail)
        let store = WorktreeAnnotationServiceActor(repositoryAccess: access)

        let delayedAcquire = Task {
            try await store.acquireDemand(
                worktreeID: detail.session.worktreeID,
                contextID: "pane-a",
                surface: .file,
                sessionID: detail.session.id
            )
        }
        await access.waitForFirstDetailLoad()

        _ = try await store.acquireDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )

        #expect(await access.detailLoadCount == 2)

        await access.completeFirstDetailLoad()
        await #expect(throws: WorktreeAnnotationServiceError.staleSourceEpoch) {
            _ = try await delayedAcquire.value
        }
        await store.releaseDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )
    }

    @Test("surviving context hydrates detail when the initiating context releases")
    func survivingContextHydratesDetailWhenInitiatingContextReleases() async throws {
        let detail = try makeLocatedCommittedDetail()
        let access = ControllableDemandDetailLoadAccess(detail: detail)
        let store = WorktreeAnnotationServiceActor(repositoryAccess: access)

        let initiatingAcquire = Task {
            try await store.acquireDemand(
                worktreeID: detail.session.worktreeID,
                contextID: "pane-a",
                surface: .file,
                sessionID: detail.session.id
            )
        }
        await access.waitForFirstDetailLoad()

        _ = try await store.acquireDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-b",
            surface: .file,
            sessionID: detail.session.id
        )
        await store.releaseDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )
        await access.completeFirstDetailLoad()

        await #expect(throws: WorktreeAnnotationServiceError.staleSourceEpoch) {
            _ = try await initiatingAcquire.value
        }
        #expect(await access.detailLoadCount == 2)
        await store.releaseDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-b",
            surface: .file,
            sessionID: detail.session.id
        )
    }

    @Test("durable source continuity returns only after repository commit")
    func durableSourceContinuityReturnsOnlyAfterRepositoryCommit() async throws {
        let initialDetail = try makeLocatedCommittedDetail()
        let committedDetail = makeSourceUpdatedDetail(
            from: initialDetail,
            fingerprint: makeSourceFingerprint(identity: "source-current")
        )
        let access = ControllableSourceRefreshAnnotationAccess(
            initialDetail: initialDetail,
            committedDetail: committedDetail
        )
        let store = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let demandGeneration = try await store.acquireDemand(
            worktreeID: initialDetail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: initialDetail.session.id
        )
        let refreshSnapshot = try await store.sourceRefreshSnapshot(
            sessionID: initialDetail.session.id
        )

        let refresh = Task {
            try await store.refreshSource(
                .init(
                    contextID: "pane-a",
                    demandGeneration: demandGeneration,
                    sessionID: initialDetail.session.id,
                    surface: .file,
                    sourceEpoch: 1,
                    expectedSnapshot: refreshSnapshot,
                    currentFingerprint: makeSourceFingerprint(identity: "source-current"),
                    material: .available([
                        .init(
                            path: "Sources/Feature.swift",
                            sourceRole: .file,
                            sourceIdentity: "source-current",
                            body: "before\nselected line\nafter\n"
                        )
                    ]),
                    now: Date(timeIntervalSince1970: 3)
                )
            )
        }
        await access.waitForSourceCommit()

        #expect(await access.sourceCommitCount == 0)
        await access.completeSourceCommit()
        let returnedDetail = try await refresh.value
        #expect(returnedDetail == committedDetail)
        #expect(await access.sourceCommitCount == 1)
    }
}

private enum WorktreeAnnotationSourceRefreshTestError: Error {
    case unexpectedOperation
}

private actor ControllableSourceRefreshAnnotationAccess: WorktreeAnnotationRepositoryAccess {
    let initialDetail: WorktreeAnnotationSessionDetail
    let committedDetail: WorktreeAnnotationSessionDetail
    private(set) var sourceCommitCount = 0
    private var commitContinuation: CheckedContinuation<Void, Never>?
    private var commitStartedContinuation: CheckedContinuation<Void, Never>?
    private var didStartCommit = false

    init(
        initialDetail: WorktreeAnnotationSessionDetail,
        committedDetail: WorktreeAnnotationSessionDetail
    ) {
        self.initialDetail = initialDetail
        self.committedDetail = committedDetail
    }

    func waitForSourceCommit() async {
        if didStartCommit { return }
        await withCheckedContinuation { commitStartedContinuation = $0 }
    }

    func completeSourceCommit() {
        commitContinuation?.resume()
        commitContinuation = nil
    }

    func discoverSessions(worktreeID _: String) async throws -> [WorktreeAnnotationSession] {
        [initialDetail.session]
    }

    func fetchSessionDetail(sessionID _: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        initialDetail
    }

    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        return .catalog(initialDetail)
    }

    func setSourceRelationship(_ props: WorktreeAnnotationSQLiteRepository.SetSourceRelationshipProps)
        async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        didStartCommit = true
        commitStartedContinuation?.resume()
        commitStartedContinuation = nil
        await withCheckedContinuation { commitContinuation = $0 }
        sourceCommitCount += 1
        return .control(committedDetail, reason: .discovery)
    }

    func fetchUnacknowledgedRecoveryProvenance() async throws -> WorktreeAnnotationRecoveryProvenance? { nil }

    func acknowledgeRecoveryProvenance(
        id _: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt _: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        throw WorktreeAnnotationRepositoryError.notFound
    }
}

private actor ControllableDemandDetailLoadAccess: WorktreeAnnotationRepositoryAccess {
    let detail: WorktreeAnnotationSessionDetail
    private(set) var detailLoadCount = 0
    private var firstDetailLoadContinuation: CheckedContinuation<Void, Never>?
    private var firstDetailLoadStartedContinuation: CheckedContinuation<Void, Never>?
    private var didStartFirstDetailLoad = false

    init(detail: WorktreeAnnotationSessionDetail) {
        self.detail = detail
    }

    func waitForFirstDetailLoad() async {
        if didStartFirstDetailLoad { return }
        await withCheckedContinuation { firstDetailLoadStartedContinuation = $0 }
    }

    func completeFirstDetailLoad() {
        firstDetailLoadContinuation?.resume()
        firstDetailLoadContinuation = nil
    }

    func discoverSessions(worktreeID _: String) async throws -> [WorktreeAnnotationSession] {
        [detail.session]
    }

    func fetchSessionDetail(sessionID _: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        detailLoadCount += 1
        guard detailLoadCount == 1 else { return detail }
        didStartFirstDetailLoad = true
        firstDetailLoadStartedContinuation?.resume()
        firstDetailLoadStartedContinuation = nil
        await withCheckedContinuation { firstDetailLoadContinuation = $0 }
        return detail
    }

    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        throw WorktreeAnnotationSourceRefreshTestError.unexpectedOperation
    }

    func fetchUnacknowledgedRecoveryProvenance() async throws -> WorktreeAnnotationRecoveryProvenance? { nil }

    func acknowledgeRecoveryProvenance(
        id _: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt _: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        throw WorktreeAnnotationRepositoryError.notFound
    }
}

private actor ControllableSourceRefreshDetailLoadAccess: WorktreeAnnotationRepositoryAccess {
    let detail: WorktreeAnnotationSessionDetail
    private(set) var sourceCommitCount = 0
    private var detailLoadCount = 0
    private var detailLoadContinuation: CheckedContinuation<Void, Never>?
    private var detailLoadStartedContinuation: CheckedContinuation<Void, Never>?
    private var didStartDetailLoad = false

    init(detail: WorktreeAnnotationSessionDetail) {
        self.detail = detail
    }

    func waitForDetailLoad() async {
        if didStartDetailLoad { return }
        await withCheckedContinuation { detailLoadStartedContinuation = $0 }
    }

    func completeDetailLoad() {
        detailLoadContinuation?.resume()
        detailLoadContinuation = nil
    }

    func discoverSessions(worktreeID _: String) async throws -> [WorktreeAnnotationSession] {
        [detail.session]
    }

    func fetchSessionDetail(sessionID _: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        detailLoadCount += 1
        guard detailLoadCount == 3 else { return detail }
        didStartDetailLoad = true
        detailLoadStartedContinuation?.resume()
        detailLoadStartedContinuation = nil
        await withCheckedContinuation { detailLoadContinuation = $0 }
        return detail
    }

    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        throw WorktreeAnnotationSourceRefreshTestError.unexpectedOperation
    }

    func setSourceRelationship(_ props: WorktreeAnnotationSQLiteRepository.SetSourceRelationshipProps)
        async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        sourceCommitCount += 1
        return .control(detail, reason: .discovery)
    }

    func fetchUnacknowledgedRecoveryProvenance() async throws -> WorktreeAnnotationRecoveryProvenance? { nil }

    func acknowledgeRecoveryProvenance(
        id _: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt _: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        throw WorktreeAnnotationRepositoryError.notFound
    }
}
