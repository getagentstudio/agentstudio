import AgentStudioCore
import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane page viewer mode", .serialized)
@MainActor
struct BridgePaneControllerPageViewerModeTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("null-source Review boot admits the first package from the page mode")
    func pageReviewBootWithNullSourceAdmitsInitialIntake() async throws {
        let fixture = try await makeRefreshAdmissionIntegrationFixture()
        await fixture.controller.applyBridgePaneActivity(.foreground)?.value
        let heldComparison = HeldStep<Void>(
            "first Review package after null-source page boot",
            cancellation: .holdThroughCancellation
        )
        defer { heldComparison.release() }
        await fixture.reviewProvider.setComparisonStep(heldComparison)

        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )

        #expect(fixture.controller.retainedViewerSurface == nil)
        let initialIntakeTask = fixture.controller.activeReviewRefreshTask
        #expect(initialIntakeTask != nil)
        guard let initialIntakeTask else {
            heldComparison.release()
            await fixture.finish()
            return
        }
        _ = try await heldComparison.firstArrival()
        heldComparison.release()
        await initialIntakeTask.value

        #expect(await fixture.reviewProvider.recordedComparisonRequestsCount() == 1)
        #expect(
            fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-initial"]
        )
        await fixture.finish()
    }

    @Test("a stale page sequence cannot replace the accepted viewer mode")
    func stalePageModeSequenceKeepsLatestVisibility() async throws {
        let fixture = try await makeRefreshAdmissionIntegrationFixture()

        await sendPageActiveViewerMode(
            .file,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 2
        )
        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )

        #expect(fixture.controller.activeViewerModeSignalState.acceptedMode == .file)
        #expect(!fixture.controller.isReviewShownByPage)
        await fixture.finish()
    }

    @Test("a new page session replaces the prior accepted viewer mode")
    func pageSessionResetClearsPriorViewerMode() async throws {
        let fixture = try await makeRefreshAdmissionIntegrationFixture()
        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 5,
            sessionId: "page-session-before-reset"
        )
        #expect(fixture.controller.isReviewShownByPage)

        await sendPageActiveViewerMode(
            .file,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1,
            sessionId: "page-session-after-reset"
        )

        #expect(fixture.controller.activeViewerModeSignalState.acceptedMode == .file)
        #expect(fixture.controller.activeViewerModeSignalState.lastSequence == 1)
        #expect(!fixture.controller.isReviewShownByPage)
        await fixture.finish()
    }
}
