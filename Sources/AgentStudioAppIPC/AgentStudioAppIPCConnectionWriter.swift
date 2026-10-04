import AgentStudioIPCTransport
import AgentStudioInfrastructure
import Foundation
import Synchronization

/// The connection owns these synchronous operations. The production binding
/// retains the transport's partial-write loop and descriptor lifetime rules.
package struct AppIPCConnectionIO: Sendable {
    package let receive: @Sendable (Int) throws -> Data
    package let send: @Sendable (Data) throws -> Void
    package let close: @Sendable () -> Void

    package init(
        receive: @escaping @Sendable (Int) throws -> Data,
        send: @escaping @Sendable (Data) throws -> Void,
        close: @escaping @Sendable () -> Void
    ) {
        self.receive = receive
        self.send = send
        self.close = close
    }

    package static func live(_ connection: UnixSocketConnection) -> Self {
        Self(
            receive: { try connection.receive(maxBytes: $0) },
            send: { try connection.send($0) },
            close: { connection.close() }
        )
    }
}

package enum AppIPCFrameEnqueueResult: Equatable, Sendable {
    case accepted
    case overloaded
}

package actor AgentStudioAppIPCConnectionWriter {
    private struct OutputState: Sendable {
        var queuedByteCount = 0
        var isClosed = false
    }

    private let io: AppIPCConnectionIO
    private let maxFrameBytes: Int
    private let outputQueue = DispatchQueue(label: "com.agentstudio.ipc.connection-output", qos: .utility)
    /// Admission is actor-serialized; physical completion returns its byte
    /// reservation on the I/O queue without waking a cooperative task.
    private let outputState = Mutex(OutputState())
    private var isAcceptingFrames = true

    package init(io: AppIPCConnectionIO, maxFrameBytes: Int) {
        self.io = io
        self.maxFrameBytes = maxFrameBytes
    }

    @discardableResult
    package func sendResult(id: JSONRPCIdentifier, result: AppIPCInvocationResult) throws -> AppIPCFrameEnqueueResult {
        switch result {
        case .encoded(let bytes):
            guard isAcceptingFrames else { return .overloaded }
            return try enqueueBytes(
                JSONRPCCodec.encodeResponseBytes(id: id, encodedResult: bytes, maxFrameBytes: maxFrameBytes))
        case .value(let value):
            return try sendResponse(JSONRPCResponse.success(id: id, result: value))
        }
    }

    @discardableResult
    package func sendResponse(_ response: JSONRPCResponse) throws -> AppIPCFrameEnqueueResult {
        try sendFrame(JSONRPCCodec.encodeResponse(response))
    }

    @discardableResult
    package func sendError(id: JSONRPCIdentifier?, code: Int, message: String, data: JSONValue? = nil) throws
        -> AppIPCFrameEnqueueResult
    {
        try sendResponse(
            JSONRPCResponse.failure(
                id: id,
                error: JSONRPCErrorPayload(code: code, message: message, data: data)
            ))
    }

    @discardableResult
    package func sendFrame(_ frame: String) throws -> AppIPCFrameEnqueueResult {
        // Subscription teardown can race a publication that already captured
        // its subscriber. The fence owns a closed admission set: a late enqueue
        // must not land behind it or abort bytes accepted before orderly EOF.
        guard isAcceptingFrames else { return .overloaded }
        let bytes = try NDJSONFrameEncoder.encode(frame, maxFrameBytes: maxFrameBytes)
        return enqueueBytes(bytes)
    }

    private func enqueueBytes(_ bytes: Data) -> AppIPCFrameEnqueueResult {
        let accepted = outputState.withLock { state in
            guard !state.isClosed,
                bytes.count <= AppPolicies.IPC.maximumQueuedOutputBytes - state.queuedByteCount
            else { return false }
            state.queuedByteCount += bytes.count
            return true
        }
        guard accepted else {
            closeOutput()
            return .overloaded
        }

        outputQueue.async { [self] in
            defer { outputState.withLock { $0.queuedByteCount -= bytes.count } }
            guard outputState.withLock({ !$0.isClosed }) else { return }
            do {
                try io.send(bytes)
            } catch {
                closeOutput()
            }
        }
        return .accepted
    }

    /// EOF can follow a peer's write-side shutdown while it still reads our
    /// replies. Keep accepted bytes alive until their serial I/O has finished.
    package func finishAcceptedOutput() async {
        isAcceptingFrames = false
        await withCheckedContinuation { continuation in
            outputQueue.async { continuation.resume() }
        }
    }

    package var queuedOutputByteCount: Int {
        outputState.withLock { $0.queuedByteCount }
    }

    private nonisolated func closeOutput() {
        let shouldClose = outputState.withLock { state in
            guard !state.isClosed else { return false }
            state.isClosed = true
            return true
        }
        if shouldClose { io.close() }
    }
}

package actor AgentStudioAppIPCSocketEventSubscriber: IPCEventSubscriber {
    private let writer: AgentStudioAppIPCConnectionWriter

    package init(writer: AgentStudioAppIPCConnectionWriter) {
        self.writer = writer
    }

    package func deliver(_ frame: String) async throws -> IPCEventDeliveryResult {
        switch try await writer.sendFrame(frame) {
        case .accepted: .delivered
        case .overloaded: .backpressure
        }
    }
}
