import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgeProductRealGitFileAndReviewWebKitTests {
        struct LiveProof {
            let fileDOMAfterFileSwitch: BridgeProductWebKitCarrierDOMSnapshot
            let fileModeActivated: Bool
            let filePathSelected: Bool
            let initialReviewGeneration: Int
            let native: BridgeProductWebKitCarrierNativeSnapshot
            let reviewDOMBeforeFileSwitch: BridgeProductWebKitCarrierDOMSnapshot
            let reviewMetadataItemCount: Int
            let reviewSelectedContentHashes: String
            let sourceOracle: LiveSourceOracle
            let successorReviewGeneration: Int
            let trace: BridgeProductWebKitCarrierTrace
        }

        struct LiveReviewMetadataDOMSnapshot: Decodable {
            let itemCount: Int
            let reviewGeneration: Int
        }

        struct LiveSourceOracle {
            let canaryText: String
            let path: String
        }

        enum LiveProofError: Error {
            case initialReviewPublicationMissing
            case successorReviewPublicationMissing
        }

        struct TransactionalPublicationHarness {
            let controller: BridgePaneController
            let controllerTarget: BridgeProductWebKitCarrierControllerTarget
            let fileMetadataSource: BridgeWebKitTrackingFileMetadataSource
            let installation: BridgeProductSessionInstallation
            let productAdmission: BridgeProductAdmissionContext
            let reviewMetadataSource: BridgeWebKitFailingReviewMetadataSource
            let traceRecorder: BridgeProductWebKitCarrierTraceRecorder
        }

        struct FirstPublicationCheckpoint {
            let fileSnapshot: BridgeProductWebKitCarrierFileSubscriptionSnapshot
            let nativeSnapshot: BridgeProductWebKitCarrierNativeSnapshot
            let publication: BridgeReviewCommittedPublication
            let retiringLease: BridgeReviewContentAuthorityLease
            let reviewSnapshot: BridgeProductWebKitCarrierReviewMetadataSnapshot
            let trace: BridgeProductWebKitCarrierTrace
        }

        private struct TransactionalControllerInput {
            let committedCallTarget: BridgePaneProductCommittedCallTarget
            let installation: BridgeProductSessionInstallation
            let paneId: UUID
            let productAdmissionGate: BridgeProductAdmissionGate
            let productProvider: BridgePaneProductSchemeProvider
            let repoId: UUID
            let repoURL: URL
            let traceRecorder: BridgeProductWebKitCarrierTraceRecorder
            let worktreeId: UUID
        }

        private struct TransactionalPublicationProof {
            let applicationReceiptsAfterReplay: [BridgeProductWebKitCarrierApplicationReceipt]
            let applicationReceiptsBeforeReplay: [BridgeProductWebKitCarrierApplicationReceipt]
            let fileAfterFailure: BridgeProductWebKitCarrierFileSubscriptionSnapshot
            let fileBeforeFailure: BridgeProductWebKitCarrierFileSubscriptionSnapshot
            let finalPublicationState: BridgeReviewPublicationStateSnapshot
            let firstPublication: BridgeReviewCommittedPublication
            let nativeAfterFailure: BridgeProductWebKitCarrierNativeSnapshot
            let nativeBeforeFailure: BridgeProductWebKitCarrierNativeSnapshot
            let reviewAfterFailure: BridgeProductWebKitCarrierReviewMetadataSnapshot
            let reviewBeforeFailure: BridgeProductWebKitCarrierReviewMetadataSnapshot
            let retiringPublicationState: BridgeReviewPublicationStateSnapshot
            let secondPublication: BridgeReviewCommittedPublication
            let traceAfterFailure: BridgeProductWebKitCarrierTrace
            let traceBeforeFailure: BridgeProductWebKitCarrierTrace
        }

        private enum TransactionalPublicationTestError: Error {
            case initialPublicationDidNotApply
            case metadataSubscriptionsDidNotOpen
            case publicationFailureDidNotReopenReview
            case replayDidNotApply
        }

        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("bundled comm worker carries real-git File and Review product data through production WebKit")
        func bundledWorkerCarriesRealGitFileAndReviewProductData() async throws {
            // Arrange
            let repoURL = try await FilesystemTestGitRepo.create(named: "bridge-product-file-review-webkit")
            defer { FilesystemTestGitRepo.destroy(repoURL) }
            try await seedHeavyReviewChanges(at: repoURL, trackedFileCount: 128)
            let sourceOracle = LiveSourceOracle(canaryText: "updated", path: "tracked.txt")
            let traceRecorder = BridgeProductWebKitCarrierTraceRecorder()
            let controller = makeController(
                repoURL: repoURL,
                traceRecorder: traceRecorder
            )

            // Act
            let run = try await collectLiveProof(
                controller: controller,
                sourceOracle: sourceOracle,
                traceRecorder: traceRecorder
            )

            // Assert
            assertProof(run)
        }

        @Test("Review publication failure replays committed B without replacing File or the pane worker")
        func reviewPublicationFailureReplaysCommittedBWithoutReplacingFileOrWorker() async throws {
            // Arrange
            let repoURL = try await FilesystemTestGitRepo.create(named: "bridge-product-review-replay-webkit")
            defer { FilesystemTestGitRepo.destroy(repoURL) }
            try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repoURL)
            try seedMultiWindowReviewChanges(at: repoURL)
            let harness = makeTransactionalPublicationHarness(repoURL: repoURL)

            // Act
            let run = try await collectTransactionalPublicationProof(
                harness: harness,
                repoURL: repoURL
            )

            // Assert
            assertTransactionalPublicationProof(run)
        }

        @Test("two hosted panes isolate native hidden admission and retain worker state")
        func twoHostedPanesIsolateHiddenAdmissionAndRetainWorkerState() async throws {
            // Arrange / Act
            let proof = try await BridgeProductWebKitTwoPaneJourneyTestSupport.run()

            // Assert
            #expect(proof.dormantDefaults.activeMode == "review")
            #expect(proof.dormantDefaults.reviewSelectedPath == nil)
            #expect(proof.staleForegroundAdmissionWasRejected)
            #expect(proof.hiddenStatus.fileStatusText == nil)
            #expect(proof.hiddenStatus.reviewStatusText == nil)
            #expect(proof.hiddenDirtyGeneration != nil)
            #expect(proof.hiddenRefreshPassCountAfterStorm == proof.hiddenRefreshPassCountBeforeStorm)
            // The metadata stream sequence also counts protocol acknowledgements,
            // which must keep flowing while a pane is hidden or the page's
            // subscription.update() promise strands. So the isolation invariant is
            // stated on the product frames a hidden pane must not admit.
            #expect(
                proof.hiddenStormProductDeltas.panePresentationEventCount == 0,
                Comment(rawValue: proof.hiddenMetadataStormDiagnostic)
            )
            #expect(
                proof.hiddenStormProductDeltas.fileMetadataPhaseCount == 0,
                Comment(rawValue: proof.hiddenMetadataStormDiagnostic)
            )
            #expect(
                proof.hiddenStormProductDeltas.reviewMetadataPhaseCount == 0,
                Comment(rawValue: proof.hiddenMetadataStormDiagnostic)
            )
            #expect(
                proof.hiddenReviewPublicationCountAfterLateRelease
                    == proof.hiddenReviewPublicationCountBeforeLateRelease
            )
            // The causal File-only invalidation after switching surfaces contributes one
            // additional pass beyond the initial Review + hidden/foreground recovery.
            #expect(proof.paneOneFinalRefreshPassCount == proof.paneOneForegroundRefreshPassCount + 3)
            #expect(proof.updatingReviewStatus.comparisonStatusText == nil)
            #expect(proof.updatingReviewStatus.reviewStatusText == nil)
            #expect(proof.updatingReviewStatus.fileStatusText == nil)
            #expect(proof.updatingFileStatus.fileStatusText == "Updating files…")
            #expect(proof.updatingFileStatus.reviewStatusText == nil)
            #expect(proof.paneOneWorkerIdBeforeHide == proof.paneOneWorkerIdAfterReturn)
            #expect(proof.paneOneWorkerIdAfterReturn != proof.paneTwoWorkerIdAfterJourney)
            #expect(proof.paneTwoWorkerIdBeforeJourney == proof.paneTwoWorkerIdAfterJourney)
            #expect(proof.paneTwoActivityAfterJourney == .foreground)
            #expect(proof.paneTwoStateAfterJourney.activeMode == proof.paneTwoStateBeforeJourney.activeMode)
            #expect(
                proof.paneTwoStateAfterJourney.reviewSelectedItemId
                    == proof.paneTwoStateBeforeJourney.reviewSelectedItemId
            )
            #expect(
                proof.paneTwoStateAfterJourney.reviewSelectedPath
                    == proof.paneTwoStateBeforeJourney.reviewSelectedPath
            )
            #expect(
                proof.reviewStateAfterReturn.reviewSelectedItemId
                    == proof.initialReviewState.reviewSelectedItemId
            )
            #expect(
                proof.reviewStateAfterReturn.reviewSelectedPath
                    == proof.initialReviewState.reviewSelectedPath
            )
            #expect(proof.fileStateAfterReturn.activeMode == "file")
        }

        @Test("native named surfaces retain independent hosted File and Review state")
        func nativeNamedSurfacesRetainIndependentHostedFileAndReviewState() async throws {
            // Arrange / Act
            let proof = try await BridgeProductWebKitSurfaceJourneyTestSupport.run()

            // Assert
            BridgeProductWebKitSurfaceJourneyTestSupport.assertProof(proof)
        }

        func makeTransactionalPublicationHarness(
            repoURL: URL
        ) -> TransactionalPublicationHarness {
            let paneId = UUIDv7.generate()
            let repoId = UUIDv7.generate()
            let worktreeId = UUIDv7.generate()
            let traceRecorder = BridgeProductWebKitCarrierTraceRecorder()
            let controllerTarget = BridgeProductWebKitCarrierControllerTarget()
            let fileMetadataSource = makeTrackingFileMetadataSource(
                paneId: paneId,
                repoId: repoId,
                repoURL: repoURL,
                worktreeId: worktreeId
            )
            let reviewMetadataSource = BridgeWebKitFailingReviewMetadataSource()
            let productAdmissionGate = BridgeProductAdmissionGate()
            let (productProvider, committedCallTarget) = makeTransactionalProductProvider(
                controllerTarget: controllerTarget,
                fileMetadataSource: fileMetadataSource,
                reviewMetadataSource: reviewMetadataSource,
                productAdmissionGate: productAdmissionGate,
                traceRecorder: traceRecorder
            )
            let installation = BridgePaneController.makeInitialProductSessionInstallation(
                paneSessionId: paneId.uuidString,
                provider: productProvider,
                productAdmissionGate: productAdmissionGate
            )
            let controller = makeTransactionalController(
                TransactionalControllerInput(
                    committedCallTarget: committedCallTarget,
                    installation: installation,
                    paneId: paneId,
                    productAdmissionGate: productAdmissionGate,
                    productProvider: productProvider,
                    repoId: repoId,
                    repoURL: repoURL,
                    traceRecorder: traceRecorder,
                    worktreeId: worktreeId
                )
            )
            controllerTarget.install(controller)
            return TransactionalPublicationHarness(
                controller: controller,
                controllerTarget: controllerTarget,
                fileMetadataSource: fileMetadataSource,
                installation: installation,
                productAdmission: productAdmissionGate.acquire()!,
                reviewMetadataSource: reviewMetadataSource,
                traceRecorder: traceRecorder
            )
        }

        private func makeTrackingFileMetadataSource(
            paneId: UUID,
            repoId: UUID,
            repoURL: URL,
            worktreeId: UUID
        ) -> BridgeWebKitTrackingFileMetadataSource {
            BridgeWebKitTrackingFileMetadataSource(
                source: BridgePaneProductFileMetadataSource(
                    authority: BridgePaneProductFileSourceAuthority(
                        paneId: paneId,
                        worktree: Worktree(
                            id: worktreeId,
                            repoId: repoId,
                            name: "bridge-product-review-replay",
                            path: repoURL
                        )
                    ),
                    gitReadContext: makeBridgeGitReadContext(rootURL: repoURL),
                    constructionCoordinator: BridgeWorktreeProductConstructionCoordinator(),
                    statusProvider: AgentStudioGitWorkingTreeStatusProvider(
                        physicalGate: AgentStudioGitStatusPhysicalGate()
                    )
                )
            )
        }

        private func makeTransactionalProductProvider(
            controllerTarget: BridgeProductWebKitCarrierControllerTarget,
            fileMetadataSource: BridgeWebKitTrackingFileMetadataSource,
            reviewMetadataSource: BridgeWebKitFailingReviewMetadataSource,
            productAdmissionGate: BridgeProductAdmissionGate,
            traceRecorder: BridgeProductWebKitCarrierTraceRecorder
        ) -> (BridgePaneProductSchemeProvider, BridgePaneProductCommittedCallTarget) {
            let committedCallTarget = BridgePaneProductCommittedCallTarget(
                productAdmissionGate: productAdmissionGate
            )
            let refreshWorkAdmission =
                BridgePaneRefreshWorkAdmissionTestContext.foregroundOnMainActor()
            let provider = BridgePaneProductSchemeProvider(
                fileMetadataSource: fileMetadataSource,
                reviewMetadataSource: reviewMetadataSource,
                reviewContentSource: BridgeProductWebKitCarrierReviewContentRelay(
                    target: controllerTarget
                ),
                reviewPublicationReplay: { productAdmission in
                    controllerTarget.committedPublication(productAdmission: productAdmission)
                },
                isReviewPublicationCurrent: { publicationId, productAdmission in
                    controllerTarget.isCurrentPublication(
                        publicationId,
                        productAdmission: productAdmission
                    )
                },
                admitReviewPublicationInstallation: { request, correlation, productAdmission in
                    controllerTarget.controller?.reviewPublicationCoordinator.admitDisplayInstallation(
                        expectedDisplayedPublicationId: request.expectedDisplayedPublicationId,
                        candidatePublicationId: request.candidatePublicationId,
                        workerInstanceId: correlation.workerInstanceId,
                        productAdmission: productAdmission
                    ) ?? .rejected
                },
                recordReviewPublicationApplication: { publicationId, correlation, productAdmission in
                    controllerTarget.recordApplication(
                        publicationId,
                        workerInstanceId: correlation.workerInstanceId,
                        productAdmission: productAdmission
                    )
                },
                markReviewItemViewed: { itemId, productAdmission in
                    _ = productAdmission.withValidAdmission {
                        controllerTarget.controller?.runtime.paneState.review.markFileViewed(itemId)
                    }
                },
                handleReviewIntakeReady: { request, productAdmission in
                    await committedCallTarget.applyReviewIntakeReady(
                        request,
                        productAdmission: productAdmission
                    )
                },
                applyActiveViewerModeUpdate: { call, correlation, productAdmission in
                    await committedCallTarget.applyActiveViewerModeUpdate(
                        call,
                        correlation: correlation,
                        productAdmission: productAdmission
                    )
                },
                refreshWorkAdmissionSource: refreshWorkAdmission.source,
                lifecycleTraceRecorder: BridgeProductMetadataLifecycleTraceRecorder(
                    recorder: traceRecorder
                )
            )
            return (provider, committedCallTarget)
        }

        private func makeTransactionalController(
            _ input: TransactionalControllerInput
        ) -> BridgePaneController {
            let gitReadContext = makeBridgeGitReadContext(rootURL: input.repoURL)
            return BridgePaneController(
                paneId: input.paneId,
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: input.repoURL.path,
                        baseline: .localDefaultBranch(branchName: "main")
                    )
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    paneId: PaneId(existingUUID: input.paneId),
                    contentType: .diff,
                    launchDirectory: input.repoURL,
                    title: "Bridge Product Review Replay",
                    facets: PaneContextFacets(
                        repoId: input.repoId,
                        worktreeId: input.worktreeId,
                        worktreeName: "bridge-product-review-replay",
                        cwd: input.repoURL
                    )
                ),
                reviewSourceProvider: BridgeReviewSourceProviderFactory.gitProvider(
                    repositoryPath: input.repoURL,
                    gitReadContext: gitReadContext,
                    statusPhysicalGate: AgentStudioGitStatusPhysicalGate()
                ),
                gitReadContext: gitReadContext,
                telemetryRuntimePolicy: .live,
                telemetryScopeGate: BridgeTelemetryScopeGate(enabledScopes: []),
                telemetryRecorder: input.traceRecorder,
                initialPaneActivity: .foreground,
                productSessionDependencies: BridgePaneProductSessionDependencies(
                    installation: input.installation,
                    owner: BridgePaneController.makeProductSessionOwner(
                        paneSessionId: input.paneId.uuidString,
                        provider: input.productProvider,
                        productAdmissionGate: input.productAdmissionGate,
                        activeInstallation: input.installation
                    ),
                    committedCallTarget: input.committedCallTarget,
                    productProvider: input.productProvider
                )
            )
        }

        private func collectTransactionalPublicationProof(
            harness: TransactionalPublicationHarness,
            repoURL: URL
        ) async throws -> BridgeProductWebKitCarrierRunResult<TransactionalPublicationProof> {
            try await BridgeProductWebKitCarrierTestSupport.withHostedController(
                harness.controller
            ) { controller in
                controller.loadApp()
                try await waitForMetadataSubscriptions(harness)
                let firstCheckpoint = try await prepareFirstPublicationCheckpoint(
                    controller: controller,
                    harness: harness
                )
                return try await exerciseFailedPublicationAndReplay(
                    controller: controller,
                    firstCheckpoint: firstCheckpoint,
                    harness: harness,
                    repoURL: repoURL
                )
            }
        }

        func waitForMetadataSubscriptions(
            _ harness: TransactionalPublicationHarness
        ) async throws {
            guard
                await BridgeProductWebKitCarrierTestSupport.waitUntil(
                    timeout: .seconds(15),
                    condition: {
                        let fileSnapshot = await harness.fileMetadataSource.snapshot()
                        let reviewSnapshot = await harness.reviewMetadataSource.snapshot()
                        return !fileSnapshot.openedSubscriptions.isEmpty
                            && !reviewSnapshot.openedSubscriptions.isEmpty
                    })
            else {
                throw TransactionalPublicationTestError.metadataSubscriptionsDidNotOpen
            }
        }

        func prepareFirstPublicationCheckpoint(
            controller: BridgePaneController,
            harness: TransactionalPublicationHarness
        ) async throws -> FirstPublicationCheckpoint {
            guard
                await BridgeProductWebKitCarrierTestSupport.waitUntil(
                    timeout: .seconds(15),
                    condition: {
                        harness.controllerTarget.applicationReceipts.filter {
                            $0.applicationResult == .advanced
                        }.count == 1
                    }),
                let publication = harness.controllerTarget.committedPublication(
                    productAdmission: harness.productAdmission
                ),
                let firstHandle = publication.contentHandles.first,
                let retiringLease = controller.reviewPublicationCoordinator.acquireContentLease(
                    handleId: firstHandle.handleId,
                    packageId: publication.package.packageId,
                    requestedGeneration: publication.package.reviewGeneration,
                    sourceIdentity: publication.package.query.queryId,
                    productAdmission: harness.productAdmission
                )
            else {
                throw TransactionalPublicationTestError.initialPublicationDidNotApply
            }
            await harness.reviewMetadataSource.armFailure(after: publication.publicationId)
            return FirstPublicationCheckpoint(
                fileSnapshot: await harness.fileMetadataSource.snapshot(),
                nativeSnapshot: await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(
                    controller
                ),
                publication: publication,
                retiringLease: retiringLease,
                reviewSnapshot: await harness.reviewMetadataSource.snapshot(),
                trace: await harness.traceRecorder.scrubbedTrace()
            )
        }

        private func exerciseFailedPublicationAndReplay(
            controller: BridgePaneController,
            firstCheckpoint: FirstPublicationCheckpoint,
            harness: TransactionalPublicationHarness,
            repoURL: URL
        ) async throws -> TransactionalPublicationProof {
            try "publication B\n".write(
                to: repoURL.appending(path: "bridge-window-000.txt"),
                atomically: true,
                encoding: .utf8
            )
            controller.scheduleReviewPackageReloadForProductResync(reason: .productResync)
            guard await harness.reviewMetadataSource.waitForReplayFailureState(timeout: .seconds(15)) else {
                let reviewFailure = await harness.reviewMetadataSource.snapshot()
                let nativeFailure = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(controller)
                Issue.record(
                    """
                    Review replay wait failed: status=\(controller.paneState.diff.status), \
                    corrupted=\(reviewFailure.didCorruptFinalWindow), held=\(reviewFailure.replayIsBlocked), \
                    opens=\(reviewFailure.openedSubscriptions.count), cancels=\(reviewFailure.cancelledSubscriptionIds.count), \
                    deliveryGenerations=\(reviewFailure.deliveryAttempts.map { $0.package.reviewGeneration.rawValue }), \
                    successorEvents=\(reviewFailure.successorEventKinds), native=\(nativeFailure)
                    """
                )
                await harness.reviewMetadataSource.releaseReplay()
                throw TransactionalPublicationTestError.publicationFailureDidNotReopenReview
            }
            guard
                let secondPublication = harness.controllerTarget.committedPublication(
                    productAdmission: harness.productAdmission
                ), secondPublication.publicationId != firstCheckpoint.publication.publicationId
            else {
                Issue.record("Review replay was held but its committed successor was missing")
                await harness.reviewMetadataSource.releaseReplay()
                throw TransactionalPublicationTestError.publicationFailureDidNotReopenReview
            }
            let receiptsBeforeReplay = harness.controllerTarget.applicationReceipts
            let fileAfterFailure = await harness.fileMetadataSource.snapshot()
            let reviewAfterFailure = await harness.reviewMetadataSource.snapshot()
            let nativeAfterFailure = await BridgeProductWebKitCarrierTestSupport.nativeSnapshot(
                controller
            )
            let retiringState = controller.reviewPublicationCoordinator.diagnosticSnapshot
            let traceAfterFailure = await harness.traceRecorder.scrubbedTrace()
            await harness.reviewMetadataSource.releaseReplay()
            guard
                await harness.controllerTarget.waitForAcceptedApplication(
                    publicationId: secondPublication.publicationId,
                    timeout: .seconds(15)
                )
            else {
                throw TransactionalPublicationTestError.replayDidNotApply
            }
            let receiptsAfterReplay = harness.controllerTarget.applicationReceipts
            _ = controller.reviewPublicationCoordinator.settleContentLease(
                firstCheckpoint.retiringLease
            )
            let finalState = controller.reviewPublicationCoordinator.diagnosticSnapshot
            return TransactionalPublicationProof(
                applicationReceiptsAfterReplay: receiptsAfterReplay,
                applicationReceiptsBeforeReplay: receiptsBeforeReplay,
                fileAfterFailure: fileAfterFailure,
                fileBeforeFailure: firstCheckpoint.fileSnapshot,
                finalPublicationState: finalState,
                firstPublication: firstCheckpoint.publication,
                nativeAfterFailure: nativeAfterFailure,
                nativeBeforeFailure: firstCheckpoint.nativeSnapshot,
                reviewAfterFailure: reviewAfterFailure,
                reviewBeforeFailure: firstCheckpoint.reviewSnapshot,
                retiringPublicationState: retiringState,
                secondPublication: secondPublication,
                traceAfterFailure: traceAfterFailure,
                traceBeforeFailure: firstCheckpoint.trace
            )
        }

        private func assertTransactionalPublicationProof(
            _ run: BridgeProductWebKitCarrierRunResult<TransactionalPublicationProof>
        ) {
            let proof = run.value
            let firstPublicationId = proof.firstPublication.publicationId
            let secondPublicationId = proof.secondPublication.publicationId
            assertReviewApplicationReceiptAdvances(
                proof.applicationReceiptsBeforeReplay,
                expectedPublicationIds: [firstPublicationId]
            )
            #expect(
                proof.applicationReceiptsBeforeReplay.allSatisfy { $0.publicationId != secondPublicationId },
                "transport-acknowledged invalid B must not produce an application receipt"
            )
            assertReviewApplicationReceiptAdvances(
                proof.applicationReceiptsAfterReplay,
                expectedPublicationIds: [firstPublicationId, secondPublicationId]
            )
            #expect(proof.reviewAfterFailure.didCorruptFinalWindow)
            #expect(proof.reviewAfterFailure.corruptedPublicationId == secondPublicationId)
            #expect(
                proof.reviewAfterFailure.openedSubscriptions.count
                    == proof.reviewBeforeFailure.openedSubscriptions.count + 1
            )
            #expect(
                proof.reviewAfterFailure.cancelledSubscriptionIds.count
                    == proof.reviewBeforeFailure.cancelledSubscriptionIds.count + 1
            )
            #expect(
                proof.reviewAfterFailure.deliveryAttempts.suffix(2).allSatisfy {
                    $0.publicationId == secondPublicationId
                        && $0.package == proof.secondPublication.package
                },
                "Review reopen must replay the exact committed B publication and payload"
            )
            #expect(proof.fileAfterFailure == proof.fileBeforeFailure)
            #expect(
                proof.nativeAfterFailure.fileWorkerDerivationEpoch
                    == proof.nativeBeforeFailure.fileWorkerDerivationEpoch
            )
            #expect(
                proof.nativeAfterFailure.workerInstanceId
                    == proof.nativeBeforeFailure.workerInstanceId
            )
            #expect(
                proof.traceAfterFailure.completedReviewPublicationCount
                    == proof.traceBeforeFailure.completedReviewPublicationCount + 1,
                "the invalid first B delivery must be transport-observed before worker application fails"
            )
            #expect(
                proof.retiringPublicationState.active?.publicationId == secondPublicationId
            )
            #expect(
                proof.retiringPublicationState.retiring.map(\.publicationId)
                    == [firstPublicationId]
            )
            #expect(proof.finalPublicationState.active?.publicationId == secondPublicationId)
            #expect(proof.finalPublicationState.retiring.isEmpty)
            #expect(run.teardownSnapshot.hasZeroResidue)
        }

        func seedMultiWindowReviewChanges(at repoURL: URL) throws {
            for index in 0..<70 {
                let filename = String(format: "bridge-window-%03d.txt", index)
                try "publication A \(index)\n".write(
                    to: repoURL.appending(path: filename),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        private func seedHeavyReviewChanges(
            at repoURL: URL,
            trackedFileCount: Int
        ) async throws {
            precondition(trackedFileCount >= 128)
            let trackedPaths =
                ["tracked.txt"]
                + (1..<trackedFileCount).map { index in
                    String(format: "zz-heavy-review-%03d.txt", index)
                }
            for (index, path) in trackedPaths.enumerated() {
                try "initial \(index)\n".write(
                    to: repoURL.appending(path: path),
                    atomically: true,
                    encoding: .utf8
                )
            }
            try await FilesystemTestGitRepo.runGit(at: repoURL, args: ["add"] + trackedPaths)
            try await FilesystemTestGitRepo.runGit(
                at: repoURL,
                args: ["commit", "-m", "Seed heavy Review fixture"]
            )
            for (index, path) in trackedPaths.enumerated() {
                try "initial \(index)\nupdated \(index)\n".write(
                    to: repoURL.appending(path: path),
                    atomically: true,
                    encoding: .utf8
                )
            }
            try "new file\n".write(
                to: repoURL.appending(path: "untracked.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        func makeController(
            repoURL: URL,
            traceRecorder: BridgeProductWebKitCarrierTraceRecorder,
            worktreeAnnotationStore: WorktreeAnnotationServiceActor? = nil,
            worktreeAnnotationOutputCoordinator: WorktreeAnnotationOutputCoordinatorActor? = nil
        ) -> BridgePaneController {
            let paneId = UUIDv7.generate()
            let gitReadContext = makeBridgeGitReadContext(rootURL: repoURL)
            let statusPhysicalGate = AgentStudioGitStatusPhysicalGate()
            return BridgePaneController(
                paneId: paneId,
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: repoURL.path,
                        baseline: .localDefaultBranch(branchName: "main")
                    )
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    paneId: PaneId(existingUUID: paneId),
                    contentType: .diff,
                    launchDirectory: repoURL,
                    title: "Bridge Product Carrier",
                    facets: PaneContextFacets(
                        repoId: UUIDv7.generate(),
                        worktreeId: UUIDv7.generate(),
                        worktreeName: "bridge-product-carrier",
                        cwd: repoURL
                    )
                ),
                reviewSourceProvider: BridgeReviewSourceProviderFactory.gitProvider(
                    repositoryPath: repoURL,
                    gitReadContext: gitReadContext,
                    statusPhysicalGate: statusPhysicalGate
                ),
                gitReadContext: gitReadContext,
                worktreeProductConstructionCoordinator: BridgeWorktreeProductConstructionCoordinator(),
                worktreeAnnotationStore: worktreeAnnotationStore,
                worktreeAnnotationOutputCoordinator: worktreeAnnotationOutputCoordinator,
                gitWorkingTreeStatusProvider: AgentStudioGitWorkingTreeStatusProvider(
                    physicalGate: statusPhysicalGate
                ),
                telemetryRuntimePolicy: .live,
                telemetryScopeGate: BridgeTelemetryScopeGate(enabledScopes: []),
                telemetryRecorder: traceRecorder,
                initialPaneActivity: .foreground
            )
        }

        func reviewMetadataDOMSnapshot(
            _ controller: BridgePaneController
        ) async -> LiveReviewMetadataDOMSnapshot? {
            do {
                let encodedSnapshot = try await controller.page.callJavaScript(
                    """
                    const shell = document.querySelector('[data-testid="review-viewer-shell"]');
                    return JSON.stringify({
                      itemCount: Number(shell?.getAttribute('data-review-metadata-item-count') ?? '0'),
                      reviewGeneration: Number(shell?.getAttribute('data-review-metadata-generation') ?? '0')
                    });
                    """
                )
                guard let encodedSnapshot = encodedSnapshot as? String,
                    let snapshotData = encodedSnapshot.data(using: .utf8)
                else {
                    return nil
                }
                return try JSONDecoder().decode(
                    LiveReviewMetadataDOMSnapshot.self,
                    from: snapshotData
                )
            } catch {
                return nil
            }
        }

        private func assertProof(
            _ run: BridgeProductWebKitCarrierRunResult<LiveProof>
        ) {
            let fileDOM = run.value.fileDOMAfterFileSwitch
            let reviewDOM = run.value.reviewDOMBeforeFileSwitch
            #expect(
                reviewDOM.hasAppRoot && fileDOM.hasAppRoot,
                "W0 product seam: the current bundled BridgeWeb app did not mount"
            )
            #expect(
                run.value.native.lifecycle == "active",
                "W0 product seam: the bundled worker did not open the production product session; native=\(run.value.native)"
            )
            #expect(
                run.value.trace.hasCanonicalEagerSubscriptions,
                "W0 product seam: the worker did not open canonical eager File+Review subscriptions; trace=\(run.value.trace)"
            )
            #expect(
                run.value.trace.hasFileMetadataWindow,
                "W0 product seam: production agentstudio-git File metadata did not reach the worker stream; trace=\(run.value.trace)"
            )
            #expect(
                run.value.trace.hasReviewMetadataPublication,
                "W0 product seam: production agentstudio-git Review metadata did not reach the worker stream; trace=\(run.value.trace)"
            )
            #expect(
                run.value.reviewMetadataItemCount >= 128,
                "W0 product seam: the worker did not publish the complete heavy Review metadata set; itemCount=\(run.value.reviewMetadataItemCount), trace=\(run.value.trace)"
            )
            #expect(
                run.value.successorReviewGeneration > run.value.initialReviewGeneration,
                "W0 product seam: the production refresh did not replace the initial Review publication; initialGeneration=\(run.value.initialReviewGeneration), successorGeneration=\(run.value.successorReviewGeneration)"
            )
            #expect(
                run.value.native.nextControlRequestSequence > 1,
                "W0 product seam: worker-initiated product command POSTs were not acknowledged; native=\(run.value.native)"
            )
            #expect(
                run.value.native.nextMetadataStreamSequence > 1,
                "W0 product seam: streamed metadata frames and bodyless observations did not advance; native=\(run.value.native)"
            )
            #expect(
                run.value.native.inFlightControlRequestSequence == nil,
                "W0 product seam: a product command remained in flight; native=\(run.value.native)"
            )
            #expect(
                reviewDOM.hasReviewModeHost && fileDOM.hasFileModeHost,
                "W0 product seam: the canonical File+Review viewer hosts were not both constructed; reviewDOM=\(reviewDOM), fileDOM=\(fileDOM)"
            )
            #expect(
                reviewDOM.hasReviewShell,
                "W0 construction seam: Review metadata crossed the worker but no product Review shell mounted; reviewDOM=\(reviewDOM), trace=\(run.value.trace)"
            )
            #expect(
                reviewDOM.hasReviewCodeViewPanel
                    && reviewDOM.reviewSelectedContentState == "ready"
                    && reviewDOM.reviewSelectedContentLineCount > 0
                    && reviewDOM.reviewSelectedContentHashes
                        == run.value.reviewSelectedContentHashes,
                "W0 content-observation seam: Swift emitted successor Review content, but the worker did not acknowledge and drain it into a ready CodeView; reviewDOM=\(reviewDOM), native=\(run.value.native), host=\(run.hostSnapshot)"
            )
            #expect(
                reviewDOM.reviewSelectedDisplayPath == run.value.sourceOracle.path,
                "G0 PACKAGED SELECTED IDENTITY MISSING: selected Review path did not match the live-git oracle; selected=\(reviewDOM.reviewSelectedDisplayPath ?? "missing"), expected=\(run.value.sourceOracle.path)"
            )
            #expect(
                reviewDOM.reviewRenderedItemId?.isEmpty == false,
                "G0 PACKAGED SEMANTIC ITEM MISSING: rendered Review item did not retain its canonical semantic identity"
            )
            #expect(
                run.value.fileModeActivated,
                "G0 PACKAGED FILE MODE MISSING: the real bundled File control was not available"
            )
            #expect(
                run.value.filePathSelected,
                "G0 PACKAGED FILE SELECTION MISSING: File mode did not select the live-git source through the real tree"
            )
            #expect(
                fileDOM.fileReadableText.contains(run.value.sourceOracle.canaryText),
                "W0 content-observation seam: File readable DOM did not contain the real-git canary"
            )
            #expect(
                run.teardownSnapshot.hasZeroResidue,
                "W0 teardown seam: production product session retained transport residue; snapshot=\(run.teardownSnapshot)"
            )
        }

    }
}
