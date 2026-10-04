import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

#if canImport(Darwin)
    import Darwin
#endif

@Suite("App IPC waiting connection")
struct AgentStudioAppIPCConnectionWaitingTests {
    @Test("EOF cancels a waiting method beside the reader as caller gone")
    func eofCancelsWaitingHandler() async throws {
        let hold = HeldStep<AppIPCConnectionContext>("waiting request before caller EOF")
        let source = makeConnectionContractFactSource()
        let recorder = try source.attach()
        let registration = try makeHeldConnectionRegistration(hold: hold, source: source)
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(additionalRegistrations: [registration]) },
            releaseHeldWork: { hold.retire() },
            body: { fixture in
                try fixture.server.start()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection, request: try connectionContractRequest("fixture.waiting", id: 1))
                _ = try await hold.firstArrival()
                try await recorder.expectNext(in: "waiting", .admitted)
                connection.close()
                try await recorder.expectNext(in: "waiting", .ended(.eof))
            }
        )
        try await recorder.finish()
    }

    @Test("a read error cancels the waiting handler with the distinct error cause")
    func readErrorCancelsWaitingHandler() async throws {
        let hold = HeldStep<AppIPCConnectionContext>("waiting request before socket read error")
        let failRead = Mutex(false)
        let source = makeConnectionContractFactSource()
        let recorder = try source.attach()
        let registration = try makeHeldConnectionRegistration(hold: hold, source: source)
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    additionalRegistrations: [registration],
                    makeConnectionIO: { connection in
                        let live = AppIPCConnectionIO.live(connection)
                        return AppIPCConnectionIO(
                            receive: { count in
                                let data = try live.receive(count)
                                if failRead.withLock({ $0 }) {
                                    throw UnixSocketTransportError(reason: .readFailed, errnoCode: EIO)
                                }
                                return data
                            },
                            send: live.send,
                            close: live.close
                        )
                    }
                )
            },
            releaseHeldWork: { hold.retire() },
            body: { fixture in
                try fixture.server.start()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection, request: try connectionContractRequest("fixture.waiting", id: 1))
                _ = try await hold.firstArrival()
                try await recorder.expectNext(in: "waiting", .admitted)
                failRead.withLock { $0 = true }
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection, request: try connectionContractRequest("fixture.failRead", id: 2))
                try await recorder.expectNext(in: "waiting", .ended(.error))
            }
        )
        try await recorder.finish()
    }

    @Test("both shutdown entry points cancel waiting work as app stopping", arguments: [false, true])
    func serverStopCancelsAsStopping(graceful: Bool) async throws {
        let hold = HeldStep<AppIPCConnectionContext>("waiting request before server stop")
        let source = makeConnectionContractFactSource()
        let recorder = try source.attach()
        let registration = try makeHeldConnectionRegistration(hold: hold, source: source)
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(additionalRegistrations: [registration]) },
            releaseHeldWork: { hold.retire() },
            body: { fixture in
                try fixture.server.start()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection, request: try connectionContractRequest("fixture.waiting", id: 1))
                _ = try await hold.firstArrival()
                try await recorder.expectNext(in: "waiting", .admitted)
                if graceful { await fixture.stopAcceptingConnections() } else { await fixture.stop() }
                try await recorder.expectNext(in: "waiting", .ended(.stopping))
            }
        )
        try await recorder.finish()
    }

    @Test("connectionBusy refuses every subsequent request before asynchronous processing")
    func busyRefusalPrecedesAuthenticationAndTargetResolution() async throws {
        let hold = HeldStep<AppIPCConnectionContext>("waiting request while connection is busy")
        let source = makeConnectionContractFactSource()
        let recorder = try source.attach()
        let waiting = try makeHeldConnectionRegistration(hold: hold, source: source)
        let forbiddenResolution = HeldStep<String>("target resolution forbidden while connection busy")
        forbiddenResolution.release()
        let ordinary = try makeConnectionContractRegistration(
            name: "fixture.read",
            resolve: {
                source.sink("ordinary", .targetResolved)
                try await forbiddenResolution.arrive("resolved")
            },
            handler: { _ in }
        )
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(additionalRegistrations: [waiting, ordinary]) },
            releaseHeldWork: { hold.retire() },
            body: { fixture in
                try fixture.server.start()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: fixture.paths.socketURL.path)
                defer { connection.close() }
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection, request: try connectionContractRequest("fixture.waiting", id: 1))
                _ = try await hold.firstArrival()
                try await recorder.expectNext(in: "waiting", .admitted)
                let opening = await recorder.mark("ordinary")
                let requests = [
                    try connectionContractRequest("fixture.read", id: 2),
                    try JSONRPCClientRequest(
                        id: .number(3), method: "auth.login",
                        params: .object(["token": .string("must-not-authenticate")])),
                    try connectionContractRequest("session.event", id: 4),
                    try connectionContractRequest("method.unknown", id: 5),
                ]
                for request in requests {
                    try await sendRequestWithoutBlockingCooperativePool(connection: connection, request: request)
                    let response = try await receiveConnectionContractReply(
                        connection: connection, named: "busy refusal for request \(request.id)"
                    )
                    #expect(response.id == request.id)
                    #expect(response.error?.code == -32_005)
                    #expect(response.error?.data == .object(["reason": .string("connectionBusy")]))
                }
                connection.close()
                try await recorder.expectNext(in: "waiting", .ended(.eof))
                await fixture.stopAcceptingConnections()
                await fixture.server.joinConnectionHandlers()
                source.sink("ordinary", .ended(.eof))
                try await recorder.expectNone(
                    of: { $0 == .targetResolved }, "busy target resolution",
                    from: opening, closedBy: { $0 == .ended(.eof) }
                )
                #expect(forbiddenResolution.recordedArrivals.isEmpty)
            }
        )
        try await recorder.finish()
    }
}
