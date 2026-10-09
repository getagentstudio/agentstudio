import AppKit
import Foundation
import GhosttyKit
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct MainWindowControllerPresentationFactsTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("real window delegate ingress publishes presentation facts under the supplied UUID")
    func realWindowDelegateIngressPublishesPresentationFactsUnderSuppliedUUID() async throws {
        await withPresentationFactsWindowHarness { harness in
            // Arrange
            #expect(harness.windowLifecycleStore.registeredWindowIds.contains(harness.windowId))
            #expect(harness.windowLifecycleStore.presentationFacts(for: UUID()) == nil)

            // Act — publish the real NSWindow properties through a real delegate callback.
            harness.window.orderFront(nil)
            harness.controller.windowDidChangeOcclusionState(
                Notification(
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: harness.window
                )
            )

            // Assert
            #expect(
                harness.windowLifecycleStore.presentationFacts(for: harness.windowId)
                    == presentationFacts(of: harness.window)
            )

            // Act — transition the actual NSWindow to hidden and publish again.
            harness.window.orderOut(nil)
            harness.controller.windowDidChangeOcclusionState(
                Notification(
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: harness.window
                )
            )

            // Assert
            #expect(harness.window.isVisible == false)
            #expect(
                harness.windowLifecycleStore.presentationFacts(for: harness.windowId)
                    == presentationFacts(of: harness.window)
            )

            // Act — close ingress is terminal presentation, independent of physical WKWebView visibility.
            harness.controller.windowWillClose(
                Notification(name: NSWindow.willCloseNotification, object: harness.window)
            )

            // Assert
            #expect(
                harness.windowLifecycleStore.presentationFacts(for: harness.windowId)
                    == WindowPresentationFacts(
                        isVisible: false,
                        isMiniaturized: harness.window.isMiniaturized,
                        isOccluded: true
                    )
            )
        }
    }

    @Test("window close stops held tab-bar work before its late completion")
    func windowCloseStopsHeldTabBarProjection() async throws {
        let projectionGate = PresentationFactsTabBarProjectionGate()
        defer { projectionGate.release() }
        let completionRecorder = PresentationFactsProjectionCompletionRecorder()

        try await withPresentationFactsWindowHarness(
            tabBarAdapterBuilder: { store, repoCache in
                let pane = store.createPane(title: "Held projection")
                store.appendTab(Tab(paneId: pane.id, name: "Held projection"))
                return TabBarAdapter(
                    store: store,
                    repoCache: repoCache,
                    project: projectionGate.project,
                    onProjectionCompletion: completionRecorder.record
                )
            },
            body: { harness in
                #expect(await projectionGate.waitUntilStarted(), "Held projection did not start")
                let retainedProjection = try #require(
                    harness.tabBarAdapter.materializedProjections.first
                )

                harness.controller.windowWillClose(
                    Notification(name: NSWindow.willCloseNotification, object: harness.window)
                )
                harness.controller.windowWillClose(
                    Notification(name: NSWindow.willCloseNotification, object: harness.window)
                )
                #expect(retainedProjection.freshness == .stopped)

                projectionGate.release()
                #expect(
                    await completionRecorder.wait(for: .cancelled(.init(value: 1))),
                    "Late held completion was not rejected after window shutdown"
                )
                #expect(retainedProjection.value == nil)
                #expect(retainedProjection.freshness == .stopped)
            }
        )
    }

    private func presentationFacts(of window: NSWindow) -> WindowPresentationFacts {
        WindowPresentationFacts(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isOccluded: !window.occlusionState.contains(.visible)
        )
    }
}

@MainActor
private struct PresentationFactsWindowHarness {
    let windowId: UUID
    let windowLifecycleStore: WindowLifecycleAtom
    let controller: MainWindowController
    let window: NSWindow
    let tabBarAdapter: TabBarAdapter
}

@MainActor
private func withPresentationFactsWindowHarness<T>(
    tabBarAdapterBuilder:
        @MainActor (
            _ store: WorkspaceStore,
            _ repoCache: RepoCacheAtom
        ) -> TabBarAdapter = { store, repoCache in
            TabBarAdapter(
                store: store,
                repoCache: repoCache
            )
        },
    body: @MainActor (PresentationFactsWindowHarness) async throws -> T
) async rethrows -> T {
    let atoms = makeTestAtomRegistry()
    let store = WorkspaceStore(
        identityAtom: atoms.core.workspaceIdentity,
        windowMemoryAtom: atoms.core.workspaceWindowMemory,
        repositoryTopologyAtom: atoms.core.workspaceRepositoryTopology,
        paneAtom: atoms.core.workspacePane,
        tabLayoutAtom: atoms.core.workspaceTabLayout,
        mutationCoordinator: atoms.core.workspaceMutationCoordinator
    )
    let viewRegistry = ViewRegistry()
    let appLifecycleStore = AppLifecycleAtom()
    let coordinator = WorkspaceSurfaceCoordinator(
        store: store,
        viewRegistry: viewRegistry,
        runtime: SessionRuntime(atom: atoms.core.sessionRuntime, store: store),
        surfaceManager: PresentationFactsWindowSurfaceManager(),
        terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
        terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
        runtimeRegistry: RuntimeRegistry(),
        windowLifecycleStore: atoms.core.windowLifecycle,
        appLifecycleStore: appLifecycleStore,
        ipcLifecycle: .testUnavailable,
        bridgePaneAttendance: atoms.bridgePaneAttendance
    )
    let applicationLifecycleMonitor = ApplicationLifecycleMonitor(
        appLifecycleStore: appLifecycleStore,
        windowLifecycleStore: atoms.core.windowLifecycle
    )
    let windowId = UUID()
    var controller: MainWindowController?

    let result = try await withAsyncTestCoreAtoms(using: atoms.core) { _ in
        let tabBarAdapter = tabBarAdapterBuilder(
            store,
            atoms.core.repoCache
        )
        let commandDispatcher = CommandDispatcherFixtureConfiguration().makeDispatcher()
        let windowController = MainWindowController(
            workspaceWindowId: windowId,
            store: store,
            octiconLoader: makeTestOcticonLoader(),
            workspaceActionExecutor: WorkspaceActionExecutor(
                coordinator: coordinator,
                store: store
            ),
            runtimeCommandDispatcher: coordinator,
            commandDispatcher: commandDispatcher,
            resolveCommandCapabilities: {
                commandDispatcher.repoExplorerCommandPresentationSnapshot(
                    requests: $0, generation: $1)
            },
            executionOwnerIdentities: commandDispatcher.executionOwnerIdentities, synchronizeRuntimeFocus: { _ in },
            applicationLifecycleMonitor: applicationLifecycleMonitor,
            appLifecycleStore: appLifecycleStore,
            tabBarAdapter: tabBarAdapter,
            viewRegistry: viewRegistry,
            bridgePaneAttendance: atoms.bridgePaneAttendance,
            editorChooser: atoms.editorChooser,
            repoExplorerSidebarPrefs: atoms.repoExplorerSidebarPrefs,
            bridgeAttendanceSnapshot: { paneId in
                atoms.bridgePaneAttendance.ordinal(for: paneId)
            }
        )
        controller = windowController
        windowController.showWindow(nil)
        let window = try #require(windowController.window)
        return try await body(
            PresentationFactsWindowHarness(
                windowId: windowId,
                windowLifecycleStore: atoms.core.windowLifecycle,
                controller: windowController,
                window: window,
                tabBarAdapter: tabBarAdapter
            )
        )
    }

    (controller?.window?.contentViewController as? MainSplitViewController)?.shutdown()
    controller?.close()
    await coordinator.shutdown()
    return result
}

private final class PresentationFactsTabBarProjectionGate: Sendable {
    private let started = TabBarAdapterTestSignal()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let didRelease = Mutex(false)

    func hold() throws(CancellationError) {
        started.signal()
        guard releaseSemaphore.wait(timeout: .now() + .seconds(5)) == .success else {
            throw CancellationError()
        }
    }

    func project(
        _ request: TabBarProjectionRequest
    ) throws(CancellationError) -> TabBarProjection {
        try hold()
        return try TabBarProjector.project(request)
    }

    func waitUntilStarted() async -> Bool {
        await started.wait()
    }

    func release() {
        let shouldRelease = didRelease.withLock { didRelease in
            guard !didRelease else { return false }
            didRelease = true
            return true
        }
        if shouldRelease {
            releaseSemaphore.signal()
        }
    }
}

@MainActor
private final class PresentationFactsProjectionCompletionRecorder {
    private var completions: [TabBarMaterializedProjection.ProjectionCompletion] = []
    private var waiters:
        [(
            completion: TabBarMaterializedProjection.ProjectionCompletion,
            signal: TabBarAdapterTestSignal
        )] = []

    func record(_ completion: TabBarMaterializedProjection.ProjectionCompletion) {
        completions.append(completion)
        for waiter in waiters where waiter.completion == completion {
            waiter.signal.signal()
        }
    }

    func wait(
        for completion: TabBarMaterializedProjection.ProjectionCompletion
    ) async -> Bool {
        if completions.contains(completion) {
            return true
        }
        let signal = TabBarAdapterTestSignal()
        waiters.append((completion: completion, signal: signal))
        return await signal.wait()
    }
}

@MainActor
private final class PresentationFactsWindowSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func syncFocus(activeSurfaceId: UUID?) {}

    func createSurface(
        config: Ghostty.SurfaceConfiguration,
        metadata: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.ghosttyNotInitialized)
    }

    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {}
}
