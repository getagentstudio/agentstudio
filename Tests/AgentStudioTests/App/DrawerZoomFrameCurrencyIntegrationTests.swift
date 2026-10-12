import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// A drawer child queued with a normal-mode frame must mount at the current
/// Pane Zoom frame after Zoom entry, a side change, and a split commit. Each
/// recovery pass is awaited through the reevaluation handler itself — a
/// causal barrier, never a sleep or poll.
@MainActor
@Suite(.serialized)
struct DrawerZoomFrameCurrencyIntegrationTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    private let containerBounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private struct QueuedDrawerChildFixture {
        let store: WorkspaceStore
        let coordinator: WorkspaceSurfaceCoordinator
        let executor: WorkspaceActionExecutor
        let sourcePane: Pane
        let drawerChild: Pane
        let tab: Tab
        let drawerLayout: DrawerGridLayout
        let generation: WorkspaceContentMountGeneration
        let childPaneID: PaneId
        let normalFrame: NSRect
        let mountHandler: RecordingPreparedTerminalMountHandler
        let port: PreparedTerminalMountAdmissionPort
        let viewRegistry: ViewRegistry
        let windowLifecycleStore: WindowLifecycleAtom
    }

    /// A drawer child pending in the prepared lane with its normal-mode frame.
    private func makeQueuedDrawerChildFixture() throws -> QueuedDrawerChildFixture {
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let windowLifecycleStore = WindowLifecycleAtom()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: SessionRuntime(store: store),
            surfaceManager: GeometryReevaluationCapturingSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: windowLifecycleStore,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        let sourcePane = store.createPane()
        let tab = Tab(paneId: sourcePane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let drawerChild = try #require(store.addDrawerPane(to: sourcePane.id))
        let drawerID = try #require(store.paneAtom.pane(sourcePane.id)?.drawer?.drawerId)
        windowLifecycleStore.recordTerminalContainerBounds(containerBounds)

        let generation = WorkspaceContentMountGeneration()
        let childPaneID = PaneId(existingUUID: drawerChild.id)
        let descriptor = TerminalActivationDescriptor(
            pane: drawerChild,
            visibilityPriority: .activeVisible,
            hostPlacement: .drawer(
                tabID: tab.id,
                parentPaneID: PaneId(existingUUID: sourcePane.id),
                drawerID: drawerID
            )
        )
        viewRegistry.installPreparedContentMountCohort(
            WorkspacePreparedContentMountCohort(
                generation: generation,
                terminalActivationInput: TerminalActivationInput(entries: [descriptor]),
                nonterminalContentMountInput: NonterminalContentMountInput(entries: [])
            )
        )
        coordinator.acceptedPreparedContentMountGeneration = generation
        let currentTab = try #require(store.tabLayoutAtom.tab(tab.id))
        let normalFrame = try #require(
            coordinator.resolveInitialFrames(for: currentTab, in: containerBounds)[drawerChild.id]
        )
        let mountHandler = RecordingPreparedTerminalMountHandler(results: [.ready(surfaceID: UUIDv7.generate())])
        return QueuedDrawerChildFixture(
            store: store,
            coordinator: coordinator,
            executor: WorkspaceActionExecutor(coordinator: coordinator, store: store),
            sourcePane: sourcePane,
            drawerChild: drawerChild,
            tab: tab,
            drawerLayout: try #require(store.drawerView(forParent: sourcePane.id)?.layout),
            generation: generation,
            childPaneID: childPaneID,
            normalFrame: normalFrame,
            mountHandler: mountHandler,
            port: PreparedTerminalMountAdmissionPort(
                generation: generation,
                initialFramesByPaneID: [childPaneID: normalFrame],
                viewRegistry: viewRegistry,
                mountHandler: mountHandler,
                descriptorsByPaneID: [childPaneID: descriptor]
            ),
            viewRegistry: viewRegistry,
            windowLifecycleStore: windowLifecycleStore
        )
    }

    @Test("a pending child keeps its trusted frame while geometry is unavailable, then refreshes when valid")
    func pendingChildSurvivesUnavailableGeometryThenRefreshes() async throws {
        // Arrange
        let fixture = try makeQueuedDrawerChildFixture()
        let (recoveryPasses, recoveryPassContinuation) = AsyncStream.makeStream(of: Set<PaneId>.self)
        fixture.coordinator.preparedTerminalGeometryReevaluationHandler = { framesByPaneID in
            recoveryPassContinuation.yield(fixture.port.refreshQueuedTrustedFrames(framesByPaneID))
        }
        var recoveryPassIterator = recoveryPasses.makeAsyncIterator()
        let tallerBounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

        // Act: valid → unavailable (container too short for any drawer) → valid.
        fixture.windowLifecycleStore.recordTerminalContainerBounds(CGRect(x: 0, y: 0, width: 1000, height: 60))
        await fixture.coordinator.reevaluatePreparedTerminalGeometry()
        let custodyWhileUnavailable = fixture.viewRegistry.preparedContentMountState(
            for: fixture.childPaneID,
            generation: fixture.generation
        )
        fixture.windowLifecycleStore.recordTerminalContainerBounds(tallerBounds)
        await fixture.coordinator.reevaluatePreparedTerminalGeometry()
        let validPass = await recoveryPassIterator.next()
        let claimOutcome = fixture.port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: fixture.generation,
                paneID: fixture.childPaneID,
                attempt: 1,
                appliedVisibilityRevision: TerminalVisibilityRevision(generation: fixture.generation, ordinal: 0)
            )
        )
        guard case .claimed(let claim) = claimOutcome else {
            Issue.record("expected the still-queued child to stay claimable, got \(claimOutcome)")
            return
        }
        _ = await fixture.port.activateClaimedTerminal(claim)

        // Assert: no queued→deferred transition; the refreshed valid frame mounts.
        let currentTab = try #require(fixture.store.tabLayoutAtom.tab(fixture.tab.id))
        let refreshedFrame = try #require(
            fixture.coordinator.resolveInitialFrames(for: currentTab, in: tallerBounds)[fixture.drawerChild.id]
        )
        #expect(custodyWhileUnavailable == .pending(owner: .terminal))
        #expect(validPass == [fixture.childPaneID])
        #expect(refreshedFrame != fixture.normalFrame)
        #expect(fixture.mountHandler.initialFrames == [refreshedFrame])

        recoveryPassContinuation.finish()
        await fixture.executor.stopAcceptingCommandsAndDrain()
        await fixture.coordinator.shutdown()
    }

    @Test("a pending drawer child mounts at the current Zoom frame after Zoom, side, and split changes")
    func pendingDrawerChildMountsAtCurrentZoomFrame() async throws {
        // Arrange
        let fixture = try makeQueuedDrawerChildFixture()
        let store = fixture.store
        let coordinator = fixture.coordinator
        let executor = fixture.executor
        let sourcePane = fixture.sourcePane
        let drawerChild = fixture.drawerChild
        let tab = fixture.tab
        let drawerLayout = fixture.drawerLayout
        let generation = fixture.generation
        let childPaneID = fixture.childPaneID
        let normalFrame = fixture.normalFrame
        let mountHandler = fixture.mountHandler
        let port = fixture.port
        let (recoveryPasses, recoveryPassContinuation) = AsyncStream.makeStream(of: Set<PaneId>.self)
        coordinator.preparedTerminalGeometryReevaluationHandler = { framesByPaneID in
            recoveryPassContinuation.yield(port.refreshQueuedTrustedFrames(framesByPaneID))
        }
        var recoveryPassIterator = recoveryPasses.makeAsyncIterator()

        // Act: normal → Zoom, move to the Bridge side, then commit the maximum 60/40 split.
        store.panePresentationAtom.enterZoom(
            inTab: tab.id,
            sourcePaneId: sourcePane.id,
            viewerPresentation: .unavailableVisible
        )
        await coordinator.reevaluatePreparedTerminalGeometry()
        let zoomPass = await recoveryPassIterator.next()
        #expect(await executor.execute(.setDrawerZoomSide(parentPaneId: sourcePane.id, side: .bridge)))
        let sidePass = await recoveryPassIterator.next()
        #expect(await executor.execute(.setZoomSplitRatio(tabId: tab.id, ratio: 0.6)))
        let splitPass = await recoveryPassIterator.next()

        let claimOutcome = port.claimPreparedTerminal(
            TerminalAdmissionProposal(
                generation: generation,
                paneID: childPaneID,
                attempt: 1,
                appliedVisibilityRevision: TerminalVisibilityRevision(generation: generation, ordinal: 0)
            )
        )
        guard case .claimed(let claim) = claimOutcome else {
            Issue.record("expected the refreshed pending child to be claimable, got \(claimOutcome)")
            return
        }
        _ = await port.activateClaimedTerminal(claim)

        // Assert: hand-derived Bridge-side content rect for a 60/40 split of
        // 1000 × (600 − toolbar): Bridge region x=600 w=400; outline 97% wide
        // centered, 85% tall on the region bottom; 8pt border inside the panel.
        let splitHeight = containerBounds.height - DrawerLayout.iconBarFrameHeight
        let outlineHeight = splitHeight * 0.85
        let connectorHeight = min(40, outlineHeight - 100)
        let expectedContentRect = CGRect(
            x: 606 + 8,
            y: splitHeight - outlineHeight + 8,
            width: 388 - 16,
            height: outlineHeight - connectorHeight - 16
        )
        let expectedChildFrame = try #require(
            TerminalPaneGeometryResolver.resolveFrames(
                for: drawerLayout,
                in: expectedContentRect,
                dividerThickness: AppStyles.General.Layout.paneGap,
                collapsedPaneWidth: AppStyles.Shell.PaneChrome.collapsedBarWidth
            )[drawerChild.id]
        )
        #expect(zoomPass == [childPaneID])
        #expect(sidePass == [childPaneID])
        #expect(splitPass == [childPaneID])
        #expect(normalFrame != expectedChildFrame)
        let mountedFrame = try #require(mountHandler.initialFrames.first.flatMap { $0 })
        #expect(abs(mountedFrame.minX - expectedChildFrame.minX) < 0.5)
        #expect(abs(mountedFrame.minY - expectedChildFrame.minY) < 0.5)
        #expect(abs(mountedFrame.width - expectedChildFrame.width) < 0.5)
        #expect(abs(mountedFrame.height - expectedChildFrame.height) < 0.5)

        recoveryPassContinuation.finish()
        await executor.stopAcceptingCommandsAndDrain()
        await coordinator.shutdown()
    }
}
