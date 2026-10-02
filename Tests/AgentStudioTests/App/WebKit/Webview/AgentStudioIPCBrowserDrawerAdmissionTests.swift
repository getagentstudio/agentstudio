import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

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
}
