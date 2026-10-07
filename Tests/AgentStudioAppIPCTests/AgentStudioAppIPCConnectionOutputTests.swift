import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

#if canImport(Darwin)
    import Darwin
#endif

@Suite("App IPC connection output")
struct AgentStudioAppIPCConnectionOutputTests {
    @Test("stop joins a queued write to a peer that never reads and returns its accounting to zero")
    func stopJoinsNonReadingPeerAndReleasesQueuedBytes() async throws {
        let writerCreated = HeldStep<AgentStudioAppIPCConnectionWriter>("non-reading peer's real connection writer")
        writerCreated.release()
        let enteredWrite = HeldStep<Data>("non-reading peer's large accepted write")
        enteredWrite.release()
        let source = makeOutputFactSource()
        let recorder = try source.attach()
        let descriptor = try TypedConnectionRegistrationFixture.preAuthenticationDescriptor(
            name: "fixture.largeReply", parameters: IPCEmptyParams(),
            result: IPCConnectionLargeReply(text: "example")
        )
        let registrations = try [
            AppIPCTypedMethodRegistration(
                descriptorRepresentations: IPCMethodDescriptorRepresentations(typedDescriptor: descriptor),
                correlation: AppIPCCorrelation<IPCEmptyParams>.notRequired,
                resolveTarget: { parameters, _, _ in
                    AppIPCTargetResolution(parameters: parameters, canonicalHandle: nil, target: .app)
                },
                connectionHandler: { _, _, _ in
                    IPCConnectionLargeReply(text: String(repeating: "x", count: 3 * 1_048_576))
                }
            ).erase()
        ]
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    additionalRegistrations: registrations,
                    makeConnectionIO: { connection in
                        let live = AppIPCConnectionIO.live(connection)
                        return AppIPCConnectionIO(
                            receive: live.receive,
                            send: { data in
                                try enteredWrite.arriveBlocking(data)
                                do {
                                    try live.send(data)
                                    source.sink("output", .written(data))
                                } catch {
                                    source.sink("output", .closed)
                                    throw error
                                }
                            },
                            close: live.close
                        )
                    },
                    makeConnectionWriter: { io, maxFrameBytes in
                        let writer = AgentStudioAppIPCConnectionWriter(io: io, maxFrameBytes: maxFrameBytes)
                        try? writerCreated.arriveBlocking(writer)
                        return writer
                    }
                )
            },
            body: { fixture in
                try fixture.server.start()
                let client = try await connectHalfCloseTestSocket(
                    socketPath: fixture.paths.socketURL.path, receiveBufferBytes: 4096)
                defer { client.connection.close() }
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: client.connection, request: try connectionContractRequest("fixture.largeReply", id: 1)
                )
                let bytes = try await enteredWrite.firstArrival()
                #expect(bytes.count > 3 * 1_048_576)
                let writer = try await writerCreated.firstArrival()
                #expect(await writer.queuedOutputByteCount == bytes.count)
                // This client performs no receive. Stop is the real descriptor
                // shutdown that must release the server's accepted output.
                await fixture.stop()
                await fixture.server.joinConnectionHandlers()
                try await recorder.expectNext(in: "output", .closed)
                #expect(await writer.queuedOutputByteCount == 0)
                #expect(fixture.server.trackedConnectionHandlerCount == 0)
            }
        )
        try await recorder.finish()
    }

    @Test("enqueue returns before a held write and the serial writer preserves exact frame bytes")
    func enqueueAcceptanceAndDependentFrameOrder() async throws {
        let firstWrite = HeldStep<Data>("first queued socket write off the cooperative pool")
        let source = makeOutputFactSource()
        let recorder = try source.attach()
        let io = AppIPCConnectionIO(
            receive: { _ in Data() },
            send: { data in
                try firstWrite.arriveBlocking(data)
                source.sink("output", .written(data))
            },
            close: { source.sink("output", .closed) }
        )
        let writer = AgentStudioAppIPCConnectionWriter(io: io, maxFrameBytes: 1_048_576)
        do {
            #expect(try await writer.sendFrame("first") == .accepted)
            #expect(try await firstWrite.firstArrival() == Data("first\n".utf8))
            #expect(try await writer.sendFrame("second") == .accepted)
            #expect(try await writer.sendFrame("third") == .accepted)
            firstWrite.release()
            for frame in ["first", "second", "third"] {
                try await recorder.expectNext(in: "output", .written(Data("\(frame)\n".utf8)))
            }
            await writer.finishAcceptedOutput()
            #expect(await writer.queuedOutputByteCount == 0)
        } catch {
            firstWrite.retire()
            throw error
        }
        try await recorder.finish()
    }

    @Test("an output frame above 4 MiB is refused before any transport write")
    func oversizedEnqueueClosesWithoutWriting() async throws {
        let written = HeldStep<Data>("transport write forbidden for oversized output")
        let source = makeOutputFactSource()
        let recorder = try source.attach()
        written.release()
        let writer = AgentStudioAppIPCConnectionWriter(
            io: AppIPCConnectionIO(
                receive: { _ in Data() },
                send: { try written.arriveBlocking($0) },
                close: { source.sink("connection", .closed) }
            ),
            maxFrameBytes: 5 * 1_048_576
        )
        // The NDJSON delimiter also occupies queued bytes.
        let frame = String(repeating: "x", count: 4 * 1_048_576)
        #expect(try await writer.sendFrame(frame) == .overloaded)
        #expect(written.recordedArrivals.isEmpty)
        try await recorder.expectNext(in: "connection", .closed)
        await writer.finishAcceptedOutput()
        #expect(await writer.queuedOutputByteCount == 0)
        try await recorder.finish()
    }

    @Test("exactly 4 MiB of held output is accepted and one more byte overloads")
    func exactQueuedByteBoundIncludesInFlightWrite() async throws {
        let heldWrite = HeldStep<Int>("4 MiB queued write held on its dedicated I/O queue")
        let source = makeOutputFactSource()
        let recorder = try source.attach()
        let writer = AgentStudioAppIPCConnectionWriter(
            io: AppIPCConnectionIO(
                receive: { _ in Data() },
                send: { data in
                    try heldWrite.arriveBlocking(data.count)
                    source.sink("output", .written(Data()))
                },
                close: { source.sink("connection", .closed) }
            ),
            maxFrameBytes: 5 * 1_048_576
        )
        do {
            #expect(try await writer.sendFrame(String(repeating: "x", count: 4 * 1_048_576 - 1)) == .accepted)
            #expect(try await heldWrite.firstArrival() == 4 * 1_048_576)
            #expect(try await writer.sendFrame("") == .overloaded)
            try await recorder.expectNext(in: "connection", .closed)
            heldWrite.release()
            try await recorder.expectNext(in: "output", .written(Data()))
            await writer.finishAcceptedOutput()
            #expect(await writer.queuedOutputByteCount == 0)
            #expect(heldWrite.recordedArrivals == [4 * 1_048_576])
        } catch {
            heldWrite.retire()
            throw error
        }
        try await recorder.finish()
    }

    @Test("a queued write failure closes output after enqueue was accepted")
    func queuedWriteFailureClosesConnection() async throws {
        let heldWrite = HeldStep<Data>("queued write before transport failure")
        let source = makeOutputFactSource()
        let recorder = try source.attach()
        let writer = AgentStudioAppIPCConnectionWriter(
            io: AppIPCConnectionIO(
                receive: { _ in Data() },
                send: { try heldWrite.arriveBlocking($0) },
                close: { source.sink("output", .closed) }
            ),
            maxFrameBytes: 1_048_576
        )
        do {
            #expect(try await writer.sendFrame("accepted-before-failure") == .accepted)
            _ = try await heldWrite.firstArrival()
            heldWrite.fail(UnixSocketTransportError(reason: .writeFailed, errnoCode: EPIPE))
            try await recorder.expectNext(in: "output", .closed)
            await writer.finishAcceptedOutput()
            #expect(await writer.queuedOutputByteCount == 0)
        } catch {
            heldWrite.retire()
            throw error
        }
        try await recorder.finish()
    }

    @Test("a stalled socket subscriber cannot delay broker publication to a healthy subscriber")
    func stalledSubscriberOnlyCostsAnEnqueue() async throws {
        let heldWrite = HeldStep<Data>("slow subscriber's queued socket write")
        let source = makeOutputFactSource()
        let recorder = try source.attach()
        let slowWriter = AgentStudioAppIPCConnectionWriter(
            io: AppIPCConnectionIO(
                receive: { _ in Data() },
                send: { data in
                    try heldWrite.arriveBlocking(data)
                    source.sink("slow", .written(data))
                },
                close: {}
            ),
            maxFrameBytes: 1_048_576
        )
        let broker = IPCEventBroker()
        let principal = TypedConnectionRegistrationFixture().diagnosticPrincipal
        let slowConnection = UUIDv7.generate()
        let healthyConnection = UUIDv7.generate()
        _ = try await broker.subscribe(
            eventNames: [.terminalCommandFinished], principal: principal,
            connectionId: slowConnection, subscriber: AgentStudioAppIPCSocketEventSubscriber(writer: slowWriter)
        )
        _ = try await broker.subscribe(
            eventNames: [.terminalCommandFinished], principal: principal,
            connectionId: healthyConnection, subscriber: OutputFactSubscriber(source: source)
        )
        let first = makeOutputNotification()
        let second = makeOutputNotification()
        // Publication must finish regardless of the dictionary's subscriber
        // order, while the physical write remains held.
        _ = await broker.publish(first) { _, _ in true }
        do {
            _ = try await heldWrite.firstArrival()
            try await expectOutputNotification(first, in: "healthy", recorder: recorder)
            _ = await broker.publish(second) { _, _ in true }
            try await expectOutputNotification(second, in: "healthy", recorder: recorder)
            heldWrite.release()
            for notification in [first, second] {
                try await expectOutputNotification(notification, in: "slow", recorder: recorder)
            }
            await slowWriter.finishAcceptedOutput()
            #expect(await slowWriter.queuedOutputByteCount == 0)
        } catch {
            heldWrite.retire()
            await broker.removeSubscriptions(connectionId: slowConnection)
            await broker.removeSubscriptions(connectionId: healthyConnection)
            throw error
        }
        await broker.removeSubscriptions(connectionId: slowConnection)
        await broker.removeSubscriptions(connectionId: healthyConnection)
        try await recorder.finish()
    }

    @Test("a slow raw-socket subscriber leaves a healthy socket receiving in order")
    func slowSocketDoesNotBlockHealthySocket() async throws {
        let heldWrite = HeldStep<Data>("slow raw-socket subscriber output")
        let acceptedConnections = Mutex(0)
        let broker = IPCEventBroker()
        let source = makeOutputFactSource()
        let recorder = try source.attach()
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    eventBroker: broker,
                    makeConnectionIO: { connection in
                        let live = AppIPCConnectionIO.live(connection)
                        let isSlow = acceptedConnections.withLock { count in
                            count += 1
                            return count == 1
                        }
                        guard isSlow else { return live }
                        return AppIPCConnectionIO(
                            receive: live.receive,
                            send: { data in
                                if let frame = String(data: data, encoding: .utf8),
                                    frame.contains("events.notification")
                                {
                                    try heldWrite.arriveBlocking(data)
                                    source.sink("slow", .written(data))
                                }
                                try live.send(data)
                            },
                            close: live.close
                        )
                    }
                )
            },
            releaseHeldWork: { heldWrite.retire() },
            body: { fixture in
                let token = fixture.installDebugCredential()
                try fixture.server.start()
                let slow = try await connectWithoutBlockingCooperativePool(socketPath: fixture.paths.socketURL.path)
                defer { slow.close() }
                var slowReader = TestFrameReader()
                try await subscribeOutputSocket(slow, token: token, reader: &slowReader)
                let healthy = try await connectWithoutBlockingCooperativePool(socketPath: fixture.paths.socketURL.path)
                defer { healthy.close() }
                var healthyReader = TestFrameReader()
                try await subscribeOutputSocket(healthy, token: token, reader: &healthyReader)
                #expect(await broker.subscriptionCount() == 2)
                let first = makeOutputNotification()
                let firstFailures = await broker.publish(first) { _, _ in true }
                #expect(firstFailures.isEmpty)
                _ = try await heldWrite.firstArrival()
                let healthyFirst = try await healthyReader.receiveFrameWithoutBlockingCooperativePool(
                    connection: healthy)
                #expect(try decodeOutputNotification(healthyFirst) == first)
                let second = makeOutputNotification()
                let secondFailures = await broker.publish(second) { _, _ in true }
                #expect(secondFailures.isEmpty)
                let healthySecond = try await healthyReader.receiveFrameWithoutBlockingCooperativePool(
                    connection: healthy)
                #expect(try decodeOutputNotification(healthySecond) == second)
                heldWrite.release()
                for notification in [first, second] {
                    let fact = try await expectOutputNotification(notification, in: "slow", recorder: recorder)
                    let observed = try await slowReader.receiveFrameWithoutBlockingCooperativePool(connection: slow)
                    #expect(Data((observed + "\n").utf8) == fact)
                }
            }
        )
        #expect(await broker.subscriptionCount() == 0)
        try await recorder.finish()
    }

    @Test("a queued failure closes its raw socket and removes its server subscriptions")
    func queuedFailureCleansUpSocketSubscriptions() async throws {
        let heldWrite = HeldStep<Data>("raw-socket queued notification before write failure")
        let source = makeOutputFactSource()
        let recorder = try source.attach()
        let broker = IPCEventBroker()
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    eventBroker: broker,
                    makeConnectionIO: { connection in
                        let live = AppIPCConnectionIO.live(connection)
                        return AppIPCConnectionIO(
                            receive: live.receive,
                            send: { data in
                                if let frame = String(data: data, encoding: .utf8),
                                    frame.contains("events.notification")
                                {
                                    try heldWrite.arriveBlocking(data)
                                }
                                try live.send(data)
                            },
                            close: {
                                live.close()
                                source.sink("output", .closed)
                            }
                        )
                    }
                )
            },
            releaseHeldWork: { heldWrite.retire() },
            body: { fixture in
                let token = fixture.installDebugCredential()
                try fixture.server.start()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                var reader = TestFrameReader()
                try await subscribeOutputSocket(connection, token: token, reader: &reader)
                #expect(await broker.subscriptionCount() == 1)
                let failures = await broker.publish(makeOutputNotification()) { _, _ in true }
                #expect(failures.isEmpty)
                _ = try await heldWrite.firstArrival()
                heldWrite.fail(UnixSocketTransportError(reason: .writeFailed, errnoCode: EPIPE))
                try await recorder.expectNext(in: "output", .closed)
                await #expect(throws: TestFrameReaderError.endOfStream) {
                    try await reader.receiveFrameWithoutBlockingCooperativePool(connection: connection)
                }
                // Physical closure was witnessed before this lifecycle join;
                // the join cannot supply the missing close and hide a failure.
                await fixture.server.joinConnectionHandlers()
                #expect(await broker.subscriptionCount() == 0)
                #expect(fixture.server.trackedConnectionHandlerCount == 0)
            }
        )
        try await recorder.finish()
    }
}

enum IPCConnectionOutputFact: Equatable, Sendable {
    case written(Data)
    case closed
}

private struct IPCConnectionLargeReply: Codable, Equatable, Sendable, IPCSchemaProviding {
    let text: String

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [.init(name: "text", description: "Large queued reply", schema: .string(minimumLength: 1))])
    }
}

private func decodeOutputNotification(_ frame: String) throws -> IPCEventNotification {
    let request = try JSONRPCCodec.decodeRequest(frame)
    try #require(request.method == "events.notification")
    try #require(request.id == nil)
    return try decodeJSONValue(IPCEventNotification.self, from: #require(request.params))
}

@discardableResult
private func expectOutputNotification(
    _ notification: IPCEventNotification,
    in scope: String,
    recorder: FactRecorder<String, IPCConnectionOutputFact>
) async throws -> Data {
    let fact = try await recorder.expectNext(
        in: scope,
        where: { fact in
            guard case .written(let bytes) = fact, let frame = String(data: bytes, encoding: .utf8) else {
                return false
            }
            return (try? decodeOutputNotification(frame)) == notification
        },
        "encoded notification \(notification.eventId)"
    )
    guard case .written(let bytes) = fact else { throw TestFrameReaderError.endOfStream }
    return bytes
}

func makeOutputFactSource() -> LocalFactSource<String, IPCConnectionOutputFact> {
    LocalFactSource(
        vocabulary: FactVocabulary(
            describeScope: { $0 },
            describeFact: { fact in
                switch fact {
                case .written(let data): "written(\(data.count) bytes)"
                case .closed: "closed"
                }
            },
            isClosing: { _, fact in fact == .closed }
        )
    )
}

private struct OutputFactSubscriber: IPCEventSubscriber {
    let source: LocalFactSource<String, IPCConnectionOutputFact>

    func deliver(_ frame: String) async throws -> IPCEventDeliveryResult {
        source.sink("healthy", .written(Data(frame.utf8)))
        return .delivered
    }
}

func makeOutputNotification() -> IPCEventNotification {
    IPCEventNotification(
        eventId: UUIDv7.generate(), name: .terminalCommandFinished,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_001),
        payload: .terminal(
            IPCTerminalEventPayload(paneId: UUIDv7.generate(), condition: .commandFinished, exitCode: 0, duration: 0.5))
    )
}

private func subscribeOutputSocket(
    _ connection: UnixSocketConnection,
    token: AgentStudioIPCSubjectToken,
    reader: inout TestFrameReader
) async throws {
    try await loginWithoutBlockingMainActor(connection: connection, token: token, requestId: 1, reader: &reader)
    try await sendRequestWithoutBlockingCooperativePool(
        connection: connection,
        request: try JSONRPCClientRequest(
            id: .number(2), method: "events.subscribe",
            params: .object([
                "eventNames": .array([.string(IPCEventName.terminalCommandFinished.rawValue)]),
                "correlationId": .string(UUIDv7.generate().uuidString),
            ])
        )
    )
    let subscribed = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
    try #require(subscribed.error == nil)
    try #require(subscribed.id == .number(2))
}
