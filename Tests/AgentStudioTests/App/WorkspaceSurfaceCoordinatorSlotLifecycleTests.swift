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

@MainActor
@Suite(.serialized)
struct WorkspaceSurfaceCoordinatorSlotLifecycleTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    private struct Harness {
        let store: WorkspaceStore
        let viewRegistry: ViewRegistry
        let coordinator: WorkspaceSurfaceCoordinator
        let tempDir: URL
    }

    private func makeHarness() throws -> Harness {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-slot-lifecycle-\(UUID().uuidString)")
        let store = try makeWorkspaceJournalTestStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: SlotLifecycleSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        return Harness(store: store, viewRegistry: viewRegistry, coordinator: coordinator, tempDir: tempDir)
    }

    private func withSlotLifecycleHarness(_ operation: @MainActor (Harness) async throws -> Void) async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        do {
            try await operation(harness)
        } catch {
            await harness.coordinator.shutdown()
            throw error
        }
        await harness.coordinator.shutdown()
    }

    private func makeWebviewPane(_ store: WorkspaceStore, title: String) -> Pane {
        let url = URL(string: "https://example.com/\(UUID().uuidString)")!
        return store.createPane(
            content: .webview(WebviewState(url: url, showNavigation: true)),
            metadata: PaneMetadata(title: title)
        )
    }

    @Test("close then undo promotes the same retired slot in the coordinator path")
    func closePaneThenUndo_promotesRetiredSlotInPlace() async throws {
        try await withSlotLifecycleHarness { harness in
            let closingPane = makeWebviewPane(harness.store, title: "Closing")
            let siblingPane = makeWebviewPane(harness.store, title: "Sibling")
            let tab = Tab(paneId: closingPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.insertPane(
                siblingPane.id,
                inTab: tab.id,
                at: closingPane.id,
                direction: .horizontal,
                position: .after,
                sizingMode: .halveTarget
            )
            let originalSlot = harness.viewRegistry.ensureSlot(for: closingPane.id)
            harness.viewRegistry.surfaceRenderedIds("tab:\(tab.id)", ids: [closingPane.id, siblingPane.id])

            try await harness.coordinator.execute(.closePane(tabId: tab.id, paneId: closingPane.id))

            #expect(harness.viewRegistry.isRetiredForTesting(closingPane.id))
            #expect(harness.viewRegistry.peekSlotForTesting(closingPane.id) === originalSlot)

            try await harness.coordinator.undoCloseTab()

            #expect(harness.store.pane(closingPane.id) != nil)
            #expect(!harness.viewRegistry.isRetiredForTesting(closingPane.id))
            #expect(harness.viewRegistry.peekSlotForTesting(closingPane.id) === originalSlot)
            #expect(harness.viewRegistry.view(for: closingPane.id) != nil)
        }
    }

    @Test("registering a replacement releases the exact prior host cycle")
    func registeringReplacementReleasesExactPriorHostCycle() async throws {
        try await withSlotLifecycleHarness { harness in
            let paneID = UUIDv7.generate()
            let weakPriorHost = WeakPaneHostReference()

            let replacementHost = autoreleasepool {
                var priorHost: PaneHostView? = harness.coordinator.registerHostedView(
                    mountedView: SlotLifecycleMountedContentView(),
                    for: paneID
                )
                _ = priorHost?.swiftUIContainer
                weakPriorHost.value = priorHost
                let replacementHost = harness.coordinator.registerHostedView(
                    mountedView: SlotLifecycleMountedContentView(),
                    for: paneID
                )
                #expect(priorHost?.superview == nil)
                priorHost = nil
                return replacementHost
            }

            #expect(weakPriorHost.value == nil)
            #expect(harness.viewRegistry.view(for: paneID) === replacementHost)
        }
    }

    @Test("unregistering releases the exact current host cycle but preserves the slot")
    func unregisteringReleasesExactCurrentHostCycleButPreservesSlot() async throws {
        try await withSlotLifecycleHarness { harness in
            let paneID = UUIDv7.generate()
            let slot = harness.viewRegistry.ensureSlot(for: paneID)
            let weakHost = WeakPaneHostReference()

            autoreleasepool {
                var host: PaneHostView? = harness.coordinator.registerHostedView(
                    mountedView: SlotLifecycleMountedContentView(),
                    for: paneID
                )
                _ = host?.swiftUIContainer
                weakHost.value = host
                harness.coordinator.unregisterHostedView(for: paneID)
                #expect(host?.superview == nil)
                host = nil
            }

            #expect(weakHost.value == nil)
            #expect(harness.viewRegistry.peekSlotForTesting(paneID) === slot)
            #expect(harness.viewRegistry.view(for: paneID) == nil)
        }
    }

    @Test("unregistering permanently unmounts content even while SwiftUI retains the old host")
    func unregisteringUnmountsContentFromRetainedHost() async throws {
        try await withSlotLifecycleHarness { harness in
            let paneID = UUIDv7.generate()
            weak var weakContent: SlotLifecycleMountedContentView?
            let retainedHost = autoreleasepool {
                let content = SlotLifecycleMountedContentView()
                weakContent = content
                let host = harness.coordinator.registerHostedView(mountedView: content, for: paneID)
                harness.coordinator.unregisterHostedView(for: paneID)
                return host
            }

            #expect(retainedHost.mountedContentViewForTesting == nil)
            #expect(weakContent == nil)
            #expect(harness.viewRegistry.view(for: paneID) == nil)
        }
    }

    @Test("unregistering asks mounted content to retire before unmount")
    func unregisteringAsksMountedContentToRetireBeforeUnmount() async throws {
        try await withSlotLifecycleHarness { harness in
            let paneID = UUIDv7.generate()
            let content = SlotLifecycleRetirementRecordingContentView()

            _ = harness.coordinator.registerHostedView(mountedView: content, for: paneID)
            harness.coordinator.unregisterHostedView(for: paneID)

            #expect(content.retireCallCount == 1)
            #expect(content.wasMountedWhenRetired)
        }
    }

    @Test("temporary transitions keep the host and mounted content intact")
    func temporaryTransitionsKeepHostAndMountedContent() async throws {
        try await withSlotLifecycleHarness { harness in
            let pane = makeWebviewPane(harness.store, title: "Minimizable")
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)

            let content = SlotLifecycleMountedContentView()
            let host = harness.coordinator.registerHostedView(mountedView: content, for: pane.id)

            try await harness.coordinator.execute(.minimizePane(tabId: tab.id, paneId: pane.id))

            #expect(harness.viewRegistry.view(for: pane.id) === host)
            #expect(host.mountedContentViewForTesting != nil)
        }
    }

    @Test("closing two drawer panes in sequence keeps fallback focus and both tombstones stable")
    func closingTwoDrawerPanesInSequence_preservesFallbackFocusAndRetiredSlots() async throws {
        try await withSlotLifecycleHarness { harness in
            let parent = makeWebviewPane(harness.store, title: "Parent")
            let tab = Tab(paneId: parent.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let first = try #require(
                harness.store.addDrawerPane(
                    to: parent.id,
                    parentFallbackCWD: FileManager.default.homeDirectoryForCurrentUser
                )
            )
            let second = try #require(
                harness.store.addDrawerPane(
                    to: parent.id,
                    parentFallbackCWD: FileManager.default.homeDirectoryForCurrentUser
                )
            )
            let third = try #require(
                harness.store.addDrawerPane(
                    to: parent.id,
                    parentFallbackCWD: FileManager.default.homeDirectoryForCurrentUser
                )
            )
            harness.store.setActiveDrawerPane(second.id, in: parent.id)
            let firstSlot = harness.viewRegistry.ensureSlot(for: first.id)
            let secondSlot = harness.viewRegistry.ensureSlot(for: second.id)
            harness.viewRegistry.surfaceRenderedIds("drawer:\(parent.id)", ids: [first.id, second.id, third.id])

            try await harness.coordinator.execute(.removeDrawerPane(parentPaneId: parent.id, drawerPaneId: second.id))
            try await harness.coordinator.execute(.removeDrawerPane(parentPaneId: parent.id, drawerPaneId: first.id))

            let drawer = try #require(harness.store.pane(parent.id)?.drawer)
            #expect(drawer.paneIds == [third.id])
            #expect(harness.store.drawerView(forParent: parent.id)?.activeChildId == third.id)
            #expect(harness.viewRegistry.isRetiredForTesting(first.id))
            #expect(harness.viewRegistry.isRetiredForTesting(second.id))
            #expect(harness.viewRegistry.peekSlotForTesting(first.id) === firstSlot)
            #expect(harness.viewRegistry.peekSlotForTesting(second.id) === secondSlot)
        }
    }

    @Test("closing the last drawer pane then creating a new one does not keep the old slot alive")
    func closeLastDrawerPaneThenCreateNewDrawerPane_cleansOldSlotAndCreatesNewSlot() async throws {
        try await withSlotLifecycleHarness { harness in
            let parent = makeWebviewPane(harness.store, title: "Parent")
            let tab = Tab(paneId: parent.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            let closedChild = try #require(
                harness.store.addDrawerPane(
                    to: parent.id,
                    parentFallbackCWD: FileManager.default.homeDirectoryForCurrentUser
                )
            )
            let oldSlot = harness.viewRegistry.ensureSlot(for: closedChild.id)

            try await harness.coordinator.execute(.closePane(tabId: tab.id, paneId: closedChild.id))

            #expect(harness.store.pane(parent.id)?.drawer?.paneIds.isEmpty == true)
            #expect(!harness.viewRegistry.isRetiredForTesting(closedChild.id))
            #expect(harness.viewRegistry.peekSlotForTesting(closedChild.id) == nil)

            try await harness.coordinator.execute(.addDrawerPane(parentPaneId: parent.id))

            let drawer = try #require(harness.store.pane(parent.id)?.drawer)
            let newChildId = try #require(harness.store.drawerView(forParent: parent.id)?.activeChildId)
            #expect(drawer.paneIds == [newChildId])
            #expect(newChildId != closedChild.id)
            #expect(harness.viewRegistry.peekSlotForTesting(newChildId) != nil)
            #expect(harness.viewRegistry.peekSlotForTesting(closedChild.id) !== oldSlot)
        }
    }
}

@MainActor
private final class SlotLifecycleMountedContentView: NSView, PaneMountedContent {
    func setContentInteractionEnabled(_: Bool) {}
}

@MainActor
private final class SlotLifecycleRetirementRecordingContentView: NSView, PaneMountedContent {
    private(set) var retireCallCount = 0
    private(set) var wasMountedWhenRetired = false

    func setContentInteractionEnabled(_: Bool) {}

    func paneHostWillRetire() {
        retireCallCount += 1
        wasMountedWhenRetired = superview != nil
    }
}

@MainActor
private final class WeakPaneHostReference {
    weak var value: PaneHostView?
}

@MainActor
private final class SlotLifecycleSurfaceManager: WorkspaceSurfaceManaging {
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

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {}

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {}
}
