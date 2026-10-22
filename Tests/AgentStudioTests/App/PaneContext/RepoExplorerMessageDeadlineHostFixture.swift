import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer

@MainActor
final class RepoExplorerMessageDeadlineHostFixture {
    typealias Completion = RepoExplorerMaterializedProjection.ProjectionCompletion

    let composition: CompositionFactoryFixture
    let store: WorkspaceStore
    let paneID: UUID
    let written: AgentLineDetail
    let initialDisplay: PaneContextDisplay
    let clock: RepoExplorerMessageDeadlineTestClock
    let adapter: RepoExplorerProjectionAdapter
    let host: RepoExplorerMessageDeadlineTableHost
    let completions: FactRecorder<Int, Completion>
    private var closed = false

    private init(
        composition: CompositionFactoryFixture, store: WorkspaceStore, atoms: CoreAtoms,
        written: AgentLineDetail, display: PaneContextDisplay, surface: SidebarSurface
    ) {
        self.composition = composition
        self.store = store
        paneID = composition.ownerId.uuid
        self.written = written
        initialDisplay = display
        let clock = RepoExplorerMessageDeadlineTestClock(wallNow: written.updatedAt.addingTimeInterval(125))
        self.clock = clock
        let completions = FactRecorder<Int, Completion>(
            vocabulary: .init(
                describeScope: { "sidebar projection generation \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { _, _ in true }))
        self.completions = completions
        atoms.workspaceSidebarState.setSidebarSurface(surface)
        let preferences = RepoExplorerSidebarPrefsAtom(sidebarState: atoms.workspaceSidebarState)
        if surface == .repos {
            preferences.setGroupingMode(.repo, for: surface)
            preferences.setSortField(.name, for: surface)
        }
        let presentation = composition.presentationAtom
        let capture = RepoExplorerProjectionInputCapture(
            store: store, preferences: preferences, repoCache: atoms.repoCache,
            sidebarState: atoms.workspaceSidebarState, sidebarCache: atoms.sidebarCache, coreAtoms: atoms,
            bridgeAttendanceSnapshot: { _ in nil }, latestPaneMessageSnapshot: { _ in nil },
            contextDisplayForPane: { presentation.value(for: $0) },
            continuousNow: { clock.continuousNow }, wallNow: { clock.wallNow })
        adapter = RepoExplorerProjectionAdapter(
            inputCapture: capture, recencyNow: { clock.wallNow }, deadlineNow: { clock.wallNow },
            continuousNow: { clock.continuousNow }, recencyDelay: clock.delay,
            onProjectionCompletion: { completion in
                let generation: Int
                switch completion {
                case .published(let value), .equal(let value), .rejected(let value),
                    .superseded(let value), .cancelled(let value):
                    generation = value
                }
                completions.append(scope: generation, fact: completion)
            })
        host = RepoExplorerMessageDeadlineTableHost(adapter: adapter)
        host.window.appearance = NSAppearance(named: .darkAqua)
    }

    static func make(
        atoms: CoreAtoms, surface: SidebarSurface = .panes
    ) async throws -> RepoExplorerMessageDeadlineHostFixture {
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        let repository = store.addRepo(at: URL(fileURLWithPath: "/tmp/sidebar-message-\(UUIDv7.generate())"))
        let worktree = try #require(repository.worktrees.first)
        let pane = store.createPane(
            launchDirectory: worktree.path, title: "Stored message pane", facets: .init(cwd: worktree.path))
        store.appendTab(Tab(paneId: pane.id))
        atoms.repoCache.setRepoEnrichment(
            .resolvedLocal(
                repoId: repository.id, identity: RemoteIdentityNormalizer.localIdentity(repoName: repository.name),
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let composition = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: pane.id))
        do {
            let service = composition.composition.paneContextService
            let writer = AgentMessageSender.pane(composition.ownerId)
            let claim = await service.claimEpoch(
                .init(paneId: composition.ownerId, writer: writer, stream: .line, claimId: UUIDv7.generate()))
            guard case .claimed(let epoch) = claim else {
                Issue.record("Stored sidebar message could not claim its write epoch")
                throw RepoExplorerMessageDeadlineFailure.unavailableMessage
            }
            try #require(
                await service.setLine(
                    .init(
                        paneId: composition.ownerId, writer: writer,
                        line: .init(summary: "Quiet stored message", refs: []),
                        writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
            await composition.composition.presentationLane.publishPending()
            let display = try #require(composition.presentationAtom.value(for: composition.ownerId))
            let written = try #require(display.agentLine)
            let fixture = RepoExplorerMessageDeadlineHostFixture(
                composition: composition, store: store, atoms: atoms, written: written, display: display,
                surface: surface)
            try #require(fixture.adapter.registerMaterializationHost(fixture.host.host))
            return fixture
        } catch {
            try? await composition.close()
            store.removePane(pane.id)
            throw error
        }
    }

    func expectPublished(_ generation: Int) async throws {
        // Every non-published owner terminal is consumed and rejected by name.
        try await completions.expectNext(in: generation, .published(generation))
    }

    func expectStoredMessageUnchanged() async throws {
        let result = await composition.composition.paneContextService.readDetail(
            .init(paneId: composition.ownerId, page: .first))
        guard case .detail(let detail) = result else {
            Issue.record("Stored sidebar message could not be read after deadline refresh")
            throw RepoExplorerMessageDeadlineFailure.unavailableMessage
        }
        #expect(detail.agentLine == written)
        #expect(composition.presentationAtom.value(for: composition.ownerId) == initialDisplay)
    }

    func expectVisibleMessage(age: String) throws -> RepoExplorerRowID {
        let materializer = try #require(host.materializer)
        let snapshot = try #require(materializer.snapshot)
        let index = try #require(
            snapshot.rows.firstIndex { row in
                if case .pane(let pane) = row.presentation { return pane.destination.paneId == paneID }
                return false
            })
        let row = snapshot.rows[index]
        guard case .pane(let pane) = row.presentation else {
            throw RepoExplorerMessageDeadlineFailure.unavailableMessage
        }
        let lines = try #require(pane.variants?.compact.lines)
        let message = try #require(
            lines.compactMap { line -> RepoExplorerPaneContextLine? in
                if case .agentLine(let value) = line { return value }
                return nil
            }.first)
        #expect(message.text == written.summary)
        #expect(message.ageText == age)
        #expect(pane.recencyText == "—")
        host.window.layoutIfNeeded()
        let cell = try #require(
            materializer.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? RepoExplorerTableRowCell)
        cell.layoutSubtreeIfNeeded()
        cell.hostingView.layoutSubtreeIfNeeded()
        cell.hostingView.displayIfNeeded()
        #expect(cell.currentBindingIdentity?.rowID == row.id)
        let label = try #require(findAgeView(in: cell.hostingView))
        #expect(label.accessibilityLabel() == age)
        let visibleFrame = materializer.scrollView.contentView.convert(label.bounds, from: label)
        #expect(!visibleFrame.isEmpty && materializer.scrollView.contentView.bounds.intersects(visibleFrame))
        let rendering = PaneContextToolbarRenderingTests()
        let reference = rendering.mountCard(
            AnyView(
                Text(age).font(.system(size: AppStyles.Shell.Sidebar.branchFontSize)).foregroundStyle(Color.secondary)
                    .fixedSize()),
            width: nil)
        defer { reference.window.close() }
        #expect(
            rendering.containsTextInk(
                try rendering.ink(in: reference.host, minimumBrightness: 60),
                in: try rendering.ink(in: cell.hostingView, minimumBrightness: 60)),
            "The full expected message age must paint in the materialized visible row")
        return row.id
    }

    private func findAgeView(in view: NSView) -> AccessibilityLabelBridgeView? {
        if let label = view as? AccessibilityLabelBridgeView,
            label.accessibilityIdentifier() == "paneContext.agentLine.age"
        {
            return label
        }
        return view.subviews.lazy.compactMap { self.findAgeView(in: $0) }.first
    }

    func closeProducers() async throws {
        guard !closed else { return }
        closed = true
        await adapter.stopAndDrain()
        // Failure cleanup still drains a deliberately faulty demand-cancellation
        // path; assertions above run before this direct owner shutdown.
        await adapter.deadlineWorker.updatePresentationDeadline(nil, demanded: false, generation: Int.max)
        host.stop(adapter: adapter)
        store.removePane(paneID)
        defer { clock.facts.append(scope: 0, fact: .retired) }
        try await composition.close()
    }

    func finishFacts() async throws {
        try await completions.finish()
        try await clock.facts.finish()
    }
}

private enum RepoExplorerMessageDeadlineFailure: Error { case unavailableMessage }

@MainActor
final class RepoExplorerMessageDeadlineTableHost {
    private final class MaterializerBox {
        var value: RepoExplorerTableMaterializer?
    }

    let host: RepoExplorerMaterializationHost
    let window: NSWindow
    private let materializerBox: MaterializerBox

    var materializer: RepoExplorerTableMaterializer? { materializerBox.value }

    init(adapter: RepoExplorerProjectionAdapter) {
        let lifetime = RepoExplorerMaterializationHostLifetimeID(rawValue: UUIDv7.generate())
        let box = MaterializerBox()
        materializerBox = box
        host = RepoExplorerMaterializationHost(
            lifetimeID: lifetime, initialDemandEpoch: adapter.materializationDemandEpoch,
            initialPresentation: .noRepositories,
            makeContentChild: {
                let materializer = RepoExplorerTableMaterializer(
                    materializationHostLifetimeID: lifetime, octiconLoader: makeTestOcticonLoader(),
                    onVisibleWorktreeSnapshotChange: { _ in })
                box.value = materializer
                return materializer
            }, onFeedback: adapter.receiveMaterializationFeedback)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
    }

    func stop(adapter: RepoExplorerProjectionAdapter) {
        host.detach()
        adapter.stop()
        window.close()
    }
}
