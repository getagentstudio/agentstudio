import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("AgentStudio IPC layout adapter", .serialized)
struct AgentStudioIPCLayoutAdapterTests {
    @Test("adapter does not retain the App-owned pane focus control")
    func adapterDoesNotRetainPaneFocusControl() async throws {
        let store = makeIPCLayoutWorkspaceStore()
        let pane = store.createPane(title: "Target")
        let tab = makeTab(paneIds: [pane.id], activePaneId: pane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        var focusControl: RecordingPaneFocusAppControl? = RecordingPaneFocusAppControl()
        let focusControlWitness = WeakLayoutAdapterOwnerReference(focusControl)
        let adapter = AgentStudioIPCLayoutAdapter(
            workspaceStore: store,
            windowLifecycleReader: FakeLayoutWorkspaceWindowLifecycleReader(
                snapshot: .singleActiveWindow(UUIDv7.generate())
            ),
            paneFocusControl: try #require(focusControl),
            workspaceActionExecutor: RecordingIPCLayoutActionExecutor()
        )

        focusControl = nil

        #expect(focusControlWitness.value == nil)
        do {
            _ = try await adapter.focusPane(
                IPCHandle(kind: .pane, reference: .canonicalUUID(pane.id))
            )
            Issue.record("focusPane unexpectedly retained its App owner")
        } catch let error as AppIPCLayoutError {
            #expect(error.reason == .noActiveWindow)
        }
    }

    @Test("pane focus fails closed when no workspace window is active")
    func paneFocusFailsClosedWhenNoWorkspaceWindowIsActive() async throws {
        let harness = LayoutAdapterHarness(windowSnapshot: .empty)

        do {
            _ = try await harness.adapter.focusPane(IPCHandle(kind: .pane, reference: .friendlyOrdinal(1)))
            Issue.record("focusPane unexpectedly succeeded without an active window")
        } catch let error as AppIPCLayoutError {
            #expect(error.reason == .noActiveWindow)
        }
    }

    @Test("pane focus resolves friendly ordinal and delegates to focus control seam")
    func paneFocusResolvesFriendlyOrdinalAndDelegatesToFocusControlSeam() async throws {
        let store = makeIPCLayoutWorkspaceStore()
        let firstPane = store.createPane(title: "First")
        let secondPane = store.createPane(title: "Second")
        let tab = makeTab(paneIds: [firstPane.id, secondPane.id], activePaneId: firstPane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let focusControl = RecordingPaneFocusAppControl()
        let harness = LayoutAdapterHarness(store: store, focusControl: focusControl)

        let result = try await harness.adapter.focusPane(IPCHandle(kind: .pane, reference: .friendlyOrdinal(2)))

        #expect(result == IPCPaneFocusResult(paneId: secondPane.id, focused: true))
        #expect(focusControl.focusedPaneIds == [secondPane.id])
    }

    @Test("pane focus result waits for the focus owner completion")
    func paneFocusResultWaitsForFocusOwnerCompletion() async throws {
        let store = makeIPCLayoutWorkspaceStore()
        let pane = store.createPane(title: "Target")
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let focusControl = HeldPaneFocusAppControl()
        let harness = LayoutAdapterHarness(store: store, focusControl: focusControl)
        var result: IPCPaneFocusResult?
        let focusTask = Task { @MainActor in
            result = try await harness.adapter.focusPane(
                IPCHandle(kind: .pane, reference: .friendlyOrdinal(1))
            )
        }

        let heldPaneID = try await focusControl.focusCompletion.firstArrival()
        #expect(heldPaneID == pane.id)
        #expect(result == nil)
        focusControl.focusCompletion.release()
        try await focusTask.value

        #expect(focusControl.focusedPaneIDs == [pane.id])
        #expect(result == IPCPaneFocusResult(paneId: pane.id, focused: true))
    }

    /// The reply to `pane.focus` must come from the committed focus operation,
    /// not from having started it. The App focus owner is the production
    /// `PaneTabViewControllerPaneFocusAppControl`; only the pane tab controller
    /// behind it is a fake, whose submitted focus task awaits a held step. A
    /// failed step is a focus that did not commit, so the reply must fail; a
    /// released step commits the focus before the reply reports success.
    @Test("pane focus reply depends on the submitted focus task")
    func paneFocusReplyDependsOnSubmittedFocusTask() async throws {
        try await proveReplyDependsOnStep(
            makeScenario: { () -> CommittedPaneFocusHeldReply in
                let store = makeIPCLayoutWorkspaceStore()
                let sourcePane = store.createPane(title: "Source")
                let targetPane = store.createPane(title: "Target")
                let sourceTab = Tab(paneId: sourcePane.id)
                let targetTab = Tab(paneId: targetPane.id)
                store.appendTab(sourceTab)
                store.appendTab(targetTab)
                store.setActiveTab(sourceTab.id)
                let submittedFocus = HeldStep<UUID>("pane.focus submitted focus task")
                let focusSubmitter = HeldTargetedPaneFocusSubmitter(store: store, submittedFocus: submittedFocus)
                let focusControl = PaneTabViewControllerPaneFocusAppControl(
                    targetedPaneFocusSubmitter: focusSubmitter,
                    workspaceStore: store
                )
                let adapter = LayoutAdapterHarness(store: store, focusControl: focusControl).adapter
                let scenario = CommittedPaneFocusScenario(
                    store: store,
                    focusControl: focusControl,
                    focusSubmitter: focusSubmitter,
                    targetTabID: targetTab.id,
                    targetPaneID: targetPane.id
                )
                return HeldReplyScenario(context: scenario, step: submittedFocus) { @MainActor in
                    do {
                        return .success(
                            try await adapter.focusPane(
                                IPCHandle(kind: .pane, reference: .canonicalUUID(targetPane.id))
                            )
                        )
                    } catch {
                        return .failure(error)
                    }
                }
            },
            replyReportsFailure: { (reply: PaneFocusReply, scenario: CommittedPaneFocusScenario) -> Bool in
                guard case .failure(let error) = reply else { return false }
                #expect((error as? AppIPCLayoutError)?.reason == .validationRejected)
                #expect(scenario.focusSubmitter.submittedPaneIDs == [scenario.targetPaneID])
                #expect(scenario.store.activeTabId != scenario.targetTabID)
                return true
            },
            assertCommitted: { (reply: PaneFocusReply, scenario: CommittedPaneFocusScenario) throws in
                #expect(try reply.get() == IPCPaneFocusResult(paneId: scenario.targetPaneID, focused: true))
                #expect(scenario.focusSubmitter.submittedPaneIDs == [scenario.targetPaneID])
                #expect(scenario.store.activeTabId == scenario.targetTabID)
            }
        )
    }

    @Test("pane focus reports target not found for missing pane handle")
    func paneFocusReportsTargetNotFoundForMissingPaneHandle() async throws {
        let harness = LayoutAdapterHarness()

        do {
            _ = try await harness.adapter.focusPane(IPCHandle(kind: .pane, reference: .canonicalUUID(UUID())))
            Issue.record("focusPane unexpectedly succeeded for a missing pane")
        } catch let error as AppIPCLayoutError {
            #expect(error.reason == .targetNotFound)
        }
    }

    @Test("pane focus rejects non-pane handles")
    func paneFocusRejectsNonPaneHandles() async throws {
        let harness = LayoutAdapterHarness()

        do {
            _ = try await harness.adapter.focusPane(IPCHandle(kind: .workspace, reference: .friendlyOrdinal(1)))
            Issue.record("focusPane unexpectedly accepted a workspace handle")
        } catch let error as AppIPCLayoutError {
            #expect(error.reason == .validationRejected)
        }
    }

    @Test("pane split resolves requested pane instead of active pane")
    func paneSplitResolvesRequestedPaneInsteadOfActivePane() async throws {
        let store = makeIPCLayoutWorkspaceStore()
        let activePane = store.createPane(title: "Active")
        let requestedPane = store.createPane(title: "Requested")
        let tab = makeTab(paneIds: [activePane.id, requestedPane.id], activePaneId: activePane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let workspaceActionExecutor = RecordingIPCLayoutActionExecutor()
        let harness = LayoutAdapterHarness(store: store, workspaceActionExecutor: workspaceActionExecutor)

        let result = try await harness.adapter.splitPane(
            IPCPaneSplitParams(handle: "pane:2", direction: .right, correlationId: nil)
        )

        #expect(result.targetPaneId == requestedPane.id)
        #expect(workspaceActionExecutor.actions.count == 1)
        guard case .insertPaneRequest(let request) = workspaceActionExecutor.actions.first else {
            Issue.record("pane split did not delegate an insertPaneRequest")
            return
        }
        #expect(request.targetTabId == tab.id)
        #expect(request.targetPaneId == requestedPane.id)
        #expect(request.direction == .right)
        #expect(request.source == .newTerminal)
    }

    @Test("pane close delegates explicit pane action")
    func paneCloseDelegatesExplicitPaneAction() async throws {
        let store = makeIPCLayoutWorkspaceStore()
        let firstPane = store.createPane(title: "First")
        let secondPane = store.createPane(title: "Second")
        let tab = makeTab(paneIds: [firstPane.id, secondPane.id], activePaneId: firstPane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let workspaceActionExecutor = RecordingIPCLayoutActionExecutor()
        let harness = LayoutAdapterHarness(store: store, workspaceActionExecutor: workspaceActionExecutor)

        let result = try await harness.adapter.closePane(
            IPCPaneCloseParams(handle: "pane:2", correlationId: nil), ownPaneAssertion: nil)

        #expect(result.paneId == secondPane.id)
        #expect(workspaceActionExecutor.actions == [.closePane(tabId: tab.id, paneId: secondPane.id)])
    }

    @Test("drawer methods delegate through layout action seam")
    func drawerMethodsDelegateThroughLayoutActionSeam() async throws {
        let store = makeIPCLayoutWorkspaceStore()
        let parentPane = store.createPane(title: "Parent")
        let tab = makeTab(paneIds: [parentPane.id], activePaneId: parentPane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let workspaceActionExecutor = RecordingIPCLayoutActionExecutor()
        let harness = LayoutAdapterHarness(store: store, workspaceActionExecutor: workspaceActionExecutor)

        // The recording seam creates nothing, so the adapter's check that the
        // named child exists refuses to report a pane it cannot find.
        await #expect(throws: AppIPCLayoutError(reason: .validationRejected)) {
            _ = try await harness.adapter.addDrawerPane(
                IPCDrawerAddPaneParams(parentPaneHandle: "pane:1", correlationId: nil), ownPaneAssertion: nil
            )
        }
        let toggleResult = try await harness.adapter.toggleDrawer(
            IPCDrawerToggleParams(parentPaneHandle: "pane:1", correlationId: nil)
        )

        #expect(toggleResult.parentPaneId == parentPane.id)
        #expect(workspaceActionExecutor.actions.count == 2)
        guard
            case .addDrawerChildInBackground(parentPane.id, _, .terminal)? = workspaceActionExecutor.actions.first
        else {
            Issue.record("drawer.addPane must create its child in the background")
            return
        }
        #expect(workspaceActionExecutor.actions.last == .toggleDrawer(paneId: parentPane.id))
    }

    @Test("drawer.addPane refuses Bridge, code-viewer and non-web browser content before creating a pane")
    func drawerAddPaneRefusesDisallowedContent() async throws {
        let store = makeIPCLayoutWorkspaceStore()
        let parentPane = store.createPane(title: "Parent")
        let tab = makeTab(paneIds: [parentPane.id], activePaneId: parentPane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let workspaceActionExecutor = RecordingIPCLayoutActionExecutor()
        let harness = LayoutAdapterHarness(store: store, workspaceActionExecutor: workspaceActionExecutor)

        for content in [
            IPCDrawerChildContent.bridge, .codeViewer, .browser(url: "file:///tmp/x"), .browser(url: "about:blank"),
        ] {
            await #expect(throws: AppIPCLayoutError(reason: .validationRejected), "\(content)") {
                _ = try await harness.adapter.addDrawerPane(
                    IPCDrawerAddPaneParams(parentPaneHandle: "pane:1", content: content, correlationId: nil),
                    ownPaneAssertion: nil
                )
            }
        }
        #expect(workspaceActionExecutor.actions.isEmpty)
    }

    @Test("drawer methods reject drawer child handles as parents")
    func drawerMethodsRejectDrawerChildHandlesAsParents() async throws {
        let store = makeIPCLayoutWorkspaceStore()
        let parentPane = store.createPane(title: "Parent")
        let drawerPane = store.paneAtom.addDrawerPane(
            to: parentPane.id,
            parentFallbackCWD: nil,
            zmxSessionID: .generateUUIDv7()
        )
        let tab = makeTab(paneIds: [parentPane.id], activePaneId: parentPane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let workspaceActionExecutor = RecordingIPCLayoutActionExecutor()
        let harness = LayoutAdapterHarness(store: store, workspaceActionExecutor: workspaceActionExecutor)

        do {
            _ = try await harness.adapter.addDrawerPane(
                IPCDrawerAddPaneParams(parentPaneHandle: "pane:2", correlationId: nil), ownPaneAssertion: nil
            )
            Issue.record("drawer.addPane unexpectedly accepted a drawer child as parent")
        } catch let error as AppIPCLayoutError {
            #expect(error.reason == .validationRejected)
        }

        do {
            _ = try await harness.adapter.toggleDrawer(
                IPCDrawerToggleParams(parentPaneHandle: "pane:2", correlationId: nil)
            )
            Issue.record("drawer.toggle unexpectedly accepted a drawer child as parent")
        } catch let error as AppIPCLayoutError {
            #expect(error.reason == .validationRejected)
        }

        #expect(drawerPane?.isDrawerChild == true)
        #expect(workspaceActionExecutor.actions.isEmpty)
    }

    @Test("layout methods report validation rejection from action owner")
    func layoutMethodsReportValidationRejectionFromActionOwner() async throws {
        let store = makeIPCLayoutWorkspaceStore()
        let parentPane = store.createPane(title: "Parent")
        let tab = makeTab(paneIds: [parentPane.id], activePaneId: parentPane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let workspaceActionExecutor = RecordingIPCLayoutActionExecutor(accepted: false)
        let harness = LayoutAdapterHarness(store: store, workspaceActionExecutor: workspaceActionExecutor)

        do {
            _ = try await harness.adapter.splitPane(
                IPCPaneSplitParams(handle: "pane:1", direction: .right, correlationId: nil)
            )
            Issue.record("pane.split unexpectedly reported success after owner rejection")
        } catch let error as AppIPCLayoutError {
            #expect(error.reason == .validationRejected)
        }
    }

    @Test("concrete pane focus control routes through PaneTabViewController owner chain")
    func concretePaneFocusControlRoutesThroughPaneTabViewControllerOwnerChain() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let harness = makeHarness()
            let firstPane = harness.store.createPane(title: "First")
            let secondPane = harness.store.createPane(title: "Second")
            let tab = makeTab(paneIds: [firstPane.id, secondPane.id], activePaneId: firstPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(firstPane.id, inTab: tab.id)
            let focusControl = PaneTabViewControllerPaneFocusAppControl(
                targetedPaneFocusSubmitter: harness.controller,
                workspaceStore: harness.store
            )

            let focusWindow = makePaneTabViewControllerCommandWindow(for: harness.controller)
            focusWindow.isReleasedWhenClosed = false
            defer { focusWindow.close() }
            try attachPaneHost(paneId: secondPane.id, in: harness, to: focusWindow)

            try await focusControl.focusPane(secondPane.id)

            #expect(harness.store.activeTabId == tab.id)
            #expect(harness.store.tab(tab.id)?.activePaneId == secondPane.id)
        }
    }

    @Test("a retained pane focus control rejects its shut down owner without changing selection")
    func retainedPaneFocusControlRejectsShutdownOwner() async throws {
        await withAsyncTestCoreAtoms { _ in
            let harness = makeHarness()
            let firstPane = harness.store.createPane(title: "First")
            let secondPane = harness.store.createPane(title: "Second")
            let tab = makeTab(paneIds: [firstPane.id, secondPane.id], activePaneId: firstPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(firstPane.id, inTab: tab.id)
            let focusControl = PaneTabViewControllerPaneFocusAppControl(
                targetedPaneFocusSubmitter: harness.controller,
                workspaceStore: harness.store
            )
            harness.controller.shutdown()

            await #expect(throws: PaneFocusAppControlError.validationRejected) {
                try await focusControl.focusPane(secondPane.id)
            }
            #expect(harness.store.tab(tab.id)?.activePaneId == firstPane.id)
        }
    }

    @Test("App focus composition resolves the current window on every call")
    func appFocusCompositionDoesNotCaptureReplacedWindow() async throws {
        let delegate = AppDelegate()
        delegate.store = makeIPCLayoutWorkspaceStore()
        let firstWindow = RecordingIPCFocusWindowController(window: nil)
        let secondWindow = RecordingIPCFocusWindowController(window: nil)
        let paneId = delegate.store.createPane(title: "Target").id
        delegate.mainWindowController = firstWindow
        try await delegate.focusPane(paneId)
        delegate.mainWindowController = secondWindow
        try await delegate.focusPane(paneId)

        #expect(firstWindow.focusControl.focusedPaneIds == [paneId])
        #expect(secondWindow.focusControl.focusedPaneIds == [paneId])
        delegate.mainWindowController = nil
        await #expect(throws: AppIPCLayoutError.self) {
            try await delegate.focusPane(paneId)
        }
        #expect(secondWindow.focusControl.focusedPaneIds == [paneId])
    }

    @Test("concrete pane focus control rejects completion when no native host can focus")
    func concretePaneFocusControlRejectsMissingNativeHost() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let harness = makeHarness()
            let pane = harness.store.createPane(title: "Target")
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let focusControl = PaneTabViewControllerPaneFocusAppControl(
                targetedPaneFocusSubmitter: harness.controller,
                workspaceStore: harness.store
            )

            do {
                try await focusControl.focusPane(pane.id)
                Issue.record("focusPane unexpectedly succeeded without a native pane host")
            } catch let error as PaneFocusAppControlError {
                #expect(error == .validationRejected)
            }
        }
    }

    @Test("concrete pane focus control maps rejected admission to validation rejection")
    func concretePaneFocusControlRejectsClosedAdmission() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let harness = makeHarness()
            let firstPane = harness.store.createPane(title: "First")
            let secondPane = harness.store.createPane(title: "Second")
            let tab = makeTab(paneIds: [firstPane.id, secondPane.id], activePaneId: firstPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let focusWindow = makePaneTabViewControllerCommandWindow(for: harness.controller)
            focusWindow.isReleasedWhenClosed = false
            defer { focusWindow.close() }
            try attachPaneHost(paneId: secondPane.id, in: harness, to: focusWindow)
            let focusControl = PaneTabViewControllerPaneFocusAppControl(
                targetedPaneFocusSubmitter: harness.controller,
                workspaceStore: harness.store
            )
            await harness.executor.stopAcceptingCommandsAndDrain()

            do {
                try await focusControl.focusPane(secondPane.id)
                Issue.record("focusPane unexpectedly succeeded after admission closed")
            } catch let error as PaneFocusAppControlError {
                #expect(error == .validationRejected)
            }
            #expect(harness.store.tab(tab.id)?.activePaneId == firstPane.id)
        }
    }

    @Test("concrete layout actions register hosts before exposing created panes")
    func concreteLayoutActionsRegisterHostsBeforeExposingCreatedPanes() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let harness = makeHarness()
            let (repo, worktree) = makeRepoAndWorktree(harness.store, root: harness.tempDir)
            let parentPane = harness.store.createPane(
                launchDirectory: worktree.path,
                title: "Parent",
                facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
            )
            let tab = makeTab(paneIds: [parentPane.id], activePaneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(parentPane.id, inTab: tab.id)
            let focusControl = RecordingPaneFocusAppControl()
            let adapter = AgentStudioIPCLayoutAdapter(
                workspaceStore: harness.store,
                windowLifecycleReader: FakeLayoutWorkspaceWindowLifecycleReader(snapshot: .singleActiveWindow(UUID())),
                paneFocusControl: focusControl,
                workspaceActionExecutor: harness.executor
            )

            let panesBeforeSplit = harness.store.paneAtom.graphAtom.paneIDs
            _ = try await adapter.splitPane(
                IPCPaneSplitParams(handle: "pane:1", direction: .right, correlationId: nil)
            )
            let splitPaneIds = harness.store.paneAtom.graphAtom.paneIDs.subtracting(panesBeforeSplit)
            let splitPaneId = try #require(splitPaneIds.first)

            #expect(harness.viewRegistry.view(for: splitPaneId) != nil)
            let splitFacets = try #require(
                harness.store.paneAtom.graphAtom.paneState(splitPaneId)?.durableContextFacets
            )
            #expect(splitFacets.repoId == repo.id)
            #expect(splitFacets.worktreeId == worktree.id)
            #expect(splitFacets.cwd?.standardizedFileURL.path == worktree.path.standardizedFileURL.path)

            let panesBeforeDrawerAdd = harness.store.paneAtom.graphAtom.paneIDs
            let added = try await adapter.addDrawerPane(
                IPCDrawerAddPaneParams(parentPaneHandle: "pane:1", correlationId: nil), ownPaneAssertion: nil
            )
            let drawerPaneIds = harness.store.paneAtom.graphAtom.paneIDs.subtracting(panesBeforeDrawerAdd)
            let drawerPaneId = try #require(drawerPaneIds.first)
            #expect(drawerPaneIds == [added.childPaneId])
            #expect(added.childHandle == drawerPaneId.uuidString)

            #expect(harness.store.paneAtom.pane(drawerPaneId)?.isDrawerChild == true)
            #expect(harness.viewRegistry.view(for: drawerPaneId) != nil)
            let drawerFacets = try #require(
                harness.store.paneAtom.graphAtom.paneState(drawerPaneId)?.durableContextFacets
            )
            #expect(drawerFacets.repoId == repo.id)
            #expect(drawerFacets.worktreeId == worktree.id)
            #expect(drawerFacets.cwd?.standardizedFileURL.path == worktree.path.standardizedFileURL.path)
        }
    }
}

@MainActor
private struct LayoutAdapterHarness {
    let adapter: AgentStudioIPCLayoutAdapter
    let focusControl: any PaneFocusAppControlling & AnyObject

    init(
        store: WorkspaceStore = makeIPCLayoutWorkspaceStore(),
        windowSnapshot: WorkspaceWindowLifecycleSnapshot = .singleActiveWindow(UUID()),
        focusControl: (any PaneFocusAppControlling & AnyObject)? = nil,
        workspaceActionExecutor: any AgentStudioIPCLayoutActionExecuting = RecordingIPCLayoutActionExecutor()
    ) {
        let focusControl = focusControl ?? RecordingPaneFocusAppControl()
        self.focusControl = focusControl
        adapter = AgentStudioIPCLayoutAdapter(
            workspaceStore: store,
            windowLifecycleReader: FakeLayoutWorkspaceWindowLifecycleReader(snapshot: windowSnapshot),
            paneFocusControl: focusControl,
            workspaceActionExecutor: workspaceActionExecutor
        )
    }
}

@MainActor
private final class RecordingPaneFocusAppControl: PaneFocusAppControlling, @unchecked Sendable {
    private(set) var focusedPaneIds: [UUID] = []
    var error: PaneFocusAppControlError?

    func focusPane(_ paneId: UUID) async throws {
        if let error {
            throw error
        }
        focusedPaneIds.append(paneId)
    }
}

/// Stands in for the App focus owner and holds its completion, so a test can
/// observe the adapter before the owner finishes.
@MainActor
private final class HeldPaneFocusAppControl: PaneFocusAppControlling, @unchecked Sendable {
    let focusCompletion = HeldStep<UUID>("pane focus owner completion")
    private(set) var focusedPaneIDs: [UUID] = []

    func focusPane(_ paneId: UUID) async throws {
        focusedPaneIDs.append(paneId)
        try await focusCompletion.arrive(paneId)
    }
}

private typealias PaneFocusReply = Result<IPCPaneFocusResult, any Error>
private typealias CommittedPaneFocusHeldReply = HeldReplyScenario<
    CommittedPaneFocusScenario, UUID, PaneFocusReply
>

private struct CommittedPaneFocusScenario: Sendable {
    let store: WorkspaceStore
    let focusControl: PaneTabViewControllerPaneFocusAppControl
    let focusSubmitter: HeldTargetedPaneFocusSubmitter
    let targetTabID: UUID
    let targetPaneID: UUID
}

/// Stands in for the pane tab controller behind the App focus owner. Its
/// submitted focus task holds at a step; a failed step is a focus that did not
/// commit, and a released step commits it by selecting the pane's tab.
@MainActor
private final class HeldTargetedPaneFocusSubmitter: TargetedPaneFocusSubmitting {
    private let store: WorkspaceStore
    private let submittedFocus: HeldStep<UUID>
    private(set) var submittedPaneIDs: [UUID] = []

    init(store: WorkspaceStore, submittedFocus: HeldStep<UUID>) {
        self.store = store
        self.submittedFocus = submittedFocus
    }

    var acceptsIPCCommands: Bool { true }

    func hasNativePaneHost(_: UUID) -> Bool { true }

    func submitTargetedPaneFocus(_ paneId: UUID) -> Task<Bool, Never> {
        submittedPaneIDs.append(paneId)
        return Task { @MainActor [store, submittedFocus] in
            do {
                try await submittedFocus.arrive(paneId)
            } catch {
                return false
            }
            guard let tabId = store.tabLayoutAtom.tabID(containingPane: paneId) else { return false }
            store.setActiveTab(tabId)
            return true
        }
    }
}

@MainActor
private final class RecordingIPCLayoutActionExecutor: AgentStudioIPCLayoutActionExecuting, @unchecked Sendable {
    private let accepted: Bool
    private(set) var actions: [WorkspaceActionCommand] = []

    init(accepted: Bool = true) {
        self.accepted = accepted
    }

    func execute(_ action: WorkspaceActionCommand) -> Bool {
        actions.append(action)
        return accepted
    }

    func execute(
        _ action: WorkspaceActionCommand,
        ownPaneAssertion _: WorkspaceOwnPaneAssertion
    ) -> WorkspaceScopedActionOutcome {
        actions.append(action)
        return accepted ? .applied : .rejected
    }
}

private struct FakeLayoutWorkspaceWindowLifecycleReader: WorkspaceWindowLifecycleReading {
    let snapshotValue: WorkspaceWindowLifecycleSnapshot

    init(snapshot: WorkspaceWindowLifecycleSnapshot) {
        snapshotValue = snapshot
    }

    func snapshot() -> WorkspaceWindowLifecycleSnapshot {
        snapshotValue
    }
}

extension WorkspaceWindowLifecycleSnapshot {
    fileprivate static var empty: Self {
        Self(
            registeredWindowIds: [],
            keyWindowId: nil,
            focusedWindowId: nil,
            preferredWorkspaceWindowId: nil
        )
    }

    fileprivate static func singleActiveWindow(_ windowId: UUID) -> Self {
        Self(
            registeredWindowIds: [windowId],
            keyWindowId: windowId,
            focusedWindowId: windowId,
            preferredWorkspaceWindowId: windowId
        )
    }
}

@MainActor
private func makeIPCLayoutWorkspaceStore() -> WorkspaceStore {
    WorkspaceStore()
}

@MainActor
private final class RecordingIPCFocusWindowController: MainWindowController {
    let focusControl = RecordingPaneFocusAppControl()
    override var acceptsIPCCommands: Bool { true }
    override func makePaneFocusAppControl(store _: WorkspaceStore) -> (any PaneFocusAppControlling)? {
        focusControl
    }
}

private final class WeakLayoutAdapterOwnerReference<Owner: AnyObject> {
    weak var value: Owner?

    init(_ value: Owner?) {
        self.value = value
    }
}
