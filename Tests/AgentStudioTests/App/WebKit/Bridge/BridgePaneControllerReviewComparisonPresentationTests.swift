import AgentStudioTestHarness
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
    struct BridgeReviewComparisonPresentationTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("committed comparison update adopts the canonical workspace target")
        func committedComparisonUpdateAdoptsCanonicalWorkspaceTarget() async throws {
            let target = WorkspaceReviewContributionTarget.branch(name: "stack/base")
            let canonicalState = BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: WorkspaceBaseline(contributionTarget: target)
                )
            )
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(rootPath: "/tmp/worktree", baseline: .branch(name: "main"))
                ),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .dormant,
                contributionTargetCommit: { _ in .applied(canonicalState) }
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            admitReviewComparisonIntent(
                workerDerivationEpoch: 1,
                controller: controller,
                productAdmission: productAdmission
            )

            let didAdopt = await controller.handleCommittedProductReviewComparisonUpdate(
                BridgeProductReviewComparisonUpdateRequest(target: target),
                workerDerivationEpoch: 1,
                productAdmission: productAdmission
            )

            #expect(controller.bridgePaneState == canonicalState)
            #expect(didAdopt == .applied)
            #expect(controller.productAdmissionGate.diagnosticSnapshot.isOpen)
        }

        @Test("unavailable comparison commit owner publishes a retryable Review failure")
        func unavailableComparisonCommitOwnerPublishesRetryableFailure() async throws {
            let currentTarget = WorkspaceReviewContributionTarget.branch(name: "review-a")
            let requestedTarget = WorkspaceReviewContributionTarget.branch(name: "review-b")
            let comparison = makeComparison()
            let controller = makeController(
                target: currentTarget,
                comparison: comparison,
                provider: makeContributionProvider(comparison: comparison),
                contributionTargetCommit: nil
            )
            let fixture = try await makeBridgeReviewComparisonControlFixture(controller: controller)
            defer {
                fixture.releaseAllHeldEffects()
                _ = controller.beginTeardown()  // fire-and-forget: defer fallback; success awaits finish().
            }
            try await fixture.openWorkerSession()
            let pageReviewBuilt = await showReviewPageAndAwaitInitialPackage(fixture)
            #expect(pageReviewBuilt)
            guard pageReviewBuilt else { return }

            let dispatch = try await fixture.dispatchComparisonUpdate(
                target: requestedTarget,
                requestSequence: 2,
                workerDerivationEpoch: 2
            )
            let operationResult = try await fixture.readOperationResult(for: dispatch)

            let comparisonAfterFailure = controller.refreshAdmissionCoordinator
                .productPresentationSnapshot.reviewComparison
            #expect(operationResult.outcome == .succeeded)
            #expect(comparisonAfterFailure?.activeTarget == requestedTarget)
            if let attempt = comparisonAfterFailure?.attempt,
                case .unavailable(let failureKind, let retryable) = attempt
            {
                #expect(failureKind == "targetCommitUnavailable")
                #expect(retryable)
            } else {
                Issue.record("Expected a retryable typed failure when the Review target commit owner is unavailable")
            }
            #expect(controller.productAdmissionGate.diagnosticSnapshot.isOpen)
            #expect(controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity != .closed)

            await fixture.finish()
            #expect(!controller.productAdmissionGate.diagnosticSnapshot.isOpen)
        }

        @Test("late completed comparison effect cannot overwrite the latest Review target")
        func lateCompletedComparisonEffectCannotOverwriteLatestTarget() async throws {
            let targetA = WorkspaceReviewContributionTarget.branch(name: "review-a")
            let targetB = WorkspaceReviewContributionTarget.branch(name: "review-b")
            let mainTarget = WorkspaceReviewContributionTarget.branch(name: "main")
            let stateA = paneState(for: targetA)
            let stateB = paneState(for: targetB)
            let mainState = paneState(for: mainTarget)
            let comparison = makeComparison()
            let sourceProvider = makeContributionProvider(comparison: comparison)
            let controller = makeController(
                target: targetA,
                comparison: comparison,
                provider: sourceProvider,
                contributionTargetCommit: { target in
                    if target == targetA { return .applied(stateA) }
                    if target == targetB { return .applied(stateB) }
                    if target == mainTarget { return .applied(mainState) }
                    return .unchanged(mainState)
                }
            )
            let fixture = try await makeBridgeReviewComparisonControlFixture(
                controller: controller,
                heldRequestSequences: [2]
            )
            defer {
                fixture.releaseHeldEffect(for: 2)
                _ = controller.beginTeardown()  // fire-and-forget: defer fallback; success awaits finish().
            }
            try await fixture.openWorkerSession()
            let pageReviewBuilt = await showReviewPageAndAwaitInitialPackage(fixture)
            #expect(pageReviewBuilt)
            guard pageReviewBuilt else { return }

            let effectADispatch = try await fixture.dispatchComparisonUpdate(
                target: targetA,
                requestSequence: 2,
                workerDerivationEpoch: 2
            )
            let heldEffect = try await fixture.firstHeldEffect(for: 2)
            guard case .productCall(.reviewComparisonUpdate(let update)) = heldEffect.effect else {
                Issue.record("Expected the held completion effect for Review target A")
                return
            }
            #expect(update.target == targetA)
            #expect(heldEffect.request.correlation.requestSequence == 2)
            #expect(heldEffect.request.workerDerivationEpoch == 2)

            let effectBDispatch = try await fixture.dispatchComparisonUpdate(
                target: targetB,
                requestSequence: 3,
                workerDerivationEpoch: 3
            )
            let effectBResult = try await fixture.readOperationResult(for: effectBDispatch)
            let mainDispatch = try await fixture.dispatchComparisonUpdate(
                target: mainTarget,
                requestSequence: 4,
                workerDerivationEpoch: 4
            )
            let mainResult = try await fixture.readOperationResult(for: mainDispatch)
            #expect(effectBResult.outcome == .succeeded)
            #expect(mainResult.outcome == .succeeded)
            #expect(controller.bridgePaneState == mainState)

            fixture.releaseHeldEffect(for: 2)
            guard case .response(let effectAAdmissionBytes) = effectADispatch else {
                Issue.record("Expected the held A operation admission")
                return
            }
            let effectAAdmission = try BridgeProductStrictJSON.decode(
                BridgeProductOperationAdmittedResponse.self,
                from: effectAAdmissionBytes
            )
            await fixture.session.waitForOperationExecution(operationId: effectAAdmission.operationId)
            #expect(controller.bridgePaneState == mainState)
            await fixture.finish()
        }

        @Test("a newer admitted Review intent fences an older effect while its effect is pending")
        func newerAdmittedReviewIntentFencesOlderEffectWhilePending() async throws {
            let lastGoodTarget = WorkspaceReviewContributionTarget.branch(name: "main")
            let targetA = WorkspaceReviewContributionTarget.branch(name: "review-a")
            let targetB = WorkspaceReviewContributionTarget.branch(name: "review-b")
            let mismatchedTarget = WorkspaceReviewContributionTarget.branch(name: "unexpected")
            let lastGoodState = paneState(for: lastGoodTarget)
            let stateA = paneState(for: targetA)
            let mismatchedState = paneState(for: mismatchedTarget)
            let comparison = makeComparison()
            let sourceProvider = makeContributionProvider(comparison: comparison)
            let controller = makeController(
                target: lastGoodTarget,
                comparison: comparison,
                provider: sourceProvider,
                contributionTargetCommit: { target in
                    if target == targetA { return .applied(stateA) }
                    if target == targetB { return .unchanged(mismatchedState) }
                    return .unchanged(lastGoodState)
                }
            )
            let fixture = try await makeBridgeReviewComparisonControlFixture(
                controller: controller,
                heldRequestSequences: [2, 3]
            )
            defer {
                fixture.releaseAllHeldEffects()
                _ = controller.beginTeardown()  // fire-and-forget: defer fallback; success awaits finish().
            }
            try await fixture.openWorkerSession()

            let pageReviewBuilt = await showReviewPageAndAwaitInitialPackage(fixture)
            #expect(pageReviewBuilt)
            guard pageReviewBuilt else { return }
            let lastGoodPackageId = try #require(controller.paneState.diff.packageMetadata?.packageId)

            let effectADispatch = try await fixture.dispatchComparisonUpdate(
                target: targetA,
                requestSequence: 2,
                workerDerivationEpoch: 2
            )
            _ = try await fixture.firstHeldEffect(for: 2)
            let effectBDispatch = try await fixture.dispatchComparisonUpdate(
                target: targetB,
                requestSequence: 3,
                workerDerivationEpoch: 3
            )
            let heldEffectB = try await fixture.firstHeldEffect(for: 3)
            #expect(heldEffectB.request.workerDerivationEpoch == 3)

            fixture.releaseHeldEffect(for: 2)
            let effectAResult = try await fixture.readOperationResult(for: effectADispatch)
            #expect(effectAResult.outcome == .succeeded)
            #expect(controller.bridgePaneState == lastGoodState)
            #expect(controller.paneState.diff.packageMetadata?.packageId == lastGoodPackageId)

            fixture.releaseHeldEffect(for: 3)
            guard case .response(let effectBAdmissionBytes) = effectBDispatch else {
                Issue.record("Expected the held B operation admission")
                return
            }
            let effectBAdmission = try BridgeProductStrictJSON.decode(
                BridgeProductOperationAdmittedResponse.self,
                from: effectBAdmissionBytes
            )
            await fixture.session.waitForOperationExecution(operationId: effectBAdmission.operationId)
            #expect(controller.bridgePaneState == lastGoodState)
            #expect(controller.paneState.diff.packageMetadata?.packageId == lastGoodPackageId)
            await fixture.finish()
        }

        @Test("a mismatched target fails only Review and a later target remains admitted")
        func mismatchedTargetDoesNotClosePaneAdmission() async throws {
            let targetA = WorkspaceReviewContributionTarget.branch(name: "review-a")
            let mismatchedTarget = WorkspaceReviewContributionTarget.branch(name: "review-b")
            let wrongCanonicalTarget = WorkspaceReviewContributionTarget.branch(name: "unexpected")
            let mainTarget = WorkspaceReviewContributionTarget.branch(name: "main")
            let stateA = paneState(for: targetA)
            let mismatchedState = paneState(for: wrongCanonicalTarget)
            let mainState = paneState(for: mainTarget)
            let comparison = makeComparison()
            let sourceProvider = makeContributionProvider(comparison: comparison)
            let controller = makeController(
                target: targetA,
                comparison: comparison,
                provider: sourceProvider,
                contributionTargetCommit: { target in
                    if target == targetA { return .applied(stateA) }
                    if target == mismatchedTarget { return .unchanged(mismatchedState) }
                    if target == mainTarget { return .applied(mainState) }
                    return .unchanged(mainState)
                }
            )
            let fixture = try await makeBridgeReviewComparisonControlFixture(controller: controller)
            defer {
                fixture.releaseAllHeldEffects()
                _ = controller.beginTeardown()  // fire-and-forget: defer fallback; success awaits finish().
            }
            try await fixture.openWorkerSession()

            let pageReviewBuilt = await showReviewPageAndAwaitInitialPackage(fixture)
            #expect(pageReviewBuilt)
            guard pageReviewBuilt else { return }
            let acceptedADispatch = try await fixture.dispatchComparisonUpdate(
                target: targetA,
                requestSequence: 2,
                workerDerivationEpoch: 2
            )
            let acceptedAResult = try await fixture.readOperationResult(for: acceptedADispatch)
            #expect(acceptedAResult.outcome == .succeeded)
            let acceptedATargetBuild = try #require(controller.activeReviewRefreshTask)
            await acceptedATargetBuild.value
            let packageA = try #require(controller.paneState.diff.packageMetadata)
            let lastGoodIdentity = BridgePaneReviewDisplayedSnapshotIdentity(
                packageId: packageA.packageId,
                reviewGeneration: packageA.reviewGeneration.rawValue,
                revision: packageA.revision
            )

            let mismatchDispatch = try await fixture.dispatchComparisonUpdate(
                target: mismatchedTarget,
                requestSequence: 3,
                workerDerivationEpoch: 3
            )
            guard case .response(let mismatchAdmissionBytes) = mismatchDispatch else {
                Issue.record("Expected the mismatched target operation admission")
                return
            }
            let mismatchAdmission = try BridgeProductStrictJSON.decode(
                BridgeProductOperationAdmittedResponse.self,
                from: mismatchAdmissionBytes
            )
            await fixture.session.waitForOperationExecution(operationId: mismatchAdmission.operationId)
            let comparisonAfterMismatch = controller.refreshAdmissionCoordinator
                .productPresentationSnapshot.reviewComparison
            #expect(comparisonAfterMismatch?.activeTarget == mismatchedTarget)
            #expect(controller.bridgePaneState == stateA)
            if let attempt = comparisonAfterMismatch?.attempt,
                case .unavailable(let failureKind, let retryable) = attempt
            {
                #expect(failureKind == "targetMismatch")
                #expect(!retryable)
            } else {
                Issue.record("Expected a target-scoped typed failure for the mismatched Review target")
            }
            #expect(comparisonAfterMismatch?.displayedSnapshot == .stale(lastGoodIdentity))
            #expect(controller.productAdmissionGate.diagnosticSnapshot.isOpen)
            #expect(controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity != .closed)
            // File and Comments share pane admission; a fresh token must remain available.
            #expect(controller.productAdmissionGate.acquire()?.withValidAdmission({ true }) == true)

            let mainDispatch = try await fixture.dispatchComparisonUpdate(
                target: mainTarget,
                requestSequence: 4,
                workerDerivationEpoch: 4
            )
            if case .response = mainDispatch {
                let mainResult = try await fixture.readOperationResult(for: mainDispatch)
                let mainTargetBuild = try #require(controller.activeReviewRefreshTask)
                await mainTargetBuild.value
                #expect(mainResult.outcome == .succeeded)
                #expect(controller.bridgePaneState == mainState)
                #expect(controller.productAdmissionGate.diagnosticSnapshot.isOpen)
                #expect(controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity != .closed)
            } else {
                Issue.record("Expected main to remain admitted after a Review target mismatch")
            }

            await fixture.finish()
            // finish tears the pane down; actual removal still ends E1.
            #expect(!controller.productAdmissionGate.diagnosticSnapshot.isOpen)
            #expect(controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity == .closed)
        }

        @Test("contribution load publishes pending then exact settled snapshot identity")
        func contributionLoadPublishesPendingThenSettledSnapshotIdentity() async throws {
            let target = WorkspaceReviewContributionTarget.branch(name: "stack/base")
            let comparison = makeComparison()
            let provider = makeContributionProvider(comparison: comparison)
            let controller = makeController(
                target: target,
                comparison: comparison,
                provider: provider
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let contributionCaptureGate = BridgeContributionCaptureGate()
            await provider.setContributionCaptureGate(contributionCaptureGate)
            let initialPresentation = controller.refreshAdmissionCoordinator.productPresentationSnapshot

            await sendPageActiveViewerMode(
                .review,
                controller: controller,
                productAdmission: productAdmission,
                sequence: 1
            )
            await contributionCaptureGate.waitForStart()
            await contributionCaptureGate.releaseAll()
            await waitForActiveReviewRefreshTaskToFinish(controller)
            let settledPresentation = controller.refreshAdmissionCoordinator.productPresentationSnapshot

            guard controller.paneState.diff.packageMetadata != nil else {
                Issue.record("Expected contribution load to succeed")
                return
            }
            #expect(initialPresentation.reviewComparison?.activeTarget == target)
            #expect(initialPresentation.reviewComparison?.attempt == .pending(reviewGeneration: 0))
            #expect(initialPresentation.reviewComparison?.displayedSnapshot == .absent)
            let package = try #require(controller.paneState.diff.packageMetadata)
            #expect(
                settledPresentation.reviewComparison
                    == BridgePaneReviewComparisonPresentation(
                        activeTarget: target,
                        attempt: .settled(reviewGeneration: package.reviewGeneration.rawValue),
                        displayedSnapshot: .current(
                            BridgePaneReviewDisplayedSnapshotIdentity(
                                packageId: package.packageId,
                                reviewGeneration: package.reviewGeneration.rawValue,
                                revision: package.revision
                            )
                        ),
                    )
            )
        }

        @Test("target update keeps predecessor stale and schedules one successor build")
        func targetUpdateKeepsPredecessorStaleAndSchedulesOneSuccessorBuild() async throws {
            let initialTarget = WorkspaceReviewContributionTarget.branch(name: "main")
            let successorTarget = WorkspaceReviewContributionTarget.branch(name: "stack/base")
            let comparison = makeComparison()
            let provider = makeContributionProvider(comparison: comparison)
            let canonicalSuccessorState = BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: WorkspaceBaseline(contributionTarget: successorTarget)
                )
            )
            let controller = makeController(
                target: initialTarget,
                comparison: comparison,
                provider: provider,
                contributionTargetCommit: { _ in .applied(canonicalSuccessorState) }
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            guard
                await showReviewPageAndAwaitInitialPackage(
                    controller,
                    productAdmission: productAdmission
                )
            else {
                Issue.record("Expected predecessor load to succeed")
                return
            }
            let predecessorPackage = try #require(controller.paneState.diff.packageMetadata)
            let predecessorIdentity = BridgePaneReviewDisplayedSnapshotIdentity(
                packageId: predecessorPackage.packageId,
                reviewGeneration: predecessorPackage.reviewGeneration.rawValue,
                revision: predecessorPackage.revision
            )
            controller.reviewGitRefreshSeedHolder.commit(
                refreshAdmissionContributionSeed(
                    targetOID: "replacement-target",
                    headOID: "replacement-head",
                    baseOID: "replacement-base"
                )
            )
            admitReviewComparisonIntent(
                workerDerivationEpoch: 1,
                controller: controller,
                productAdmission: productAdmission
            )

            let didAdopt = await controller.handleCommittedProductReviewComparisonUpdate(
                BridgeProductReviewComparisonUpdateRequest(target: successorTarget),
                workerDerivationEpoch: 1,
                productAdmission: productAdmission
            )
            let pendingPresentation = controller.refreshAdmissionCoordinator.productPresentationSnapshot
            await waitForActiveReviewRefreshTaskToFinish(controller)
            let settledPresentation = controller.refreshAdmissionCoordinator.productPresentationSnapshot

            #expect(didAdopt == .applied)
            #expect(controller.nextReviewGeneration == predecessorPackage.reviewGeneration.next())
            #expect(!controller.reviewGitRefreshSeedHolder.hasActiveSeed)
            #expect(pendingPresentation.reviewComparison?.activeTarget == successorTarget)
            #expect(pendingPresentation.reviewComparison?.displayedSnapshot == .stale(predecessorIdentity))
            guard case .current(let successorIdentity) = settledPresentation.reviewComparison?.displayedSnapshot
            else {
                Issue.record("Expected current successor snapshot identity")
                return
            }
            #expect(successorIdentity != predecessorIdentity)
            #expect(await provider.recordedContributionRequests().count == 2)
            #expect(controller.pendingComparisonReviewGeneration == nil)
            #expect(controller.pendingReviewPackageBuildReasons.isEmpty)
        }

        @Test("target replacement publishes settled pane presentation after package commit")
        func targetReplacementPublishesSettledPanePresentationAfterPackageCommit() async throws {
            // Arrange
            let initialTarget = WorkspaceReviewContributionTarget.branch(name: "main")
            let successorTarget = WorkspaceReviewContributionTarget.branch(name: "stack/base")
            let canonicalSuccessorState = BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/bridge-refresh-admission",
                    baseline: WorkspaceBaseline(contributionTarget: successorTarget)
                )
            )
            let fixture = try await makeRefreshAdmissionIntegrationFixture(
                initialContributionTarget: initialTarget,
                contributionTargetCommit: { _ in .applied(canonicalSuccessorState) }
            )
            defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            // fire-and-forget: this fixture asserts Review package admission, not the transition handle.
            _ = fixture.controller.applyBridgePaneActivity(.foreground)
            guard
                await showReviewPageAndAwaitInitialPackage(
                    fixture.controller,
                    productAdmission: fixture.productAdmission
                )
            else {
                Issue.record("Expected the shown Review page to build the initial package")
                return
            }
            _ = try await fixture.consumeQueuedMetadataFrames()
            let contributionCaptureGate = BridgeContributionCaptureGate()
            await fixture.reviewProvider.setContributionCaptureGate(contributionCaptureGate)
            admitReviewComparisonIntent(
                workerDerivationEpoch: 1,
                controller: fixture.controller,
                productAdmission: fixture.productAdmission
            )

            // Act
            let didAdopt = await fixture.controller.handleCommittedProductReviewComparisonUpdate(
                BridgeProductReviewComparisonUpdateRequest(target: successorTarget),
                workerDerivationEpoch: 1,
                productAdmission: fixture.productAdmission
            )
            await contributionCaptureGate.waitForStart()
            #expect(await waitForRefreshAdmissionQueuedMetadataFrame(fixture))
            let pendingFrames = try await fixture.consumeQueuedMetadataFrames()
            await contributionCaptureGate.releaseAll()
            await waitForActiveReviewRefreshTaskToFinish(fixture.controller)
            _ = await waitForRefreshAdmissionQueuedMetadataFrame(fixture)
            let terminalFrames = try await fixture.consumeQueuedMetadataFrames()

            // Assert
            let pendingPresentations: [BridgeProductPanePresentationFrame] = pendingFrames.compactMap { frame in
                guard case .panePresentation(let presentation) = frame else { return nil }
                return presentation
            }
            let terminalPresentations: [BridgeProductPanePresentationFrame] = terminalFrames.compactMap { frame in
                guard case .panePresentation(let presentation) = frame else { return nil }
                return presentation
            }
            #expect(didAdopt == .applied)
            #expect(
                pendingPresentations.last?.reviewComparison?.attempt
                    == .pending(reviewGeneration: 2)
            )
            #expect(terminalPresentations.last?.reviewComparison?.activeTarget == successorTarget)
            #expect(
                terminalPresentations.last?.reviewComparison?.attempt
                    == .settled(reviewGeneration: 2)
            )
        }

        @Test("filesystem reload preserves settled comparison presentation")
        func filesystemReloadPreservesSettledComparisonPresentation() async throws {
            let target = WorkspaceReviewContributionTarget.branch(name: "main")
            let comparison = makeComparison()
            let provider = makeContributionProvider(comparison: comparison)
            let controller = makeController(
                target: target,
                comparison: comparison,
                provider: provider
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            guard
                await showReviewPageAndAwaitInitialPackage(
                    controller,
                    productAdmission: productAdmission
                )
            else {
                Issue.record("Expected initial contribution load to succeed")
                return
            }
            let settledBeforeRefresh = try #require(
                controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison
            )
            let contributionCaptureGate = BridgeContributionCaptureGate()
            await provider.setContributionCaptureGate(contributionCaptureGate)

            controller.scheduleReviewPackageReloadForProductResync(reason: .filesystemRefresh)
            await contributionCaptureGate.waitForStart()
            let presentationDuringRefresh = controller.refreshAdmissionCoordinator
                .productPresentationSnapshot.reviewComparison
            await contributionCaptureGate.releaseAll()
            await waitForActiveReviewRefreshTaskToFinish(controller)

            #expect(presentationDuringRefresh == settledBeforeRefresh)
            #expect(
                controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?
                    .attempt == settledBeforeRefresh.attempt
            )
        }

        @Test("successor comparison clears and refreshes repository default identity")
        func successorComparisonClearsAndRefreshesRepositoryDefaultIdentity() async throws {
            // Arrange
            let initialTarget = WorkspaceReviewContributionTarget.branch(name: "main")
            let successorTarget = WorkspaceReviewContributionTarget.branch(name: "stack/base")
            let initialDefaultTarget = BridgeReviewComparisonDefaultTargetIdentity(
                remoteName: "origin",
                branchName: "main"
            )
            let successorDefaultTarget = BridgeReviewComparisonDefaultTargetIdentity(
                remoteName: "upstream",
                branchName: "trunk"
            )
            let comparison = makeComparison()
            let provider = makeContributionProvider(
                comparison: comparison,
                repositoryDefaultTarget: initialDefaultTarget
            )
            let canonicalSuccessorState = BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: WorkspaceBaseline(contributionTarget: successorTarget)
                )
            )
            let controller = makeController(
                target: initialTarget,
                comparison: comparison,
                provider: provider,
                contributionTargetCommit: { _ in .applied(canonicalSuccessorState) }
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            guard
                await showReviewPageAndAwaitInitialPackage(
                    controller,
                    productAdmission: productAdmission
                )
            else {
                Issue.record("Expected initial contribution load to succeed")
                return
            }
            #expect(
                controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?
                    .repositoryDefaultTarget == initialDefaultTarget
            )
            let defaultTargetGate = BridgeContributionCaptureGate()
            await provider.setRepositoryDefaultTarget(successorDefaultTarget)
            await provider.setDefaultTargetGate(defaultTargetGate)
            admitReviewComparisonIntent(
                workerDerivationEpoch: 1,
                controller: controller,
                productAdmission: productAdmission
            )

            // Act
            let didAdopt = await controller.handleCommittedProductReviewComparisonUpdate(
                BridgeProductReviewComparisonUpdateRequest(target: successorTarget),
                workerDerivationEpoch: 1,
                productAdmission: productAdmission
            )
            await defaultTargetGate.waitForStart()
            let pendingPresentation =
                controller.refreshAdmissionCoordinator.productPresentationSnapshot
            await defaultTargetGate.releaseAll()
            await waitForActiveReviewRefreshTaskToFinish(controller)
            let settledPresentation =
                controller.refreshAdmissionCoordinator.productPresentationSnapshot

            // Assert
            #expect(didAdopt == .applied)
            #expect(
                pendingPresentation.reviewComparison?.repositoryDefaultTarget
                    == initialDefaultTarget
            )
            #expect(
                settledPresentation.reviewComparison?.repositoryDefaultTarget
                    == successorDefaultTarget
            )
            #expect(await provider.recordedDefaultTargetReadCount() == 2)
        }

        private func makeComparison() -> BridgeEndpointComparison {
            BridgeEndpointComparison(
                baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                changedFiles: []
            )
        }

        private func makeContributionProvider(
            comparison: BridgeEndpointComparison,
            repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity? = nil
        ) -> BridgeReviewSourceProviderFake {
            BridgeReviewSourceProviderFake(
                comparison: comparison,
                contentByHandleId: [:],
                contributionCapture: BridgeContributionComparisonCapture(
                    resolvedTargetOID: "resolved-target-oid",
                    reviewedHeadOID: "reviewed-head-oid",
                    baseRole: .commonCommit,
                    baseOID: "contribution-base-oid",
                    comparison: comparison
                ),
                repositoryDefaultTarget: repositoryDefaultTarget
            )
        }

        private func makeController(
            target: WorkspaceReviewContributionTarget,
            comparison: BridgeEndpointComparison,
            provider: BridgeReviewSourceProviderFake,
            contributionTargetCommit:
                (@MainActor @Sendable (WorkspaceReviewContributionTarget) -> BridgePaneStateMutationResult)? = nil
        ) -> BridgePaneController {
            BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: WorkspaceBaseline(contributionTarget: target)
                    )
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    contentType: .diff,
                    title: "Bridge Review",
                    facets: PaneContextFacets(worktreeId: comparison.headEndpoint.worktreeId)
                ),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground,
                contributionTargetCommit: contributionTargetCommit
            )
        }

        private func paneState(for target: WorkspaceReviewContributionTarget) -> BridgePaneState {
            BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: WorkspaceBaseline(contributionTarget: target)
                )
            )
        }
    }
}

@MainActor
private func admitReviewComparisonIntent(
    workerDerivationEpoch: Int,
    controller: BridgePaneController,
    productAdmission: BridgeProductAdmissionContext
) {
    _ = productAdmission.withValidAdmission {
        controller.refreshAdmissionCoordinator.workAdmissionSource.admitReviewComparisonIntent(
            workerDerivationEpoch: workerDerivationEpoch,
            productAdmission: productAdmission
        )
    }
}

@MainActor
private func showReviewPageAndAwaitInitialPackage(
    _ fixture: BridgeReviewComparisonControlFixture
) async -> Bool {
    await showReviewPageAndAwaitInitialPackage(
        fixture.controller,
        productAdmission: fixture.productAdmission
    )
}

@MainActor
private func showReviewPageAndAwaitInitialPackage(
    _ controller: BridgePaneController,
    productAdmission: BridgeProductAdmissionContext
) async -> Bool {
    await sendPageActiveViewerMode(
        .review,
        controller: controller,
        productAdmission: productAdmission,
        sequence: 1
    )
    if let initialBuild = controller.activeReviewRefreshTask {
        await initialBuild.value
    }
    return controller.paneState.diff.packageMetadata != nil
}
