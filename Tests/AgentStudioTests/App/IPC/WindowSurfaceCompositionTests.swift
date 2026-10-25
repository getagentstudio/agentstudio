import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioTestSupport

enum WindowSurfaceComposition: CaseIterable, Sendable {
    case sideBySide, drawer, zoomTerminal, zoomBridge
}

@MainActor
@Suite("Real pane composition crop identity", .serialized)
struct WindowSurfaceCompositionTests {
    @Test(
        "side-by-side, drawer and Zoom preserve repeated controls and actual marker regions",
        arguments: WindowSurfaceComposition.allCases)
    func windowSurfacesIdentifyRealPaneCompositions(composition: WindowSurfaceComposition) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = try PaneSurfaceCaptureFixture(atoms: atoms, composition: composition)
            defer { fixture.stop() }
            let identityCardLabels = try await fixture.awaitIdentityCardLabels()
            #expect(identityCardLabels.contains("Capture source"))
            #expect(identityCardLabels.contains("Capture adjacent"))
            let result = try await fixture.render()
            let surfaces = result.surfaces

            for paneId in fixture.visibleLeafIds {
                let matchingLeaf = surfaces.first { $0.kind == .paneLeaf && $0.paneId == paneId }
                let leaf = try #require(matchingLeaf)
                #expect(leaf.frame.width > 0 && leaf.frame.height > 0)
            }
            let toolbarIds = Set(surfaces.filter { $0.kind == .paneToolbar }.compactMap(\.paneId))
            #expect(toolbarIds == [fixture.sourceId, fixture.adjacentId])
            let copies = surfaces.filter {
                $0.kind == .toolbarControl && $0.identifier == "paneSurfaceToolbar.copyPath"
            }
            #expect(copies.count == 2)
            #expect(Set(copies.compactMap(\.paneId)) == [fixture.sourceId, fixture.adjacentId])
            #expect(surfaces.filter { $0.kind == .toolbarControl }.allSatisfy { $0.paneId != nil })
            let matchingCard = surfaces.first { $0.kind == .paneCard && $0.paneId == fixture.sourceId }
            let matchingToolbar = surfaces.first { $0.kind == .paneToolbar && $0.paneId == fixture.sourceId }
            let card = try #require(matchingCard)
            let sourceToolbar = try #require(matchingToolbar)
            #expect(card.frame.y + card.frame.height <= sourceToolbar.frame.y)
            #expect(
                Set(surfaces.filter { $0.kind == .paneCard }.compactMap(\.paneId)) == [
                    fixture.sourceId, fixture.adjacentId,
                ])
            let markerViews = fixture.markers()
            let nativeCard = try #require(
                markerViews.first { $0.regionKind == "paneCard" && $0.regionID == fixture.sourceId.uuidString })
            let identityFrames = fixture.identityFrames()
            #expect(identityFrames.contains(nativeCard.convert(nativeCard.bounds, to: fixture.host)))

            // Freeze both captures without suspension: the PNG write awaits may advance unrelated UI work.
            let beforeFrames = markerViews.map { $0.convert($0.bounds, to: fixture.host) }
            let beforeImage = try fixture.captureImage()
            for marker in markerViews { marker.isHidden = true }
            let afterImage = try fixture.captureImage()
            let withoutMarkers = WindowRenderSurfaceCollector.collect(
                window: fixture.filesystem.window, contentView: fixture.host)
            #expect(beforeFrames == markerViews.map { $0.convert($0.bounds, to: fixture.host) })
            let beforePath = try await WindowContentRenderer.writePNG(
                image: beforeImage, directory: fixture.filesystem.rendersDirectory, renderId: UUIDv7.generate())
            let afterPath = try await WindowContentRenderer.writePNG(
                image: afterImage, directory: fixture.filesystem.rendersDirectory, renderId: UUIDv7.generate())
            let before = try decodedWindowRenderBitmap(path: beforePath.path)
            let after = try decodedWindowRenderBitmap(path: afterPath.path)
            #expect(before.bytesPerRow == after.bytesPerRow && before.pixelsHigh == after.pixelsHigh)
            let length = before.bytesPerRow * before.pixelsHigh
            #expect(
                Data(bytes: try #require(before.bitmapData), count: length)
                    == Data(bytes: try #require(after.bitmapData), count: length))
            #expect(!withoutMarkers.contains { [.paneLeaf, .paneToolbar, .paneCard].contains($0.kind) })
        }
    }
}

@MainActor
private final class PaneSurfaceCaptureFixture {
    let filesystem: WindowRenderTestFixture
    let store: WorkspaceStore
    let registry = ViewRegistry()
    let sourceId: UUID
    let adjacentId: UUID
    let companionId: UUID
    let childId: UUID?
    let tabId: UUID
    let composition: WindowSurfaceComposition
    let host: NSHostingView<AnyView>
    private var initialRelativeTimeInputs: [UUID: PaneManagementIdentityCapture.VisibleInput] = [:]
    private let relativeTimeFacts = FactRecorder<UUID, PaneRelativeTimeRefresh.Event>(
        vocabulary: .init(
            describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
            isClosing: { _, event in
                switch event {
                case .ended, .hidden: true
                case .operation, .entered: false
                }
            }))
    let editorChooser = EditorChooserState()
    let closeCoordinator = PaneCloseTransitionCoordinator()
    let cache = RepoCacheAtom()
    let dispatcher = PaneTabActionDispatcher(
        dispatch: { _ in }, shouldHandleSplitDragPayload: { _ in false }, shouldAcceptDrop: { _, _, _, _ in false },
        handleDrop: { _, _, _, _ in })

    var visibleLeafIds: Set<UUID> {
        var ids: Set<UUID> = [sourceId, adjacentId]
        if composition == .zoomTerminal || composition == .zoomBridge { ids.insert(companionId) }
        if let childId { ids.insert(childId) }
        return ids
    }

    init(atoms: CoreAtoms, composition: WindowSurfaceComposition) throws {
        filesystem = try WindowRenderTestFixture()
        self.composition = composition
        store = WorkspaceStore(
            identityAtom: atoms.workspaceIdentity, windowMemoryAtom: atoms.workspaceWindowMemory,
            repositoryTopologyAtom: atoms.workspaceRepositoryTopology, paneAtom: atoms.workspacePane,
            tabLayoutAtom: atoms.workspaceTabLayout, mutationCoordinator: atoms.workspaceMutationCoordinator,
            startsObserving: false)
        sourceId = store.createPane(launchDirectory: URL(filePath: "/tmp/capture-source"), title: "Capture source").id
        adjacentId =
            store.createPane(launchDirectory: URL(filePath: "/tmp/capture-adjacent"), title: "Capture adjacent").id
        companionId = store.createPane().id
        let tab = Tab(paneId: sourceId)
        tabId = tab.id
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        if composition == .sideBySide {
            childId = nil
        } else {
            childId = try #require(store.addDrawerPane(to: sourceId)).id
            store.paneAtom.setDrawerZoomSide(composition == .zoomBridge ? .bridge : .terminal, forOwner: sourceId)
        }
        for paneId in [sourceId, adjacentId, companionId] + (childId.map { [$0] } ?? []) {
            registry.register(PaneHostView(paneId: paneId), for: paneId)
        }
        host = NSHostingView(rootView: AnyView(EmptyView()))
        atoms.managementLayer.activate()
        host.rootView = AnyView(
            content().frame(width: 1600, height: 640).environment(\.colorScheme, .dark).transaction {
                $0.disablesAnimations = true
                $0.animation = nil
            })
        filesystem.window.contentView = host
        filesystem.window.setContentSize(NSSize(width: 1600, height: 640))
        host.layoutSubtreeIfNeeded()
    }

    func render() async throws -> IPCWindowRenderResult {
        try await WindowContentRenderer.render(
            window: filesystem.window, workspaceWindowId: filesystem.windowId,
            rendersDirectory: filesystem.rendersDirectory)
    }

    func captureImage() throws -> CGImage {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.cgImage)
    }

    func awaitIdentityCardLabels() async throws -> [String] {
        do {
            for paneId in [sourceId, adjacentId] {
                let input = try #require(initialRelativeTimeInputs[paneId], "Mounted card must start its owner")
                // These inputs finish after the first publication instead of scheduling a future refresh.
                try #require(input.activityTime == nil && input.agentLine == nil, "Fixture must have no deadline")
                try await relativeTimeFacts.expectNext(in: paneId, .operation(input, .started))
                try await relativeTimeFacts.expectNext(in: paneId, .entered(input))
                try await relativeTimeFacts.expectNext(in: paneId, .ended(input, .completed))
            }
            try await relativeTimeFacts.finish()
        } catch {
            try? await relativeTimeFacts.finish()
            throw error
        }
        // Publication precedes the native layout that establishes the capture baseline.
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return PaneIdentityCardFixture.elements(in: host).map(\.label)
    }

    private func observeRelativeTime(_ event: PaneRelativeTimeRefresh.Event, paneId: UUID) {
        if case .operation(let input, .started) = event { initialRelativeTimeInputs[paneId] = input }
        relativeTimeFacts.append(scope: paneId, fact: event)
    }

    func stop() {
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        atom(\.managementLayer).deactivate()
        filesystem.window.contentView = nil
        filesystem.tearDown()
    }

    private func content() -> some View {
        HStack(spacing: 0) {
            if composition == .zoomTerminal || composition == .zoomBridge {
                ZoomPresentationContainer(
                    tabId: tabId, sourcePaneId: sourceId, sourceOrdinal: 1,
                    sourceContent: AnyView(leaf(sourceId, hiddenToolbar: true)),
                    companionContent: AnyView(leaf(companionId, hiddenToolbar: true)),
                    parentToolbarPresentation: toolbar(), splitRatio: 0.7, store: store,
                    octiconLoader: makeTestOcticonLoader(), editorChooser: editorChooser,
                    actionDispatcher: dispatcher, commandDispatcher: AppTerminalFixtureCommandDispatcher(),
                    arrangementInlineRenameState: ArrangementInlineRenameState(), onPaneFocusTrigger: { _ in },
                    viewRegistry: registry, surfaceId: "capture-zoom", renderedPaneIds: [sourceId, companionId],
                    onRelativeTimeEvent: { [weak self] event in
                        guard let self else { return }
                        self.observeRelativeTime(event, paneId: self.sourceId)
                    }
                )
                .frame(width: 1100)
            } else {
                ZStack {
                    leaf(sourceId)
                    if composition == .drawer { drawerOverlay() }
                }.frame(width: 1100).coordinateSpace(name: "tabContainer")
            }
            leaf(adjacentId).frame(width: 500)
        }
    }

    private func leaf(_ paneId: UUID, hiddenToolbar: Bool = false) -> some View {
        PaneLeafContainer(
            paneHost: registry.view(for: paneId)!, octiconLoader: makeTestOcticonLoader(), tabId: tabId,
            isActive: paneId == sourceId, isSplit: true, isSplitResizing: false, store: store, repoCache: cache,
            editorChooser: editorChooser, closeTransitionCoordinator: closeCoordinator, actionDispatcher: dispatcher,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(), onPaneFocusTrigger: { _ in },
            onOpenPaneGitHub: { _ in },
            toolbarPresentation: hiddenToolbar ? .hidden : toolbar(),
            managementChromePresentation: hiddenToolbar ? .zoomChild : .ordinary,
            onRelativeTimeEvent: { [weak self] event in self?.observeRelativeTime(event, paneId: paneId) })
    }

    private func drawerOverlay() -> some View {
        DrawerPanelOverlay(
            store: store, octiconLoader: makeTestOcticonLoader(), repoCache: cache, editorChooser: editorChooser,
            viewRegistry: registry, appLifecycleStore: AppLifecycleAtom(), closeTransitionCoordinator: closeCoordinator,
            tabId: tabId, presentation: .normal,
            paneFrames: [sourceId: CGRect(x: 0, y: 0, width: 1100, height: 600)],
            tabSize: CGSize(width: 1100, height: 640),
            iconBarFrame: CGRect(x: 0, y: 600, width: 1100, height: 40), actionDispatcher: dispatcher,
            commandDispatcher: AppTerminalFixtureCommandDispatcher(),
            arrangementInlineRenameState: ArrangementInlineRenameState(),
            onPaneFocusTrigger: { _ in }, onFocusPane: { _ in }, paneInboxPresentation: nil, onOpenPaneGitHub: { _ in },
            drawerDropTarget: nil, dismissCoordinateView: nil, workspaceWindowId: nil, dragSourcePaneId: nil)
    }

    private func toolbar() -> PaneSurfaceToolbarPresentation {
        .zoom(.init(viewerAction: nil, zoomAction: nil))
    }

    func markers() -> [CaptureRegionMarkerView] {
        func walk(_ view: NSView) -> [CaptureRegionMarkerView] {
            (view as? CaptureRegionMarkerView).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return walk(host)
    }

    func identityFrames() -> [CGRect] {
        func walk(_ view: NSView) -> [CGRect] {
            if view.identifier?.rawValue == "paneManagement.identityStrip" {
                return [view.convert(view.bounds, to: host)]
            }
            return view.subviews.flatMap(walk)
        }
        return walk(host)
    }
}
