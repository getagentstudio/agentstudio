import AgentStudioIPCTransport
import AgentStudioTestSupport
import Synchronization
import Testing

@Suite("IPC client execution boundary", .serialized)
struct IPCClientExecutionBoundaryTests {
    @Test("three real clients send and receive outside Swift tasks")
    func concurrentClientsKeepSocketIOOffCooperativePool() async throws {
        // Boundary proof, not a reproduction of a three-thread pool starving.
        // Observe actual socket operations, then join every real client reply.
        let observations = SocketIORecorder()
        try await withLiveServer(
            makeFixture: { try LiveServerFixture() },
            body: { fixture in
                try fixture.server.start()
                try await withThrowingTaskGroup(of: Void.self) { clients in
                    for requestID in 1...3 {
                        clients.addTask {
                            let response = try await sendRequestWithoutBlockingMainActor(
                                socketPath: fixture.paths.socketURL.path,
                                request: JSONRPCClientRequest(
                                    id: .number(requestID), method: "system.ping", params: .object([:])),
                                observeIO: { operation, insideTask in
                                    observations.record(operation: operation, insideTask: insideTask)
                                }
                            )
                            #expect(response.id == .number(requestID))
                            #expect(response.error == nil)
                        }
                    }
                    try await clients.waitForAll()
                }
            })
        let recorded = observations.recorded
        #expect(recorded.filter { $0.operation == .send }.count == 3)
        #expect(recorded.filter { $0.operation == .receive }.count >= 3)
        #expect(recorded.allSatisfy { !$0.insideTask }, "socket I/O must run outside a Swift task: \(recorded)")
    }

    @Test("the existing dedicated-thread primitive runs outside a Swift task")
    func dedicatedThreadPrimitiveLeavesSwiftTask() async {
        let insideTask = await withoutBlockingCooperativePool {
            withUnsafeCurrentTask { $0 != nil }
        }
        #expect(!insideTask)
    }
}

private struct SocketIOObservation: Sendable {
    let operation: TestSocketIOOperation
    let insideTask: Bool
}

private final class SocketIORecorder: Sendable {
    private let observations = Mutex<[SocketIOObservation]>([])

    func record(operation: TestSocketIOOperation, insideTask: Bool) {
        observations.withLock { $0.append(SocketIOObservation(operation: operation, insideTask: insideTask)) }
    }

    var recorded: [SocketIOObservation] {
        observations.withLock { $0 }
    }
}
