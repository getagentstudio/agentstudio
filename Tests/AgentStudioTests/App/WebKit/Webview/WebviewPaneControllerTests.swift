import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct WebviewPaneControllerTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        private func settleEventLoop(turns: Int = 8) async {
            for _ in 0..<turns {
                await Task.yield()
            }
        }

        private func setManagementLayer(active: Bool) async {
            for _ in 0..<6 {
                if active {
                    if !atom(\.managementLayer).isActive {
                        atom(\.managementLayer).toggle()
                    }
                } else if atom(\.managementLayer).isActive {
                    atom(\.managementLayer).deactivate()
                }

                await settleEventLoop(turns: 10)
                if atom(\.managementLayer).isActive == active {
                    return
                }
            }
        }

        private func makeController() -> WebviewPaneController {
            WebviewPaneController(
                paneId: UUIDv7.generate(),
                state: WebviewState(url: URL(string: "https://example.com")!)
            )
        }

        // MARK: - Init

        @Test
        func test_init_createsPage_fromState() {
            // Arrange
            let state = WebviewState(url: URL(string: "https://github.com")!, title: "GitHub")

            // Act
            let controller = WebviewPaneController(paneId: UUIDv7.generate(), state: state)

            // Assert
            #expect(controller.showNavigation)
            #expect(controller.url?.scheme == state.url.scheme)
            #expect(controller.url?.host() == state.url.host())
        }

        @Test
        func test_init_aboutBlank_doesNotLoad() {
            // Arrange
            let state = WebviewState(url: URL(string: "about:blank")!)

            // Act
            let controller = WebviewPaneController(paneId: UUIDv7.generate(), state: state)

            // Assert — page exists but url is nil (nothing loaded)
            #expect(controller.url == nil)
        }

        @Test
        func test_init_respectsShowNavigation() {
            // Arrange
            let state = WebviewState(url: URL(string: "https://example.com")!, showNavigation: false)

            // Act
            let controller = WebviewPaneController(paneId: UUIDv7.generate(), state: state)

            // Assert
            #expect(!controller.showNavigation)
        }

        // MARK: - Snapshot

        @Test
        func test_snapshot_capturesState() {
            // Arrange
            let controller = makeController()

            // Act
            let snapshot = controller.snapshot()

            // Assert
            #expect(snapshot.showNavigation)
            #expect(snapshot.url.host() == "example.com")
        }

        @Test
        func test_snapshot_aboutBlank_fallback() {
            // Arrange — controller with about:blank (nothing loaded → url is nil)
            let controller = WebviewPaneController(
                paneId: UUIDv7.generate(),
                state: WebviewState(url: URL(string: "about:blank")!)
            )

            // Act
            let snapshot = controller.snapshot()

            // Assert — nil url falls back to about:blank
            #expect(snapshot.url.absoluteString == "about:blank")
        }

        // MARK: - Management Layer Interaction Regression Coverage

        @Test
        func test_managementLayerToggle_updatesWebviewControllerInteractionState() async {
            await withAsyncTestCoreAtoms { _ in
                await setManagementLayer(active: false)
                let mountedView = WebviewPaneMountView(
                    paneId: UUIDv7.generate(),
                    state: WebviewState(url: URL(string: "about:blank")!)
                )
                let host = PaneHostView(paneId: mountedView.paneId)
                host.mountContentView(mountedView)
                _ = host.swiftUIContainer
                await settleEventLoop()
                #expect(mountedView.controller.isContentInteractionEnabled)

                await setManagementLayer(active: true)
                #expect(atom(\.managementLayer).isActive)
                #expect(!mountedView.controller.isContentInteractionEnabled)

                await setManagementLayer(active: false)
                #expect(!atom(\.managementLayer).isActive)
                #expect(mountedView.controller.isContentInteractionEnabled)
            }
        }

        @Test
        func test_webviewPaneView_resizesHostingViewToBounds() {
            // Arrange
            let paneView = WebviewPaneMountView(
                paneId: UUIDv7.generate(),
                state: WebviewState(url: URL(string: "about:blank")!)
            )
            let targetSize = NSSize(width: 920, height: 620)

            // Act
            paneView.setFrameSize(targetSize)
            paneView.layoutSubtreeIfNeeded()

            // Assert
            guard let hostingView = paneView.subviews.first else {
                Issue.record("Expected hosting view to be installed")
                return
            }
            #expect(hostingView.frame.equalTo(paneView.bounds))
        }
    }
}
