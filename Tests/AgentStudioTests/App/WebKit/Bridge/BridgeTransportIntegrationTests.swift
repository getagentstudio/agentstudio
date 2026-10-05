import Foundation
import Synchronization
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
            let diagnostics = BridgePackagedProductDiagnosticRecorder()
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                telemetryRecorder: diagnostics,
                initialPaneActivity: .foreground
            )

            let liveCapture = try BridgePackagedLiveCapture(controller: controller)
            try await liveCapture.withManagedPage { page in
                // Act
                controller.loadApp()
                await WebPageEventWaits.waitForNavigationToFinish(page)
                try await installPageErrorProbe(page)
                let didNavigateToAppURL = page.url?.absoluteString == "agentstudio://app/index.html"
                await WebPageEventWaits.waitForTitle(page, equals: "AgentStudio Bridge")
                await WebPageEventWaits.waitForBridgeReady(controller)

                // Assert
                #expect(didNavigateToAppURL)

                let nativeReadback = await packagedProductNativeReadback(controller)
                print("[packaged-product-diagnostic] no-source boundary: \(nativeReadback)")
                let noSourceObserved = try await WebPageEventWaits.waitForDocumentValue(
                    page,
                    reader: """
                        const regions = ['review-content', 'review-tree'].map((region) =>
                          document.querySelector(`[data-bridge-region="${region}"]`));
                        return regions.every((region) => region !== null
                          && region.getAttribute('data-presentation-state') === 'empty'
                          && region.getAttribute('data-empty-reason') === 'noSource'
                          && region.textContent.includes('This pane has no worktree')
                          && region.querySelector('[data-slot="skeleton"]') === null) ? true : null;
                        """,
                    arguments: ["selector": "[data-testid=\"bridge-review-empty-shell\"]"],
                    milestone:
                        "Packaged React app settles both Review regions as no-source empty; native=\(nativeReadback)",
                    lastObservation: """
                        return JSON.stringify({
                          title: document.title,
                          emptyShellPresent: document.querySelector(selector) !== null,
                          activeViewerMode: document.querySelector('[data-testid="bridge-app-root"]')
                            ?.getAttribute('data-bridge-viewer-mode') ?? null,
                          reviewRegions: Array.from(document.querySelectorAll('[data-bridge-region^="review-"]'))
                            .map((region) => ({
                              region: region.getAttribute('data-bridge-region'),
                              presentationState: region.getAttribute('data-presentation-state'),
                              emptyReason: region.getAttribute('data-empty-reason'),
                              text: region.textContent,
                              skeletonPresent: region.querySelector('[data-slot="skeleton"]') !== null
                            })),
                          metadataStreamDiagnostic: window.__bridgeProductMetadataStreamDiagnostic ?? null,
                          productResources: performance.getEntriesByType('resource')
                            .filter((entry) => entry.name.includes('agentstudio://rpc/'))
                            .map((entry) => ({name: entry.name, responseStatus: entry.responseStatus ?? null})),
                          javascriptErrors: window.__bridgeErrorProbe ?? []
                        });
                        """
                )
                #expect(noSourceObserved as? Bool == true)
                _ = try await page.callJavaScript("document.title = 'AgentStudio Bridge Visible';")
                await WebPageEventWaits.waitForTitle(page, equals: "AgentStudio Bridge Visible")
                let pageErrors = await pageErrorProbeDescription(page)
                #expect(pageErrors == "[]", Comment(rawValue: pageErrors))
            }

            await teardownBridgeControllerForTest(controller)
        }

        @Test
        func test_handleDiffCommandWithSmokeProvider_rendersReviewViewerShell() async throws {
            // Arrange
            let paneId = UUIDv7.generate()
            let reviewBuildFacts = BridgeSmokeReviewBuildFacts()
            let diagnostics = BridgePackagedProductDiagnosticRecorder()
            let controller = BridgePaneController(
                paneId: paneId,
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: BridgeObservabilitySmokeReviewSourceProvider(),
                telemetryRecorder: diagnostics,
                initialPaneActivity: .foreground,
                reviewBuildAdmissionFactSink: reviewBuildFacts.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            let liveCapture = try BridgePackagedLiveCapture(controller: controller)
            try await liveCapture.withManagedPage { page in
                controller.loadApp()
                await WebPageEventWaits.waitForNavigationToFinish(page)
                await WebPageEventWaits.waitForBridgeReady(controller)
                try await installPageErrorProbe(page)

                // Act
                let loadInputs = (
                    acceptedMode: controller.activeViewerModeSignalState.acceptedMode,
                    modeSequence: controller.activeViewerModeSignalState.lastSequence,
                    reviewGeneration: controller.nextReviewGeneration,
                    authorityGeneration: controller.refreshAdmissionCoordinator.currentAuthorityGeneration(
                        for: .review),
                    activity: controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity
                )
                let commandId = UUIDv7.generate()
                let commandResult = await controller.handleDiffCommand(
                    .loadDiff(
                        DiffArtifact(
                            diffId: BridgeObservabilitySmokeReviewSourceProvider.diffId,
                            worktreeId: BridgeObservabilitySmokeReviewSourceProvider.worktreeId,
                            patchData: Data()
                        )
                    ),
                    commandId: commandId,
                    correlationId: nil
                )

                // Assert
                let nativeReadback = await packagedProductNativeReadback(controller)
                print("[packaged-product-diagnostic] explicit delivery boundary: \(nativeReadback)")
                let diagnosticFacts = reviewBuildFacts.describe(
                    controller: controller,
                    commandId: commandId,
                    commandResult: commandResult
                )
                let loadOutputs = (
                    acceptedMode: controller.activeViewerModeSignalState.acceptedMode,
                    modeSequence: controller.activeViewerModeSignalState.lastSequence,
                    reviewGeneration: controller.nextReviewGeneration,
                    authorityGeneration: controller.refreshAdmissionCoordinator.currentAuthorityGeneration(
                        for: .review),
                    activity: controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity
                )
                let commandSucceeded = if case .success = commandResult { true } else { false }
                #expect(
                    commandSucceeded,
                    Comment(
                        rawValue:
                            "Expected smoke provider diff command to succeed; actual: \(commandResult); inputs: \(loadInputs); outputs: \(loadOutputs); build facts: \(diagnosticFacts)"
                    )
                )
                guard commandSucceeded else { return }
                // The assertion reads `hasReviewShell`, which is computed from this
                // exact element, so the wait and the assertion read the same thing.
                _ = try await WebPageEventWaits.waitForDocumentValue(
                    page,
                    reader: "return document.querySelector(selector) === null ? null : true;",
                    arguments: ["selector": bridgeReviewShellSelector],
                    milestone: "Bridge Review shell; \(diagnosticFacts); native=\(nativeReadback)",
                    lastObservation: """
                        const shell = document.querySelector(selector);
                        const activeViewerModeHost = document.querySelector(
                          '[data-bridge-viewer-mode-active="true"]'
                        );
                        return JSON.stringify({
                          reviewShellPresent: shell !== null,
                          activeViewerMode: activeViewerModeHost?.getAttribute('data-bridge-viewer-mode-host') ?? null,
                          metadataStreamDiagnostic: window.__bridgeProductMetadataStreamDiagnostic ?? null,
                          productResources: performance.getEntriesByType('resource')
                            .filter((entry) => entry.name.includes('agentstudio://rpc/'))
                            .map((entry) => ({name: entry.name, responseStatus: entry.responseStatus ?? null})),
                          javascriptErrors: window.__bridgeErrorProbe ?? []
                        });
                        """
                )
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

private final class BridgeSmokeReviewBuildFacts: Sendable {
    private let facts = Mutex<[(BridgePaneReviewBuildAdmissionScope, BridgePaneReviewBuildAdmissionFact)]>([])

    var sink: BridgePaneReviewBuildAdmissionFactSink {
        { [self] scope, fact in
            facts.withLock { $0.append((scope, fact)) }
        }
    }

    @MainActor
    func describe(
        controller: BridgePaneController,
        commandId: UUID,
        commandResult: ActionResult
    ) -> String {
        let commandFacts = facts.withLock { recordedFacts in
            recordedFacts.compactMap { scope, fact -> BridgePaneReviewBuildAdmissionFact? in
                scope == .pendingExplicitCommand(commandId) ? fact : nil
            }
        }
        let pendingCommand = controller.pendingExplicitReviewCommand
        let resumingCommand = controller.resumingExplicitReviewCommandsById[commandId]
        let installationPresent =
            controller.productSessionOwner.installationFenceProjection.snapshot.installation != nil
        let admissionResult: String
        if commandFacts.contains(where: {
            if case .pendingExplicitCommandResumptionAdmissionAcquired(let factCommandId) = $0 {
                factCommandId == commandId
            } else {
                false
            }
        }) {
            admissionResult = "acquired"
        } else if commandFacts.contains(where: {
            if case .pendingExplicitCommandResumptionAdmissionRejected(let factCommandId) = $0 {
                factCommandId == commandId
            } else {
                false
            }
        }) {
            admissionResult = "rejected"
        } else if commandFacts.contains(where: {
            if case .pendingExplicitCommandResumptionPreflightRejected(let factCommandId) = $0 {
                factCommandId == commandId
            } else {
                false
            }
        }) {
            admissionResult = "preflight rejected"
        } else {
            admissionResult = "not attempted for this command"
        }
        let resumptionScheduled = commandFacts.contains {
            if case .pendingExplicitCommandResumptionScheduled(let factCommandId) = $0 {
                factCommandId == commandId
            } else {
                false
            }
        }
        let buildStarted = commandFacts.contains {
            if case .explicitReviewPackageBuildStarted(let factCommandId) = $0 {
                factCommandId == commandId
            } else {
                false
            }
        }
        let resumedBuildStarted = commandFacts.contains {
            if case .pendingExplicitCommandBuildStarted(let factCommandId) = $0 {
                factCommandId == commandId
            } else {
                false
            }
        }
        let publicationDelivery =
            commandFacts.compactMap { fact -> String? in
                guard case .explicitReviewPackageDelivery(let factCommandId, let disposition) = fact,
                    factCommandId == commandId
                else { return nil }
                return String(describing: disposition)
            }.last ?? "not recorded"
        let commandSucceeded: Bool
        if case .success = commandResult {
            commandSucceeded = true
        } else {
            commandSucceeded = false
        }

        return [
            "commandId=\(commandId.uuidString)",
            "commandSucceeded=\(commandSucceeded)",
            "acceptedMode=\(String(describing: controller.activeViewerModeSignalState.acceptedMode))",
            "acceptedSequence=\(String(describing: controller.activeViewerModeSignalState.lastSequence))",
            "installationPresent=\(installationPresent)",
            "pendingCommandId=\(pendingCommand?.commandId.uuidString ?? "none")",
            "resumingCommandId=\(resumingCommand?.commandId.uuidString ?? "none")",
            "resumingTaskPresent=\(controller.resumingExplicitReviewCommandTasksById[commandId] != nil)",
            "resumptionScheduled=\(resumptionScheduled)",
            "resumptionAdmission=\(admissionResult)",
            "buildStarted=\(buildStarted)",
            "resumedBuildStarted=\(resumedBuildStarted)",
            "publicationDelivery=\(publicationDelivery)",
            "commandFacts=\(commandFacts.map(String.init(describing:)))",
            "diffStatus=\(String(describing: controller.paneState.diff.status))",
            "reviewPackagePresent=\(controller.paneState.diff.packageMetadata != nil)",
            "activeConstructionWaits=\(controller.reviewConstructionProgress.activeWaitCount())",
        ].joined(separator: "; ")
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
