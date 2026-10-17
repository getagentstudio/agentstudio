import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation

/// Serial frame admission owns the waiting child, while physical socket I/O
/// belongs to the existing dispatch reader and the connection's output queue.
struct AgentStudioAppIPCConnectionReader: Sendable {
    let methodRegistry: AppIPCMethodRegistry
    let connection: UnixSocketConnection
    let io: AppIPCConnectionIO
    let writer: AgentStudioAppIPCConnectionWriter
    let maxRequestFrameBytes: Int
    let isStopping: @Sendable () -> Bool
    let executeRequest:
        @Sendable (JSONRPCRequest, JSONRPCIdentifier, AgentStudioAppIPCConnectionState) async throws
            -> AppIPCInvocationResult

    func run(connectionState: AgentStudioAppIPCConnectionState) async {
        var decoder = NDJSONFrameDecoder(maxFrameBytes: maxRequestFrameBytes)
        await withTaskGroup(of: Void.self) { taskGroup in
            defer { taskGroup.cancelAll() }
            var hasWaitingChild = false
            while true {
                do {
                    let data = try await receiveFrameData(from: io)
                    guard !data.isEmpty else {
                        connectionState.endConnection(cause: isStopping() ? .stopping : .eof)
                        return
                    }
                    let frames = try decoder.append(data)
                    for frame in frames {
                        let request: JSONRPCRequest
                        do {
                            request = try JSONRPCCodec.decodeRequest(frame, maxBytes: maxRequestFrameBytes)
                            try IPCEventBroker.validateInboundClientNotification(method: request.method)
                        } catch {
                            guard
                                try await writer.sendError(id: nil, code: -32_600, message: "invalid request")
                                    == .accepted
                            else {
                                connectionState.endConnection(cause: isStopping() ? .stopping : .error)
                                return
                            }
                            continue
                        }

                        guard let id = request.id else { continue }
                        // The decision precedes every suspension, including
                        // authentication, target resolution and the handler.
                        if connectionState.hasWaitingRequest {
                            let error = AgentStudioAppIPCRequestError.connectionBusy
                            guard
                                try await writer.sendError(
                                    id: id, code: error.code, message: error.message, data: error.data) == .accepted
                            else {
                                connectionState.endConnection(cause: isStopping() ? .stopping : .error)
                                return
                            }
                            continue
                        }

                        // Consume the finished child before admitting another
                        // request, so a long-lived connection retains at most
                        // one waiting task's result in its group.
                        if hasWaitingChild {
                            _ = await taskGroup.next()
                            hasWaitingChild = false
                        }

                        if methodRegistry.registration(named: request.method)?.execution == .waitsBesideReader {
                            connectionState.beginWaitingRequest()
                            hasWaitingChild = true
                            taskGroup.addTask { [self] in
                                defer { connectionState.finishWaitingRequest() }
                                do {
                                    if try await executeAndEnqueueReply(
                                        request, connectionState: connectionState
                                    ) == false {
                                        connection.close()
                                    }
                                } catch {
                                    connection.close()
                                }
                            }
                        } else {
                            guard
                                try await executeAndEnqueueReply(
                                    request, connectionState: connectionState
                                )
                            else {
                                connectionState.endConnection(cause: isStopping() ? .stopping : .error)
                                return
                            }
                        }
                    }
                } catch {
                    connectionState.endConnection(cause: isStopping() ? .stopping : .error)
                    return
                }
            }
        }
    }

    private func executeAndEnqueueReply(
        _ request: JSONRPCRequest,
        connectionState: AgentStudioAppIPCConnectionState
    ) async throws -> Bool {
        guard let id = request.id else { return true }
        do {
            let result = try await executeRequest(request, id, connectionState)
            return try await writer.sendResult(id: id, result: result) == .accepted
        } catch let error as AgentStudioAppIPCRequestError {
            return try await writer.sendError(id: id, code: error.code, message: error.message, data: error.data)
                == .accepted
        } catch {
            let mappedError = AgentStudioAppIPCRequestError(error)
            return try await writer.sendError(
                id: id, code: mappedError.code, message: mappedError.message, data: mappedError.data
            ) == .accepted
        }
    }

    private func receiveFrameData(from io: AppIPCConnectionIO) async throws -> Data {
        let readLimit = min(maxRequestFrameBytes, 16_384)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try io.receive(readLimit))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

}

final class AgentStudioAppIPCConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAuthenticatedContext: AgentStudioIPCAuthenticatedContext?
    private var storedAuthenticationFailed = false
    private var storedHasWaitingRequest = false
    private var storedEndCause: AppIPCConnectionEndCause?

    var authenticatedContext: AgentStudioIPCAuthenticatedContext? { lock.withLock { storedAuthenticatedContext } }
    var principal: IPCPrincipal? { authenticatedContext?.principal }
    var authenticationFailed: Bool { lock.withLock { storedAuthenticationFailed } }
    var hasWaitingRequest: Bool { lock.withLock { storedHasWaitingRequest } }
    var endCause: AppIPCConnectionEndCause? { lock.withLock { storedEndCause } }

    func beginWaitingRequest() {
        lock.withLock { storedHasWaitingRequest = true }
    }

    func finishWaitingRequest() {
        lock.withLock { storedHasWaitingRequest = false }
    }

    func endConnection(cause: AppIPCConnectionEndCause) {
        lock.withLock {
            if storedEndCause == nil { storedEndCause = cause }
        }
    }

    func setAuthenticatedContext(_ context: AgentStudioIPCAuthenticatedContext) {
        lock.withLock {
            storedAuthenticatedContext = context
            storedAuthenticationFailed = false
        }
    }

    func replaceAuthenticatedContext(
        _ context: AgentStudioIPCAuthenticatedContext
    ) -> AgentStudioIPCAuthenticatedContext? {
        lock.withLock {
            let replaced = storedAuthenticatedContext
            storedAuthenticatedContext = context
            storedAuthenticationFailed = false
            return replaced
        }
    }

    func rejectAuthentication() -> AgentStudioIPCAuthenticatedContext? {
        lock.withLock {
            let rejected = storedAuthenticatedContext
            storedAuthenticatedContext = nil
            storedAuthenticationFailed = true
            return rejected
        }
    }
}
