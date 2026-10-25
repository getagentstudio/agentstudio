import AgentStudioInfrastructure
import Darwin
import Synchronization
import Testing

@testable import AgentStudioCore

@Suite("Exact-size process argument transactions")
struct ProcessArgumentsReaderTests {
    @Test(
        "the shared reader returns the exact result and retries only consistency failures and EIO",
        arguments: ArgumentsReadScenario.allCases)
    func exactArgumentResult(scenario: ArgumentsReadScenario) {
        // Arrange: D4's independent syscall outcomes, not parser-produced expectations.
        let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
        let attempts = AppPolicies.Restore.processArgumentsReadAttempts
        let calls = ScriptedArgumentsSyscalls(
            sizes: scenario.sizes, fetches: scenario.fetches, bytes: bytes)
        let reader = ProcessArgumentsReader(syscalls: calls)

        // Act
        let result = reader.read(pid: 42)

        // Assert
        #expect(result == scenario.expected(bytes: bytes))
        #expect(calls.queryCount == scenario.expectedQueries(attempts: attempts))
        #expect(calls.requestedSizes == scenario.expectedCapacities(attempts: attempts))
    }
}

enum ArgumentsReadScenario: CaseIterable, Sendable {
    case zeroThenSuccess, headerThenSuccess, zeroExhausted, oversized
    case queryEIOThenSuccess, queryEIOExhausted, queryESRCH
    case fetchEIOThenSuccess, fetchEIOExhausted, fetchESRCH
    case requeryChangedThenSuccess, requeryEIOThenSuccess, requeryESRCH
    case alignedShortFetch, misalignedExhausted

    var sizes: [Result<Int, POSIXErrorNumber>] {
        switch self {
        case .zeroThenSuccess: [.success(0), .success(8), .success(8)]
        case .headerThenSuccess: [.success(4), .success(8), .success(8)]
        case .zeroExhausted: [.success(0)]
        case .oversized: [.success(Int(ARG_MAX) + 1)]
        case .queryEIOThenSuccess: [.failure(POSIXErrorNumber(EIO)), .success(8), .success(8)]
        case .queryEIOExhausted: [.failure(POSIXErrorNumber(EIO))]
        case .queryESRCH: [.failure(POSIXErrorNumber(ESRCH))]
        case .requeryChangedThenSuccess: [.success(8), .success(12), .success(8), .success(8)]
        case .requeryEIOThenSuccess: [.success(8), .failure(POSIXErrorNumber(EIO)), .success(8), .success(8)]
        case .requeryESRCH: [.success(8), .failure(POSIXErrorNumber(ESRCH))]
        case .misalignedExhausted: [.success(12)]
        case .fetchEIOThenSuccess, .fetchEIOExhausted, .fetchESRCH, .alignedShortFetch: [.success(8)]
        }
    }

    var fetches: [Result<Int, POSIXErrorNumber>] {
        switch self {
        case .fetchEIOThenSuccess: [.failure(POSIXErrorNumber(EIO)), .success(7)]
        case .fetchEIOExhausted: [.failure(POSIXErrorNumber(EIO))]
        case .fetchESRCH: [.failure(POSIXErrorNumber(ESRCH))]
        default: [.success(7)]
        }
    }

    func expected(bytes: [UInt8]) -> Result<[UInt8], POSIXErrorNumber> {
        switch self {
        case .zeroExhausted, .queryEIOExhausted, .fetchEIOExhausted, .misalignedExhausted:
            .failure(POSIXErrorNumber(EIO))
        case .oversized: .failure(POSIXErrorNumber(E2BIG))
        case .queryESRCH, .fetchESRCH, .requeryESRCH: .failure(POSIXErrorNumber(ESRCH))
        case .zeroThenSuccess, .headerThenSuccess, .queryEIOThenSuccess, .fetchEIOThenSuccess,
            .requeryChangedThenSuccess, .requeryEIOThenSuccess, .alignedShortFetch:
            .success(bytes)
        }
    }

    func expectedQueries(attempts: Int) -> Int {
        switch self {
        case .zeroThenSuccess, .headerThenSuccess, .queryEIOThenSuccess, .fetchEIOThenSuccess: 3
        case .zeroExhausted, .queryEIOExhausted, .fetchEIOExhausted, .misalignedExhausted: attempts
        case .oversized, .queryESRCH, .fetchESRCH: 1
        case .requeryChangedThenSuccess, .requeryEIOThenSuccess: 4
        case .requeryESRCH, .alignedShortFetch: 2
        }
    }

    func expectedCapacities(attempts: Int) -> [Int] {
        switch self {
        case .zeroExhausted, .oversized, .queryEIOExhausted, .queryESRCH: []
        case .fetchEIOExhausted: Array(repeating: 8, count: attempts)
        case .misalignedExhausted: Array(repeating: 12, count: attempts)
        case .fetchEIOThenSuccess, .requeryChangedThenSuccess, .requeryEIOThenSuccess: [8, 8]
        case .zeroThenSuccess, .headerThenSuccess, .queryEIOThenSuccess, .fetchESRCH,
            .requeryESRCH, .alignedShortFetch:
            [8]
        }
    }
}

final class ScriptedArgumentsSyscalls: ProcessArgumentsSyscalls {
    private struct Calls {
        var queryIndex = 0
        var fetchIndex = 0
        var capacities: [Int] = []
    }
    private let calls = Mutex(Calls())
    private let sizes: [Result<Int, POSIXErrorNumber>]
    private let fetches: [Result<Int, POSIXErrorNumber>]
    private let bytes: [UInt8]

    init(
        sizes: [Result<Int, POSIXErrorNumber>], fetches: [Result<Int, POSIXErrorNumber>] = [.success(7)],
        bytes: [UInt8] = []
    ) {
        self.sizes = sizes
        self.fetches = fetches
        self.bytes = bytes
    }

    var queryCount: Int { calls.withLock { $0.queryIndex } }
    var requestedSizes: [Int] { calls.withLock { $0.capacities } }

    func requiredSize(of pid: Int32) -> Result<Int, POSIXErrorNumber> {
        calls.withLock { state in
            defer { state.queryIndex += 1 }
            return sizes[min(state.queryIndex, sizes.count - 1)]
        }
    }

    func readArguments(of pid: Int32, into buffer: inout [UInt8]) -> Result<Int, POSIXErrorNumber> {
        for index in 0..<min(bytes.count, buffer.count) { buffer[index] = bytes[index] }
        return calls.withLock { state in
            state.capacities.append(buffer.count)
            defer { state.fetchIndex += 1 }
            return fetches[min(state.fetchIndex, fetches.count - 1)]
        }
    }
}
