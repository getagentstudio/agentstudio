import AgentStudioIPCTransport
import Foundation

final class S5CLIWireRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var connectionCount = 0
    private var recordedRequests: [JSONRPCRequest] = []

    var connections: Int { lock.withLock { connectionCount } }
    var methods: [String] { lock.withLock { recordedRequests.map(\.method) } }
    var requests: [JSONRPCRequest] { lock.withLock { recordedRequests } }

    func recordConnection() { lock.withLock { connectionCount += 1 } }
    func recordRequest(_ request: JSONRPCRequest) { lock.withLock { recordedRequests.append(request) } }
}

/// One recorder per accepted connection, observing the same bytes the real
/// reader receives and never replacing its decoding or admission.
final class S5CLIFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = NDJSONFrameDecoder(maxFrameBytes: IPCFramePolicy.maximumRequestFrameBytes)
    private let wire: S5CLIWireRecorder

    init(wire: S5CLIWireRecorder) { self.wire = wire }

    func record(_ bytes: Data) {
        guard let frames = try? lock.withLock({ try decoder.append(bytes) }) else { return }
        for frame in frames {
            if let request = try? JSONRPCCodec.decodeRequest(frame) { wire.recordRequest(request) }
        }
    }
}
