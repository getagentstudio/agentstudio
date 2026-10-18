import AgentStudioCLIStore
import AgentStudioPrimitives
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("CLI ordering store discovery")
struct CLIOrderingStoreLocationTests {
    @Test("split discovery opens the canonical channel store", arguments: [CLIStoreChannel.stable, .beta, .debug])
    func splitDiscoveryOpensCanonicalStore(channel: CLIStoreChannel) async throws {
        let observed = try await valueFromDedicatedThread { () throws -> OpenedOrderingStoreObservation in
            let fixture = try OrderingDiscoveryFixture(channel: channel)
            defer { fixture.cleanup() }
            let location = CLIOrderingStoreLocation.resolve(
                environment: fixture.environment, socketPath: fixture.socket.path)
            var openedChannel: CLIStoreChannel?
            if let location {
                let writer = try CLIStore.openWriter(url: location.url, channel: location.channel).get()
                openedChannel = writer.identity.channel
                try writer.close()
            }
            return OpenedOrderingStoreObservation(
                actualURL: location?.url, expectedURL: fixture.store.resolvingSymlinksInPath(),
                discoveredChannel: location?.channel, openedChannel: openedChannel,
                socketStoreExists: FileManager.default.fileExists(
                    atPath: fixture.socketDirectory.appending(path: "cli.sqlite").path))
        }

        #expect(observed.actualURL == observed.expectedURL)
        #expect(observed.discoveredChannel == channel)
        #expect(observed.openedChannel == channel)
        #expect(!observed.socketStoreExists)
    }

    @Test(
        "unproven discovery never creates a store",
        arguments: [
            "missingPointer", "danglingPointer", "unreadable", "socketMismatch", "unknownChannel",
            "missingStore", "selectedSocketMismatch",
        ])
    func unprovenDiscoveryDoesNotCreateStore(scenario: String) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try OrderingDiscoveryFixture()
            defer { fixture.cleanup() }
            switch scenario {
            case "missingPointer": try FileManager.default.removeItem(at: fixture.discovery)
            case "danglingPointer": try FileManager.default.removeItem(at: fixture.metadata)
            case "unreadable": try Data("invalid metadata".utf8).write(to: fixture.metadata)
            case "socketMismatch": try fixture.writeMetadata(socket: "/other/socket", channel: "debug")
            case "unknownChannel": try fixture.writeMetadata(socket: fixture.socket.path, channel: "foreign")
            case "missingStore": try FileManager.default.removeItem(at: fixture.store)
            default: break
            }
            let before = try FileManager.default.contentsOfDirectory(atPath: fixture.storeDirectory.path).sorted()
            let socket = scenario == "selectedSocketMismatch" ? "/other/selected.sock" : fixture.socket.path
            let location = CLIOrderingStoreLocation.resolve(environment: fixture.environment, socketPath: socket)
            return (
                refused: location == nil, before: before,
                after: try FileManager.default.contentsOfDirectory(atPath: fixture.storeDirectory.path).sorted(),
                socketStoreExists: FileManager.default.fileExists(
                    atPath: fixture.socketDirectory.appending(path: "cli.sqlite").path)
            )
        }

        #expect(observed.refused)
        #expect(observed.after == observed.before)
        #expect(!observed.socketStoreExists)
    }

    @Test("explicit store context precedes invalid adjacent metadata")
    func explicitStorePrecedesRuntimeDiscovery() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try OrderingDiscoveryFixture()
            defer { fixture.cleanup() }
            try Data("invalid metadata".utf8).write(to: fixture.metadata)
            var environment = fixture.environment
            environment["AGENTSTUDIO_CLI_STORE"] = fixture.store.path
            environment["AGENTSTUDIO_CLI_STORE_CHANNEL"] = "debug"
            let location = CLIOrderingStoreLocation.resolve(environment: environment, socketPath: nil)
            environment.removeValue(forKey: "AGENTSTUDIO_CLI_STORE_CHANNEL")
            return (
                actualURL: location?.url, expectedURL: fixture.store, channel: location?.channel,
                missingChannelRefused: CLIOrderingStoreLocation.resolve(
                    environment: environment, socketPath: fixture.socket.path) == nil
            )
        }

        #expect(observed.actualURL == observed.expectedURL)
        #expect(observed.channel == .debug)
        #expect(observed.missingChannelRefused)
    }

    @Test("a metadata channel cannot open a different channel's canonical store")
    func splitDiscoveryRetainsStoreChannelProof() async throws {
        let observed = try await valueFromDedicatedThread {
            () throws -> (locationFound: Bool, failure: CLIStoreFailure?) in
            let fixture = try OrderingDiscoveryFixture()
            defer { fixture.cleanup() }
            try fixture.writeMetadata(socket: fixture.socket.path, channel: "beta")
            guard
                let location = CLIOrderingStoreLocation.resolve(
                    environment: fixture.environment, socketPath: fixture.socket.path)
            else { return (false, nil) }
            switch CLIStore.openWriter(url: location.url, channel: location.channel) {
            case .failure(let failure): return (true, failure)
            case .success(let writer):
                try writer.close()
                return (true, nil)
            }
        }

        #expect(observed.locationFound)
        #expect(observed.failure == .channelMismatch)
    }
}

private struct OpenedOrderingStoreObservation: Sendable {
    let actualURL: URL?
    let expectedURL: URL
    let discoveredChannel: CLIStoreChannel?
    let openedChannel: CLIStoreChannel?
    let socketStoreExists: Bool
}

private struct OrderingDiscoveryFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "ordering-discovery-\(UUIDv7.generate())")
    var storeDirectory: URL { root.appending(path: "ipc") }
    var socketDirectory: URL { root.appending(path: "ipc-socket") }
    var socket: URL { socketDirectory.appending(path: "agentstudio.sock") }
    var metadata: URL { storeDirectory.appending(path: "runtime.json") }
    var discovery: URL { socketDirectory.appending(path: "runtime.json") }
    var store: URL { storeDirectory.appending(path: "cli.sqlite") }
    var environment: [String: String] { ["AGENTSTUDIO_IPC_SOCKET": socket.path] }

    init(channel: CLIStoreChannel = .debug) throws {
        do {
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false)
            let writer = try CLIStore.openWriter(url: store, channel: channel)
                .get()
            try writer.close()
            try writeMetadata(socket: socket.path, channel: channel.rawValue)
            try FileManager.default.createSymbolicLink(at: discovery, withDestinationURL: metadata)
        } catch {
            cleanup()
            throw error
        }
    }

    func writeMetadata(socket: String, channel: String) throws {
        try JSONSerialization.data(withJSONObject: ["socketPath": socket, "channel": channel]).write(to: metadata)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
