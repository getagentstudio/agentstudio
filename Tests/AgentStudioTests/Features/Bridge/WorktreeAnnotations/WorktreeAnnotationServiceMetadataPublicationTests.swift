import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Worktree annotation service metadata publication")
struct WorktreeAnnotationServiceMetadataPublicationTests {
    @Test("three unconsumed session invalidations coalesce as a union of ranges")
    func invalidationBufferPreservesEveryRange() async throws {
        let worktreeID = "worktree-invalidation-union"
        let access = MetadataPublicationRepositoryAccess(
            catalogCapture: .init(worktreeID: worktreeID, sessions: [], threads: [], messages: [])
        )
        let service = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let observer = await service.registerCatalogInvalidationObserver(worktreeID: worktreeID)
        let sessionIDs = (0..<3).map { _ in WorktreeAnnotationSessionID.generate() }

        for sessionID in sessionIDs {
            await service.emitCommittedCatalogInvalidation(
                .content(sessionChanges: [
                    .init(worktreeID: worktreeID, sessionID: sessionID, semanticRevision: 0)
                ])
            )
        }

        var iterator = observer.stream.makeAsyncIterator()
        let invalidation = try #require(await iterator.next())
        #expect(invalidation.ranges == Set(sessionIDs.map(WorktreeAnnotationCatalogRange.session)))
        await service.removeCatalogInvalidationObserver(token: observer.token)
    }

    @Test("a committed session change emits its range before the caller returns")
    func committedChangeEmitsSessionRange() async throws {
        let detail = try makeCommittedDetail()
        let access = MetadataPublicationRepositoryAccess(
            catalogCapture: .init(worktreeID: "worktree-1", sessions: [], threads: [], messages: [])
        )
        await access.enqueueMutation(.content(detail))
        let service = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let observer = await service.registerCatalogInvalidationObserver(worktreeID: detail.session.worktreeID)
        var iterator = observer.stream.makeAsyncIterator()

        _ = try await service.createRootDraft(makeCreateRootDraftProps())

        let invalidation = try #require(await iterator.next())
        #expect(invalidation.ranges == [.session(detail.session.id)])
        await service.removeCatalogInvalidationObserver(token: observer.token)
    }

    @Test("an unknown mutation outcome conservatively invalidates the observed worktree")
    func unknownOutcomeEmitsWorktreeRange() async throws {
        let access = MetadataPublicationRepositoryAccess(
            catalogCapture: .init(worktreeID: "worktree-1", sessions: [], threads: [], messages: [])
        )
        await access.failNextMutation()
        let service = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let observer = await service.registerCatalogInvalidationObserver(worktreeID: "worktree-1")
        var iterator = observer.stream.makeAsyncIterator()

        await #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            _ = try await service.createRootDraft(makeCreateRootDraftProps())
        }

        let invalidation = try #require(await iterator.next())
        #expect(invalidation.ranges == [.worktree])
        await service.removeCatalogInvalidationObserver(token: observer.token)
    }

    @Test("cancellation after the repository commits cannot skip its invalidation")
    func cancellationAfterCommitStillEmitsRange() async throws {
        let detail = try makeCommittedDetail()
        let access = MetadataPublicationRepositoryAccess(
            catalogCapture: .init(worktreeID: "worktree-1", sessions: [], threads: [], messages: [])
        )
        await access.enqueueMutation(.content(detail))
        let committedReturn = HeldStep<Void>(
            "annotationRepositoryCommittedReturn",
            cancellation: .holdThroughCancellation
        )
        await access.holdNextMutationReturn(committedReturn)
        let service = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let observer = await service.registerCatalogInvalidationObserver(worktreeID: detail.session.worktreeID)
        var iterator = observer.stream.makeAsyncIterator()
        let mutation = Task { try await service.createRootDraft(makeCreateRootDraftProps()) }
        _ = try await committedReturn.firstArrival()

        mutation.cancel()
        try await committedReturn.cancellationObserved()
        committedReturn.release()
        _ = try await mutation.value

        let invalidation = try #require(await iterator.next())
        #expect(invalidation.ranges == [.session(detail.session.id)])
        await service.removeCatalogInvalidationObserver(token: observer.token)
    }

    @Test("content, control, and catalog mutations invalidate their complete committed ranges")
    func mutationClassesEmitTheirRanges() async throws {
        let detail = try makeCommittedDetail()
        let anotherSessionID = WorktreeAnnotationSessionID.generate()
        let sessionChange = detail.committedSessionChange
        let anotherSessionChange = WorktreeAnnotationCommittedSessionChange(
            worktreeID: detail.session.worktreeID,
            sessionID: anotherSessionID,
            semanticRevision: 0
        )
        let cases: [(WorktreeAnnotationCommittedChange, Set<WorktreeAnnotationCatalogRange>)] = [
            (.content(sessionChanges: [sessionChange]), [.session(detail.session.id)]),
            (
                .control(
                    worktreeIDs: [detail.session.worktreeID],
                    reason: .recovery,
                    sessionChanges: []
                ),
                [.worktree]
            ),
            (
                .catalog(
                    worktreeIDs: [detail.session.worktreeID],
                    sessionChanges: [sessionChange, anotherSessionChange]
                ),
                [.session(detail.session.id), .session(anotherSessionID)]
            ),
        ]
        for (change, expectedRanges) in cases {
            let access = MetadataPublicationRepositoryAccess(
                catalogCapture: .init(
                    worktreeID: detail.session.worktreeID,
                    sessions: [],
                    threads: [],
                    messages: []
                )
            )
            await access.enqueueMutation(.init(canonicalResult: detail, change: change))
            let service = WorktreeAnnotationServiceActor(repositoryAccess: access)
            let observer = await service.registerCatalogInvalidationObserver(
                worktreeID: detail.session.worktreeID
            )
            var iterator = observer.stream.makeAsyncIterator()
            _ = try await service.createRootDraft(makeCreateRootDraftProps())
            #expect(try #require(await iterator.next()).ranges == expectedRanges)
            await service.removeCatalogInvalidationObserver(token: observer.token)
        }
    }

    @Test("none preserves the canonical result without advancing generation or notifying")
    func nonePreservesCanonicalResultWithoutPublication() async throws {
        // Arrange
        let detail = try makeCommittedDetail()
        let access = MetadataPublicationRepositoryAccess(
            catalogCapture: .init(worktreeID: "worktree-1", sessions: [], threads: [], messages: [])
        )
        await access.enqueueMutation(.init(canonicalResult: detail, change: .noChange))
        let service = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let observer = await service.registerChangeObserver(worktreeID: "worktree-1")
        var iterator = observer.stream.makeAsyncIterator()
        let initialCapture = try await service.captureCatalog(worktreeID: "worktree-1")

        // Act
        let returnedDetail = try await service.createRootDraft(makeCreateRootDraftProps())
        let finalCapture = try await service.captureCatalog(worktreeID: "worktree-1")
        await service.removeChangeObserver(token: observer.token)

        // Assert
        #expect(returnedDetail == detail)
        #expect(finalCapture.applicationSourceGeneration == initialCapture.applicationSourceGeneration)
        #expect(await iterator.next() == nil)
    }

    @Test("buffered content changes retain the newest revision for every session")
    func bufferedContentChangesRetainNewestRevisionPerSession() async throws {
        // Arrange
        let detail = try makeCommittedDetail()
        let sessionA = WorktreeAnnotationSessionID.generate()
        let sessionB = WorktreeAnnotationSessionID.generate()
        let access = MetadataPublicationRepositoryAccess(
            catalogCapture: .init(worktreeID: "worktree-1", sessions: [], threads: [], messages: [])
        )
        for sessionChange in [
            WorktreeAnnotationCommittedSessionChange(
                worktreeID: "worktree-1",
                sessionID: sessionA,
                semanticRevision: 2
            ),
            WorktreeAnnotationCommittedSessionChange(
                worktreeID: "worktree-1",
                sessionID: sessionB,
                semanticRevision: 3
            ),
            WorktreeAnnotationCommittedSessionChange(
                worktreeID: "worktree-1",
                sessionID: sessionA,
                semanticRevision: 4
            ),
        ] {
            await access.enqueueMutation(
                .init(canonicalResult: detail, change: .content(sessionChanges: [sessionChange]))
            )
        }
        let service = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let observer = await service.registerChangeObserver(worktreeID: "worktree-1")
        var iterator = observer.stream.makeAsyncIterator()

        // Act
        _ = try await service.createRootDraft(makeCreateRootDraftProps())
        _ = try await service.createRootDraft(makeCreateRootDraftProps())
        _ = try await service.createRootDraft(makeCreateRootDraftProps())
        let change = try #require(await iterator.next())

        // Assert
        #expect(change.disposition == .content)
        #expect(change.applicationSourceGeneration == 3)
        #expect(change.sessionSemanticRevisionByID[sessionA] == 4)
        #expect(change.sessionSemanticRevisionByID[sessionB] == 3)
        await service.removeChangeObserver(token: observer.token)
    }

    @Test("control publication retains its reason and embedded session revision")
    func controlPublicationRetainsReasonAndSessionRevision() async throws {
        // Arrange
        let detail = try makeCommittedDetail()
        let sessionChange = WorktreeAnnotationCommittedSessionChange(
            worktreeID: "worktree-1",
            sessionID: detail.session.id,
            semanticRevision: detail.session.semanticRevision
        )
        let access = MetadataPublicationRepositoryAccess(
            catalogCapture: .init(worktreeID: "worktree-1", sessions: [], threads: [], messages: [])
        )
        await access.enqueueMutation(
            .init(
                canonicalResult: detail,
                change: .control(
                    worktreeIDs: ["worktree-1"],
                    reason: .recovery,
                    sessionChanges: [sessionChange]
                )
            )
        )
        let service = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let observer = await service.registerChangeObserver(worktreeID: "worktree-1")
        var iterator = observer.stream.makeAsyncIterator()

        // Act
        _ = try await service.createRootDraft(makeCreateRootDraftProps())
        let change = try #require(await iterator.next())

        // Assert
        #expect(change.disposition == .control(.recovery))
        #expect(change.sessionSemanticRevisionByID[detail.session.id] == detail.session.semanticRevision)
        await service.removeChangeObserver(token: observer.token)
    }

    @Test("catalog supersedes buffered content and publishes reassociation to both worktrees")
    func catalogSupersedesContentAndPublishesBothWorktrees() async throws {
        // Arrange
        let detail = try makeCommittedDetail()
        let previousWorktreeID = "worktree-previous"
        let currentWorktreeID = "worktree-current"
        let access = MetadataPublicationRepositoryAccess(
            catalogCapture: .init(worktreeID: currentWorktreeID, sessions: [], threads: [], messages: [])
        )
        await access.enqueueMutation(
            .init(
                canonicalResult: detail,
                change: .content(
                    sessionChanges: [
                        .init(
                            worktreeID: currentWorktreeID,
                            sessionID: detail.session.id,
                            semanticRevision: 2
                        )
                    ]
                )
            )
        )
        let association = WorktreeAnnotationSQLiteRepository.AssociationMutationResult(
            detail: detail,
            previousWorktreeID: previousWorktreeID,
            currentWorktreeID: currentWorktreeID
        )
        await access.setAssociationMutation(
            .init(
                canonicalResult: association,
                change: .catalog(
                    worktreeIDs: [previousWorktreeID, currentWorktreeID],
                    sessionChanges: [
                        .init(
                            worktreeID: currentWorktreeID,
                            sessionID: detail.session.id,
                            semanticRevision: 3
                        )
                    ]
                )
            )
        )
        let service = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let previousObserver = await service.registerChangeObserver(worktreeID: previousWorktreeID)
        let currentObserver = await service.registerChangeObserver(worktreeID: currentWorktreeID)
        var previousIterator = previousObserver.stream.makeAsyncIterator()
        var currentIterator = currentObserver.stream.makeAsyncIterator()

        // Act
        _ = try await service.createRootDraft(makeCreateRootDraftProps())
        let returnedAssociation = try await service.acceptCurrentAssociation(
            try makeAssociationProps(
                sessionID: detail.session.id,
                previousWorktreeID: previousWorktreeID,
                currentWorktreeID: currentWorktreeID
            )
        )
        let previousChange = try #require(await previousIterator.next())
        let currentChange = try #require(await currentIterator.next())

        // Assert
        #expect(returnedAssociation == association)
        #expect(previousChange.disposition == .catalog)
        #expect(currentChange.disposition == .catalog)
        #expect(currentChange.applicationSourceGeneration == 2)
        #expect(currentChange.sessionSemanticRevisionByID[detail.session.id] == 3)
        await service.removeChangeObserver(token: previousObserver.token)
        await service.removeChangeObserver(token: currentObserver.token)
    }

    @Test("observer before a racing catalog capture receives the invalidating change")
    func observerBeforeCatalogCaptureClosesMutationRace() async throws {
        // Arrange
        let detail = try makeCommittedDetail()
        let access = MetadataPublicationRepositoryAccess(
            catalogCapture: .init(worktreeID: "worktree-1", sessions: [], threads: [], messages: [])
        )
        await access.suspendCatalogCapture()
        await access.enqueueMutation(.catalog(detail))
        let service = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let observer = await service.registerChangeObserver(worktreeID: "worktree-1")
        var iterator = observer.stream.makeAsyncIterator()
        let captureTask = Task { try await service.captureCatalog(worktreeID: "worktree-1") }
        await access.waitForCatalogCapture()

        // Act
        _ = try await service.createRootDraft(makeCreateRootDraftProps())
        await access.resumeCatalogCapture()

        // Assert
        await #expect(throws: WorktreeAnnotationServiceError.staleSourceEpoch) {
            try await captureTask.value
        }
        #expect(try #require(await iterator.next()).disposition == .catalog)
        await service.removeChangeObserver(token: observer.token)
    }
}

private actor MetadataPublicationRepositoryAccess: WorktreeAnnotationRepositoryAccess {
    private let catalogCapture: WorktreeAnnotationCatalogCapture
    private var catalogCaptureContinuation: CheckedContinuation<Void, Never>?
    private var catalogCaptureStartedContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendCatalogCapture = false
    private var didStartCatalogCapture = false
    private var mutations: [WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>] = []
    private var shouldFailNextMutation = false
    private var heldNextMutationReturn: HeldStep<Void>?
    private var associationMutation:
        WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.AssociationMutationResult>?

    init(catalogCapture: WorktreeAnnotationCatalogCapture) {
        self.catalogCapture = catalogCapture
    }

    func enqueueMutation(_ mutation: WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>) {
        mutations.append(mutation)
    }

    func failNextMutation() { shouldFailNextMutation = true }

    func holdNextMutationReturn(_ heldReturn: HeldStep<Void>) {
        heldNextMutationReturn = heldReturn
    }

    func setAssociationMutation(
        _ mutation: WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.AssociationMutationResult>
    ) {
        associationMutation = mutation
    }

    func suspendCatalogCapture() { shouldSuspendCatalogCapture = true }

    func waitForCatalogCapture() async {
        if didStartCatalogCapture { return }
        await withCheckedContinuation { catalogCaptureStartedContinuation = $0 }
    }

    func resumeCatalogCapture() {
        catalogCaptureContinuation?.resume()
        catalogCaptureContinuation = nil
        shouldSuspendCatalogCapture = false
    }

    func discoverSessions(worktreeID _: String) async throws -> [WorktreeAnnotationSession] { [] }

    func fetchCatalogCapture(worktreeID _: String) async throws -> WorktreeAnnotationCatalogCapture {
        didStartCatalogCapture = true
        catalogCaptureStartedContinuation?.resume()
        catalogCaptureStartedContinuation = nil
        if shouldSuspendCatalogCapture {
            await withCheckedContinuation { catalogCaptureContinuation = $0 }
        }
        return catalogCapture
    }

    func fetchProjectionSnapshot(
        worktreeID _: String,
        demandedSessionIDs _: [WorktreeAnnotationSessionID]
    ) async throws -> WorktreeAnnotationRepositoryProjectionSnapshot {
        .init(details: [], sessions: [])
    }

    func fetchSessionDetail(sessionID _: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        throw WorktreeAnnotationRepositoryError.notFound
    }

    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        if shouldFailNextMutation {
            shouldFailNextMutation = false
            throw WorktreeAnnotationRepositoryError.invalidState
        }
        guard !mutations.isEmpty else { throw WorktreeAnnotationRepositoryError.invalidState }
        let committed = mutations.removeFirst()
        if let heldNextMutationReturn {
            self.heldNextMutationReturn = nil
            try await heldNextMutationReturn.arrive(())
        }
        return committed
    }

    func acceptCurrentAssociation(
        _ props: WorktreeAnnotationSQLiteRepository.AcceptCurrentAssociationProps
    ) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.AssociationMutationResult>
    {
        _ = props
        guard let associationMutation else { throw WorktreeAnnotationRepositoryError.invalidState }
        return associationMutation
    }

    func fetchUnacknowledgedRecoveryProvenance() async throws -> WorktreeAnnotationRecoveryProvenance? { nil }

    func acknowledgeRecoveryProvenance(
        id _: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt _: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        throw WorktreeAnnotationRepositoryError.notFound
    }
}

private func makeAssociationProps(
    sessionID: WorktreeAnnotationSessionID,
    previousWorktreeID: String,
    currentWorktreeID: String
) throws -> WorktreeAnnotationSQLiteRepository.AcceptCurrentAssociationProps {
    .init(
        sessionID: sessionID,
        expectedSessionRevision: 1,
        expectedRepositoryID: "repo-1",
        previousWorktreeID: previousWorktreeID,
        currentWorktreeID: currentWorktreeID,
        acceptedReviewedSubject: try .init(
            branchName: "main",
            reviewedHeadOID: String(repeating: "a", count: 40)
        ),
        acceptedSourceFingerprint: .init(
            repositoryID: "repo-1",
            worktreeID: currentWorktreeID,
            fileSourceIdentity: "source-current",
            reviewComparisonOrigin: nil
        ),
        now: Date(timeIntervalSince1970: 4)
    )
}
