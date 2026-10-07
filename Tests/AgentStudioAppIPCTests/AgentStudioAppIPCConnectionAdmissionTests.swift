import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("App IPC connection admission")
struct AgentStudioAppIPCConnectionAdmissionTests {
    @Test("write-side EOF drains accepted reply bytes before the server closes")
    func halfClosePreservesLegacyReplyBytes() async throws {
        let heldWrite = HeldStep<Data>("half-closed peer's accepted reply on the I/O queue")
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(makeConnectionIO: { connection in
                    let live = AppIPCConnectionIO.live(connection)
                    return AppIPCConnectionIO(
                        receive: live.receive,
                        send: { data in
                            try heldWrite.arriveBlocking(data)
                            try live.send(data)
                        },
                        close: live.close
                    )
                })
            },
            releaseHeldWork: { heldWrite.retire() },
            body: { fixture in
                try fixture.server.start()
                let client = try await connectHalfCloseTestSocket(socketPath: fixture.paths.socketURL.path)
                defer { client.connection.close() }
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: client.connection, request: try connectionContractRequest("system.ping", id: 1)
                )
                try await valueFromDedicatedThread { try client.finishSending() }
                let expected = try await heldWrite.firstArrival()
                let frame = try #require(String(data: expected.dropLast(), encoding: .utf8))
                let reply = try JSONRPCCodec.decodeResponse(frame)
                #expect(reply.id == .number(1))
                #expect(reply.error == nil)
                #expect(
                    reply.result == .object(["ok": .bool(true), "runtimeId": .string(fixture.runtimeId.uuidString)]))
                heldWrite.release()
                #expect(try await receiveBytesThroughEOF(connection: client.connection) == expected)
                await fixture.server.joinConnectionHandlers()
                #expect(fixture.server.trackedConnectionHandlerCount == 0)
            }
        )
    }

    @Test("pipelined login establishes authentication before the next frame")
    func pipelinedLoginThenAuthenticatedCall() async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture() },
            body: { fixture in
                let token = fixture.installDebugCredential()
                try fixture.server.start()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                let requests = [
                    try JSONRPCClientRequest(
                        id: .number(1), method: "auth.login", params: .object(["token": .string(token.rawValue)])),
                    try connectionContractRequest("auth.status", id: 2),
                ]
                // One transport write makes this an actual pipeline, rather
                // than waiting for login before sending the dependent frame.
                try await valueFromDedicatedThread {
                    var frames = Data()
                    for request in requests {
                        frames.append(
                            try NDJSONFrameEncoder.encode(JSONRPCCodec.encodeRequest(request), maxFrameBytes: 65_536))
                    }
                    try connection.send(frames)
                }
                var reader = TestFrameReader()
                let login = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                let status = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                #expect(login.id == .number(1))
                #expect(status.id == .number(2))
                #expect(login.error == nil)
                #expect(status.error == nil)
                #expect(login.result == status.result)
            }
        )
    }

    @Test("dependent inline mutations commit and reply in admission order")
    func dependentInlineWritesStayOrdered() async throws {
        let firstWrite = HeldStep<String>("first inline write before commit")
        let observedWrites = HeldStep<String>("inline write commit witness")
        observedWrites.release()
        let first = try makeConnectionContractRegistration(name: "fixture.firstWrite") { _ in
            try await firstWrite.arrive("first")
            try await observedWrites.arrive("first")
        }
        let second = try makeConnectionContractRegistration(name: "fixture.secondWrite") { _ in
            try await observedWrites.arrive("second")
        }
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(additionalRegistrations: [first, second]) },
            releaseHeldWork: { firstWrite.release() },
            body: { fixture in
                try fixture.server.start()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection, request: try connectionContractRequest("fixture.firstWrite", id: 1))
                #expect(try await firstWrite.firstArrival() == "first")
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection, request: try connectionContractRequest("fixture.secondWrite", id: 2))
                firstWrite.release()
                var reader = TestFrameReader()
                let firstReply = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                let secondReply = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                #expect(firstReply.id == .number(1))
                #expect(secondReply.id == .number(2))
                #expect(firstReply.error == nil)
                #expect(secondReply.error == nil)
                #expect(observedWrites.recordedArrivals == ["first", "second"])
            }
        )
    }
}
