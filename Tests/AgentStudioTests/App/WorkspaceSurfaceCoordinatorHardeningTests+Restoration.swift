import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

extension WorkspaceSurfaceCoordinatorHardeningTests {
    @Test("toggleDrawer collapse hands focus back to the parent pane host")
    func toggleDrawer_collapseFocusesParentPaneHost() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let parentPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Parent")
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))

            let parentHost = PaneHostView(paneId: parentPane.id)
            let drawerHost = PaneHostView(paneId: drawerPane.id)
            let parentMountedContent = HardeningFocusableMountedContentView()
            let drawerMountedContent = HardeningFocusableMountedContentView()
            parentHost.mountContentView(parentMountedContent)
            drawerHost.mountContentView(drawerMountedContent)
            harness.viewRegistry.register(parentHost, for: parentPane.id)
            harness.viewRegistry.register(drawerHost, for: drawerPane.id)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            let contentView = try #require(window.contentView)
            contentView.addSubview(parentHost)
            contentView.addSubview(drawerHost)
            window.makeFirstResponder(drawerHost)

            try await harness.coordinator.execute(.toggleDrawer(paneId: parentPane.id))

            #expect(harness.store.pane(parentPane.id)?.drawer?.isExpanded == false)
            #expect(window.firstResponder === parentMountedContent)
        }
    }

    @Test("restore tail hands focus from the target pane placeholder to its mounted surface")
    func restoreTail_handsFocusFromTargetPanePlaceholderToMountedSurface() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let pane = harness.store.createPane(
                launchDirectory: harness.tempDir,
                title: "Restored Terminal",
                provider: .zmx
            )
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)

            let paneHost = PaneHostView(paneId: pane.id)
            let terminalMount = TerminalPaneMountView(
                surfaceOperations: makeAppTerminalFixtureMountOperations(), paneId: pane.id, title: "Restored Terminal")
            let placeholder = terminalMount.showPlaceholder(mode: .preparing)
            paneHost.mountContentView(terminalMount)
            harness.viewRegistry.register(paneHost, for: pane.id)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            let contentView = try #require(window.contentView)
            contentView.addSubview(paneHost)
            #expect(window.makeFirstResponder(placeholder))

            harness.coordinator.focusVisiblePaneHost(pane.id, reason: .restoreTail)

            #expect(window.firstResponder === terminalMount)
        }
    }

    @Test("restore tail preserves an interactive responder inside mounted pane content")
    func restoreTail_preservesInteractiveResponderInsideMountedPaneContent() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let pane = makeWebviewPane(harness.store, title: "Restored Webview")
            harness.store.appendTab(Tab(paneId: pane.id))

            let paneHost = PaneHostView(paneId: pane.id)
            let mountedContent = HardeningFocusableMountedContentView()
            let interactiveControl = HardeningFocusableResponderView()
            mountedContent.addSubview(interactiveControl)
            paneHost.mountContentView(mountedContent)
            harness.viewRegistry.register(paneHost, for: pane.id)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            let contentView = try #require(window.contentView)
            contentView.addSubview(paneHost)
            #expect(window.makeFirstResponder(interactiveControl))

            harness.coordinator.focusVisiblePaneHost(pane.id, reason: .restoreTail)

            #expect(window.firstResponder === interactiveControl)
        }
    }

    @Test("parked restore replay preserves an interactive responder inside mounted pane content")
    func parkedRestoreReplay_preservesInteractiveResponderInsideMountedPaneContent() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let pane = makeWebviewPane(harness.store, title: "Restored Webview")
            harness.store.appendTab(Tab(paneId: pane.id))

            let paneHost = PaneHostView(paneId: pane.id)
            let mountedContent = HardeningFocusableMountedContentView()
            let interactiveControl = HardeningFocusableResponderView()
            mountedContent.addSubview(interactiveControl)
            paneHost.mountContentView(mountedContent)
            harness.viewRegistry.register(paneHost, for: pane.id)

            harness.coordinator.focusVisiblePaneHost(pane.id, reason: .restoreTail)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            let contentView = try #require(window.contentView)
            contentView.addSubview(paneHost)
            #expect(window.makeFirstResponder(interactiveControl))

            harness.coordinator.handlePaneHostAttachedToWindow(pane.id)

            #expect(window.firstResponder === interactiveControl)
        }
    }

    @Test("drawer focus park survives unrelated user focus until the host attaches")
    func drawerFocusPark_survivesUnrelatedUserFocusUntilHostAttaches() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let parentPane = harness.store.createPane()
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))

            let parentHost = PaneHostView(paneId: parentPane.id)
            let parentContent = HardeningFocusableMountedContentView()
            parentHost.mountContentView(parentContent)
            harness.viewRegistry.register(parentHost, for: parentPane.id)

            let drawerHost = PaneHostView(paneId: drawerPane.id)
            let drawerContent = HardeningFocusableMountedContentView()
            drawerHost.mountContentView(drawerContent)
            harness.viewRegistry.register(drawerHost, for: drawerPane.id)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            let contentView = try #require(window.contentView)
            contentView.addSubview(parentHost)
            #expect(window.makeFirstResponder(parentContent))

            harness.coordinator.focusVisiblePaneHost(drawerPane.id)
            harness.coordinator.clearPendingPaneRefocusRequestsAfterUserFocusChange()
            contentView.addSubview(drawerHost)
            harness.coordinator.handlePaneHostAttachedToWindow(drawerPane.id)

            #expect(window.firstResponder === drawerContent)
        }
    }

    @Test("removeDrawerPane closing the last drawer pane lands in empty drawer context")
    func removeDrawerPane_lastDrawerPaneClearsResponderToEmptyDrawerContext() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let parentPane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Parent")
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))

            let parentHost = PaneHostView(paneId: parentPane.id)
            let drawerHost = PaneHostView(paneId: drawerPane.id)
            let parentMountedContent = HardeningFocusableMountedContentView()
            let drawerMountedContent = HardeningFocusableMountedContentView()
            parentHost.mountContentView(parentMountedContent)
            drawerHost.mountContentView(drawerMountedContent)
            harness.viewRegistry.register(parentHost, for: parentPane.id)
            harness.viewRegistry.register(drawerHost, for: drawerPane.id)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            let contentView = try #require(window.contentView)
            contentView.addSubview(parentHost)
            contentView.addSubview(drawerHost)
            window.makeFirstResponder(drawerHost)

            try await harness.coordinator.execute(
                .removeDrawerPane(parentPaneId: parentPane.id, drawerPaneId: drawerPane.id))

            #expect(harness.store.pane(parentPane.id)?.drawer?.paneIds.isEmpty == true)
            #expect(window.firstResponder !== drawerMountedContent)
            #expect(window.firstResponder !== drawerHost)
            #expect(window.firstResponder === contentView)
        }
    }

    @Test(
        "closing a main pane with drawer children retires child slots so drawer panel renders safely during transition"
    )
    func closeMainPane_withDrawerChildren_retiresChildSlots() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let parent = harness.store.createPane()
            let tab = Tab(paneId: parent.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let child = try #require(harness.store.addDrawerPane(to: parent.id))
            _ = harness.viewRegistry.ensureSlot(for: parent.id)
            _ = harness.viewRegistry.ensureSlot(for: child.id)

            // Phase 1 still goes through the current close path, including the
            // validator's canonicalization of single-pane tabs to .closeTab. To
            // isolate the retire behavior, drive the main-pane close via the
            // coordinator directly with a non-canonicalized closePane call for a
            // multi-pane test state.
            let sibling = harness.store.createPane()
            harness.store.insertPane(
                sibling.id,
                inTab: tab.id,
                at: parent.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
            harness.viewRegistry.surfaceRenderedIds("tab:\(tab.id)", ids: [parent.id, sibling.id])
            harness.viewRegistry.surfaceRenderedIds("drawer:\(parent.id)", ids: [child.id])

            try await harness.coordinator.execute(.closePane(tabId: tab.id, paneId: parent.id))

            #expect(harness.store.tab(tab.id)?.allPaneIds.contains(child.id) == false)
            #expect(harness.viewRegistry.isRetiredForTesting(parent.id))
            #expect(harness.viewRegistry.isRetiredForTesting(child.id))
            #expect(harness.viewRegistry.peekSlotForTesting(parent.id) != nil)
            #expect(harness.viewRegistry.peekSlotForTesting(child.id) != nil)
        }
    }

    @Test(".removeDrawerPane retires the slot rather than deleting it immediately")
    func removeDrawerPane_retiresSlot() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let parent = harness.store.createPane()
            let tab = Tab(paneId: parent.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let child = try #require(harness.store.addDrawerPane(to: parent.id))
            let survivor = try #require(harness.store.addDrawerPane(to: parent.id))
            harness.store.setActiveDrawerPane(survivor.id, in: parent.id)
            _ = harness.viewRegistry.ensureSlot(for: child.id)
            harness.viewRegistry.surfaceRenderedIds("drawer:\(parent.id)", ids: [child.id])

            try await harness.coordinator.execute(.removeDrawerPane(parentPaneId: parent.id, drawerPaneId: child.id))

            #expect(harness.viewRegistry.isRetiredForTesting(child.id))
            #expect(harness.viewRegistry.peekSlotForTesting(child.id) != nil)
        }
    }

    @Test(".removeDrawerPane stale segment reads the retired slot instead of creating a lazy fallback")
    func removeDrawerPane_staleSegmentSlotRead_returnsRetiredSlot() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let parent = harness.store.createPane()
            let tab = Tab(paneId: parent.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let child = try #require(harness.store.addDrawerPane(to: parent.id))
            let survivor = try #require(harness.store.addDrawerPane(to: parent.id))
            harness.store.setActiveDrawerPane(survivor.id, in: parent.id)
            let originalSlot = harness.viewRegistry.ensureSlot(for: child.id)
            harness.viewRegistry.surfaceRenderedIds("drawer:\(parent.id)", ids: [child.id])

            try await harness.coordinator.execute(.removeDrawerPane(parentPaneId: parent.id, drawerPaneId: child.id))
            let staleSegmentSlot = harness.viewRegistry.slot(for: child.id)

            #expect(staleSegmentSlot === originalSlot)
            #expect(harness.viewRegistry.isRetiredForTesting(child.id))
        }
    }

    @Test(".removeDrawerPane finalizes retired slots only after every rendering surface drops the pane id")
    func removeDrawerPane_surfaceUnionFinalizesOnlyAfterAllSurfacesDropPaneId() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let parent = harness.store.createPane()
            let tab = Tab(paneId: parent.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let child = try #require(harness.store.addDrawerPane(to: parent.id))
            let survivor = try #require(harness.store.addDrawerPane(to: parent.id))
            harness.store.setActiveDrawerPane(survivor.id, in: parent.id)
            let originalSlot = harness.viewRegistry.ensureSlot(for: child.id)

            harness.viewRegistry.surfaceRenderedIds("tab:\(tab.id)", ids: [parent.id, child.id])
            harness.viewRegistry.surfaceRenderedIds("drawer:\(parent.id)", ids: [child.id])

            try await harness.coordinator.execute(.removeDrawerPane(parentPaneId: parent.id, drawerPaneId: child.id))

            #expect(harness.viewRegistry.isRetiredForTesting(child.id))
            #expect(harness.viewRegistry.peekSlotForTesting(child.id) === originalSlot)

            harness.viewRegistry.surfaceRenderedIds("drawer:\(parent.id)", ids: [])

            #expect(harness.viewRegistry.isRetiredForTesting(child.id))
            #expect(harness.viewRegistry.peekSlotForTesting(child.id) === originalSlot)

            harness.viewRegistry.surfaceRenderedIds("tab:\(tab.id)", ids: [parent.id])

            #expect(!harness.viewRegistry.isRetiredForTesting(child.id))
            #expect(harness.viewRegistry.peekSlotForTesting(child.id) == nil)
        }
    }

    @Test("closePane on the final drawer child leaves an empty expanded drawer")
    func closePane_lastDrawerChild_leavesEmptyExpandedDrawer() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let parent = harness.store.createPane()
            let tab = Tab(paneId: parent.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let child = try #require(harness.store.addDrawerPane(to: parent.id))

            try await harness.coordinator.execute(.closePane(tabId: tab.id, paneId: child.id))

            let drawer = try #require(harness.store.pane(parent.id)?.drawer)
            #expect(drawer.isExpanded)
            #expect(drawer.paneIds.isEmpty)
            #expect(harness.store.drawerView(forParent: parent.id) == nil)
        }
    }

    @Test("repair recreateSurface registers preparing placeholder when geometry is unavailable")
    func repairRecreateSurface_registersPreparingPlaceholderWhenGeometryUnavailable() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let pane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Repair")
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            try await harness.coordinator.execute(.repair(.recreateSurface(paneId: pane.id)))

            let placeholder = harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id)
            #expect(placeholder?.mode == .preparing)
        }
    }

    @Test("repair createMissingView retries from failed placeholder instead of treating it as an existing live view")
    func repairCreateMissingView_failedPlaceholderRetriesCreation() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let pane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Retry")
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.coordinator.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)
            _ = harness.coordinator.registerTerminalPlaceholderIfNeeded(for: pane, mode: .failedToStart)

            try await harness.coordinator.execute(.repair(.createMissingView(paneId: pane.id)))

            #expect(harness.surfaceManager.createSurfaceCallCount == 1)
            let placeholder = harness.viewRegistry.terminalStatusPlaceholderView(for: pane.id)
            #expect(placeholder?.mode == .failedToStart)
        }
    }

    @Test("undo GC removes orphaned panes after stack overflows max entries")
    func undoGc_removesExpiredPaneResources() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            var closedPaneIds: [UUID] = []
            var oldestClosedSlot: ViewRegistry.PaneViewSlot?
            for index in 0...(AppPolicies.WorkspacePersistence.maximumAvailableUndoCloses) {
                let pane = makeWebviewPane(harness.store, title: "Pane \(index)")
                let tab = Tab(paneId: pane.id)
                harness.store.appendTab(tab)
                let slot = harness.viewRegistry.ensureSlot(for: pane.id)
                if index == 0 {
                    oldestClosedSlot = slot
                    harness.viewRegistry.surfaceRenderedIds("tab:\(tab.id)", ids: [pane.id])
                }
                try await harness.coordinator.execute(.closeTab(tabId: tab.id))
                closedPaneIds.append(pane.id)
            }

            #expect(harness.coordinator.undoStack.count == AppPolicies.WorkspacePersistence.maximumAvailableUndoCloses)
            guard let oldestClosedPaneId = closedPaneIds.first else {
                Issue.record("Expected at least one closed pane id")
                return
            }
            #expect(harness.store.pane(oldestClosedPaneId) == nil)
            #expect(harness.viewRegistry.isRetiredForTesting(oldestClosedPaneId))
            #expect(harness.viewRegistry.peekSlotForTesting(oldestClosedPaneId) === oldestClosedSlot)
        }
    }

    @Test("undo GC deletes expired pane slot immediately when no surface renders it")
    func undoGc_expiredPaneWithoutRenderedSurfaceDeletesSlot() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {
            var oldestClosedPaneId: UUID?
            for index in 0...(AppPolicies.WorkspacePersistence.maximumAvailableUndoCloses) {
                let pane = makeWebviewPane(harness.store, title: "Pane \(index)")
                let tab = Tab(paneId: pane.id)
                harness.store.appendTab(tab)
                _ = harness.viewRegistry.ensureSlot(for: pane.id)
                if index == 0 { oldestClosedPaneId = pane.id }
                try await harness.coordinator.execute(.closeTab(tabId: tab.id))
            }
            #expect(harness.coordinator.undoStack.count == AppPolicies.WorkspacePersistence.maximumAvailableUndoCloses)
            let oldestPaneId = try #require(oldestClosedPaneId)
            #expect(harness.store.pane(oldestPaneId) == nil)
            #expect(!harness.viewRegistry.isRetiredForTesting(oldestPaneId))
            #expect(harness.viewRegistry.peekSlotForTesting(oldestPaneId) == nil)
        }
    }

    @Test("restoreView defers runtime registration until after undo lookup")
    func restoreView_defersRuntimeRegistrationUntilAfterUndoLookup() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let pane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Restore")
            let runtimePaneId = PaneId(existingUUID: pane.id)

            var runtimeWasRegisteredDuringUndoLookup = false
            var undoLookupRan = false
            harness.surfaceManager.onUndoClose = {
                undoLookupRan = true
                runtimeWasRegisteredDuringUndoLookup = harness.coordinator.runtimeForPane(runtimePaneId) != nil
            }

            let restored = harness.coordinator.restoreView(for: pane, worktree: worktree, repo: repo)

            #expect(restored == nil)
            #expect(undoLookupRan)
            #expect(!runtimeWasRegisteredDuringUndoLookup)
            #expect(harness.coordinator.runtimeForPane(runtimePaneId) == nil)
        }
    }

    @Test("reused-surface undo schedules affected pane filesystem registration without full reconciliation")
    func reusedSurfaceUndo_schedulesAffectedPaneFilesystemRegistration() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let pane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Reused")
            let fullReconciliationCountBefore = harness.coordinator.filesystemFullReconciliationRequestCount
            let affectedKeyCountBefore = harness.coordinator.filesystemAffectedKeyRequestCount

            harness.coordinator.registerPaneFilesystemContextIfNeeded(for: pane)

            #expect(
                harness.coordinator.filesystemFullReconciliationRequestCount
                    == fullReconciliationCountBefore
            )
            #expect(harness.coordinator.filesystemAffectedKeyRequestCount == affectedKeyCountBefore + 1)
            #expect(harness.coordinator.pendingFilesystemPaneUpdatesByPaneId[pane.id] != nil)

            let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
            let sourceURL = projectRoot.appending(
                path: "Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ViewLifecycle.swift"
            )
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let reusedBranchStart = try #require(
                source.range(of: "guard let undone = surfaceManager.undoClose(forPaneId: pane.id) else {")
            )
            let reusedBranchEnd = try #require(
                source.range(
                    of: "\n    /// Restore a view from an undo close.",
                    range: reusedBranchStart.upperBound..<source.endIndex
                )
            )
            let reusedBranch = String(source[reusedBranchStart.lowerBound..<reusedBranchEnd.lowerBound])

            #expect(reusedBranch.contains("registerPaneFilesystemContextIfNeeded(for: pane)"))
            #expect(!reusedBranch.contains("syncFilesystemRootsAndActivity"))
        }
    }

    @Test("fresh createView registers runtime before createSurface")
    func freshCreateView_registersRuntimeBeforeCreateSurface() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let pane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Fresh")
            let runtimePaneId = PaneId(existingUUID: pane.id)

            var runtimeWasRegisteredDuringCreateSurface = false
            harness.surfaceManager.onCreateSurface = { _ in
                runtimeWasRegisteredDuringCreateSurface = harness.coordinator.runtimeForPane(runtimePaneId) != nil
            }

            let created = harness.coordinator.createView(
                for: pane,
                worktree: worktree,
                repo: repo,
                initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 600)
            )

            #expect(created == nil)
            #expect(runtimeWasRegisteredDuringCreateSurface)
        }
    }

    @Test("fresh createView rolls back newly created runtime when createSurface fails")
    func freshCreateView_rollsBackNewRuntimeWhenCreateSurfaceFails() async throws {
        let harness = makeHarness()
        try await withHardeningHarness(harness) {

            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let pane = makeWorktreePane(harness.store, repo: repo, worktree: worktree, title: "Rollback")
            let runtimePaneId = PaneId(existingUUID: pane.id)

            let created = harness.coordinator.createView(
                for: pane,
                worktree: worktree,
                repo: repo,
                initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 600)
            )

            #expect(created == nil)
            #expect(harness.coordinator.runtimeForPane(runtimePaneId) == nil)
        }
    }
}
