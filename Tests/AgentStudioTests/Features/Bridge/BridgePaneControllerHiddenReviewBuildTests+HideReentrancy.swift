import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgePaneControllerHiddenReviewBuildTests {
    @Test("hidden build completion closes retained admission before its task returns")
    func hiddenBuildCompletionClosesRetainedAdmission() async throws {
        // Arrange
        let facts = try BridgePaneReviewBuildAdmissionTrace()
        let progressOwner = BridgeReviewConstructionProgressWaitOwner()
        let hideTelemetry = HeldStep<Void>("accepted File telemetry", cancellation: .holdThroughCancellation)
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            reviewConstructionProgress: progressOwner,
            reviewBuildAdmissionFactSink: facts.source.sink,
            telemetryRecorder: HiddenReviewAcceptedFileTelemetryRecorder(step: hideTelemetry)
        )
        await fixture.controller.applyBridgePaneActivity(.foreground)?.value
        let buildStep = HeldStep<Void>("initial build before hide", cancellation: .holdThroughCancellation)
        await fixture.reviewProvider.setComparisonStep(buildStep)
        await sendPageActiveViewerMode(
            .review, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 1
        )
        let attempt = try await facts.nextAdmittedAttempt()
        let buildTask = try #require(fixture.controller.activeReviewRefreshTask)
        _ = try await buildStep.firstArrival()

        let input = BridgePaneReviewBuildAdmissionInput.retainedPackageBuild
        let opening = await facts.recorder.mark(.hiddenInput(input))
        let hideTask = Task { @MainActor in
            await sendPageActiveViewerMode(
                .file,
                controller: fixture.controller,
                productAdmission: fixture.productAdmission,
                sequence: 2,
                activeSource: BridgeActiveViewerSource(
                    protocolId: .worktreeFile,
                    streamId: "file-source",
                    generation: 1
                )
            )
        }
        _ = try await hideTelemetry.firstArrival()
        let physicalConstructionTasks = progressOwner.physicalTaskHandles()
        #expect(physicalConstructionTasks.count == 1)
        buildStep.release()
        await buildTask.value
        let buildOutcome = try await facts.attemptOutcome(for: attempt)
        #expect(buildOutcome == .stale)
        for physicalConstructionTask in physicalConstructionTasks {
            await physicalConstructionTask.value
        }
        #expect(await fixture.reviewProvider.recordedComparisonRequestsCount() == 1)
        #expect(fixture.controller.activeReviewRefreshTask == nil)
        #expect(fixture.controller.pendingReviewPackageBuildReasons.contains(.initialIntake))

        // Settle the source after both logical and physical construction owners.
        facts.source.end()
        let negativeExpectationError: (any Error)?
        do {
            _ = try await facts.expectNoAdmission(for: input, from: opening)
            negativeExpectationError = nil
        } catch {
            negativeExpectationError = error
        }
        hideTelemetry.release()
        await hideTask.value
        await fixture.finish()
        try await facts.finish()
        if let negativeExpectationError {
            throw negativeExpectationError
        }
    }

    @Test("File acceptance fences before telemetry and its delayed tail preserves the shown successor")
    func acceptedHideFencesBeforeTelemetryAndPreservesSuccessor() async throws {
        // Arrange: a committed predecessor and an in-flight filesystem catch-up.
        let facts = try BridgePaneReviewBuildAdmissionTrace()
        let hideTelemetry = HeldStep<Void>("accepted File telemetry", cancellation: .holdThroughCancellation)
        let fixture = try await makeRefreshAdmissionIntegrationFixture(
            reviewBuildAdmissionFactSink: facts.source.sink,
            telemetryRecorder: HiddenReviewAcceptedFileTelemetryRecorder(step: hideTelemetry)
        )
        await fixture.controller.applyBridgePaneActivity(.foreground)?.value
        await sendPageActiveViewerMode(
            .review, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 1
        )
        #expect(try await facts.nextAttemptOutcome() == .succeeded)
        let predecessor = fixture.controller.paneState.diff.packageMetadata
        let firstComparison = HeldStep<Void>("catch-up before File", cancellation: .holdThroughCancellation)
        await fixture.reviewProvider.setComparisonStep(firstComparison)
        await fixture.reviewProvider.setComparison(fixture.refreshedComparison)
        await postHiddenReviewJourneyBatch(fixture, batch: 701)
        let firstAttempt = try await facts.nextAdmittedAttempt()
        let firstTask = try #require(fixture.controller.activeReviewRefreshTask)
        _ = try await firstComparison.firstArrival()
        let firstAuthority = fixture.controller.refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)

        // Act: acceptance runs, but the asynchronous telemetry tail cannot return.
        let hideTask = Task { @MainActor in
            await sendPageActiveViewerMode(
                .file, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 2,
                activeSource: BridgeActiveViewerSource(
                    protocolId: .worktreeFile, streamId: "file-source", generation: 1
                )
            )
        }
        _ = try await hideTelemetry.firstArrival()
        let didFenceAtAcceptance =
            fixture.controller.activeReviewRefreshTaskId == nil
            && fixture.controller.refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review) != firstAuthority
        #expect(didFenceAtAcceptance)
        #expect(fixture.controller.paneState.diff.packageMetadata == predecessor)
        #expect(
            fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact?.requiresReviewRefresh == true)
        guard didFenceAtAcceptance else {
            hideTelemetry.release()
            await hideTask.value
            firstComparison.release()
            await firstTask.value
            _ = try await facts.attemptOutcome(for: firstAttempt)
            await fixture.finish()
            try await facts.finish()
            return
        }
        firstComparison.release()
        await firstTask.value
        #expect(try await facts.attemptOutcome(for: firstAttempt) == .cancelled)

        // A newer accepted show owns the retained catch-up while the old hide is suspended.
        let latestComparison = HeldStep<Void>("shown successor catch-up", cancellation: .holdThroughCancellation)
        await fixture.reviewProvider.setComparisonStep(latestComparison)
        await sendPageActiveViewerMode(
            .review, controller: fixture.controller, productAdmission: fixture.productAdmission, sequence: 3
        )
        let successor = try await facts.nextAdmittedAttempt()
        let successorTask = try #require(fixture.controller.activeReviewRefreshTask)
        _ = try await latestComparison.firstArrival()
        let successorAuthority = fixture.controller.refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)
        let successorReservation = fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.activeRefreshPass?
            .id
        hideTelemetry.release()
        await hideTask.value

        // Assert: the older callback cannot retire or steal the newer task's reservation.
        #expect(fixture.controller.activeReviewRefreshTaskId == successor)
        #expect(
            fixture.controller.refreshAdmissionCoordinator.currentAuthorityGeneration(for: .review)
                == successorAuthority)
        #expect(
            fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.activeRefreshPass?.id
                == successorReservation)
        latestComparison.release()
        await successorTask.value
        #expect(try await facts.attemptOutcome(for: successor) == .succeeded)
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"])
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact == nil)
        await fixture.finish()
        try await facts.finish()
    }
}

@MainActor
func postHiddenReviewJourneyBatch(_ fixture: RefreshAdmissionIntegrationFixture, batch: UInt64) async {
    await fixture.controller.handlePaneFilesystemContextEvent(
        .cwdSubtreeChanged(
            context: PaneFilesystemContext(
                paneId: PaneId(existingUUID: fixture.controller.paneId),
                repoId: fixture.headEndpoint.repoId,
                cwd: URL(fileURLWithPath: "/tmp/bridge-refresh-admission"),
                worktreeId: fixture.headEndpoint.worktreeId
            ),
            paths: ["Sources/App/Refreshed.swift"], batchSeq: batch
        )
    )
    await fixture.controller.worktreeRefreshDriver.awaitActiveFileOperations()
    await fixture.controller.worktreeRefreshDriver.awaitRetiringFileOperations()
}

private actor HiddenReviewAcceptedFileTelemetryRecorder: BridgePerformanceTraceRecording {
    let step: HeldStep<Void>

    init(step: HeldStep<Void>) { self.step = step }

    func record(sample: BridgeTelemetrySample, receivedAtUnixNano: UInt64) async {
        if sample.name == "performance.bridge.swift.active_viewer_mode_signal_accepted",
            sample.stringAttributes["agentstudio.bridge.active_viewer.mode"] == "file"
        {
            try? await step.arrive(())
        }
    }

    func recordDrop(
        reason: BridgeTelemetryDropReason, droppedCount: Int,
        firstRejectedEventName: String?, receivedAtUnixNano: UInt64
    ) async {}

    func drain() async throws {}
}
