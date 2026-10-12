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
extension WorkspaceSurfaceTerminalRestoreIntegrationTests {

    private struct RealHeldTerminalFixture {
        let store: WorkspaceStore
        let pane: Pane
        let tab: Tab
        let surfaceManager: SurfaceManager
        let coordinator: WorkspaceSurfaceCoordinator
        let managedSurface: ManagedSurface
        let surface: Ghostty.SurfaceView
        let heldState: HeldPanePreviewState
        let target: ValidatedPanePreviewTarget
    }

    private func withRealHeldTerminalFixture(
        _ operation: @MainActor (RealHeldTerminalFixture) async throws -> Void
    ) async throws {
        try await withRealSurfaceManagerHarness { store, _, surfaceManager, windowLifecycleStore, coordinator in
            let pane = store.createPane(provider: .zmx)
            let tab = Tab(paneId: pane.id, name: "Held terminal")
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

            let surface = Ghostty.SurfaceView(
                managedSurfaceID: UUIDv7.generate(),
                appCommandDispatcher: TerminalRestoreNoOpAppCommandDispatcher()
            )
            let managedSurface = try surfaceManager.acceptCreatedSurface(
                surface,
                metadata: SurfaceMetadata(
                    paneId: pane.id,
                    zmxSessionID: pane.terminalState?.zmxSessionID
                )
            ).get()
            let heldState = HeldPanePreviewState()
            coordinator.bindHeldPanePreviewState(heldState)
            let target = ValidatedPanePreviewTarget(
                paneID: pane.id,
                owningTabID: tab.id,
                provider: pane.provider,
                sessionID: pane.terminalState?.zmxSessionID
            )
            try await operation(
                RealHeldTerminalFixture(
                    store: store,
                    pane: pane,
                    tab: tab,
                    surfaceManager: surfaceManager,
                    coordinator: coordinator,
                    managedSurface: managedSurface,
                    surface: surface,
                    heldState: heldState,
                    target: target
                )
            )
        }
    }

    private func makeLateTerminalView(for fixture: RealHeldTerminalFixture) -> TerminalPaneMountView {
        TerminalPaneMountView(
            surfaceOperations: makeAppTerminalFixtureMountOperations(),
            restoredSurfaceId: fixture.managedSurface.id,
            paneId: fixture.pane.id,
            title: "Late terminal"
        )
    }

    @Test
    func heldPreview_attachesHiddenSurfaceAndPublishesAfterDisplay() async throws {
        try await withRealSurfaceManagerHarness { store, _, surfaceManager, windowLifecycleStore, coordinator in
            let pane = store.createPane(provider: .zmx)
            let tab = Tab(paneId: pane.id, name: "Hidden terminal")
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

            let surface = Ghostty.SurfaceView(
                managedSurfaceID: UUIDv7.generate(),
                appCommandDispatcher: TerminalRestoreNoOpAppCommandDispatcher()
            )
            let managedSurface = try surfaceManager.acceptCreatedSurface(
                surface,
                metadata: SurfaceMetadata(
                    paneId: pane.id,
                    zmxSessionID: pane.terminalState?.zmxSessionID
                )
            ).get()
            let terminalView = TerminalPaneMountView(
                surfaceOperations: makeAppTerminalFixtureMountOperations(),
                restoredSurfaceId: managedSurface.id,
                paneId: pane.id,
                title: "Hidden terminal"
            )
            _ = coordinator.registerHostedView(mountedView: terminalView, for: pane.id)

            #expect(surfaceManager.hiddenSurfaceCount == 1)
            #expect(surfaceManager.activeSurfaceCount == 0)

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

            #expect(surfaceManager.hiddenSurfaceCount == 0)
            #expect(surfaceManager.activeSurfaceCount == 1)
            #expect(terminalView.ghosttySurface === surface)
            #expect(heldState.presentedTarget == target)
        }
    }

    @Test
    func heldPreview_lateValidSurfacePublishesThroughRealAttachment() async throws {
        try await withRealHeldTerminalFixture { fixture in
            #expect(fixture.heldState.beginSpaceHold(requestedTarget: fixture.target))
            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = fixture.coordinator.beginHeldPanePreviewPreparation()

            let lateView = makeLateTerminalView(for: fixture)
            _ = fixture.coordinator.registerHostedView(mountedView: lateView, for: fixture.pane.id)

            #expect(fixture.surfaceManager.hiddenSurfaceCount == 0)
            #expect(fixture.surfaceManager.activeSurfaceCount == 1)
            #expect(lateView.ghosttySurface === fixture.surface)
            #expect(fixture.heldState.presentedTarget == fixture.target)
        }
    }

    @Test
    func heldPreview_lateValidBackgroundTabSurfaceUsesTrustedBounds() async throws {
        try await withRealHeldTerminalFixture { fixture in
            let backgroundPane = fixture.store.createPane(provider: .zmx)
            let backgroundTab = Tab(paneId: backgroundPane.id, name: "Background")
            fixture.store.appendTab(backgroundTab)
            fixture.store.setActiveTab(backgroundTab.id)

            #expect(fixture.heldState.beginSpaceHold(requestedTarget: fixture.target))
            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = fixture.coordinator.beginHeldPanePreviewPreparation()
            let lateView = makeLateTerminalView(for: fixture)
            _ = fixture.coordinator.registerHostedView(mountedView: lateView, for: fixture.pane.id)

            #expect(lateView.ghosttySurface === fixture.surface)
            #expect(fixture.heldState.presentedTarget == fixture.target)
        }
    }

    @Test
    func heldPreview_lateValidDrawerChildPublishesWhenParentIsAbsentFromActiveArrangement() async throws {
        try await withRealSurfaceManagerHarness { store, _, surfaceManager, windowLifecycleStore, coordinator in
            let parentPane = store.createPane(provider: .zmx)
            let drawerPane = try #require(store.addDrawerPane(to: parentPane.id))
            let backgroundPane = store.createPane(provider: .zmx)
            let drawerID = try #require(
                store.paneAtom.graphAtom.paneStructuralFacts(parentPane.id)?.ownedDrawerID
            )
            let activeArrangement = PaneArrangement(
                name: "Background only",
                isDefault: true,
                layout: Layout(paneId: backgroundPane.id),
                activePaneId: backgroundPane.id,
                drawerViews: [
                    drawerID: DrawerView(
                        layout: DrawerGridLayout(topRow: Layout(paneId: drawerPane.id)),
                        activeChildId: drawerPane.id
                    )
                ]
            )
            let tab = Tab(
                name: "Drawer preview",
                allPaneIds: [parentPane.id, drawerPane.id, backgroundPane.id],
                arrangements: [activeArrangement],
                activeArrangementId: activeArrangement.id
            )
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

            let surface = Ghostty.SurfaceView(
                managedSurfaceID: UUIDv7.generate(),
                appCommandDispatcher: TerminalRestoreNoOpAppCommandDispatcher()
            )
            let managedSurface = try surfaceManager.acceptCreatedSurface(
                surface,
                metadata: SurfaceMetadata(
                    paneId: drawerPane.id,
                    zmxSessionID: drawerPane.terminalState?.zmxSessionID
                )
            ).get()
            let heldState = HeldPanePreviewState()
            coordinator.bindHeldPanePreviewState(heldState)
            let target = ValidatedPanePreviewTarget(
                paneID: drawerPane.id,
                owningTabID: tab.id,
                provider: drawerPane.provider,
                sessionID: drawerPane.terminalState?.zmxSessionID
            )
            #expect(heldState.beginSpaceHold(requestedTarget: target))
            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = coordinator.beginHeldPanePreviewPreparation()

            let lateView = TerminalPaneMountView(
                surfaceOperations: makeAppTerminalFixtureMountOperations(),
                restoredSurfaceId: managedSurface.id,
                paneId: drawerPane.id,
                title: "Drawer preview"
            )
            _ = coordinator.registerHostedView(mountedView: lateView, for: drawerPane.id)

            #expect(lateView.ghosttySurface === surface)
            #expect(heldState.presentedTarget == target)
        }
    }

    @Test
    func heldPreview_rejectsLateTerminalHostWithSurfaceIdButNoDisplayedSurface() async throws {
        try await withTerminalRestoreHarness { harness in
            let pane = makeAcceptedPreparedTerminalPane(launchDirectory: harness.tempDir)
            try #require(harness.store.paneAtom.insertRestoredPane(pane))
            let tab = Tab(paneId: pane.id, name: "Late terminal")
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

            let heldState = HeldPanePreviewState()
            harness.coordinator.bindHeldPanePreviewState(heldState)
            let target = ValidatedPanePreviewTarget(
                paneID: pane.id,
                owningTabID: tab.id,
                provider: pane.provider,
                sessionID: pane.terminalState?.zmxSessionID
            )
            #expect(heldState.beginSpaceHold(requestedTarget: target))

            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = harness.coordinator.beginHeldPanePreviewPreparation()
            #expect(heldState.presentedTarget == nil)

            let lateView = TerminalPaneMountView(
                surfaceOperations: makeAppTerminalFixtureMountOperations(),
                restoredSurfaceId: UUIDv7.generate(),
                paneId: pane.id,
                title: "Late terminal"
            )
            _ = harness.coordinator.registerHostedView(mountedView: lateView, for: pane.id)

            #expect(lateView.ghosttySurface == nil)
            #expect(heldState.presentedTarget == nil)
        }
    }

    @Test
    func heldPreview_rejectsLatePreparationAfterReleaseTargetAndBoundsChange() async throws {
        try await withRealHeldTerminalFixture { fixture in
            #expect(fixture.heldState.beginSpaceHold(requestedTarget: fixture.target))
            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = fixture.coordinator.beginHeldPanePreviewPreparation()
            let targetWithChangedIdentity = ValidatedPanePreviewTarget(
                paneID: fixture.pane.id,
                owningTabID: fixture.tab.id,
                provider: .ghostty,
                sessionID: nil
            )
            fixture.heldState.updateRequestedTarget(targetWithChangedIdentity)
            let staleIdentityView = makeLateTerminalView(for: fixture)
            _ = fixture.coordinator.registerHostedView(
                mountedView: staleIdentityView,
                for: fixture.pane.id
            )
            #expect(fixture.heldState.presentedTarget == nil)
            #expect(fixture.surfaceManager.hiddenSurfaceCount == 1)
            fixture.coordinator.unregisterHostedView(for: fixture.pane.id)

            #expect(fixture.heldState.beginSpaceHold(requestedTarget: fixture.target) == false)
            fixture.heldState.endSpaceHold()
            #expect(fixture.heldState.beginSpaceHold(requestedTarget: fixture.target))
            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = fixture.coordinator.beginHeldPanePreviewPreparation()
            fixture.heldState.endSpaceHold()
            let staleReleaseView = makeLateTerminalView(for: fixture)
            _ = fixture.coordinator.registerHostedView(
                mountedView: staleReleaseView,
                for: fixture.pane.id
            )
            #expect(fixture.heldState.presentedTarget == nil)
            fixture.coordinator.unregisterHostedView(for: fixture.pane.id)

            #expect(fixture.heldState.beginSpaceHold(requestedTarget: fixture.target))
            // fire-and-forget: the test asserts preview state; the deferred reevaluation handle is not its claim
            _ = fixture.coordinator.beginHeldPanePreviewPreparation()
            fixture.coordinator.windowLifecycleStore.recordTerminalContainerBounds(
                CGRect(x: 0, y: 0, width: 1200, height: 700)
            )
            let staleBoundsView = makeLateTerminalView(for: fixture)
            _ = fixture.coordinator.registerHostedView(
                mountedView: staleBoundsView,
                for: fixture.pane.id
            )
            #expect(fixture.heldState.presentedTarget == nil)
            #expect(fixture.surfaceManager.hiddenSurfaceCount == 1)
        }
    }

    @Test
    func heldPreview_keepsRequestedTargetQueuedAcrossCanonicalRestoreRefresh() async throws {
        try await withTerminalRestoreHarness { harness in
            let activePane = makeAcceptedPreparedTerminalPane(launchDirectory: harness.tempDir)
            let previewPane = makeAcceptedPreparedTerminalPane(launchDirectory: harness.tempDir)
            try #require(harness.store.paneAtom.insertRestoredPane(activePane))
            try #require(harness.store.paneAtom.insertRestoredPane(previewPane))
            let activeTab = Tab(paneId: activePane.id, name: "Active")
            let previewTab = Tab(paneId: previewPane.id, name: "Preview")
            harness.store.appendTab(activeTab)
            harness.store.appendTab(previewTab)
            harness.store.setActiveTab(activeTab.id)
            harness.windowLifecycleStore.recordTerminalContainerBounds(trustedBounds)

            var queuedSets: [PreparedContentVisibleQueuedSet] = []
            harness.coordinator.preparedContentVisibilitySignalHandler = { visibleQueuedSet in
                queuedSets.append(visibleQueuedSet)
                return []
            }

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
            queuedSets.removeAll()

            harness.coordinator.restoreViewsForActiveTabIfNeeded(forceWhenBoundsExist: true)

            #expect(
                queuedSets.contains { $0.visiblePaneIDs.contains(PaneId(existingUUID: previewPane.id)) },
                "a canonical restore refresh must retain the held target in prepared visibility custody"
            )
        }
    }

}

@MainActor
private final class TerminalRestoreNoOpAppCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
