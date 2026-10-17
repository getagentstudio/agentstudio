import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct ReviewNativeProgressDeadlineTests {
        init() { installTestCoreAtomsIfNeeded() }

        @Test("producer phase completion renews a joined consumer while acquisition remains held")
        func producerProgressRenewsJoinedConsumerBeforeAcquisitionCompletes() async throws {
            let pair = try await makeReviewNativeProgressPair(initialContributionTarget: nil)
            await pair.provider.holdComparison()
            await pair.provider.holdCapture()
            let firstForeground = pair.first.controller.applyBridgePaneActivity(.foreground)
            let firstIntake = try #require(pair.first.controller.activeReviewRefreshTask)
            await firstForeground?.value
            try await pair.provider.comparisonStep.firstArrival()
            let entry = try #require(pair.constructionProbe.events.last { $0.kind == .buildStarted }?.entryNonce)
            let secondForeground = pair.second.controller.applyBridgePaneActivity(.foreground)
            let secondIntake = try #require(pair.second.controller.activeReviewRefreshTask)
            await secondForeground?.value
            try await pair.facts.expectNext(in: entry, .joined)
            do {
                await pair.secondClock.waitForPendingSleepCount(atLeast: 1)
                pair.secondClock.advance(by: .seconds(4))
                pair.provider.comparisonStep.release()
                try await pair.provider.captureStep.firstArrival()
                await pair.secondClock.waitForPendingSleepCount(atLeast: 1)
                pair.secondClock.advance(by: .seconds(2))
                try #require(pair.secondClock.pendingSleepCount == 1)
                #expect(pair.secondProgress.activeWaitCount() == 1)
                #expect(await pair.coordinator.snapshot().waiterCount == 2)
                pair.secondClock.advance(by: AppPolicies.Bridge.reviewBuildProgressDeadline)
                await secondIntake.value
                #expect(pair.second.controller.activeReviewRefreshTask == nil)
                #expect(pair.second.controller.paneState.diff.status == .error)
                #expect(pair.second.controller.paneState.diff.packageMetadata == nil)
                let physicalTasks = pair.secondProgress.physicalTaskHandles()
                pair.provider.captureStep.release()
                await firstIntake.value
                for task in physicalTasks { await task.value }
                #expect(pair.second.controller.paneState.diff.packageMetadata == nil)
                await pair.first.finish()
                await pair.second.finish()
                let residue = await pair.coordinator.snapshot()
                #expect(residue.waiterCount == 0)
                #expect(residue.leaseCount == 0)
                #expect(residue.inFlightCount == 0)
                try await pair.facts.finish()
            } catch {
                pair.provider.comparisonStep.release()
                pair.provider.captureStep.release()
                await firstIntake.value
                await secondIntake.value
                for task in pair.secondProgress.physicalTaskHandles() { await task.value }
                await pair.first.finish()
                await pair.second.finish()
                throw error
            }
        }

        @Test("a new consumer and presentation traffic do not renew a stalled shared-build join")
        func joiningConsumerAndTrafficDoNotRenew() async throws {
            let pair = try await makeReviewNativeProgressPair()
            let evidence = try await captureReviewNativeProgressPredecessor(pair)
            let (firstCatchUp, secondCatchUp) = try await pair.startHeldCatchUp()
            let third = try await makeJoiningReviewNativeProgressPeer(pair)
            var thirdLoad: Task<Void, Never>?
            do {
                await pair.secondClock.waitForPendingSleepCount(atLeast: 1)
                pair.secondClock.advance(by: .seconds(4))
                await pair.second.controller.scheduleProductPresentationPublication()?.value
                let foreground = third.controller.applyBridgePaneActivity(.foreground)
                let startedLoad = try #require(third.controller.activeReviewRefreshTask)
                thirdLoad = startedLoad
                await foreground?.value
                let entry = try #require(pair.constructionProbe.events.last { $0.kind == .buildStarted }?.entryNonce)
                try await pair.facts.expectNext(in: entry, .joined)
                pair.secondClock.advance(by: .seconds(2))
                try #require(pair.secondClock.pendingSleepCount == 0)
                await secondCatchUp.value
                let failure = try #require(
                    pair.second.controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison)
                guard case .unavailable(let kind, let retryable) = failure.attempt else {
                    throw NoPublicationProgressProofFailure.expectedRetryableUnavailable
                }
                #expect(kind == "reviewBuildProgressDeadline")
                #expect(retryable)
                #expect(failure.displayedSnapshot == evidence.presentation.displayedSnapshot.stalePredecessor)
                pair.provider.captureStep.release()
                await firstCatchUp.value
                await thirdLoad?.value
                for task in pair.secondProgress.physicalTaskHandles() { await task.value }
                #expect(
                    try pair.second.currentCommittedReviewPublication().publicationId
                        == evidence.predecessor.publicationId)
                await third.finish()
                await pair.first.finish()
                await pair.second.finish()
                let residue = await pair.coordinator.snapshot()
                #expect(residue.waiterCount == 0)
                #expect(residue.leaseCount == 0)
                #expect(residue.inFlightCount == 0)
                try await pair.facts.finish()
            } catch {
                pair.provider.captureStep.release()
                await firstCatchUp.value
                await secondCatchUp.value
                await thirdLoad?.value
                for task in pair.secondProgress.physicalTaskHandles() { await task.value }
                await third.finish()
                await pair.first.finish()
                await pair.second.finish()
                throw error
            }
        }

        @Test(
            "real phase completion renews the progress window; a later installation stall expires and releases its late pin"
        )
        func completedPhaseRenewsThenLaterStallExpires() async throws {
            let pair = try await makeReviewNativeProgressPair()
            let evidence = try await captureReviewNativeProgressPredecessor(pair)
            await pair.provider.holdInstall()
            await pair.targetsProvider.holdInstall()
            let (firstCatchUp, secondCatchUp) = try await pair.startHeldCatchUp()
            do {
                await pair.secondClock.waitForPendingSleepCount(atLeast: 1)
                pair.secondClock.advance(by: .seconds(4))
                pair.provider.captureStep.release()
                try await pair.targetsProvider.installStep.firstArrival()
                await pair.secondClock.waitForPendingSleepCount(atLeast: 1)
                // Cross the original five-second window. A renewed deadline is still in the clock's future.
                pair.secondClock.advance(by: .seconds(2))
                try #require(pair.secondClock.pendingSleepCount == 1)
                #expect(pair.secondProgress.activeWaitCount() == 1)
                pair.secondClock.advance(by: AppPolicies.Bridge.reviewBuildProgressDeadline)
                await secondCatchUp.value
                let failure = try #require(
                    pair.second.controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison)
                guard case .unavailable(let kind, let retryable) = failure.attempt else {
                    throw NoPublicationProgressProofFailure.expectedRetryableUnavailable
                }
                #expect(kind == "reviewBuildProgressDeadline")
                #expect(retryable)
                #expect(failure.displayedSnapshot == evidence.presentation.displayedSnapshot.stalePredecessor)
                #expect(
                    try pair.second.currentCommittedReviewPublication().publicationId
                        == evidence.predecessor.publicationId)
                let afterDeadline = pair.second.controller.refreshAdmissionCoordinator.productPresentationSnapshot
                let physicalTasks = pair.secondProgress.physicalTaskHandles()
                #expect(physicalTasks.count == 1)
                pair.provider.installStep.release()
                pair.targetsProvider.installStep.release()
                await firstCatchUp.value
                for task in physicalTasks { await task.value }
                #expect(
                    try pair.second.currentCommittedReviewPublication().publicationId
                        == evidence.predecessor.publicationId)
                #expect(pair.second.controller.refreshAdmissionCoordinator.productPresentationSnapshot == afterDeadline)
                await pair.first.finish()
                await pair.second.finish()
                let residue = await pair.coordinator.snapshot()
                #expect(residue.waiterCount == 0)
                #expect(residue.leaseCount == 0)
                #expect(residue.inFlightCount == 0)
                try await pair.facts.finish()
            } catch {
                pair.provider.captureStep.release()
                pair.provider.installStep.release()
                pair.targetsProvider.installStep.release()
                await firstCatchUp.value
                await secondCatchUp.value
                for task in pair.secondProgress.physicalTaskHandles() { await task.value }
                await pair.first.finish()
                await pair.second.finish()
                throw error
            }
        }

        @Test("shown cold Review with a held build ends retryable unavailable and fences its late result")
        func coldIntakeBuildExpiresAndFencesLateResult() async throws {
            let pair = try await makeReviewNativeProgressPair()
            await pair.provider.holdCapture()
            let foreground = pair.first.controller.applyBridgePaneActivity(.foreground)
            let intake = try #require(pair.first.controller.activeReviewRefreshTask)
            await foreground?.value
            try await pair.provider.captureStep.firstArrival()
            let entry = try #require(pair.constructionProbe.events.last { $0.kind == .buildStarted }?.entryNonce)
            do {
                try #require(pair.firstProgress.activeWaitCount() == 1)
                await pair.firstClock.waitForPendingSleepCount(atLeast: 1)
                pair.firstClock.advance(by: AppPolicies.Bridge.reviewBuildProgressDeadline)
                await intake.value
                #expect(pair.first.controller.activeReviewRefreshTask == nil)
                #expect(pair.first.controller.paneState.diff.status == .error)
                #expect(pair.first.controller.paneState.diff.packageMetadata == nil)
                let failure = try #require(
                    pair.first.controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison)
                guard case .unavailable(let kind, let retryable) = failure.attempt else {
                    throw NoPublicationProgressProofFailure.expectedRetryableUnavailable
                }
                #expect(kind == "reviewBuildProgressDeadline")
                #expect(retryable)
                #expect(failure.displayedSnapshot == .absent)
                #expect(await pair.coordinator.snapshot().inFlightCount == 1)
                let afterDeadline = pair.first.controller.refreshAdmissionCoordinator.productPresentationSnapshot
                let physicalTasks = pair.firstProgress.physicalTaskHandles()
                pair.provider.captureStep.release()
                for task in physicalTasks { await task.value }
                try await pair.facts.expectNext(in: entry, .removed)
                #expect(pair.first.controller.paneState.diff.packageMetadata == nil)
                #expect(pair.first.controller.refreshAdmissionCoordinator.productPresentationSnapshot == afterDeadline)
                #expect(pair.firstProgress.activeWaitCount() == 0)
                pair.first.controller.scheduleReviewPackageReloadForProductResync()
                let retry = try #require(pair.first.controller.activeReviewRefreshTask)
                await retry.value
                let recovered = try pair.first.currentCommittedReviewPublication()
                #expect(recovered.package.orderedItemIds == ["item-initial"])
                let recoveredPresentation = try #require(
                    pair.first.controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison)
                #expect(
                    recoveredPresentation.attempt
                        == .settled(reviewGeneration: recovered.package.reviewGeneration.rawValue))
                #expect(pair.first.controller.activeReviewRefreshTask == nil)
                for task in pair.firstProgress.physicalTaskHandles() { await task.value }
                await pair.first.finish()
                await pair.second.finish()
                let residue = await pair.coordinator.snapshot()
                #expect(residue.waiterCount == 0)
                #expect(residue.leaseCount == 0)
                #expect(residue.inFlightCount == 0)
                try await pair.facts.finish()
            } catch {
                pair.provider.captureStep.release()
                await intake.value
                for task in pair.firstProgress.physicalTaskHandles() { await task.value }
                await pair.first.finish()
                await pair.second.finish()
                throw error
            }
        }

        @Test("background catch-up without a publication expires its shared build join")
        func noPublicationCatchUpJoinExpiresAndFencesLateResult() async throws {
            let pair = try await makeReviewNativeProgressPair()
            let (coldIntake, catchUp) = try await pair.startHeldInitialCatchUp()
            do {
                try #require(pair.secondProgress.activeWaitCount() == 1)
                await pair.secondClock.waitForPendingSleepCount(atLeast: 1)
                pair.secondClock.advance(by: AppPolicies.Bridge.reviewBuildProgressDeadline)
                await catchUp.value
                #expect(pair.second.controller.activeReviewRefreshTask == nil)
                #expect(
                    pair.second.controller.reviewPublicationCoordinator.committedPublicationForReplay(
                        productAdmission: pair.second.productAdmission) == nil)
                #expect(pair.second.controller.paneState.diff.packageMetadata == nil)
                let failure = try #require(
                    pair.second.controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison)
                guard case .unavailable(let kind, let retryable) = failure.attempt else {
                    throw NoPublicationProgressProofFailure.expectedRetryableUnavailable
                }
                #expect(kind == "reviewBuildProgressDeadline")
                #expect(retryable)
                #expect(failure.displayedSnapshot == .absent)
                #expect(failure.activeTarget == .ref(name: "main"))
                #expect(pair.second.controller.reviewComparisonTargetProjection.currentTarget == .ref(name: "main"))
                // The cold peer's physical shared build remains accounted for after the join expires.
                #expect(await pair.coordinator.snapshot().inFlightCount == 1)
                let afterDeadline = pair.second.controller.refreshAdmissionCoordinator.productPresentationSnapshot
                let physicalTasks = pair.secondProgress.physicalTaskHandles()
                pair.provider.captureStep.release()
                await coldIntake.value
                for task in physicalTasks { await task.value }
                #expect(try pair.first.currentCommittedReviewPublication().package.orderedItemIds == ["item-initial"])
                #expect(pair.second.controller.paneState.diff.packageMetadata == nil)
                #expect(pair.second.controller.refreshAdmissionCoordinator.productPresentationSnapshot == afterDeadline)
                #expect(pair.secondProgress.activeWaitCount() == 0)
                await pair.first.finish()
                await pair.second.finish()
                let residue = await pair.coordinator.snapshot()
                #expect(residue.waiterCount == 0)
                #expect(residue.leaseCount == 0)
                #expect(residue.inFlightCount == 0)
                try await pair.facts.finish()
            } catch {
                pair.provider.captureStep.release()
                await coldIntake.value
                await catchUp.value
                for task in pair.secondProgress.physicalTaskHandles() { await task.value }
                await pair.first.finish()
                await pair.second.finish()
                throw error
            }
        }

        @Test(
            "background catch-up joining a held shared build ends typed and keeps its predecessor after late build completion"
        )
        func sharedBuildJoinExpiresAndKeepsPredecessor() async throws {
            let pair = try await makeReviewNativeProgressPair()
            let first = pair.first
            let second = pair.second
            let provider = pair.provider
            let targetsProvider = pair.targetsProvider
            let coordinator = pair.coordinator
            let facts = pair.facts
            let secondClock = pair.secondClock
            let secondProgress = pair.secondProgress
            let evidence = try await captureReviewNativeProgressPredecessor(pair)
            let predecessor = evidence.predecessor
            let oldItems = predecessor.package.orderedItemIds
            let oldPresentation = evidence.presentation
            let oldTarget = evidence.target
            let authorizeTargets = evidence.authorizeTargets
            let catalogRequest = evidence.catalogRequest
            let targetsBefore = evidence.catalog
            let oldHandle = evidence.handle
            let oldBytes = evidence.bytes
            #expect(secondProgress.activeWaitCount() == 0)
            let (firstCatchUp, secondCatchUp) = try await pair.startHeldCatchUp()
            do {
                // The original fails here, before a join on the held shared build.
                try #require(secondProgress.activeWaitCount() == 1)
                await secondClock.waitForPendingSleepCount(atLeast: 1)
                secondClock.advance(by: AppPolicies.Bridge.reviewBuildProgressDeadline)
                await secondCatchUp.value
                #expect(second.controller.activeReviewRefreshTask == nil)
                #expect(try second.currentCommittedReviewPublication().publicationId == predecessor.publicationId)
                #expect(second.controller.paneState.diff.packageMetadata?.orderedItemIds == oldItems)
                let failure = try #require(
                    second.controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison)
                guard case .unavailable(let kind, let retryable) = failure.attempt else {
                    Issue.record("Expected the current native catch-up deadline to publish a retryable phase failure")
                    provider.captureStep.release()
                    await firstCatchUp.value
                    await first.finish()
                    await second.finish()
                    return
                }
                #expect(kind == "reviewBuildProgressDeadline")
                #expect(retryable)
                #expect(failure.displayedSnapshot == oldPresentation.displayedSnapshot.stalePredecessor)
                #expect(failure.activeTarget == oldPresentation.activeTarget)
                #expect(failure.repositoryDefaultTarget == oldPresentation.repositoryDefaultTarget)
                #expect(second.controller.reviewComparisonTargetProjection.currentTarget == oldTarget)
                let authorizedAfter = try #require(await authorizeTargets())
                #expect(authorizedAfter.currentTarget == oldTarget)
                let targetsAfter = try await targetsProvider.captureReviewComparisonTargets(catalogRequest)
                #expect(targetsAfter.branches == targetsBefore.branches)
                #expect(targetsAfter.currentTarget == targetsBefore.currentTarget)
                #expect(targetsAfter.defaultTarget == targetsBefore.defaultTarget)
                #expect(
                    try await second.controller.reviewContentLoaderCache.load(
                        handle: oldHandle, productAdmission: second.productAdmission
                    ).data == oldBytes)
                let afterDeadline = second.controller.refreshAdmissionCoordinator.productPresentationSnapshot
                let physicalTasks = secondProgress.physicalTaskHandles()
                provider.captureStep.release()
                await firstCatchUp.value
                for task in physicalTasks { await task.value }
                #expect(try first.currentCommittedReviewPublication().package.orderedItemIds == ["item-refreshed"])
                #expect(try second.currentCommittedReviewPublication().publicationId == predecessor.publicationId)
                #expect(second.controller.paneState.diff.packageMetadata?.orderedItemIds == oldItems)
                #expect(
                    try await second.controller.reviewContentLoaderCache.load(
                        handle: oldHandle, productAdmission: second.productAdmission
                    ).data == oldBytes)
                #expect(second.controller.refreshAdmissionCoordinator.productPresentationSnapshot == afterDeadline)
                #expect(second.controller.activeReviewRefreshTask == nil)
                #expect(secondProgress.activeWaitCount() == 0)
                await first.finish()
                await second.finish()
                let residue = await coordinator.snapshot()
                #expect(residue.waiterCount == 0)
                #expect(residue.leaseCount == 0)
                #expect(residue.inFlightCount == 0)
                try await facts.finish()
            } catch {
                provider.captureStep.release()
                await firstCatchUp.value
                await secondCatchUp.value
                for task in secondProgress.physicalTaskHandles() { await task.value }
                await first.finish()
                await second.finish()
                throw error
            }
        }
    }
}

private enum NativeProgressConstructionFact: Equatable, Sendable { case joined, removed }
private enum NoPublicationProgressProofFailure: Error { case expectedRetryableUnavailable }

@MainActor
private func makeJoiningReviewNativeProgressPeer(_ pair: ReviewNativeProgressPair) async throws
    -> RefreshAdmissionIntegrationFixture
{
    let fixture = try await makeRefreshAdmissionIntegrationFixture(
        initialContributionTarget: .ref(name: "main"), constructionCoordinator: pair.coordinator,
        reviewConstructionProgress: .init(clock: TestPushClock()),
        reviewProviderTransform: { NativeProgressSharedReviewProvider(source: $0) })
    await fixture.reviewProvider.setContributionCapture(
        .init(
            resolvedTargetOID: "resolved-target-oid", reviewedHeadOID: "reviewed-head-oid",
            baseRole: .commonCommit, baseOID: "contribution-base-oid",
            comparison: fixture.refreshedComparison,
            gitRefreshSeed: refreshAdmissionContributionSeed(
                targetOID: "resolved-target-oid", headOID: "reviewed-head-oid", baseOID: "contribution-base-oid")))
    fixture.controller.refreshAdmissionCoordinator.recordInvalidation(fileChangeset: nil, requiresReviewRefresh: true)
    return fixture
}

@MainActor
private struct ReviewNativeProgressPair {
    let first: RefreshAdmissionIntegrationFixture
    let second: RefreshAdmissionIntegrationFixture
    let provider: NativeProgressSharedReviewProvider
    let targetsProvider: NativeProgressSharedReviewProvider
    let coordinator: BridgeWorktreeProductConstructionCoordinator
    let constructionProbe: BridgeWorktreeProductConstructionEventProbe
    let facts: FactRecorder<UInt64, NativeProgressConstructionFact>
    let firstClock: TestPushClock
    let secondClock: TestPushClock
    let firstProgress: BridgeReviewConstructionProgressWaitOwner
    let secondProgress: BridgeReviewConstructionProgressWaitOwner

    func startHeldInitialCatchUp() async throws -> (Task<Void, Never>, Task<Void, Never>) {
        // G2 schedules initial intake whenever Review is shown. A no-publication
        // catch-up therefore follows a real failed initial attempt.
        await targetsProvider.failNextSharedCapture()
        let initialForeground = second.controller.applyBridgePaneActivity(.foreground)
        let failedInitialAttempt = try #require(second.controller.activeReviewRefreshTask)
        await initialForeground?.value
        await failedInitialAttempt.value
        #expect(second.controller.paneState.diff.status == .error)
        #expect(second.controller.paneState.diff.packageMetadata == nil)
        #expect(second.controller.pendingReviewPackageBuildReasons.isEmpty)
        let hiddenTransition = second.controller.applyBridgePaneActivity(.loadedHidden)
        await hiddenTransition?.value
        await provider.holdCapture()
        for fixture in [first, second] {
            fixture.controller.refreshAdmissionCoordinator.recordInvalidation(
                fileChangeset: nil, requiresReviewRefresh: true)
        }
        let firstForeground = first.controller.applyBridgePaneActivity(.foreground)
        let coldIntake = try #require(first.controller.activeReviewRefreshTask)
        await firstForeground?.value
        try await provider.captureStep.firstArrival()
        let entry = try #require(constructionProbe.events.last { $0.kind == .buildStarted }?.entryNonce)
        let secondForeground = second.controller.applyBridgePaneActivity(.foreground)
        let catchUp = try #require(second.controller.activeReviewRefreshTask)
        await secondForeground?.value
        try await facts.expectNext(in: entry, .joined)
        return (coldIntake, catchUp)
    }

    func startHeldCatchUp() async throws -> (Task<Void, Never>, Task<Void, Never>) {
        await provider.holdCapture()
        for fixture in [first, second] {
            await fixture.reviewProvider.setContributionCapture(
                .init(
                    resolvedTargetOID: "resolved-target-oid", reviewedHeadOID: "reviewed-head-oid",
                    baseRole: .commonCommit, baseOID: "contribution-base-oid",
                    comparison: fixture.refreshedComparison,
                    gitRefreshSeed: refreshAdmissionContributionSeed(
                        targetOID: "resolved-target-oid", headOID: "reviewed-head-oid",
                        baseOID: "contribution-base-oid")))
        }
        first.controller.refreshAdmissionCoordinator.recordInvalidation(
            fileChangeset: nil, requiresReviewRefresh: true)
        first.controller.scheduleWorktreeProductCatchUpIfPossible()
        let firstCatchUp = try #require(first.controller.activeReviewRefreshTask)
        try await provider.captureStep.firstArrival()
        let entry = try #require(constructionProbe.events.last { $0.kind == .buildStarted }?.entryNonce)
        second.controller.refreshAdmissionCoordinator.recordInvalidation(
            fileChangeset: nil, requiresReviewRefresh: true)
        second.controller.scheduleWorktreeProductCatchUpIfPossible()
        let secondCatchUp = try #require(second.controller.activeReviewRefreshTask)
        try await facts.expectNext(in: entry, .joined)
        return (firstCatchUp, secondCatchUp)
    }
}

@MainActor
private func makeReviewNativeProgressPair(
    initialContributionTarget: WorkspaceReviewContributionTarget? = .ref(name: "main")
) async throws
    -> ReviewNativeProgressPair
{
    let constructionProbe = BridgeWorktreeProductConstructionEventProbe()
    let facts = FactRecorder<UInt64, NativeProgressConstructionFact>(
        vocabulary: .init(
            describeScope: { "entry \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .removed }))
    let coordinator = BridgeWorktreeProductConstructionCoordinator { event in
        constructionProbe.eventSink(event)
        if event.kind == .consumerJoined { facts.append(scope: event.entryNonce, fact: .joined) }
        if event.kind == .entryRemoved { facts.append(scope: event.entryNonce, fact: .removed) }
    }
    let firstClock = TestPushClock()
    let secondClock = TestPushClock()
    let firstProgress = BridgeReviewConstructionProgressWaitOwner(clock: firstClock)
    let secondProgress = BridgeReviewConstructionProgressWaitOwner(clock: secondClock)
    var heldProvider: NativeProgressSharedReviewProvider?
    var catalogProvider: NativeProgressSharedReviewProvider?
    let first = try await makeRefreshAdmissionIntegrationFixture(
        initialContributionTarget: initialContributionTarget, constructionCoordinator: coordinator,
        reviewConstructionProgress: firstProgress,
        reviewProviderTransform: { provider in
            let shared = NativeProgressSharedReviewProvider(source: provider)
            heldProvider = shared
            return shared
        })
    let second = try await makeRefreshAdmissionIntegrationFixture(
        initialContributionTarget: initialContributionTarget, constructionCoordinator: coordinator,
        reviewConstructionProgress: secondProgress,
        reviewProviderTransform: { provider in
            let shared = NativeProgressSharedReviewProvider(source: provider)
            catalogProvider = shared
            return shared
        })
    return ReviewNativeProgressPair(
        first: first, second: second, provider: try #require(heldProvider),
        targetsProvider: try #require(catalogProvider), coordinator: coordinator,
        constructionProbe: constructionProbe, facts: facts, firstClock: firstClock, secondClock: secondClock,
        firstProgress: firstProgress, secondProgress: secondProgress)
}

private struct ReviewNativeProgressPredecessor {
    let predecessor: BridgeReviewCommittedPublication
    let presentation: BridgePaneReviewComparisonPresentation
    let target: WorkspaceReviewContributionTarget?
    let authorizeTargets: @Sendable () async -> BridgeProductReviewComparisonTargetsAuthorization?
    let catalogRequest: BridgeReviewComparisonTargetsCaptureRequest
    let catalog: BridgeReviewComparisonTargetsCapture
    let handle: BridgeContentHandle
    let bytes: Data
}

@MainActor
private func captureReviewNativeProgressPredecessor(_ pair: ReviewNativeProgressPair) async throws
    -> ReviewNativeProgressPredecessor
{
    let first = pair.first
    let second = pair.second
    let targetsProvider = pair.targetsProvider
    let oldContent = "retained old diff\n"
    let oldBytes = Data(oldContent.utf8)
    for fixture in [first, second] {
        await fixture.reviewProvider.setContributionCapture(
            .init(
                resolvedTargetOID: "resolved-target-oid", reviewedHeadOID: "reviewed-head-oid",
                baseRole: .commonCommit, baseOID: "contribution-base-oid",
                comparison: .init(
                    baseEndpoint: fixture.baseEndpoint, headEndpoint: fixture.headEndpoint,
                    changedFiles: [
                        makeBridgeEndpointChangedFile(
                            fileId: "initial", path: "Sources/App/Initial.swift", sizeBytes: 100,
                            newContentHash: bridgeSHA256ContentHash(oldContent))
                    ]),
                gitRefreshSeed: refreshAdmissionContributionSeed(
                    targetOID: "resolved-target-oid", headOID: "reviewed-head-oid",
                    baseOID: "contribution-base-oid")))
    }
    let firstForeground = first.controller.applyBridgePaneActivity(.foreground)
    let firstInitial = try #require(first.controller.activeReviewRefreshTask)
    await firstForeground?.value
    await firstInitial.value
    let secondForeground = second.controller.applyBridgePaneActivity(.foreground)
    let secondInitial = try #require(second.controller.activeReviewRefreshTask)
    await secondForeground?.value
    await secondInitial.value
    let predecessor = try second.currentCommittedReviewPublication()
    let oldPresentation = try #require(
        second.controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison)
    let oldTarget = second.controller.reviewComparisonTargetProjection.currentTarget
    let authorizeTargets = BridgePaneProductComparisonTargetQuerySource.makeAuthorization(
        targetProjection: second.controller.reviewComparisonTargetProjection,
        refreshWorkAdmissionSource: second.controller.refreshAdmissionCoordinator.workAdmissionSource)
    let authorizedBefore = try #require(await authorizeTargets())
    #expect(authorizedBefore.currentTarget == oldTarget)
    let catalogRequest = BridgeReviewComparisonTargetsCaptureRequest(
        currentTarget: oldTarget, capturedAtUnixMilliseconds: 100, cutoffUnixMilliseconds: 0, maximumRows: 100)
    let targetsBefore = try await targetsProvider.captureReviewComparisonTargets(catalogRequest)
    #expect(!targetsBefore.branches.isEmpty)
    let oldHandle = try #require(predecessor.package.itemsById.values.first?.contentRoles.head)
    await second.reviewProvider.installNativeProgressReadResult(
        .init(
            handle: oldHandle, data: oldBytes, mimeType: oldHandle.mimeType,
            contentHash: oldHandle.contentHash, contentHashAlgorithm: oldHandle.contentHashAlgorithm))
    #expect(
        try await second.controller.reviewContentLoaderCache.load(
            handle: oldHandle, productAdmission: second.productAdmission
        ).data == oldBytes)
    return ReviewNativeProgressPredecessor(
        predecessor: predecessor, presentation: oldPresentation, target: oldTarget,
        authorizeTargets: authorizeTargets, catalogRequest: catalogRequest, catalog: targetsBefore,
        handle: oldHandle, bytes: oldBytes)
}
