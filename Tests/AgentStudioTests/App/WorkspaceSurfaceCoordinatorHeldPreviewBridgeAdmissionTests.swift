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
    struct WorkspaceHeldPreviewBridgeAdmissionTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @MainActor
        private struct CoordinatorFixture {
            let store: WorkspaceStore
            let coordinator: WorkspaceSurfaceCoordinator
            let viewRegistry: ViewRegistry
            let targetPane: Pane
            let targetTab: Tab
            let peerPane: Pane
            let targetMountView: BridgePaneMountView
            let heldState: HeldPanePreviewState

            func finish() async {
                await coordinator.shutdown()
            }
        }

        private func makeCoordinatorFixture(
            targetController: BridgePaneController,
            targetEndpoint: BridgeSourceEndpoint,
            peerController: BridgePaneController? = nil,
            peerEndpoint: BridgeSourceEndpoint? = nil
        ) -> CoordinatorFixture {
            let store = WorkspaceStore()
            let viewRegistry = ViewRegistry()
            let appLifecycleStore = AppLifecycleAtom()
            let windowLifecycleStore = WindowLifecycleAtom()
            let owningWindowId = UUIDv7.generate()
            let targetPane = Pane(
                id: targetController.paneId,
                content: .bridgePanel(targetController.bridgePaneState),
                metadata: PaneMetadata(
                    contentType: .diff,
                    title: "Held target",
                    facets: PaneContextFacets(
                        repoId: targetEndpoint.repoId,
                        worktreeId: targetEndpoint.worktreeId,
                        cwd: URL(fileURLWithPath: "/tmp/bridge-refresh-admission")
                    )
                )
            )
            let peerPane: Pane
            if let peerController, let peerEndpoint {
                peerPane = Pane(
                    id: peerController.paneId,
                    content: .bridgePanel(peerController.bridgePaneState),
                    metadata: PaneMetadata(
                        contentType: .diff,
                        title: "Canonical peer",
                        facets: PaneContextFacets(
                            repoId: peerEndpoint.repoId,
                            worktreeId: peerEndpoint.worktreeId,
                            cwd: URL(fileURLWithPath: "/tmp/bridge-refresh-admission-peer")
                        )
                    )
                )
            } else {
                peerPane = store.createPane(
                    content: .webview(
                        WebviewState(url: URL(string: "https://example.com/peer")!)
                    ),
                    metadata: PaneMetadata(title: "Peer")
                )
            }
            let targetTab = Tab(paneId: targetPane.id, name: "Target")
            let peerTab = Tab(paneId: peerPane.id, name: "Peer")
            #expect(store.paneAtom.insertRestoredPane(targetPane))
            if peerController != nil { #expect(store.paneAtom.insertRestoredPane(peerPane)) }
            store.appendTab(targetTab)
            store.appendTab(peerTab)
            store.setActiveTab(peerTab.id)

            appLifecycleStore.setActive(true)
            windowLifecycleStore.recordWindowRegistered(owningWindowId)
            windowLifecycleStore.recordWindowPresentation(
                WindowPresentationFacts(isVisible: true, isMiniaturized: false, isOccluded: false),
                for: owningWindowId
            )
            windowLifecycleStore.recordTerminalContainerBounds(
                CGRect(x: 0, y: 0, width: 1200, height: 800)
            )
            let coordinator = WorkspaceSurfaceCoordinator(
                store: store,
                viewRegistry: viewRegistry,
                runtime: SessionRuntime(store: store),
                surfaceManager: BridgeActivityIntegrationSurfaceManager(),
                terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
                terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
                runtimeRegistry: RuntimeRegistry(),
                paneEventBus: makeTestPaneRuntimeEventBus(),
                windowLifecycleStore: windowLifecycleStore,
                appLifecycleStore: appLifecycleStore,
                ipcLifecycle: .testUnavailable,
                bridgePaneAttendance: BridgePaneAttendanceAtom()
            )
            coordinator.startBridgePaneActivityObservation()
            let targetMountView = BridgePaneMountView(
                paneId: targetPane.id,
                controller: targetController
            )
            _ = coordinator.registerHostedView(mountedView: targetMountView, for: targetPane.id)
            if let peerController {
                _ = coordinator.registerHostedView(
                    mountedView: BridgePaneMountView(
                        paneId: peerPane.id,
                        controller: peerController
                    ),
                    for: peerPane.id
                )
            }
            let heldState = HeldPanePreviewState()
            coordinator.bindHeldPanePreviewState(heldState)
            return CoordinatorFixture(
                store: store,
                coordinator: coordinator,
                viewRegistry: viewRegistry,
                targetPane: targetPane,
                targetTab: targetTab,
                peerPane: peerPane,
                targetMountView: targetMountView,
                heldState: heldState
            )
        }

        @Test("held preview admits retained Bridge product work through the controller")
        func heldPreviewAdmitsRetainedBridgeProductWorkThroughController() async throws {
            let admissionFixture = try await makeRefreshAdmissionIntegrationFixture()
            let workspace = makeCoordinatorFixture(
                targetController: admissionFixture.controller,
                targetEndpoint: admissionFixture.headEndpoint
            )
            let target = ValidatedPanePreviewTarget(
                paneID: workspace.targetPane.id,
                owningTabID: workspace.targetTab.id,
                provider: workspace.targetPane.provider,
                sessionID: workspace.targetPane.terminalState?.zmxSessionID
            )
            do {
                workspace.store.setActiveTab(workspace.targetTab.id)
                #expect(
                    workspace.store.tabLayoutAtom.minimizePane(
                        workspace.targetPane.id,
                        inTab: workspace.targetTab.id
                    )
                )
                #expect(workspace.targetMountView.controller === admissionFixture.controller)
                await expectBridgePaneActivity(
                    .loadedHidden,
                    for: workspace.targetPane.id,
                    in: workspace.coordinator,
                    because: "an installed minimized target retains product work without admission"
                )
                #expect(await admissionFixture.reviewProvider.recordedComparisonRequestsCount() == 0)
                #expect(admissionFixture.controller.paneState.diff.packageMetadata == nil)
                #expect(workspace.heldState.beginSpaceHold(requestedTarget: target))
                // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
                _ = workspace.coordinator.beginHeldPanePreviewPreparation()
                #expect(workspace.heldState.presentedTarget == target)
                #expect(
                    workspace.viewRegistry.allBridgeViews[workspace.targetPane.id]
                        === workspace.targetMountView
                )
                await expectBridgePaneActivity(
                    .foreground,
                    for: workspace.targetPane.id,
                    in: workspace.coordinator,
                    because: "the held target is admitted through the existing controller owner"
                )
                await waitForActiveReviewRefreshTaskToFinish(admissionFixture.controller)
                #expect(await admissionFixture.reviewProvider.recordedComparisonRequestsCount() == 1)
                #expect(admissionFixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-initial"])
                #expect(
                    admissionFixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.activity
                        == .foreground
                )

                try await assertHiddenInvalidationCatchesUp(
                    admissionFixture: admissionFixture,
                    workspace: workspace,
                    target: target
                )
            } catch {
                await workspace.finish()
                await admissionFixture.finish()
                throw error
            }
            await workspace.finish()
            await admissionFixture.finish()
        }

        private func assertHiddenInvalidationCatchesUp(
            admissionFixture: RefreshAdmissionIntegrationFixture,
            workspace: CoordinatorFixture,
            target: ValidatedPanePreviewTarget
        ) async throws {
            workspace.heldState.endSpaceHold()
            workspace.coordinator.refreshBridgePaneActivities()
            await expectBridgePaneActivity(
                .loadedHidden,
                for: workspace.targetPane.id,
                in: workspace.coordinator,
                because: "release returns product admission to the canonical background tab"
            )
            let comparisonCountBeforeHiddenInvalidation =
                await admissionFixture.reviewProvider.recordedComparisonRequestsCount()
            await admissionFixture.reviewProvider.setComparison(admissionFixture.refreshedComparison)
            await admissionFixture.controller.handleWorktreeProductInvalidation(
                .filesChanged(
                    admissionFixture.makeChangeset(
                        paths: ["Sources/App/HeldPreview.swift"],
                        batchSequence: 901
                    )
                )
            )
            #expect(
                await admissionFixture.reviewProvider.recordedComparisonRequestsCount()
                    == comparisonCountBeforeHiddenInvalidation
            )
            #expect(
                admissionFixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact != nil
            )

            #expect(workspace.heldState.beginSpaceHold(requestedTarget: target))
            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = workspace.coordinator.beginHeldPanePreviewPreparation()
            #expect(
                workspace.viewRegistry.allBridgeViews[workspace.targetPane.id]
                    === workspace.targetMountView
            )
            await expectBridgePaneActivity(
                .foreground,
                for: workspace.targetPane.id,
                in: workspace.coordinator,
                because: "re-presenting the target admits the retained stale Review work"
            )
            await waitForActiveReviewRefreshTaskToFinish(admissionFixture.controller)
            #expect(
                await admissionFixture.reviewProvider.recordedComparisonRequestsCount()
                    == comparisonCountBeforeHiddenInvalidation + 1
            )
            #expect(
                admissionFixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"]
            )
            #expect(
                admissionFixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact == nil
            )
            workspace.heldState.endSpaceHold()
            workspace.coordinator.refreshBridgePaneActivities()
            await expectBridgePaneActivity(
                .loadedHidden,
                for: workspace.targetPane.id,
                in: workspace.coordinator,
                because: "releasing the second preview retires product foreground admission"
            )
        }

        @Test("covered Bridge peer stays hidden and catches up only after preview release")
        func coveredBridgePeerStaysHiddenUntilPreviewRelease() async throws {
            let targetAdmission = try await makeRefreshAdmissionIntegrationFixture()
            let peerAdmission = try await makeRefreshAdmissionIntegrationFixture()
            let workspace = makeCoordinatorFixture(
                targetController: targetAdmission.controller,
                targetEndpoint: targetAdmission.headEndpoint,
                peerController: peerAdmission.controller,
                peerEndpoint: peerAdmission.headEndpoint
            )
            await expectBridgePaneActivity(
                .foreground,
                for: workspace.peerPane.id,
                in: workspace.coordinator,
                because: "the canonical peer owns the active tab before preview"
            )
            await waitForActiveReviewRefreshTaskToFinish(peerAdmission.controller)
            let peerComparisonCountBeforePreview =
                await peerAdmission.reviewProvider.recordedComparisonRequestsCount()
            await peerAdmission.reviewProvider.setComparison(peerAdmission.refreshedComparison)
            let target = ValidatedPanePreviewTarget(
                paneID: workspace.targetPane.id,
                owningTabID: workspace.targetTab.id,
                provider: workspace.targetPane.provider,
                sessionID: workspace.targetPane.terminalState?.zmxSessionID
            )

            #expect(workspace.heldState.beginSpaceHold(requestedTarget: target))
            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = workspace.coordinator.beginHeldPanePreviewPreparation()
            await expectBridgePaneActivity(
                .loadedHidden,
                for: workspace.peerPane.id,
                in: workspace.coordinator,
                because: "the canonical peer is covered by the held target"
            )
            await peerAdmission.controller.handleWorktreeProductInvalidation(
                .filesChanged(
                    peerAdmission.makeChangeset(
                        paths: ["Sources/App/CoveredPeer.swift"],
                        batchSequence: 902
                    )
                )
            )
            #expect(
                await peerAdmission.reviewProvider.recordedComparisonRequestsCount()
                    == peerComparisonCountBeforePreview
            )
            #expect(
                peerAdmission.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact != nil
            )

            workspace.heldState.endSpaceHold()
            workspace.coordinator.refreshBridgePaneActivities()
            await expectBridgePaneActivity(
                .foreground,
                for: workspace.peerPane.id,
                in: workspace.coordinator,
                because: "release restores the canonical peer admission"
            )
            await waitForActiveReviewRefreshTaskToFinish(peerAdmission.controller)
            #expect(
                await peerAdmission.reviewProvider.recordedComparisonRequestsCount()
                    == peerComparisonCountBeforePreview + 1
            )
            #expect(peerAdmission.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"])
            await workspace.finish()
            await targetAdmission.finish()
            await peerAdmission.finish()
        }

    }
}
