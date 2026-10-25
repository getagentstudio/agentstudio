import AgentStudioTestHarness
import Darwin
import Foundation
import Synchronization

@testable import AgentStudioCore
@testable import AgentStudioTerminal

enum ExitSourceOperation: Equatable, Sendable {
    case made(Int)
    case registrationHandler(Int)
    case eventHandler(Int)
    case cancelHandler(Int)
    case resumed(Int)
    case cancelled(Int)
}

final class ExitSourceLedger: Sendable {
    private let state = Mutex<[ExitSourceOperation]>([])
    func append(_ operation: ExitSourceOperation) { state.withLock { $0.append(operation) } }
    func snapshot() -> [ExitSourceOperation] { state.withLock { $0 } }
}

final class ScriptedExitSource: ProcessExitSource, Sendable {
    private struct Handlers {
        var registration: (@Sendable () -> Void)?
        var event: (@Sendable () -> Void)?
        var cancellation: (@Sendable () -> Void)?
    }
    let ordinal: Int
    private let ledger: ExitSourceLedger
    private let handlers = Mutex(Handlers())
    init(ordinal: Int, ledger: ExitSourceLedger) {
        self.ordinal = ordinal
        self.ledger = ledger
    }
    func setRegistrationHandler(_ handler: @escaping @Sendable () -> Void) {
        handlers.withLock { $0.registration = handler }
        ledger.append(.registrationHandler(ordinal))
    }
    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        handlers.withLock { $0.event = handler }
        ledger.append(.eventHandler(ordinal))
    }
    func setCancelHandler(_ handler: @escaping @Sendable () -> Void) {
        handlers.withLock { $0.cancellation = handler }
        ledger.append(.cancelHandler(ordinal))
    }
    func resume() { ledger.append(.resumed(ordinal)) }
    func cancel() {
        ledger.append(.cancelled(ordinal))
        handlers.withLock { $0.cancellation }?()
    }
    func registered() { handlers.withLock { $0.registration }?() }
    func exited() { handlers.withLock { $0.event }?() }
}

final class ScriptedExitSourceMaker: ProcessExitSourceMaking, Sendable {
    private struct State {
        var sources: [ScriptedExitSource] = []
        var failure: POSIXErrorNumber?
    }
    let ledger = ExitSourceLedger()
    private let state = Mutex(State())
    func fail(with errnoValue: Int32) { state.withLock { $0.failure = POSIXErrorNumber(errnoValue) } }
    func sources() -> [ScriptedExitSource] { state.withLock { $0.sources } }
    func makeSource(pid: Int32) throws -> any ProcessExitSource {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            let ordinal = state.sources.count
            let source = ScriptedExitSource(ordinal: ordinal, ledger: ledger)
            state.sources.append(source)
            ledger.append(.made(ordinal))
            return source
        }
    }
}

final class ScriptedIncarnationReader: Sendable {
    private struct State {
        var result = ColdStartLeaderState.sameIncarnationAlive
        var calls: [ProcessIncarnation] = []
    }
    private let state = Mutex(State())
    func set(_ result: ColdStartLeaderState) { state.withLock { $0.result = result } }
    func read(_ process: ProcessIncarnation) -> ColdStartLeaderState {
        state.withLock { state in
            state.calls.append(process)
            return state.result
        }
    }
    func calls() -> [ProcessIncarnation] { state.withLock { $0.calls } }
}

struct ProcessExitFixture: Sendable {
    let maker = ScriptedExitSourceMaker()
    let reader = ScriptedIncarnationReader()
    let recorder: FactRecorder<UUID, ProcessExitWatcherFact>
    let watcher: DarwinProcessExitWatcher

    init() throws {
        let source = LocalFactSource(
            vocabulary: FactVocabulary<UUID, ProcessExitWatcherFact>(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    switch fact {
                    case .settled, .cancelled, .lateRequestDropped: true
                    default: false
                    }
                }))
        recorder = try source.attach()
        watcher = DarwinProcessExitWatcher(
            sourceMaker: maker, leaderState: { [reader] in reader.read($0) }, factSink: source.sink)
    }

    func open(watchId: UUID) async throws -> ProcessExitWatch {
        let watch = watcher.watchExit(of: foregroundTestProcess(pid: 4200), watchId: watchId)
        try await recorder.expectNext(in: watchId, .sourceCreated)
        try await recorder.expectNext(in: watchId, .resumed)
        return watch
    }

    func verifyRegistration(
        watchId: UUID, source: ScriptedExitSource, expected: ColdStartLeaderState = .sameIncarnationAlive
    ) async throws {
        source.registered()
        try await recorder.expectNext(in: watchId, .registered)
        try await recorder.expectNext(in: watchId, .checked(expected))
    }
}

func withProcessExitFixture(_ operation: @Sendable (ProcessExitFixture) async throws -> Void) async throws {
    let fixture = try ProcessExitFixture()
    do {
        try await operation(fixture)
        fixture.watcher.shutdown()
        try await fixture.recorder.finish()
    } catch {
        fixture.watcher.shutdown()
        try? await fixture.recorder.finish()
        throw error
    }
}
