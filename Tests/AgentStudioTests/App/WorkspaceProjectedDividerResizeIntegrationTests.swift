import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Projected divider resize", .serialized)
struct WorkspaceProjectedDividerResizeIntegrationTests {
    @Test("rendered pair resize skips a backgrounded canonical pane")
    func renderedPairResizeSkipsBackgroundedCanonicalPane() async throws {
        installTestCoreAtomsIfNeeded()
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let runtime = SessionRuntime(store: store)
        let surfaceManager = makeAppTerminalFixtureSurfaceManager()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: runtime,
            surfaceManager: surfaceManager,
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(surfaceManager: surfaceManager),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: WindowLifecycleAtom(),
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: BridgePaneAttendanceAtom()
        )
        let executor = WorkspaceActionExecutor(coordinator: coordinator, store: store)
        let firstActivePane = store.createPane()
        let backgroundedPane = store.createPane()
        let secondActivePane = store.createPane()
        let tab = makeTab(
            paneIds: [firstActivePane.id, backgroundedPane.id, secondActivePane.id],
            activePaneId: firstActivePane.id
        )
        store.appendTab(tab)
        store.setResidency(.backgrounded, for: backgroundedPane.id)
        let canonicalLayoutBeforeResize = try #require(store.tab(tab.id)?.activeArrangement.layout)

        let didExecute = await executor.execute(
            .resizeVisiblePanePair(
                tabId: tab.id,
                leftPaneId: firstActivePane.id,
                rightPaneId: secondActivePane.id,
                ratio: 0.3
            )
        )

        let canonicalLayoutAfterResize = try #require(store.tab(tab.id)?.activeArrangement.layout)
        #expect(didExecute)
        #expect(
            abs(
                (canonicalLayoutAfterResize.ratioForPanePair(
                    leftPaneId: firstActivePane.id,
                    rightPaneId: secondActivePane.id
                ) ?? 0) - 0.3
            ) < 0.001
        )
        #expect(
            canonicalLayoutAfterResize.paneRatio(backgroundedPane.id)
                == canonicalLayoutBeforeResize.paneRatio(backgroundedPane.id)
        )
        #expect(store.pane(backgroundedPane.id)?.residency == .backgrounded)

        store.setResidency(.active, for: backgroundedPane.id)
        let layoutBeforeStalePair = try #require(store.tab(tab.id)?.activeArrangement.layout)

        let didExecuteStalePair = await executor.execute(
            .resizeVisiblePanePair(
                tabId: tab.id,
                leftPaneId: firstActivePane.id,
                rightPaneId: secondActivePane.id,
                ratio: 0.7
            )
        )

        #expect(!didExecuteStalePair)
        #expect(store.tab(tab.id)?.activeArrangement.layout == layoutBeforeStalePair)
    }
}
