import Foundation
import Testing
import WebKit

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

/// Integration tests for the current Bridge product-session path.
///
/// These tests cover bootstrap readiness, packaged app loading, and native
/// Review sources flowing through the pane's product streams into the React UI.
extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    final class BridgeTransportIntegrationTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test
        func test_bridgeReady_gatesAndIsIdempotent() async {
            // Arrange
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground
            )

            // Act / Assert
            #expect(!controller.isBridgeReady)
            #expect(controller.handleBridgeReady())
            #expect(controller.isBridgeReady)
            #expect(!controller.handleBridgeReady())
            #expect(controller.isBridgeReady)

            await teardownBridgeControllerForTest(controller)
        }

        @Test
        func test_teardown_resetsBridgeReady() async {
            // Arrange
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground
            )
            #expect(controller.handleBridgeReady())

            // Act
            let teardownRetirement = controller.beginTeardown()

            // Assert
            #expect(!controller.isBridgeReady)
            _ = await teardownRetirement.value
            await WebPageTestHarness.settle()
        }

        @Test
        func test_schemeHandler_servesPackagedReactApp() async throws {
            // Arrange
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground
            )

            try await WebPageTestHarness.withManagedPage(controller.page) { page in
                // Act
                controller.loadApp()
                await WebPageEventWaits.waitForNavigationToFinish(page)
                let didNavigateToAppURL = page.url?.absoluteString == "agentstudio://app/index.html"
                await WebPageEventWaits.waitForTitle(page, equals: "AgentStudio Bridge")
                await WebPageEventWaits.waitForBridgeReady(controller)

                // Assert
                #expect(didNavigateToAppURL)

                _ = try await page.callJavaScript(
                    """
                    document.title = document.querySelector('[data-testid="bridge-review-empty-shell"]') !== null
                      ? 'AgentStudio Bridge Visible'
                      : 'AgentStudio Bridge Missing Shell'
                    """
                )
                await WebPageEventWaits.waitForTitle(page, equals: "AgentStudio Bridge Visible")
            }

            await teardownBridgeControllerForTest(controller)
        }

        @Test
        func test_handleDiffCommandWithSmokeProvider_rendersReviewViewerShell() async throws {
            // Arrange
            let paneId = UUIDv7.generate()
            let controller = BridgePaneController(
                paneId: paneId,
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: BridgeObservabilitySmokeReviewSourceProvider(),
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            try await WebPageTestHarness.withManagedPage(controller.page) { page in
                controller.loadApp()
                await WebPageEventWaits.waitForNavigationToFinish(page)
                await WebPageEventWaits.waitForBridgeReady(controller)
                try await installPageErrorProbe(page)

                // Act
                let commandResult = await controller.handleDiffCommand(
                    .loadDiff(
                        DiffArtifact(
                            diffId: BridgeObservabilitySmokeReviewSourceProvider.diffId,
                            worktreeId: BridgeObservabilitySmokeReviewSourceProvider.worktreeId,
                            patchData: Data()
                        )
                    ),
                    commandId: UUIDv7.generate(),
                    correlationId: nil
                )

                // Assert
                let commandSucceeded = if case .success = commandResult { true } else { false }
                #expect(
                    commandSucceeded,
                    Comment(rawValue: "Expected smoke provider diff command to succeed; actual: \(commandResult)")
                )
                guard commandSucceeded else { return }
                // The assertion reads `hasReviewShell`, which is computed from this
                // exact element, so the wait and the assertion read the same thing.
                try await WebPageEventWaits.waitForDocumentSelector(page, bridgeReviewShellSelector)
                let renderState = try await controller.renderStateForIPC()
                #expect(renderState.summary.hasReviewShell)
                #expect(!renderState.summary.hasEmptyShell)
                #expect(renderState.diagnostics.evaluateSucceeded)
                #expect(renderState.diagnostics.pageErrorCount == 0)
                let pageErrors = await pageErrorProbeDescription(page)
                #expect(pageErrors == "[]", Comment(rawValue: pageErrors))
            }
        }

        @Test
        func test_sourceBackedInitialReviewLoad_rendersReviewViewerShell() async throws {
            // Arrange
            let paneId = UUIDv7.generate()
            let controller = BridgePaneController(
                paneId: paneId,
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: .unstaged)
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    paneId: PaneId(existingUUID: paneId),
                    contentType: .diff,
                    launchDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                    title: "Bridge Review",
                    facets: PaneContextFacets(
                        repoId: BridgeObservabilitySmokeReviewSourceProvider.repoId,
                        worktreeId: BridgeObservabilitySmokeReviewSourceProvider.worktreeId,
                        cwd: URL(fileURLWithPath: "/tmp/worktree")
                    )
                ),
                reviewSourceProvider: BridgeObservabilitySmokeReviewSourceProvider(),
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            try await WebPageTestHarness.withManagedPage(controller.page) { page in
                controller.loadApp()
                await WebPageEventWaits.waitForNavigationToFinish(page)
                await WebPageEventWaits.waitForBridgeReady(controller)
                try await installPageErrorProbe(page)

                // Act / Assert
                // The assertion reads `hasReviewShell`, which is computed from this
                // exact element, so the wait and the assertion read the same thing.
                try await WebPageEventWaits.waitForDocumentSelector(page, bridgeReviewShellSelector)
                let renderState = try await controller.renderStateForIPC()
                #expect(renderState.summary.hasReviewShell)
                #expect(!renderState.summary.hasEmptyShell)
                #expect(renderState.diagnostics.evaluateSucceeded)
                #expect(renderState.diagnostics.pageErrorCount == 0)
                let pageErrors = await pageErrorProbeDescription(page)
                #expect(pageErrors == "[]", Comment(rawValue: pageErrors))
            }
        }
    }
}

@MainActor
private func installPageErrorProbe(_ page: WebPage) async throws {
    _ = try await page.callJavaScript(
        """
        window.__bridgeErrorProbe = [];
        window.addEventListener('error', function(event) {
          window.__bridgeErrorProbe.push({
            kind: 'error',
            message: String(event.message)
          });
        });
        window.addEventListener('unhandledrejection', function(event) {
          window.__bridgeErrorProbe.push({
            kind: 'unhandledrejection',
            message: String(event.reason?.message || event.reason)
          });
        });
        """
    )
}

@MainActor
private func pageErrorProbeDescription(_ page: WebPage) async -> String {
    do {
        let result = try await page.callJavaScript(
            """
            return JSON.stringify(window.__bridgeErrorProbe ?? [])
            """
        )
        return (result as? String) ?? String(describing: result)
    } catch {
        return String(describing: error)
    }
}

@MainActor
private func teardownBridgeControllerForTest(_ controller: BridgePaneController) async {
    _ = await controller.beginTeardown().value
    await WebPageTestHarness.settle()
}
