import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

extension WebKitSerializedTests.WebviewPaneControllerTests {
    @Test(
        "an HTTPS browser drawer child is admitted",
        arguments: [AgentStudioIPCChannel.debug, .stable]
    )
    func agentHTTPSBrowserDrawerChildIsAdmitted(channel: AgentStudioIPCChannel) async throws {
        let harness = try await PaneAgentControlHarness.make(channel: channel)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)
            let before = harness.workspaceFacts()
            let browserURL = try #require(URL(string: "https://example.com"))

            let response = try await harness.response(
                token: token, method: "drawer.addPane",
                params: .object([
                    "parentPaneHandle": .string("self"),
                    "content": .object(["kind": .string("browser"), "url": .string(browserURL.absoluteString)]),
                    "correlationId": .string(UUIDv7.generate().uuidString),
                ]))

            let result = try #require(response.result, "drawer.addPane: \(String(describing: response.error))")
            let added = try JSONDecoder().decode(IPCDrawerAddPaneResult.self, from: JSONEncoder().encode(result))
            #expect(added.parentPaneId == harness.mainPaneId)
            let pane = try #require(harness.store.paneAtom.pane(added.childPaneId))
            if case .webview(let state) = pane.content {
                #expect(state.url == browserURL)
            } else {
                Issue.record("Expected HTTPS browser admission to create a webview drawer child")
            }
            let after = harness.workspaceFacts()
            #expect(after.drawerChildIds == before.drawerChildIds + [added.childPaneId])
            #expect(after.isDrawerExpanded == before.isDrawerExpanded)
            #expect(after.activeDrawerChildId == before.activeDrawerChildId)
            #expect(after.activeTabId == before.activeTabId)
            #expect(after.activePaneId == before.activePaneId)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("a second drawer.addPane browser call adds a tab to the drawer's browser and returns it")
    func secondBrowserDrawerCallAddsTabToExistingBrowser() async throws {
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)
            let before = harness.workspaceFacts()

            func addBrowser(_ url: String) async throws -> IPCDrawerAddPaneResult {
                let response = try await harness.response(
                    token: token, method: "drawer.addPane",
                    params: .object([
                        "parentPaneHandle": .string("self"),
                        "content": .object(["kind": .string("browser"), "url": .string(url)]),
                        "correlationId": .string(UUIDv7.generate().uuidString),
                    ]))
                let result = try #require(response.result, "drawer.addPane: \(String(describing: response.error))")
                return try JSONDecoder().decode(IPCDrawerAddPaneResult.self, from: JSONEncoder().encode(result))
            }

            let first = try await addBrowser("https://example.com/first")
            let second = try await addBrowser("https://example.com/second")

            // One browser: the second call returns the first call's child and
            // adds no drawer child; the browser now holds two tabs.
            #expect(second.childPaneId == first.childPaneId)
            let after = harness.workspaceFacts()
            #expect(after.drawerChildIds == before.drawerChildIds + [first.childPaneId])
            let controller = try #require(
                harness.commandHarness.viewRegistry.view(for: first.childPaneId)?
                    .mountedContent(as: WebviewPaneMountView.self)?.controller
            )
            #expect(
                controller.tabList.tabs.map(\.url.absoluteString) == [
                    "https://example.com/first", "https://example.com/second",
                ])
            // Background presentation both times: drawer and focus unchanged.
            #expect(after.isDrawerExpanded == before.isDrawerExpanded)
            #expect(after.activeDrawerChildId == before.activeDrawerChildId)
            #expect(after.activePaneId == before.activePaneId)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }
}
