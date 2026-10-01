import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.BridgePaneControllerTests {

    @Test("unchanged contribution refresh commits successor seed without publication")
    func unchangedContributionRefreshCommitsSuccessorSeedWithoutPublication() async throws {
        let fixture = try await makeContributionRefreshFixture()
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
        guard
            case .success = await fixture.controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: fixture.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: UUIDv7.generate(),
                correlationId: nil
            )
        else {
            Issue.record("Expected initial contribution load")
            return
        }
        let productAdmission = try #require(fixture.controller.productAdmissionGate.acquire())
        let initialPublication = try #require(
            fixture.controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        )
        #expect(fixture.controller.reviewGitRefreshSeedHolder.commitCount == 1)

        await fixture.controller.handlePaneFilesystemContextEvent(
            .cwdSubtreeChanged(
                context: PaneFilesystemContext(
                    paneId: PaneId(existingUUID: fixture.paneId),
                    repoId: fixture.repoId,
                    cwd: URL(fileURLWithPath: "/tmp/contribution-refresh"),
                    worktreeId: fixture.worktreeId
                ),
                paths: ["Sources/App/Initial.swift"],
                batchSeq: 1
            )
        )
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
        let finalPublication = try #require(
            fixture.controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        )

        #expect(finalPublication.publicationId == initialPublication.publicationId)
        #expect(fixture.controller.reviewGitRefreshSeedHolder.commitCount == 2)
        #expect(fixture.controller.reviewGitRefreshSeedHolder.hasActiveSeed)
    }

    @Test("contribution refresh captures fresh truth under stable lineage without endpoint replay")
    func contributionRefreshCapturesFreshTruthUnderStableLineageWithoutEndpointReplay() async throws {
        let fixture = try await makeContributionRefreshFixture()
        let controller = fixture.controller
        let provider = fixture.provider
        let paneId = fixture.paneId
        let repoId = fixture.repoId
        let worktreeId = fixture.worktreeId
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

        let initialCommandId = UUIDv7.generate()
        let initialResult = await controller.handleDiffCommand(
            DiffCommand.loadDiff(
                DiffArtifact(diffId: UUIDv7.generate(), worktreeId: worktreeId, patchData: Data())
            ),
            commandId: initialCommandId,
            correlationId: nil
        )
        let productAdmission = try #require(controller.productAdmissionGate.acquire())
        let predecessor = try #require(
            controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        )

        let captureGate = BridgeContributionCaptureGate()
        await provider.setContributionCapture(fixture.successorCapture)
        await provider.setContributionCaptureGate(captureGate)
        await controller.handlePaneFilesystemContextEvent(
            PaneFilesystemContextEvent.cwdSubtreeChanged(
                context: PaneFilesystemContext(
                    paneId: PaneId(existingUUID: paneId),
                    repoId: repoId,
                    cwd: URL(fileURLWithPath: "/tmp/contribution-refresh"),
                    worktreeId: worktreeId
                ),
                paths: ["Sources/App/Successor.swift"],
                batchSeq: 1
            )
        )
        await captureGate.waitForStart()
        let visibleWhilePending = try #require(
            controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        )
        #expect(controller.nextReviewGeneration == 1)
        #expect(visibleWhilePending == predecessor)
        #expect(controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-initial"])
        await captureGate.releaseAll()
        await waitForActiveReviewRefreshTaskToFinish(controller)

        let successor = try #require(
            controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        )
        let requests = await provider.recordedContributionRequests()
        #expect(initialResult == .success(commandId: initialCommandId))
        #expect(await provider.recordedComparisonRequestsCount() == 0)
        assertStableLineageContributionRefresh(
            controller: controller,
            predecessor: predecessor,
            successor: successor,
            requests: requests
        )

        try await assertStaleContributionCaptureCannotCommit(
            fixture: fixture,
            productAdmission: productAdmission,
            successor: successor
        )
    }

    @Test("superseded contribution refresh retains lineage until its successor settles")
    func supersededContributionRefreshRetainsLineageUntilSuccessorSettles() async throws {
        // Arrange
        let fixture = try await makeContributionRefreshFixture()
        let controller = fixture.controller
        defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
        guard
            case .success = await controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: fixture.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: UUIDv7.generate(),
                correlationId: nil
            )
        else {
            Issue.record("Expected the initial contribution load to succeed")
            return
        }
        let pendingGeneration = controller.nextReviewGeneration
        controller.refreshAdmissionCoordinator.beginReviewComparisonAttempt(
            activeTarget: .ref(name: "target"),
            reviewGeneration: pendingGeneration.rawValue
        )
        try #require(
            controller.pendingComparisonReviewGeneration == nil,
            "Same-lineage refresh must not be blocked by a fabricated comparison replacement"
        )
        let captureGate = BridgeContributionCaptureGate()
        await fixture.provider.setContributionCaptureGate(captureGate)

        // Act — the predecessor attempt remains blocked while its successor
        // becomes current under the same public Review generation.
        await controller.handlePaneFilesystemContextEvent(
            .cwdSubtreeChanged(
                context: PaneFilesystemContext(
                    paneId: PaneId(existingUUID: fixture.paneId),
                    repoId: fixture.repoId,
                    cwd: URL(fileURLWithPath: "/tmp/contribution-refresh"),
                    worktreeId: fixture.worktreeId
                ),
                paths: ["Sources/App/Generation2.swift"],
                batchSeq: 1
            )
        )
        await captureGate.waitForStartedCaptureCount(1)
        await controller.handlePaneFilesystemContextEvent(
            .cwdSubtreeChanged(
                context: PaneFilesystemContext(
                    paneId: PaneId(existingUUID: fixture.paneId),
                    repoId: fixture.repoId,
                    cwd: URL(fileURLWithPath: "/tmp/contribution-refresh"),
                    worktreeId: fixture.worktreeId
                ),
                paths: ["Sources/App/Generation3.swift"],
                batchSeq: 2
            )
        )
        await captureGate.waitForStartedCaptureCount(2)
        let refreshRequests = await fixture.provider.recordedContributionRequests()
        try #require(refreshRequests.count == 3)
        #expect(refreshRequests.map { $0.reviewGenerationValue } == [1, 1, 1])
        #expect(
            refreshRequests[2].reviewAttemptAuthorityGeneration
                > refreshRequests[1].reviewAttemptAuthorityGeneration
        )
        await captureGate.releaseFirst()
        #expect(await waitForRetiringReviewRefreshTasksToDrain(controller))

        // Assert — stale cleanup cannot manufacture a failure for the live successor.
        #expect(
            controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?
                .attempt == .pending(reviewGeneration: pendingGeneration.rawValue)
        )

        await captureGate.releaseAll()
        await waitForActiveReviewRefreshTaskToFinish(controller)
        #expect(
            controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?
                .attempt == .settled(reviewGeneration: controller.nextReviewGeneration.rawValue)
        )
    }

    @Test("filesystem context refresh preserves revisions across changed and no-op packages")
    func filesystemContextRefreshPreservesRevisionsAcrossChangedAndNoOpPackages() async throws {
        let fixture = try await makeRefreshRevisionFixture()
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

        let loadResult = await fixture.controller.handleDiffCommand(
            .loadDiff(
                DiffArtifact(
                    diffId: UUIDv7.generate(),
                    worktreeId: fixture.headEndpoint.worktreeId,
                    patchData: Data()
                )
            ),
            commandId: fixture.commandId,
            correlationId: nil
        )
        #expect(fixture.controller.paneState.diff.packageMetadata?.comparisonOrigin == nil)

        await setRefreshComparison(fixture, changedFile: fixture.refreshedFile)
        await postRefreshEvent(fixture, path: "Sources/App/New.swift", batchSeq: 10)
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
        #expect(loadResult == .success(commandId: fixture.commandId))
        #expect(fixture.controller.paneState.diff.status == .ready)
        #expect(fixture.controller.paneState.diff.packageMetadata?.comparisonOrigin == nil)
        expectRefreshPackageState(
            fixture,
            itemId: "item-new",
            revision: 1,
            addedItemIds: ["item-new"],
            removedItemIds: ["item-old"]
        )
        let productAdmission = try #require(fixture.controller.productAdmissionGate.acquire())
        let changedPublication = try #require(
            fixture.controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        )
        let changedPackageMetadata = fixture.controller.paneState.diff.packageMetadata
        let changedPackageDelta = fixture.controller.paneState.diff.packageDelta

        await postRefreshEvent(fixture, path: "Sources/App/New.swift", batchSeq: 11)
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
        let unchangedPublication = try #require(
            fixture.controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        )
        #expect(unchangedPublication.publicationId == changedPublication.publicationId)
        #expect(unchangedPublication == changedPublication)
        #expect(fixture.controller.reviewPublicationCoordinator.diagnosticSnapshot.pending == nil)
        #expect(fixture.controller.paneState.diff.status == .ready)
        #expect(fixture.controller.paneState.diff.packageMetadata == changedPackageMetadata)
        #expect(fixture.controller.paneState.diff.packageDelta == changedPackageDelta)

        await setRefreshComparison(fixture, changedFile: fixture.secondRefreshedFile)
        await postRefreshEvent(fixture, path: "Sources/App/Newer.swift", batchSeq: 12)
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
        expectRefreshPackageState(
            fixture,
            itemId: "item-newer",
            revision: 2,
            addedItemIds: ["item-newer"],
            removedItemIds: ["item-new"]
        )
        #expect(await fixture.provider.recordedComparisonRequestsCount() == 4)
    }

    @Test("filesystem context refresh coalesces overlapping refresh events")
    func filesystemContextRefreshCoalescesOverlappingRefreshEvents() async throws {
        let fixture = try await makeRefreshRevisionFixture()
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
        let loadResult = await fixture.controller.handleDiffCommand(
            .loadDiff(
                DiffArtifact(
                    diffId: UUIDv7.generate(),
                    worktreeId: fixture.headEndpoint.worktreeId,
                    patchData: Data()
                )
            ),
            commandId: fixture.commandId,
            correlationId: nil
        )
        #expect(loadResult == .success(commandId: fixture.commandId))

        let gate = BridgeComparisonGate()
        await fixture.provider.setComparisonGate(gate)
        await setRefreshComparison(fixture, changedFile: fixture.refreshedFile)
        await postRefreshEvent(
            fixture,
            path: "Sources/App/New.swift",
            batchSeq: 20
        )
        await gate.waitForStartedComparisonCount(1)

        await setRefreshComparison(fixture, changedFile: fixture.secondRefreshedFile)
        await postRefreshEvent(
            fixture,
            path: "Sources/App/Newer.swift",
            batchSeq: 21
        )
        await postRefreshEvent(
            fixture,
            path: "Sources/App/Newer.swift",
            batchSeq: 22
        )
        await Task.yield()
        await Task.yield()

        #expect(await fixture.provider.recordedComparisonRequestsCount() == 2)
        await gate.releaseAll()
        await waitForActiveReviewRefreshTaskToFinish(fixture.controller)

        #expect(await fixture.provider.recordedComparisonRequestsCount() == 3)
        expectRefreshPackageState(
            fixture,
            itemId: "item-newer",
            revision: 1,
            addedItemIds: ["item-newer"],
            removedItemIds: ["item-old"]
        )
    }

    @Test("loadDiff ignores stale earlier generation completion")
    func loadDiff_ignores_stale_earlier_generation_completion() async throws {
        let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
        let firstFile = makeBridgeEndpointChangedFile(
            fileId: "old",
            path: "Sources/App/Old.swift",
            sizeBytes: 100
        )
        let secondFile = makeBridgeEndpointChangedFile(
            fileId: "new",
            path: "Sources/App/New.swift",
            sizeBytes: 100
        )
        let provider = OutOfOrderBridgeReviewSourceProvider(
            firstGenerationComparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                changedFiles: [firstFile]
            ),
            laterGenerationComparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                changedFiles: [secondFile]
            )
        )
        let controller = makeController(
            state: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .unstaged)
            ),
            reviewSourceProvider: provider
        )
        defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
        try await showReviewInNativeFixture(controller)
        let firstCommandId = UUID()
        let secondCommandId = UUID()

        async let firstResult = controller.handleDiffCommand(
            .loadDiff(
                DiffArtifact(diffId: UUIDv7.generate(), worktreeId: headEndpoint.worktreeId, patchData: Data())
            ),
            commandId: firstCommandId,
            correlationId: nil
        )
        await provider.waitForFirstGenerationStarted()
        let secondResult = await controller.handleDiffCommand(
            .loadDiff(
                DiffArtifact(diffId: UUIDv7.generate(), worktreeId: headEndpoint.worktreeId, patchData: Data())
            ),
            commandId: secondCommandId,
            correlationId: nil
        )
        await provider.releaseFirstGeneration()

        #expect(secondResult == .success(commandId: secondCommandId))
        #expect(await firstResult == .failure(.invalidPayload(description: "Stale bridge review load")))
        #expect(controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-new"])
        #expect(controller.paneState.diff.packageMetadata?.itemsById["item-old"] == nil)
    }

    @Test("loadDiff close after package commit suppresses diffLoaded and success")
    func loadDiff_close_after_package_state_commit_suppresses_diffLoaded_and_success() async throws {
        // Arrange
        let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
        let changedFile = makeBridgeEndpointChangedFile(
            fileId: "late-close",
            path: "Sources/App/LateClose.swift",
            sizeBytes: 100
        )
        let reviewSourceProvider = BridgeReviewSourceProviderFake(
            comparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                changedFiles: [changedFile]
            ),
            contentByHandleId: [:]
        )
        let reviewMetadataSource = DiffLoadReadyPublicationGate()
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let productProvider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: reviewMetadataSource,
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let paneId = UUIDv7.generate()
        let productAdmissionGate = BridgeProductAdmissionGate()
        let installation = BridgePaneController.makeInitialProductSessionInstallation(
            paneSessionId: paneId.uuidString,
            provider: productProvider,
            productAdmissionGate: productAdmissionGate
        )
        let controller = BridgePaneController(
            paneId: paneId,
            state: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .unstaged)
            ),
            appRootURL: testBridgeAppRootURL(),
            reviewSourceProvider: reviewSourceProvider,
            initialPaneActivity: .foreground,
            productSessionDependencies: BridgePaneProductSessionDependencies(
                installation: installation,
                owner: BridgePaneController.makeProductSessionOwner(
                    paneSessionId: paneId.uuidString,
                    provider: productProvider,
                    productAdmissionGate: productAdmissionGate,
                    activeInstallation: installation
                ),
                productProvider: productProvider
            )
        )
        let productAdmission = try #require(productAdmissionGate.acquire())
        let metadataProducerLease = try await installDiffLoadMetadataProducer(
            installation: installation,
            productProvider: productProvider,
            productAdmission: productAdmission
        )
        try await showReviewInNativeFixture(controller, metadataProducerLease: metadataProducerLease)
        let commandId = UUIDv7.generate()

        // Act
        async let commandResult = controller.handleDiffCommand(
            .loadDiff(
                DiffArtifact(
                    diffId: UUIDv7.generate(),
                    worktreeId: headEndpoint.worktreeId,
                    patchData: Data()
                )
            ),
            commandId: commandId,
            correlationId: nil
        )
        await reviewMetadataSource.waitUntilReadyPublicationStarted()

        // Assert
        #expect(controller.paneState.diff.status == .ready)
        #expect(controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-late-close"])
        #expect(controller.runtime.snapshot().lastSeq == 0)

        let retirementTask = controller.beginTeardown()
        await reviewMetadataSource.releaseReadyPublication()

        #expect(
            await commandResult
                == .failure(.invalidPayload(description: "Bridge pane is closed"))
        )
        #expect(controller.runtime.snapshot().lastSeq == 0)
        let replay = await controller.runtime.eventsSince(seq: 0)
        #expect(!replay.events.contains(where: isDiffLoadWitnessEvent))
        #expect(await retirementTask.value)
        #expect(await controller.productSessionOwner.snapshot().hasZeroResidue)
    }

    @Test("contribution load cannot commit after its expected generation advances during reservation")
    func contributionLoadCannotCommitAfterGenerationAdvancesDuringReservation() async throws {
        let baseEndpoint = makeBridgeEndpoint(endpointId: "contribution-base", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
        let changedFile = makeBridgeEndpointChangedFile(
            fileId: "generation-a",
            path: "Sources/App/GenerationA.swift",
            sizeBytes: 100
        )
        let contributionCapture = BridgeContributionComparisonCapture(
            resolvedTargetOID: "target-a",
            reviewedHeadOID: "head-a",
            baseRole: .commonCommit,
            baseOID: "base-a",
            comparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                changedFiles: [changedFile]
            )
        )
        let reviewSourceProvider = BridgeReviewSourceProviderFake(
            comparison: contributionCapture.comparison,
            contentByHandleId: [:],
            contributionCapture: contributionCapture
        )
        let reservationGate = DiffLoadReviewReservationGate()
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let productProvider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: reservationGate,
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let paneId = UUIDv7.generate()
        let productAdmissionGate = BridgeProductAdmissionGate()
        let installation = BridgePaneController.makeInitialProductSessionInstallation(
            paneSessionId: paneId.uuidString,
            provider: productProvider,
            productAdmissionGate: productAdmissionGate
        )
        let controller = BridgePaneController(
            paneId: paneId,
            state: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/contribution-generation-fence",
                    baseline: .ref(name: "target")
                )
            ),
            appRootURL: testBridgeAppRootURL(),
            reviewSourceProvider: reviewSourceProvider,
            initialPaneActivity: .foreground,
            productSessionDependencies: BridgePaneProductSessionDependencies(
                installation: installation,
                owner: BridgePaneController.makeProductSessionOwner(
                    paneSessionId: paneId.uuidString,
                    provider: productProvider,
                    productAdmissionGate: productAdmissionGate,
                    activeInstallation: installation
                ),
                productProvider: productProvider
            )
        )
        defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
        try await showReviewInNativeFixture(controller)
        let commandId = UUIDv7.generate()
        async let commandResult = controller.handleDiffCommand(
            .loadDiff(
                DiffArtifact(
                    diffId: UUIDv7.generate(),
                    worktreeId: headEndpoint.worktreeId,
                    patchData: Data()
                )
            ),
            commandId: commandId,
            correlationId: nil
        )
        await reservationGate.waitUntilReservationStarted()

        controller.nextReviewGeneration = controller.nextReviewGeneration.next()
        await reservationGate.releaseReservation()

        #expect(await commandResult != .success(commandId: commandId))
        let productAdmission = try #require(productAdmissionGate.acquire())
        #expect(
            controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            ) == nil
        )
        #expect(controller.paneState.diff.packageMetadata == nil)
        #expect(controller.reviewPublicationCoordinator.diagnosticSnapshot.pending == nil)
    }

    @Test("loadDiff does not leak absolute workspace root in review package")
    func loadDiff_does_not_leak_absolute_workspace_root_in_review_package() async throws {
        let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
        let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
        let changedFile = makeBridgeEndpointChangedFile(
            fileId: "source",
            path: "Sources/App/View.swift",
            sizeBytes: 100
        )
        let provider = BridgeReviewSourceProviderFake(
            comparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                changedFiles: [changedFile]
            ),
            contentByHandleId: [:]
        )
        let controller = makeController(
            state: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .unstaged)
            ),
            reviewSourceProvider: provider
        )
        defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
        try await showReviewInNativeFixture(controller)
        let commandId = UUID()

        let result = await controller.handleDiffCommand(
            .loadDiff(
                DiffArtifact(diffId: UUIDv7.generate(), worktreeId: headEndpoint.worktreeId, patchData: Data())
            ),
            commandId: commandId,
            correlationId: nil
        )

        #expect(result == .success(commandId: commandId))
        let package = try #require(controller.paneState.diff.packageMetadata)
        #expect(package.orderedItemIds == ["item-source"])
        #expect(package.query.pathScope.isEmpty)
        #expect(package.headEndpoint.providerIdentity.contains("/tmp") == false)
        #expect(package.baseEndpoint.providerIdentity.contains("/tmp") == false)
    }

    @Test("loadDiff publishes typed provider unavailable failure")
    func loadDiff_publishes_typed_provider_unavailable_failure() async throws {
        let controller = BridgePaneController(
            paneId: UUIDv7.generate(),
            state: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .ref(name: "HEAD~1"))
            ),
            appRootURL: testBridgeAppRootURL(),
            initialPaneActivity: .foreground
        )
        defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
        try await showReviewInNativeFixture(controller)
        let commandId = UUID()
        let artifact = DiffArtifact(
            diffId: UUIDv7.generate(),
            worktreeId: UUIDv7.generate(),
            patchData: Data()
        )

        let result = await controller.handleDiffCommand(
            .loadDiff(artifact),
            commandId: commandId,
            correlationId: nil
        )

        #expect(result == .failure(.backendUnavailable(backend: "BridgeReviewSourceProvider")))
        #expect(controller.paneState.diff.status == .error)
        #expect(controller.paneState.diff.error == "providerUnavailable")
        #expect(controller.paneState.diff.packageMetadata == nil)
    }
}

@MainActor
private func assertStableLineageContributionRefresh(
    controller: BridgePaneController,
    predecessor: BridgeReviewCommittedPublication,
    successor: BridgeReviewCommittedPublication,
    requests: [BridgeContributionComparisonRequest]
) {
    #expect(requests.map { $0.reviewGenerationValue } == [1, 1])
    #expect(requests[1].reviewAttemptAuthorityGeneration > requests[0].reviewAttemptAuthorityGeneration)
    #expect(requests[1].baseEndpoint == predecessor.package.baseEndpoint)
    #expect(requests[1].headEndpoint == predecessor.package.headEndpoint)
    #expect(requests[1].gitRefreshScope == .exactPaths(["Sources/App/Successor.swift"]))
    #expect(requests[1].gitRefreshSeed != nil)
    #expect(predecessor.package.reviewGeneration == 1)
    #expect(successor.package.reviewGeneration == 1)
    #expect(successor.package.revision > predecessor.package.revision)
    #expect(successor.package.packageId == predecessor.package.packageId)
    #expect(successor.package.query.queryId == predecessor.package.query.queryId)
    #expect(successor.package.baseEndpoint.endpointId == predecessor.package.baseEndpoint.endpointId)
    #expect(successor.package.headEndpoint.endpointId == predecessor.package.headEndpoint.endpointId)
    #expect(
        successor.package.baseEndpoint.createdAtUnixMilliseconds
            == predecessor.package.baseEndpoint.createdAtUnixMilliseconds
    )
    #expect(
        successor.package.headEndpoint.createdAtUnixMilliseconds
            == predecessor.package.headEndpoint.createdAtUnixMilliseconds
    )
    #expect(predecessor.publicationId != successor.publicationId)
    #expect(
        predecessor.package.comparisonOrigin
            == .contribution(
                BridgeReviewContributionOrigin(
                    symbolicTarget: .ref(name: "target"),
                    resolvedTargetOID: "target-oid-1",
                    reviewedHeadOID: "head-oid-1",
                    baseRole: .commonCommit,
                    baseOID: "base-oid-1"
                )
            )
    )
    #expect(
        successor.package.comparisonOrigin
            == .contribution(
                BridgeReviewContributionOrigin(
                    symbolicTarget: .ref(name: "target"),
                    resolvedTargetOID: "target-oid-2",
                    reviewedHeadOID: "head-oid-2",
                    baseRole: .commonCommit,
                    baseOID: "base-oid-2"
                )
            )
    )
    #expect(predecessor.package.reviewedSubjectLabel == "feature-review")
    #expect(successor.package.reviewedSubjectLabel == "feature-review")
    #expect(successor.package.orderedItemIds == ["item-successor"])
    #expect(controller.reviewGitRefreshSeedHolder.commitCount == 2)
    #expect(controller.reviewGitRefreshSeedHolder.hasActiveSeed)
}

private enum DiffLoadWitnessError: Error {
    case expectedMetadataProducerRegistration
    case expectedWorkerSessionExecution
}

private actor DiffLoadReadyPublicationGate: BridgePaneProductReviewMetadataProducing {
    private var readyPublicationRelease: CheckedContinuation<Void, Never>?
    private var readyPublicationStarted = false
    private var readyPublicationStartedWaiters: [CheckedContinuation<Void, Never>] = []

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws {}

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        BridgeReviewMetadataPublicationReservation(
            reservationId: UUIDv7.generate(),
            packageId: package.packageId,
            publicationId: publicationId,
            reviewGeneration: package.reviewGeneration,
            revision: package.revision,
            projectionPlan: try BridgeReviewMetadataPublicationProjectionPlan.prepare(
                package: package,
                publicationId: publicationId
            )
        )
    }

    func deliver(
        publication _: BridgeReviewCommittedPublication,
        reservation _: BridgeReviewMetadataPublicationReservation,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        readyPublicationStarted = true
        let startedWaiters = readyPublicationStartedWaiters
        readyPublicationStartedWaiters.removeAll(keepingCapacity: false)
        for waiter in startedWaiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            readyPublicationRelease = continuation
        }
        return .delivered(
            BridgeReviewMetadataPublicationReceipt(
                retained: 0,
                publishedSubscriptions: 0,
                emittedEvents: 0,
                superseded: 0,
                finalFrames: []
            )
        )
    }

    func cancel(subscriptionId _: String) {}

    func waitUntilReadyPublicationStarted() async {
        guard !readyPublicationStarted else { return }
        await withCheckedContinuation { continuation in
            readyPublicationStartedWaiters.append(continuation)
        }
    }

    func releaseReadyPublication() {
        readyPublicationRelease?.resume()
        readyPublicationRelease = nil
    }
}

private actor DiffLoadReviewReservationGate: BridgePaneProductReviewMetadataProducing {
    private var reservationRelease: CheckedContinuation<Void, Never>?
    private var reservationStarted = false
    private var reservationStartedWaiters: [CheckedContinuation<Void, Never>] = []

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws {}

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        reservationStarted = true
        let waiters = reservationStartedWaiters
        reservationStartedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            reservationRelease = continuation
        }
        return BridgeReviewMetadataPublicationReservation(
            reservationId: UUIDv7.generate(),
            packageId: package.packageId,
            publicationId: publicationId,
            reviewGeneration: package.reviewGeneration,
            revision: package.revision,
            projectionPlan: try BridgeReviewMetadataPublicationProjectionPlan.prepare(
                package: package,
                publicationId: publicationId
            )
        )
    }

    func deliver(
        publication _: BridgeReviewCommittedPublication,
        reservation _: BridgeReviewMetadataPublicationReservation,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        .delivered(
            BridgeReviewMetadataPublicationReceipt(
                retained: 0,
                publishedSubscriptions: 0,
                emittedEvents: 0,
                superseded: 0,
                finalFrames: []
            )
        )
    }

    func cancel(subscriptionId _: String) {}

    func waitUntilReservationStarted() async {
        guard !reservationStarted else { return }
        await withCheckedContinuation { continuation in
            reservationStartedWaiters.append(continuation)
        }
    }

    func releaseReservation() {
        reservationRelease?.resume()
        reservationRelease = nil
    }
}

private func installDiffLoadMetadataProducer(
    installation: BridgeProductSessionInstallation,
    productProvider: BridgePaneProductSchemeProvider,
    productAdmission: BridgeProductAdmissionContext
) async throws -> BridgeProductProducerLease {
    let workerOpenRequest = try diffLoadWitnessControlRequest([
        "kind": "workerSession.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "request": NSNull(),
        "requestId": "request-open-late-close-witness",
        "requestSequence": 1,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
    let workerOpenAdmission = await installation.session.beginControl(
        exactRequestBytes: try JSONEncoder().encode(workerOpenRequest),
        presentedCapability: try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        ),
        productAdmission: productAdmission
    )
    guard case .execute(let workerOpenToken, _) = workerOpenAdmission else {
        throw DiffLoadWitnessError.expectedWorkerSessionExecution
    }
    let admitted = try await installation.session.admitControlOperation(token: workerOpenToken) { _ in }
    let workerOpenResponse = try BridgeProductControlResponse.workerSessionAccepted(
        correlating: workerOpenRequest
    )
    _ = try await installation.session.completeControl(
        token: workerOpenToken,
        exactResponseBytes: try JSONEncoder().encode(workerOpenResponse)
    )
    await installation.session.settleOperation(
        operationId: admitted.operationId,
        response: workerOpenResponse
    )
    await installation.session.waitForOperationExecution(operationId: admitted.operationId)

    let metadataRequest = try diffLoadWitnessMetadataRequest(installation: installation)
    let registration = await installation.session.registerMetadataProducer(
        request: metadataRequest,
        productAdmission: productAdmission
    ) { lease in
        await productProvider.runMetadataProducer(
            request: metadataRequest,
            lease: lease,
            productAdmission: productAdmission,
            session: installation.session
        )
    }
    guard case .accepted(let lease) = registration else {
        throw DiffLoadWitnessError.expectedMetadataProducerRegistration
    }
    _ = await consumeNextBridgeProductProducerFrame(
        for: lease,
        from: installation.session,
        productAdmission: productAdmission
    )
    return lease
}

private func diffLoadWitnessControlRequest(
    _ object: [String: Any]
) throws -> BridgeProductControlRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductControlRequest.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

private func diffLoadWitnessMetadataRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductMetadataStreamRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductMetadataStreamRequest.self,
        from: JSONSerialization.data(
            withJSONObject: [
                "kind": "metadataStream.open",
                "metadataStreamId": "metadata-late-close-witness",
                "paneSessionId": installation.bootstrap.paneSessionId,
                "resumeFromStreamSequence": NSNull(),
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ],
            options: [.sortedKeys]
        )
    )
}

private func isDiffLoadWitnessEvent(_ envelope: RuntimeEnvelope) -> Bool {
    guard case .pane(let paneEnvelope) = envelope,
        case .diff(.diffLoaded) = paneEnvelope.event
    else {
        return false
    }
    return true
}
