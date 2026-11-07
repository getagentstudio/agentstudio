import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

/// A browser pane needs the icon loader boot hands the coordinator. Mounting
/// one without it is a composition bug, and it must stop the process with a
/// cause, not silently mount nothing.
@Suite("Webview mount without the icon loader")
struct WorkspaceSurfaceCoordinatorWebviewLoaderExitTests {
    @Test("mounting a browser before boot assigns the icon loader fails loudly")
    func browserMountWithoutLoaderFails() async throws {
        let result = try await #require(
            processExitsWith: .failure,
            observing: [\.standardErrorContent]
        ) {
            await MainActor.run {
                installTestCoreAtomsIfNeeded()
                let store = WorkspaceStore()
                let surfaceManager = makeAppTerminalFixtureSurfaceManager()
                let coordinator = WorkspaceSurfaceCoordinator(
                    store: store,
                    viewRegistry: ViewRegistry(),
                    runtime: SessionRuntime(store: store),
                    surfaceManager: surfaceManager, terminalSurfaceCommandDispatcher: surfaceManager,
                    terminalSurfaceOperations: surfaceManager.makeTerminalPaneSurfaceOperations(),
                    runtimeRegistry: RuntimeRegistry(),
                    windowLifecycleStore: WindowLifecycleAtom(),
                    ipcLifecycle: .testUnavailable,
                    bridgePaneAttendance: BridgePaneAttendanceAtom()
                )
                let pane = store.createPane(
                    content: .webview(WebviewState(url: URL(string: "https://example.com/unloaded")!)),
                    metadata: PaneMetadata(title: "Browser without loader")
                )
                _ = coordinator.createViewForContent(pane: pane)
            }
        }

        let standardError = try #require(String(bytes: result.standardErrorContent, encoding: .utf8))
        #expect(standardError.contains("webview pane mounted before boot assigned the coordinator's icon loader"))
    }
}
