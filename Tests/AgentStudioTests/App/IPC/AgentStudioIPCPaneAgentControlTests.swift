import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// A1 through the real server: registry, pane-agent authorization, the App's
/// own-pane port over the real pane graph, and the existing handlers, on the
/// debug channel and on the stable channel's registry and exposure rules.
@MainActor
@Suite("App IPC pane-agent control", .serialized)
struct AgentStudioIPCPaneAgentControlTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test(
        "a main-terminal agent runs own-pane commands on its terminal and its drawer child",
        arguments: [AgentStudioIPCChannel.debug, .stable]
    )
    func mainTerminalAgentRunsOwnPaneCommands(channel: AgentStudioIPCChannel) async throws {
        let harness = try await PaneAgentControlHarness.make(channel: channel)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)
            let before = harness.workspaceFacts()

            for target in [harness.mainPaneId, harness.drawerChildPaneId] {
                let send = try await harness.response(
                    token: token, method: "terminal.send",
                    params: .object([
                        "handle": .string(target.uuidString), "input": .string("ls\n"),
                        "correlationId": .string(UUIDv7.generate().uuidString),
                    ]))
                let status = try await harness.response(
                    token: token, method: "terminal.status", params: .object(["handle": .string(target.uuidString)]))
                #expect(send.error == nil, "terminal.send \(target): \(String(describing: send.error))")
                #expect(status.error == nil, "terminal.status \(target): \(String(describing: status.error))")
            }
            let scrolled = try await withIsolatedCommandDispatcher(
                configure: { AppCommandDispatcher.shared.handler = harness.commandHarness.controller },
                body: {
                    try await harness.response(
                        token: token, method: "command.execute",
                        params: try harness.command(
                            .scrollToBottom, arguments: try harness.paneArguments(harness.drawerChildPaneId)))
                })
            let listing = try await harness.response(token: token, method: "pane.list", params: .object([:]))

            #expect(scrolled.error == nil, "scrollToBottom: \(String(describing: scrolled.error))")
            #expect(listing.error == nil)
            let mainCommands = try #require(harness.runtimesByPaneId[harness.mainPaneId]).receivedCommands
            let childCommands = try #require(harness.runtimesByPaneId[harness.drawerChildPaneId]).receivedCommands
            #expect(terminalCommandNames(mainCommands) == ["sendInput(ls\n)"])
            #expect(terminalCommandNames(childCommands) == ["sendInput(ls\n)", "scrollToBottom"])
            #expect(harness.workspaceFacts() == before)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test(
        "everything outside the agent's own pane is refused by name with no effect",
        arguments: [AgentStudioIPCChannel.debug, .stable]
    )
    func outsideOwnPaneIsNotYetAllowed(channel: AgentStudioIPCChannel) async throws {
        let harness = try await PaneAgentControlHarness.make(channel: channel)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)
            let own = harness.mainPaneId.uuidString
            let before = harness.workspaceFacts()

            let otherPaneInput = try await harness.response(
                token: token, method: "terminal.send",
                params: .object([
                    "handle": .string(harness.otherPaneId.uuidString), "input": .string("ls\n"),
                    "correlationId": .string(UUIDv7.generate().uuidString),
                ]))
            let focus = try await harness.response(
                token: token, method: "pane.focus",
                params: .object(["handle": .string(own), "correlationId": .string(UUIDv7.generate().uuidString)]))
            let bridge = try await harness.response(
                token: token, method: "bridge.diff.getPackage", params: .object(["handle": .string(own)]))
            let zoom = try await harness.response(
                token: token, method: "command.execute",
                params: try harness.command(.zoomPane, arguments: try harness.paneArguments(harness.mainPaneId)))
            let split = try await harness.response(
                token: token, method: "command.execute",
                params: try harness.command(.splitRight, arguments: try harness.paneArguments(harness.mainPaneId)))
            let closeSelf = try await harness.response(
                token: token, method: "pane.close",
                params: .object(["handle": .string(own), "correlationId": .string(UUIDv7.generate().uuidString)]))
            let unknown = try await harness.response(token: token, method: "bogus.method", params: .object([:]))

            #expect(PaneAgentRefusal(otherPaneInput) == .notYetAllowed("terminal.send"))
            #expect(PaneAgentRefusal(focus) == .notYetAllowed("pane.focus"))
            #expect(PaneAgentRefusal(bridge) == .notYetAllowed("bridge.diff.getPackage"))
            #expect(PaneAgentRefusal(zoom) == .notYetAllowed("zoomPane"))
            #expect(PaneAgentRefusal(split) == .notYetAllowed("splitRight"))
            #expect(PaneAgentRefusal(closeSelf) == .refusedForAgent("pane.close"))
            #expect(unknown.error?.code == -32_601)
            #expect(try #require(harness.runtimesByPaneId[harness.otherPaneId]).receivedCommands.isEmpty)
            #expect(harness.workspaceFacts() == before)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("stable discovery names the methods and commands it hides, with their eligibility")
    func stableDiscoveryNamesHiddenEntries() async throws {
        let harness = try await PaneAgentControlHarness.make(channel: .stable)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)

            let capabilities = try await harness.response(
                token: token, method: "system.capabilities", params: .object([:]))
            let commandList = try await harness.response(token: token, method: "command.list", params: .object([:]))
            let methodCatalog = try JSONDecoder().decode(
                IPCMethodCatalogResult.self,
                from: JSONEncoder().encode(
                    try #require(capabilities.result, "\(String(describing: capabilities.error))")))
            let commandCatalog = try JSONDecoder().decode(
                IPCCommandCatalogResult.self,
                from: JSONEncoder().encode(try #require(commandList.result, "\(String(describing: commandList.error))"))
            )

            // Hidden on stable: listed by name, never as an invocable entry.
            #expect(
                methodCatalog.recognizedUnexposedMethods.contains(
                    IPCRecognizedUnexposedName(name: "pane.focus", agentEligibility: .notYetAllowed)))
            #expect(!methodCatalog.methods.contains { $0.name == "pane.focus" })
            #expect(
                commandCatalog.recognizedUnexposedCommands.contains(
                    IPCRecognizedUnexposedName(name: "splitRight", agentEligibility: .notYetAllowed)))
            #expect(!commandCatalog.commands.contains { $0.id.rawValue == "splitRight" })
            // Exposed on stable: invocable, not listed as hidden.
            #expect(!methodCatalog.recognizedUnexposedMethods.contains { $0.name == "terminal.send" })
            #expect(!commandCatalog.recognizedUnexposedCommands.contains { $0.name == "scrollToBottom" })
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test(
        "a drawer-terminal agent owns only itself and cannot add drawer children",
        arguments: [AgentStudioIPCChannel.debug, .stable]
    )
    func drawerTerminalAgentOwnsOnlyItself(channel: AgentStudioIPCChannel) async throws {
        let harness = try await PaneAgentControlHarness.make(channel: channel)
        do {
            let token = try harness.agentToken(boundTo: harness.drawerChildPaneId)
            let before = harness.workspaceFacts()

            let ownStatus = try await harness.response(
                token: token, method: "terminal.status",
                params: .object(["handle": .string(harness.drawerChildPaneId.uuidString)]))
            let parentStatus = try await harness.response(
                token: token, method: "terminal.status",
                params: .object(["handle": .string(harness.mainPaneId.uuidString)]))
            let closeSelf = try await harness.response(
                token: token, method: "command.execute",
                params: try harness.command(
                    .closeDrawerPane,
                    arguments: try harness.drawerChildArguments(
                        parent: harness.mainPaneId, child: harness.drawerChildPaneId)))
            let addDrawerChild = try await harness.response(
                token: token, method: "drawer.addPane",
                params: .object([
                    "parentPaneHandle": .string("self"), "correlationId": .string(UUIDv7.generate().uuidString),
                ]))

            #expect(ownStatus.error == nil)
            #expect(PaneAgentRefusal(parentStatus) == .notYetAllowed("terminal.status"))
            #expect(PaneAgentRefusal(closeSelf) == .notYetAllowed("closeDrawerPane"))
            #expect(PaneAgentRefusal(addDrawerChild) == .refusedForAgent("drawer.addPane"))
            #expect(harness.workspaceFacts() == before)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test(
        "established session methods keep bound-pane admission for pane agents",
        arguments: [AgentStudioIPCChannel.debug, .stable]
    )
    func establishedSessionMethodsAreUnchanged(channel: AgentStudioIPCChannel) async throws {
        let harness = try await PaneAgentControlHarness.make(channel: channel)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)

            let own = try await harness.response(
                token: token, method: "session.query",
                params: .object(["handle": .string(harness.mainPaneId.uuidString)]))
            let drawerChild = try await harness.response(
                token: token, method: "session.query",
                params: .object(["handle": .string(harness.drawerChildPaneId.uuidString)]))

            #expect(own.error == nil, "session.query own: \(String(describing: own.error))")
            #expect(drawerChild.error?.code == -32_002)
            #expect(PaneAgentRefusal(drawerChild)?.reason == "missingGrant")
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test(
        "an agent adds a background drawer child, targets it by the returned handle, and cannot add Bridge content",
        arguments: [AgentStudioIPCChannel.debug, .stable]
    )
    func agentAddsAndTargetsBackgroundDrawerChild(channel: AgentStudioIPCChannel) async throws {
        let harness = try await PaneAgentControlHarness.make(channel: channel)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)
            let before = harness.workspaceFacts()

            let add = try await harness.response(
                token: token, method: "drawer.addPane",
                params: .object([
                    "parentPaneHandle": .string("self"),
                    "content": .object(["kind": .string("terminal")]),
                    "correlationId": .string(UUIDv7.generate().uuidString),
                ]))
            let added = try decodeAddResult(add)
            let addedPane = try #require(harness.store.paneAtom.pane(added.childPaneId))
            if case .terminal = addedPane.content {
                // This targeting case stays in the non-WebKit lane.
            } else {
                Issue.record("Expected background targeting fixture to create a terminal drawer child")
            }
            let snapshot = try await harness.response(
                token: token, method: "pane.snapshot", params: .object(["handle": .string(added.childHandle)]))
            let bridge = try await harness.response(
                token: token, method: "drawer.addPane",
                params: .object([
                    "parentPaneHandle": .string("self"), "content": .object(["kind": .string("bridge")]),
                    "correlationId": .string(UUIDv7.generate().uuidString),
                ]))

            #expect(added.parentPaneId == harness.mainPaneId)
            #expect(snapshot.error == nil, "pane.snapshot child: \(String(describing: snapshot.error))")
            #expect(PaneAgentRefusal(bridge) == .refusedForAgent("drawer.addPane"))
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

    private func decodeAddResult(_ response: JSONRPCResponseMessage) throws -> IPCDrawerAddPaneResult {
        let result = try #require(response.result, "drawer.addPane: \(String(describing: response.error))")
        return try JSONDecoder().decode(IPCDrawerAddPaneResult.self, from: JSONEncoder().encode(result))
    }

    @Test(
        "a drawer close naming a sibling as the parent is refused and closes nothing",
        arguments: [AgentStudioIPCChannel.debug, .stable]
    )
    func mismatchedDrawerCloseIsRefused(channel: AgentStudioIPCChannel) async throws {
        let harness = try await PaneAgentControlHarness.make(channel: channel)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)
            let sibling = try #require(harness.store.addDrawerPane(to: harness.mainPaneId))
            let before = harness.workspaceFacts()

            // Both panes are inside the agent's own pane, so admission passes; the
            // sibling is not the child's parent, so the effect owner refuses.
            let close = try await withIsolatedCommandDispatcher(
                configure: { AppCommandDispatcher.shared.handler = harness.commandHarness.controller },
                body: {
                    try await harness.response(
                        token: token, method: "command.execute",
                        params: try harness.command(
                            .closeDrawerPane,
                            arguments: try harness.drawerChildArguments(
                                parent: harness.drawerChildPaneId, child: sibling.id)))
                })

            #expect(close.result == nil)
            #expect(close.error?.code == -32_005)
            #expect(harness.store.paneAtom.pane(sibling.id)?.parentPaneId == harness.mainPaneId)
            #expect(harness.workspaceFacts() == before)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test(
        "an agent closes its own drawer child through the catalog command",
        arguments: [AgentStudioIPCChannel.debug, .stable]
    )
    func agentClosesItsOwnDrawerChild(channel: AgentStudioIPCChannel) async throws {
        let harness = try await PaneAgentControlHarness.make(channel: channel)
        do {
            let token = try harness.agentToken(boundTo: harness.mainPaneId)

            let close = try await withIsolatedCommandDispatcher(
                configure: { AppCommandDispatcher.shared.handler = harness.commandHarness.controller },
                body: {
                    try await harness.response(
                        token: token, method: "command.execute",
                        params: try harness.command(
                            .closeDrawerPane,
                            arguments: try harness.drawerChildArguments(
                                parent: harness.mainPaneId, child: harness.drawerChildPaneId)))
                })

            #expect(close.error == nil, "closeDrawerPane: \(String(describing: close.error))")
            #expect(harness.store.paneAtom.pane(harness.drawerChildPaneId) == nil)
            #expect(harness.store.paneAtom.pane(harness.mainPaneId) != nil)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }
}

/// Names only the terminal commands a runtime received; runtime commands are
/// not Equatable.
@MainActor
func terminalCommandNames(_ envelopes: [RuntimeCommandEnvelope]) -> [String] {
    envelopes.map { envelope in
        switch envelope.command {
        case .terminal(.sendInput(let input)): "sendInput(\(input))"
        case .terminal(.scrollToBottom): "scrollToBottom"
        case .terminal(.scrollPageFractional(let fraction)): "scrollPageFractional(\(fraction))"
        case .terminal(.jumpToPrompt(let delta)): "jumpToPrompt(\(delta))"
        default: "other"
        }
    }
}
