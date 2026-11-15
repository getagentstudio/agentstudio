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

    @Test("retirement cannot follow a replaced socket directory", arguments: [false, true])
    func retirementPreservesForeignMetadataAfterDirectoryReplacement(graceful: Bool) async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(separateSocketDirectory: true) },
            body: { fixture in
                try fixture.server.start()
                let storeBytes = Data("retained store".utf8)
                try storeBytes.write(to: fixture.paths.cliStoreURL)
                let foreign = fixture.rootURL.appending(path: "another-runtime")
                try FileManager.default.createDirectory(
                    at: foreign, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let metadataURL = foreign.appending(path: "runtime.json")
                let sentinel = Data("another runtime's metadata".utf8)
                try sentinel.write(to: metadataURL)
                try FileManager.default.moveItem(
                    at: fixture.paths.socketDirectory, to: fixture.rootURL.appending(path: "retired-socket"))
                try FileManager.default.createSymbolicLink(
                    at: fixture.paths.socketDirectory, withDestinationURL: foreign)
                // Keep the existing listener's wake connection reachable after moving its directory.
                try FileManager.default.createSymbolicLink(
                    at: foreign.appending(path: "agentstudio.sock"),
                    withDestinationURL: fixture.rootURL.appending(path: "retired-socket/agentstudio.sock"))

                if graceful { await fixture.server.stopAcceptingConnections() } else { await fixture.server.stop() }

                #expect((try? Data(contentsOf: metadataURL)) == sentinel)
                #expect(try Data(contentsOf: fixture.paths.cliStoreURL) == storeBytes)
                #expect(!FileManager.default.fileExists(atPath: fixture.paths.metadataURL.path))
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
