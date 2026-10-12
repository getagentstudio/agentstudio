import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// Proof of successful surface creation, attachment, and reuse — a real
/// Ghostty surface actually mounting and being reused across restore and
/// tab-switch — lives in the debug-app runtime proof recorded on PR #330,
/// not in this file. Every fake surface manager here always fails
/// `createSurface`, so a "two createSurface calls" assertion in this suite
/// proves one admission cycle ran (attempt 1 retry, attempt 2 doNotRetry),
/// never that a surface was actually created.
@MainActor
@Suite(.serialized)
struct PaneTabViewControllerLaunchRestoreTests {
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

    private struct Harness {
        let store: WorkspaceStore
        let viewRegistry: ViewRegistry
        let runtime: SessionRuntime
        let coordinator: WorkspaceSurfaceCoordinator
        let executor: WorkspaceActionExecutor
        let appLifecycleStore: AppLifecycleAtom
        let windowLifecycleStore: WindowLifecycleAtom
        let applicationLifecycleMonitor: ApplicationLifecycleMonitor
        let controller: PaneTabViewController
        let surfaceManager: LaunchCapturingSurfaceManager
        let window: NSWindow
        let tempDir: URL
    }

    private func makeHarness() -> Harness {
        let atomRegistry = AtomRegistry(core: CoreAtomScope.store)
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-tab-launch-tests-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let appLifecycleStore = AppLifecycleAtom()
        let windowLifecycleStore = WindowLifecycleAtom()
        let applicationLifecycleMonitor = ApplicationLifecycleMonitor(
            appLifecycleStore: appLifecycleStore,
            windowLifecycleStore: windowLifecycleStore
        )
        let surfaceManager = LaunchCapturingSurfaceManager()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: surfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: windowLifecycleStore,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: atomRegistry.bridgePaneAttendance
        )
        coordinator.sessionConfig = fixtureSessionConfiguration
        coordinator.terminalRestoreRuntime = TerminalRestoreRuntime(
            sessionConfiguration: fixtureSessionConfiguration
        )
        let executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
        let controller = PaneTabViewController(
            store: store,
            octiconLoader: makeTestOcticonLoader(),
            repoCache: RepoCacheAtom(),
            applicationLifecycleMonitor: applicationLifecycleMonitor,
            appLifecycleStore: appLifecycleStore,
            executor: executor,
            runtimeCommandDispatcher: coordinator,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(), synchronizeRuntimeFocus: { _ in },
            tabBarAdapter: TabBarAdapter(
                store: store,
                repoCache: RepoCacheAtom(),
            ),
            viewRegistry: viewRegistry,
            bridgePaneAttendance: atomRegistry.bridgePaneAttendance,
            editorChooser: atomRegistry.editorChooser,
            heldPanePreviewState: HeldPanePreviewState(),
            registersAsCommandHandler: false
        )
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1200, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView?.layoutSubtreeIfNeeded()

        return Harness(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            coordinator: coordinator,
            executor: executor,
            appLifecycleStore: appLifecycleStore,
            windowLifecycleStore: windowLifecycleStore,
            applicationLifecycleMonitor: applicationLifecycleMonitor,
            controller: controller,
            surfaceManager: surfaceManager,
            window: window,
            tempDir: tempDir
        )
    }

    @Test
    func layout_writesNonEmptyBoundsToWindowLifecycleStore() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        harness.controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        harness.controller.view.layoutSubtreeIfNeeded()

        #expect(harness.windowLifecycleStore.terminalContainerBounds.width > 0)
        #expect(harness.windowLifecycleStore.terminalContainerBounds.height > 0)
        #expect(harness.windowLifecycleStore.isReadyForLaunchRestore == false)
    }

    @Test
    func settledLayoutWithRecordedBounds_makesStoreReadyForLaunchRestore() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        harness.controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        harness.controller.view.layoutSubtreeIfNeeded()
        harness.applicationLifecycleMonitor.handleLaunchLayoutSettled()

        #expect(harness.windowLifecycleStore.isLaunchLayoutSettled == true)
        #expect(harness.windowLifecycleStore.isReadyForLaunchRestore == true)
    }

    @Test
    func restoreViewsForActiveTabIfNeeded_doesNotCreateViewsBeforeLaunchLayoutSettles() {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let tab = Tab(paneId: pane.id, name: "Early Restore")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        harness.windowLifecycleStore.recordTerminalContainerBounds(
            CGRect(x: 0, y: 0, width: 512, height: 552)
        )
        #expect(harness.windowLifecycleStore.isReadyForLaunchRestore == false)

        harness.coordinator.restoreViewsForActiveTabIfNeeded()

        #expect(harness.surfaceManager.createdPaneIds.isEmpty)
    }

    @Test
    func settledLayout_defersSurfaceCreationUntilLayoutCallbackUnwinds() async {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let tab = Tab(paneId: pane.id, name: "Deferred Restore")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        harness.applicationLifecycleMonitor.handleLaunchLayoutSettled()
        harness.controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        harness.controller.view.layoutSubtreeIfNeeded()

        #expect(harness.surfaceManager.createdPaneIds.isEmpty)

        await Task.yield()

        #expect(harness.surfaceManager.createdPaneIds == [pane.id])
    }

    @Test
    func initialLaunchRestore_attemptsVisibleZmxSurfaceCreation() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let tab = Tab(paneId: pane.id, name: "Initial Placeholder")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let frame = NSRect(x: 8, y: 8, width: 1184, height: 784)
        try await mountPreparedContent(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            terminalDescriptors: [
                try preparedTerminalDescriptor(
                    pane: pane,
                    visibilityPriority: .activeVisible,
                    hostPlacement: .tab(tabID: tab.id)
                )
            ],
            nonterminalDescriptors: [],
            initialFramesByPaneID: [PaneId(existingUUID: pane.id): frame]
        )

        let placeholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id))
        #expect(placeholder.mode == .failedToStart)
        #expect(placeholder.shouldRetryCreationWhenBoundsChange == false)
        #expect(harness.surfaceManager.createdPaneIds == [pane.id, pane.id])
        #expect(harness.viewRegistry.isInitialRestorePending == false)
    }

    @Test
    func initialLaunchRestore_mountsNonTerminalVisiblePane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = harness.store.createPane(
            content: .webview(
                WebviewState(
                    url: try #require(URL(string: "https://example.com/initial-webview")),
                    showNavigation: true
                )
            ),
            metadata: PaneMetadata(
                title: "Initial Webview"
            )
        )
        let tab = Tab(paneId: pane.id, name: "Initial Webview")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        try await mountPreparedContent(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            terminalDescriptors: [],
            nonterminalDescriptors: [
                NonterminalContentMountDescriptor(
                    content: .webview(pane),
                    visibilityPriority: .activeVisible,
                    hostPlacement: .tab(tabID: tab.id)
                )
            ],
            initialFramesByPaneID: [:]
        )

        #expect(harness.viewRegistry.webviewView(for: pane.id) != nil)
        #expect(harness.surfaceManager.createdPaneIds.isEmpty)
        #expect(harness.viewRegistry.isInitialRestorePending == false)
    }

    @Test
    func preparedContentOwner_initialRestoreAttemptsZmxTerminalSurfaceCreation() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let tab = Tab(paneId: pane.id, name: "Initial Full Restore")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        try await mountPreparedContent(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            terminalDescriptors: [
                try preparedTerminalDescriptor(
                    pane: pane,
                    visibilityPriority: .activeVisible,
                    hostPlacement: .tab(tabID: tab.id)
                )
            ],
            nonterminalDescriptors: [],
            initialFramesByPaneID: [
                PaneId(existingUUID: pane.id): CGRect(x: 8, y: 8, width: 1184, height: 784)
            ]
        )

        let placeholder = try #require(harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id))
        #expect(placeholder.mode == .failedToStart)
        #expect(placeholder.shouldRetryCreationWhenBoundsChange == false)
        #expect(harness.surfaceManager.createdPaneIds == [pane.id, pane.id])
        #expect(harness.viewRegistry.isInitialRestorePending == false)
    }

    @Test
    func terminalRestoreDoesNotExposeManualPausedStartupState() throws {
        let sourcePaths = [
            "Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ActiveTabRestore.swift",
            "Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ViewLifecycle.swift",
            "Sources/AgentStudio/Features/Terminal/Hosting/TerminalStatusPlaceholderView.swift",
            "Sources/AgentStudio/Features/Terminal/Views/SurfaceErrorOverlay.swift",
        ]

        for sourcePath in sourcePaths {
            let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: sourcePath)
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            #expect(!source.contains("restorationPaused"))
            #expect(!source.contains("Terminal Restore Paused"))
            #expect(!source.contains("Start Terminal"))
        }
    }

    @Test
    func preparedContentOwner_usesFrozenLifecycleStoreBounds() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let tab = Tab(paneId: pane.id, name: "Launch Restore")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        let containerWidth: CGFloat = 1000
        let containerHeight: CGFloat = 600
        harness.windowLifecycleStore.recordTerminalContainerBounds(
            CGRect(x: 0, y: 0, width: containerWidth, height: containerHeight)
        )

        let resolvedFramesByTabID = harness.coordinator.resolveInitialFramesByTabId(
            in: harness.windowLifecycleStore.terminalContainerBounds
        )
        let initialFrame = try #require(resolvedFramesByTabID[tab.id]?[pane.id])
        try await mountPreparedContent(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            terminalDescriptors: [
                try preparedTerminalDescriptor(
                    pane: pane,
                    visibilityPriority: .activeVisible,
                    hostPlacement: .tab(tabID: tab.id)
                )
            ],
            nonterminalDescriptors: [],
            initialFramesByPaneID: [PaneId(existingUUID: pane.id): initialFrame]
        )

        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[pane.id])
        let gap = AppStyles.General.Layout.paneGap
        #expect(
            config.initialFrame
                == CGRect(x: gap, y: gap, width: containerWidth - gap * 2, height: containerHeight - gap * 2))
    }

    @Test
    func appLifecycleChanges_doNotReplaceActiveTabHost() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir,
            provider: .zmx
        )
        let tab = Tab(paneId: pane.id, name: "Lifecycle")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.controller.view.layoutSubtreeIfNeeded()

        let originalTabHost = try #require(harness.controller.tabHostViewForTesting(tabId: tab.id))
        #expect(harness.controller.appLifecycleStoreForTesting === harness.appLifecycleStore)

        harness.applicationLifecycleMonitor.handleApplicationDidBecomeActive()
        harness.controller.view.layoutSubtreeIfNeeded()

        let updatedTabHost = try #require(harness.controller.tabHostViewForTesting(tabId: tab.id))
        #expect(updatedTabHost === originalTabHost)

        harness.applicationLifecycleMonitor.handleApplicationDidResignActive()
        harness.controller.view.layoutSubtreeIfNeeded()

        let tabHostAfterResign = try #require(harness.controller.tabHostViewForTesting(tabId: tab.id))
        #expect(tabHostAfterResign === originalTabHost)
    }

    /// Bounded state wait for the scheduler's supplemental drain — spawned by
    /// `TerminalActivationScheduler.acceptLaterGeometry` as an unstructured
    /// `Task` the S9 reevaluation tail never awaits — to reach the effect
    /// under test. Never a wall-clock sleep: each iteration only yields the
    /// MainActor so the drain's already-queued work can run, and the loop
    /// returns the instant `condition` is true. The iteration cap is a
    /// safety net against a genuine hang, not a timer. Returns whether
    /// `condition` was ever observed true — every call site must `#expect`
    /// this rather than let budget exhaustion pass silently.
    private func waitUntil(iterations: Int = 20_000, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<iterations {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    @Test
    func switchingToATabOfAlreadyMountedTerminalsInvokesCreateSurfaceZeroTimes() async throws {
        // Arrange: `targetPane` is settled to `.completed(.mounted)` custody
        // directly. A genuinely successful `createSurface` needs a real
        // Ghostty surface, which no fake surface manager in this repo can
        // produce (every one, including this file's, always fails).
        // Registering a real `TerminalPaneMountView` with a stable
        // `surfaceId` — never attached via `displaySurface`, matching how
        // `restoreView` builds one before attaching — reproduces "the
        // prepared lane already mounted this pane's host" without one.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        harness.windowLifecycleStore.recordTerminalContainerBounds(
            CGRect(x: 0, y: 0, width: 1200, height: 800)
        )
        harness.applicationLifecycleMonitor.handleLaunchLayoutSettled()

        let sourcePane = harness.store.createPane(launchDirectory: harness.tempDir, provider: .zmx)
        let sourceTab = Tab(paneId: sourcePane.id, name: "Source")
        harness.store.appendTab(sourceTab)
        harness.store.setActiveTab(sourceTab.id)

        let targetPane = harness.store.createPane(launchDirectory: harness.tempDir, provider: .zmx)
        let targetTab = Tab(paneId: targetPane.id, name: "Target")
        harness.store.appendTab(targetTab)

        let generation = try preparedContentGeneration()
        let targetDescriptor = try preparedTerminalDescriptor(
            pane: targetPane,
            visibilityPriority: .hidden,
            hostPlacement: .tab(tabID: targetTab.id)
        )
        harness.viewRegistry.beginInitialRestore()
        harness.viewRegistry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [targetDescriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        let targetPaneID = PaneId(existingUUID: targetPane.id)
        #expect(
            harness.viewRegistry.claimPreparedContentMount(
                paneID: targetPaneID, owner: .terminal, generation: generation)
                == .accepted
        )
        let stableSurfaceID = UUID()
        let alreadyMountedView = TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(),
            restoredSurfaceId: stableSurfaceID,
            paneId: targetPane.id,
            title: "Already Mounted"
        )
        harness.coordinator.registerHostedView(mountedView: alreadyMountedView, for: targetPane.id)
        harness.viewRegistry.settlePreparedContentMount(
            paneID: targetPaneID, owner: .terminal, generation: generation, disposition: .mounted
        )
        harness.viewRegistry.completeInitialRestore()
        harness.coordinator.acceptedPreparedContentMountGeneration = generation

        // Act: drive the real tab selection path —
        // `PaneTabViewController.selectTabAndRestoreVisibleViews` forwards to
        // exactly this executor call.
        harness.store.setActiveTab(targetTab.id)
        harness.executor.restoreVisibleViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)

        // Assert: zero creations, unchanged surface ID.
        #expect(harness.surfaceManager.createdPaneIds.isEmpty)
        #expect(harness.viewRegistry.terminalView(for: targetPane.id)?.surfaceId == stableSurfaceID)
    }

    @Test
    func aDeferredPaneCompletesOneAdmissionCycleAsTwoFailedCreateSurfaceCallsWhenGeometryArrives() async throws {
        // Arrange: `deferredPane` is withheld from the initial frame set so
        // it settles `deferredGeometry` custody. Its tab is deliberately not
        // appended to the store until after the cohort mount below returns:
        // this harness's controller is a real, mounted `PaneTabViewController`
        // in a real window, and appending a tab can trigger a real AppKit
        // layout pass that (via this test file's S9 wiring) calls the
        // geometry-reevaluation tail on its own. If that real pass lands
        // while `TerminalActivationScheduler.activate()` is between "no
        // queued candidates remain" and computing its one-time aggregate
        // settlement, `acceptLaterGeometry` requeuing this pane in that
        // window crashes `makeSettlement()`'s "cohort settled with
        // unfinished members" precondition — a genuine, pre-existing
        // scheduler race this test must not trip by accident. Deferring the
        // tab append until after `mountPreparedContent` returns (settlement
        // already locked in) keeps this test's own real-layout activity
        // outside that window; see the same note where this test discovered
        // that race for reference.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        #expect(!harness.windowLifecycleStore.terminalContainerBounds.isEmpty)
        harness.applicationLifecycleMonitor.handleLaunchLayoutSettled()

        let deferredPane = harness.store.createPane(launchDirectory: harness.tempDir, provider: .zmx)
        let deferredTab = Tab(paneId: deferredPane.id, name: "Deferred")

        // `mounted` is captured (not discarded) and kept alive for the rest
        // of this test: `coordinator.preparedTerminalGeometryReevaluationHandler`
        // only holds `mounted.port`/`mounted.owner` `weak`,
        // matching production's lifetime contract.
        let mounted = try await mountPreparedContent(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            terminalDescriptors: [
                try preparedTerminalDescriptor(
                    pane: deferredPane, visibilityPriority: .hidden, hostPlacement: .tab(tabID: deferredTab.id))
            ],
            nonterminalDescriptors: [],
            initialFramesByPaneID: [:]
        )
        harness.store.appendTab(deferredTab)

        // Act: reveal the deferred pane's tab. The steady-state path must
        // create nothing on its own while the prepared lane still owns the
        // pane — this is the exact guard S5's cutover added: reverting it
        // lets this reveal create a surface immediately, independent of
        // whatever real layout has or has not already done.
        harness.store.setActiveTab(deferredTab.id)
        harness.executor.restoreVisibleViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)
        #expect(
            await waitUntil { harness.surfaceManager.createdPaneIds.filter { $0 == deferredPane.id }.count == 2 },
            "deferredPane never reached two createSurface calls"
        )

        // Assert: exactly one admission cycle — the two low-level
        // `createSurface` calls this harness's always-failing surface
        // manager produces for one real admission (attempt 1 retry, attempt
        // 2 `.doNotRetry`). A regression that lets the steady-state reveal
        // also create, in addition to the prepared lane's own admission,
        // would push this past two.
        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == deferredPane.id }.count == 2)
        // Keeps `mounted` alive through the `await` above. Swift's ARC
        // releases a local at its last syntactic use, not merely at end of
        // scope, so this must be the last line.
        withExtendedLifetime(mounted) {}
    }

    @Test
    func revealAndPreparedRequeueOverlapCompleteOneAdmissionCycleAsTwoFailedCreateSurfaceCallsWithOneSurfaceIdentity()
        async throws
    {
        // Arrange: `overlapPane` is withheld from the initial frame set so it
        // settles `deferredGeometry` custody. Its tab is appended to the
        // store *before* the cohort mount below — the original, natural
        // ordering (no test-side workaround). Before S10b's scheduler fix,
        // this exact ordering intermittently (about 1 run in 3) crashed with
        // `TerminalActivationScheduler.swift:557: Fatal error: terminal
        // activation cohort settled with unfinished members`: appending the
        // tab can trigger this harness's real, mounted controller to
        // independently run the S9 geometry-reevaluation tail via real
        // AppKit layout *during* `mountPreparedContent`'s own `await
        // owner.mount()`, landing `acceptLaterGeometry` in the exact window
        // between `activate()`'s drain deciding no candidate remains and
        // `makeSettlement()` locking in. S10b's `while hasQueuedMember()`
        // retry in `activate()` closes that window; this test restores the
        // ordering that originally exposed it, rather than routing around it,
        // to prove the fix rather than the workaround is what makes this safe.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        #expect(!harness.windowLifecycleStore.terminalContainerBounds.isEmpty)
        harness.applicationLifecycleMonitor.handleLaunchLayoutSettled()

        let overlapPane = harness.store.createPane(launchDirectory: harness.tempDir, provider: .zmx)
        let overlapTab = Tab(paneId: overlapPane.id, name: "Overlap")
        harness.store.appendTab(overlapTab)

        // Held alive for the rest of the test — see the note in
        // `aDeferredPaneCompletesOneAdmissionCycleAsTwoFailedCreateSurfaceCallsWhenGeometryArrives`.
        let mounted = try await mountPreparedContent(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            terminalDescriptors: [
                try preparedTerminalDescriptor(
                    pane: overlapPane, visibilityPriority: .hidden, hostPlacement: .tab(tabID: overlapTab.id))
            ],
            nonterminalDescriptors: [],
            initialFramesByPaneID: [:]
        )

        // Act: reveal the pane's tab — any real layout the tab-append above
        // triggered during mount, and this explicit reveal, race each other.
        harness.store.setActiveTab(overlapTab.id)
        harness.executor.restoreVisibleViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)
        #expect(
            await waitUntil { harness.surfaceManager.createdPaneIds.filter { $0 == overlapPane.id }.count == 2 },
            "overlapPane never reached two createSurface calls"
        )

        // Assert: exactly one admission cycle, one surface identity.
        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == overlapPane.id }.count == 2)
        #expect(harness.surfaceManager.createdConfigsByPaneId[overlapPane.id] != nil)
        withExtendedLifetime(mounted) {}
    }

    @Test
    func oneVisibilityChangeRevealingMainAndDrawerPanesAdmitsTheFullPromotedBatchInTierOrder() async throws {
        // Arrange: a tab with a main split (`activeMainPane`, `mainSiblingPane`)
        // and an expanded drawer (`activeDrawerPane` active,
        // `siblingDrawerPane` not), all four withheld from the initial frame
        // set so all four settle `deferredGeometry` custody. The descriptor
        // list below is the reverse of the expected admission order, so a
        // rank derived from source ordinal rather than the promoted tier
        // would fail this test.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        #expect(!harness.windowLifecycleStore.terminalContainerBounds.isEmpty)
        harness.applicationLifecycleMonitor.handleLaunchLayoutSettled()

        let activeMainPane = harness.store.createPane(launchDirectory: harness.tempDir, provider: .zmx)
        let tab = Tab(paneId: activeMainPane.id, name: "Promoted Batch")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        let mainSiblingPane = harness.store.createPane(launchDirectory: harness.tempDir, provider: .zmx)
        _ = harness.store.insertPane(
            mainSiblingPane.id,
            inTab: tab.id,
            at: activeMainPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        // `WorkspaceTabArrangementAtom.insertPane` (Sources/AgentStudio/Core/State/MainActor/Atoms/WorkspaceTabArrangementAtom.swift:260)
        // deliberately reassigns the arrangement's `activePaneId` to the pane
        // just inserted — splitting a pane focuses the new pane, matching
        // real UX. Left alone, `mainSiblingPane` — not `activeMainPane` —
        // would be the one `StoreVisibilityTierResolver.isActive` (Sources/AgentStudio/Features/Terminal/Restore/TerminalRestoreScheduler.swift:56)
        // ranks active, since it checks `activeTab.activePaneId`. Restoring
        // `activeMainPane` here is test setup catching up with real product
        // behavior, not a workaround for a product defect.
        harness.store.setActivePane(activeMainPane.id, inTab: tab.id)

        let activeDrawerPane = try #require(harness.store.addDrawerPane(to: activeMainPane.id))
        let siblingDrawerPane = try #require(harness.store.addDrawerPane(to: activeMainPane.id))
        harness.store.setActiveDrawerPane(activeDrawerPane.id, in: activeMainPane.id)
        let drawerID = try #require(harness.store.pane(activeMainPane.id)?.drawer?.drawerId)

        let acceptedActiveMainPane = try #require(harness.store.pane(activeMainPane.id))
        let acceptedMainSiblingPane = try #require(harness.store.pane(mainSiblingPane.id))
        let acceptedActiveDrawerPane = try #require(harness.store.pane(activeDrawerPane.id))
        let acceptedSiblingDrawerPane = try #require(harness.store.pane(siblingDrawerPane.id))

        // Flushes the layout AppKit already wants to run for the tab/split/
        // drawer structure above before any cohort exists (a harmless no-op
        // for the S9 reevaluation tail, since nothing is deferred yet),
        // instead of leaving it pending to fire during `mountPreparedContent`'s
        // `await`. See the note in
        // `aDeferredPaneCompletesOneAdmissionCycleAsTwoFailedCreateSurfaceCallsWhenGeometryArrives` for the
        // pre-existing scheduler race a layout pass landing during that
        // window can trigger; this test's four-way tier-order assertion
        // additionally needs the one visibility change below to be the only
        // reevaluation trigger, not a race with an uncontrolled real one.
        harness.controller.view.layoutSubtreeIfNeeded()

        let mounted = try await mountPreparedContent(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            terminalDescriptors: [
                try preparedTerminalDescriptor(
                    pane: acceptedSiblingDrawerPane,
                    visibilityPriority: .hidden,
                    hostPlacement: .drawer(
                        tabID: tab.id, parentPaneID: PaneId(existingUUID: activeMainPane.id), drawerID: drawerID)
                ),
                try preparedTerminalDescriptor(
                    pane: acceptedActiveDrawerPane,
                    visibilityPriority: .hidden,
                    hostPlacement: .drawer(
                        tabID: tab.id, parentPaneID: PaneId(existingUUID: activeMainPane.id), drawerID: drawerID)
                ),
                try preparedTerminalDescriptor(
                    pane: acceptedMainSiblingPane, visibilityPriority: .hidden, hostPlacement: .tab(tabID: tab.id)),
                try preparedTerminalDescriptor(
                    pane: acceptedActiveMainPane, visibilityPriority: .hidden, hostPlacement: .tab(tabID: tab.id)),
            ],
            nonterminalDescriptors: [],
            initialFramesByPaneID: [:]
        )

        // Act: one visibility change — reveal the tab that holds all four.
        // (This harness's real, mounted controller may also independently
        // trigger the S9 geometry-reevaluation tail via its own AppKit
        // layout — see the note in
        // `aDeferredPaneCompletesOneAdmissionCycleAsTwoFailedCreateSurfaceCallsWhenGeometryArrives` — but all
        // four panes' tab/drawer placement is already fully structured
        // above, before that can happen, so whichever trigger fires first
        // still resolves and promotes all four together.)
        harness.executor.restoreVisibleViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)
        #expect(
            await waitUntil { harness.surfaceManager.createdPaneIds.filter { $0 == siblingDrawerPane.id }.count == 2 },
            "siblingDrawerPane never reached two createSurface calls"
        )

        // Assert: admitted active-main, then main sibling, then active
        // drawer, then drawer sibling — the tier order, not the deliberately
        // reversed source-ordinal order the descriptors above were listed in.
        // Each expected pane's actual first-admission index is required to
        // exist (a pane never admitted at all fails loudly here instead of
        // silently comparing as tied with everything else), then the actual
        // admission sequence — `expectedOrder` reordered by those indices —
        // is compared against `expectedOrder` itself.
        let expectedOrder = [activeMainPane.id, mainSiblingPane.id, activeDrawerPane.id, siblingDrawerPane.id]
        let firstAdmissionIndices = try expectedOrder.map { paneID in
            try #require(harness.surfaceManager.createdPaneIds.firstIndex(of: paneID), "\(paneID) was never admitted")
        }
        let actualAdmissionOrder = zip(expectedOrder, firstAdmissionIndices)
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        #expect(actualAdmissionOrder == expectedOrder)
        withExtendedLifetime(mounted) {}
    }

    @Test
    func theExactStoredZmxSessionIdentityIsUsedAcrossOneAdmissionCycleOfTwoFailedCreateSurfaceCalls() async throws {
        // The tab is not appended until after the cohort mount returns — see
        // the note in `aDeferredPaneCompletesOneAdmissionCycleAsTwoFailedCreateSurfaceCallsWhenGeometryArrives`
        // for the pre-existing scheduler race that ordering avoids.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        #expect(!harness.windowLifecycleStore.terminalContainerBounds.isEmpty)
        harness.applicationLifecycleMonitor.handleLaunchLayoutSettled()

        let storedSessionID = ZmxSessionID.generateUUIDv7()
        let pane = harness.store.createPane(
            launchDirectory: harness.tempDir, provider: .zmx, zmxSessionID: storedSessionID)
        let tab = Tab(paneId: pane.id, name: "Deferred Identity")

        let mounted = try await mountPreparedContent(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            terminalDescriptors: [
                try preparedTerminalDescriptor(
                    pane: pane, visibilityPriority: .hidden, hostPlacement: .tab(tabID: tab.id))
            ],
            nonterminalDescriptors: [],
            initialFramesByPaneID: [:]
        )
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        // Act: reveal the pane's tab.
        harness.executor.restoreVisibleViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)
        #expect(
            await waitUntil { harness.surfaceManager.createdPaneIds.filter { $0 == pane.id }.count == 2 },
            "pane never reached two createSurface calls"
        )

        // Assert: exactly one admission cycle (two low-level calls, matching
        // this harness's always-failing attempt-1-retry/attempt-2-fail
        // convention — never a third, which would mean a duplicate attach),
        // and the created config's startup command carries the pane's own
        // already-persisted session identity, not a freshly generated one.
        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == pane.id }.count == 2)
        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[pane.id])
        #expect(
            config.startupStrategy.startupCommandForSurface?
                .contains(ZmxBackend.shellEscape(storedSessionID.rawValue)) == true
        )
        withExtendedLifetime(mounted) {}
    }
}

/// The concrete owners `mountPreparedContent` installs, returned so a caller
/// that needs the accepted generation (to gate `terminalSurfaceCreationAuthority`)
/// or to drive a later geometry reevaluation directly can reach them. The
/// `WorkspaceSurfaceCoordinator` only holds `port`/`owner`
/// through its `weak`-captured reevaluation handler, matching the production
/// lifetime contract, so tests that outlive one MainActor turn must keep a
/// strong reference themselves.
private struct MountedPreparedContent {
    let generation: WorkspaceContentMountGeneration
    let port: PreparedTerminalMountAdmissionPort
    let owner: WorkspacePreparedContentMountCoordinator
}

@MainActor
@discardableResult
private func mountPreparedContent(
    coordinator: WorkspaceSurfaceCoordinator,
    viewRegistry: ViewRegistry,
    terminalDescriptors: [TerminalActivationDescriptor],
    nonterminalDescriptors: [NonterminalContentMountDescriptor],
    initialFramesByPaneID: [PaneId: NSRect]
) async throws -> MountedPreparedContent {
    let generation = try preparedContentGeneration()
    let cohort = WorkspacePreparedContentMountCohort(
        generation: generation,
        terminalActivationInput: TerminalActivationInput(entries: terminalDescriptors),
        nonterminalContentMountInput: NonterminalContentMountInput(entries: nonterminalDescriptors)
    )
    viewRegistry.beginInitialRestore()
    // Matches `AppDelegate+LaunchRestore.swift`'s real sequencing: the port
    // starts `.awaitingInstallation` so `installTrustedInitialFrames` can
    // defer any cohort pane without a frame, and that call only happens
    // after the coordinator's own init has installed the cohort into
    // `viewRegistry` (a pane must be `.pending` before it can be deferred).
    let port = PreparedTerminalMountAdmissionPort(
        generation: generation,
        viewRegistry: viewRegistry,
        mountHandler: coordinator,
        descriptorsByPaneID: Dictionary(uniqueKeysWithValues: terminalDescriptors.map { ($0.paneID, $0) })
    )
    let owner = WorkspacePreparedContentMountCoordinator(
        cohort: cohort,
        viewRegistry: viewRegistry,
        terminalAdmissionPort: port,
        nonterminalAdmissionPort: PreparedNonterminalMountAdmissionPort(
            generation: generation,
            coordinator: coordinator
        )
    )
    // Threads the accepted generation into the coordinator and wires the two
    // signal handlers exactly as `AppDelegate+WorkspaceBoot.swift` wires them
    // in production (S9's `preparedTerminalGeometryReevaluationHandler` and
    // S4's `preparedContentVisibilitySignalHandler`), so the steady-state
    // creation paths and the geometry-reevaluation tail behave identically to
    // a real boot instead of taking the "no accepted generation" release
    // fallback the five pre-S10 tests in this file never needed.
    coordinator.acceptedPreparedContentMountGeneration = generation
    coordinator.preparedContentVisibilitySignalHandler = { [weak owner] visibleQueuedSet in
        owner?.handleVisibilitySignals(for: visibleQueuedSet) ?? []
    }
    coordinator.preparedTerminalGeometryReevaluationHandler = { [weak port, weak owner] framesByPaneID in
        guard let port, let owner else { return }
        let acceptedPaneIDs = port.acceptLaterTrustedFrames(framesByPaneID)
        guard !acceptedPaneIDs.isEmpty else { return }
        await owner.acceptTerminalGeometry(acceptedPaneIDs)
    }
    let eligibleTerminalPaneIDs = port.installTrustedInitialFrames(initialFramesByPaneID)
    await owner.installTerminalGeometryAvailability(eligibleTerminalPaneIDs)
    _ = await owner.mount()
    return MountedPreparedContent(generation: generation, port: port, owner: owner)
}

@MainActor
private func preparedContentGeneration() throws -> WorkspaceContentMountGeneration {
    WorkspaceContentMountGeneration()
}

private func preparedTerminalDescriptor(
    pane: Pane,
    visibilityPriority: TerminalActivationVisibilityPriority,
    hostPlacement: TerminalHostPlacementIdentity
) throws -> TerminalActivationDescriptor {
    guard case .terminal = pane.content else {
        preconditionFailure("prepared terminal descriptor requires terminal content")
    }
    return TerminalActivationDescriptor(
        pane: pane,
        visibilityPriority: visibilityPriority,
        hostPlacement: hostPlacement
    )
}

@MainActor
private final class LaunchCapturingSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    private(set) var createdPaneIds: [UUID] = []
    private(set) var createdConfigsByPaneId: [UUID: Ghostty.SurfaceConfiguration] = [:]

    func syncFocus(activeSurfaceId _: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        if let paneId = metadata.paneId {
            createdPaneIds.append(paneId)
            createdConfigsByPaneId[paneId] = config
        }
        return .failure(.operationFailed("capture only"))
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        _ = surfaceId
        _ = paneId
        return nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        _ = surfaceId
        _ = reason
    }

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {
        _ = surfaceId
    }
}
