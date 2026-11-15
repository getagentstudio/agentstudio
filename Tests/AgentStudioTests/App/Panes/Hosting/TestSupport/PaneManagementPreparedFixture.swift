import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

/// Supplies the production reader/family composition omitted by the old synchronous card fixtures.
@MainActor
final class PaneManagementPreparedFixture {
    let source: CompositionFactoryFixture
    let readers: PaneContextUIReaders
    let bindings: PaneContextPopoverHostBindings
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var window: NSWindow?
    private var renderingTasks: [Task<Void, Never>] = []
    private var handles: [PaneContextPopoverConsumerHandle] = []
    private var applications: [UUID: PaneContextPopoverApplication] = [:]

    private init(source: CompositionFactoryFixture, store: WorkspaceStore) {
        self.source = source
        let adapter = PaneContextUIAdapter(service: source.composition.paneContextService)
        let status = SessionStatusAtom()
        let owners = PaneContextTestSourceOwners(
            sessionStatus: status, presentation: source.presentationAtom,
            pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
        bindings = owners.bindings(clock: TestPushClock(), wallNow: { source.now })
        readers = .init(
            sessionStatus: status, presentation: source.presentationAtom, pane: owners.pane, popoverBindings: bindings)
    }

    static func make(paneId: UUID, store: WorkspaceStore) async throws -> PaneManagementPreparedFixture {
        let source = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: paneId))
        // Real lazy-service startup publishes canonical state before the measured UI opening.
        let display = await source.composition.paneContextService.readDisplay(paneId: source.ownerId)
        guard display != nil else {
            try await source.close()
            throw FixtureFailure.missingDisplay
        }
        await source.composition.presentationLane.publishPending()
        return .init(source: source, store: store)
    }

    func mount(_ root: some View, size: CGSize) {
        host.rootView = AnyView(
            root.frame(width: size.width, height: size.height).environment(\.paneContextUIReaders, readers)
                .transaction {
                    $0.disablesAnimations = true
                    $0.animation = nil
                })
        let window = NSWindow(
            contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        self.window = window
        host.layoutSubtreeIfNeeded()
    }

    func renderingStarted(_ task: Task<Void, Never>) { renderingTasks.append(task) }
    func consumerStarted(_ handle: PaneContextPopoverConsumerHandle) { handles.append(handle) }
    func observeApplication(_ event: PaneContextPopoverApplicationEvent) {
        if case .applied(let value) = event { applications[value.publication.id] = value }
    }

    func renderedCard() async throws {
        try #require(!renderingTasks.isEmpty, "The actual mounted card must announce its rendering producer")
        for task in renderingTasks { await task.value }
        let handle = try #require(handles.last, "Rendering ended without an actual card consumer")
        let accepted = try #require(handle.atom.latestAcceptedValue, "Rendering ended without an accepted card")
        try #require(accepted.publication.request.validationPhase == .resolved)
        let isCurrent = handle.atom.isCurrent(accepted.publication.request)
        try #require(isCurrent)
        // Equal completion advances authority/metadata while retaining the actual rendered value reference.
        let value = try #require(handle.atom.value, "Rendering ended without a displayed card")
        try #require(value.card != nil)
        // Existing D56/D57 owning-host application boundary, no settlement loop or timed wait.
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        try #require(
            applications[value.publication.id] != nil, "The exact prepared card never reached native application")
    }

    func close() async throws {
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        await bindings.stop()
        for task in renderingTasks {
            task.cancel()
            await task.value
        }
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        try await source.close()
    }

    private enum FixtureFailure: Error { case missingDisplay }
}
