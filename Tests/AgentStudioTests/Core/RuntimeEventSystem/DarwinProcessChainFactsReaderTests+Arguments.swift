import Darwin
import Testing

@testable import AgentStudioCore

extension DarwinProcessChainFactsReaderTests {
    @Test("the argv0 fallback requests the complete buffer and ignores later bytes")
    func completeArgumentFetch() {
        // Arrange: malformed later arguments must not change argv0 classification.
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/bin/sleep\0\0claude\0".utf8)
        bytes += [0xff, 0, 0xfe, 0]
        let requiredSize = (bytes.count + 3) / 4 * 4
        let calls = ScriptedArgumentsSyscalls(
            sizes: [.success(requiredSize)], fetches: [.success(bytes.count)], bytes: bytes)

        // Act
        let name = DarwinProcessChainExecutableReader(
            argumentsReader: ProcessArgumentsReader(syscalls: calls)
        ).argumentZero(of: 42)

        // Assert
        #expect(name == "claude")
        #expect(calls.requestedSizes == [requiredSize])
    }
}
