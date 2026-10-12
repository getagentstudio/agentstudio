import Foundation
import GhosttyKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct WorkspaceSurfaceCoordinatorRuntimeDispatchTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("constructing another coordinator cannot replace the selected runtime registry")
    func anotherCoordinatorCannotReplaceSelectedRegistry() async {
        let store = WorkspaceStore()
        let firstRegistry = RuntimeRegistry()
        let secondRegistry = RuntimeRegistry()
        let first = makeTestWorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: MockWorkspaceSurfaceCoordinatorSurfaceManager(), runtimeRegistry: firstRegistry
        )
        let pane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/registry-selection")!)),
            metadata: PaneMetadata(title: "Selected registry")
        )
        let paneID = PaneId(existingUUID: pane.id)
        let firstRuntime = FakePaneRuntime(paneId: paneID)
        first.registerRuntime(firstRuntime)
        let second = makeTestWorkspaceSurfaceCoordinator(
            store: store, viewRegistry: ViewRegistry(), runtime: SessionRuntime(store: store),
            surfaceManager: MockWorkspaceSurfaceCoordinatorSurfaceManager(), runtimeRegistry: secondRegistry
        )
        let secondRuntime = FakePaneRuntime(paneId: paneID)
        second.registerRuntime(secondRuntime)

        let firstResult = await first.dispatchRuntimeCommand(.activate, target: .pane(paneID))
        if case .success = firstResult {} else { Issue.record("First selected runtime did not activate") }
        #expect(firstRuntime.receivedCommands.count == 1)
        #expect(secondRuntime.receivedCommands.isEmpty)
        let secondResult = await second.dispatchRuntimeCommand(.activate, target: .pane(paneID))
        if case .success = secondResult {} else { Issue.record("Second selected runtime did not activate") }
        #expect(firstRuntime.receivedCommands.count == 1)
        #expect(secondRuntime.receivedCommands.count == 1)
        await first.shutdown()
        await second.shutdown()
    }

    @Test("dispatchRuntimeCommand resolves pane target centrally")
    func dispatchUsesResolver() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-runtime-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let mockSurfaceManager = MockWorkspaceSurfaceCoordinatorSurfaceManager()
        let runtimeRegistry = RuntimeRegistry()
        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: mockSurfaceManager,
            runtimeRegistry: runtimeRegistry
        )

        let pane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/runtime-dispatch")!)),
            metadata: PaneMetadata(title: "Runtime")
        )
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)

        let fakeRuntime = FakePaneRuntime(paneId: PaneId(existingUUID: pane.id))
        coordinator.registerRuntime(fakeRuntime)

        let result = await coordinator.dispatchRuntimeCommand(.activate, target: .activePane)
        #expect(result == .success(commandId: fakeRuntime.receivedCommandIds.first!))
        #expect(fakeRuntime.receivedCommands.count == 1)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("dispatchRuntimeCommand fails for unresolved target")
    func dispatchFailsForMissingTarget() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-runtime-missing-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let mockSurfaceManager = MockWorkspaceSurfaceCoordinatorSurfaceManager()
        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: mockSurfaceManager,
            runtimeRegistry: RuntimeRegistry()
        )

        let result = await coordinator.dispatchRuntimeCommand(.activate, target: .activePane)
        #expect(result == .failure(.invalidPayload(description: "Unable to resolve pane target")))

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("dispatchRuntimeCommand rejects dispatch when runtime lifecycle is not ready")
    func dispatchFailsWhenRuntimeNotReady() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-runtime-not-ready-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let mockSurfaceManager = MockWorkspaceSurfaceCoordinatorSurfaceManager()
        let runtimeRegistry = RuntimeRegistry()
        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: mockSurfaceManager,
            runtimeRegistry: runtimeRegistry
        )

        let pane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/runtime-not-ready")!)),
            metadata: PaneMetadata(title: "Runtime")
        )
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)

        let fakeRuntime = FakePaneRuntime(paneId: PaneId(existingUUID: pane.id))
        fakeRuntime.lifecycle = .created
        coordinator.registerRuntime(fakeRuntime)

        let result = await coordinator.dispatchRuntimeCommand(.activate, target: .activePane)
        #expect(result == .failure(.runtimeNotReady(lifecycle: .created)))
        #expect(fakeRuntime.receivedCommands.isEmpty)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("dispatchRuntimeCommand surfaces runtime capability failures")
    func dispatchFailsWhenCapabilityMissing() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-runtime-capability-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let mockSurfaceManager = MockWorkspaceSurfaceCoordinatorSurfaceManager()
        let runtimeRegistry = RuntimeRegistry()
        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: mockSurfaceManager,
            runtimeRegistry: runtimeRegistry
        )

        let pane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/runtime-capability")!)),
            metadata: PaneMetadata(title: "Runtime")
        )
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)

        let fakeRuntime = FakePaneRuntime(paneId: PaneId(existingUUID: pane.id))
        fakeRuntime.capabilities = [.input]
        coordinator.registerRuntime(fakeRuntime)

        let result = await coordinator.dispatchRuntimeCommand(.browser(.reload(hard: false)), target: .activePane)
        switch result {
        case .failure(.unsupportedCommand(_, .navigation)):
            break
        default:
            #expect(Bool(false), "Expected unsupportedCommand requiring navigation capability")
        }
        #expect(fakeRuntime.receivedCommands.isEmpty)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("dispatchRuntimeCommand rejects diff artifact worktree mismatch")
    func dispatchRejectsDiffWorktreeMismatch() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-runtime-diff-worktree-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let mockSurfaceManager = MockWorkspaceSurfaceCoordinatorSurfaceManager()
        let runtimeRegistry = RuntimeRegistry()
        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: mockSurfaceManager,
            runtimeRegistry: runtimeRegistry
        )

        let pane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/runtime-diff")!)),
            metadata: PaneMetadata(title: "Runtime")
        )
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)

        let fakeRuntime = FakePaneRuntime(paneId: PaneId(existingUUID: pane.id))
        fakeRuntime.capabilities = [.diffReview]
        var facets = fakeRuntime.metadata.facets
        facets.worktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        fakeRuntime.metadata.updateFacets(facets)
        coordinator.registerRuntime(fakeRuntime)

        let artifact = DiffArtifact(
            diffId: UUID(),
            worktreeId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            patchData: Data("diff".utf8)
        )
        let result = await coordinator.dispatchRuntimeCommand(.diff(.loadDiff(artifact)), target: .activePane)
        switch result {
        case .failure(.invalidPayload(let description)):
            #expect(description.contains("worktree"))
        default:
            #expect(Bool(false), "Expected invalidPayload for mismatched diff worktree routing")
        }
        #expect(fakeRuntime.receivedCommands.isEmpty)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("closeTab teardown unregisters runtime from registry")
    func closeTab_unregistersRuntime() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-runtime-close-\(UUID().uuidString)")
        let store = try makeWorkspaceJournalTestStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let mockSurfaceManager = MockWorkspaceSurfaceCoordinatorSurfaceManager()
        let runtimeRegistry = RuntimeRegistry()
        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: mockSurfaceManager,
            runtimeRegistry: runtimeRegistry
        )

        let pane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/runtime-close")!)),
            metadata: PaneMetadata(
                contentType: .browser,
                title: "RuntimeClose"
            )
        )
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)

        let fakeRuntime = FakePaneRuntime(paneId: PaneId(existingUUID: pane.id))
        coordinator.registerRuntime(fakeRuntime)
        #expect(coordinator.runtimeForPane(PaneId(existingUUID: pane.id)) != nil)

        do {
            try await coordinator.execute(.closeTab(tabId: tab.id))
        } catch {
            await coordinator.shutdown()
            throw error
        }

        #expect(coordinator.runtimeForPane(PaneId(existingUUID: pane.id)) == nil)

        await coordinator.shutdown()
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("runtime terminal title/cwd events update pane metadata")
    func runtimeEventMetadataUpdatesPaneStore() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-runtime-events-metadata-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let mockSurfaceManager = MockWorkspaceSurfaceCoordinatorSurfaceManager()
        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: mockSurfaceManager,
            runtimeRegistry: RuntimeRegistry()
        )

        let sourcePane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/source-metadata")!)),
            metadata: PaneMetadata(title: "Source")
        )
        let sourceTab = Tab(paneId: sourcePane.id)
        store.appendTab(sourceTab)
        store.setActiveTab(sourceTab.id)

        let fakeRuntime = FakePaneRuntime(paneId: PaneId(existingUUID: sourcePane.id))
        coordinator.registerRuntime(fakeRuntime)
        let expectedCWD = URL(filePath: "/tmp/updated-cwd", directoryHint: .isDirectory)

        fakeRuntime.emit(
            makeRuntimeEnvelope(
                source: .pane(PaneId(existingUUID: sourcePane.id)),
                paneKind: .terminal,
                seq: 1,
                commandId: nil,
                correlationId: nil,
                timestamp: ContinuousClock().now,
                epoch: 0,
                event: .terminal(.titleChanged("Updated Title"))
            )
        )
        fakeRuntime.emit(
            makeRuntimeEnvelope(
                source: .pane(PaneId(existingUUID: sourcePane.id)),
                paneKind: .terminal,
                seq: 2,
                commandId: nil,
                correlationId: nil,
                timestamp: ContinuousClock().now,
                epoch: 0,
                event: .terminal(.cwdChanged(expectedCWD.path))
            )
        )

        await eventually("runtime metadata updates are reflected in workspace store") {
            store.pane(sourcePane.id)?.metadata.title == "Updated Title"
                && store.pane(sourcePane.id)?.metadata.cwd == expectedCWD
        }

        #expect(store.pane(sourcePane.id)?.metadata.title == "Updated Title")
        #expect(store.pane(sourcePane.id)?.metadata.cwd == expectedCWD)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("runtime cwd changed updates pane worktree identity")
    func runtimeCwdChangedUpdatesPaneWorktreeIdentity() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-runtime-cwd-identity-\(UUID().uuidString)")
        let store = WorkspaceStore()
        let coordinator = makeTestWorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: MockWorkspaceSurfaceCoordinatorSurfaceManager(),
            runtimeRegistry: RuntimeRegistry()
        )

        let repo = store.addRepo(at: URL(filePath: "/tmp/cwd-identity-repo"))
        let main = Worktree(
            repoId: repo.id,
            name: "main",
            path: URL(filePath: "/tmp/cwd-identity-repo"),
            isMainWorktree: true
        )
        let feature = Worktree(
            repoId: repo.id,
            name: "feature",
            path: URL(filePath: "/tmp/cwd-identity-repo-feature")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [main, feature])

        let pane = store.createPane(
            launchDirectory: main.path,
            title: "Terminal",
            facets: PaneContextFacets(repoId: repo.id, worktreeId: main.id, cwd: main.path),
        )
        store.appendTab(Tab(paneId: pane.id))

        let fakeRuntime = FakePaneRuntime(paneId: PaneId(existingUUID: pane.id))
        coordinator.registerRuntime(fakeRuntime)
        let expectedCWD = URL(
            filePath: feature.path.appending(path: "Sources").path,
            directoryHint: .isDirectory
        )
        fakeRuntime.emit(
            makeRuntimeEnvelope(
                source: .pane(PaneId(existingUUID: pane.id)),
                paneKind: .terminal,
                seq: 1,
                commandId: nil,
                correlationId: nil,
                timestamp: ContinuousClock().now,
                epoch: 0,
                event: .terminal(.cwdChanged(expectedCWD.path))
            )
        )

        await eventually("runtime cwd should refresh pane identity") {
            store.pane(pane.id)?.worktreeId == feature.id
        }

        let updated = store.pane(pane.id)
        #expect(updated?.metadata.cwd == expectedCWD)
        #expect(updated?.repoId == repo.id)
        #expect(updated?.worktreeId == feature.id)
        #expect(updated?.metadata.worktreeName == "feature")

        #expect(
            updated?.metadata.launchDirectory
                == URL(filePath: main.path.path, directoryHint: .isDirectory)
        )

        try? FileManager.default.removeItem(at: tempDir)
    }

}

// swiftlint:enable type_body_length

@MainActor
private final class MockWorkspaceSurfaceCoordinatorSurfaceManager: WorkspaceSurfaceManaging {
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
