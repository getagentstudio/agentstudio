import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("AgentStudio runtime discovery publication", .serialized)
struct AgentStudioIPCRuntimeDiscoveryTests {
    @Test("split runtime discovery retires with either server shutdown", arguments: [false, true])
    func splitRuntimeDiscoveryRetiresWithServer(graceful: Bool) async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(separateSocketDirectory: true) },
            body: { fixture in
                try fixture.server.start()
                let discoveryURL = fixture.paths.socketDirectory.appending(path: "runtime.json")
                #expect(
                    try FileManager.default.destinationOfSymbolicLink(atPath: discoveryURL.path)
                        == fixture.paths.metadataURL.path)
                let storeContents = Data("retained store".utf8)
                try storeContents.write(to: fixture.paths.cliStoreURL)

                if graceful {
                    await fixture.server.stopAcceptingConnections()
                } else {
                    await fixture.server.stop()
                }

                #expect(!FileManager.default.fileExists(atPath: fixture.paths.metadataURL.path))
                #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: discoveryURL.path)) == nil)
                #expect(try Data(contentsOf: fixture.paths.cliStoreURL) == storeContents)
            })
    }

    @Test("failed discovery publication removes metadata and stops the listening socket")
    func failedDiscoveryPublicationStopsServer() async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(separateSocketDirectory: true) },
            body: { fixture in
                try AgentStudioIPCFilesystem.prepare(paths: fixture.paths)
                let blockedURL = fixture.paths.socketDirectory.appending(path: "runtime.json")
                try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: false)
                let sentinelURL = blockedURL.appending(path: "keep")
                try Data("untouched".utf8).write(to: sentinelURL)

                #expect(throws: AgentStudioIPCFilesystemTrustError.self) { try fixture.server.start() }

                #expect(!FileManager.default.fileExists(atPath: fixture.paths.metadataURL.path))
                #expect(try Data(contentsOf: sentinelURL) == Data("untouched".utf8))
                let connectionFailure = try await valueFromDedicatedThread {
                    () throws -> UnixSocketTransportError? in
                    do {
                        let connection = try UnixSocketClient.connect(
                            endpoint: .init(path: fixture.paths.socketURL.path))
                        connection.close()
                        return nil
                    } catch let error as UnixSocketTransportError {
                        return error
                    }
                }
                #expect(connectionFailure?.reason == .connectFailed)
            })
    }

}
