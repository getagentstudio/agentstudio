import Foundation
import Testing

@testable import AgentStudioCore

@Suite("ScrollbackCaptureResult classification")
struct ScrollbackCaptureResultTests {
    @Test("read failure rejects partial bytes even when the process exits successfully")
    func readFailureRejectsPartialBytes() {
        let result = ScrollbackCaptureResult.classify(
            standardOutput: Data("partial".utf8), exitStatus: 0, readFailed: true)
        #expect(result == .readFailed)
    }

    @Test("nonzero exit rejects partial bytes")
    func nonzeroExitRejectsPartialBytes() {
        let result = ScrollbackCaptureResult.classify(
            standardOutput: Data("partial".utf8), exitStatus: 17, readFailed: false)
        #expect(result == .exitedNonZero(17))
    }

    @Test("successful byte-empty output is empty")
    func successfulEmptyOutput() {
        #expect(ScrollbackCaptureResult.classify(standardOutput: Data(), exitStatus: 0, readFailed: false) == .empty)
    }

    @Test("successful bytes keep whitespace, escapes, NUL and invalid UTF8 unchanged")
    func successfulBytesAreNotDecodedOrTrimmed() {
        let bytes = Data([0x20, 0x09, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x00, 0xFF, 0x0A])
        #expect(
            ScrollbackCaptureResult.classify(standardOutput: bytes, exitStatus: 0, readFailed: false)
                == .accepted(bytes))
    }
}
