import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    @Test("clean real-git Review publishes the loaded empty presentation")
    func cleanRealGitReviewPublishesLoadedEmptyPresentation() async throws {
        // Arrange
        let repoURL = try await FilesystemTestGitRepo.create(named: "bridge-product-empty-review-webkit")
        defer { FilesystemTestGitRepo.destroy(repoURL) }
        try "tracked\n".write(
            to: repoURL.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await FilesystemTestGitRepo.runGit(at: repoURL, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: repoURL, args: ["commit", "-m", "Initial commit"])
        let traceRecorder = BridgeProductWebKitCarrierTraceRecorder()
        let controller = makeController(repoURL: repoURL, traceRecorder: traceRecorder)

        // Act
        let run = try await BridgeProductWebKitCarrierTestSupport.withHostedController(
            controller
        ) { hostedController in
            hostedController.loadApp()
            await WebPageEventWaits.waitForNavigationToFinish(hostedController.page)
            // The bundled Review protocol starts in Review mode. Observe that
            // active host instead of clicking its already-selected toggle.
            try await WebPageEventWaits.waitForDocumentSelector(
                hostedController.page,
                "[data-testid=\"bridge-viewer-mode-host-review\"][data-bridge-viewer-mode-active=\"true\"]"
            )
            // Native construction and page installation have separate owners.
            // Observe the native ready package before asserting the page view.
            _ = try await BridgePaneControllerEventWaits.waitForValue {
                hostedController.paneState.diff.status == .ready
                    ? hostedController.paneState.diff.packageMetadata : nil
            }
            // Q43's ready-empty state renders the existing empty canvas in a
            // fallback shell, without a regular Review viewer shell.
            try await WebPageEventWaits.waitForDocumentSelector(
                hostedController.page,
                "[data-testid=\"bridge-review-empty-canvas\"]"
            )
            let package = try hostedController.ipcReviewPackageSnapshot()
            let didLoadEmptyPackage = package.status == "ready" && package.items.isEmpty
            let didRenderEmptyShell =
                (try? await hostedController.page.callJavaScript(
                    """
                    return document.querySelector(
                      '[data-testid="bridge-review-empty-canvas"]'
                    )?.textContent === 'Nothing to review';
                    """
                ) as? Bool) == true
            return (didLoadEmptyPackage, didRenderEmptyShell)
        }

        // Assert
        #expect(run.value.0)
        #expect(run.value.1)
        #expect(run.teardownSnapshot.hasZeroResidue)
    }
}
