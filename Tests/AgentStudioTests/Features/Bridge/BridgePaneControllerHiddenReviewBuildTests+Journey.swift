import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgePaneControllerHiddenReviewBuildTests {
    @Test("held catch-up survives File Review hidden batches and foreground with latest truth")
    func heldCatchUpModeRoundTripResumesLatestHiddenBatch() async throws {
        // Arrange: mirror the hosted two-pane journey's native ingress ordering.
        let facts = try BridgePaneReviewBuildAdmissionTrace()
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            reviewBuildAdmissionFactSink: facts.source.sink
        )
        await fixture.controller.applyBridgePaneActivity(.foreground)?.value
        await sendPageActiveViewerMode(
            .review, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 1
        )
        #expect(try await facts.nextAttemptOutcome() == .succeeded)
        let heldComparison = HeldStep<Void>("journey held catch-ups", cancellation: .holdThroughCancellation)
        await fixture.reviewProvider.setComparisonStep(heldComparison)
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
        await postHiddenReviewJourneyBatch(fixture, batch: 701)
        let firstAttempt = try await facts.nextAdmittedAttempt()
        let firstTask = try #require(fixture.controller.activeReviewRefreshTask)
        _ = try await heldComparison.firstArrival()

        // Act: File and Review share a foreground pane, then native visibility closes.
        await sendPageActiveViewerMode(
            .file, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 2
        )
        #expect(fixture.controller.activeReviewRefreshTaskId == nil)
        let secondComparison = HeldStep<Void>("journey reshown catch-up", cancellation: .holdThroughCancellation)
        await fixture.reviewProvider.setComparisonStep(secondComparison)
        await sendPageActiveViewerMode(
            .review, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 3
        )
        let secondAttempt = try await facts.nextAdmittedAttempt()
        let secondTask = try #require(fixture.controller.activeReviewRefreshTask)
        _ = try await secondComparison.firstArrival()
        await fixture.controller.applyBridgePaneActivity(.loadedHidden)?.value
        await postHiddenReviewJourneyBatch(fixture, batch: 702)
        let latestFile = makeBridgeEndpointChangedFile(
            fileId: "journey-latest", path: "Sources/App/Latest.swift", sizeBytes: 140
        )
        await fixture.reviewProvider.setComparison(
            BridgeEndpointComparison(
                baseEndpoint: fixture.baseEndpoint, headEndpoint: fixture.headEndpoint, changedFiles: [latestFile]
            )
        )
        await postHiddenReviewJourneyBatch(fixture, batch: 703)
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact?.latestBatchSequence == 703)
        heldComparison.release()
        secondComparison.release()
        await firstTask.value
        await secondTask.value
        #expect(try await facts.attemptOutcome(for: firstAttempt) == .cancelled)
        #expect(try await facts.attemptOutcome(for: secondAttempt) == .cancelled)
        #expect(fixture.controller.activeReviewRefreshTask == nil)

        // Assert the exact latest owner completes; no generic idle or first-terminal test.
        await fixture.controller.applyBridgePaneActivity(.foreground)?.value
        let latestAttempt = try await facts.nextAdmittedAttempt()
        #expect(latestAttempt != firstAttempt && latestAttempt != secondAttempt)
        let latestOutcome = try await facts.attemptOutcome(for: latestAttempt)
        #expect(latestOutcome == .succeeded)
        await fixture.controller.worktreeRefreshDriver.awaitActiveFileOperations()
        await fixture.controller.worktreeRefreshDriver.awaitRetiringFileOperations()
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-journey-latest"])
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact == nil)
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.activeRefreshPass == nil)
        #expect(fixture.controller.pendingReviewPackageBuildReasons.isEmpty)
        await fixture.finish()
        try await facts.finish()
    }

    @Test("accepted File preserves Publishing and committed AwaitingInstall", arguments: [false, true], [false, true])
    func acceptedHidePreservesPublicationLifetime(catchUp: Bool, committed: Bool) async throws {
        // Arrange: stop at the existing publication owner's reservation/delivery seam.
        let facts = try BridgePaneReviewBuildAdmissionTrace()
        let publicationStep = HeldStep<Void>("Review publication lifetime", cancellation: .holdThroughCancellation)
        let lifecycleRecorder = HiddenReviewCommittedPublicationRecorder()
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            reviewMetadataHeldPackageItemId: catchUp ? "item-refreshed" : nil,
            reviewMetadataReservationStep: committed ? nil : publicationStep,
            reviewBuildAdmissionFactSink: facts.source.sink,
            publicationLifecycleRecorder: lifecycleRecorder
        )
        if committed && !catchUp { await lifecycleRecorder.hold(at: publicationStep) }
        await fixture.controller.applyBridgePaneActivity(.foreground)?.value
        await sendPageActiveViewerMode(
            .review, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 1
        )
        if catchUp {
            #expect(try await facts.nextAttemptOutcome() == .succeeded)
            if committed { await lifecycleRecorder.hold(at: publicationStep) }
            await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
            await postHiddenReviewJourneyBatch(fixture, batch: 701)
        }
        let attempt = try await facts.nextAdmittedAttempt()
        let task = try #require(fixture.controller.activeReviewRefreshTask)
        _ = try await publicationStep.firstArrival()
        let authority = fixture.controller.refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)
        #expect(committed == (fixture.controller.reviewPublicationCoordinator.diagnosticSnapshot.pending == nil))

        // Act / Assert
        await sendPageActiveViewerMode(
            .file, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 2
        )
        #expect(fixture.controller.activeReviewRefreshTaskId == attempt)
        #expect(fixture.controller.refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review) == authority)
        publicationStep.release()
        await task.value
        #expect(try await facts.attemptOutcome(for: attempt) == .succeeded)
        #expect(fixture.controller.paneState.diff.packageMetadata != nil)
        await fixture.finish()
        try await facts.finish()
    }
}

private actor HiddenReviewCommittedPublicationRecorder: BridgeProductMetadataLifecycleTraceRecording {
    private var step: HeldStep<Void>?

    func hold(at step: HeldStep<Void>) { self.step = step }

    func record(_ event: BridgeProductReviewMetadataPublicationTraceEvent) async {
        guard case .started = event, let step else { return }
        try? await step.arrive(())
    }

    func record(_: BridgeAnnotationLifecycleTraceEvent) async {}
    func record(_: BridgeProductMetadataLifecycleTraceEvent) async {}
}
