import AgentStudioIPCTransport
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@Suite("IPC test frame reader EOF", .serialized)
struct TestFrameReaderEOFTests {
    @Test("a peer close before any frame ends the blocking read")
    func peerCloseEndsBlockingFrameRead() async throws {
        let connection = try makePeerClosedConnection()
        defer { connection.close() }

        do {
            _ = try await valueFromDedicatedThread {
                var reader = TestFrameReader()
                return try reader.receiveFrame(connection: connection)
            }
            Issue.record("Expected TestFrameReaderError.endOfStream")
        } catch let error as TestFrameReaderError {
            #expect(error == .endOfStream)
        }
    }

    @Test("a peer close before any response ends the asynchronous read")
    func peerCloseEndsAsyncResponseRead() async throws {
        let connection = try makePeerClosedConnection()
        defer { connection.close() }
        var reader = TestFrameReader()

        do {
            _ = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
            Issue.record("Expected TestFrameReaderError.endOfStream")
        } catch let error as TestFrameReaderError {
            #expect(error == .endOfStream)
        }
    }

    private func makePeerClosedConnection() throws -> UnixSocketConnection {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let peer = UnixSocketConnection(fileDescriptor: descriptors[1])
        peer.close()
        return UnixSocketConnection(fileDescriptor: descriptors[0])
    }
}
