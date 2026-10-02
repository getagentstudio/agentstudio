import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.BridgePaneControllerTests {
    @Test("hidden page mode defers initial Review build during File invalidation")
    func fileInvalidationDoesNotAdmitInitialReview() async {
        // Arrange
        // Hidden behavior: this controller receives no accepted page Review mode.
        let worktreeId = UUIDv7.generate()
        let provider = BridgeReviewSourceProviderFake(
            comparison: BridgeEndpointComparison(
                baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                changedFiles: []
            ),
            contentByHandleId: [:]
        )
        let controller = BridgePaneController(
            paneId: UUIDv7.generate(),
            state: BridgePaneState(
                panelKind: .fileViewer,
                source: .workspace(rootPath: "/tmp/worktree", baseline: .unstaged)
            ),
            appRootURL: testBridgeAppRootURL(),
            metadata: PaneMetadata(
                contentType: .diff,
                title: "Bridge Review",
                facets: PaneContextFacets(worktreeId: worktreeId)
            ),
            reviewSourceProvider: provider,
            initialPaneActivity: .foreground
        )
        defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

        // Act
        await controller.handleWorktreeProductInvalidation(
            .statusChanged(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                    branch: nil,
                    origin: nil
                )
            )
        )
        await waitForActiveReviewRefreshTaskToFinish(controller)

        // Assert
        #expect(controller.paneState.diff.packageMetadata == nil)
        #expect(await provider.recordedComparisonRequestsCount() == 0)
    }

    @Test("loaded-hidden presentation precedes cancellation-ignoring metadata producer drain")
    func loadedHiddenPresentationPrecedesCancellationIgnoringMetadataProducerDrain() async throws {
        // Arrange — the producer opening is already consumed by fixture installation, so the
        // foreground transition is the first queued metadata frame.
        let producerGate = RefreshAdmissionCancellationIgnoringProducerGate()
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            fileMetadataProducerGate: producerGate
        )
        let foregroundTransition = fixture.controller.applyBridgePaneActivity(.foreground)
        await foregroundTransition?.value
        guard
            case .panePresentation(let foregroundPresentation) =
                try await fixture.consumeNextMetadataFrame()
        else {
            Issue.record("Expected the foreground pane presentation")
            producerGate.releaseAll()
            await fixture.finish()
            return
        }
        #expect(foregroundPresentation.nativeActivity == .foreground)
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
        try await fixture.openFileMetadataSubscription()
        await producerGate.waitUntilStarted()

        // Act — native admission closes synchronously. The producer observes cancellation but
        // deliberately does not return, so producer drain remains held at a known boundary.
        let hiddenTransition = fixture.controller.applyBridgePaneActivity(.loadedHidden)
        await producerGate.waitUntilCancellationRequested()
        let presentationWasQueuedBeforeProducerRelease =
            await waitForRefreshAdmissionQueuedMetadataFrame(fixture)
        let presentationBeforeProducerRelease: BridgeProductPanePresentationFrame?
        if presentationWasQueuedBeforeProducerRelease {
            guard
                case .panePresentation(let presentation) =
                    try await fixture.consumeNextMetadataFrame()
            else {
                Issue.record("Expected loaded-hidden pane presentation before producer drain")
                producerGate.releaseAll()
                await hiddenTransition?.value
                await fixture.finish()
                return
            }
            presentationBeforeProducerRelease = presentation
        } else {
            presentationBeforeProducerRelease = nil
        }

        // Assert — the comm-worker activity boundary must not wait for native producer drain.
        #expect(presentationBeforeProducerRelease?.nativeActivity == .loadedHidden)

        // Cleanup also captures the current defective ordering without leaking the held task.
        producerGate.releaseAll()
        await hiddenTransition?.value
        if presentationBeforeProducerRelease == nil {
            guard
                case .panePresentation(let delayedPresentation) =
                    try await fixture.consumeNextMetadataFrame()
            else {
                Issue.record("Expected delayed loaded-hidden presentation after producer release")
                await fixture.finish()
                return
            }
            #expect(delayedPresentation.nativeActivity == .loadedHidden)
        }
        await fixture.finish()
    }

    @Test("loaded-hidden initial Review intake waits for one foreground load")
    func loadedHiddenInitialReviewIntakeWaitsForOneForegroundLoad() async throws {
        // Arrange
        let comparisonGate = BridgeComparisonGate()
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            comparisonGate: comparisonGate
        )
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.loadedHidden)

        // Act
        fixture.controller.scheduleInitialReviewPackageLoadIfPossible(reason: .initialIntake)

        // Assert — scheduling while hidden retains intent without starting provider or package work.
        #expect(fixture.controller.activeReviewRefreshTask == nil)
        #expect(await fixture.reviewProvider.recordedComparisonRequestsCount() == 0)
        #expect(fixture.controller.paneState.diff.packageMetadata == nil)

        // Act — native foreground is the only fact that may admit the retained intake.
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.foreground)
        await comparisonGate.waitForStartedComparisonCount(1)
        await comparisonGate.releaseAll()
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)

        // Assert
        #expect(await fixture.reviewProvider.recordedComparisonRequestsCount() == 1)
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-initial"])
        await fixture.finish()
    }

    @Test("initial Review failure resets Review through the product session and leaves File active")
    func initialReviewFailureResetsReviewThroughProductSessionAndLeavesFileActive() async throws {
        // Arrange
        let fixture = try await makeRefreshAdmissionIntegrationFixture()
        guard fixture.controller.pendingReviewPackageBuildReasons.contains(.initialIntake) else {
            Issue.record("Initial Review failure proof requires an admitted intake request before foreground")
            await fixture.finish()
            return
        }
        await fixture.reviewProvider.setComparison(
            BridgeEndpointComparison(
                baseEndpoint: fixture.baseEndpoint,
                headEndpoint: fixture.headEndpoint,
                changedFiles: [
                    makeBridgeEndpointChangedFile(
                        fileId: "invalid/review-item",
                        path: "Sources/App/InvalidReviewItem.swift",
                        sizeBytes: 100
                    )
                ]
            )
        )
        try await fixture.openFileMetadataSubscription()
        try await fixture.openReviewMetadataSubscription()

        // Act
        let foregroundTransition = fixture.controller.applyBridgePaneActivity(.foreground)
        await foregroundTransition?.value
        guard case .panePresentation = try await fixture.consumeNextMetadataFrame() else {
            Issue.record("Expected foreground pane presentation before Review load result")
            await fixture.finish()
            return
        }
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
        let resetFrame = try await fixture.consumeNextMetadataFrame()
        let fileComplete = try await sealRefreshAdmissionFileProofBatch(fixture)

        // Assert
        guard case .subscriptionReset(let reset) = resetFrame else {
            Issue.record("Expected the controller failure to reset Review")
            await fixture.finish()
            return
        }
        #expect(
            reset.identity.subscriptionIdentity.subscriptionId
                == "review-subscription-refresh-admission"
        )
        #expect(reset.reason == .staleSource)
        #expect(
            fileComplete.identity.subscriptionId
                == "file-subscription-refresh-admission"
        )
        #expect(
            await fixture.productInstallation.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-refresh-admission"
            ) == nil
        )
        #expect(
            await fixture.productInstallation.session.subscriptionSnapshot(
                subscriptionId: "file-subscription-refresh-admission"
            ) != nil
        )
        await fixture.finish()
    }

    @Test("repository invalidation retries an initial Review failure without a committed snapshot")
    func repositoryInvalidationRetriesInitialReviewFailureWithoutCommittedSnapshot() async throws {
        // Arrange — the first package reaches the real publication boundary but cannot reserve
        // its invalid item identity, leaving no committed snapshot to replay.
        let fixture = try await makeRefreshAdmissionIntegrationFixture()
        await fixture.reviewProvider.setComparison(
            BridgeEndpointComparison(
                baseEndpoint: fixture.baseEndpoint,
                headEndpoint: fixture.headEndpoint,
                changedFiles: [
                    makeBridgeEndpointChangedFile(
                        fileId: "invalid/review-item",
                        path: "Sources/App/InvalidReviewItem.swift",
                        sizeBytes: 100
                    )
                ]
            )
        )
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.foreground)
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
        #expect(fixture.controller.paneState.diff.status == .error)
        #expect(fixture.controller.paneState.diff.packageMetadata == nil)
        #expect(await fixture.reviewProvider.recordedComparisonRequestsCount() == 1)
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)

        // Act — a real repository change is fresh intake and should retry the initial path.
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Recovered.swift"],
                    batchSequence: 31
                )
            )
        )
        await waitForRefreshAdmissionIdle(fixture.controller)
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)

        // Assert
        #expect(await fixture.reviewProvider.recordedComparisonRequestsCount() == 2)
        #expect(fixture.controller.paneState.diff.status == .ready)
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"])
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact == nil)
        await fixture.finish()
    }

    @Test("current initial Review reservation failure resets Review and leaves File active")
    func currentInitialReviewReservationFailureResetsReviewAndLeavesFileActive() async throws {
        // Arrange
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            failsReviewReservation: true
        )
        try await fixture.openFileMetadataSubscription()
        try await fixture.openReviewMetadataSubscription()

        // Act
        let foregroundTransition = fixture.controller.applyBridgePaneActivity(.foreground)
        await foregroundTransition?.value
        guard case .panePresentation = try await fixture.consumeNextMetadataFrame() else {
            Issue.record("Expected foreground pane presentation before Review load result")
            await fixture.finish()
            return
        }
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
        let producerSnapshot = await fixture.productInstallation.session.producerSnapshot()
        #expect(producerSnapshot.queuedFrameCount == 1)
        guard producerSnapshot.queuedFrameCount == 1 else {
            await fixture.finish()
            return
        }
        let resetFrame = try await fixture.consumeNextMetadataFrame()
        let fileComplete = try await sealRefreshAdmissionFileProofBatch(fixture)

        // Assert
        #expect(fixture.controller.paneState.diff.status == .error)
        #expect(fixture.controller.paneState.diff.error == "loadFailed:publication")
        #expect(fixture.controller.paneState.diff.packageMetadata == nil)
        #expect(fixture.controller.activeReviewRefreshTask == nil)
        #expect(await fixture.reviewProvider.recordedComparisonRequestsCount() == 1)
        guard case .subscriptionReset(let reset) = resetFrame else {
            Issue.record("Expected current Review reservation failure to reset Review")
            await fixture.finish()
            return
        }
        #expect(
            reset.identity.subscriptionIdentity.subscriptionId
                == "review-subscription-refresh-admission"
        )
        #expect(reset.reason == .staleSource)
        #expect(
            fileComplete.identity.subscriptionId
                == "file-subscription-refresh-admission"
        )
        #expect(
            await fixture.productInstallation.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-refresh-admission"
            ) == nil
        )
        #expect(
            await fixture.productInstallation.session.subscriptionSnapshot(
                subscriptionId: "file-subscription-refresh-admission"
            ) != nil
        )
        await fixture.finish()
    }

    @Test("initial Review delivery exhaustion resets Review and retains committed publication")
    func initialReviewDeliveryExhaustionResetsReviewAndRetainsCommittedPublication() async throws {
        // Arrange
        let fixture = try await makeRefreshAdmissionIntegrationFixture(failsReviewDelivery: true)
        try await fixture.openFileMetadataSubscription()
        try await fixture.openReviewMetadataSubscription()

        // Act
        let foregroundTransition = fixture.controller.applyBridgePaneActivity(.foreground)
        await foregroundTransition?.value
        guard case .panePresentation = try await fixture.consumeNextMetadataFrame() else {
            Issue.record("Expected foreground pane presentation before Review load result")
            await fixture.finish()
            return
        }
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
        let producerSnapshot = await fixture.productInstallation.session.producerSnapshot()

        // Assert
        #expect(producerSnapshot.queuedFrameCount == 1)
        #expect(
            await fixture.productInstallation.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-refresh-admission"
            ) == nil
        )
        #expect(
            await fixture.productInstallation.session.subscriptionSnapshot(
                subscriptionId: "file-subscription-refresh-admission"
            ) != nil
        )
        #expect(try fixture.currentCommittedReviewPublication().package.orderedItemIds == ["item-initial"])
        if producerSnapshot.queuedFrameCount == 1 {
            guard case .subscriptionReset(let reset) = try await fixture.consumeNextMetadataFrame() else {
                Issue.record("Expected exhausted Review delivery to enqueue one Review reset")
                await fixture.finish()
                return
            }
            #expect(
                reset.identity.subscriptionIdentity.subscriptionId
                    == "review-subscription-refresh-admission"
            )
            #expect(reset.reason == .staleSource)
        }
        await fixture.finish()
    }

    @Test("loaded-hidden product resync waits for one foreground Review reload")
    func loadedHiddenProductResyncWaitsForOneForegroundReviewReload() async throws {
        // Arrange
        let fixture = try await makeRefreshAdmissionIntegrationFixture()
        try await fixture.loadInitialReviewPackage()
        let comparisonCountBeforeResync = await fixture.reviewProvider.recordedComparisonRequestsCount()
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
        let comparisonGate = BridgeComparisonGate()
        await fixture.reviewProvider.setComparisonGate(comparisonGate)
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.loadedHidden)

        // Act
        fixture.controller.scheduleReviewPackageReloadForProductResync(reason: .productResync)

        // Assert — the retained package stays readable and no replacement build starts hidden.
        #expect(fixture.controller.activeReviewRefreshTask == nil)
        #expect(
            await fixture.reviewProvider.recordedComparisonRequestsCount()
                == comparisonCountBeforeResync
        )
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-initial"])

        // Act
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.foreground)
        await comparisonGate.waitForStartedComparisonCount(1)
        await comparisonGate.releaseAll()
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)

        // Assert
        #expect(
            await fixture.reviewProvider.recordedComparisonRequestsCount()
                == comparisonCountBeforeResync + 1
        )
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"])
        await fixture.finish()
    }

    @Test("loaded-hidden worktree invalidations coalesce and foreground catches up both surfaces once")
    func loadedHiddenWorktreeInvalidationsCoalesceIntoOneBothSurfaceCatchUp() async throws {
        // Arrange
        let fixture = try await makeRefreshAdmissionIntegrationFixture()
        try await fixture.loadInitialReviewPackage()
        let comparisonCountBeforeInvalidation = await fixture.reviewProvider.recordedComparisonRequestsCount()
        let firstStatus = makeRefreshAdmissionStatus(branch: "feature/first", changed: 2)
        let latestStatus = makeRefreshAdmissionStatus(branch: "feature/latest", changed: 4)
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.loadedHidden)

        // Act
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/First.swift"],
                    batchSequence: 41
                )
            )
        )
        await fixture.controller.handleWorktreeProductInvalidation(.statusChanged(firstStatus))
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Second.swift", "Sources/App/First.swift"],
                    batchSequence: 42
                )
            )
        )
        await fixture.controller.handleWorktreeProductInvalidation(.statusChanged(latestStatus))

        // Assert — loaded-hidden retains one pane-wide fact and starts no product work.
        let hiddenSnapshot = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot
        let hiddenDirtyFact = try #require(hiddenSnapshot.dirtyFact)
        #expect(hiddenSnapshot.activity == .loadedHidden)
        #expect(hiddenSnapshot.refreshPassCount == 0)
        #expect(hiddenSnapshot.activeRefreshPass == nil)
        #expect(
            hiddenDirtyFact.filePaths
                == [
                    "Sources/App/First.swift",
                    "Sources/App/Second.swift",
                ]
        )
        #expect(hiddenDirtyFact.latestBatchSequence == 42)
        #expect(hiddenDirtyFact.latestFileStatus == latestStatus)
        #expect(hiddenDirtyFact.requiresReviewRefresh)
        #expect(await fixture.reviewProvider.recordedComparisonRequestsCount() == comparisonCountBeforeInvalidation)
        #expect(await fixture.fileMetadataSource.changesetPublishCount == 0)
        #expect(await fixture.fileMetadataSource.statusPublishCount == 0)

        // Act — foreground return starts one catch-up. Hold Review so repeated foreground
        // inputs cannot accidentally start another pass.
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
        let comparisonGate = BridgeComparisonGate()
        await fixture.reviewProvider.setComparisonGate(comparisonGate)
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.foreground)
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.foreground)
        await comparisonGate.waitForStartedComparisonCount(1)
        await comparisonGate.releaseAll()
        await fixture.fileMetadataSource.waitForChangesetPublishCount(1)
        await fixture.fileMetadataSource.waitForStatusPublishCount(1)
        await waitForRefreshAdmissionIdle(fixture.controller)

        // Assert
        #expect(
            await fixture.reviewProvider.recordedComparisonRequestsCount()
                == comparisonCountBeforeInvalidation + 1
        )
        #expect(await fixture.fileMetadataSource.publishedChangesets().count == 1)
        #expect(await fixture.fileMetadataSource.publishedStatuses() == [latestStatus])
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"])
        let foregroundSnapshot = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot
        #expect(foregroundSnapshot.activity == .foreground)
        #expect(foregroundSnapshot.refreshPassCount == 2)
        #expect(foregroundSnapshot.activeRefreshPass == nil)
        #expect(foregroundSnapshot.dirtyFact == nil)
        await fixture.finish()
    }

    @Test("second File invalidation publishes while Review construction remains blocked")
    func secondFileInvalidationPublishesWhileReviewConstructionRemainsBlocked() async throws {
        // Arrange
        let fixture = try await makeRefreshAdmissionIntegrationFixture()
        try await fixture.loadInitialReviewPackage()
        let comparisonCountBeforeInvalidation =
            await fixture.reviewProvider.recordedComparisonRequestsCount()
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
        let comparisonGate = BridgeComparisonGate()
        await fixture.reviewProvider.setComparisonGate(comparisonGate)

        // Act — the first invalidation starts both lanes. Review remains held at its provider
        // boundary while File publishes progressively.
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/First.swift"],
                    batchSequence: 43
                )
            )
        )
        await comparisonGate.waitForStartedComparisonCount(1)
        await fixture.fileMetadataSource.waitForChangesetPublishCount(1)

        // Act — a newer File fact must not wait for the still-running Review operation.
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Second.swift"],
                    batchSequence: 44
                )
            )
        )
        await fixture.fileMetadataSource.waitForChangesetPublishCount(2)

        // Assert — both File generations publish before either Review attempt is released, and
        // the newer Review attempt is admitted independently of its predecessor's lifetime.
        await comparisonGate.waitForStartedComparisonCount(2)
        #expect(await fixture.fileMetadataSource.changesetPublishAttemptCount == 2)
        #expect(await fixture.fileMetadataSource.publishedChangesets().count == 2)
        #expect(
            await fixture.reviewProvider.recordedComparisonRequestsCount()
                == comparisonCountBeforeInvalidation + 2
        )

        await comparisonGate.releaseAll()
        await waitForRefreshAdmissionIdle(fixture.controller)
        await fixture.finish()
    }

    @Test("late stale File publication cannot mutate after its successor")
    func lateStaleFilePublicationCannotMutateAfterSuccessor() async throws {
        // Arrange
        let publicationGate = RefreshAdmissionCancellationIgnoringProducerGate()
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            fileChangesetPublicationGate: publicationGate
        )
        try await fixture.loadInitialReviewPackage()
        let generation10 = fixture.makeChangeset(
            paths: ["Sources/App/Generation10.swift"],
            batchSequence: 45
        )
        let generation11 = fixture.makeChangeset(
            paths: ["Sources/App/Generation11.swift"],
            batchSequence: 46
        )

        // Act — generation 10 ignores cancellation while generation 11 becomes current.
        await fixture.controller.handleWorktreeProductInvalidation(.filesChanged(generation10))
        await publicationGate.waitUntilStartedCount(1)
        await fixture.controller.handleWorktreeProductInvalidation(.filesChanged(generation11))
        await publicationGate.waitUntilStartedCount(2)

        // Act — the current successor publishes first, then the stale predecessor drains late.
        publicationGate.releaseLatest()
        await fixture.fileMetadataSource.waitForChangesetPublishCount(1)
        let successorPublications = await fixture.fileMetadataSource.publishedChangesets()
        let successorChangeset = try #require(successorPublications.first)
        #expect(successorPublications.count == 1)
        #expect(successorChangeset.batchSeq == generation11.batchSeq)
        #expect(Set(successorChangeset.paths) == Set(generation10.paths + generation11.paths))
        publicationGate.releaseFirst()
        #expect(await waitForRetiringFileRefreshTasksToDrain(fixture.controller))
        await waitForRefreshAdmissionIdle(fixture.controller)

        // Assert — stale generation 10 may clean up, but cannot mutate after generation 11.
        let finalPublications = await fixture.fileMetadataSource.publishedChangesets()
        let finalChangeset = try #require(finalPublications.first)
        #expect(finalPublications.count == 1)
        #expect(finalChangeset.batchSeq == generation11.batchSeq)
        #expect(Set(finalChangeset.paths) == Set(generation10.paths + generation11.paths))
        await fixture.finish()
    }

    @Test("newest Review starts before a cancellation-ignoring predecessor returns")
    func newestReviewStartsBeforeCancellationIgnoringPredecessorReturns() async throws {
        // Arrange
        let fixture = try await makeRefreshAdmissionIntegrationFixture()
        try await fixture.loadInitialReviewPackage()
        let comparisonCountBeforeInvalidation =
            await fixture.reviewProvider.recordedComparisonRequestsCount()
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
        let comparisonGate = BridgeComparisonGate()
        await fixture.reviewProvider.setComparisonGate(comparisonGate)

        // Act — operation 10 enters the provider and deliberately ignores cancellation while
        // blocked. Operation 11 becomes authoritative before 10 is released.
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Generation10.swift"],
                    batchSequence: 45
                )
            )
        )
        await comparisonGate.waitForStartedComparisonCount(1)
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Generation11.swift"],
                    batchSequence: 46
                )
            )
        )

        // Assert — successor admission is independent of operation 10's physical lifetime.
        await comparisonGate.waitForStartedComparisonCount(2)
        #expect(await comparisonGate.hasStartedComparisonCount(2))

        // Act — only the predecessor is released. Its late completion may clean its retiring
        // custody, but it cannot clear successor ownership or Review loading.
        await comparisonGate.releaseFirst()
        #expect(await waitForRetiringReviewRefreshTasksToDrain(fixture.controller))
        #expect(fixture.controller.activeReviewRefreshTask != nil)
        #expect(fixture.controller.activeReviewRefreshTaskId != nil)
        #expect(
            fixture.controller.refreshAdmissionCoordinator.productPresentationSnapshot
                .refreshingLanes.contains(.review)
        )

        // Cleanup and final convergence.
        await comparisonGate.releaseAll()
        await waitForRefreshAdmissionIdle(fixture.controller)
        #expect(
            await fixture.reviewProvider.recordedComparisonRequestsCount()
                == comparisonCountBeforeInvalidation + 2
        )
        #expect(fixture.controller.activeReviewRefreshTask == nil)
        #expect(fixture.controller.activeReviewRefreshTaskId == nil)
        #expect(fixture.controller.retiringReviewRefreshTaskById.isEmpty)
        await fixture.finish()
    }

    @Test("foreground to loaded-hidden suppresses a late admitted Review publication")
    func foregroundToLoadedHiddenSuppressesLateReviewPublication() async throws {
        // Arrange
        let fixture = try await makeRefreshAdmissionIntegrationFixture()
        try await fixture.loadInitialReviewPackage()
        let committedBeforeRefresh = try fixture.currentCommittedReviewPublication()
        let panePackageBeforeRefresh = try #require(fixture.controller.paneState.diff.packageMetadata)
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
        let comparisonGate = BridgeComparisonGate()
        await fixture.reviewProvider.setComparisonGate(comparisonGate)

        // Act
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Refreshed.swift"],
                    batchSequence: 51
                )
            )
        )
        await comparisonGate.waitForStartedComparisonCount(1)
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.loadedHidden)
        await comparisonGate.releaseAll()
        await waitForRefreshAdmissionSettledWhileHidden(fixture.controller)

        // Assert
        let committedAfterLateCompletion = try fixture.currentCommittedReviewPublication()
        #expect(committedAfterLateCompletion.publicationId == committedBeforeRefresh.publicationId)
        #expect(committedAfterLateCompletion.package == committedBeforeRefresh.package)
        #expect(fixture.controller.paneState.diff.packageMetadata == panePackageBeforeRefresh)
        let hiddenSnapshot = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot
        #expect(hiddenSnapshot.activity == .loadedHidden)
        #expect(hiddenSnapshot.activeRefreshPass == nil)
        #expect(hiddenSnapshot.dirtyFact != nil)
        await fixture.finish()
    }

    @Test("foreground return replays only the cancelled Review lane")
    func foregroundReturnBeforeCanceledRefreshUnwindsStartsOneReplacementCatchUp() async throws {
        // Arrange
        let fixture = try await makeRefreshAdmissionIntegrationFixture()
        try await fixture.loadInitialReviewPackage()
        let comparisonCountBeforeInvalidation = await fixture.reviewProvider.recordedComparisonRequestsCount()
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
        let comparisonGate = BridgeComparisonGate()
        await fixture.reviewProvider.setComparisonGate(comparisonGate)

        // Act — block the first pass, invalidate its foreground epoch, then return before
        // its canceled task has had a chance to unwind.
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Replacement.swift"],
                    batchSequence: 61
                )
            )
        )
        await comparisonGate.waitForStartedComparisonCount(1)
        await waitForActiveFileRefreshTaskToFinish(fixture.controller)
        #expect(!fixture.controller.worktreeRefreshDriver.hasActiveFileOperation)
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.loadedHidden)
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = fixture.controller.applyBridgePaneActivity(.foreground)
        await comparisonGate.releaseAll()
        await waitForRefreshAdmissionIdle(fixture.controller)

        // Assert — File completed before the activity transition, so only the cancelled Review
        // lane is restored and replayed after foreground returns.
        #expect(
            await fixture.reviewProvider.recordedComparisonRequestsCount()
                == comparisonCountBeforeInvalidation + 2
        )
        #expect(await fixture.fileMetadataSource.changesetPublishAttemptCount == 1)
        #expect(await fixture.fileMetadataSource.publishedChangesets().count == 1)
        let snapshot = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot
        #expect(snapshot.refreshPassCount == 3)
        #expect(snapshot.activeRefreshPass == nil)
        #expect(snapshot.dirtyFact == nil)
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"])
        await fixture.finish()
    }

    @Test("stale Review commit after rapid foreground return replays only Review")
    func staleReviewCommitAfterRapidForegroundReturnSchedulesOneReplacementCatchUp() async throws {
        // Arrange — initial Review authority commits before the reservation boundary is armed.
        let reservationGate = RefreshAdmissionReviewReservationGate()
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            reviewMetadataReservationGate: reservationGate
        )
        try await fixture.loadInitialReviewPackage()
        let comparisonCountBeforeInvalidation = await fixture.reviewProvider.recordedComparisonRequestsCount()
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
        await reservationGate.enable()

        // Act — hold the first replacement immediately before commit, invalidate its original
        // foreground token, and return foreground before that old transaction unwinds.
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/StaleCommit.swift"],
                    batchSequence: 63
                )
            )
        )
        await reservationGate.waitForHeldReservationCount(1)
        let hiddenTransition = fixture.controller.applyBridgePaneActivity(.loadedHidden)
        let foregroundTransition = fixture.controller.applyBridgePaneActivity(.foreground)
        await hiddenTransition?.value
        await foregroundTransition?.value
        await reservationGate.releaseAll()
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)

        // Assert — the rejected old transaction is stale, not failed. File already completed,
        // so exactly one Review replacement consumes the restored Review fact.
        #expect(
            await fixture.reviewProvider.recordedComparisonRequestsCount()
                == comparisonCountBeforeInvalidation + 2
        )
        #expect(await fixture.fileMetadataSource.changesetPublishAttemptCount == 1)
        #expect(await fixture.fileMetadataSource.publishedChangesets().count == 1)
        let snapshot = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot
        #expect(snapshot.refreshPassCount == 3)
        #expect(snapshot.activeRefreshPass == nil)
        #expect(snapshot.dirtyFact == nil)
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"])
        await fixture.finish()
    }

    @Test("File publication failure retains dirty state after successful Review refresh")
    func filePublicationFailureRetainsDirtyStateAfterSuccessfulReviewRefresh() async throws {
        // Arrange
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            failsChangesetPublication: true
        )
        try await fixture.loadInitialReviewPackage()
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)

        // Act
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/FileFailure.swift"],
                    batchSequence: 62
                )
            )
        )
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)

        // Assert — Review advances independently. Only the failed File lane retains its exact
        // worktree fact for retry.
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"])
        #expect(await fixture.fileMetadataSource.changesetPublishAttemptCount == 1)
        #expect(await fixture.fileMetadataSource.publishedChangesets().isEmpty)
        let snapshot = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot
        let retainedDirtyFact = snapshot.dirtyFact
        #expect(retainedDirtyFact?.filePaths == ["Sources/App/FileFailure.swift"])
        #expect(retainedDirtyFact?.latestBatchSequence == 62)
        #expect(retainedDirtyFact?.requiresReviewRefresh == false)
        #expect(snapshot.activeRefreshPass == nil)
        #expect(snapshot.fileRefreshFailure?.retryable == false)
        await fixture.finish()
    }

    @Test("retryable File publication failure retries once and converges")
    func retryableFilePublicationFailureRetriesOnceAndConverges() async throws {
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            retryableChangesetFailureCount: 1
        )
        try await fixture.loadInitialReviewPackage()

        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Transient.swift"],
                    batchSequence: 63
                )
            )
        )
        await waitForActiveFileRefreshTaskToFinish(fixture.controller)

        let snapshot = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot
        #expect(await fixture.fileMetadataSource.changesetPublishAttemptCount == 2)
        #expect(await fixture.fileMetadataSource.publishedChangesets().count == 1)
        #expect(snapshot.dirtyFact == nil)
        #expect(snapshot.fileRefreshFailure == nil)
        await fixture.finish()
    }

    @Test("second retryable File publication failure becomes unavailable")
    func secondRetryableFilePublicationFailureBecomesUnavailable() async throws {
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            retryableChangesetFailureCount: 2
        )
        try await fixture.loadInitialReviewPackage()

        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Unavailable.swift"],
                    batchSequence: 64
                )
            )
        )
        await waitForActiveFileRefreshTaskToFinish(fixture.controller)

        let snapshot = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot
        #expect(await fixture.fileMetadataSource.changesetPublishAttemptCount == 2)
        #expect(snapshot.dirtyFact?.latestBatchSequence == 64)
        #expect(snapshot.fileRefreshFailure?.retryable == true)
        await fixture.finish()
    }

    @Test("new File invalidation recovers unavailable refresh")
    func newFileInvalidationRecoversUnavailableRefresh() async throws {
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            retryableChangesetFailureCount: 2
        )
        try await fixture.loadInitialReviewPackage()
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Unavailable.swift"],
                    batchSequence: 65
                )
            )
        )
        await waitForActiveFileRefreshTaskToFinish(fixture.controller)
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.fileRefreshFailure != nil)

        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Recovered.swift"],
                    batchSequence: 66
                )
            )
        )
        await waitForActiveFileRefreshTaskToFinish(fixture.controller)

        let snapshot = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot
        #expect(await fixture.fileMetadataSource.changesetPublishAttemptCount == 3)
        #expect(await fixture.fileMetadataSource.publishedChangesets().count == 1)
        #expect(snapshot.dirtyFact == nil)
        #expect(snapshot.fileRefreshFailure == nil)
        await fixture.finish()
    }

    @Test("explicit File retry recovers retained unavailable refresh")
    func explicitFileRetryRecoversRetainedUnavailableRefresh() async throws {
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            retryableChangesetFailureCount: 2
        )
        try await fixture.loadInitialReviewPackage()
        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/ExplicitRetry.swift"],
                    batchSequence: 67
                )
            )
        )
        await waitForActiveFileRefreshTaskToFinish(fixture.controller)
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.fileRefreshFailure != nil)

        fixture.controller.retryUnavailableFileRefresh()
        await waitForActiveFileRefreshTaskToFinish(fixture.controller)

        let snapshot = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot
        #expect(await fixture.fileMetadataSource.changesetPublishAttemptCount == 3)
        #expect(await fixture.fileMetadataSource.publishedChangesets().count == 1)
        #expect(snapshot.dirtyFact == nil)
        #expect(snapshot.fileRefreshFailure == nil)
        await fixture.finish()
    }

    @Test("controller teardown synchronously closes the refresh work gate")
    func controllerTeardownSynchronouslyClosesRefreshWorkGate() async throws {
        // Arrange
        let controller = makeController(
            state: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/bridge-refresh-teardown",
                    baseline: .ref(name: "HEAD~1"))
            )
        )
        // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
        _ = controller.applyBridgePaneActivity(.foreground)
        controller.reviewGitRefreshSeedHolder.commit(
            refreshAdmissionContributionSeed(
                targetOID: "teardown-target",
                headOID: "teardown-head",
                baseOID: "teardown-base"
            )
        )
        let admittedWork = try #require(
            controller.refreshAdmissionCoordinator.acquireForegroundWork()
        )
        var latePublicationCount = 0

        // Act
        let retirementTask = controller.beginTeardown()
        let latePublication = admittedWork.withValidAdmission {
            latePublicationCount += 1
            return true
        }

        // Assert
        #expect(latePublication == nil)
        #expect(latePublicationCount == 0)
        #expect(controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity == .closed)
        #expect(controller.refreshAdmissionCoordinator.acquireForegroundWork() == nil)
        #expect(!controller.reviewGitRefreshSeedHolder.hasActiveSeed)
        #expect(await retirementTask.value)
    }
}
