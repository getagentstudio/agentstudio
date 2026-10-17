import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioTerminal

@MainActor
@Suite("Scrollback workspace retirement paths", .serialized)
struct ScrollbackWorkspaceLifecycleTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("committed direct discard retires a pane snapshot through the shared route")
    func directDiscardDeletesSnapshot() async throws {
        try await withWorkspace { fixture in
            let pane = fixture.store.createPane(zmxSessionID: .generateUUIDv7(), residency: .backgrounded)
            #expect(await fixture.store.flushAsync() == .persisted)
            let paneID = PaneId(existingUUID: pane.id)
            _ = try await fixture.scrollback.store(paneId: paneID, capture: Data("discarded output".utf8))
            try await fixture.coordinator.execute(.purgeOrphanedPane(paneId: pane.id))
            try await expectRetirement(fixture, paneIDs: [paneID])
            #expect(await fixture.scrollback.load(paneId: paneID) == .absent)
            let url = fixture.scrollback.snapshotURL(for: paneID)
            #expect(await withoutBlockingCooperativePool { !FileManager.default.fileExists(atPath: url.path) })
        }
    }

    @Test("undo expiry reaches the same snapshot retirement route")
    func undoExpiryDeletesSnapshot() async throws {
        try await withWorkspace { fixture in
            let pane = fixture.store.createPane(zmxSessionID: .generateUUIDv7())
            let tab = Tab(paneId: pane.id)
            fixture.store.appendTab(tab)
            #expect(await fixture.store.flushAsync() == .persisted)
            let paneID = PaneId(existingUUID: pane.id)
            _ = try await fixture.scrollback.store(paneId: paneID, capture: Data("undo output".utf8))
            try await fixture.coordinator.execute(.closeTab(tabId: tab.id))
            let close = try #require(
                try await fixture.datastore.fetchAvailableUndoCloses(workspaceID: fixture.workspaceID).first)
            let retired = try await fixture.store.expireUndoCloses(
                time: .init(
                    utc: close.expiresAt.addingTimeInterval(1), bootID: close.deadlineBootID,
                    uptimeNanoseconds: close.deadlineUptimeNanoseconds + 1))
            fixture.coordinator.consumeUndoRetirements(retired)
            try await expectRetirement(fixture, paneIDs: [paneID])
            #expect(await fixture.scrollback.load(paneId: paneID) == .absent)
        }
    }

    @Test("shutdown joins a held undo expiry and its retirement before stopping the snapshotter")
    func shutdownJoinsUndoExpiryRetirement() async throws {
        let expiry = HeldStep<WorkspaceUndoJournalTime>(
            "undo deadline clock reached expiry during shutdown", cancellation: .holdThroughCancellation)
        defer { expiry.release() }
        try await withWorkspace(expiryHold: expiry) { fixture in
            let pane = fixture.store.createPane(zmxSessionID: .generateUUIDv7())
            let tab = Tab(paneId: pane.id)
            fixture.store.appendTab(tab)
            #expect(await fixture.store.flushAsync() == .persisted)
            let paneID = PaneId(existingUUID: pane.id)
            _ = try await fixture.scrollback.store(
                paneId: paneID, capture: Data("output expiring during shutdown".utf8))
            try await fixture.coordinator.execute(.closeTab(tabId: tab.id))
            let close = try #require(
                try await fixture.datastore.fetchAvailableUndoCloses(workspaceID: fixture.workspaceID).first)
            await fixture.clock.waitForPendingSleepCount(exactly: 1)
            fixture.clock.advance(by: AppPolicies.WorkspacePersistence.undoGracePeriod)
            let observedExpiry = try await expiry.firstArrival()
            #expect(observedExpiry.bootID == close.deadlineBootID)
            #expect(observedExpiry.uptimeNanoseconds >= close.deadlineUptimeNanoseconds)
            async let shutdown: Void = fixture.coordinator.shutdown()
            try await expiry.cancellationObserved()
            expiry.release()
            await shutdown
            // These reads happen after the exact shutdown completion, so no
            // later unrelated retirement can satisfy the deletion assertion.
            #expect(await fixture.scrollback.load(paneId: paneID) == .absent)
            let snapshotURL = fixture.scrollback.snapshotURL(for: paneID)
            #expect(await withoutBlockingCooperativePool { !FileManager.default.fileExists(atPath: snapshotURL.path) })
            try await expectRetirement(fixture, paneIDs: [paneID])
            try await fixture.recorder.expectNext(in: .scheduler, .stopped)
            let observedFacts = fixture.lifecycleFacts.observations()
            let retired = try #require(observedFacts.firstIndex(of: .retirementFinished))
            let stopped = try #require(observedFacts.firstIndex(of: .stopped))
            #expect(retired < stopped)
            #expect(fixture.clock.pendingSleepCount == 0)
        }
    }

    @Test("closing for undo retains both the snapshot and its persisted capture binding")
    func availableUndoKeepsSnapshotAndCaptureBinding() async throws {
        try await withWorkspace { fixture in
            let sessionID = ZmxSessionID.generateUUIDv7()
            let pane = fixture.store.createPane(zmxSessionID: sessionID)
            let tab = Tab(paneId: pane.id)
            fixture.store.appendTab(tab)
            #expect(await fixture.store.flushAsync() == .persisted)
            let paneID = PaneId(existingUUID: pane.id)
            let capture = Data("kept for undo".utf8)
            _ = try await fixture.scrollback.store(paneId: paneID, capture: capture)
            try await fixture.coordinator.execute(.closeTab(tabId: tab.id))
            #expect(fixture.store.paneAtom.pane(pane.id) == nil)
            let bindings = try await fixture.datastore.scrollbackPaneBindings(workspaceID: fixture.workspaceID)
            #expect(bindings == [.init(paneID: paneID, sessionID: sessionID)])
            #expect(await fixture.scrollback.load(paneId: paneID) == .present(ScrollbackStore.persistedForm(capture)))
            let restored = try await fixture.coordinator.undoCloseTab()
            #expect(restored)
            #expect(fixture.store.paneAtom.pane(pane.id)?.terminalState?.zmxSessionID == sessionID)
            let restoredBindings = try await fixture.datastore.scrollbackPaneBindings(workspaceID: fixture.workspaceID)
            #expect(restoredBindings == bindings)
            #expect(await fixture.scrollback.load(paneId: paneID) == .present(ScrollbackStore.persistedForm(capture)))
        }
    }

    @Test("the real repository-removal owner preserves a pane snapshot")
    func repositoryRemovalKeepsSnapshot() async throws {
        try await withWorkspace { fixture in
            let repo = fixture.store.mutationCoordinator.addRepo(at: fixture.root.appending(path: "repository"))
            let pane = fixture.store.createPane(zmxSessionID: .generateUUIDv7())
            fixture.store.appendTab(Tab(paneId: pane.id))
            #expect(await fixture.store.flushAsync() == .persisted)
            let paneID = PaneId(existingUUID: pane.id)
            let capture = Data("survives repository removal".utf8)
            _ = try await fixture.scrollback.store(paneId: paneID, capture: capture)
            fixture.coordinator.removeRepoHandler = { fixture.cacheCoordinator.handleRepoRemoval(repoId: $0) }
            try await fixture.coordinator.execute(.removeRepo(repoId: repo.id))
            #expect(fixture.store.repositoryTopologyAtom.repo(repo.id) == nil)
            await fixture.coordinator.shutdown()
            #expect(await fixture.scrollback.load(paneId: paneID) == .present(ScrollbackStore.persistedForm(capture)))
        }
    }

    private func expectRetirement(_ fixture: ScrollbackWorkspaceFixture, paneIDs: Set<PaneId>) async throws {
        let scope = try await fixture.recorder.expectNextOperation(
            matching: { if case .retirement = $0 { true } else { false } },
            opening: { $0 == .retirementStarted(paneIDs) }, "permanent retirement of the expected panes")
        try await fixture.recorder.expectNext(in: scope, .retirementStarted(paneIDs))
        try await fixture.recorder.expectNext(in: scope, .retirementFinished)
    }

    private func withWorkspace(
        expiryHold: HeldStep<WorkspaceUndoJournalTime>? = nil,
        _ body: (ScrollbackWorkspaceFixture) async throws -> Void
    ) async throws {
        let fixture = try ScrollbackWorkspaceFixture(expiryHold: expiryHold)
        var bodyError: (any Error)?
        do { try await body(fixture) } catch { bodyError = error }
        await fixture.coordinator.shutdown()
        await fixture.cacheCoordinator.shutdown()
        await fixture.snapshotter.shutdown()
        do { try await fixture.recorder.finish() } catch { if bodyError == nil { bodyError = error } }
        try await withoutBlockingCooperativePool {
            if FileManager.default.fileExists(atPath: fixture.root.path) {
                try FileManager.default.removeItem(at: fixture.root)
            }
        }
        if let bodyError { throw bodyError }
    }
}

@MainActor
private final class ScrollbackWorkspaceFixture {
    let workspaceID = UUIDv7.generate()
    let root = FileManager.default.temporaryDirectory.appending(
        path: "scrollback-workspace-\(UUIDv7.generate().uuidString)")
    let clock = AgentStudioTestSupport.TestPushClock()
    let store: WorkspaceStore
    let datastore: WorkspaceSQLiteDatastoreActor
    let coordinator: WorkspaceSurfaceCoordinator
    let cacheCoordinator: WorkspaceCacheCoordinator
    let scrollback: ScrollbackStore
    let snapshotter: ScrollbackSnapshotter
    let source: LocalFactSource<ScrollbackSnapshotterScope, ScrollbackSnapshotterFact>
    let recorder: FactRecorder<ScrollbackSnapshotterScope, ScrollbackSnapshotterFact>
    let lifecycleFacts = ScrollbackLifecycleRecorder()

    init(expiryHold: HeldStep<WorkspaceUndoJournalTime>? = nil) throws {
        let sqliteFixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        datastore = try preparedWorkspaceSQLiteDatastore(from: sqliteFixture.backend)
        store = WorkspaceStore(
            identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID), sqliteDatastore: datastore,
            startsObserving: false)
        let clock = clock
        let origin = clock.now
        let surfaceManager = HarnessSurfaceManager()
        coordinator = WorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: surfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable, bridgePaneAttendance: BridgePaneAttendanceAtom(),
            undoClock: {
                let elapsed = Int64(origin.duration(to: clock.now).nanosecondsForTaskSleep)
                let time = WorkspaceUndoJournalTime(
                    utc: Date(timeIntervalSince1970: 100 + Double(elapsed) / 1_000_000_000), bootID: "scrollback-test",
                    uptimeNanoseconds: 100_000_000_000 + elapsed)
                let expiryNanoseconds = Int64(AppPolicies.WorkspacePersistence.undoGracePeriod.nanosecondsForTaskSleep)
                if elapsed >= expiryNanoseconds, let expiryHold {
                    try await expiryHold.arrive(time)
                }
                return time
            }, undoDelay: .clock(clock))
        cacheCoordinator = WorkspaceCacheCoordinator(
            bus: EventBus<RuntimeEnvelope>(), workspaceStore: store,
            repoCache: RepoCacheAtom(), welcomeAtom: WelcomeAtom(), scopeSyncHandler: { _ in })
        scrollback = ScrollbackStore(directoryURL: root)
        source = LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    switch fact {
                    case .passFinished, .captureFinished, .retirementFinished, .quitFinished, .stopped: true
                    default: false
                    }
                }))
        recorder = try source.attach()
        let datastore = datastore
        let workspaceID = workspaceID
        let lifecycleFacts = lifecycleFacts
        let source = source
        snapshotter = ScrollbackSnapshotter(
            clock: clock, store: scrollback, performanceRecorder: nil, inventory: { .complete([:]) },
            paneBindings: { try await datastore.scrollbackPaneBindings(workspaceID: workspaceID) },
            capture: { _ in .empty },
            factSink: { scope, fact in
                lifecycleFacts.append(fact)
                source.sink(scope, fact)
            })
        coordinator.scrollbackSnapshotter = snapshotter
    }
}

private final class ScrollbackLifecycleRecorder: Sendable {
    private let recorded = Mutex<[ScrollbackSnapshotterFact]>([])

    func append(_ fact: ScrollbackSnapshotterFact) {
        recorded.withLock { $0.append(fact) }
    }

    func observations() -> [ScrollbackSnapshotterFact] {
        recorded.withLock { $0 }
    }
}
