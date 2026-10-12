import Foundation
import Testing
import WebKit

@testable import AgentStudio
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

// MARK: - Test Helpers

/// Minimal URLSchemeHandler that serves a blank HTML page.
/// Used for tests that need a proper document context.
private struct BlankPageSchemeHandler: URLSchemeHandler {
    func reply(for request: URLRequest) -> some AsyncSequence<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream<URLSchemeTaskResult, any Error> { continuation in
            let html = "<html><head><title>Spike Blank</title></head><body></body></html>"
            let data = Data(html.utf8)
            guard let url = request.url else {
                continuation.finish()
                return
            }
            continuation.yield(
                .response(
                    URLResponse(
                        url: url,
                        mimeType: "text/html",
                        expectedContentLength: data.count,
                        textEncodingName: "utf-8"
                    )))
            continuation.yield(.data(data))
            continuation.finish()
        }
    }
}

// MARK: - Tests

/// Verification spike for bridge-specific WebKit APIs.
///
/// Validates design doc section 16 items 1-4 before Phase 1 implementation:
/// 1. WKContentWorld creation and identity
/// 2. callJavaScript with arguments and content world targeting
/// 3. WKUserScript with content world injection isolation
/// 4. Message handler scoped to content world
///
/// These are NOT unit tests -- they exercise real WebKit instances.
///
/// ## Spike Finding: callJavaScript return values
///
/// `WebPage.callJavaScript` returns nil in headless test contexts (no window host).
/// This is a WebKit for SwiftUI limitation: the underlying WKWebView needs to be
/// hosted in a view hierarchy attached to a window for JS evaluation to return values.
/// However, `callJavaScript` DOES execute the JS code -- side effects like
/// `postMessage` work correctly. Tests use message handlers as verification probes
/// instead of relying on return values.
///
/// This does NOT affect production use, where WebPages are always hosted in a
/// `WebView` inside a window.
extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    final class BridgeWebKitSpikeTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        // MARK: - Item 1: WKContentWorld creation and identity

        /// Verify `WKContentWorld.world(name:)` returns a non-nil world,
        /// and calling it twice with the same name returns the same instance.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_STUDIO_WEBKIT_SPIKE_MODE"] == "on"))
        func test_contentWorld_sameNameReturnsSameWorld() async {
            // Arrange
            let worldA = WKContentWorld.world(name: "agentStudioBridge")
            let worldB = WKContentWorld.world(name: "agentStudioBridge")

            // Assert -- same name should return the same (identical) world object
            #expect(
                worldA === worldB,
                "WKContentWorld.world(name:) with the same name should return the identical object"
            )
        }

        /// Verify different names produce different worlds.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_STUDIO_WEBKIT_SPIKE_MODE"] == "on"))
        func test_contentWorld_differentNamesProduceDifferentWorlds() async {
            // Arrange
            let worldA = WKContentWorld.world(name: "agentStudioBridge")
            let worldC = WKContentWorld.world(name: "differentWorld")

            // Assert
            #expect(!(worldA === worldC), "Different content world names should produce different world objects")
        }

        // MARK: - Item 2: callJavaScript with content world targeting

        /// Verify that callJavaScript in one content world cannot see globals
        /// set in another content world (JS namespace isolation).
        ///
        /// Strategy: Set a global in bridge world, then try to read it from page world
        /// via postMessage. If isolation works, page world won't see the variable.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_STUDIO_WEBKIT_SPIKE_MODE"] == "on"))
        func test_callJavaScript_contentWorldIsolation_globalsDoNotLeak() async throws {
            // Arrange -- handlers in both worlds
            let bridgeWorld = WKContentWorld.world(name: "testBridgeIsolation")
            let bridgeHandler = WebKitScriptMessageRecorder()
            let pageHandler = WebKitScriptMessageRecorder()

            var config = WebPageTestHarness.makeConfiguration()
            // Register handler in bridge world
            config.userContentController.add(bridgeHandler, contentWorld: bridgeWorld, name: "bridgeProbe")
            // Register handler in page world
            config.userContentController.add(pageHandler, contentWorld: .page, name: "pageProbe")
            config.urlSchemeHandlers[URLScheme("agentstudio")!] = BlankPageSchemeHandler()

            try await WebPageTestHarness.withManagedPage(
                WebPage(
                    configuration: config,
                    navigationDecider: WebviewNavigationDecider(),
                    dialogPresenter: WebviewDialogHandler()
                )
            ) { page in
                _ = page.load(URL(string: "agentstudio://app/blank.html")!)
                await waitForPageLoad(page)

                // Act -- set a global in bridge world. Awaiting callJavaScript is the
                // barrier; evaluations in one content world are ordered.
                _ = try await page.callJavaScript(
                    "window.__spikeVar = 'bridge-only'",
                    contentWorld: bridgeWorld
                )

                // Read from bridge world -- should see it
                _ = try await page.callJavaScript(
                    "window.webkit.messageHandlers.bridgeProbe.postMessage(window.__spikeVar || 'NOT_FOUND')",
                    contentWorld: bridgeWorld
                )
                await bridgeHandler.waitForMessages(atLeast: 1)

                // Read from page world -- should NOT see it
                _ = try await page.callJavaScript(
                    "window.webkit.messageHandlers.pageProbe.postMessage(window.__spikeVar || 'NOT_FOUND')"
                    // no contentWorld = page world
                )
                await pageHandler.waitForMessages(atLeast: 1)

                // Assert
                #expect(bridgeHandler.receivedMessages.count == 1)
                #expect(
                    bridgeHandler.receivedMessages.first as? String == "bridge-only",
                    "Bridge world should see its own global variable")

                #expect(pageHandler.receivedMessages.count == 1)
                #expect(
                    pageHandler.receivedMessages.first as? String == "NOT_FOUND",
                    "Page world should NOT see bridge world's global variable (isolation)")
            }
        }

        // MARK: - Item 3: WKUserScript with content world injection

        /// Verify that a WKUserScript injected into a specific content world runs
        /// in that world and is isolated from the page world.
        ///
        /// Strategy: Inject a user script in bridge world that sets a global flag,
        /// then use message handlers in both worlds to verify the flag is only
        /// visible in the bridge world.
        ///
        /// Design doc section 11.2: WKUserScript takes content world in its initializer
        /// via the `in:` parameter label.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_STUDIO_WEBKIT_SPIKE_MODE"] == "on"))
        func test_userScript_contentWorldInjection_isolatedFromPageWorld() async throws {
            // Arrange
            let world = WKContentWorld.world(name: "testBridgeUserScript")
            let bridgeHandler = WebKitScriptMessageRecorder()
            let pageHandler = WebKitScriptMessageRecorder()

            var config = WebPageTestHarness.makeConfiguration()

            // Inject user script in bridge world that sets a flag
            let script = WKUserScript(
                source: "window.__testFlag = true;",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: world
            )
            config.userContentController.addUserScript(script)

            // Register handlers in both worlds for verification
            config.userContentController.add(bridgeHandler, contentWorld: world, name: "bridgeProbe")
            config.userContentController.add(pageHandler, contentWorld: .page, name: "pageProbe")
            config.urlSchemeHandlers[URLScheme("agentstudio")!] = BlankPageSchemeHandler()

            try await WebPageTestHarness.withManagedPage(
                WebPage(
                    configuration: config,
                    navigationDecider: WebviewNavigationDecider(),
                    dialogPresenter: WebviewDialogHandler()
                )
            ) { page in
                // Act -- load page to trigger user script injection
                _ = page.load(URL(string: "agentstudio://app/blank.html")!)
                await waitForPageLoad(page)

                // Read flag from bridge world
                _ = try await page.callJavaScript(
                    "window.webkit.messageHandlers.bridgeProbe.postMessage(String(window.__testFlag))",
                    contentWorld: world
                )
                await bridgeHandler.waitForMessages(atLeast: 1)

                // Read flag from page world
                _ = try await page.callJavaScript(
                    "window.webkit.messageHandlers.pageProbe.postMessage(String(window.__testFlag))"
                    // no contentWorld = page world
                )
                await pageHandler.waitForMessages(atLeast: 1)

                // Assert -- bridge world should see the flag
                #expect(bridgeHandler.receivedMessages.count == 1)
                #expect(
                    bridgeHandler.receivedMessages.first as? String == "true",
                    "WKUserScript injected with `in: world` should set __testFlag in bridge world")

                // Assert -- page world should NOT see the flag
                #expect(pageHandler.receivedMessages.count == 1)
                #expect(
                    pageHandler.receivedMessages.first as? String == "undefined",
                    "Page world should NOT see __testFlag set by bridge-world WKUserScript (isolation)")
            }
        }

        // MARK: - Item 4: Message handler scoped to content world

        /// Verify that a message handler registered in a specific content world
        /// receives messages posted from that world.
        ///
        /// Design doc section 11.1 layer 2: "Only bridge-world scripts can post
        /// to the rpc handler."
        @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_STUDIO_WEBKIT_SPIKE_MODE"] == "on"))
        func test_messageHandler_bridgeWorldCanPost() async throws {
            // Arrange
            let world = WKContentWorld.world(name: "testBridgeMsgHandler")
            let handler = WebKitScriptMessageRecorder()

            let config = WebPageTestHarness.makeConfiguration()
            config.userContentController.add(handler, contentWorld: world, name: "rpc")

            try await WebPageTestHarness.withManagedPage(
                WebPage(
                    configuration: config,
                    navigationDecider: WebviewNavigationDecider(),
                    dialogPresenter: WebviewDialogHandler()
                )
            ) { page in
                _ = page.load(URL(string: "about:blank")!)
                await waitForPageLoad(page)

                // Act -- post message FROM the bridge world
                _ = try await page.callJavaScript(
                    "window.webkit.messageHandlers.rpc.postMessage('hello')",
                    contentWorld: world
                )
                await handler.waitForMessages(atLeast: 1)

                // Assert -- handler received the message
                #expect(
                    handler.receivedMessages.count == 1, "Message posted from bridge world should reach the handler")
                #expect(handler.receivedMessages.first as? String == "hello", "Message body should be the posted value")
            }
        }

        /// Verify that the page world cannot post to a message handler registered
        /// in a different content world.
        ///
        /// The handler `rpc` is only registered in the bridge world. Page world
        /// should not be able to access `window.webkit.messageHandlers.rpc`.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_STUDIO_WEBKIT_SPIKE_MODE"] == "on"))
        func test_messageHandler_pageWorldCannotAccessBridgeHandler() async throws {
            // Arrange
            let world = WKContentWorld.world(name: "testBridgeMsgHandlerIsolation")
            let handler = WebKitScriptMessageRecorder()

            let config = WebPageTestHarness.makeConfiguration()
            config.userContentController.add(handler, contentWorld: world, name: "rpc")

            try await WebPageTestHarness.withManagedPage(
                WebPage(
                    configuration: config,
                    navigationDecider: WebviewNavigationDecider(),
                    dialogPresenter: WebviewDialogHandler()
                )
            ) { page in
                _ = page.load(URL(string: "about:blank")!)
                await waitForPageLoad(page)

                // Act -- attempt to access the handler from page world using optional chaining
                // to avoid throwing if the handler doesn't exist
                _ = try? await page.callJavaScript(
                    "window.webkit?.messageHandlers?.rpc?.postMessage('evil')"
                    // no contentWorld = page world
                )

                // Barrier -- post a LEGAL message from the bridge world and await it.
                // Delivery to one handler is ordered and the page-world attempt was
                // awaited first, so anything it managed to post would already be here
                // by the time this arrives. That is an ordering fact; a yield budget
                // or a sleep would only have been a guess about machine speed.
                _ = try await page.callJavaScript(
                    "window.webkit.messageHandlers.rpc.postMessage('bridge-world-probe')",
                    contentWorld: world
                )
                await handler.waitForMessages(atLeast: 1)

                // Assert -- handler should NOT have received a message from page world
                #expect(
                    handler.receivedMessages.count == 1,
                    "Page world should NOT be able to post to a bridge-world-scoped message handler")
                #expect(
                    handler.receivedMessages.first as? String == "bridge-world-probe",
                    "The only message delivered should be the bridge world's own probe")
            }
        }

        // MARK: - Helpers

        /// Create a WebPage with a scheme handler for tests that need a real
        /// HTML document.
        private func makeSchemeServedPage() -> WebPage {
            var config = WebPageTestHarness.makeConfiguration()
            config.urlSchemeHandlers[URLScheme("agentstudio")!] = BlankPageSchemeHandler()
            return WebPage(
                configuration: config,
                navigationDecider: WebviewNavigationDecider(),
                dialogPresenter: WebviewDialogHandler()
            )
        }

        /// Suspends until the page's own navigation completes.
        private func waitForPageLoad(_ page: WebPage) async {
            await WebPageEventWaits.waitForNavigationToFinish(page)
        }

    }

}
