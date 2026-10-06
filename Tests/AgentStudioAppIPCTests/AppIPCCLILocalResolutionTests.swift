import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("App IPC CLI compiled resolution", .serialized)
struct AppIPCCLILocalResolutionTests {
    @Test(
        "compiled method families send one login and one call on one connection",
        arguments: [
            ["terminal.status", "--handle", "self"],
            ["pane.close", "--handle", "self"],
            ["drawer.toggle", "--parent-pane-handle", "self"],
            ["session.query", "--handle", "self"],
            ["system.identify"],
        ])
    func compiledMethodFamiliesSkipDiscovery(arguments: [String]) async throws {
        let observed = try await runRecordedCLIInvocation(.init(arguments: arguments))

        // The fake domain ports may refuse a target. The real transport still
        // proves resolution, login, and submission without catalog traffic.
        #expect(observed.acceptedConnections == 1)
        #expect(observed.requests.map(\.method) == ["auth.login", arguments[0]])
    }

    @Test(
        "unknown names fail locally without any connection or request", arguments: ["terminal.sned", "future.method"])
    func unknownNamesNeverContactServer(method: String) async throws {
        let observed = try await runRecordedCLIInvocation(.init(arguments: [method]))

        #expect(observed.outcome.exitCode != 0)
        #expect(observed.outcome.standardError.contains("unknownMethod"))
        #expect(observed.acceptedConnections == 0)
        #expect(observed.requests.isEmpty)
    }

    @Test("invalid compiled arguments fail before login or discovery")
    func invalidCompiledArgumentsNeverContactServer() async throws {
        let observed = try await runRecordedCLIInvocation(
            .init(arguments: ["terminal.send", "--handle", "self"]))

        #expect(observed.outcome.exitCode != 0)
        #expect(observed.acceptedConnections == 0)
        #expect(observed.requests.isEmpty)
    }

    @Test(
        "explicit capabilities accepts every empty parameter spelling",
        arguments: [["system.capabilities"], ["system.capabilities", "--json"], ["system.capabilities", "--stdin"]])
    func explicitCapabilitiesAcceptsArguments(arguments: [String]) async throws {
        let observed = try await runRecordedCLIInvocation(
            .init(arguments: arguments, standardInput: Data("{}".utf8)))

        #expect(observed.outcome.exitCode == 0, "stderr: \(observed.outcome.standardError)")
        #expect(observed.acceptedConnections == 1)
        #expect(observed.requests.map(\.method) == ["auth.login", "system.capabilities"])
        let catalog = try JSONDecoder().decode(
            IPCMethodCatalogResult.self, from: Data(observed.outcome.standardOutput.utf8))
        #expect(catalog.methods.contains { $0.name == "terminal.send" })
    }

    @Test("the retired reload-catalog flag is refused locally without fetching")
    func retiredReloadFlagNeverConnects() async throws {
        let observed = try await runRecordedCLIInvocation(.init(arguments: ["--reload-catalog", "system.identify"]))
        #expect(observed.outcome.exitCode != 0)
        #expect(observed.acceptedConnections == 0)
        #expect(observed.requests.isEmpty)
    }

    @Test("stdin defaults correlation in the actual request sent to the server")
    func stdinDefaultsCorrelation() async throws {
        let generated = UUIDv7.generate()
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: ["terminal.send", "--stdin"],
                standardInput: Data(#"{"handle":"self","input":"hello"}"#.utf8),
                correlationId: generated))
        let request = try #require(observed.requests.first { $0.method == "terminal.send" })
        guard case .object(let fields) = request.params else {
            Issue.record("terminal.send request must carry an object")
            return
        }
        #expect(fields["correlationId"] == .string(generated.uuidString))
        #expect(fields["input"] == .string("hello"))
    }

    @Test("stdin preserves the supplied correlation in the actual request")
    func stdinPreservesCorrelation() async throws {
        let supplied = UUIDv7.generate()
        let generated = UUIDv7.generate()
        let input = try JSONSerialization.data(
            withJSONObject: ["handle": "self", "input": "hello", "correlationId": supplied.uuidString])
        let observed = try await runRecordedCLIInvocation(
            .init(arguments: ["terminal.send", "--stdin"], standardInput: input, correlationId: generated))
        let request = try #require(observed.requests.first { $0.method == "terminal.send" })
        guard case .object(let fields) = request.params else {
            Issue.record("terminal.send request must carry an object")
            return
        }
        #expect(fields["correlationId"] == .string(supplied.uuidString))
        #expect(fields["correlationId"] != .string(generated.uuidString))
    }
}
