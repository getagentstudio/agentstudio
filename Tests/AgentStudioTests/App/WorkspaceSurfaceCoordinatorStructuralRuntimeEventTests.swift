import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("WorkspaceSurfaceCoordinator structural runtime events", .serialized)
struct GhosttyStructureRuntimeEventTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("structural events always drop while terminal facts from panes in no tab remain filtered")
    func structuralRuntimeEventsDoNotMutateWorkspace() async throws {
        var submittedWorkspaceActions: [WorkspaceActionCommand] = []
        let commandHandler = StructuralRuntimeCommandHandler()
        let context = try makeStructuralRuntimeContext()
        defer { try? FileManager.default.removeItem(at: context.tempDir) }
        await prepareHiddenRuntimeSources(context)
        context.coordinator.workspaceActionSubmission = { action in
            submittedWorkspaceActions.append(action)
        }

        let initialTabs = context.store.tabs
        let initialPaneIds = Set(context.store.paneAtom.paneSnapshot().keys)
        let initialActiveTabId = context.store.activeTabId
        let initialZoomPresentation = context.store.panePresentationAtom.zoomPresentation(forTab: context.sourceTabId)
        let events = structuralEvents()
        let unattachedPaneId = UUIDv7.generate()

        do {
            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = commandHandler
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    for (index, event) in events.enumerated() {
                        _ = await emit(
                            event,
                            index: index,
                            through: context.runtime,
                            sourcePaneId: context.sourcePaneId
                        )
                    }
                    let outsideLayoutEvents = await emit(
                        .bellRang,
                        index: events.count,
                        through: context.runtime,
                        sourcePaneId: context.sourcePaneId,
                        eventSourcePaneId: unattachedPaneId,
                        eventSequence: 1,
                        barrierSequence: UInt64(events.count * 2 + 1)
                    )
                    #expect(
                        !outsideLayoutEvents.contains { event in
                            if case .worktreeBellRang(let paneId) = event {
                                return paneId == unattachedPaneId
                            }
                            return false
                        })
                    _ = await emit(
                        .newSplit(direction: .left),
                        index: events.count + 1,
                        through: context.runtime,
                        sourcePaneId: context.sourcePaneId,
                        eventSourcePaneId: context.drawerChildId,
                        eventSequence: 2,
                        barrierSequence: UInt64(events.count * 2 + 2)
                    )

                    #expect(submittedWorkspaceActions.isEmpty)
                    #expect(commandHandler.targetedCommands.isEmpty)
                    #expect(context.store.tabs == initialTabs)
                    #expect(Set(context.store.paneAtom.paneSnapshot().keys) == initialPaneIds)
                    #expect(context.store.activeTabId == initialActiveTabId)
                    #expect(
                        context.store.panePresentationAtom.zoomPresentation(forTab: context.sourceTabId)
                            == initialZoomPresentation
                    )
                }
            )
        } catch {
            await context.coordinator.shutdown()
            throw error
        }

        await context.coordinator.shutdown()
    }

    @Test("drawer child terminal title facts update that child's metadata")
    func drawerChildRuntimeTitleUpdatesPane() async throws {
        let context = try makeStructuralRuntimeContext()
        defer { try? FileManager.default.removeItem(at: context.tempDir) }
        await prepareHiddenRuntimeSources(context)

        _ = await emit(
            .titleChanged("Drawer terminal title"), index: 0,
            through: context.runtime, sourcePaneId: context.sourcePaneId,
            eventSourcePaneId: context.drawerChildId
        )
        #expect(context.store.pane(context.drawerChildId)?.metadata.title == "Drawer terminal title")
        _ = await emit(
            .tabTitleChanged("Drawer tab title"), index: 1,
            through: context.runtime, sourcePaneId: context.sourcePaneId,
            eventSourcePaneId: context.drawerChildId
        )
        #expect(context.store.pane(context.drawerChildId)?.metadata.title == "Drawer tab title")

        await context.coordinator.shutdown()
    }

    @Test("drawer child terminal CWD facts update that child's metadata")
    func drawerChildRuntimeCWDUpdatesPane() async throws {
        let context = try makeStructuralRuntimeContext()
        defer { try? FileManager.default.removeItem(at: context.tempDir) }
        await prepareHiddenRuntimeSources(context)
        let expectedCWD = context.tempDir.appending(path: "Sources", directoryHint: .isDirectory)

        _ = await emit(
            .cwdChanged(expectedCWD.path), index: 0,
            through: context.runtime, sourcePaneId: context.sourcePaneId,
            eventSourcePaneId: context.drawerChildId
        )
        #expect(context.store.pane(context.drawerChildId)?.metadata.cwd == expectedCWD)

        await context.coordinator.shutdown()
    }

    @Test("terminal metadata facts from a pane in no tab remain dropped")
    func unattachedPaneRuntimeMetadataIsDropped() async throws {
        let context = try makeStructuralRuntimeContext()
        defer { try? FileManager.default.removeItem(at: context.tempDir) }
        await prepareHiddenRuntimeSources(context)
        let unattachedPane = context.store.createPane(title: "Unattached terminal")
        let initialMetadata = unattachedPane.metadata
        #expect(context.store.tabLayoutAtom.tabContaining(paneId: unattachedPane.id) == nil)

        _ = await emit(
            .titleChanged("Must stay dropped"), index: 0,
            through: context.runtime, sourcePaneId: context.sourcePaneId,
            eventSourcePaneId: unattachedPane.id
        )
        #expect(context.store.pane(unattachedPane.id)?.metadata == initialMetadata)
        _ = await emit(
            .cwdChanged(context.tempDir.appending(path: "Unattached").path), index: 1,
            through: context.runtime, sourcePaneId: context.sourcePaneId,
            eventSourcePaneId: unattachedPane.id
        )
        #expect(context.store.pane(unattachedPane.id)?.metadata == initialMetadata)

        await context.coordinator.shutdown()
    }

    private func prepareHiddenRuntimeSources(_ context: GhosttyStructureRuntimeContext) async {
        // Keep source and bell barrier in the same hidden priority tier so the
        // reducer cannot move the barrier ahead of the fact being checked.
        context.store.setActiveTab(context.store.tabs.last?.id)
        await waitForBusSubscriberRegistration(
            context.coordinator.paneEventBus, subscriberName: "WorkspaceSurfaceCoordinator")
    }

    private func makeStructuralRuntimeContext() throws -> GhosttyStructureRuntimeContext {
        installTestAtomRegistryIfNeeded()
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-ghostty-structure-events-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let store = WorkspaceStore()
        let repo = store.addRepo(at: tempDir)
        let worktree = try #require(repo.worktrees.first)
        let paneFacets = PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path)
        let sourcePane = store.createPane(
            launchDirectory: worktree.path,
            title: "Structure source",
            provider: .zmx,
            facets: paneFacets
        )
        let rightPane = store.createPane(
            launchDirectory: worktree.path,
            title: "Structure right split",
            provider: .zmx,
            facets: paneFacets
        )
        let thirdPane = store.createPane(
            launchDirectory: worktree.path,
            title: "Structure third split",
            provider: .zmx,
            facets: paneFacets
        )
        let otherTabPane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/structure-other")!)),
            metadata: PaneMetadata(title: "Other tab")
        )
        let lastTabPane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/structure-last")!)),
            metadata: PaneMetadata(title: "Last tab")
        )

        let sourceTab = Tab(paneId: sourcePane.id)
        store.appendTab(sourceTab)
        #expect(
            store.insertPane(
                rightPane.id,
                inTab: sourceTab.id,
                at: sourcePane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        #expect(
            store.insertPane(
                thirdPane.id,
                inTab: sourceTab.id,
                at: rightPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
        )
        let drawerChild = try #require(store.addDrawerPane(to: sourcePane.id))
        let drawerId = try #require(store.pane(sourcePane.id)?.drawer?.drawerId)
        store.tabArrangementAtom.addDrawerPaneView(
            drawerId: drawerId,
            parentPaneId: sourcePane.id,
            drawerPaneId: drawerChild.id,
            inTab: sourceTab.id
        )
        let updatedSourceTab = try #require(store.tabLayoutAtom.tab(sourceTab.id))
        #expect(!updatedSourceTab.activePaneIds.contains(drawerChild.id))
        #expect(updatedSourceTab.activeArrangement.drawerViews[drawerId]?.layout.paneIds == [drawerChild.id])
        store.appendTab(Tab(paneId: otherTabPane.id))
        store.appendTab(Tab(paneId: lastTabPane.id))
        store.setActiveTab(sourceTab.id)

        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: StructuralRuntimeSurfaceManager(),
            runtimeRegistry: RuntimeRegistry()
        )
        let runtime = FakePaneRuntime(paneId: PaneId(existingUUID: sourcePane.id))
        coordinator.registerRuntime(runtime)
        return GhosttyStructureRuntimeContext(
            tempDir: tempDir,
            store: store,
            coordinator: coordinator,
            runtime: runtime,
            sourcePaneId: sourcePane.id,
            sourceTabId: sourceTab.id,
            drawerChildId: drawerChild.id
        )
    }

    private func structuralEvents() -> [GhosttyEvent] {
        [
            .newTab,
            .newSplit(direction: .right),
            .gotoSplit(direction: .next),
            .resizeSplit(amount: 10, direction: .right),
            .equalizeSplits,
            .toggleSplitZoom,
            .closeTab(mode: .otherTabs),
            .closeTab(mode: .rightTabs),
            .gotoTab(target: .next),
            .gotoTab(target: .index(4)),
            .moveTab(amount: 1),
        ]
    }

    private func emit(
        _ event: GhosttyEvent,
        index: Int,
        through runtime: FakePaneRuntime,
        sourcePaneId: UUID,
        eventSourcePaneId: UUID? = nil,
        eventSequence: UInt64? = nil,
        barrierSequence: UInt64? = nil
    ) async -> [AppEvent] {
        let structuralSequence = eventSequence ?? UInt64(index * 2 + 1)
        let resolvedBarrierSequence = barrierSequence ?? structuralSequence + 1
        let eventSource = EventSource.pane(PaneId(existingUUID: eventSourcePaneId ?? sourcePaneId))
        let barrierSource = EventSource.pane(PaneId(existingUUID: sourcePaneId))
        let appEventStream = await AppEventBus.shared.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "GhosttyStructureRuntimeEventTests.barrier.\(index)"
        )

        // Consume the event stream independently while the MainActor coordinator publishes the barrier.
        // swiftlint:disable:next no_task_detached
        let bellWaiter = Task.detached { () -> [AppEvent] in
            var receivedEvents: [AppEvent] = []
            for await appEvent in appEventStream {
                receivedEvents.append(appEvent)
                if case .worktreeBellRang(let paneId) = appEvent, paneId == sourcePaneId {
                    return receivedEvents
                }
            }
            return receivedEvents
        }

        runtime.emit(
            makeRuntimeEnvelope(
                source: eventSource,
                paneKind: .terminal,
                seq: structuralSequence,
                commandId: nil,
                correlationId: nil,
                timestamp: ContinuousClock().now,
                epoch: 0,
                event: .terminal(event)
            )
        )
        runtime.emit(
            makeRuntimeEnvelope(
                source: barrierSource,
                paneKind: .terminal,
                seq: resolvedBarrierSequence,
                commandId: nil,
                correlationId: nil,
                timestamp: ContinuousClock().now,
                epoch: 0,
                event: .terminal(.bellRang)
            )
        )

        let receivedEvents = await bellWaiter.value
        #expect(
            receivedEvents.contains { event in
                if case .worktreeBellRang(let paneId) = event {
                    return paneId == sourcePaneId
                }
                return false
            },
            "Coordinator did not finish the event preceding the bell barrier"
        )
        return receivedEvents
    }
}

@MainActor
private struct GhosttyStructureRuntimeContext {
    let tempDir: URL
    let store: WorkspaceStore
    let coordinator: WorkspaceSurfaceCoordinator
    let runtime: FakePaneRuntime
    let sourcePaneId: UUID
    let sourceTabId: UUID
    let drawerChildId: UUID
}

@MainActor
private final class StructuralRuntimeCommandHandler: WorkspaceCommandHandling {
    private(set) var commands: [AppCommand] = []
    private(set) var targetedCommands: [AppCommand] = []

    func execute(_ command: AppCommand) {
        commands.append(command)
    }

    func execute(_ command: AppCommand, target: UUID, targetType: SearchItemType) {
        _ = target
        _ = targetType
        targetedCommands.append(command)
    }

    func canExecute(_ command: AppCommand) -> Bool {
        _ = command
        return true
    }

    func executeExtractPaneToTab(tabId: UUID, paneId: UUID, targetTabInsertionIndex: Int?) {
        _ = tabId
        _ = paneId
        _ = targetTabInsertionIndex
    }

    func executeMovePaneToTab(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID) {
        _ = sourcePaneId
        _ = sourceTabId
        _ = targetTabId
    }
}

@MainActor
private final class StructuralRuntimeSurfaceManager: WorkspaceSurfaceManaging {
    func syncFocus(activeSurfaceId: UUID?) {
        _ = activeSurfaceId
    }

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        _ = config
        _ = metadata
        return .failure(.ghosttyNotInitialized)
    }

    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        _ = surfaceId
        _ = paneId
        return nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        _ = surfaceId
        _ = reason
    }

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? {
        _ = paneId
        return nil
    }

    func destroy(_ surfaceId: UUID) {
        _ = surfaceId
    }

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {
        _ = paneIDs
    }

    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {
        _ = paneIDs
    }

    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {
        _ = paneIDs
    }
}
