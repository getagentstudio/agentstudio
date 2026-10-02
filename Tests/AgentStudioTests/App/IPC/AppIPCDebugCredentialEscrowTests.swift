import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

#if canImport(Darwin)
    import Darwin
#endif

/// The debug credential exists only while the runtime does. These cases run the
/// real handover: mint on readiness, verify from memory on every call, and drop
/// both the verifier and the file the launcher named when the server stops.
@MainActor
@Suite("App IPC debug credential escrow", .serialized)
struct AppIPCDebugCredentialEscrowTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("a debug app hands its reusable credential to an unrelated shell through the escrow file")
    func debugServerPublishesEscrowFileAndAuthenticatesItsToken() async throws {
        let escrowDirectory = FileManager.default.temporaryDirectory
            .appending(path: "as-ipc-escrow-\(UUIDv7.generate().uuidString.suffix(12))")
        try FileManager.default.createDirectory(
            at: escrowDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: escrowDirectory) }
        let escrowURL = escrowDirectory.appending(path: "debug-credential.json")

        let harness = try await SessionsVerticalHarness.make(debugCredentialEscrowURL: escrowURL)

        let escrow = try JSONDecoder().decode(
            IPCDebugCredentialEscrowDocument.self,
            from: try Data(contentsOf: escrowURL)
        )
        #expect(escrow.runtimeId == harness.appDelegate.appIPCRuntimeID)
        #expect(escrow.socketPath == harness.socketPath)
        #expect(!escrow.token.isEmpty)
        #expect(try mode(for: escrowURL) & 0o777 == 0o600)

        #expect(try await loginSucceeds(socketPath: harness.socketPath, token: escrow.token))

        await harness.tearDown()

        #expect(!FileManager.default.fileExists(atPath: escrowURL.path))
        await #expect(throws: (any Error).self) {
            _ = try await loginSucceeds(socketPath: harness.socketPath, token: escrow.token)
        }
    }

    @Test("a debug app without an escrow path writes no credential file")
    func debugServerWithoutEscrowPathPublishesNothing() async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            #expect(harness.appDelegate.appIPCDebugCredentialEscrowURL == nil)
            let ipcDirectoryEntries = try FileManager.default.contentsOfDirectory(
                atPath: harness.appDelegate.appIPCPaths.ipcDirectory.path
            )
            #expect(
                ipcDirectoryEntries.allSatisfy {
                    ["agentstudio.sock", "runtime.json", "spool"].contains($0)
                }
            )
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    private func loginSucceeds(socketPath: String, token: String) async throws -> Bool {
        let connection = try await withoutBlockingCooperativePool {
            try UnixSocketClient.connect(endpoint: UnixSocketEndpoint(path: socketPath))
        }
        defer { connection.close() }
        var reader = SessionsVerticalFrameReader()
        try await withoutBlockingCooperativePool {
            try connection.send(
                try NDJSONFrameEncoder.encode(
                    JSONRPCCodec.encodeRequest(
                        try JSONRPCClientRequest(
                            id: .number(1),
                            method: "auth.login",
                            params: .object(["token": .string(token)])
                        )
                    ),
                    maxFrameBytes: 65_536
                )
            )
        }
        let response = try await reader.receiveResponse(connection: connection)
        guard response.error == nil else {
            throw AppIPCDebugCredentialEscrowTestError.loginRejected
        }
        return true
    }

    private func mode(for url: URL) throws -> mode_t {
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else { throw POSIXError(.ENOENT) }
        return statBuffer.st_mode
    }
}

private enum AppIPCDebugCredentialEscrowTestError: Error {
    case loginRejected
}
