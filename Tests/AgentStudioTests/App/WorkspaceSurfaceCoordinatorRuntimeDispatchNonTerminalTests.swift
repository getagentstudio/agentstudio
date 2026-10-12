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
struct WorkspaceRuntimeDispatchNonTerminalTests {
    @Test("dispatchRuntimeCommand routes non-terminal commands to targeted runtimes")
    func dispatchRoutesNonTerminalRuntimeCommands() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-coordinator-runtime-non-terminal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WorkspaceStore()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: ViewRegistry(),
            runtime: SessionRuntime(store: store),
            surfaceManager: NonTerminalSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )

        let webviewPane = store.createPane(
            content: .webview(WebviewState(url: URL(string: "https://example.com/non-terminal-webview")!)),
            metadata: PaneMetadata(title: "Webview")
        )
        let bridgePane = store.createPane(
            content: .bridgePanel(BridgePaneState(panelKind: .diffViewer, source: nil)),
            metadata: PaneMetadata(
                title: "Bridge",
                facets: PaneContextFacets(cwd: tempDir)
            )
        )
        let codePane = store.createPane(
            content: .codeViewer(
                CodeViewerState(filePath: URL(fileURLWithPath: "/tmp/non-terminal.swift"), scrollToLine: nil)
            ),
            metadata: PaneMetadata(title: "Code")
        )

        store.appendTab(Tab(paneId: webviewPane.id))
        store.appendTab(Tab(paneId: bridgePane.id))
        store.appendTab(Tab(paneId: codePane.id))

        let bridgeWorktreeId = UUID()
        let webviewRuntime = FakePaneRuntimeNonTerminal(
            paneId: PaneId(existingUUID: webviewPane.id),
            contentType: .browser,
            capabilities: [.navigation]
        )
        let bridgeRuntime = FakePaneRuntimeNonTerminal(
            paneId: PaneId(existingUUID: bridgePane.id),
            contentType: .diff,
            capabilities: [.diffReview]
        )
        var bridgeRuntimeFacets = bridgeRuntime.metadata.facets
        bridgeRuntimeFacets.worktreeId = bridgeWorktreeId
        bridgeRuntime.metadata.updateFacets(bridgeRuntimeFacets)
        let codeViewerRuntime = FakePaneRuntimeNonTerminal(
            paneId: PaneId(existingUUID: codePane.id),
            contentType: .codeViewer,
            capabilities: [.editorActions]
        )
        coordinator.registerRuntime(webviewRuntime)
        coordinator.registerRuntime(bridgeRuntime)
        coordinator.registerRuntime(codeViewerRuntime)

        let webviewResult = await coordinator.dispatchRuntimeCommand(
            .browser(.reload(hard: false)),
            target: .pane(PaneId(existingUUID: webviewPane.id))
        )
        let artifact = DiffArtifact(
            diffId: UUID(),
            worktreeId: bridgeWorktreeId,
            patchData: Data("diff --git a/file b/file\n+line\n-line\n".utf8)
        )
        let bridgeResult = await coordinator.dispatchRuntimeCommand(
            .diff(.loadDiff(artifact)),
            target: .pane(PaneId(existingUUID: bridgePane.id))
        )
        let codeViewerResult = await coordinator.dispatchRuntimeCommand(
            .editor(.save),
            target: .pane(PaneId(existingUUID: codePane.id))
        )

        #expect(webviewResult == .success(commandId: webviewRuntime.receivedCommandIds.first!))
        #expect(bridgeResult == .success(commandId: bridgeRuntime.receivedCommandIds.first!))
        #expect(codeViewerResult == .success(commandId: codeViewerRuntime.receivedCommandIds.first!))
        #expect(webviewRuntime.receivedCommands.count == 1)
        #expect(bridgeRuntime.receivedCommands.count == 1)
        #expect(codeViewerRuntime.receivedCommands.count == 1)
    }
}

@MainActor
private final class FakePaneRuntimeNonTerminal: PaneRuntime {
    let paneId: PaneId
    var metadata: PaneMetadata
    var lifecycle: PaneRuntimeLifecycle = .ready
    var capabilities: Set<PaneCapability>
    private let stream: AsyncStream<RuntimeEnvelope>
    private let continuation: AsyncStream<RuntimeEnvelope>.Continuation

    private(set) var receivedCommands: [RuntimeCommandEnvelope] = []
    private(set) var receivedCommandIds: [UUID] = []

    init(
        paneId: PaneId,
        contentType: PaneContentType,
        capabilities: Set<PaneCapability>
    ) {
        self.paneId = paneId
        self.metadata = PaneMetadata(
            paneId: paneId,
            contentType: contentType,
            title: "Fake"
        )
        self.capabilities = capabilities
        let (stream, continuation) = AsyncStream.makeStream(of: RuntimeEnvelope.self)
        self.stream = stream
        self.continuation = continuation
    }

    func handleCommand(_ envelope: RuntimeCommandEnvelope) async -> ActionResult {
        receivedCommands.append(envelope)
        receivedCommandIds.append(envelope.commandId)
        return .success(commandId: envelope.commandId)
    }

    func subscribe() -> AsyncStream<RuntimeEnvelope> { stream }

    func snapshot() -> PaneRuntimeSnapshot {
        PaneRuntimeSnapshot(
            paneId: paneId,
            metadata: metadata,
            lifecycle: lifecycle,
            capabilities: capabilities,
            lastSeq: 0,
            timestamp: Date()
        )
    }

    func eventsSince(seq: UInt64) async -> EventReplayBuffer.ReplayResult {
        EventReplayBuffer.ReplayResult(events: [], nextSeq: seq, gapDetected: false)
    }

    func shutdown(timeout _: Duration) async -> [UUID] {
        continuation.finish()
        return []
    }
}

@MainActor
private final class NonTerminalSurfaceManager: WorkspaceSurfaceManaging {
    func retainSurfacesForUndo(forPaneIDs paneIDs: Set<UUID>) {}
    func retireActiveAndHiddenSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func releaseUndoSurfaces(forPaneIDs paneIDs: Set<UUID>) {}

    func syncFocus(activeSurfaceId _: UUID?) {}

    func createSurface(
        config _: Ghostty.SurfaceConfiguration,
        metadata _: SurfaceMetadata
    ) -> Result<ManagedSurface, SurfaceError> {
        .failure(.ghosttyNotInitialized)
    }

    @discardableResult
    func attach(_ surfaceId: UUID, to paneId: UUID) -> Ghostty.SurfaceView? {
        _ = surfaceId
        _ = paneId
        return nil
    }

    func detach(_ surfaceId: UUID, reason: SurfaceDetachReason) {
        _ = surfaceId
        _ = reason
    }

    func undoClose(forPaneId paneId: UUID) -> ManagedSurface? { nil }

    func destroy(_ surfaceId: UUID) {
        _ = surfaceId
    }
}
