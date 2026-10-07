import AgentStudioCLIStore
import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

#if canImport(Darwin)
    import Darwin
#endif

@Suite("Offline pane notification outbox writer")
struct PaneNotificationOutboxWriterTests {
    @Test("an eligible message stores the exact wire envelope in an owner-only SQLite file")
    func eligibleMessageAppendsTheWireEnvelope() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try PaneNotificationOutboxFixture()
            defer { fixture.remove() }
            let invocation = try fixture.invocation(["message", "deploy finished"])
            let expectedLine = try fixture.client.requestFrame(invocation)
            let parameters = try JSONDecoder().decode(
                IPCSessionMessageParams.self, from: invocation.normalizedParameters.data)

            let outcome = try fixture.handler.handleUnreachableApp(invocation: invocation) { expectedLine }

            let entries = try fixture.entries()
            return QueuedEnvelopeObservation(
                outcome: outcome, entries: entries, expectedLine: expectedLine,
                correlationID: parameters.correlationId, paneID: fixture.paneID,
                fileMode: try fixture.storeFileMode(), lineContainsToken: expectedLine.contains(fixture.paneToken),
                legacyDirectoryExists: FileManager.default.fileExists(atPath: fixture.legacyDirectory.path))
        }
        #expect(observed.outcome == .queued(reply: "message queued"))
        #expect(observed.entries.count == 1)
        if let entry = observed.entries.first, case .notice(let notice) = entry {
            #expect(notice.payloadJSON == observed.expectedLine)
            #expect(notice.messageID == observed.correlationID)
            #expect(notice.paneID == observed.paneID)
        }
        #expect(observed.fileMode == 0o600)
        #expect(!observed.lineContainsToken)
        #expect(!observed.legacyDirectoryExists)
    }

    @Test("needs-you and done queue their own replies while clear refuses offline")
    func deliberateVariantsFollowDescriptorEligibility() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try PaneNotificationOutboxFixture()
            defer { fixture.remove() }

            let needsYou = try fixture.queue(["needs-you", "approval please"])
            let done = try fixture.queue(["done"])
            let clear = try fixture.queue(["needs-you", "--clear"])

            return QueuedVariantsObservation(
                needsYou: needsYou, done: done, clear: clear, entryCount: try fixture.entries().count)
        }
        #expect(observed.needsYou == .queued(reply: "needs-you queued"))
        #expect(observed.done == .queued(reply: "done queued"))
        #expect(observed.clear == .clearUnavailableWhileOffline)
        #expect(observed.entryCount == 2)
    }

    @Test("a pane without store environment keeps the ordinary unreachable failure")
    func missingPaneEnvironmentDoesNotQueue() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try PaneNotificationOutboxFixture()
            defer { fixture.remove() }
            let handler = PaneNotificationOfflineHandler(environment: [:])
            let invocation = try fixture.invocation(["message", "unaddressed"])

            let outcome = try handler.handleUnreachableApp(invocation: invocation) {
                try fixture.client.requestFrame(invocation)
            }

            return (outcome: outcome, storeExists: FileManager.default.fileExists(atPath: fixture.storeURL.path))
        }
        #expect(observed.outcome == .notQueued)
        #expect(!observed.storeExists)
    }

    @Test("a missing or unknown store channel never defaults to stable", arguments: ["", "unknown-channel"])
    func missingOrUnknownChannelDoesNotQueue(channel: String) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try PaneNotificationOutboxFixture()
            defer { fixture.remove() }
            var environment = fixture.environment
            environment["AGENTSTUDIO_CLI_STORE_CHANNEL"] = channel.isEmpty ? nil : channel
            let handler = PaneNotificationOfflineHandler(environment: environment)
            let invocation = try fixture.invocation(["message", "channel unavailable"])

            let outcome = try handler.handleUnreachableApp(invocation: invocation) {
                try fixture.client.requestFrame(invocation)
            }

            return (outcome: outcome, storeExists: FileManager.default.fileExists(atPath: fixture.storeURL.path))
        }
        #expect(observed.outcome == .notQueued)
        #expect(!observed.storeExists)
    }

    @Test("an unwritable store fails explicitly without claiming a queued notification")
    func unwritableStoreFailsWithoutClaimingQueued() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try PaneNotificationOutboxFixture()
            defer { fixture.remove() }
            try fixture.makeStoreDirectoryReadOnly()
            defer { fixture.restorePermissions() }
            let invocation = try fixture.invocation(["message", "unwritable"])

            let attempt = Result<PaneNotificationOfflineOutcome, any Error> {
                try fixture.handler.handleUnreachableApp(invocation: invocation) {
                    try fixture.client.requestFrame(invocation)
                }
            }
            return (attempt: attempt, storeExists: FileManager.default.fileExists(atPath: fixture.storeURL.path))
        }
        #expect(throws: CLIStoreFailure.unavailable) { _ = try observed.attempt.get() }
        #expect(!observed.storeExists)
    }

    @Test("concurrent writers preserve every durably acknowledged envelope intact")
    func concurrentWritersPreserveAcknowledgedEnvelopes() async throws {
        let fixture = try await valueFromDedicatedThread { try PaneNotificationOutboxFixture() }
        defer { fixture.remove() }
        _ = try await valueFromDedicatedThread { try CLIStore.openWriter(url: fixture.storeURL, channel: .debug).get() }
        let first = try fixture.invocation(["message", String(repeating: "a", count: 4096)])
        let second = try fixture.invocation(["message", String(repeating: "b", count: 4096)])
        let firstLine = try fixture.client.requestFrame(first)
        let secondLine = try fixture.client.requestFrame(second)

        async let firstOutcome = queueOnDedicatedThread(fixture: fixture, invocation: first, line: firstLine)
        async let secondOutcome = queueOnDedicatedThread(fixture: fixture, invocation: second, line: secondLine)
        let outcomes = await [firstOutcome, secondOutcome]

        var acknowledged: [String] = []
        for (outcome, line) in zip(outcomes, [firstLine, secondLine]) {
            switch outcome {
            case .success(.queued): acknowledged.append(line)
            case .failure(.busy): break
            default: Issue.record("A configured writer neither queued nor reported SQLite busy")
            }
        }
        #expect(!acknowledged.isEmpty)
        let expected = Set(acknowledged)
        let expectedCount = acknowledged.count
        let payloads = try await valueFromDedicatedThread {
            let entries = try fixture.entries()
            return entries.map { entry in
                switch entry {
                case .notice(let notice): notice.payloadJSON
                }
            }
        }
        #expect(Set(payloads) == expected)
        #expect(payloads.count == expectedCount)
    }

    @Test("a missing socket path and a refused connection both permit queuing")
    func unreachableEndpointsPermitQueuing() async throws {
        let socket = await valueFromDedicatedThread { makeBoundButUnlistenedSocketPath() }
        let descriptor = socket.descriptor
        let pathBytes = socket.pathBytes
        let bound = socket.bound
        defer { unlink(socket.path) }
        try #require(descriptor >= 0)
        try #require(pathBytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path))
        try #require(bound == 0)
        let refusedPath = socket.path
        let observed = try await valueFromDedicatedThread {
            let fixture = try PaneNotificationOutboxFixture()
            defer { fixture.remove() }
            let invocation = try fixture.invocation(["message", "unreachable"])
            let refusedClient = AgentStudioIPCClient(
                configuration: .init(socketPath: refusedPath), descriptors: fixture.descriptors)
            let missingClient = AgentStudioIPCClient(
                configuration: .init(socketPath: temporaryIPCDescriptorClientSocketPath()),
                descriptors: fixture.descriptors)

            let missing = Result<Void, any Error> { _ = try missingClient.call(invocation, requestID: 1) }
            let refused = Result<Void, any Error> { _ = try refusedClient.call(invocation, requestID: 1) }
            return (missing: missing, refused: refused)
        }
        // This shared helper records issues on unexpected errors or success;
        // replaying the captured result here keeps those issues on the test task.
        let missing = try captureIPCDescriptorClientFailure { try observed.missing.get() }
        let refused = try captureIPCDescriptorClientFailure { try observed.refused.get() }
        #expect(missing.permitsOfflineQueue)
        #expect(refused.permitsOfflineQueue)
    }

    @Test("authentication rejection from a live app never permits queuing")
    func authenticationRejectionNeverQueues() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try PaneNotificationOutboxFixture()
            defer { fixture.remove() }
            let endpoint = UnixSocketEndpoint(path: temporaryIPCDescriptorClientSocketPath())
            let listener = UnixSocketListener(endpoint: endpoint)
            try listener.start { connection in
                defer { connection.close() }
                var decoder = NDJSONFrameDecoder(maxFrameBytes: 65_536)
                let request = try receiveIPCDescriptorClientRequest(connection: connection, decoder: &decoder)
                try connection.send(
                    try makeIPCDescriptorClientResponseFrame(
                        id: request.id, result: IPCAuthStatusResult.unauthenticated))
            }
            defer { listener.stop() }
            let invocation = try fixture.invocation(["message", "rejected"])
            let client = AgentStudioIPCClient(
                configuration: .init(
                    socketPath: endpoint.path, authToken: fixture.paneToken, maxRequestFrameBytes: 65_536),
                descriptors: fixture.descriptors + [try IPCDescriptorClientFixtureCatalog.make().authentication])

            let rejected = Result<Void, any Error> { _ = try client.call(invocation, requestID: 1) }
            return (rejected: rejected, storeExists: FileManager.default.fileExists(atPath: fixture.storeURL.path))
        }
        let rejected = try captureIPCDescriptorClientFailure { try observed.rejected.get() }
        #expect(rejected.disposition == .authenticationRejected)
        #expect(!rejected.permitsOfflineQueue)
        #expect(!observed.storeExists)
    }
}

private func queueOnDedicatedThread(
    fixture: PaneNotificationOutboxFixture, invocation: IPCDescriptorInvocation, line: String
) async -> Result<PaneNotificationOfflineOutcome, CLIStoreFailure> {
    do {
        return .success(
            try await valueFromDedicatedThread {
                try fixture.handler.handleUnreachableApp(invocation: invocation) { line }
            })
    } catch let failure as CLIStoreFailure {
        return .failure(failure)
    } catch {
        Issue.record("Unexpected offline queue error: \(error)")
        return .failure(.unavailable)
    }
}

private struct QueuedEnvelopeObservation: Sendable {
    let outcome: PaneNotificationOfflineOutcome
    let entries: [CLIOutboxEntry]
    let expectedLine: String
    let correlationID: UUID
    let paneID: UUID
    let fileMode: UInt16
    let lineContainsToken: Bool
    let legacyDirectoryExists: Bool
}

private struct QueuedVariantsObservation: Sendable {
    let needsYou: PaneNotificationOfflineOutcome
    let done: PaneNotificationOfflineOutcome
    let clear: PaneNotificationOfflineOutcome
    let entryCount: Int
}

private struct BoundSocketObservation: Sendable {
    let path: String
    let descriptor: Int32
    let pathBytes: [UInt8]
    let bound: Int32?
}

private func makeBoundButUnlistenedSocketPath() -> BoundSocketObservation {
    let path = temporaryIPCDescriptorClientSocketPath()
    let pathBytes = Array(path.utf8)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        return BoundSocketObservation(path: path, descriptor: descriptor, pathBytes: pathBytes, bound: nil)
    }
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        return BoundSocketObservation(path: path, descriptor: descriptor, pathBytes: pathBytes, bound: nil)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return BoundSocketObservation(path: path, descriptor: descriptor, pathBytes: pathBytes, bound: bound)
}

private struct PaneNotificationOutboxFixture: Sendable {
    let rootURL: URL
    let storeURL: URL
    let legacyDirectory: URL
    let paneID = UUIDv7.generate()
    let handler: PaneNotificationOfflineHandler
    let client: AgentStudioIPCClient
    let descriptors: [IPCAnyMethodDescriptor]
    let paneToken = "PANE-TOKEN-NEVER-RECORDED"

    var environment: [String: String] {
        [
            "AGENTSTUDIO_CLI_STORE": storeURL.path, "AGENTSTUDIO_CLI_STORE_CHANNEL": "debug",
            "AGENTSTUDIO_PANE_ID": paneID.uuidString,
        ]
    }

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(path: "notification-outbox-\(UUIDv7.generate())")
        storeURL = rootURL.appending(path: "ipc/cli.sqlite")
        legacyDirectory = rootURL.appending(path: "ipc/spool/v2")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        descriptors = try IPCBuiltInMethodCatalog.offlineNotificationDescriptors(
            examples: .init(illustrativeIdentifier: UUIDv7.generate()))
        client = AgentStudioIPCClient(
            configuration: .init(socketPath: rootURL.appending(path: "absent.sock").path, authToken: paneToken),
            descriptors: descriptors)
        handler = PaneNotificationOfflineHandler(environment: [
            "AGENTSTUDIO_CLI_STORE": storeURL.path, "AGENTSTUDIO_CLI_STORE_CHANNEL": "debug",
            "AGENTSTUDIO_PANE_ID": paneID.uuidString,
        ])
    }

    func invocation(_ arguments: [String]) throws -> IPCDescriptorInvocation {
        try IPCDescriptorInvocationParser.parse(
            arguments, descriptors: descriptors, correlationIDGenerator: { UUIDv7.generate() })
    }

    func queue(_ arguments: [String]) throws -> PaneNotificationOfflineOutcome {
        let invocation = try invocation(arguments)
        return try handler.handleUnreachableApp(invocation: invocation) { try client.requestFrame(invocation) }
    }

    func entries() throws -> [CLIOutboxEntry] {
        try CLIStore.openReader(url: storeURL, expectedChannel: .debug).get().readOutbox(after: 0).get().entries
    }

    func storeFileMode() throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        return (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    }

    func makeStoreDirectoryReadOnly() throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o500])
    }

    func restorePermissions() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: storeURL.deletingLastPathComponent().path)
    }

    func remove() {
        restorePermissions()
        try? FileManager.default.removeItem(at: rootURL)
    }
}
