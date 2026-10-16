import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Worktree annotation Store")
struct WorktreeAnnotationStoreTests {
    @Test("coalesced observer delivery merges the displaced session revision")
    func coalescedObserverDeliveryMergesDisplacedSessionRevision() async throws {
        let recorder = AnnotationServiceLifecycleTraceRecorder()
        let service = WorktreeAnnotationServiceActor(
            repositoryAccess: ImmediateWorktreeAnnotationAccess(detail: try makeCommittedDetail()),
            lifecycleTraceRecorder: recorder
        )
        let observer = await service.registerChangeObserver(worktreeID: "worktree-1")
        var iterator = observer.stream.makeAsyncIterator()
        let predecessorID = String(repeating: "a", count: 64)
        let successorID = String(repeating: "b", count: 64)
        let predecessorSessionID = WorktreeAnnotationSessionID.generate()
        let successorSessionID = WorktreeAnnotationSessionID.generate()

        await service.applyCommittedChange(
            .content(
                sessionChanges: [
                    .init(
                        worktreeID: "worktree-1",
                        sessionID: predecessorSessionID,
                        semanticRevision: 2
                    )
                ]
            ),
            operationCorrelationID: predecessorID
        )
        await service.applyCommittedChange(
            .content(
                sessionChanges: [
                    .init(
                        worktreeID: "worktree-1",
                        sessionID: successorSessionID,
                        semanticRevision: 3
                    )
                ]
            ),
            operationCorrelationID: successorID
        )

        let deliveredChange = try #require(await iterator.next())
        #expect(deliveredChange.operationCorrelationID == successorID)
        #expect(deliveredChange.sessionSemanticRevisionByID[predecessorSessionID] == 2)
        #expect(deliveredChange.sessionSemanticRevisionByID[successorSessionID] == 3)
        #expect(
            await recorder.snapshot().contains {
                $0.operationCorrelationID == predecessorID
                    && $0.stage == .notificationDeliveryTerminal
                    && $0.result == .stale
            }
        )
        await service.removeChangeObserver(token: observer.token)
    }

    @Test("committed mutation broadcasts one coalescible invalidation to every observer")
    func committedMutationBroadcastsToEveryObserver() async throws {
        let repository = try makeAnnotationRepository()
        let service = WorktreeAnnotationServiceActor(
            repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(repository: repository)
        )
        let observerA = await service.registerChangeObserver(worktreeID: "worktree-1")
        let observerB = await service.registerChangeObserver(worktreeID: "worktree-1")
        var iteratorA = observerA.stream.makeAsyncIterator()
        var iteratorB = observerB.stream.makeAsyncIterator()

        _ = try await service.createRootDraft(
            makeCreateRootDraftProps(),
            ownerGeneration: "worker-a"
        )

        let changeA = try #require(await iteratorA.next())
        let changeB = try #require(await iteratorB.next())
        #expect(changeA.worktreeID == "worktree-1")
        #expect(changeA.disposition == .catalog)
        #expect(changeA.operationCorrelationID.count == 64)
        #expect(changeB.worktreeID == changeA.worktreeID)
        #expect(changeB.disposition == .catalog)
        #expect(changeB.operationCorrelationID == changeA.operationCorrelationID)
        await service.removeChangeObserver(token: observerA.token)
        await service.removeChangeObserver(token: observerB.token)
        #expect(await service.changeObserverCount() == 0)
    }

    @Test("located root admission returns and durably stores its exact source origin")
    func locatedRootAdmissionReturnsDurableSourceOrigin() async throws {
        let repository = try makeAnnotationRepository()
        let store = WorktreeAnnotationServiceActor(
            repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(repository: repository)
        )

        let detail = try await store.createRootDraft(
            makeLocatedRootDraftProps(),
            ownerGeneration: "worker-a",
            placementContext: .init(contextID: "pane-a", surface: .file)
        )
        let durableDetail = try repository.fetchSessionDetail(sessionID: detail.session.id)
        guard case .located(let origin) = durableDetail.threads.first?.thread.origin else {
            Issue.record("Expected a durable located source origin")
            return
        }
        #expect(origin.repositoryRelativePath == "Sources/Feature.swift")
        #expect(origin.startLine == 2)
        #expect(origin.endLine == 2)
        #expect(origin.sourceIdentity == "source-original")
    }

    @Test("Store binds edit ownership to product generation and disconnect enables fenced reclaim")
    func productGenerationEditOwnershipAndReclaim() async throws {
        let repository = try makeAnnotationRepository()
        let store = WorktreeAnnotationServiceActor(
            repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(repository: repository)
        )
        var detail = try await store.createRootDraft(
            makeCreateRootDraftProps(),
            ownerGeneration: "worker-a"
        )
        let message = try #require(detail.threads.first?.messages.first)
        let originalDraft = try #require(message.draft)
        let acquireProps = WorktreeAnnotationEditTokenCommandProps(
            sessionID: detail.session.id,
            messageID: message.id,
            editToken: "editor-reclaimed",
            expectedMessageRevision: message.semanticRevision,
            expectedDraftRevision: originalDraft.draftRevision,
            now: Date(timeIntervalSince1970: 3)
        )

        await #expect(throws: WorktreeAnnotationRepositoryError.editTokenConflict) {
            try await store.acquireEditToken(acquireProps, ownerGeneration: "worker-b")
        }

        await store.invalidateEditOwnerGeneration("worker-a")
        detail = try await store.acquireEditToken(acquireProps, ownerGeneration: "worker-b")
        let reclaimedDraft = try #require(detail.threads.first?.messages.first?.draft)
        #expect(reclaimedDraft.body == originalDraft.body)
        #expect(reclaimedDraft.draftRevision == originalDraft.draftRevision + 1)

        await #expect(throws: WorktreeAnnotationRepositoryError.editTokenConflict) {
            try await store.flushDraft(
                .init(
                    sessionID: detail.session.id,
                    messageID: message.id,
                    editToken: "editor-1",
                    expectedMessageRevision: try #require(detail.threads.first?.messages.first?.semanticRevision),
                    expectedDraftRevision: originalDraft.draftRevision,
                    body: "delayed old writer",
                    now: Date(timeIntervalSince1970: 4)
                ),
                ownerGeneration: "worker-a"
            )
        }

        detail = try await store.releaseEditToken(
            .init(
                sessionID: detail.session.id,
                messageID: message.id,
                editToken: "editor-reclaimed",
                expectedMessageRevision: try #require(detail.threads.first?.messages.first?.semanticRevision),
                expectedDraftRevision: reclaimedDraft.draftRevision,
                now: Date(timeIntervalSince1970: 5)
            ),
            ownerGeneration: "worker-b"
        )
        #expect(detail.threads.first?.messages.first?.draft?.activeEditToken == nil)
    }

    @Test("committed repository detail and invalidation appear only after mutation returns")
    func committedDetailAndInvalidationAppearAfterMutationReturns() async throws {
        let access = ControllableWorktreeAnnotationAccess()
        let traceRecorder = AnnotationServiceLifecycleTraceRecorder()
        let store = WorktreeAnnotationServiceActor(
            repositoryAccess: access,
            lifecycleTraceRecorder: traceRecorder
        )
        let props = makeCreateRootDraftProps()
        let retiredObserver = await store.registerChangeObserver(worktreeID: "worktree-1")
        var retiredIterator = retiredObserver.stream.makeAsyncIterator()
        let committedObserver = await store.registerChangeObserver(worktreeID: "worktree-1")
        var committedIterator = committedObserver.stream.makeAsyncIterator()

        let mutation = Task { try await store.createRootDraft(props) }
        await access.waitForCreateRootDraft()
        let startedEvents = await traceRecorder.snapshot()
        #expect(startedEvents.map(\.stage) == [.nativeWorkStarted])
        await store.removeChangeObserver(token: retiredObserver.token)
        #expect(await retiredIterator.next() == nil)

        let committedDetail = try makeCommittedDetail()
        await access.completeCreateRootDraft(with: .success(committedDetail))
        let returnedDetail = try await mutation.value

        #expect(returnedDetail == committedDetail)
        guard let committedChange = await committedIterator.next() else {
            Issue.record("Expected correlated committed invalidation")
            return
        }
        #expect(committedChange.worktreeID == "worktree-1")
        #expect(committedChange.disposition == .catalog)
        #expect(committedChange.operationCorrelationID == startedEvents.first?.operationCorrelationID)
        #expect(
            await traceRecorder.snapshot().map(\.stage)
                == [.nativeWorkStarted, .nativeWorkTerminal, .notificationDeliveryStarted]
        )
        await store.removeChangeObserver(token: committedObserver.token)
    }

    @Test("failed repository mutation emits no invalidation")
    func failedMutationEmitsNoInvalidation() async throws {
        let access = ControllableWorktreeAnnotationAccess()
        let store = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let observer = await store.registerChangeObserver(worktreeID: "worktree-1")
        var iterator = observer.stream.makeAsyncIterator()

        let mutation = Task { try await store.createRootDraft(makeCreateRootDraftProps()) }
        await access.waitForCreateRootDraft()
        await access.completeCreateRootDraft(with: .failure(TestAnnotationAccessError.writeFailed))

        await #expect(throws: TestAnnotationAccessError.writeFailed) {
            try await mutation.value
        }
        await store.removeChangeObserver(token: observer.token)
        #expect(await iterator.next() == nil)
    }

    @Test("each demand validates durable detail and release performs no persistence")
    func eachDemandValidatesDurableDetailWithoutPersistence() async throws {
        let detail = try makeCommittedDetail()
        let access = ImmediateWorktreeAnnotationAccess(detail: detail)
        let store = WorktreeAnnotationServiceActor(repositoryAccess: access)

        _ = try await store.acquireDemand(
            worktreeID: "worktree-1",
            contextID: "pane-b",
            surface: .file,
            sessionID: detail.session.id
        )
        _ = try await store.acquireDemand(
            worktreeID: "worktree-1",
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )

        #expect(await access.detailLoadCount == 2)

        await store.releaseDemand(
            worktreeID: "worktree-1",
            contextID: "pane-b",
            surface: .file,
            sessionID: detail.session.id
        )
        await store.releaseDemand(
            worktreeID: "worktree-1",
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )

        #expect(await access.mutationCount == 0)

        _ = try await store.acquireDemand(
            worktreeID: "worktree-1",
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )
        #expect(await access.detailLoadCount == 3)
    }

    @Test("unacknowledged recovery witness blocks mutation until durable acknowledgement")
    func recoveryWitnessBlocksMutationUntilAcknowledgement() async throws {
        let witness = WorktreeAnnotationRecoveryProvenance(
            id: .generate(),
            recoveredAt: Date(timeIntervalSince1970: 10),
            quarantinedFilenames: ["local.sqlite.corrupt-1"],
            reason: "corrupt_database",
            acknowledgedAt: nil
        )
        let access = ImmediateWorktreeAnnotationAccess(detail: try makeCommittedDetail(), witness: witness)
        let store = WorktreeAnnotationServiceActor(repositoryAccess: access)
        let observer = await store.registerChangeObserver(worktreeID: "worktree-1")
        var iterator = observer.stream.makeAsyncIterator()

        await store.restoreRecoveryState()

        #expect(isCatalogChange(await iterator.next(), worktreeID: "worktree-1"))
        await #expect(throws: WorktreeAnnotationServiceError.recoveryAcknowledgementRequired) {
            try await store.createRootDraft(makeCreateRootDraftProps())
        }

        try await store.acknowledgeRecovery(at: Date(timeIntervalSince1970: 11))
        #expect(isRecoveryControlChange(await iterator.next(), worktreeID: "worktree-1"))
        _ = try await store.createRootDraft(makeCreateRootDraftProps())
        #expect(isCatalogChange(await iterator.next(), worktreeID: "worktree-1"))
        #expect(await access.mutationCount == 1)
        await store.removeChangeObserver(token: observer.token)
    }

    @Test("local quarantine writes a durable annotation witness before availability")
    func localQuarantineWritesWitnessBeforeAvailability() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "annotation-recovery-witness-\(UUIDv7.generate().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coreURL = root.appending(path: "core.sqlite")
        let localURL = root.appending(path: "local.sqlite")
        try Data("not sqlite".utf8).write(to: localURL)
        let datastore = WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: coreURL,
            localDatabaseURL: localURL,
            localDatabaseReplacementObserver: WorktreeAnnotationRecoveryWitnessWriter.write
        ).makeDatastore()

        guard case .prepared = await datastore.prepareDatabasesForBoot() else {
            Issue.record("Expected replacement database to become available")
            return
        }
        let adapter = WorktreeAnnotationSQLiteDatastoreAdapter(
            workspaceID: UUIDv7.generate(),
            datastore: datastore
        )
        let witness = try #require(try await adapter.fetchUnacknowledgedRecoveryProvenance())

        #expect(witness.reason == "corrupt_database")
        #expect(witness.quarantinedFilenames.count == 1)
        #expect(witness.quarantinedFilenames[0].contains("local.sqlite.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: witness.quarantinedFilenames[0]).path))
    }

    @Test("failed recovery witness callback keeps replacement local database unavailable")
    func failedRecoveryWitnessCallbackKeepsLocalDatabaseUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "annotation-recovery-callback-failure-\(UUIDv7.generate().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localURL = root.appending(path: "local.sqlite")
        try Data("not sqlite".utf8).write(to: localURL)
        let datastore = WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: root.appending(path: "core.sqlite"),
            localDatabaseURL: localURL,
            localDatabaseReplacementObserver: { _, _ in
                throw TestAnnotationAccessError.writeFailed
            }
        ).makeDatastore()

        guard case .prepared = await datastore.prepareDatabasesForBoot() else {
            Issue.record("Core preparation should remain available after local callback failure")
            return
        }
        let adapter = WorktreeAnnotationSQLiteDatastoreAdapter(
            workspaceID: UUIDv7.generate(),
            datastore: datastore
        )
        do {
            _ = try await adapter.fetchUnacknowledgedRecoveryProvenance()
            Issue.record("Replacement local repository must not publish after witness callback failure")
        } catch let failure as WorkspaceSQLiteDatastoreFailure {
            #expect(failure.description.contains("writeFailed"))
        }
    }

    @Test("real local SQLite restart restores demanded draft without Atom state")
    func localSQLiteRestartRestoresDraftWithoutAtomState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "annotation-restart-\(UUIDv7.generate().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coreURL = root.appending(path: "core.sqlite")
        let localURL = root.appending(path: "local.sqlite")
        let workspaceID = UUIDv7.generate()

        let firstDatastore = WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: coreURL,
            localDatabaseURL: localURL
        ).makeDatastore()
        guard case .prepared = await firstDatastore.prepareDatabasesForBoot() else {
            Issue.record("Expected first datastore preparation")
            return
        }
        let workspaceStore = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
            sqliteDatastore: firstDatastore,
            startsObserving: false
        )
        guard case .initializedDefaultWorkspace = await workspaceStore.loadCanonicalComposition() else {
            Issue.record("Expected first datastore to persist its default workspace")
            return
        }
        let firstStore = WorktreeAnnotationServiceActor(
            sqliteAdapter: .init(workspaceID: workspaceID, datastore: firstDatastore)
        )
        let committed = try await firstStore.createRootDraft(makeCreateRootDraftProps())

        let restartedDatastore = WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: coreURL,
            localDatabaseURL: localURL
        ).makeDatastore()
        let restartedPreparation = await restartedDatastore.prepareDatabasesForBoot()
        guard case .prepared = restartedPreparation else {
            Issue.record("Expected restarted datastore preparation, received \(restartedPreparation)")
            return
        }
        let restartedStore = WorktreeAnnotationServiceActor(
            sqliteAdapter: .init(workspaceID: workspaceID, datastore: restartedDatastore)
        )

        let restoredDetail = try await restartedStore.outputSessionDetail(sessionID: committed.session.id)
        #expect(
            restoredDetail.threads.first?.messages.first?.draft?.body == "Draft"
        )
    }

    @Test("semantic mutations return durable detail and output bytes stay repository-owned")
    func semanticMutationsReturnDurableDetailAndKeepOutputBytesRepositoryOwned() async throws {
        let repository = try makeAnnotationRepository()
        let access = RepositoryBackedWorktreeAnnotationAccess(repository: repository)
        let store = WorktreeAnnotationServiceActor(repositoryAccess: access)
        var detail = try await store.createRootDraft(makeLocatedRootDraftProps())
        let rootMessage = try #require(detail.threads.first?.messages.first)

        detail = try await store.flushDraft(
            .init(
                sessionID: detail.session.id,
                messageID: rootMessage.id,
                editToken: "editor-1",
                expectedMessageRevision: rootMessage.semanticRevision,
                expectedDraftRevision: 0,
                body: "Updated draft",
                now: Date(timeIntervalSince1970: 3)
            )
        ).detail
        let updatedRoot = try #require(detail.threads.first?.messages.first)
        detail = try await store.saveDraft(
            .init(
                sessionID: detail.session.id,
                messageID: updatedRoot.id,
                editToken: "editor-1",
                expectedMessageRevision: updatedRoot.semanticRevision,
                expectedDraftRevision: try #require(updatedRoot.draft?.draftRevision),
                now: Date(timeIntervalSince1970: 4)
            )
        )
        let savedRoot = try #require(detail.threads.first?.messages.first)
        let threadID = try #require(detail.threads.first?.thread.id)
        let savedRevision = try #require(savedRoot.savedRevision)
        let attemptID = WorktreeAnnotationOutputAttemptID.generate()
        let snapshot = try WorktreeAnnotationBatchProjector.makeSnapshot(
            .init(
                batchID: attemptID,
                createdAt: Date(timeIntervalSince1970: 5),
                sessionDetail: detail,
                selectedMessages: [.init(messageID: savedRoot.id, expectedSavedRevision: savedRevision)],
                placementsByThreadID: [
                    threadID: .init(
                        placement: .exact,
                        currentPath: "Sources/Feature.swift",
                        currentStartLine: 2,
                        currentEndLine: 2,
                        currentSourceIdentity: "source-original"
                    )
                ],
                sessionLabel: "Current review",
                worktreeLabel: "agent-studio.review-comments",
                comparisonLabel: nil
            )
        )
        let markdownPresentation = WorktreeAnnotationMarkdownPresentationContext(
            worktreeLabel: "agent-studio.review-comments",
            comparisonLabel: nil
        )
        let exactBytes = WorktreeAnnotationBatchProjector.markdownData(
            for: snapshot,
            presentation: markdownPresentation
        )
        let preparedCommit = try await access.prepareOutput(
            .init(
                attemptID: attemptID,
                sessionID: detail.session.id,
                outputKind: .clipboardMarkdown,
                formatVersion: snapshot.formatVersion,
                contentType: "text/markdown; charset=utf-8",
                canonicalSnapshot: snapshot,
                exactBytes: exactBytes,
                markdownPresentation: markdownPresentation,
                destinationPath: nil,
                repeatedFromAttemptID: nil,
                selectedMessages: [.init(messageID: savedRoot.id, expectedSavedRevision: savedRevision)],
                now: Date(timeIntervalSince1970: 5)
            )
        )
        let prepared = preparedCommit.canonicalResult

        #expect(prepared.attempt.exactBytes == exactBytes)
        let durableDetail = try repository.fetchSessionDetail(sessionID: detail.session.id)
        #expect(durableDetail.threads.first?.messages.first?.status == .editable)
        #expect(try repository.inspectOutputAttempt(attemptID: attemptID).attempt.exactBytes == exactBytes)
    }

    @Test("detail hydration failure returns the repository error without poisoning later reads")
    func detailHydrationFailureDoesNotPoisonServiceAvailability() async throws {
        let store = WorktreeAnnotationServiceActor(
            repositoryAccess: FailingHydrationWorktreeAnnotationAccess()
        )

        await #expect(throws: WorktreeAnnotationRepositoryError.invalidState) {
            try await store.acquireDemand(
                worktreeID: "worktree-1",
                contextID: "pane-a",
                surface: .file,
                sessionID: WorktreeAnnotationSessionID.generate()
            )
        }
        #expect(try await store.discoverSessions(worktreeID: "worktree-1").isEmpty)
    }

    @Test("source refresh fences are context scoped and stale epochs cannot overwrite durable state")
    func sourceRefreshFencesAreContextScopedAndRejectStaleEpochs() async throws {
        let repository = try makeAnnotationRepository()
        let store = WorktreeAnnotationServiceActor(
            repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(repository: repository)
        )
        let detail = try await store.createRootDraft(makeLocatedRootDraftProps())
        let paneADemandGeneration = try await store.acquireDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: detail.session.id
        )
        let paneARefreshSnapshot = try await store.sourceRefreshSnapshot(
            sessionID: detail.session.id
        )

        _ = try await store.refreshSource(
            .init(
                contextID: "pane-a",
                demandGeneration: paneADemandGeneration,
                sessionID: detail.session.id,
                surface: .file,
                sourceEpoch: 2,
                expectedSnapshot: paneARefreshSnapshot,
                currentFingerprint: makeSourceFingerprint(identity: "source-a"),
                material: storeSourceMaterial(
                    path: "Sources/Feature.swift",
                    sourceIdentity: "source-a"
                ),
                now: Date(timeIntervalSince1970: 3)
            )
        )
        let afterFirstRefresh = try repository.fetchSessionDetail(sessionID: detail.session.id)
        let paneBDemandGeneration = try await store.acquireDemand(
            worktreeID: detail.session.worktreeID,
            contextID: "pane-b",
            surface: .file,
            sessionID: detail.session.id
        )
        let paneBRefreshSnapshot = try await store.sourceRefreshSnapshot(
            sessionID: detail.session.id
        )
        _ = try await store.refreshSource(
            .init(
                contextID: "pane-b",
                demandGeneration: paneBDemandGeneration,
                sessionID: detail.session.id,
                surface: .file,
                sourceEpoch: 1,
                expectedSnapshot: paneBRefreshSnapshot,
                currentFingerprint: makeSourceFingerprint(identity: "source-b"),
                material: storeSourceMaterial(
                    path: "Sources/RenamedFeature.swift",
                    sourceIdentity: "source-b"
                ),
                now: Date(timeIntervalSince1970: 4)
            )
        )

        let afterSecondRefresh = try repository.fetchSessionDetail(sessionID: detail.session.id)
        #expect(afterSecondRefresh.session.acceptedSourceFingerprint.fileSourceIdentity == "source-b")
        await #expect(throws: WorktreeAnnotationServiceError.staleSourceEpoch) {
            let staleEpochSnapshot = try await store.sourceRefreshSnapshot(
                sessionID: detail.session.id
            )
            _ = try await store.refreshSource(
                .init(
                    contextID: "pane-a",
                    demandGeneration: paneADemandGeneration,
                    sessionID: detail.session.id,
                    surface: .file,
                    sourceEpoch: 1,
                    expectedSnapshot: staleEpochSnapshot,
                    currentFingerprint: afterFirstRefresh.session.acceptedSourceFingerprint,
                    material: .unavailable,
                    now: Date(timeIntervalSince1970: 5)
                )
            )
        }
        #expect(try repository.fetchSessionDetail(sessionID: detail.session.id) == afterSecondRefresh)
    }

    @Test("source refresh rejects material captured from stale durable origins")
    func sourceRefreshRejectsStaleDurableOriginSnapshot() async throws {
        // Arrange
        let repository = try makeAnnotationRepository()
        let store = WorktreeAnnotationServiceActor(
            repositoryAccess: RepositoryBackedWorktreeAnnotationAccess(repository: repository)
        )
        let initialDetail = try await store.createRootDraft(makeLocatedRootDraftProps())
        let demandGeneration = try await store.acquireDemand(
            worktreeID: initialDetail.session.worktreeID,
            contextID: "pane-a",
            surface: .file,
            sessionID: initialDetail.session.id
        )
        let refreshSnapshot = try await store.sourceRefreshSnapshot(
            sessionID: initialDetail.session.id
        )
        let changedDetail = try await store.setSourceRelationship(
            .init(
                sessionID: initialDetail.session.id,
                relationship: .applicable,
                sourceFingerprint: makeSourceFingerprint(identity: "source-changed-during-capture"),
                expectedSessionRevision: initialDetail.session.semanticRevision,
                now: Date(timeIntervalSince1970: 3)
            )
        )

        // Act / Assert
        await #expect(throws: WorktreeAnnotationServiceError.staleSourceEpoch) {
            _ = try await store.refreshSource(
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
                    now: Date(timeIntervalSince1970: 4)
                )
            )
        }
        #expect(
            try repository.fetchSessionDetail(sessionID: initialDetail.session.id)
                .session.acceptedSourceFingerprint == changedDetail.session.acceptedSourceFingerprint
        )
    }

}

private func storeSourceMaterial(
    path: String,
    sourceIdentity: String
) -> WorktreeAnnotationSourceMaterial {
    .available([
        .init(
            path: path,
            sourceRole: .file,
            sourceIdentity: sourceIdentity,
            body: "before\nselected line\nafter\n"
        )
    ])
}

private enum TestAnnotationAccessError: Error {
    case writeFailed
    case unexpectedOperation
}

extension WorktreeAnnotationRepositoryAccess {
    func flushDraft(_ props: WorktreeAnnotationSQLiteRepository.FlushDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    {
        _ = props
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func saveDraft(_ props: WorktreeAnnotationSQLiteRepository.SaveDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func revertDraft(_ props: WorktreeAnnotationSQLiteRepository.RevertDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    {
        _ = props
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func createReplyDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateReplyDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func setThreadResolution(_ props: WorktreeAnnotationSQLiteRepository.SetThreadResolutionProps)
        async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func setSessionLifecycle(_ props: WorktreeAnnotationSQLiteRepository.SetSessionLifecycleProps)
        async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func setSourceRelationship(_ props: WorktreeAnnotationSQLiteRepository.SetSourceRelationshipProps)
        async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func prepareOutput(_ props: WorktreeAnnotationSQLiteRepository.PrepareOutputProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    {
        _ = props
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func inspectOutputAttempt(attemptID: WorktreeAnnotationOutputAttemptID) async throws
        -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    {
        _ = attemptID
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func cancelOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        _ = (attemptID, now)
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func finalizeOutputAttempt(
        attemptID: WorktreeAnnotationOutputAttemptID,
        eventKind: WorktreeAnnotationOutputEventKind,
        destinationPath: String?,
        now: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        _ = (attemptID, eventKind, destinationPath, now)
        throw TestAnnotationAccessError.unexpectedOperation
    }

    func markPreparedOutputAttemptsUnknown(now: Date) async throws
        -> WorktreeAnnotationCommittedMutation<Int>
    {
        _ = now
        throw TestAnnotationAccessError.unexpectedOperation
    }
}

private actor ControllableWorktreeAnnotationAccess: WorktreeAnnotationRepositoryAccess {
    private var createContinuation:
        CheckedContinuation<WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>, any Error>?
    private var createStartedContinuation: CheckedContinuation<Void, Never>?
    private var didStartCreate = false

    func waitForCreateRootDraft() async {
        if didStartCreate { return }
        await withCheckedContinuation { createStartedContinuation = $0 }
    }

    func completeCreateRootDraft(with result: Result<WorktreeAnnotationSessionDetail, any Error>) {
        createContinuation?.resume(with: result.map { .catalog($0) })
        createContinuation = nil
    }

    func discoverSessions(worktreeID _: String) async throws -> [WorktreeAnnotationSession] { [] }

    func fetchSessionDetail(sessionID _: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        throw WorktreeAnnotationRepositoryError.notFound
    }

    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        didStartCreate = true
        createStartedContinuation?.resume()
        createStartedContinuation = nil
        return try await withCheckedThrowingContinuation { createContinuation = $0 }
    }

    func fetchUnacknowledgedRecoveryProvenance() async throws -> WorktreeAnnotationRecoveryProvenance? { nil }

    func acknowledgeRecoveryProvenance(
        id _: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt _: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        throw WorktreeAnnotationRepositoryError.notFound
    }
}

private actor ImmediateWorktreeAnnotationAccess: WorktreeAnnotationRepositoryAccess {
    let detail: WorktreeAnnotationSessionDetail
    let witness: WorktreeAnnotationRecoveryProvenance?
    private(set) var detailLoadCount = 0
    private(set) var mutationCount = 0

    init(detail: WorktreeAnnotationSessionDetail, witness: WorktreeAnnotationRecoveryProvenance? = nil) {
        self.detail = detail
        self.witness = witness
    }

    func discoverSessions(worktreeID _: String) async throws -> [WorktreeAnnotationSession] { [detail.session] }

    func fetchSessionDetail(sessionID _: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        detailLoadCount += 1
        return detail
    }

    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        mutationCount += 1
        return .catalog(detail)
    }

    func fetchUnacknowledgedRecoveryProvenance() async throws -> WorktreeAnnotationRecoveryProvenance? {
        witness
    }

    func acknowledgeRecoveryProvenance(
        id: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        guard let witness, witness.id == id else { throw WorktreeAnnotationRepositoryError.notFound }
        return WorktreeAnnotationRecoveryProvenance(
            id: witness.id,
            recoveredAt: witness.recoveredAt,
            quarantinedFilenames: witness.quarantinedFilenames,
            reason: witness.reason,
            acknowledgedAt: acknowledgedAt
        )
    }
}

private actor FailingHydrationWorktreeAnnotationAccess: WorktreeAnnotationRepositoryAccess {
    func discoverSessions(worktreeID _: String) async throws -> [WorktreeAnnotationSession] { [] }

    func fetchSessionDetail(sessionID _: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func createRootDraft(_ props: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        _ = props
        throw WorktreeAnnotationRepositoryError.invalidState
    }

    func fetchUnacknowledgedRecoveryProvenance() async throws
        -> WorktreeAnnotationRecoveryProvenance?
    {
        nil
    }

    func acknowledgeRecoveryProvenance(
        id _: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt _: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        throw WorktreeAnnotationRepositoryError.notFound
    }
}

private actor AnnotationServiceLifecycleTraceRecorder: BridgeProductMetadataLifecycleTraceRecording {
    private var events: [BridgeAnnotationLifecycleTraceEvent] = []

    func record(_ event: BridgeAnnotationLifecycleTraceEvent) {
        events.append(event)
    }

    func record(_: BridgeProductMetadataLifecycleTraceEvent) {}
    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) {}

    func snapshot() -> [BridgeAnnotationLifecycleTraceEvent] { events }
}

private func isCatalogChange(
    _ change: WorktreeAnnotationChange?,
    worktreeID: String
) -> Bool {
    change?.worktreeID == worktreeID
        && change?.disposition == .catalog
        && change?.operationCorrelationID.count == 64
}

private func isRecoveryControlChange(
    _ change: WorktreeAnnotationChange?,
    worktreeID: String
) -> Bool {
    change?.worktreeID == worktreeID
        && change?.disposition == .control(.recovery)
        && change?.operationCorrelationID.count == 64
}
