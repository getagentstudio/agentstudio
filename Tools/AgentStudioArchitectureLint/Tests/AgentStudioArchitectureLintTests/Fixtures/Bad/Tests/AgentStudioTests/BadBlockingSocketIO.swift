import AgentStudioIPCTransport

func directCalls(connection: UnixSocketConnection, reader: inout TestFrameReader) throws {
    let client = try UnixSocketClient.connect(endpoint: endpoint)
    try client.send(data)
    _ = try connection.receive(maxBytes: 64)
    try sendRequest(connection: connection, request: request)
    _ = try sendRequest(socketPath: socketPath, request: request)
    try login(connection: connection, token: token, requestId: 1, reader: &reader)
    _ = try reader.receiveResponse(connection: connection)
    _ = try reader.receiveFrame(connection: connection)
}

func qualifiedCalls(connection: AgentStudioIPCTransport.UnixSocketConnection) throws {
    _ = try AgentStudioIPCTransport.UnixSocketClient.connect(endpoint: endpoint)
    try connection.send(data)
}
