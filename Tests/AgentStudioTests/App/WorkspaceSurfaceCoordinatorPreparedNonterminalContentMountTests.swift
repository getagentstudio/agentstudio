import AgentStudioRepoExplorer
import AgentStudioWebview
import AppKit
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
    struct PreparedNonterminalContentMountTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("prepared Bridge mount uses the exact accepted pane and settles one generation claim")
        func preparedBridgeMountUsesExactAcceptedPaneAndSettlesOneClaim() async throws {
            // Arrange
            let generation = try makePreparedBridgeContentMountGeneration()
            let acceptedState = BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/accepted/bridge/source",
                    baseline: .unstaged
                )
            )
            let acceptedPane = Pane(
                id: UUIDv7.generate(),
                content: .bridgePanel(acceptedState),
                metadata: PaneMetadata(
                    contentType: .diff,
                    launchDirectory: URL(filePath: "/accepted/bridge/launch-directory"),
                    title: "Accepted Bridge",
                    facets: PaneContextFacets(
                        cwd: URL(filePath: "/accepted/bridge/current-working-directory")
                    ),
                    fillNilLaunchDirectoryFacet: false
                )
            )
            let descriptor = NonterminalContentMountDescriptor(
                content: .bridgePanel(acceptedPane),
                visibilityPriority: .activeVisible,
                hostPlacement: .tab(tabID: UUIDv7.generate())
            )
            let mountInput = NonterminalContentMountInput(entries: [descriptor])
            let store = WorkspaceStore()
            let viewRegistry = ViewRegistry()
            let coordinator = {
                let fixtureSurfaceManager = makeAppTerminalFixtureSurfaceManager()
                return WorkspaceSurfaceCoordinator(
                    store: store,
                    viewRegistry: viewRegistry,
                    runtime: SessionRuntime(store: store),
                    surfaceManager: fixtureSurfaceManager, terminalSurfaceCommandDispatcher: fixtureSurfaceManager,
                    terminalSurfaceOperations: fixtureSurfaceManager.makeTerminalPaneSurfaceOperations(),
                    runtimeRegistry: RuntimeRegistry(),
                    windowLifecycleStore: WindowLifecycleAtom(),
                    ipcLifecycle: .testUnavailable,
                    bridgePaneAttendance: BridgePaneAttendanceAtom()
                )
            }()
            viewRegistry.installPreparedContentMountCohort(
                WorkspacePreparedContentMountCohort(
                    generation: generation,
                    terminalActivationInput: TerminalActivationInput(entries: []),
                    nonterminalContentMountInput: mountInput
                )
            )
            let admissionPort = PreparedNonterminalMountAdmissionPort(
                generation: generation,
                coordinator: coordinator
            )
            let owner = NonterminalContentMountOwner(
                generation: generation,
                input: mountInput,
                admissionPort: admissionPort
            )
            let paneID = PaneId(existingUUID: acceptedPane.id)

            // Act
            let settlement = await owner.mount()

            // Assert
            #expect(settlement.outcomesByPaneID[paneID] == .mounted)
            #expect(
                viewRegistry.preparedContentMountState(for: paneID, generation: generation)
                    == .completed(owner: .nonterminal, disposition: .mounted)
            )
            #expect(
                viewRegistry.claimPreparedContentMount(
                    paneID: paneID,
                    owner: .nonterminal,
                    generation: generation
                )
                    == .rejected(
                        .alreadyClaimed(
                            .completed(owner: .nonterminal, disposition: .mounted)
                        )
                    )
            )

            let mountedBridgeView =
                viewRegistry.view(for: acceptedPane.id)?.mountedContentViewForTesting
                as? BridgePaneMountView
            #expect(mountedBridgeView != nil)
            #expect(mountedBridgeView?.controller.bridgePaneState == acceptedState)
            #expect(coordinator.runtimeForPane(paneID) is BridgeRuntime)

            coordinator.teardownView(for: acceptedPane.id)
            await coordinator.shutdown()
        }

        @Test("held preview publishes an installed nonterminal target through the real sidebar callback")
        func heldPreviewPublishesInstalledNonterminalTargetThroughSidebarCallback() async throws {
            var onSelectedPaneTargetChange:
                (
                    @MainActor (RepoExplorerSelectedPaneTarget?, RepoExplorerSelectedPaneTargetChangeOrigin) -> Void
                )?

            try await withMainSplitViewControllerHarness(
                withRepos: false,
                configureSidebarDependencies: { dependencies in
                    onSelectedPaneTargetChange = dependencies.onSelectedPaneTargetChange
                },
                body: { harness in
                    let pane = harness.store.createPane(
                        content: .webview(
                            WebviewState(url: URL(string: "https://example.com/held-preview")!)
                        ),
                        metadata: PaneMetadata(title: "Preview Webview")
                    )
                    let tab = Tab(paneId: pane.id, name: "Preview")
                    harness.store.appendTab(tab)
                    harness.store.setActiveTab(tab.id)
                    harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(
                        CGRect(x: 0, y: 0, width: 1000, height: 700)
                    )
                    var recordedVisibleQueuedSet: PreparedContentVisibleQueuedSet?
                    harness.coordinator.preparedContentVisibilitySignalHandler = { visibleQueuedSet in
                        recordedVisibleQueuedSet = visibleQueuedSet
                        return []
                    }

                    _ = try #require(harness.coordinator.createViewForContent(pane: pane))
                    let installedView = try #require(
                        harness.coordinator.viewRegistry.webviewView(for: pane.id)
                    )
                    let selectedTarget = RepoExplorerSelectedPaneTarget(
                        paneID: pane.id,
                        owningTabID: tab.id
                    )

                    onSelectedPaneTargetChange?(selectedTarget, .arrowNavigation)

                    let heldState = try #require(harness.controller.heldPanePreviewState)
                    #expect(heldState.requestedTarget?.paneID == pane.id)
                    #expect(
                        recordedVisibleQueuedSet?.visiblePaneIDs.contains(PaneId(existingUUID: pane.id)) == true,
                        "the requested preview target stays in prepared visibility custody while it is pending"
                    )
                    #expect(
                        heldState.presentedTarget?.paneID == pane.id,
                        "an installed nonterminal mount must become presented through the real sidebar callback"
                    )
                    #expect(
                        harness.coordinator.viewRegistry.webviewView(for: pane.id) === installedView,
                        "held preview must reuse the installed Webview mount"
                    )

                    heldState.endSpaceHold()
                    onSelectedPaneTargetChange?(selectedTarget, .arrowNavigation)
                    #expect(heldState.presentedTarget?.paneID == pane.id)
                    #expect(harness.coordinator.viewRegistry.webviewView(for: pane.id) === installedView)
                }
            )
        }

        @Test("held preview accepts a late prepared host only for the current request")
        func heldPreviewAcceptsLatePreparedHostOnlyForCurrentRequest() async throws {
            let store = WorkspaceStore()
            let viewRegistry = ViewRegistry()
            let coordinator = {
                let fixtureSurfaceManager = makeAppTerminalFixtureSurfaceManager()
                return WorkspaceSurfaceCoordinator(
                    store: store,
                    viewRegistry: viewRegistry,
                    runtime: SessionRuntime(store: store),
                    surfaceManager: fixtureSurfaceManager, terminalSurfaceCommandDispatcher: fixtureSurfaceManager,
                    terminalSurfaceOperations: fixtureSurfaceManager.makeTerminalPaneSurfaceOperations(),
                    runtimeRegistry: RuntimeRegistry(),
                    windowLifecycleStore: WindowLifecycleAtom(),
                    ipcLifecycle: .testUnavailable,
                    bridgePaneAttendance: BridgePaneAttendanceAtom()
                )
            }()
            let pane = store.createPane(
                content: .webview(WebviewState(url: URL(string: "https://example.com/late")!)),
                metadata: PaneMetadata(title: "Late preview")
            )
            let tab = Tab(paneId: pane.id, name: "Late")
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            coordinator.windowLifecycleStore.recordTerminalContainerBounds(
                CGRect(x: 0, y: 0, width: 1000, height: 700)
            )
            coordinator.preparedContentVisibilitySignalHandler = { (_: PreparedContentVisibleQueuedSet) in
                Set([PaneId(existingUUID: pane.id)])
            }

            let heldState = HeldPanePreviewState()
            coordinator.bindHeldPanePreviewState(heldState)
            let target = ValidatedPanePreviewTarget(
                paneID: pane.id,
                owningTabID: tab.id,
                provider: pane.provider,
                sessionID: pane.terminalState?.zmxSessionID
            )
            #expect(heldState.beginSpaceHold(requestedTarget: target))
            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = coordinator.beginHeldPanePreviewPreparation()
            #expect(heldState.presentedTarget == nil)

            let mountedView = WebviewPaneMountView(
                paneId: pane.id,
                state: WebviewState(url: URL(string: "https://example.com/late")!)
            )
            _ = coordinator.registerHostedView(mountedView: mountedView, for: pane.id)

            #expect(heldState.presentedTarget == target)
            await coordinator.shutdown()
        }
    }
}

@MainActor
private func makePreparedBridgeContentMountGeneration() throws -> WorkspaceContentMountGeneration {
    WorkspaceContentMountGeneration()
}
