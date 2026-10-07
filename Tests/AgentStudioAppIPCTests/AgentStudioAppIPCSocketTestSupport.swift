import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import AgentStudioTestSupport
import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#endif

struct HalfCloseTestSocket: Sendable {
    let connection: UnixSocketConnection
    let finishSending: @Sendable () throws -> Void
}

/// Retains the real client descriptor only to exercise SHUT_WR. Transport
/// framing and reads still use the ordinary UnixSocketConnection path.
func connectHalfCloseTestSocket(socketPath: String, receiveBufferBytes: Int32? = nil) async throws
    -> HalfCloseTestSocket
{
    try await withoutBlockingCooperativePool {
        #if canImport(Darwin)
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
            }
            do {
                if var receiveBufferBytes {
                    guard
                        Darwin.setsockopt(
                            descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBufferBytes,
                            socklen_t(MemoryLayout<Int32>.size)
                        ) == 0
                    else {
                        throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
                    }
                }
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = socketPath.utf8CString.map { UInt8(bitPattern: $0) }
                guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                    throw UnixSocketTransportError(reason: .pathTooLong)
                }
                withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
                let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(descriptor, $0, length)
                    }
                }
                guard connected == 0 else { throw UnixSocketTransportError(reason: .connectFailed, errnoCode: errno) }
                let connection = UnixSocketConnection(fileDescriptor: descriptor)
                return HalfCloseTestSocket(
                    connection: connection,
                    finishSending: {
                        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
                            throw UnixSocketTransportError(reason: .closeFailed, errnoCode: errno)
                        }
                    }
                )
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        #else
            throw UnixSocketTransportError(reason: .unsupportedPlatform)
        #endif
    }
}

func receiveBytesThroughEOF(connection: UnixSocketConnection) async throws -> Data {
    try await withoutBlockingCooperativePool {
        var received = Data()
        while true {
            let bytes = try connection.receive(maxBytes: 4096)
            guard !bytes.isEmpty else { return received }
            received.append(bytes)
        }
    }
}

enum TestSocketIOOperation: Sendable {
    case send
    case receive
}

/// Optional boundary witness for execution-placement tests; never changes I/O.
typealias TestSocketIOObserver = @Sendable (TestSocketIOOperation, Bool) -> Void

func sendRequest(
    socketPath: String,
    request: JSONRPCClientRequest,
    observeIO: TestSocketIOObserver? = nil
) throws -> JSONRPCResponseMessage {
    let connection = try UnixSocketClient.connect(endpoint: UnixSocketEndpoint(path: socketPath))
    defer {
        connection.close()
    }
    try sendRequest(connection: connection, request: request, observeIO: observeIO)
    var reader = TestFrameReader(observeIO: observeIO)
    return try reader.receiveResponse(connection: connection)
}

func sendRequestWithoutBlockingMainActor(
    socketPath: String,
    request: JSONRPCClientRequest,
    observeIO: TestSocketIOObserver? = nil
) async throws -> JSONRPCResponseMessage {
    try await sendRequestWithoutBlockingCooperativePool(
        socketPath: socketPath, request: request, observeIO: observeIO)
}

/// A persistent connection keeps its frame reader in the caller; only I/O hops.
func connectWithoutBlockingCooperativePool(socketPath: String) async throws -> UnixSocketConnection {
    try await withoutBlockingCooperativePool {
        try UnixSocketClient.connect(endpoint: UnixSocketEndpoint(path: socketPath))
    }
}

func sendRequestWithoutBlockingCooperativePool(
    connection: UnixSocketConnection,
    request: JSONRPCClientRequest,
    observeIO: TestSocketIOObserver? = nil,
    maxFrameBytes: Int = 65_536
) async throws {
    try await withoutBlockingCooperativePool {
        try sendRequest(connection: connection, request: request, observeIO: observeIO, maxFrameBytes: maxFrameBytes)
    }
}

func sendRequest(
    connection: UnixSocketConnection,
    request: JSONRPCClientRequest,
    observeIO: TestSocketIOObserver? = nil,
    maxFrameBytes: Int = 65_536
) throws {
    let frameData = try NDJSONFrameEncoder.encode(
        JSONRPCCodec.encodeRequest(request),
        maxFrameBytes: maxFrameBytes
    )
    withUnsafeCurrentTask { observeIO?(.send, $0 != nil) }
    try connection.send(frameData)
}

func loginWithoutBlockingMainActor(
    connection: UnixSocketConnection,
    token: AgentStudioIPCSubjectToken,
    requestId: Int,
    reader: inout TestFrameReader
) async throws {
    try await sendRequestWithoutBlockingCooperativePool(
        connection: connection,
        request: JSONRPCClientRequest(
            id: .number(requestId),
            method: "auth.login",
            params: .object(["token": .string(token.rawValue)])
        ),
        observeIO: reader.observeIO
    )
    let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
    try #require(response.id == .number(requestId))

    var rejectionContext = "auth.login rejection was not observed"
    if response.error != nil {
        do {
            try await sendRequestWithoutBlockingCooperativePool(
                connection: connection,
                request: JSONRPCClientRequest(
                    id: .number(requestId + 1_000_000),
                    method: "auth.status",
                    params: .object([:])
                ),
                observeIO: reader.observeIO
            )
            let status = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
            let authenticated: Bool?
            if case .object(let result)? = status.result,
                case .bool(let value)? = result["authenticated"]
            {
                authenticated = value
            } else {
                authenticated = nil
            }
            rejectionContext =
                "post-rejection auth.status error code: \(status.error?.code.description ?? "none"); "
                + "authenticated: \(authenticated?.description ?? "unknown")"
        } catch {
            rejectionContext = "post-rejection auth.status transport failed"
        }
    }
    try #require(response.error == nil, Comment(rawValue: rejectionContext))
}

func decodeResponseResult<T: Decodable>(
    _ type: T.Type,
    from response: JSONRPCResponseMessage
) throws -> T {
    let result = try #require(response.result)
    return try decodeJSONValue(type, from: result)
}

func decodeJSONValue<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(type, from: data)
}

enum TestFrameReaderError: Error, Equatable {
    case endOfStream
}

struct TestFrameReader {
    var decoder = NDJSONFrameDecoder(maxFrameBytes: 1_048_576)
    var queuedFrames: [String] = []
    var observeIO: TestSocketIOObserver?

    mutating func receiveResponse(connection: UnixSocketConnection) throws -> JSONRPCResponseMessage {
        try JSONRPCCodec.decodeResponse(receiveFrame(connection: connection))
    }

    mutating func receiveFrame(connection: UnixSocketConnection) throws -> String {
        if !queuedFrames.isEmpty {
            return queuedFrames.removeFirst()
        }
        while true {
            withUnsafeCurrentTask { observeIO?(.receive, $0 != nil) }
            let data = try connection.receive(maxBytes: 4096)
            guard !data.isEmpty else { throw TestFrameReaderError.endOfStream }
            queuedFrames.append(contentsOf: try decoder.append(data))
            if !queuedFrames.isEmpty {
                return queuedFrames.removeFirst()
            }
        }
    }

    func hasBufferedFrame(containing text: String) -> Bool {
        queuedFrames.contains { $0.contains(text) }
    }

    mutating func receiveResponseWithoutBlockingMainActor(connection: UnixSocketConnection) async throws
        -> JSONRPCResponseMessage
    {
        try JSONRPCCodec.decodeResponse(try await receiveFrameWithoutBlockingCooperativePool(connection: connection))
    }

    mutating func receiveFrameWithoutBlockingCooperativePool(connection: UnixSocketConnection) async throws -> String {
        if !queuedFrames.isEmpty {
            return queuedFrames.removeFirst()
        }
        while true {
            let observeIO = observeIO
            let data = try await withoutBlockingCooperativePool {
                withUnsafeCurrentTask { observeIO?(.receive, $0 != nil) }
                return try connection.receive(maxBytes: 4096)
            }
            guard !data.isEmpty else { throw TestFrameReaderError.endOfStream }
            queuedFrames.append(contentsOf: try decoder.append(data))
            if !queuedFrames.isEmpty {
                return queuedFrames.removeFirst()
            }
        }
    }
}

/// `AgentStudioIPCClient` is synchronous: every call sends a frame and then
/// blocks in `UnixSocketConnection.receive` until the app answers. From a test
/// body that block lands on the cooperative executor, which is where the
/// server's own connection handler needs to run, so these shims move the wait
/// to a dedicated thread. See `withoutBlockingCooperativePool`.
extension AgentStudioIPCClient {
    func discoverCatalogWithoutBlockingCooperativePool(
        requestID: Int = 1
    ) async throws -> IPCMethodCatalogResult {
        try await withoutBlockingCooperativePool { try discoverCatalog(requestID: requestID) }
    }

    func callWithoutBlockingCooperativePool(
        _ invocation: IPCDescriptorInvocation,
        requestID: Int = 1
    ) async throws -> IPCDescriptorClientCallResult {
        try await withoutBlockingCooperativePool { try call(invocation, requestID: requestID) }
    }
}

/// The socket-path form of `sendRequest`, off the cooperative pool. The
/// connection is opened, used and closed inside the one hop.
func sendRequestWithoutBlockingCooperativePool(
    socketPath: String,
    request: JSONRPCClientRequest,
    observeIO: TestSocketIOObserver? = nil
) async throws -> JSONRPCResponseMessage {
    try await withoutBlockingCooperativePool {
        try sendRequest(socketPath: socketPath, request: request, observeIO: observeIO)
    }
}

/// Reads one request inside a `UnixSocketListener.start` handler.
///
/// This blocking receive is correct where it is used: the listener invokes its
/// handler on its own serial dispatch queue, never on the cooperative executor,
/// so parking here costs a libdispatch thread rather than one the IPC server
/// needs. It lives in this file so the blocking primitive stays in the handful
/// of allowlisted places the lint rule knows about.
func receiveListenerHandlerRequest(
    connection: UnixSocketConnection,
    decoder: inout NDJSONFrameDecoder
) throws -> JSONRPCRequest {
    while true {
        let data = try connection.receive(maxBytes: 4096)
        let frames = try decoder.append(data)
        if let frame = frames.first {
            return try JSONRPCCodec.decodeRequest(frame)
        }
    }
}

/// Direct registration tests inspect the same result the production writer frames.
func decodeJSONValue<T: Decodable>(_ type: T.Type, from result: AppIPCInvocationResult) throws -> T {
    try JSONDecoder().decode(type, from: encodedAppIPCInvocationResult(result))
}

func encodedAppIPCInvocationResult(_ result: AppIPCInvocationResult) throws -> Data {
    let bytes: Data
    switch result {
    case .value(let value): bytes = try JSONEncoder().encode(value)
    case .encoded(let encoded): bytes = encoded
    }
    return bytes
}
