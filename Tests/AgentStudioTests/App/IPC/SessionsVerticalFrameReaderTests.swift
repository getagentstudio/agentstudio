import AgentStudioIPCTransport
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@Suite("Sessions vertical frame reader")
struct SessionsVerticalFrameReaderTests {
    @Test("peer closure before a complete response throws with the buffered byte count")
    func peerClosureBeforeCompleteResponseThrows() async throws {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw UnixSocketTransportError(reason: .socketCreationFailed, errnoCode: errno)
        }
        let connection = UnixSocketConnection(fileDescriptor: descriptors[0])
        let peer = UnixSocketConnection(fileDescriptor: descriptors[1])
        defer {
            connection.close()
            peer.close()
        }
        let incompleteResponse = Data(#"{"jsonrpc":"2.0","id":1"#.utf8)
        try await valueFromDedicatedThread {
            try peer.send(incompleteResponse)
            peer.close()
        }

        var reader = SessionsVerticalFrameReader()
        await #expect(
            throws: SessionsVerticalFrameReaderError.connectionClosedBeforeCompleteFrame(
                bufferedByteCount: incompleteResponse.count)
        ) {
            _ = try await reader.receiveResponse(connection: connection)
        }
    }
}
