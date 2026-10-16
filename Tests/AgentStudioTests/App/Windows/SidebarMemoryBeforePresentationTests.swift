import AgentStudioInfrastructure
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

@MainActor
@Suite("Sidebar memory before presentation", .serialized)
struct SidebarMemoryBeforePresentationTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("saved collapsed Panes sidebar is collapsed at first window construction")
    func collapsedPanesMemoryPrecedesWindowConstruction() async throws {
        try await restoreIntoWindow(sidebarCollapsed: true)
    }

    @Test("saved open Panes sidebar draws only matching panes with bound visible cells")
    func openPanesMemoryBuildsFilteredBoundRows() async throws {
        try await restoreIntoWindow(sidebarCollapsed: false)
    }

    private func restoreIntoWindow(sidebarCollapsed: Bool) async throws {
        let observation = SidebarLaunchObservation()
        var sidebarDependencies: SidebarRootViewDependencies?
        try await withUnloadedMainSplitViewControllerHarness(
            startsObserving: false,
            configureSidebarDependencies: { sidebarDependencies = $0 },
            sidebarRootViewBuilder: { _, _ in
                guard let dependencies = sidebarDependencies else {
                    preconditionFailure("The split view must supply its sidebar dependencies")
                }
                return AnyView(SidebarLaunchObservedHost(dependencies: dependencies, observation: observation))
            },
            body: { harness in
                let datastore = WorkspaceSQLiteDatastoreFactory(
                    coreDatabaseURL: harness.tempDir.appending(path: "core.sqlite"),
                    localDatabaseURL: harness.tempDir.appending(path: "local.sqlite")
                ).makeDatastore()
                let workspaceID = harness.store.identityAtom.workspaceId
                let sidebarState = harness.atoms.core.workspaceSidebarState
                let uiStore = UIStateStore(atom: sidebarState, sqliteDatastore: datastore)
                let matchingPane = harness.store.createPane(title: "Matching pane")
                let excludedPane = harness.store.createPane(title: "unrelated")
                harness.store.appendTab(makeTab(paneIds: [matchingPane.id, excludedPane.id], name: "Launch fixture"))
                guard case .prepared = await datastore.prepareDatabasesForBoot() else {
                    Issue.record("The launch fixture's real SQLite databases must prepare")
                    return
                }
                try await datastore.saveUIState(
                    .init(
                        filterText: "pane 1",
                        isFilterVisible: true,
                        sidebarCollapsed: sidebarCollapsed,
                        sidebarSurface: .panes
                    ),
                    workspaceContextId: workspaceID
                )

                // Keep the production list as the order authority. The other boot
                // services are outside this seam; UI restoration and the window are real.
                // Raw values let the regression test compile against the pre-fix enum.
                await WorkspaceBootSequence.runPresentationPrerequisitesAsync { step in
                    if step.rawValue == "loadSidebarMemory" || step.rawValue == "loadUIStore" {
                        await uiStore.restoreAsync(for: workspaceID)
                    }
                }

                harness.window.isReleasedWhenClosed = false
                defer {
                    observation.finish()
                    harness.window.contentViewController = nil
                    harness.window.close()
                }
                harness.window.contentViewController = harness.controller
                _ = harness.controller.view

                // Fixture 1's RED must be this user-visible mismatch, before any
                // post-presentation restore, projection wait, or sidebar interaction.
                #expect(harness.controller.isSidebarCollapsed == sidebarCollapsed)
                guard harness.controller.isSidebarCollapsed == sidebarCollapsed else { return }
                #expect(sidebarState.sidebarCollapsed == sidebarCollapsed)
                #expect(sidebarState.sidebarSurface == .panes)
                #expect(sidebarState.filterText == "pane 1")
                #expect(!uiStore.isAutosaveObservationActive)

                harness.controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
                harness.controller.splitView.frame = harness.controller.view.bounds
                harness.window.makeKeyAndOrderFront(nil)
                harness.window.layoutIfNeeded()
                harness.controller.view.layoutSubtreeIfNeeded()

                let presentation = try await observation.presentation(
                    query: "pane 1", isDemanded: !sidebarCollapsed
                )
                #expect(presentation.filterText == "pane 1")
                #expect(presentation.isDemanded == !sidebarCollapsed)
                #expect(harness.controller.isSidebarCollapsed == sidebarState.sidebarCollapsed)
                if sidebarCollapsed {
                    #expect(presentation.listedRowIDs.isEmpty)
                    #expect(presentation.visibleRowIDs.isEmpty)
                    #expect(presentation.boundRowIDs.isEmpty)
                } else {
                    #expect(paneIDs(in: presentation.listedRowIDs) == [matchingPane.id])
                    #expect(!paneIDs(in: presentation.listedRowIDs).contains(excludedPane.id))
                    #expect(!presentation.visibleRowIDs.isEmpty)
                    #expect(presentation.boundRowIDs == presentation.visibleRowIDs)
                    #expect(paneIDs(in: presentation.boundRowIDs) == [matchingPane.id])
                }
            }
        )
    }

    private func paneIDs(in rowIDs: [RepoExplorerRowID]) -> [UUID] {
        rowIDs.compactMap { rowID in
            if case .tabPane(_, let paneID) = rowID { return paneID }
            return nil
        }
    }
}

private struct SidebarLaunchPresentation: Sendable {
    let filterText: String
    let isDemanded: Bool
    let projectionQuery: String?
    let listedRowIDs: [RepoExplorerRowID]
    let visibleRowIDs: [RepoExplorerRowID]
    let boundRowIDs: [RepoExplorerRowID]
}

/// Observes native layout and the existing projection completion readback.
/// A suspended host plus the copied filter closes the collapsed case, which
/// deliberately never starts a projection and therefore has no projection fact.
@MainActor
private final class SidebarLaunchObservation {
    private let events = AsyncStream<SidebarLaunchPresentation>.makeStream(bufferingPolicy: .unbounded)
    weak var hostingView: SidebarLaunchHostingView?
    var latestProof: RepoExplorerPerformanceProofReadback?

    func capture() {
        guard let hostingView,
            let host = firstSidebarLaunchDescendant(RepoExplorerMaterializationHost.self, in: hostingView),
            let field = firstSidebarLaunchDescendant(NSTextField.self, in: hostingView)
        else { return }
        let table = firstSidebarLaunchDescendant(NSTableView.self, in: host)
        let materializer = table?.dataSource as? RepoExplorerTableMaterializer
        let listedRows = materializer?.snapshot?.rows.map(\.id) ?? []
        var visibleRows: [RepoExplorerRowID] = []
        var boundRows: [RepoExplorerRowID] = []
        if let table, let snapshot = materializer?.snapshot, host.isPresentationReady {
            // The table binds row cells during its own layout; run it synchronously so the
            // read observes what a display pass would draw, without waiting.
            table.layoutSubtreeIfNeeded()
            let range = table.rows(in: table.enclosingScrollView?.documentVisibleRect ?? table.bounds)
            if range.location != NSNotFound {
                for index in range.location..<min(NSMaxRange(range), snapshot.rows.count) {
                    visibleRows.append(snapshot.rows[index].id)
                    let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? RepoExplorerTableRowCell
                    if let identity = cell?.currentBindingIdentity { boundRows.append(identity.rowID) }
                }
            }
        }
        events.continuation.yield(
            SidebarLaunchPresentation(
                filterText: field.stringValue,
                isDemanded: latestProof?.isDemanded ?? host.isPresentationReady,
                projectionQuery: latestProof?.query,
                listedRowIDs: listedRows,
                visibleRowIDs: visibleRows,
                boundRowIDs: boundRows
            )
        )
    }

    func presentation(query: String, isDemanded: Bool) async throws -> SidebarLaunchPresentation {
        capture()
        for await event in events.stream {
            guard event.filterText == query, event.isDemanded == isDemanded else { continue }
            if !isDemanded || event.projectionQuery == query { return event }
        }
        throw CancellationError()
    }

    func finish() {
        events.continuation.finish()
        hostingView?.rootView = AnyView(EmptyView())
        hostingView?.layoutSubtreeIfNeeded()
    }
}

@MainActor
private struct SidebarLaunchObservedHost: NSViewRepresentable {
    let dependencies: SidebarRootViewDependencies
    let observation: SidebarLaunchObservation

    func makeNSView(context: Context) -> SidebarLaunchHostingView {
        let host = SidebarSurfaceHost(
            commandDispatcher: dependencies.commandDispatcher,
            resolveCommandCapabilities: dependencies.resolveCommandCapabilities,
            executionOwnerIdentities: dependencies.executionOwnerIdentities,
            store: dependencies.store,
            octiconLoader: dependencies.octiconLoader,
            paneActivityStatusAtom: dependencies.paneActivityStatusAtom,
            paneContextReaders: dependencies.paneContextReaders,
            applicationLifecycleMonitor: dependencies.applicationLifecycleMonitor,
            sidebarTimeInvalidationConsumerID: dependencies.sidebarTimeInvalidationConsumerID,
            sidebarState: dependencies.sidebarState,
            repoExplorerSidebarPrefs: dependencies.repoExplorerSidebarPrefs,
            bridgeAttendanceSnapshot: dependencies.bridgeAttendanceSnapshot,
            performanceTraceRecorder: dependencies.performanceTraceRecorder,
            onRefocusActivePane: dependencies.onRefocusActivePane,
            onSelectedPaneTargetChange: dependencies.onSelectedPaneTargetChange,
            onPreviewEligibilityLoss: dependencies.onPreviewEligibilityLoss,
            onPreviewCommit: dependencies.onPreviewCommit,
            onSidebarVisibleWorktreesChanged: dependencies.onSidebarVisibleWorktreesChanged,
            onPerformanceProofReadback: { proof in
                observation.latestProof = proof
                observation.capture()
            },
            onRepositoryFactUpdateProgressPresented: dependencies.onRepositoryFactUpdateProgressPresented
        )
        let hostingView = SidebarLaunchHostingView(rootView: AnyView(host))
        hostingView.onLayout = { observation.capture() }
        observation.hostingView = hostingView
        return hostingView
    }

    func updateNSView(_ nsView: SidebarLaunchHostingView, context: Context) {}

    static func dismantleNSView(_ nsView: SidebarLaunchHostingView, coordinator: ()) {
        MainActor.assumeIsolated {
            nsView.onLayout = nil
            nsView.rootView = AnyView(EmptyView())
        }
    }
}

@MainActor
private final class SidebarLaunchHostingView: NSHostingView<AnyView> {
    var onLayout: (@MainActor () -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
private func firstSidebarLaunchDescendant<Descendant: NSView>(
    _ type: Descendant.Type, in view: NSView
) -> Descendant? {
    if let descendant = view as? Descendant { return descendant }
    for subview in view.subviews {
        if let descendant = firstSidebarLaunchDescendant(type, in: subview) { return descendant }
    }
    return nil
}
