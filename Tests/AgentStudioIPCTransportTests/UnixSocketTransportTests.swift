import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioIPCTransport

@Suite("Unix socket transport")
struct UnixSocketTransportTests {
    @Test("connects, sends, reads, and closes against a temp Unix socket")
    func connectsSendsReadsAndCloses() async throws {
        let fixture = try UnixSocketFixture()
        defer { fixture.cleanup() }

        let listener = UnixSocketListener(endpoint: fixture.endpoint)
        let handledRequest = HeldStep<String?>("listener handled the request")
        handledRequest.release()

        try listener.start { connection in
            var receivedFrame: String?
            defer {
                connection.close()
                try? handledRequest.arriveBlocking(receivedFrame)
            }

            let request = try connection.receive(maxBytes: 64)
            receivedFrame = String(data: request, encoding: .utf8)
            try connection.send(Data("pong\n".utf8))
        }
        defer { listener.stop() }

        let client = try await valueFromDedicatedThread { try UnixSocketClient.connect(endpoint: fixture.endpoint) }
        defer { client.close() }

        try await valueFromDedicatedThread { try client.send(Data("ping\n".utf8)) }
        let response = try await valueFromDedicatedThread { try client.receive(maxBytes: 64) }

        #expect(String(data: response, encoding: .utf8) == "pong\n")
        #expect(try await handledRequest.firstArrival() == "ping\n")
    }

    @Test("reads Darwin same-user peer credentials from accepted sockets")
    func readsDarwinPeerCredentials() async throws {
        let fixture = try UnixSocketFixture()
        defer { fixture.cleanup() }

        let listener = UnixSocketListener(endpoint: fixture.endpoint)
        let handledConnection = HeldStep<PeerCredentials?>("listener read peer credentials")
        handledConnection.release()

        try listener.start { connection in
            var credentials: PeerCredentials?
            defer {
                connection.close()
                try? handledConnection.arriveBlocking(credentials)
            }

            credentials = try connection.peerCredentials(using: DarwinPeerCredentialProvider())
        }
        defer { listener.stop() }

        let client = try await valueFromDedicatedThread { try UnixSocketClient.connect(endpoint: fixture.endpoint) }
        defer { client.close() }

        #expect(try await handledConnection.firstArrival()?.userIdentifier == getuid())
    }

    /// The normal wake-and-join branch must retain the listening descriptor
    /// until the real accept-queue barrier runs. The controlled wait blocks on
    /// that actual barrier, so success is never fabricated by the test.
    @Test("normal stop joins the accept loop before freeing its descriptor")
    func normalStopJoinsAcceptLoopBeforeFreeingDescriptor() async throws {
        #if canImport(Darwin)
            let fixture = try UnixSocketFixture()
            defer { fixture.cleanup() }

            let handler = HeldStep<Void>("accept-loop handler")
            let stopReturned = HeldStep<Void>("listener stop returned")
            stopReturned.release()
            let descriptorProbe = UnixSocketListeningDescriptorProbe(endpointPath: fixture.endpoint.path)
            let joinWait = UnixSocketShutdownWaitController(
                mode: .waitForFirstBarrier,
                descriptorProbe: descriptorProbe
            )
            let listener = UnixSocketListener(
                endpoint: fixture.endpoint,
                acceptLoopJoinWait: { barrier in joinWait.wait(for: barrier) }
            )

            try listener.start { connection in
                try? handler.arriveBlocking(())
                connection.close()
            }
            defer { listener.stop() }

            do {
                try descriptorProbe.recordListeningDescriptor()

                // Arrange: occupy the loop inside the handler.
                let served = try await valueFromDedicatedThread {
                    try UnixSocketClient.connect(endpoint: fixture.endpoint)
                }
                defer { served.close() }
                try await handler.firstArrival()

                // Act
                let stopping = Task {
                    await valueFromDedicatedThread {
                        listener.stop()
                        try? stopReturned.arriveBlocking(())
                    }
                }
                let joinEntry = try await joinWait.firstJoin.firstArrival()
                let stopReturnedBeforeRelease = !stopReturned.recordedArrivals.isEmpty
                let descriptorOwnedEndpointWhileJoinWaits = descriptorProbe.descriptorOwnsEndpoint
                handler.release()
                try await stopReturned.firstArrival()
                await stopping.value

                // Assert: afterwards the loop is gone, the descriptor is released,
                // and a descriptor opened now is nobody else's to close.
                #expect(joinEntry.ownedEndpoint)
                #expect(!stopReturnedBeforeRelease)
                #expect(descriptorOwnedEndpointWhileJoinWaits)
                #expect(stopReturned.recordedArrivals.count == 1)
                let probe = try TemporaryFileDescriptor()
                defer { probe.cleanup() }
                #expect(probe.isOpen)
                #expect(probe.readBack() == "listener must not own this descriptor")
                await #expect(throws: (any Error).self) {
                    try await valueFromDedicatedThread { _ = try UnixSocketClient.connect(endpoint: fixture.endpoint) }
                }
                #expect(handler.recordedArrivals.count == 1)
                #expect(!descriptorProbe.descriptorOwnsEndpoint)
            } catch {
                let fixtureError = error
                handler.release()
                await valueFromDedicatedThread { listener.stop() }
                throw fixtureError
            }
        #endif
    }

    /// When the first bounded join expires, production closes the descriptor
    /// before its second join. That fallback cannot promise normal-path
    /// retention, only that the old descriptor no longer owns this endpoint.
    @Test("fallback closes before its second accept-loop join")
    func fallbackClosesBeforeSecondAcceptLoopJoin() async throws {
        #if canImport(Darwin)
            let fixture = try UnixSocketFixture()
            defer { fixture.cleanup() }

            let handler = HeldStep<Void>("accept-loop handler")
            let stopReturned = HeldStep<Void>("listener stop returned")
            stopReturned.release()
            let descriptorProbe = UnixSocketListeningDescriptorProbe(endpointPath: fixture.endpoint.path)
            let joinWait = UnixSocketShutdownWaitController(
                mode: .timeOutFirstAndWaitForSecondBarrier,
                descriptorProbe: descriptorProbe
            )
            let listener = UnixSocketListener(
                endpoint: fixture.endpoint,
                acceptLoopJoinWait: { barrier in joinWait.wait(for: barrier) }
            )

            try listener.start { connection in
                try? handler.arriveBlocking(())
                connection.close()
            }
            defer { listener.stop() }

            do {
                try descriptorProbe.recordListeningDescriptor()
                let served = try await valueFromDedicatedThread {
                    try UnixSocketClient.connect(endpoint: fixture.endpoint)
                }
                defer { served.close() }
                try await handler.firstArrival()

                // Act
                let stopping = Task {
                    await valueFromDedicatedThread {
                        listener.stop()
                        try? stopReturned.arriveBlocking(())
                    }
                }
                let firstJoinEntry = try await joinWait.firstJoin.firstArrival()
                let secondJoinEntry = try await joinWait.secondJoin.firstArrival()
                let stopReturnedAtSecondJoin = !stopReturned.recordedArrivals.isEmpty
                handler.release()
                try await stopReturned.firstArrival()
                await stopping.value
                await valueFromDedicatedThread { firstJoinEntry.barrier.wait() }

                // Assert
                #expect(firstJoinEntry.ownedEndpoint)
                #expect(!secondJoinEntry.ownedEndpoint)
                #expect(!stopReturnedAtSecondJoin)
                #expect(stopReturned.recordedArrivals.count == 1)
                #expect(joinWait.invocationCount == 2)
                await #expect(throws: (any Error).self) {
                    try await valueFromDedicatedThread { _ = try UnixSocketClient.connect(endpoint: fixture.endpoint) }
                }
            } catch {
                let fixtureError = error
                handler.release()
                await valueFromDedicatedThread { listener.stop() }
                throw fixtureError
            }
        #endif
    }

    /// A handler that outlives both existing join budgets cannot strand the
    /// stop caller. This selects both deadline-exceeded results without using
    /// elapsed time as the verdict, then drains both real queue barriers.
    @Test("stop returns after both bounded accept-loop joins expire")
    func stopReturnsAfterBothBoundedAcceptLoopJoinsExpire() async throws {
        #if canImport(Darwin)
            let fixture = try UnixSocketFixture()
            defer { fixture.cleanup() }

            let handler = HeldStep<Void>("accept-loop handler")
            let stopReturned = HeldStep<Void>("listener stop returned")
            stopReturned.release()
            let descriptorProbe = UnixSocketListeningDescriptorProbe(endpointPath: fixture.endpoint.path)
            let joinWait = UnixSocketShutdownWaitController(
                mode: .timeOutBothBarriers,
                descriptorProbe: descriptorProbe
            )
            let listener = UnixSocketListener(
                endpoint: fixture.endpoint,
                acceptLoopJoinWait: { barrier in joinWait.wait(for: barrier) }
            )

            try listener.start { connection in
                try? handler.arriveBlocking(())
                connection.close()
            }
            defer { listener.stop() }

            do {
                try descriptorProbe.recordListeningDescriptor()
                let served = try await valueFromDedicatedThread {
                    try UnixSocketClient.connect(endpoint: fixture.endpoint)
                }
                defer { served.close() }
                try await handler.firstArrival()

                // Act
                let stopping = Task {
                    await valueFromDedicatedThread {
                        listener.stop()
                        try? stopReturned.arriveBlocking(())
                    }
                }
                let firstJoinEntry = try await joinWait.firstJoin.firstArrival()
                let secondJoinEntry = try await joinWait.secondJoin.firstArrival()
                // Stop returns while the handler is still held.
                try await stopReturned.firstArrival()
                await stopping.value
                handler.release()
                await valueFromDedicatedThread { firstJoinEntry.barrier.wait() }
                await valueFromDedicatedThread { secondJoinEntry.barrier.wait() }
                let selectedJoinCount = joinWait.invocationCount
                await valueFromDedicatedThread { listener.stop() }
                let joinCountAfterRepeatedStop = joinWait.invocationCount

                // Assert
                #expect(firstJoinEntry.ownedEndpoint)
                #expect(!secondJoinEntry.ownedEndpoint)
                #expect(stopReturned.recordedArrivals.count == 1)
                #expect(selectedJoinCount == 2)
                #expect(joinCountAfterRepeatedStop == 3)
                await #expect(throws: (any Error).self) {
                    try await valueFromDedicatedThread { _ = try UnixSocketClient.connect(endpoint: fixture.endpoint) }
                }
            } catch {
                let fixtureError = error
                handler.release()
                await valueFromDedicatedThread { listener.stop() }
                throw fixtureError
            }
        #endif
    }

    /// A second `stop()`, and the one `deinit` runs, must not close a
    /// descriptor number that now belongs to an unrelated file.
    @Test("repeated stop leaves an unrelated descriptor untouched")
    func repeatedStopLeavesUnrelatedDescriptorUntouched() throws {
        #if canImport(Darwin)
            let fixture = try UnixSocketFixture()
            defer { fixture.cleanup() }

            let probe: TemporaryFileDescriptor
            do {
                let listener = UnixSocketListener(endpoint: fixture.endpoint)
                try listener.start { connection in connection.close() }
                listener.stop()

                // The listener's number is free now; take it before `deinit`
                // and the second `stop()` get a chance to close it again.
                probe = try TemporaryFileDescriptor()
                listener.stop()
            }

            defer { probe.cleanup() }
            #expect(probe.isOpen)
            #expect(probe.readBack() == "listener must not own this descriptor")
        #endif
    }

    @Test("send to a disconnected peer fails without SIGPIPE")
    func sendToDisconnectedPeerFailsWithoutSIGPIPE() async throws {
        #if canImport(Darwin)
            var descriptors: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
            }
            var localDescriptor: Int32? = descriptors[0]
            var peerDescriptor: Int32? = descriptors[1]
            defer {
                if let localDescriptor {
                    _ = Darwin.close(localDescriptor)
                }
                if let peerDescriptor {
                    _ = Darwin.close(peerDescriptor)
                }
            }

            try UnixSocketOptions.disableSigPipe(fileDescriptor: descriptors[0])
            let connection = UnixSocketConnection(fileDescriptor: descriptors[0])
            localDescriptor = nil
            defer { connection.close() }

            if let descriptor = peerDescriptor {
                _ = Darwin.close(descriptor)
                peerDescriptor = nil
            }

            await #expect(throws: UnixSocketTransportError.self) {
                try await valueFromDedicatedThread { try connection.send(Data("reply\n".utf8)) }
            }
        #endif
    }

    @Test("closed connection rejects operations before descriptor access")
    func closedConnectionRejectsOperationsBeforeDescriptorAccess() async throws {
        #if canImport(Darwin)
            var descriptors: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
            }

            let connection = UnixSocketConnection(fileDescriptor: descriptors[0])
            connection.close()
            _ = Darwin.close(descriptors[1])

            let credentialProvider = RecordingPeerCredentialProvider()
            #expect(throws: UnixSocketTransportError(reason: .connectionClosed)) {
                _ = try connection.peerCredentials(using: credentialProvider)
            }
            #expect(credentialProvider.invocationCount == 0)

            await #expect(throws: UnixSocketTransportError(reason: .connectionClosed)) {
                try await valueFromDedicatedThread { try connection.send(Data("stale\n".utf8)) }
            }
            await #expect(throws: UnixSocketTransportError(reason: .connectionClosed)) {
                try await valueFromDedicatedThread { _ = try connection.receive(maxBytes: 64) }
            }
        #endif
    }
}

private final class RecordingPeerCredentialProvider: PeerCredentialProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedInvocationCount = 0

    var invocationCount: Int {
        lock.withLock { storedInvocationCount }
    }

    func credentials(forAcceptedSocket _: Int32) throws -> PeerCredentials {
        lock.withLock {
            storedInvocationCount += 1
        }
        return PeerCredentials(userIdentifier: getuid(), groupIdentifier: getgid())
    }
}

private struct UnixSocketFixture: Sendable {
    let directory: URL
    let endpoint: UnixSocketEndpoint

    init() throws {
        directory = URL(
            fileURLWithPath: "/tmp/asipc-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        endpoint = UnixSocketEndpoint(path: directory.appendingPathComponent("ipc.sock").path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A real file holding a descriptor, used to prove the listener does not close
/// a number it no longer owns. `isOpen` asks the kernel about this exact
/// descriptor rather than trusting that nothing touched it.
private struct TemporaryFileDescriptor {
    static let contents = "listener must not own this descriptor"

    let url: URL
    let descriptor: Int32

    init() throws {
        url = URL(
            fileURLWithPath: "/tmp/asipc-probe-\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).txt"
        )
        try Self.contents.write(to: url, atomically: true, encoding: .utf8)
        descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
        }
    }

    var isOpen: Bool {
        fcntl(descriptor, F_GETFD) != -1
    }

    func readBack() -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return String(bytes: buffer[0..<count], encoding: .utf8)
    }

    func cleanup() {
        if isOpen {
            _ = close(descriptor)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
