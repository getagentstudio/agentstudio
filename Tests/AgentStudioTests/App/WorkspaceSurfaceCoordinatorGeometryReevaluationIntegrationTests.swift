import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// S9 — canonical geometry-change reevaluation tail (SPEC R5 retry; the R1
/// clause that hidden, minimized, and collapsed panes hydrate once geometry
/// becomes safe, without ever being revealed). These cases live in their own
/// suite rather than
/// `WorkspaceSurfaceCoordinatorTerminalRestoreIntegrationTests.swift` or
/// `WorkspaceSurfaceCoordinatorDrawerRestoreIntegrationTests.swift` because
/// both of those files already sit at the repo's SwiftLint `file_length`
/// ceiling (999 and 883 of 1000 lines).
@MainActor
@Suite(.serialized)
struct WorkspaceGeometryReevaluationIntegrationTests {
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

    let trustedBounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    struct Harness {
        let store: WorkspaceStore
        let viewRegistry: ViewRegistry
        let runtime: SessionRuntime
        let coordinator: WorkspaceSurfaceCoordinator
        let windowLifecycleStore: WindowLifecycleAtom
        let surfaceManager: GeometryReevaluationCapturingSurfaceManager
        let tempDir: URL
    }

    private func makeHarness() -> Harness {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-geometry-reevaluation-tests-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let windowLifecycleStore = WindowLifecycleAtom()
        let surfaceManager = GeometryReevaluationCapturingSurfaceManager()
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

    func withGeometryReevaluationHarness<TResult>(
        _ operation: @MainActor (Harness) async throws -> TResult
    ) async throws -> TResult {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        do {
            let result = try await operation(harness)
            await harness.coordinator.shutdown()
            return result
        } catch {
            await harness.coordinator.shutdown()
            throw error
        }
    }

    /// Bounded state wait for the scheduler's supplemental drain — spawned by
    /// `TerminalActivationScheduler.acceptLaterGeometry` as an unstructured
    /// `Task` the reevaluation tail never awaits — to reach the effect under
    /// test. Never a wall-clock sleep: each iteration only yields the
    /// MainActor so the drain's already-queued work can run, and the loop
    /// returns the instant `condition` is true. The iteration cap is a
    /// safety net against a genuine hang, not a timer.
    private func waitUntil(iterations: Int = 20_000, _ condition: () -> Bool) async {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test
    func aLayoutChangeHydratesAStillHiddenDeferredTerminal() async throws {
        // Arrange: an active tab with a visible pane, and a separate,
        // never-selected tab whose pane is withheld from the initial frame
        // set so it settles `deferredGeometry` custody.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let activePane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let hiddenPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let activeTab = Tab(paneId: activePane.id, name: "Active")
        let hiddenTab = Tab(paneId: hiddenPane.id, name: "Hidden")
        harness.store.appendTab(activeTab)
        harness.store.appendTab(hiddenTab)
        harness.store.setActiveTab(activeTab.id)
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        let mounted = try await mountGeometryReevaluationCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (activePane, .activeVisible, .tab(tabID: activeTab.id)),
                (hiddenPane, .hidden, .tab(tabID: hiddenTab.id)),
            ],
            eligiblePaneIDs: [PaneId(existingUUID: activePane.id)],
            trustedBounds: trustedBounds
        )
        let hiddenPaneID = PaneId(existingUUID: hiddenPane.id)
        #expect(
            harness.viewRegistry.preparedContentMountState(for: hiddenPaneID, generation: mounted.generation)
                == .deferredGeometry(owner: .terminal)
        )
        #expect(harness.surfaceManager.createdPaneIds.contains(hiddenPane.id) == false)

        // Act: a layout change on the ACTIVE tab — unrelated to the hidden
        // pane's own tab — triggers the reevaluation tail. The hidden tab is
        // never selected.
        try await harness.coordinator.execute(.equalizePanes(tabId: activeTab.id))
        await waitUntil { harness.surfaceManager.createdPaneIds.filter { $0 == hiddenPane.id }.count == 2 }

        // Assert: the still-hidden pane was hydrated exactly once, without
        // its tab ever becoming active.
        #expect(harness.store.activeTabId == activeTab.id)
        #expect(harness.surfaceManager.createdPaneIds.filter { $0 == hiddenPane.id }.count == 2)
        #expect(
            harness.viewRegistry.preparedContentMountState(for: hiddenPaneID, generation: mounted.generation)
                == .completed(owner: .terminal, disposition: .failed)
        )
    }

    @Test
    func revealingADeferredTabHydratesFromExistingSafeGeometryWithoutAWindowLayoutCallback() async throws {
        let mounted = try await withGeometryReevaluationHarness { harness in
            let repo = harness.store.addRepo(at: harness.tempDir)
            let worktree = try #require(repo.worktrees.first)
            let activePane = harness.store.createPane(
                launchDirectory: worktree.path,
                provider: .zmx,
                facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
            )
            let deferredPane = harness.store.createPane(
                launchDirectory: worktree.path,
                provider: .zmx,
                facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
            )
            let unrelatedDeferredPane = harness.store.createPane(
                launchDirectory: worktree.path,
                provider: .zmx,
                facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
            )
            let activeTab = Tab(paneId: activePane.id, name: "Active")
            let deferredTab = Tab(paneId: deferredPane.id, name: "Deferred")
            let unrelatedTab = Tab(paneId: unrelatedDeferredPane.id, name: "Unrelated")
            harness.store.appendTab(activeTab)
            harness.store.appendTab(deferredTab)
            harness.store.appendTab(unrelatedTab)
            harness.store.setActiveTab(activeTab.id)
            harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

            let mounted = try await mountGeometryReevaluationCohort(
                coordinator: harness.coordinator,
                viewRegistry: harness.viewRegistry,
                entries: [
                    (activePane, .activeVisible, .tab(tabID: activeTab.id)),
                    (deferredPane, .hidden, .tab(tabID: deferredTab.id)),
                    (unrelatedDeferredPane, .hidden, .tab(tabID: unrelatedTab.id)),
                ],
                eligiblePaneIDs: [PaneId(existingUUID: activePane.id)],
                trustedBounds: trustedBounds
            )
            let deferredPaneID = PaneId(existingUUID: deferredPane.id)
            let unrelatedDeferredPaneID = PaneId(existingUUID: unrelatedDeferredPane.id)
            #expect(
                harness.viewRegistry.preparedContentMountState(for: deferredPaneID, generation: mounted.generation)
                    == .deferredGeometry(owner: .terminal)
            )
            #expect(
                harness.viewRegistry.preparedContentMountState(
                    for: unrelatedDeferredPaneID,
                    generation: mounted.generation
                ) == .deferredGeometry(owner: .terminal)
            )
            #expect(harness.surfaceManager.createdPaneIds.contains(deferredPane.id) == false)
            #expect(harness.surfaceManager.createdPaneIds.contains(unrelatedDeferredPane.id) == false)

            let originalGeometryReevaluationHandler = harness.coordinator.preparedTerminalGeometryReevaluationHandler
            var reevaluatedPaneIDs: Set<PaneId> = []
            harness.coordinator.preparedTerminalGeometryReevaluationHandler = { framesByPaneID in
                reevaluatedPaneIDs.formUnion(framesByPaneID.keys)
                await originalGeometryReevaluationHandler(framesByPaneID)
            }

            harness.store.setActiveTab(deferredTab.id)
            harness.coordinator.restoreViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)
            await waitUntil { harness.surfaceManager.createdPaneIds.filter { $0 == deferredPane.id }.count == 2 }

            #expect(harness.surfaceManager.createdPaneIds.filter { $0 == deferredPane.id }.count == 2)
            #expect(
                harness.viewRegistry.preparedContentMountState(for: deferredPaneID, generation: mounted.generation)
                    == .completed(owner: .terminal, disposition: .failed)
            )
            #expect(reevaluatedPaneIDs == [deferredPaneID])
            #expect(harness.surfaceManager.createdPaneIds.contains(unrelatedDeferredPane.id) == false)
            #expect(
                harness.viewRegistry.preparedContentMountState(
                    for: unrelatedDeferredPaneID,
                    generation: mounted.generation
                ) == .deferredGeometry(owner: .terminal)
            )
            return mounted
        }
        withExtendedLifetime(mounted) {}
    }

    @Test
    func aMinimizedDeferredTerminalHydratesWhenGeometryBecomesSafe() async throws {
        // Arrange: two split panes in one active tab. `secondPane` is
        // withheld from the initial frame set so it settles
        // `deferredGeometry` custody, then minimized — proving minimization
        // does not block hydration once its canonical (small collapsed-bar)
        // frame becomes safe.
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
        let tab = Tab(paneId: firstPane.id, name: "Minimize")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        _ = harness.store.insertPane(
            secondPane.id,
            inTab: tab.id,
            at: firstPane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        let mounted = try await mountGeometryReevaluationCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (firstPane, .activeVisible, .tab(tabID: tab.id)),
                (secondPane, .activeVisible, .tab(tabID: tab.id)),
            ],
            eligiblePaneIDs: [PaneId(existingUUID: firstPane.id)],
            trustedBounds: trustedBounds
        )
        #expect(
            harness.viewRegistry.preparedContentMountState(
                for: PaneId(existingUUID: secondPane.id), generation: mounted.generation
            ) == .deferredGeometry(owner: .terminal)
        )

        // Act: minimize the still-deferred pane. Its own minimized frame
        // (the small collapsed-bar rect) is exactly what makes its placement
        // safe.
        try await harness.coordinator.execute(.minimizePane(tabId: tab.id, paneId: secondPane.id))
        await waitUntil { harness.surfaceManager.createdPaneIds.filter { $0 == secondPane.id }.count == 2 }

        // Assert: created with the canonical minimized (collapsed-bar) frame.
        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[secondPane.id])
        #expect(
            config.initialFrame?.width
                == AppStyles.Shell.PaneChrome.collapsedBarWidth - (AppStyles.General.Layout.paneGap * 2)
        )
    }

    @Test
    func aCollapsedDrawerChildHydratesWithoutTheDrawerBeingOpened() async throws {
        // Arrange: a parent pane with a collapsed drawer child. The child is
        // withheld from the initial frame set so it settles
        // `deferredGeometry` custody.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let parentPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let tab = Tab(paneId: parentPane.id, name: "Collapsed Drawer")
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
        let drawerID = try #require(harness.store.pane(parentPane.id)?.drawer?.drawerId)
        harness.store.tabArrangementAtom.addDrawerPaneView(
            drawerId: drawerID,
            parentPaneId: parentPane.id,
            drawerPaneId: drawerPane.id,
            inTab: tab.id
        )
        harness.store.toggleDrawer(for: parentPane.id)
        #expect(harness.store.pane(parentPane.id)?.drawer?.isExpanded == false)
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        let acceptedParentPane = try #require(harness.store.pane(parentPane.id))
        let acceptedDrawerPane = try #require(harness.store.pane(drawerPane.id))
        let mounted = try await mountGeometryReevaluationCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (acceptedParentPane, .activeVisible, .tab(tabID: tab.id)),
                (
                    acceptedDrawerPane,
                    .hidden,
                    .drawer(
                        tabID: tab.id,
                        parentPaneID: PaneId(existingUUID: parentPane.id),
                        drawerID: drawerID
                    )
                ),
            ],
            eligiblePaneIDs: [PaneId(existingUUID: parentPane.id)],
            trustedBounds: trustedBounds
        )
        #expect(
            harness.viewRegistry.preparedContentMountState(
                for: PaneId(existingUUID: drawerPane.id), generation: mounted.generation
            ) == .deferredGeometry(owner: .terminal)
        )

        // Act: an unrelated layout change on the same tab triggers
        // reevaluation. The drawer is never toggled back open.
        try await harness.coordinator.execute(.equalizePanes(tabId: tab.id))
        await waitUntil { harness.surfaceManager.createdPaneIds.filter { $0 == drawerPane.id }.count == 2 }

        // Assert: hydrated while still collapsed.
        #expect(harness.store.pane(parentPane.id)?.drawer?.isExpanded == false)
        let config = try #require(harness.surfaceManager.createdConfigsByPaneId[drawerPane.id])
        #expect(config.initialFrame != nil)
    }

    @Test
    func reevaluationTouchesNoReadyFailedOrInFlightMember() async throws {
        // Arrange: `failedPane` is eligible from the start and settles
        // `completed(.failed)` during the initial mount (the harness's
        // surface manager always fails). `deferredPane`, in a separate
        // never-selected tab, is withheld so it settles `deferredGeometry`
        // custody.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let failedPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let deferredPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let failedTab = Tab(paneId: failedPane.id, name: "Failed")
        let deferredTab = Tab(paneId: deferredPane.id, name: "Deferred")
        harness.store.appendTab(failedTab)
        harness.store.appendTab(deferredTab)
        harness.store.setActiveTab(failedTab.id)
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        let mounted = try await mountGeometryReevaluationCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (failedPane, .activeVisible, .tab(tabID: failedTab.id)),
                (deferredPane, .hidden, .tab(tabID: deferredTab.id)),
            ],
            eligiblePaneIDs: [PaneId(existingUUID: failedPane.id)],
            trustedBounds: trustedBounds
        )
        #expect(
            harness.viewRegistry.preparedContentMountState(
                for: PaneId(existingUUID: failedPane.id), generation: mounted.generation
            ) == .completed(owner: .terminal, disposition: .failed)
        )
        let failedAttemptsBeforeReevaluation =
            harness.surfaceManager.createdPaneIds.filter { $0 == failedPane.id }.count

        // Act
        try await harness.coordinator.execute(.equalizePanes(tabId: failedTab.id))
        await waitUntil { harness.surfaceManager.createdPaneIds.filter { $0 == deferredPane.id }.count == 2 }

        // Assert: the deferred member was hydrated, and the already-settled
        // failed member was never re-touched.
        #expect(
            harness.surfaceManager.createdPaneIds.filter { $0 == failedPane.id }.count
                == failedAttemptsBeforeReevaluation
        )
    }

    @Test
    func anAmbiguousPlacementLeavesTheMemberWaiting() async throws {
        // Arrange: `mainPane` in `mainTab` is eligible from the start.
        // `ambiguousDrawerChild` is a drawer child of `ambiguousParentPane`
        // in a separate tab that is removed entirely before reevaluation
        // runs — its canonical tab position becomes genuinely unknown. No
        // live mutation API leaves one arrangement holding a drawer view
        // another lacks (every insert/remove keeps every arrangement synced
        // by construction), so removing the owning tab outright is the
        // realistic way a pane's placement goes ambiguous.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let mainPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let ambiguousParentPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let mainTab = Tab(paneId: mainPane.id, name: "Main")
        let ambiguousTab = Tab(paneId: ambiguousParentPane.id, name: "Ambiguous")
        harness.store.appendTab(mainTab)
        harness.store.appendTab(ambiguousTab)
        harness.store.setActiveTab(mainTab.id)
        let ambiguousDrawerChild = try #require(harness.store.addDrawerPane(to: ambiguousParentPane.id))
        let ambiguousDrawerID = try #require(harness.store.pane(ambiguousParentPane.id)?.drawer?.drawerId)
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        let acceptedAmbiguousParent = try #require(harness.store.pane(ambiguousParentPane.id))
        let acceptedAmbiguousDrawerChild = try #require(harness.store.pane(ambiguousDrawerChild.id))
        let mounted = try await mountGeometryReevaluationCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (mainPane, .activeVisible, .tab(tabID: mainTab.id)),
                (acceptedAmbiguousParent, .hidden, .tab(tabID: ambiguousTab.id)),
                (
                    acceptedAmbiguousDrawerChild,
                    .hidden,
                    .drawer(
                        tabID: ambiguousTab.id,
                        parentPaneID: PaneId(existingUUID: ambiguousParentPane.id),
                        drawerID: ambiguousDrawerID
                    )
                ),
            ],
            eligiblePaneIDs: [PaneId(existingUUID: mainPane.id)],
            trustedBounds: trustedBounds
        )
        let ambiguousDrawerChildID = PaneId(existingUUID: ambiguousDrawerChild.id)
        #expect(
            harness.viewRegistry.preparedContentMountState(for: ambiguousDrawerChildID, generation: mounted.generation)
                == .deferredGeometry(owner: .terminal)
        )

        // The pane models survive — `removeTab` only mutates the tab/layout
        // structure — but no tab now places `ambiguousParentPane`.
        harness.store.removeTab(ambiguousTab.id)
        #expect(harness.store.pane(ambiguousDrawerChild.id) != nil)

        // Act
        try await harness.coordinator.execute(.equalizePanes(tabId: mainTab.id))
        // Bounded settle for a negative assertion: give the MainActor queue
        // room to run anything the tail scheduled, then assert nothing
        // arrived. Never a sleep — each iteration only yields.
        for _ in 0..<200 {
            await Task.yield()
        }

        // Assert: still waiting — never claimed, never created.
        #expect(
            harness.viewRegistry.preparedContentMountState(for: ambiguousDrawerChildID, generation: mounted.generation)
                == .deferredGeometry(owner: .terminal)
        )
        #expect(harness.surfaceManager.createdPaneIds.contains(ambiguousDrawerChild.id) == false)
    }

    @Test
    func aNewlyQueuedVisibleMemberReceivesItsPromotedTier() async throws {
        // Arrange: `backgroundDeferredPane` (created first, earlier
        // original ordinal) sits in a never-selected tab. `visibleSiblingPane`
        // (created second, later ordinal) is mounted with the SAME `.hidden`
        // cohort-time priority as `backgroundDeferredPane` — only becoming a
        // split sibling of `activePane` in the ACTIVE tab after the cohort
        // has already mounted and settled. Both start deferred at an
        // identical static priority, so only a live geometry-reevaluation
        // promotion (SPEC R3), not the static descriptor fallback, can make
        // the now-visible sibling win the cohort's single admission slot
        // ahead of its earlier original ordinal.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let activePane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let backgroundDeferredPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let visibleSiblingPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let activeTab = Tab(paneId: activePane.id, name: "Active")
        let backgroundTab = Tab(paneId: backgroundDeferredPane.id, name: "Background")
        harness.store.appendTab(activeTab)
        harness.store.appendTab(backgroundTab)
        harness.store.setActiveTab(activeTab.id)
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        let mounted = try await mountGeometryReevaluationCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (activePane, .activeVisible, .tab(tabID: activeTab.id)),
                (backgroundDeferredPane, .hidden, .tab(tabID: backgroundTab.id)),
                (visibleSiblingPane, .hidden, .tab(tabID: activeTab.id)),
            ],
            eligiblePaneIDs: [PaneId(existingUUID: activePane.id)],
            trustedBounds: trustedBounds
        )
        _ = mounted

        // `visibleSiblingPane` becomes an actual active-tab sibling only
        // after the cohort has already mounted and settled, mirroring
        // `aDeferredPaneCompletesOneAdmissionCycleAsTwoFailedCreateSurfaceCallsWhenGeometryArrives`'s precaution
        // against a real AppKit layout pass landing mid-mount.
        _ = harness.store.insertPane(
            visibleSiblingPane.id,
            inTab: activeTab.id,
            at: activePane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )

        // Act
        try await harness.coordinator.execute(.equalizePanes(tabId: activeTab.id))
        await waitUntil {
            harness.surfaceManager.createdPaneIds.contains(backgroundDeferredPane.id)
                || harness.surfaceManager.createdPaneIds.contains(visibleSiblingPane.id)
        }

        // Assert: the promoted visible sibling claimed the single admission
        // slot first, despite its later original ordinal.
        let firstAdmitted = harness.surfaceManager.createdPaneIds.first {
            $0 == backgroundDeferredPane.id || $0 == visibleSiblingPane.id
        }
        #expect(firstAdmitted == visibleSiblingPane.id)
    }

    @Test("the visible queued set is recorded before requeuing deferred geometry")
    func theVisibleQueuedSetIsRecordedBeforeRequeuingDeferredGeometry() async throws {
        // Arrange: the same shape as `aNewlyQueuedVisibleMemberReceivesItsPromotedTier`
        // — `backgroundDeferredPane` (earlier ordinal) sits in a
        // never-selected tab, the "earlier-ordinal hidden competitor" R8
        // guards against; `visibleSiblingPane` (later ordinal) starts
        // deferred too, then becomes an actual split sibling of `activePane`
        // in the ACTIVE tab only after the cohort has already mounted and
        // settled, so its frame is "now safe" without ever having been
        // installed as eligible.
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let repo = harness.store.addRepo(at: harness.tempDir)
        let worktree = try #require(repo.worktrees.first)
        let activePane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let backgroundDeferredPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let visibleSiblingPane = harness.store.createPane(
            launchDirectory: worktree.path,
            provider: .zmx,
            facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        )
        let activeTab = Tab(paneId: activePane.id, name: "Active")
        let backgroundTab = Tab(paneId: backgroundDeferredPane.id, name: "Background")
        harness.store.appendTab(activeTab)
        harness.store.appendTab(backgroundTab)
        harness.store.setActiveTab(activeTab.id)
        harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

        let mounted = try await mountGeometryReevaluationCohort(
            coordinator: harness.coordinator,
            viewRegistry: harness.viewRegistry,
            entries: [
                (activePane, .activeVisible, .tab(tabID: activeTab.id)),
                (backgroundDeferredPane, .hidden, .tab(tabID: backgroundTab.id)),
                (visibleSiblingPane, .hidden, .tab(tabID: activeTab.id)),
            ],
            eligiblePaneIDs: [PaneId(existingUUID: activePane.id)],
            trustedBounds: trustedBounds
        )
        let visibleSiblingPaneID = PaneId(existingUUID: visibleSiblingPane.id)
        #expect(
            harness.viewRegistry.preparedContentMountState(for: visibleSiblingPaneID, generation: mounted.generation)
                == .deferredGeometry(owner: .terminal)
        )
        _ = harness.store.insertPane(
            visibleSiblingPane.id,
            inTab: activeTab.id,
            at: activePane.id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )

        // Interpose recording around the coordinator's two existing test
        // seams without changing what they actually do — each still
        // delegates to the real port/owner `mountGeometryReevaluationCohort`
        // wired above.
        let originalVisibilitySignalHandler = harness.coordinator.preparedContentVisibilitySignalHandler
        let originalGeometryReevaluationHandler = harness.coordinator.preparedTerminalGeometryReevaluationHandler
        let recorder = ReevaluationOrderRecorder()
        harness.coordinator.preparedContentVisibilitySignalHandler = { visibleQueuedSet in
            recorder.recordVisibilitySignal(visiblePaneIDs: visibleQueuedSet.visiblePaneIDs)
            return originalVisibilitySignalHandler(visibleQueuedSet)
        }
        harness.coordinator.preparedTerminalGeometryReevaluationHandler = { framesByPaneID in
            recorder.recordGeometryReevaluation(paneIDs: Set(framesByPaneID.keys))
            await originalGeometryReevaluationHandler(framesByPaneID)
        }

        // Act: run the reevaluation tail directly — no need to route through
        // a real AppKit layout action for an order assertion.
        await harness.coordinator.reevaluatePreparedTerminalGeometry()

        // Assert: the visibility signal (naming `visibleSiblingPane`, since
        // it is now a genuine topological sibling in the active tab) is
        // recorded before the requeue — the fence a competing claim from
        // `backgroundDeferredPane`, carrying the older revision, relies on
        // (R8). `backgroundDeferredPane` itself is never named: it is
        // genuinely hidden, not merely deferred.
        #expect(recorder.events.count == 2)
        guard case .visibilitySignal(let visiblePaneIDs) = recorder.events.first else {
            Issue.record("expected the visibility signal to be recorded first")
            return
        }
        #expect(visiblePaneIDs.contains(visibleSiblingPaneID))
        guard case .geometryReevaluation(let paneIDs) = recorder.events.last else {
            Issue.record("expected the geometry reevaluation to be recorded second")
            return
        }
        #expect(paneIDs.contains(visibleSiblingPaneID))
        withExtendedLifetime(mounted) {}
    }
}

/// Records the relative order of the two S9 reevaluation-tail seams without
/// altering their behavior — each caller still chains to the original
/// handler `mountGeometryReevaluationCohort` wired.
@MainActor
private final class ReevaluationOrderRecorder {
    enum Event: Equatable {
        case visibilitySignal(visiblePaneIDs: Set<PaneId>)
        case geometryReevaluation(paneIDs: Set<PaneId>)
    }

    private(set) var events: [Event] = []

    func recordVisibilitySignal(visiblePaneIDs: [PaneId]) {
        events.append(.visibilitySignal(visiblePaneIDs: Set(visiblePaneIDs)))
    }

    func recordGeometryReevaluation(paneIDs: Set<PaneId>) {
        events.append(.geometryReevaluation(paneIDs: paneIDs))
    }
}

struct MountedGeometryReevaluationCohort {
    let terminalAdmissionPort: PreparedTerminalMountAdmissionPort
    let owner: WorkspacePreparedContentMountCoordinator
    let generation: WorkspaceContentMountGeneration
}

/// Mounts a cohort where only `eligiblePaneIDs` receive their resolved
/// canonical frame at mount time; every other cohort pane is deliberately
/// withheld from `installTrustedInitialFrames` so it settles
/// `deferredGeometry` custody — the starting state every S9 test needs.
/// Wires `coordinator.preparedTerminalGeometryReevaluationHandler` and
/// `coordinator.preparedContentVisibilitySignalHandler` exactly as
/// `AppDelegate+WorkspaceBoot.swift` wires them in production, and returns
/// the concrete port/coordinator so the caller can keep them alive — the
/// `WorkspaceSurfaceCoordinator` only holds them `weak`, matching the
/// production lifetime contract.
@MainActor
func mountGeometryReevaluationCohort(
    coordinator: WorkspaceSurfaceCoordinator,
    viewRegistry: ViewRegistry,
    entries: [(Pane, TerminalActivationVisibilityPriority, TerminalHostPlacementIdentity)],
    eligiblePaneIDs: Set<PaneId>,
    trustedBounds: CGRect
) async throws -> MountedGeometryReevaluationCohort {
    let generation = WorkspaceContentMountGeneration()
    let descriptors = try entries.map { pane, priority, placement in
        try geometryReevaluationTerminalDescriptor(pane: pane, visibilityPriority: priority, hostPlacement: placement)
    }
    let resolvedFramesByTabID = coordinator.resolveInitialFramesByTabId(in: trustedBounds)
    var initialFramesByPaneID: [PaneId: NSRect] = [:]
    for tabFrames in resolvedFramesByTabID.values {
        for (paneUUID, frame) in tabFrames where !frame.isEmpty {
            let paneID = PaneId(existingUUID: paneUUID)
            guard eligiblePaneIDs.contains(paneID) else { continue }
            initialFramesByPaneID[paneID] = frame
        }
    }
    let cohort = WorkspacePreparedContentMountCohort(
        generation: generation,
        terminalActivationInput: TerminalActivationInput(entries: descriptors),
        nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
    )
    viewRegistry.beginInitialRestore()
    let port = PreparedTerminalMountAdmissionPort(
        generation: generation,
        viewRegistry: viewRegistry,
        mountHandler: coordinator,
        descriptorsByPaneID: Dictionary(uniqueKeysWithValues: descriptors.map { ($0.paneID, $0) })
    )
    let owner = WorkspacePreparedContentMountCoordinator(
        cohort: cohort,
        viewRegistry: viewRegistry,
        terminalAdmissionPort: port,
        nonterminalAdmissionPort: PreparedNonterminalMountAdmissionPort(
            generation: generation, coordinator: coordinator)
    )
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
    await owner.installTerminalGeometryAvailability(port.installTrustedInitialFrames(initialFramesByPaneID))
    _ = await owner.mount()
    return MountedGeometryReevaluationCohort(terminalAdmissionPort: port, owner: owner, generation: generation)
}

func geometryReevaluationTerminalDescriptor(
    pane: Pane,
    visibilityPriority: TerminalActivationVisibilityPriority,
    hostPlacement: TerminalHostPlacementIdentity
) throws -> TerminalActivationDescriptor {
    guard case .terminal = pane.content else {
        preconditionFailure("prepared terminal cohort requires terminal content")
    }
    return TerminalActivationDescriptor(
        pane: pane,
        visibilityPriority: visibilityPriority,
        hostPlacement: hostPlacement
    )
}

@MainActor
final class GeometryReevaluationCapturingSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    var lastConfig: Ghostty.SurfaceConfiguration?
    var lastMetadata: SurfaceMetadata?
    var createdPaneIds: [UUID] = []
    var createdConfigsByPaneId: [UUID: Ghostty.SurfaceConfiguration] = [:]

    func syncFocus(activeSurfaceId _: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        lastConfig = config
        lastMetadata = metadata
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
