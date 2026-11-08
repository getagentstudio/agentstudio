import AgentStudioAppIPC
import AgentStudioIPCTransport
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

    @Test("drawer.browse opens new, added and reused tabs in a main pane's drawer, and refusals change nothing")
    func drawerBrowseOpensTabsAndRefusesWithoutChanges() async throws {
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)
            let before = harness.workspaceFacts()
            func browse(_ page: JSONValue, parent: UUID) async throws -> JSONRPCResponseMessage {
                try await harness.response(
                    token: token, method: "drawer.browse",
                    params: .object([
                        "parentPaneHandle": .string(parent.uuidString),
                        "page": page,
                        "correlationId": .string(UUIDv7.generate().uuidString),
                    ]))
            }
            func opened(_ url: String) async throws -> IPCDrawerBrowseResult {
                let response = try await browse(
                    .object(["kind": .string("web"), "url": .string(url)]), parent: harness.mainPaneId)
                let result = try #require(response.result, "drawer.browse: \(String(describing: response.error))")
                return try JSONDecoder().decode(IPCDrawerBrowseResult.self, from: JSONEncoder().encode(result))
            }

            let first = try await opened("https://example.com/one")
            let second = try await opened("https://example.com/two")
            let again = try await opened("https://example.com/one")

            #expect([first.tab, second.tab, again.tab] == [.newBrowser, .newTab, .reusedTab])
            #expect(second.childPaneId == first.childPaneId && again.childPaneId == first.childPaneId)
            #expect([first.notice, second.notice, again.notice] == [.posted, .posted, .posted])
            let afterOpens = harness.workspaceFacts()
            #expect(afterOpens.drawerChildIds == before.drawerChildIds + [first.childPaneId])
            #expect(afterOpens.isDrawerExpanded == before.isDrawerExpanded)
            #expect(afterOpens.activeDrawerChildId == before.activeDrawerChildId)
            #expect(afterOpens.activePaneId == before.activePaneId)

            // Refusals change nothing: an unsupported page, a target that is a
            // drawer child rather than a main pane, and a caller with no credential.
            let unsupported = try await browse(
                .object(["kind": .string("localHTML"), "path": .string("/tmp/notes.md")]), parent: harness.mainPaneId)
            #expect(unsupported.result == nil)
            let drawerChild = try await browse(
                .object(["kind": .string("web"), "url": .string("https://example.com/x")]),
                parent: harness.drawerChildPaneId)
            #expect(drawerChild.result == nil)
            #expect(drawerChild.error?.data == .object(["reason": .string("notMainPane")]))
            let anonymous = try await harness.unauthenticatedResponse(
                method: "drawer.browse",
                params: .object([
                    "parentPaneHandle": .string(harness.mainPaneId.uuidString),
                    "page": .object(["kind": .string("web"), "url": .string("https://example.com/y")]),
                    "correlationId": .string(UUIDv7.generate().uuidString),
                ]))
            #expect(anonymous.result == nil)
            #expect(anonymous.error?.code == -32_001, "no credential: \(String(describing: anonymous.error))")
            #expect(harness.workspaceFacts() == afterOpens)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    /// R18 and U8: an agent bound to one main pane may name another main
    /// pane; the page and its notice land in that pane, and the caller's own
    /// pane is unchanged.
    @Test("drawer.browse from an agent in pane A opens in main pane B, with the notice in B and A unchanged")
    func drawerBrowseOpensInAnotherMainPane() async throws {
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        do {
            // Arrange: the agent is bound to the main pane, A; B is the other main pane.
            let tokenA = try harness.agentToken(boundTo: harness.mainPaneId)
            let tokenB = try harness.agentToken(boundTo: harness.otherPaneId)
            let factsA = harness.workspaceFacts()
            let drawerB = harness.store.paneAtom.pane(harness.otherPaneId)?.drawer?.paneIds ?? []
            func browserNotices(_ token: AgentStudioIPCSubjectToken) async throws -> [IPCPaneMessageDetail] {
                let response = try await harness.response(
                    token: token, method: "pane.context.get",
                    params: try JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)))
                let result = try #require(response.result, "pane.context.get: \(String(describing: response.error))")
                let context = try JSONDecoder().decode(
                    IPCPaneContextGetResult.self, from: JSONEncoder().encode(result))
                return context.messages.filter { $0.body.hasSuffix("in the drawer browser") }
            }

            // Act
            let response = try await harness.response(
                token: tokenA, method: "drawer.browse",
                params: .object([
                    "parentPaneHandle": .string(harness.otherPaneId.uuidString),
                    "page": .object(["kind": .string("web"), "url": .string("https://example.com/b")]),
                    "correlationId": .string(UUIDv7.generate().uuidString),
                ]))

            // Assert
            let result = try #require(response.result, "drawer.browse: \(String(describing: response.error))")
            let opened = try JSONDecoder().decode(IPCDrawerBrowseResult.self, from: JSONEncoder().encode(result))
            #expect(opened.parentPaneId == harness.otherPaneId)
            #expect(opened.tab == .newBrowser)
            #expect(opened.notice == .posted)
            #expect(harness.store.paneAtom.pane(harness.otherPaneId)?.drawer?.paneIds == drawerB + [opened.childPaneId])
            #expect(try await browserNotices(tokenB).map(\.actions) == [[.goToPane(paneId: opened.childPaneId)]])
            #expect(try await browserNotices(tokenA).isEmpty)
            // Pane A, the caller's own pane, is unchanged: its drawer, the
            // active tab and the active pane. Only B gained a pane.
            let after = harness.workspaceFacts()
            #expect(after.drawerChildIds == factsA.drawerChildIds)
            #expect(after.isDrawerExpanded == factsA.isDrawerExpanded)
            #expect(after.activeDrawerChildId == factsA.activeDrawerChildId)
            #expect(after.activeTabId == factsA.activeTabId)
            #expect(after.activePaneId == factsA.activePaneId)
            #expect(after.paneIds == factsA.paneIds.union([opened.childPaneId]))
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("a drawer browser closed between browses is replaced, and its notice with it")
    func drawerBrowseAfterBrowserClosedOpensNewBrowserAndReplacesNotice() async throws {
        let harness = try await PaneAgentControlHarness.make(channel: .debug)
        do {
            // Arrange: one browse leaves a drawer browser and its notice.
            let token = try harness.agentToken(boundTo: harness.mainPaneId)
            func opened(_ url: String) async throws -> IPCDrawerBrowseResult {
                let response = try await harness.response(
                    token: token, method: "drawer.browse",
                    params: .object([
                        "parentPaneHandle": .string(harness.mainPaneId.uuidString),
                        "page": .object(["kind": .string("web"), "url": .string(url)]),
                        "correlationId": .string(UUIDv7.generate().uuidString),
                    ]))
                let result = try #require(response.result, "drawer.browse: \(String(describing: response.error))")
                return try JSONDecoder().decode(IPCDrawerBrowseResult.self, from: JSONEncoder().encode(result))
            }
            /// Every browser notice in the main pane, unread or settled.
            func browserNotices() async throws -> [IPCPaneMessageDetail] {
                let response = try await harness.response(
                    token: token, method: "pane.context.get",
                    params: try JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)))
                let result = try #require(response.result, "pane.context.get: \(String(describing: response.error))")
                let context = try JSONDecoder().decode(
                    IPCPaneContextGetResult.self, from: JSONEncoder().encode(result))
                return context.messages.filter { $0.body.hasSuffix("in the drawer browser") }
            }
            let first = try await opened("https://example.com/one")
            try #require(first.tab == .newBrowser)
            let firstNotices = try await browserNotices()
            try #require(firstNotices.map(\.actions) == [[.goToPane(paneId: first.childPaneId)]])
            try #require(firstNotices.map(\.shape) == [.notice(state: .unread)])
            let firstNoticeId = firstNotices[0].id

            // Act: the browser is closed through the workspace route, then the
            // agent browses again.
            let closed = await harness.commandHarness.executor.execute(
                .removeDrawerPane(parentPaneId: harness.mainPaneId, drawerPaneId: first.childPaneId))
            try #require(closed)
            try #require(harness.store.paneAtom.pane(first.childPaneId) == nil)
            let second = try await opened("https://example.com/two")

            // Assert: a new browser, not the closed one; its notice is the only
            // unread one, and the closed browser's notice was withdrawn.
            #expect(second.tab == .newBrowser)
            #expect(second.childPaneId != first.childPaneId)
            #expect(harness.store.paneAtom.pane(second.childPaneId) != nil)
            #expect(second.notice == .posted)
            let noticesAfterReplacement = try await browserNotices()
            let unread = noticesAfterReplacement.filter { $0.shape == .notice(state: .unread) }
            #expect(unread.map(\.actions) == [[.goToPane(paneId: second.childPaneId)]])
            #expect(
                noticesAfterReplacement.first { $0.id == firstNoticeId }?.shape == .notice(state: .withdrawn))
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }
}
