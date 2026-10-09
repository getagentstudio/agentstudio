import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCodeViewer
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct WorkspaceSurfaceCoordinatorViewFactoryTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("createViewForContent registers a host whose mounted content is a webview mount")
        func createViewForContent_registersHostedWebviewView() {
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            let viewRegistry = harness.viewRegistry
            let coordinator = harness.coordinator
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let pane = Pane(
                id: UUIDv7.generate(),
                content: .webview(WebviewState(url: URL(string: "https://example.com")!)),
                metadata: PaneMetadata()
            )

            let maybeView = coordinator.createViewForContent(pane: pane)
            let registered = viewRegistry.view(for: pane.id)

            #expect(maybeView is WebviewPaneMountView)
            #expect(!(maybeView is PaneHostView))
            #expect(registered != nil)
            #expect(registered?.mountedContentViewForTesting is WebviewPaneMountView)
            #expect(viewRegistry.allWebviewViews.count == 1)
            #expect(viewRegistry.allWebviewViews[pane.id] === maybeView as? WebviewPaneMountView)
        }

        @Test("createViewForContent registers a host whose mounted content is a code viewer mount")
        func createViewForContent_registersHostedCodeViewerView() {
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            let viewRegistry = harness.viewRegistry
            let coordinator = harness.coordinator
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let pane = Pane(
                id: UUIDv7.generate(),
                content: .codeViewer(
                    CodeViewerState(filePath: URL(fileURLWithPath: "/tmp/example.swift"), scrollToLine: 42)
                ),
                metadata: PaneMetadata()
            )

            let maybeView = coordinator.createViewForContent(pane: pane)
            let registered = viewRegistry.view(for: pane.id)

            #expect(maybeView is CodeViewerPaneMountView)
            #expect(!(maybeView is PaneHostView))
            #expect(registered != nil)
            #expect(registered?.mountedContentViewForTesting is CodeViewerPaneMountView)
            #expect(viewRegistry.registeredPaneIds == Set([pane.id]))
        }

        @Test("createViewForContent builds bridge mounted content under a host and teardown clears bridge readiness")
        func createViewForContent_bridgeView_tearsDownCleanly() async {
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            let viewRegistry = harness.viewRegistry
            let coordinator = harness.coordinator
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let pane = Pane(
                id: UUIDv7.generate(),
                content: .bridgePanel(BridgePaneState(panelKind: .diffViewer, source: .commit(sha: "abc123"))),
                metadata: PaneMetadata()
            )

            let maybeView = coordinator.createViewForContent(pane: pane)
            guard let bridgeView = maybeView as? BridgePaneMountView else {
                Issue.record("Expected a BridgePaneMountView")
                return
            }
            let registered = viewRegistry.view(for: pane.id)
            #expect(registered != nil)
            #expect(registered?.mountedContentViewForTesting === bridgeView)
            let bridgeController = bridgeView.controller
            #expect(bridgeController.isBridgeReady == false)

            bridgeController.handleBridgeReady()
            #expect(bridgeController.isBridgeReady == true)

            coordinator.teardownView(for: pane.id)

            #expect(bridgeController.isBridgeReady == false)
            #expect(coordinator.pendingBridgePaneRetirementCount == 1)
            #expect(viewRegistry.view(for: pane.id) != nil)

            await coordinator.drainBridgePaneRetirements()

            #expect(coordinator.pendingBridgePaneRetirementCount == 0)
            #expect(viewRegistry.view(for: pane.id) == nil)
            #expect(viewRegistry.registeredPaneIds == Set<UUID>())
        }

        @Test("terminal teardown remains synchronous and never enters Bridge retirement tracking")
        func terminalViewTeardownRemainsSynchronous() {
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            let paneId = UUIDv7.generate()
            let terminalView = TerminalPaneMountView(paneId: paneId, title: "Terminal")
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }
            harness.coordinator.registerHostedView(mountedView: terminalView, for: paneId)

            harness.coordinator.teardownView(for: paneId)

            #expect(harness.coordinator.pendingBridgePaneRetirementCount == 0)
            #expect(harness.viewRegistry.view(for: paneId) == nil)
        }

        @Test("quick Bridge restore evicts old replay before creating a fresh controller")
        func quickBridgeRestoreWaitsForRetirementBeforeRecreation() async throws {
            // Arrange
            let paneEventBus = EventBus<RuntimeEnvelope>(
                name: #function,
                replayConfiguration: .init(
                    capacityPerSource: 4,
                    sourceKey: { $0.source.description }
                )
            )
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness(paneEventBus: paneEventBus)
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let pane = harness.store.createPane(
                content: .bridgePanel(
                    BridgePaneState(panelKind: .diffViewer, source: .commit(sha: "quick-restore"))
                ),
                metadata: PaneMetadata(
                    title: "Bridge Review",
                    facets: PaneContextFacets(cwd: tempDir)
                )
            )
            harness.store.appendTab(Tab(paneId: pane.id))
            let provider = BridgePaneProductSessionProviderGate()
            let productAdmissionGate = BridgeProductAdmissionGate()
            let productAdmission = try #require(productAdmissionGate.acquire())
            let installation = BridgePaneController.makeInitialProductSessionInstallation(
                paneSessionId: pane.id.uuidString,
                provider: provider,
                productAdmissionGate: productAdmissionGate
            )
            let owner = BridgePaneController.makeProductSessionOwner(
                paneSessionId: pane.id.uuidString,
                provider: provider,
                productAdmissionGate: productAdmissionGate,
                activeInstallation: installation
            )
            let controller = BridgePaneController(
                paneId: pane.id,
                state: BridgePaneState(panelKind: .diffViewer, source: .commit(sha: "quick-restore")),
                appRootURL: testBridgeAppRootURL(),
                metadata: pane.metadata,
                initialPaneActivity: .foreground,
                productSessionDependencies: BridgePaneProductSessionDependencies(
                    installation: installation,
                    owner: owner
                )
            )
            let mountedView = BridgePaneMountView(paneId: pane.id, controller: controller)
            harness.coordinator.registerHostedView(mountedView: mountedView, for: pane.id)
            harness.coordinator.registerRuntime(controller.runtime)
            let runtimePaneId = PaneId(existingUUID: pane.id)
            _ = await paneEventBus.post(makeBridgeReplayEnvelope(paneId: runtimePaneId, sequence: 1))
            try await openBridgePaneProductSession(installation)
            let metadataReply = try await startBridgePaneProductMetadataReply(
                installation: installation,
                provider: provider
            )
            await provider.failNextLifecycleAcknowledgementThenHoldRetries()

            // Act
            harness.coordinator.teardownView(for: pane.id)
            _ = await provider.waitForLifecycleAcknowledgement(count: 2)
            let restoredWhileRetiring = harness.coordinator.createViewForContent(pane: pane)

            // Assert
            #expect(restoredWhileRetiring === mountedView)
            #expect(harness.coordinator.pendingBridgePaneRetirementCount == 1)
            #expect(await owner.activeInstallation == nil)
            let lifecycleAcknowledgements = await provider.lifecycleAcknowledgements
            #expect(lifecycleAcknowledgements.count == 2)
            #expect(lifecycleAcknowledgements[0] == lifecycleAcknowledgements[1])
            await #expect(throws: BridgePaneProductSessionOwnerError.ownerDisposed) {
                _ = try await owner.prepareCandidate(productAdmission: productAdmission)
            }

            await provider.releaseLifecycleAcknowledgements(result: true)
            await harness.coordinator.drainBridgePaneRetirements()
            _ = try? await metadataReply.value

            let replacementView = try #require(
                harness.viewRegistry.view(for: pane.id)?.mountedContent(as: BridgePaneMountView.self)
            )
            #expect(replacementView !== mountedView)
            #expect(replacementView.controller !== controller)
            #expect(replacementView.controller.runtime !== controller.runtime)
            #expect(harness.coordinator.pendingBridgePaneRetirementCount == 0)
            #expect((await owner.snapshot()).hasZeroResidue)

            let replayProbe = await paneEventBus.subscribe(
                policy: .criticalUnbounded,
                subscriberName: "quickBridgeRestoreReplayProbe"
            )
            _ = await paneEventBus.post(makeBridgeReplayEnvelope(paneId: runtimePaneId, sequence: 2))
            var replayIterator = replayProbe.makeAsyncIterator()
            #expect((await replayIterator.next())?.seq == 2)

            harness.coordinator.teardownView(for: pane.id)
            await harness.coordinator.drainBridgePaneRetirements()
        }

        @Test("coordinator shutdown retires Bridge panes without restoring them")
        func shutdownDoesNotRestoreRetiredBridgePane() async throws {
            // Arrange
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let pane = harness.store.createPane(
                content: .bridgePanel(
                    BridgePaneState(panelKind: .diffViewer, source: .commit(sha: "shutdown"))
                ),
                metadata: PaneMetadata(
                    title: "Bridge Review",
                    facets: PaneContextFacets(cwd: tempDir)
                )
            )
            harness.store.appendTab(Tab(paneId: pane.id))
            _ = try #require(harness.coordinator.createViewForContent(pane: pane))
            #expect(harness.coordinator.runtimeForPane(PaneId(existingUUID: pane.id)) is BridgeRuntime)

            // Act
            await harness.coordinator.shutdown()

            // Assert
            #expect(harness.viewRegistry.view(for: pane.id) == nil)
            #expect(harness.coordinator.runtimeForPane(PaneId(existingUUID: pane.id)) == nil)
            #expect(harness.coordinator.pendingBridgePaneRetirementCount == 0)
        }

        @Test("a close strengthens an in-flight Bridge repair retirement")
        func closeStrengthensInFlightBridgeRepairRetirement() async throws {
            // Arrange
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let pane = harness.store.createPane(
                content: .bridgePanel(
                    BridgePaneState(panelKind: .diffViewer, source: .commit(sha: "repair-close"))
                ),
                metadata: PaneMetadata(
                    title: "Bridge Review",
                    facets: PaneContextFacets(cwd: tempDir)
                )
            )
            harness.store.appendTab(Tab(paneId: pane.id))
            _ = try #require(harness.coordinator.createViewForContent(pane: pane))
            #expect(harness.coordinator.runtimeForPane(PaneId(existingUUID: pane.id)) is BridgeRuntime)

            // Act
            harness.coordinator.teardownView(for: pane.id, shouldUnregisterRuntime: false)
            harness.coordinator.teardownView(for: pane.id, shouldUnregisterRuntime: true)
            await harness.coordinator.drainBridgePaneRetirements()

            // Assert
            #expect(harness.viewRegistry.view(for: pane.id) == nil)
            #expect(harness.coordinator.runtimeForPane(PaneId(existingUUID: pane.id)) == nil)
            #expect(harness.coordinator.pendingBridgePaneRetirementCount == 0)
        }

        @Test("retired worker command is refused while successor serves and cleanup is held")
        func retiredWorkerCommandIsRefusedWhileSuccessorServes() async throws {
            // Arrange
            let paneId = UUIDv7.generate()
            let provider = BridgePaneProductSessionProviderGate()
            let productAdmissionGate = BridgeProductAdmissionGate()
            let initialInstallation = BridgePaneController.makeInitialProductSessionInstallation(
                paneSessionId: paneId.uuidString,
                provider: provider,
                productAdmissionGate: productAdmissionGate
            )
            let owner = BridgePaneController.makeProductSessionOwner(
                paneSessionId: paneId.uuidString,
                provider: provider,
                productAdmissionGate: productAdmissionGate,
                activeInstallation: initialInstallation
            )
            var deliveredRequestIds: [String] = []
            let schemeRouter = await owner.schemeRouter
            let handler = BridgeSchemeHandler(
                paneId: paneId, appRootURL: testBridgeAppRootURL(), productSessionRouter: schemeRouter
            )
            var deliveredInstallations: [BridgeProductSessionInstallation] = []
            let controller = BridgePaneController(
                paneId: paneId,
                state: BridgePaneState(panelKind: .diffViewer, source: .commit(sha: "rotation")),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground,
                productSessionDependencies: BridgePaneProductSessionDependencies(
                    installation: initialInstallation,
                    owner: owner
                ),
                productSessionBootstrapSink: { _, requestId, installation, _, _ in
                    deliveredRequestIds.append(requestId)
                    deliveredInstallations.append(installation)
                }
            )
            await controller.enqueueProductSessionBootstrapRequest(
                requestId: "bootstrap-initial",
                reason: .initial
            )
            try await openBridgePaneProductSession(initialInstallation)
            let metadataReply = try await startBridgePaneProductMetadataReply(
                installation: initialInstallation,
                provider: provider
            )
            await provider.holdLifecycleAcknowledgements()

            // Act
            let replacementTask = Task { @MainActor in
                await controller.enqueueProductSessionBootstrapRequest(
                    requestId: "bootstrap-replacement",
                    reason: .workerReplacement
                )
            }
            _ = await provider.waitForLifecycleAcknowledgement(count: 1)
            await replacementTask.value

            // Assert
            let replacementInstallation = try #require(deliveredInstallations.last)
            #expect(!(await provider.lifecycleAcknowledgementsWereReleased))
            #expect(deliveredRequestIds == ["bootstrap-initial", "bootstrap-replacement"])
            #expect(
                (await owner.activeInstallation)?.bootstrap.workerInstanceId
                    == replacementInstallation.bootstrap.workerInstanceId
            )
            #expect(
                (await owner.schemeRouter.activeInstallation)?.bootstrap.workerInstanceId
                    == replacementInstallation.bootstrap.workerInstanceId
            )

            let staleReply = try await assertRetiredPaneProductCommandRefusal(
                installation: initialInstallation,
                handler: handler
            )

            let successorResponse = try await openBridgePaneProductSessionThroughRouter(
                installation: replacementInstallation,
                handler: handler
            )
            if case .workerSessionAccepted(let accepted) = successorResponse {
                #expect(accepted.correlation.workerInstanceId == replacementInstallation.bootstrap.workerInstanceId)
            } else {
                Issue.record("Expected the live successor to accept its worker session while cleanup is held")
            }
            #expect(!(await provider.lifecycleAcknowledgementsWereReleased))

            await provider.releaseLifecycleAcknowledgements(result: true)
            _ = try? await metadataReply.value

            #expect(
                replacementInstallation.bootstrap.workerInstanceId
                    != initialInstallation.bootstrap.workerInstanceId
            )
            #expect(replacementInstallation.capabilityBytes != initialInstallation.capabilityBytes)
            #expect((await initialInstallation.session.producerSnapshot()).hasZeroResidue)
            let afterCleanupReply = try await assertRetiredPaneProductCommandRefusal(
                installation: initialInstallation,
                handler: handler
            )
            #expect(afterCleanupReply.response?.statusCode == 403)
            #expect(afterCleanupReply.body == staleReply.body)
            #expect((await replacementInstallation.session.snapshot.controlReplay).nextExpectedRequestSequence == 2)

            #expect(await controller.beginTeardown().value)
        }

        @Test("createViewForContent derives Bridge workspace identity from source root before bootstrap")
        func createViewForContent_bridgeWorkspaceSourceDerivesMissingWorktreeFacets() {
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            let store = harness.store
            let coordinator = harness.coordinator
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(at: tempDir.appending(path: "repo"))
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }
            let pane = Pane(
                id: UUIDv7.generate(),
                content: .bridgePanel(
                    BridgePaneState(
                        panelKind: .diffViewer,
                        source: .workspace(
                            rootPath: worktree.path.path,
                            baseline: .localDefaultBranch(branchName: "main")
                        )
                    )
                ),
                metadata: PaneMetadata(
                    contentType: .diff,
                    launchDirectory: worktree.path,
                    title: "Bridge Review"
                )
            )

            let maybeView = coordinator.createViewForContent(pane: pane)
            guard let bridgeView = maybeView as? BridgePaneMountView else {
                Issue.record("Expected a BridgePaneMountView")
                return
            }

            #expect(bridgeView.controller.runtime.metadata.repoId == repo.id)
            #expect(bridgeView.controller.runtime.metadata.worktreeId == worktree.id)
            #expect(bridgeView.controller.runtime.metadata.cwd == worktree.path)
        }

        @Test("createViewForContent repairs restored FileView identity from pane working directory")
        func createViewForContent_restoredFileViewerDerivesWorktreeFacetsFromCWD() {
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            let store = harness.store
            let coordinator = harness.coordinator
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let repo = store.addRepo(at: tempDir.appending(path: "repo"))
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }
            let pane = Pane(
                id: UUIDv7.generate(),
                content: .bridgePanel(
                    BridgePaneState(
                        panelKind: .fileViewer,
                        source: nil
                    )
                ),
                metadata: PaneMetadata(
                    contentType: .diff,
                    launchDirectory: worktree.path,
                    title: "Files",
                    facets: PaneContextFacets(cwd: worktree.path)
                )
            )

            let maybeView = coordinator.createViewForContent(pane: pane)
            guard let bridgeView = maybeView as? BridgePaneMountView else {
                Issue.record("Expected a BridgePaneMountView")
                return
            }
            let script = bridgeView.controller.bootstrapScriptSourceForTesting

            #expect(bridgeView.controller.runtime.metadata.repoId == repo.id)
            #expect(bridgeView.controller.runtime.metadata.worktreeId == worktree.id)
            #expect(bridgeView.controller.runtime.metadata.cwd == worktree.path)
            #expect(script.contains("const APP_PROTOCOL = \"worktree-file\""))
            #expect(script.contains("data-bridge-app-protocol"))
            #expect(!script.contains("data-bridge-worktree-file-source-spec"))
            #expect(!script.contains(repo.id.uuidString))
            #expect(!script.contains(worktree.id.uuidString))
        }

        @Test("review bootstrap keeps Review route without exposing File source identity")
        func reviewBootstrapKeepsReviewRouteWithoutFileSourceIdentity() {
            let rootPath = URL(fileURLWithPath: "/tmp/agentstudio-review-root")

            let artifacts = BridgePaneController.makeBootstrapArtifacts(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: rootPath.path,
                        baseline: .localDefaultBranch(branchName: "main"))
                ),
                telemetryScopeGate: BridgeTelemetryScopeGate(enabledScopes: []),
                viewerOpenTelemetryAnchor: nil,
                bridgeWorld: .page
            )

            #expect(artifacts.script.source.contains("const APP_PROTOCOL = \"review\""))
            #expect(artifacts.script.source.contains("data-bridge-app-protocol"))
            #expect(!artifacts.script.source.contains("data-bridge-worktree-file-source-spec"))
        }

        @Test("file viewer bootstrap selects Worktree/File route without source identity")
        func fileViewerBootstrapSelectsWorktreeFileRouteWithoutSourceIdentity() {
            let paneId = UUIDv7.generate()
            let rootPath = URL(fileURLWithPath: "/tmp/agentstudio-file-view-root")
            let state = BridgePaneState(
                panelKind: .fileViewer,
                source: .workspace(
                    rootPath: rootPath.path,
                    baseline: .localDefaultBranch(branchName: "main"))
            )

            let artifacts = BridgePaneController.makeBootstrapArtifacts(
                paneId: paneId,
                state: state,
                telemetryScopeGate: BridgeTelemetryScopeGate(enabledScopes: []),
                viewerOpenTelemetryAnchor: nil,
                bridgeWorld: .page
            )

            #expect(artifacts.script.source.contains("const APP_PROTOCOL = \"worktree-file\""))
            #expect(artifacts.script.source.contains("data-bridge-app-protocol"))
            #expect(!artifacts.script.source.contains("data-bridge-worktree-file-source-spec"))
            #expect(!artifacts.script.source.contains(StableKey.fromPath(rootPath)))
        }

        @Test("Bridge bootstrap transports the App-owned viewer-open anchor unchanged")
        func bridgeBootstrapTransportsAppOwnedViewerOpenAnchor() {
            let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
            let anchor = BridgeViewerOpenTelemetryAnchor(
                openEpochUnixMillis: 1_750_000_000_123,
                traceparent: traceparent
            )

            let artifacts = BridgePaneController.makeBootstrapArtifacts(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                telemetryScopeGate: BridgeTelemetryScopeGate(enabledScopes: [.web]),
                viewerOpenTelemetryAnchor: anchor,
                bridgeWorld: .page
            )

            #expect(artifacts.script.source.contains("1750000000123"))
            #expect(artifacts.script.source.contains(traceparent))
        }

        @Test("Bridge bootstrap does not fabricate a user-open anchor for non-user construction")
        func bridgeBootstrapDoesNotFabricateUserOpenAnchor() {
            let artifacts = BridgePaneController.makeBootstrapArtifacts(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                telemetryScopeGate: BridgeTelemetryScopeGate(enabledScopes: [.web]),
                viewerOpenTelemetryAnchor: nil,
                bridgeWorld: .page
            )

            #expect(!artifacts.script.source.contains("viewerOpenEpochUnixMillis"))
            #expect(!artifacts.script.source.contains("viewerOpenTraceparent"))
        }

        @Test("createViewForContent registers runtime for bridge, webview, and code viewer panes")
        func createViewForContent_registersNonTerminalRuntimes() {
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            let coordinator = harness.coordinator
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let webviewPane = Pane(
                id: UUIDv7.generate(),
                content: .webview(WebviewState(url: URL(string: "https://example.com/runtime-web")!)),
                metadata: PaneMetadata()
            )
            let bridgePane = Pane(
                id: UUIDv7.generate(),
                content: .bridgePanel(BridgePaneState(panelKind: .diffViewer, source: .commit(sha: "def456"))),
                metadata: PaneMetadata()
            )
            let fileURL = FileManager.default.temporaryDirectory
                .appending(path: "code-view-runtime-\(UUID().uuidString).swift")
            try? "struct Runtime {}\n".write(to: fileURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let codeViewerPane = Pane(
                id: UUIDv7.generate(),
                content: .codeViewer(CodeViewerState(filePath: fileURL, scrollToLine: 1)),
                metadata: PaneMetadata(
                    contentType: .codeViewer,
                    launchDirectory: fileURL.deletingLastPathComponent(),
                    title: "Code"
                )
            )

            _ = coordinator.createViewForContent(pane: webviewPane)
            _ = coordinator.createViewForContent(pane: bridgePane)
            _ = coordinator.createViewForContent(pane: codeViewerPane)

            #expect(coordinator.runtimeForPane(PaneId(existingUUID: webviewPane.id)) is WebviewRuntime)
            #expect(coordinator.runtimeForPane(PaneId(existingUUID: bridgePane.id)) is BridgeRuntime)
            #expect(coordinator.runtimeForPane(PaneId(existingUUID: codeViewerPane.id)) is SwiftPaneRuntime)
        }

        @Test("createViewForContent returns nil for unsupported pane content")
        func createViewForContent_unsupportedContentReturnsNil() {
            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            let viewRegistry = harness.viewRegistry
            let coordinator = harness.coordinator
            let tempDir = harness.tempDir
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let pane = Pane(
                id: UUIDv7.generate(),
                content: .unsupported(UnsupportedContent(type: "legacy", version: 1, rawState: nil)),
                metadata: PaneMetadata()
            )

            let maybeView = coordinator.createViewForContent(pane: pane)

            #expect(maybeView == nil)
            #expect(viewRegistry.view(for: pane.id) == nil)
            #expect(viewRegistry.registeredPaneIds.isEmpty)
        }

        @Test("floating zmx restore uses stored session IDs for drawer panes")
        func floatingZmxRestoreSessionId_drawerPane_usesStoredSessionId() {
            let parentPaneId = UUIDv7.generate()
            let drawerPaneId = UUIDv7.generate()
            let storedSessionID = ZmxSessionID.generateUUIDv7()
            let pane = Pane(
                id: drawerPaneId,
                content: .terminal(
                    TerminalState(
                        provider: .zmx,
                        lifetime: .persistent,
                        zmxSessionID: storedSessionID
                    )
                ),
                metadata: PaneMetadata(
                    launchDirectory: URL(fileURLWithPath: "/Users/test"),
                    title: "Drawer"
                ),
                kind: .drawerChild(parentPaneId: parentPaneId)
            )

            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let sessionID = harness.coordinator.terminalRestoreRuntime.zmxSessionID(for: pane)

            #expect(sessionID == storedSessionID)
        }

        @Test("floating zmx restore uses stored session IDs for top-level floating panes")
        func floatingZmxRestoreSessionId_topLevelFloatingPane_usesStoredSessionId() {
            let paneId = UUIDv7.generate()
            let launchDirectory = URL(fileURLWithPath: "/Users/test/project")
            let storedSessionID = ZmxSessionID.generateUUIDv7()
            let pane = Pane(
                id: paneId,
                content: .terminal(
                    TerminalState(
                        provider: .zmx,
                        lifetime: .persistent,
                        zmxSessionID: storedSessionID
                    )
                ),
                metadata: PaneMetadata(
                    launchDirectory: launchDirectory,
                    title: "Floating"
                )
            )

            let harness = makeWorkspaceSurfaceCoordinatorViewFactoryHarness()
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            let sessionID = harness.coordinator.terminalRestoreRuntime.zmxSessionID(for: pane)

            #expect(sessionID == storedSessionID)
        }
    }
}
