import AgentStudioIPCTransport
import Foundation
import Network

func explicitHops(connection: UnixSocketConnection) async throws {
    try await withoutBlockingCooperativePool {
        _ = try UnixSocketClient.connect(endpoint: endpoint)
        try connection.send(data)
        _ = try connection.receive(maxBytes: 64)
        try sendRequest(connection: connection, request: request)
    }
    try await valueFromDedicatedThread {
        try connection.send(data)
        _ = try connection.receive(maxBytes: 64)
    }
}

func dispatchOwners(connection: UnixSocketConnection) {
    let workerQueue = DispatchQueue(label: "socket-owner")
    workerQueue.async { try? connection.send(data) }
    DispatchQueue.global().async { _ = try? connection.receive(maxBytes: 64) }
    Thread.detachNewThread { try? connection.send(data) }
    let worker = Thread { try? connection.send(data) }
    worker.start()
}

func listenerOwners(connection: UnixSocketConnection) throws {
    let listener = UnixSocketListener(endpoint: endpoint)
    try listener.start { socket in
        try socket.send(data)
    }
    let networkListener = try NWListener(using: .tcp)
    networkListener.newConnectionHandler = { _ in try? connection.send(data) }
    networkListener.start(queue: DispatchQueue.global())
}

func unrelatedCalls() async {
    await stateMachine.send(.verify)
    fixture.send(.moveSelectionDown)
    await asyncReader.receiveResponse(connection: connection)
    await asyncReader.receiveFrame(connection: connection)
    // UnixSocketClient.connect(endpoint: endpoint)
    let source = "connection.receive(maxBytes: 64)"
}
