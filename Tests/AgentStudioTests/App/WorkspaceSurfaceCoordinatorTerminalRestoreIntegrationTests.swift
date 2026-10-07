// swiftlint:disable file_length type_body_length
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct WorkspaceSurfaceTerminalRestoreIntegrationTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    private let fixtureSessionConfiguration = SessionConfiguration(
        isEnabled: true,
        zmxPath: "/tmp/fake-zmx",
        zmxDir: "/tmp/fake-zmx-dir",
        healthCheckInterval: 30,
        maxCheckpointAge: 60
    )

    struct Harness {
        let store: WorkspaceStore
        let viewRegistry: ViewRegistry
        let runtime: SessionRuntime
        let coordinator: WorkspaceSurfaceCoordinator
        let windowLifecycleStore: WindowLifecycleAtom
        let surfaceManager: TerminalRestoreCapturingSurfaceManager
        let tempDir: URL
    }

    private func makeHarness(
        ipcLifecycle: WorkspaceSurfaceIPCLifecycle = .testUnavailable
    ) -> Harness {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-luna295-tests-\(UUID().uuidString)")
        let store: WorkspaceStore
        do { store = try makeWorkspaceJournalTestStore() } catch {
            preconditionFailure("Could not prepare the terminal restore harness SQLite store: \(error)")
        }
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let windowLifecycleStore = WindowLifecycleAtom()
        let surfaceManager = TerminalRestoreCapturingSurfaceManager()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: surfaceManager,
            runtimeRegistry: .shared,
            windowLifecycleStore: windowLifecycleStore,
            ipcLifecycle: ipcLifecycle,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        coordinator.sessionConfig = fixtureSessionConfiguration
        coordinator.terminalRestoreRuntime = TerminalRestoreRuntime(
            sessionConfiguration: fixtureSessionConfiguration
        )
        return Harness(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            coordinator: coordinator,
            windowLifecycleStore: windowLifecycleStore,
            surfaceManager: surfaceManager,
            tempDir: tempDir
        )
    }

    func withTerminalRestoreHarness(_ operation: @MainActor (Harness) async throws -> Void) async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        do {
            try await operation(harness)
        } catch {
            await harness.coordinator.shutdown()
            throw error
        }
        await harness.coordinator.shutdown()
    }

    func withRealSurfaceManagerHarness(
        _ operation:
            @MainActor (
                WorkspaceStore,
                ViewRegistry,
                SurfaceManager,
                WindowLifecycleAtom,
                WorkspaceSurfaceCoordinator
            ) async throws -> Void
    ) async throws {
        let store = try makeWorkspaceJournalTestStore()
        let viewRegistry = ViewRegistry()
        let surfaceManager = SurfaceManager(
            maxCreationRetries: 0,
            healthCheckInterval: 3600,
            nativeSurfaceRetirement: { _ in }
        )
        let windowLifecycleStore = WindowLifecycleAtom()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: SessionRuntime(store: store),
            surfaceManager: surfaceManager,
            runtimeRegistry: .shared,
            windowLifecycleStore: windowLifecycleStore,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        do {
            try await operation(store, viewRegistry, surfaceManager, windowLifecycleStore, coordinator)
        } catch {
            await coordinator.shutdown()
            throw error
        }
        await coordinator.shutdown()
    }

    let trustedBounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test("fresh Ghostty shell receives the pane IPC environment")
    func freshGhosttyShellReceivesPaneIPCEnvironment() throws {
        let expectedEnvironment = [
            "AGENTSTUDIO_PANE_ID": "pane-id",
            "AGENTSTUDIO_WORKSPACE_ID": "workspace-id",
            "AGENTSTUDIO_PANE_TOKEN": "pane-token",
        ]
        let harness = makeHarness(
            ipcLifecycle: WorkspaceSurfaceIPCLifecycle(
                environment: { _, _ in expectedEnvironment },
                invalidatePaneIDs: { _ in },
                finalRevokePaneIDs: { _ in }
            )
        )
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .ghostty
        )

        _ = harness.coordinator.createViewForContent(
            pane: pane,
            initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 600)
        )

        #expect(harness.surfaceManager.lastConfig?.environmentVariables == expectedEnvironment)
    }

    @Test("existing zmx attach configuration keeps pane IPC values while isolation keys win")
    func existingZmxAttachConfigurationMergesPaneIPCEnvironment() throws {
        let harness = makeHarness(
            ipcLifecycle: WorkspaceSurfaceIPCLifecycle(
                environment: { _, _ in
                    [
                        "AGENTSTUDIO_PANE_TOKEN": "pane-token",
                        "ZMX_DIR": "/tmp/inherited-zmx-dir",
                        "ZMX_SESSION": "inherited-session",
                        "ZMX_SESSION_PREFIX": "inherited-prefix",
                    ]
                },
                invalidatePaneIDs: { _ in },
                finalRevokePaneIDs: { _ in }
            )
        )
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane(zmxSessionID: .generateUUIDv7())

        _ = harness.coordinator.createViewForContent(
            pane: pane,
            initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 600)
        )

        let config = try #require(harness.surfaceManager.lastConfig)
        #expect(config.startupStrategy.startupCommandForSurface?.contains(" attach ") == true)
        #expect(config.environmentVariables["AGENTSTUDIO_PANE_TOKEN"] == "pane-token")
        #expect(config.environmentVariables["ZMX_DIR"] == fixtureSessionConfiguration.zmxDir)
        #expect(config.environmentVariables["ZMX_SESSION"]?.isEmpty == true)
        #expect(config.environmentVariables["ZMX_SESSION_PREFIX"]?.isEmpty == true)
    }

    @Test
    func preparedTerminalCohort_publishesEveryPlaceholderBeforeSurfaceCreation() async throws {
        try await withTerminalRestoreHarness { harness in
            // Arrange
            let firstPane = makeAcceptedPreparedTerminalPane(launchDirectory: harness.tempDir)
            let secondPane = makeAcceptedPreparedTerminalPane(launchDirectory: harness.tempDir)
            try #require(harness.store.paneAtom.insertRestoredPane(firstPane))
            try #require(harness.store.paneAtom.insertRestoredPane(secondPane))
            let generation = try preparedTerminalCohortGeneration()
            let descriptors = try [firstPane, secondPane].map { pane in
                try preparedTerminalCohortDescriptor(
                    pane: pane,
                    visibilityPriority: .activeVisible,
                    hostPlacement: .tab(tabID: UUIDv7.generate())
                )
            }
            let registry = harness.viewRegistry
            registry.beginInitialRestore()
            let owner = WorkspacePreparedContentMountCoordinator(
                cohort: WorkspacePreparedContentMountCohort(
                    generation: generation,
                    terminalActivationInput: TerminalActivationInput(entries: descriptors),
                    nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
                ),
                viewRegistry: registry,
                terminalAdmissionPort: PreparedTerminalMountAdmissionPort(
                    generation: generation,
                    initialFramesByPaneID: [:],
                    viewRegistry: registry,
                    mountHandler: harness.coordinator,
                    descriptorsByPaneID: Dictionary(uniqueKeysWithValues: descriptors.map { ($0.paneID, $0) })
                ),
                nonterminalAdmissionPort: PreparedNonterminalMountAdmissionPort(
                    generation: generation,
                    coordinator: harness.coordinator
                )
            )

            // Act
            let publication = owner.publishTerminalPlaceholders {
                harness.coordinator.registerPreparedTerminalPlaceholders(for: $0)
            }

            // Assert
            #expect(publication.paneIDs == descriptors.map(\.paneID))
            #expect(harness.surfaceManager.createdPaneIds.isEmpty)
            for descriptor in descriptors {
                #expect(
                    registry.terminalStatusPlaceholderView(for: descriptor.paneID.uuid)?.mode
                        == .preparing
                )
            }
        }
    }

    @Test
    func preparedTerminalMount_rejectsMissingTrustedFrameBeforeSurfaceCreation() async throws {
        try await withTerminalRestoreHarness { harness in
            // Arrange
            let pane = makeAcceptedPreparedTerminalPane(launchDirectory: harness.tempDir)
            try #require(harness.store.paneAtom.insertRestoredPane(pane))
            let admission = try makePreparedTerminalAdmission(pane: pane)

            // Act
            let result = await harness.coordinator.mountPreparedTerminalContent(
                admission: admission,
                initialFrame: nil,
                authority: .released(admission.descriptor.paneID)
            )

            // Assert
            #expect(
                result
                    == .failed(
                        failure: .surfaceCreationFailed(code: "trusted_initial_frame_unavailable"),
                        retry: .doNotRetry
                    )
            )
            #expect(harness.surfaceManager.createdPaneIds.isEmpty)
        }
    }

    @Test
    func heldPreviewColdBackgroundTerminalUsesTrustedFullBoundsWithoutActiveLayout() async throws {
        try await withTerminalRestoreHarness { harness in
            let activePane = harness.store.createPane(launchDirectory: harness.tempDir)
            let previewPane = makeAcceptedPreparedTerminalPane(launchDirectory: harness.tempDir)
            try #require(harness.store.paneAtom.insertRestoredPane(previewPane))
            let activeTab = Tab(paneId: activePane.id, name: "Active")
            let previewTab = Tab(paneId: previewPane.id, name: "Preview")
            harness.store.appendTab(activeTab)
            harness.store.appendTab(previewTab)
            harness.store.setActiveTab(activeTab.id)
            harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

            let heldState = HeldPanePreviewState()
            harness.coordinator.bindHeldPanePreviewState(heldState)
            let target = ValidatedPanePreviewTarget(
                paneID: previewPane.id,
                owningTabID: previewTab.id,
                provider: previewPane.provider,
                sessionID: previewPane.terminalState?.zmxSessionID
            )
            #expect(heldState.beginSpaceHold(requestedTarget: target))

            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = harness.coordinator.beginHeldPanePreviewPreparation()

            #expect(harness.surfaceManager.createdPaneIds == [previewPane.id])
            #expect(harness.surfaceManager.createdConfigsByPaneId[previewPane.id]?.initialFrame == trustedBounds)
            #expect(harness.surfaceManager.lastMetadata?.paneId == previewPane.id)
            #expect(harness.surfaceManager.lastMetadata?.zmxSessionID == previewPane.terminalState?.zmxSessionID)
            #expect(
                harness.surfaceManager.createdConfigsByPaneId[previewPane.id]?
                    .startupStrategy.startupCommandForSurface?
                    .contains(previewPane.terminalState?.zmxSessionID.rawValue ?? "") == true
            )
            #expect(heldState.presentedTarget == nil)
            #expect(heldState.requestedTarget?.paneID == previewPane.id)
        }
    }

    @Test
    func preparedTerminalMount_usesAcceptedPaneAndFrozenFrameWithoutTopologyLookup() async throws {
        try await withTerminalRestoreHarness { harness in
            // Arrange
            let pane = makeAcceptedPreparedTerminalPane(launchDirectory: harness.tempDir)
            try #require(harness.store.paneAtom.insertRestoredPane(pane))
            let admission = try makePreparedTerminalAdmission(pane: pane)
            let frozenFrame = NSRect(x: 12, y: 18, width: 880, height: 540)

            // Act
            let result = await harness.coordinator.mountPreparedTerminalContent(
                admission: admission,
                initialFrame: frozenFrame,
                authority: .released(admission.descriptor.paneID)
            )

            // Assert
            #expect(
                result
                    == .failed(
                        failure: .surfaceCreationFailed(code: "prepared_mount_failed"),
                        retry: .retry
                    )
            )
            #expect(harness.surfaceManager.createdPaneIds == [pane.id])
            #expect(harness.surfaceManager.createdConfigsByPaneId[pane.id]?.initialFrame == frozenFrame)
            let expectedSessionID = try #require(pane.terminalState?.zmxSessionID)
            #expect(
                harness.surfaceManager.createdConfigsByPaneId[pane.id]?
                    .startupStrategy.startupCommandForSurface?
                    .contains(expectedSessionID.rawValue) == true
            )
        }
    }

    @Test
    func newZmxPane_uses_directSurfaceCommand_notDeferredShell() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)

        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )

        _ = harness.coordinator.createView(
            for: pane,
            worktree: worktree,
            repo: repo,
            initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 600)
        )

        let config = try #require(harness.surfaceManager.lastConfig)
        let generatedSessionID = try #require(pane.terminalState?.zmxSessionID)
        let generatedUUID = try #require(UUID(uuidString: generatedSessionID.rawValue))
        #expect(config.startupStrategy.startupCommandForSurface?.contains(" attach ") == true)
        #expect(
            config.startupStrategy.startupCommandForSurface?
                .contains(ZmxBackend.shellEscape(generatedSessionID.rawValue)) == true
        )
        #expect(UUIDv7.isV7(generatedUUID))
        #expect(config.environmentVariables["ZMX_DIR"] == fixtureSessionConfiguration.zmxDir)
        #expect(config.environmentVariables["ZMX_SESSION"]?.isEmpty == true)
        #expect(config.environmentVariables["ZMX_SESSION_PREFIX"]?.isEmpty == true)
    }

    @Test
    func floatingZmxPane_uses_directSurfaceCommand_notDeferredShell() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )

        _ = harness.coordinator.createViewForContent(
            pane: pane,
            initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 600)
        )

        let config = try #require(harness.surfaceManager.lastConfig)
        #expect(config.startupStrategy.startupCommandForSurface?.contains(" attach ") == true)
        #expect(config.environmentVariables["ZMX_DIR"] == fixtureSessionConfiguration.zmxDir)
        #expect(config.environmentVariables["ZMX_SESSION"]?.isEmpty == true)
        #expect(config.environmentVariables["ZMX_SESSION_PREFIX"]?.isEmpty == true)
    }

    @Test
    func floatingZmxPane_withoutPersistedCwd_stillUsesDirectSurfaceCommand() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = harness.store.createPane(
            provider: .zmx
        )

        _ = harness.coordinator.createViewForContent(
            pane: pane,
            initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 600)
        )

        let config = try #require(harness.surfaceManager.lastConfig)
        #expect(config.startupStrategy.startupCommandForSurface?.contains(" attach ") == true)
        #expect(config.environmentVariables["ZMX_DIR"] == fixtureSessionConfiguration.zmxDir)
        #expect(config.environmentVariables["ZMX_SESSION"]?.isEmpty == true)
        #expect(config.environmentVariables["ZMX_SESSION_PREFIX"]?.isEmpty == true)
    }

    @Test
    func preparedContentOwnerRestoresHiddenZmxAfterForegroundWithoutSelection() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let visiblePane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let hiddenPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )

        let visibleTab = Tab(paneId: visiblePane.id, name: "Visible")
        let hiddenTab = Tab(paneId: hiddenPane.id, name: "Hidden")
        harness.store.appendTab(visibleTab)
        harness.store.appendTab(hiddenTab)
        harness.store.setActiveTab(visibleTab.id)

        try await mountPreparedTerminalCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (visiblePane, .activeVisible, .tab(tabID: visibleTab.id)),
                (hiddenPane, .hidden, .tab(tabID: hiddenTab.id)),
            ],
            trustedBounds: trustedBounds
        )
        let visiblePlaceholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: visiblePane.id))
        let hiddenPlaceholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: hiddenPane.id))
        #expect(visiblePlaceholder.mode == .failedToStart)
        #expect(hiddenPlaceholder.mode == .failedToStart)
        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == visiblePane.id }.count == 2)
        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == hiddenPane.id }.count == 2)
        #expect(harness.viewRegistry.isInitialRestorePending == false)

        let creationAttemptsBeforeSelection = harness.surfaceManager.createdPaneIds

        try await harness.coordinator.execute(.selectTab(tabId: hiddenTab.id))

        #expect(harness.surfaceManager.createdPaneIds == creationAttemptsBeforeSelection)
    }

    @Test
    func preparedContentOwner_restoresHiddenDrawerZmxUnderNonZmxParent() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let visiblePane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let hiddenParentPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .ghostty,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )

        let visibleTab = Tab(paneId: visiblePane.id, name: "Visible")
        let hiddenTab = Tab(paneId: hiddenParentPane.id, name: "Hidden")
        harness.store.appendTab(visibleTab)
        harness.store.appendTab(hiddenTab)
        let hiddenDrawerPane = try #require(harness.store.addDrawerPane(to: hiddenParentPane.id))
        harness.store.setActiveTab(visibleTab.id)

        let acceptedHiddenParent = try #require(harness.store.pane(hiddenParentPane.id))
        let hiddenDrawer = try #require(harness.store.pane(hiddenDrawerPane.id))
        let hiddenDrawerID = try #require(acceptedHiddenParent.drawer?.drawerId)
        let drawerViewBeforePreparedMount = try #require(
            harness.store.drawerView(forParent: hiddenParentPane.id)
        )
        try await mountPreparedTerminalCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (visiblePane, .activeVisible, .tab(tabID: visibleTab.id)),
                (acceptedHiddenParent, .hidden, .tab(tabID: hiddenTab.id)),
                (
                    hiddenDrawer,
                    .hidden,
                    .drawer(
                        tabID: hiddenTab.id,
                        parentPaneID: PaneId(existingUUID: hiddenParentPane.id),
                        drawerID: hiddenDrawerID
                    )
                ),
            ],
            trustedBounds: trustedBounds
        )

        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == visiblePane.id }.count == 2)
        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == hiddenParentPane.id }.count == 2)
        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == hiddenDrawerPane.id }.count == 2)
        #expect(harness.viewRegistry.terminalStatusPlaceholderView(for: hiddenParentPane.id) == nil)
        #expect(harness.viewRegistry.terminalStatusPlaceholderView(for: hiddenDrawerPane.id) != nil)
        #expect(harness.surfaceManager.createdConfigsByPaneId[hiddenParentPane.id]?.initialFrame != nil)
        #expect(harness.surfaceManager.createdConfigsByPaneId[hiddenDrawerPane.id]?.initialFrame != nil)
        #expect(harness.store.drawerView(forParent: hiddenParentPane.id) == drawerViewBeforePreparedMount)
    }

    @Test
    func preparedContentOwner_restoresHiddenDrawerAndHiddenZmxParent() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let visiblePane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let hiddenParentPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )

        let visibleTab = Tab(paneId: visiblePane.id, name: "Visible")
        let hiddenTab = Tab(paneId: hiddenParentPane.id, name: "Hidden")
        harness.store.appendTab(visibleTab)
        harness.store.appendTab(hiddenTab)
        let hiddenDrawerPane = try #require(harness.store.addDrawerPane(to: hiddenParentPane.id))
        harness.store.setActiveTab(visibleTab.id)

        let acceptedHiddenParent = try #require(harness.store.pane(hiddenParentPane.id))
        let hiddenDrawer = try #require(harness.store.pane(hiddenDrawerPane.id))
        let hiddenDrawerID = try #require(acceptedHiddenParent.drawer?.drawerId)
        let drawerViewBeforePreparedMount = try #require(
            harness.store.drawerView(forParent: hiddenParentPane.id)
        )
        try await mountPreparedTerminalCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (visiblePane, .activeVisible, .tab(tabID: visibleTab.id)),
                (acceptedHiddenParent, .hidden, .tab(tabID: hiddenTab.id)),
                (
                    hiddenDrawer,
                    .hidden,
                    .drawer(
                        tabID: hiddenTab.id,
                        parentPaneID: PaneId(existingUUID: hiddenParentPane.id),
                        drawerID: hiddenDrawerID
                    )
                ),
            ],
            trustedBounds: trustedBounds
        )

        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == visiblePane.id }.count == 2)
        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == hiddenParentPane.id }.count == 2)
        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == hiddenDrawerPane.id }.count == 2)
        #expect(harness.viewRegistry.terminalStatusPlaceholderView(for: hiddenParentPane.id) != nil)
        #expect(harness.viewRegistry.terminalStatusPlaceholderView(for: hiddenDrawerPane.id) != nil)
        #expect(harness.surfaceManager.createdConfigsByPaneId[hiddenParentPane.id]?.initialFrame != nil)
        #expect(harness.surfaceManager.createdConfigsByPaneId[hiddenDrawerPane.id]?.initialFrame != nil)
        #expect(harness.store.drawerView(forParent: hiddenParentPane.id) == drawerViewBeforePreparedMount)
    }

    @Test
    func preparedContentOwner_passesResolvedInitialFrame_toVisiblePane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )

        let tab = Tab(paneId: pane.id, name: "Visible")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        let containerWidth: CGFloat = 1000
        let containerHeight: CGFloat = 600
        try await mountPreparedTerminalCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [(pane, .activeVisible, .tab(tabID: tab.id))],
            trustedBounds: CGRect(x: 0, y: 0, width: containerWidth, height: containerHeight)
        )

        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[pane.id])
        let gap = AppStyles.General.Layout.paneGap
        #expect(
            config.initialFrame
                == CGRect(x: gap, y: gap, width: containerWidth - gap * 2, height: containerHeight - gap * 2))
    }

    @Test
    func preparedContentOwner_passesResolvedInitialFrame_toExpandedDrawerPane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )

        let tab = Tab(paneId: pane.id, name: "Visible")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let drawerPane = try #require(harness.store.addDrawerPane(to: pane.id))

        let acceptedParentPane = try #require(harness.store.pane(pane.id))
        let acceptedDrawerPane = try #require(harness.store.pane(drawerPane.id))
        let drawerID = try #require(acceptedParentPane.drawer?.drawerId)
        try await mountPreparedTerminalCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (acceptedParentPane, .activeVisible, .tab(tabID: tab.id)),
                (
                    acceptedDrawerPane,
                    .activeVisible,
                    .drawer(
                        tabID: tab.id,
                        parentPaneID: PaneId(existingUUID: pane.id),
                        drawerID: drawerID
                    )
                ),
            ],
            trustedBounds: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[drawerPane.id])
        let frame = try #require(config.initialFrame)
        #expect(frame.width > 0)
        #expect(frame.height > 0)
        #expect(frame.origin.y > 0)
    }

    @Test
    func resolveInitialFramesByTabId_usesCanonicalMinimizedGeometry() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let firstPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let secondPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )

        let tab = Tab(paneId: firstPane.id, name: "Minimized")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        _ = harness.store.insertPane(
            secondPane.id,
            inTab: tab.id,
            at: firstPane.id,
            direction: .horizontal,
            position: .after, sizingMode: .halveTarget
        )
        _ = harness.store.minimizePane(secondPane.id, inTab: tab.id)

        let framesByTabId = harness.coordinator.resolveInitialFramesByTabId(
            in: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )
        let minimizedFrame = try #require(framesByTabId[tab.id]?[secondPane.id])

        #expect(
            minimizedFrame.width
                == AppStyles.Shell.PaneChrome.collapsedBarWidth
                - (AppStyles.General.Layout.paneGap * 2)
        )
    }

    @Test
    func splitRight_newZmxPane_usesTrustedInitialFrame_notPlaceholderGeometry() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let existingPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let tab = Tab(paneId: existingPane.id, name: "Split")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.windowLifecycleStore.recordTerminalContainerBounds(
            CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        let existingPaneIds = Set(harness.store.panes.keys)
        try await harness.coordinator.execute(
            .insertPane(
                source: .newTerminal,
                targetTabId: tab.id,
                targetPaneId: existingPane.id,
                direction: .right,
                sizingMode: .halveTarget
            )
        )

        let newPaneId = try #require(Set(harness.store.panes.keys).subtracting(existingPaneIds).first)
        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[newPaneId])
        let activeTab = try #require(harness.store.activeTab)
        let resolvedFrames = TerminalPaneGeometryResolver.resolveFrames(
            for: activeTab.layout,
            in: harness.windowLifecycleStore.terminalContainerBounds,
            dividerThickness: AppStyles.General.Layout.paneGap,
            minimizedPaneIds: activeTab.activeMinimizedPaneIds,
            collapsedPaneWidth: AppStyles.Shell.PaneChrome.collapsedBarWidth
        )

        #expect(config.initialFrame != nil)
        #expect(config.initialFrame != CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(config.initialFrame == resolvedFrames[newPaneId])
    }

    @Test
    func openNewTerminalTab_usesTrustedInitialFrame_notPlaceholderGeometry() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        harness.windowLifecycleStore.recordTerminalContainerBounds(
            CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        let pane = try #require(try await harness.coordinator.openNewTerminal(for: worktree, in: repo))
        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[pane.id])
        let activeTab = try #require(harness.store.activeTab)
        let resolvedFrames = TerminalPaneGeometryResolver.resolveFrames(
            for: activeTab.layout,
            in: harness.windowLifecycleStore.terminalContainerBounds,
            dividerThickness: AppStyles.General.Layout.paneGap,
            minimizedPaneIds: activeTab.activeMinimizedPaneIds,
            collapsedPaneWidth: AppStyles.Shell.PaneChrome.collapsedBarWidth
        )

        #expect(config.initialFrame != nil)
        #expect(config.initialFrame != CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(config.initialFrame == resolvedFrames[pane.id])
    }

    @Test
    func openFloatingTerminal_usesTrustedInitialFrame_notPlaceholderGeometry() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        harness.windowLifecycleStore.recordTerminalContainerBounds(
            CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        let pane = try #require(
            try await harness.coordinator.openFloatingTerminal(launchDirectory: harness.tempDir, title: "Floating")
        )
        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[pane.id])
        let activeTab = try #require(harness.store.activeTab)
        let resolvedFrames = TerminalPaneGeometryResolver.resolveFrames(
            for: activeTab.layout,
            in: harness.windowLifecycleStore.terminalContainerBounds,
            dividerThickness: AppStyles.General.Layout.paneGap,
            minimizedPaneIds: activeTab.activeMinimizedPaneIds,
            collapsedPaneWidth: AppStyles.Shell.PaneChrome.collapsedBarWidth
        )

        #expect(config.initialFrame != nil)
        #expect(config.initialFrame != CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(config.initialFrame == resolvedFrames[pane.id])
    }

    @Test
    func openNewTerminalTab_defersSurfaceCreation_untilBoundsExist_thenCreatesWithTrustedFrame() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)

        let pane = try #require(try await harness.coordinator.openNewTerminal(for: worktree, in: repo))
        #expect(harness.surfaceManager.createdConfigsByPaneId[pane.id] == nil)
        let preparingPlaceholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id))
        #expect(preparingPlaceholder.mode == .preparing)

        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
        harness.coordinator.restoreViewsForActiveTabIfNeeded()

        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[pane.id])
        let failedPlaceholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id))
        let activeTab = try #require(harness.store.activeTab)
        let resolvedFrames = TerminalPaneGeometryResolver.resolveFrames(
            for: activeTab.layout,
            in: harness.windowLifecycleStore.terminalContainerBounds,
            dividerThickness: AppStyles.General.Layout.paneGap,
            minimizedPaneIds: activeTab.activeMinimizedPaneIds,
            collapsedPaneWidth: AppStyles.Shell.PaneChrome.collapsedBarWidth
        )

        #expect(config.initialFrame == resolvedFrames[pane.id])
        #expect(failedPlaceholder.mode == .failedToStart)
    }

    @Test
    func targetedRepair_retriesFloatingTerminalPreparingPlaceholderWhenBoundsExist() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = try #require(
            try await harness.coordinator.openFloatingTerminal(launchDirectory: harness.tempDir, title: "Floating")
        )
        #expect(harness.surfaceManager.createdConfigsByPaneId[pane.id] == nil)
        let preparingPlaceholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id))
        #expect(preparingPlaceholder.mode == .preparing)

        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
        harness.coordinator.restoreViewsForActiveTabIfNeeded()

        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[pane.id])
        let failedPlaceholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id))
        let activeTab = try #require(harness.store.activeTab)
        let resolvedFrames = TerminalPaneGeometryResolver.resolveFrames(
            for: activeTab.layout,
            in: harness.windowLifecycleStore.terminalContainerBounds,
            dividerThickness: AppStyles.General.Layout.paneGap,
            minimizedPaneIds: activeTab.activeMinimizedPaneIds,
            collapsedPaneWidth: AppStyles.Shell.PaneChrome.collapsedBarWidth
        )

        #expect(config.initialFrame == resolvedFrames[pane.id])
        #expect(failedPlaceholder.mode == .failedToStart)
    }

    @Test
    func openNewTerminalTab_failedCreation_keepsFailurePlaceholderVisible() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        let pane = try #require(try await harness.coordinator.openNewTerminal(for: worktree, in: repo))

        let placeholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id))
        #expect(placeholder.mode == .failedToStart)
    }

    @Test
    func failedToStartPlaceholder_doesNotAutoRetryOnLaterBoundsChanges() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        let pane = try #require(try await harness.coordinator.openNewTerminal(for: worktree, in: repo))
        let createAttemptsBefore = harness.surfaceManager.createdPaneIds.count
        let placeholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id))

        #expect(placeholder.mode == .failedToStart)
        #expect(placeholder.shouldRetryCreationWhenBoundsChange == false)

        harness.windowLifecycleStore.recordTerminalContainerBounds(
            CGRect(x: 0, y: 0, width: 1200, height: 700)
        )
        harness.coordinator.restoreViewsForActiveTabIfNeeded()

        #expect(harness.surfaceManager.createdPaneIds.count == createAttemptsBefore)
        #expect(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id)?.mode == .failedToStart)
    }

    @Test
    func createViewForContentUsingCurrentGeometry_withoutBounds_returnsNil_andDoesNotReachSurfaceManager() async throws
    {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let pane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )

        let view = harness.coordinator.createViewForContentUsingCurrentGeometry(pane: pane)

        #expect(view == nil)
        let placeholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id))
        #expect(placeholder.mode == .preparing)
        #expect(harness.surfaceManager.lastConfig == nil)
        #expect(harness.surfaceManager.createdPaneIds.isEmpty)
    }

    @Test
    func aRevealOfAPaneUnderPreparedCustodyCreatesNothing() async throws {
        // Arrange
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane(launchDirectory: harness.tempDir)
        let tab = Tab(paneId: pane.id, name: "Reveal")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
        harness.windowLifecycleStore.recordLaunchLayoutSettled()

        let generation = try preparedTerminalCohortGeneration()
        let descriptor = try preparedTerminalCohortDescriptor(
            pane: pane,
            visibilityPriority: .activeVisible,
            hostPlacement: .tab(tabID: tab.id)
        )
        let registry = harness.viewRegistry
        registry.beginInitialRestore()
        // Constructing the owner alone installs the cohort into ViewRegistry
        // (pane custody becomes `.pending(owner: .terminal)`); `.mount()` is
        // never called, so the pane is never claimed.
        _ = WorkspacePreparedContentMountCoordinator(
            cohort: WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            ),
            viewRegistry: registry,
            terminalAdmissionPort: PreparedTerminalMountAdmissionPort(
                generation: generation,
                initialFramesByPaneID: [:],
                viewRegistry: registry,
                mountHandler: harness.coordinator,
                descriptorsByPaneID: [descriptor.paneID: descriptor]
            ),
            nonterminalAdmissionPort: PreparedNonterminalMountAdmissionPort(
                generation: generation,
                coordinator: harness.coordinator
            )
        )
        harness.coordinator.acceptedPreparedContentMountGeneration = generation

        // Act
        harness.coordinator.restoreVisiblePaneIfNeeded(pane.id, forceWhenBoundsExist: true)

        // Assert: the prepared lane still owns this pane, so the steady-state
        // reveal path creates nothing.
        #expect(harness.surfaceManager.createdPaneIds.isEmpty)
    }

    @Test
    func aRevealOfAReleasedPaneStillCreatesNormally() async throws {
        // Arrange
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane(launchDirectory: harness.tempDir)
        let tab = Tab(paneId: pane.id, name: "Reveal")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
        harness.windowLifecycleStore.recordLaunchLayoutSettled()

        // Act: no cohort has ever been installed for any generation, so this
        // pane's custody is absent — `terminalSurfaceCreationAuthority`
        // returns `.released` and steady-state creation proceeds.
        harness.coordinator.restoreVisiblePaneIfNeeded(pane.id, forceWhenBoundsExist: true)

        // Assert
        #expect(harness.surfaceManager.createdPaneIds == [pane.id])
    }
}
