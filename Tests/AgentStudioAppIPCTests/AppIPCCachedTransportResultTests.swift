import AgentStudioIPCTransport
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioAppIPC

@Suite("App IPC cached transport result")
struct AppIPCCachedTransportResultTests {
    @Test("the response is composed once however many times it is served")
    func composesOnce() throws {
        let compositionCount = LockedCounter()
        let cache = AppIPCCachedTransportResult {
            compositionCount.increment()
            return Data("{\"methods\":[]}".utf8)
        }

        let first = try cache.encodedValue()
        let second = try cache.encodedValue()
        let third = try cache.encodedValue()

        #expect(compositionCount.value == 1)
        #expect(first == second)
        #expect(second == third)
    }

    @Test("a failing composition is not cached and is retried")
    func failedCompositionIsNotCached() throws {
        let compositionCount = LockedCounter()
        let cache = AppIPCCachedTransportResult {
            compositionCount.increment()
            guard compositionCount.value > 1 else { throw CachedTransportProbeFailure() }
            return Data("{}".utf8)
        }

        #expect(throws: CachedTransportProbeFailure.self) { try cache.encodedValue() }
        #expect(!cache.hasComposedValue)
        #expect(try cache.encodedValue() == Data("{}".utf8))
        #expect(cache.hasComposedValue)
    }

    @Test("concurrent first requests settle on one stored response")
    func concurrentFirstRequestsShareOneResponse() async throws {
        let cache = AppIPCCachedTransportResult { Data("{\"n\":1}".utf8) }

        let values = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 { group.addTask { try cache.encodedValue() } }
            var collected: [Data] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        #expect(cache.compositionCount == 1)
        #expect(values.count == 8)
        #expect(values.allSatisfy { $0 == Data("{\"n\":1}".utf8) })
    }

    @Test(
        "invalid UTF-8 and newline fills fail before caching and remain retryable",
        arguments: CachedByteFailureCase.allCases)
    func invalidFillIsRetried(failureCase: CachedByteFailureCase) throws {
        let attempts = LockedCounter()
        let cache = AppIPCCachedTransportResult {
            attempts.increment()
            return attempts.value == 1 ? failureCase.bytes : Data("{}".utf8)
        }
        #expect(throws: NDJSONFrameError(reason: failureCase.reason)) { try cache.encodedValue() }
        #expect(!cache.hasComposedValue)
        #expect(cache.compositionCount == 0)
        let first = try cache.encodedValue()
        let second = try cache.encodedValue()
        #expect(first == Data("{}".utf8))
        #expect(second == first)
        #expect(attempts.value == 2)
        #expect(cache.compositionCount == 1)
    }
}

enum CachedByteFailureCase: CaseIterable, Sendable {
    case invalidUTF8
    case lineFeed
    case carriageReturn

    var bytes: Data {
        switch self {
        case .invalidUTF8: Data([0xff])
        case .lineFeed: Data("{\n}".utf8)
        case .carriageReturn: Data("{\r}".utf8)
        }
    }

    var reason: NDJSONFrameError.Reason {
        switch self {
        case .invalidUTF8: .invalidUTF8
        case .lineFeed, .carriageReturn: .embeddedNewline
        }
    }
}

private struct CachedTransportProbeFailure: Error {}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
