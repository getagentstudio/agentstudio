import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("CLI capabilities served-byte passthrough", .serialized)
struct AppIPCCapabilitiesPassthroughTests {
    @Test("explicit capabilities prints the app-composed result bytes unchanged")
    func capabilitiesPreservesServedBytes() async throws {
        try await assertServedBytes(result: nil)
    }

    @Test("explicit capabilities preserves a mismatched catalog version without client rechecking")
    func mismatchedCatalogVersionPreservesServedBytes() async throws {
        let foreignResult = IPCMethodCatalogResult(
            compatibility: .init(wireProtocolIdentifier: "foreign-wire", catalogIdentifier: "foreign-catalog"),
            methods: [])
        try await assertServedBytes(result: foreignResult)
    }

    private func assertServedBytes(result: IPCMethodCatalogResult?) async throws {
        let fixture = try await valueFromDedicatedThread { try CapabilitiesBytePeer(result: result) }
        defer { fixture.removeSocket() }
        try fixture.start()
        let outcome = await runClientCommandLineOffCooperativePool(
            arguments: ["system.capabilities"], environment: ["AGENTSTUDIO_IPC_SOCKET": fixture.socketPath])
        await fixture.shutdown()
        #expect(outcome.exitCode == 0)
        #expect(outcome.standardError.isEmpty)
        #expect(fixture.requestMethods == ["system.capabilities"])
        // Keep exact byte equality, but avoid Swift Testing's collection diff
        // over the entire catalog when the intentionally different bytes fail.
        let preservesServedBytes = Data(outcome.standardOutput.utf8) == fixture.servedBytes + Data([0x0a])
        #expect(preservesServedBytes, "stdout must preserve the served result bytes plus one newline")
        let printed = try JSONDecoder().decode(IPCMethodCatalogResult.self, from: Data(outcome.standardOutput.utf8))
        #expect(printed == fixture.servedResult)
    }
}

/// The normal case uses the existing real composer. A foreign-version case
/// proves that explicit discovery trusts served metadata without client checks.
/// Single-line whitespace distinguishes served bytes from a typed re-encoding.
private final class CapabilitiesBytePeer: @unchecked Sendable {
    let socketPath: String
    let servedBytes: Data
    let servedResult: IPCMethodCatalogResult
    private let listener: UnixSocketListener
    private let lock = NSLock()
    private var connections: [UnixSocketConnection] = []
    private var tasks: [Task<Void, Never>] = []
    private var methods: [String] = []
    private var closing = false

    init(result: IPCMethodCatalogResult?) throws {
        socketPath = "/tmp/capabilities-bytes-\(UUIDv7.generate().uuidString).sock"
        listener = UnixSocketListener(endpoint: UnixSocketEndpoint(path: socketPath))
        let encodedResult: Data
        if let result {
            servedResult = result
            encodedResult = try JSONEncoder().encode(result)
        } else {
            let catalog = try IPCBuiltInMethodCatalog(
                inputs: .init(examples: .init(illustrativeIdentifier: UUIDv7.generate())))
            guard let ping = catalog.erasedDescriptors.first(where: { $0.metadata.name == "system.ping" }) else {
                throw CapabilitiesByteFixtureError.missingPing
            }
            let composition = try IPCSystemCapabilitiesDescriptorFactory.compose(
                compatibility: .current, availableDescriptors: catalog.erasedDescriptors, illustrativeDescriptor: ping)
            servedResult = composition.result
            encodedResult = composition.encodedResult
        }
        guard encodedResult.first == 0x7b else { throw CapabilitiesByteFixtureError.nonObjectCatalog }
        var bytes = Data(" {   ".utf8)
        bytes.append(encodedResult.dropFirst())
        bytes.append(0x20)
        servedBytes = bytes
    }

    var requestMethods: [String] { lock.withLock { methods } }

    func start() throws {
        try listener.start { [self] connection in
            lock.withLock {
                guard !closing else {
                    connection.close()
                    return
                }
                connections.append(connection)
                tasks.append(Task { await self.serve(connection) })
            }
        }
    }

    private func serve(_ connection: UnixSocketConnection) async {
        await valueFromDedicatedThread { [self] in
            defer { connection.close() }
            do {
                var decoder = NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumRequestFrameBytes)
                let request = try receiveListenerHandlerRequest(connection: connection, decoder: &decoder)
                lock.withLock { methods.append(request.method) }
                guard request.method == "system.capabilities" else {
                    throw CapabilitiesByteFixtureError.unexpectedMethod
                }
                try connection.send(
                    JSONRPCCodec.encodeResponseBytes(
                        id: request.id ?? .null, encodedResult: servedBytes,
                        maxFrameBytes: IPCFramePolicy.maximumResponseFrameBytes))
            } catch {}
        }
    }

    func shutdown() async {
        await valueFromDedicatedThread { self.listener.stop() }
        let owned = lock.withLock {
            closing = true
            return (connections, tasks)
        }
        for connection in owned.0 { connection.close() }
        for task in owned.1 { await task.value }
    }

    func removeSocket() { try? FileManager.default.removeItem(atPath: socketPath) }
}

private enum CapabilitiesByteFixtureError: Error {
    case missingPing
    case nonObjectCatalog
    case unexpectedMethod
}
