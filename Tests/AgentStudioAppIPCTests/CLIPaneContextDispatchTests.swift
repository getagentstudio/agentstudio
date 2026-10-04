import AgentStudioCore
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("Pane CLI compiled dispatch", .serialized)
struct CLIPaneContextDispatchTests {
    @Test(
        "each pane verb has offline help", arguments: ["notify", "ask", "withdraw", "answers", "line", "title", "pane"])
    func paneVerbHelpIsOffline(verb: String) async throws {
        try await withS5PaneCLIContext { context in
            let output = try await context.run([verb, "--help"], useStore: false)
            #expect(output.terminationStatus == 0)
            #expect(output.standardError.isEmpty)
            let text = try #require(String(bytes: output.standardOutput, encoding: .utf8))
            #expect(text.contains(verb))
            #expect(context.port.wire.connections == 0)
            #expect(context.port.wire.methods.isEmpty)
        }
    }

    @Test("retired methods fail locally before opening a socket", arguments: ["session.message", "session.report"])
    func retiredMethodIsLocallyUnknown(method: String) async throws {
        try await withS5PaneCLIContext { context in
            let output = try await context.run([method])
            #expect(output.terminationStatus != 0)
            let text = try #require(String(bytes: output.standardError, encoding: .utf8))
            #expect(text.contains("unknownMethod"))
            #expect(text.contains("closest methods:"))
            #expect(!text.contains("closest methods: session.message"))
            #expect(!text.contains("closest methods: session.report"))
            #expect(context.port.wire.connections == 0)
            #expect(context.port.wire.methods.isEmpty)
        }
    }

    @Test("offline overview lists replacement methods and no retired surface")
    func overviewRetiresLegacyMethods() async throws {
        try await withS5PaneCLIContext { context in
            let output = try await context.run(["help"], useStore: false)
            #expect(output.terminationStatus == 0)
            let text = try #require(String(bytes: output.standardOutput, encoding: .utf8))
            #expect(!text.contains("session.message"))
            #expect(!text.contains("session.report"))
            #expect(text.contains("pane.message.send"))
            #expect(text.contains("pane.message.ask"))
            #expect(text.contains("session.event"))
            #expect(text.contains("session.query"))
            #expect(context.port.wire.connections == 0)
        }
    }

    @Test("stalled authentication is not sent and a stalled command reply has an unknown outcome", arguments: [1, 2])
    func clientClassifiesStalledFrames(replyID: Int) async throws {
        let hold = HeldStep<Data>("S5 real server reply held through the client deadline")
        try await withS5PaneCLIContext(heldReply: (.number(replyID), hold)) { context in
            let observed = try await valueFromDedicatedThread {
                let descriptors = try IPCCompiledInvocationResolver().resolve(
                    arguments: ["pane.context.get"], authenticated: true,
                    inputs: .init(examples: .init(illustrativeIdentifier: UUIDv7.generate())))
                let parameters = IPCPaneContextGetParams(handle: "self", page: .first)
                let bytes = try JSONEncoder().encode(parameters)
                guard let json = String(bytes: bytes, encoding: .utf8) else { throw S5CLIFixtureError.invalidJSON }
                let invocation = try IPCDescriptorInvocationParser.parse(
                    ["pane.context.get", "--json", json], descriptors: descriptors,
                    correlationIDGenerator: { UUIDv7.generate() })
                let client = AgentStudioIPCClient(
                    configuration: .init(
                        socketPath: context.fixture.paths.socketURL.path,
                        authToken: context.environment["AGENTSTUDIO_PANE_TOKEN"]),
                    descriptors: descriptors, deadline: CallDeadline(limit: .seconds(1)))
                do {
                    _ = try client.call(invocation)
                    return Optional<IPCDescriptorClientFailure>.none
                } catch let error as IPCDescriptorClientFailure { return Optional(error) }
            }
            let heldBytes = try #require(hold.recordedArrivals.first)
            #expect(!heldBytes.isEmpty)
            let failure = try #require(observed)
            #expect(failure.disposition == (replyID == 1 ? .notSubmitted : .deliveryUncertain))
            #expect(failure.reason == (replyID == 1 ? .authenticationTransport : .commandResponseMissing))
            #expect(context.port.wire.connections == 1)
            let methods = replyID == 1 ? ["auth.login"] : ["auth.login", "pane.context.get"]
            #expect(context.port.wire.methods == methods)
            hold.release()
        }
    }

    @Test("an ordinary pane verb ends with outcomeUnknown when its real reply stalls")
    func ordinaryVerbUsesItsAbsoluteDeadline() async throws {
        let hold = HeldStep<Data>("S5 ordinary pane reply before physical send")
        try await withS5PaneCLIContext(heldReply: (.number(2), hold)) { context in
            let output = try await context.run(["pane"])
            #expect(output.terminationStatus != 0)
            let failureText = try #require(String(bytes: output.standardError, encoding: .utf8))
            #expect(failureText.contains("outcomeUnknown"))
            let bytes = try #require(hold.recordedArrivals.first)
            #expect(!bytes.isEmpty)
            #expect(context.port.wire.connections == 1)
            #expect(context.port.wire.methods == ["auth.login", "pane.context.get"])
            #expect(context.port.messages.isEmpty)
            hold.release()
        }
    }

    @Test("a fresh ordered title uses one connection and only authentication, claim and write")
    func orderedTitleIsOneCompiledExchange() async throws {
        try await withS5PaneCLIContext { context in
            let output = try await context.run(["title", "compiled title"])
            #expect(output.terminationStatus == 0)
            #expect(context.port.wire.connections == 1)
            #expect(context.port.wire.methods == ["auth.login", "pane.writer.claimEpoch", "pane.title.set"])
            let title = try await context.title()
            #expect(title == "compiled title")
        }
    }

    @Test("notify reaches the pane without discovery or an ordering claim")
    func notifyIsOneCompiledExchange() async throws {
        try await withS5PaneCLIContext { context in
            let output = try await context.run(["notify", "compiled notice"], useStore: false)
            #expect(output.terminationStatus == 0)
            #expect(context.port.wire.connections == 1)
            #expect(context.port.wire.methods == ["auth.login", "pane.message.send"])
        }
    }

    @Test("an own-pane CLI notice round-trips its exact Unicode and embedded newline")
    func noticeUnicodeBodyRoundTripsThroughCLI() async throws {
        try await withS5PaneCLIContext { context in
            let text = "migration \u{1F680} done\nsecond line \u{00E9}\u{4E2D}"
            let output = try await context.run(["notify", text], useStore: false)
            #expect(output.terminationStatus == 0)
            guard output.terminationStatus == 0 else { return }
            let sent = try JSONDecoder().decode(IPCPaneMessageSendResult.self, from: output.standardOutput)
            guard case .created(let id) = sent else {
                Issue.record("Expected a created notice")
                return
            }
            let read = try await context.run(["pane"], useStore: false)
            #expect(read.terminationStatus == 0)
            guard read.terminationStatus == 0 else { return }
            let detail = try JSONDecoder().decode(IPCPaneContextGetResult.self, from: read.standardOutput)
            #expect(detail.messages.map(\.body) == [text])
            #expect(detail.messages.first?.shape == .notice(state: .unread))
            #expect(detail.messages.first?.id == id)
            let firstMessage = try #require(detail.messages.first)
            guard case .session = firstMessage.sender else {
                Issue.record("Expected bound session sender")
                return
            }
            #expect(context.port.wire.methods == ["auth.login", "pane.message.send", "auth.login", "pane.context.get"])
        }
    }

    @Test("line builds only its epoch claim and write on one authenticated connection")
    func lineIsOneCompiledExchange() async throws {
        try await withS5PaneCLIContext { context in
            let output = try await context.run(["line", "compiled line", "--working"])
            #expect(output.terminationStatus == 0)
            #expect(context.port.wire.connections == 1)
            #expect(context.port.wire.methods == ["auth.login", "pane.writer.claimEpoch", "pane.line.set"])
            let read = await context.domain.service.readDetail(
                .init(paneId: PaneId(existingUUID: context.domain.paneId), page: .first))
            guard case .detail(let detail) = read else {
                Issue.record("Missing real line detail")
                return
            }
            #expect(detail.agentLine?.summary == "compiled line")
        }
    }

    @Test("a nonblocking ask and its withdrawal retain the provider writer and compiled routes")
    func askAndWithdrawUseTheirOwningMethods() async throws {
        try await withS5PaneCLIContext { context in
            let asked = try await context.run(["ask", "Continue?"])
            #expect(asked.terminationStatus == 0)
            guard asked.terminationStatus == 0 else { return }
            #expect(context.port.wire.connections == 1)
            #expect(context.port.wire.methods == ["auth.login", "pane.message.send"])
            let message = try #require(context.port.messages.last)
            #expect(message.writer == context.writer)
            #expect(message.body == "Continue?")
            guard case .ask(_, _, .nonBlocking) = message.shape else {
                Issue.record("An ordinary ask must be nonblocking")
                return
            }
            let withdrawn = try await context.run(["withdraw", message.messageId.uuidString])
            #expect(withdrawn.terminationStatus == 0)
            #expect(context.port.wire.connections == 2)
            #expect(Array(context.port.wire.methods.suffix(2)) == ["auth.login", "pane.message.withdraw"])
        }
    }

    @Test("a blocking ask uses its requested deadline and expired never becomes permission")
    func blockingAskExpirationNeverGrants() async throws {
        try await withS5PaneCLIContext { context in
            let creationTime = context.domain.time.now.addingTimeInterval(-60)
            let output = await context.runWithWallClock(
                ["ask", "Proceed?", "--wait", "--timeout", "30"], now: creationTime)
            #expect((output.standardOutput + output.standardError).contains("expired"))
            #expect(context.port.wire.connections == 1)
            #expect(context.port.wire.methods == ["auth.login", "pane.message.ask"])
            let request = try #require(context.port.asks.last)
            #expect(request.writer == context.writer)
            guard case .ask(_, _, .blocking(let deadline)) = request.shape else {
                Issue.record("--wait must use a blocking ask")
                return
            }
            #expect(deadline == creationTime.addingTimeInterval(30))
        }
    }

    @Test("reset and clear stay ordered writes", arguments: ["title", "line"])
    func clearingUsesTheSameOrderedStream(verb: String) async throws {
        try await withS5PaneCLIContext { context in
            let seedArguments = verb == "title" ? ["title", "before reset"] : ["line", "before clear", "--working"]
            let seed = try await context.run(seedArguments)
            #expect(seed.terminationStatus == 0)
            guard seed.terminationStatus == 0 else { return }
            let clearing = try await context.run([verb, verb == "title" ? "--reset" : "--clear"])
            #expect(clearing.terminationStatus == 0)
            #expect(context.port.wire.connections == 2)
            let method = verb == "title" ? "pane.title.set" : "pane.line.set"
            #expect(Array(context.port.wire.methods.suffix(2)) == ["auth.login", method])
            let read = await context.domain.service.readDetail(
                .init(paneId: PaneId(existingUUID: context.domain.paneId), page: .first))
            guard case .detail(let detail) = read else {
                Issue.record("Missing detail after ordered clear")
                return
            }
            if verb == "title" { #expect(detail.agentTitle == nil) } else { #expect(detail.agentLine == nil) }
        }
    }

    @Test("pane reads its own context on one connection without discovery")
    func paneReadIsOneCompiledExchange() async throws {
        try await withS5PaneCLIContext { context in
            let output = try await context.run(["pane"])
            #expect(output.terminationStatus == 0)
            #expect(context.port.wire.connections == 1)
            #expect(context.port.wire.methods == ["auth.login", "pane.context.get"])
        }
    }
}
