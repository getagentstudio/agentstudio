import Darwin
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

extension DarwinProcessChainFactsReaderTests {
    @Test("the argv0 fallback requests the complete queried buffer and ignores later bytes")
    func completeArgumentFetch() {
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/bin/sleep\0\0claude\0".utf8)
        bytes += [0xff, 0, 0xfe, 0]  // Neither later argv nor environment must decode.
        let requiredSize = (bytes.count + 3) / 4 * 4
        let calls = ScriptedProcessArguments(sizes: [requiredSize], returnedSize: bytes.count, bytes: bytes)
        let name = DarwinProcessChainExecutableReader(argumentsReader: calls).argumentZero(of: 42)
        #expect(name == "claude")
        #expect(calls.requestedSizes == [requiredSize])
    }

    @Test(
        "the argv0 fallback rejects size races, syscall failures and unsafe sizes",
        arguments: ArgumentReadFailure.allCases)
    func argumentFetchFailsClosed(failure: ArgumentReadFailure) {
        let bytes = withUnsafeBytes(of: Int32(1)) { Array($0) } + Array("/bin/sleep\0\0claude\0".utf8)
        let requiredSize = (bytes.count + 3) / 4 * 4
        let size: Int?
        let returnedSize: Int?
        switch failure {
        case .queryDenied:
            size = nil
            returnedSize = bytes.count
        case .empty:
            size = 0
            returnedSize = 0
        case .tooSmall:
            size = 4
            returnedSize = 4
        case .tooLarge:
            size = Int(ARG_MAX) + 1
            returnedSize = bytes.count
        case .fetchDenied:
            size = requiredSize
            returnedSize = nil
        case .shrank:
            size = requiredSize
            returnedSize = requiredSize - 4
        case .grew:
            size = requiredSize
            returnedSize = requiredSize + 1
        case .queryChanged, .recheckDenied:
            size = requiredSize
            returnedSize = bytes.count
        }
        let sizes: [Int?]
        switch failure {
        case .queryChanged: sizes = [size, requiredSize + 4]
        case .recheckDenied: sizes = [size, nil]
        default: sizes = [size]
        }
        let calls = ScriptedProcessArguments(sizes: sizes, returnedSize: returnedSize, bytes: bytes)
        #expect(DarwinProcessChainExecutableReader(argumentsReader: calls).argumentZero(of: 42) == nil)
        switch failure {
        case .queryDenied, .empty, .tooSmall, .tooLarge: #expect(calls.requestedSizes.isEmpty)
        case .fetchDenied, .shrank, .grew, .queryChanged, .recheckDenied:
            #expect(calls.requestedSizes == [requiredSize])
        }
    }
}

enum ArgumentReadFailure: CaseIterable, Sendable {
    case queryDenied, empty, tooSmall, tooLarge, fetchDenied, shrank, grew, queryChanged, recheckDenied
}

private final class ScriptedProcessArguments: ProcessChainArgumentsReading {
    let sizes: [Int?]
    private let queryIndex = Mutex(0)
    let returnedSize: Int?
    let bytes: [UInt8]
    private let requests = Mutex<[Int]>([])
    init(sizes: [Int?], returnedSize: Int?, bytes: [UInt8]) {
        self.sizes = sizes
        self.returnedSize = returnedSize
        self.bytes = bytes
    }
    var requestedSizes: [Int] { requests.withLock { $0 } }
    func requiredSize(of pid: Int32) -> Int? {
        queryIndex.withLock { index in
            defer { index += 1 }
            return sizes[min(index, sizes.count - 1)]
        }
    }
    func readArguments(of pid: Int32, into buffer: inout [UInt8]) -> Int? {
        requests.withLock { $0.append(buffer.count) }
        for index in 0..<min(buffer.count, bytes.count) { buffer[index] = bytes[index] }
        return returnedSize
    }
}
