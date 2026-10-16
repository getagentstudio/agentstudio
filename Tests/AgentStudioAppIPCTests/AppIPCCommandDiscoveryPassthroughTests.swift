import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@Suite("CLI command discovery trusts served metadata", .serialized)
struct AppIPCCommandDiscoveryPassthroughTests {
    private static let payload = Data(
        [
            #" { "compatibility":{"wireProtocolIdentifier":"future-wire","catalogIdentifier":"future-catalog"}, "#,
            #""commands":[{"id":"fixture.dynamicHelp","title":"Dynamic help","description":"Presented metadata","#,
            #""futureField":true}] } "#,
        ].joined().utf8)

    @Test("authenticated command.list prints the exact bytes the app served without rechecking")
    func commandListPreservesServedBytes() async throws {
        let outcome = try await runCommandDiscovery(arguments: ["command.list"])
        #expect(outcome.output.exitCode == 0)
        #expect(outcome.output.standardError.isEmpty)
        #expect(outcome.methods == ["auth.login", "command.list"])
        let preservesBytes = Data(outcome.output.standardOutput.utf8) == Self.payload + Data([0x0a])
        #expect(preservesBytes)
    }

    @Test("live help fetches only command metadata and presents it without catalog validation")
    func liveHelpPresentsOnlyServedMetadata() async throws {
        let outcome = try await runCommandDiscovery(arguments: ["help", "--live"])
        #expect(outcome.output.exitCode == 0)
        #expect(outcome.output.standardError.isEmpty)
        #expect(outcome.methods == ["auth.login", "command.list"])
        #expect(outcome.output.standardOutput.contains("fixture.dynamicHelp — Dynamic help: Presented metadata"))
    }

    private func runCommandDiscovery(arguments: [String]) async throws
        -> (output: ClientCommandLineOutcome, methods: [String])
    {
        let path = "/tmp/command-discovery-\(UUIDv7.generate().uuidString).sock"
        let listener = UnixSocketListener(endpoint: .init(path: path))
        let methods = Mutex<[String]>([])
        let principal = UUIDv7.generate()
        let runtime = UUIDv7.generate()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try listener.start { connection in
            defer { connection.close() }
            var reader = TestFrameReader()
            let login = try JSONRPCCodec.decodeRequest(reader.receiveFrame(connection: connection))
            methods.withLock { $0.append(login.method) }
            guard login.method == "auth.login" else { throw CommandDiscoveryPeerError.unexpectedMethod }
            let status = IPCAuthStatusResult.authenticated(
                principalId: principal, runtimeId: runtime, accessMode: .automationSameUser)
            let authResponse = JSONRPCResponse.success(
                id: login.id, result: try JSONRPCCodec.encodeJSONValue(status))
            try connection.send(
                NDJSONFrameEncoder.encode(
                    JSONRPCCodec.encodeResponse(authResponse),
                    maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes))
            let request = try JSONRPCCodec.decodeRequest(reader.receiveFrame(connection: connection))
            methods.withLock { $0.append(request.method) }
            guard request.method == "command.list" else { throw CommandDiscoveryPeerError.unexpectedMethod }
            try connection.send(
                JSONRPCCodec.encodeResponseBytes(
                    id: request.id ?? .null, encodedResult: Self.payload,
                    maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes))
        }
        let output = await runClientCommandLineOffCooperativePool(
            arguments: arguments,
            environment: ["AGENTSTUDIO_IPC_SOCKET": path, "AGENTSTUDIO_PANE_TOKEN": "command-discovery-test"])
        await valueFromDedicatedThread { listener.stop() }
        return (output, methods.withLock { $0 })
    }
}

private enum CommandDiscoveryPeerError: Error { case unexpectedMethod }
