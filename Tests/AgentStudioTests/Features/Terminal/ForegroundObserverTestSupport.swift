import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization

@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

actor ForegroundMemoryRepository: PaneForegroundEvidenceRepository {
    var bindings: [ForegroundPaneBinding]
    private var observations: [UUID: PaneForegroundLook] = [:]
    private var retiredPanes: Set<UUID> = []
    private var writeCount = 0
    func observationWriteCount() -> Int { writeCount }

    init(binding: ForegroundPaneBinding) { bindings = [binding] }
    func eligiblePanes() -> [ForegroundPaneBinding] { bindings.filter { !retiredPanes.contains($0.paneId) } }
    func load(paneId: UUID) -> PaneForegroundLook? { observations[paneId] }
    // This fixture models looks; reported policy is exercised against the real SQLite repository.
    func loadEvidence(paneId: UUID) -> PaneForegroundEvidence? {
        observations[paneId].map(\.evidence)
    }
    func clearReportedEvidenceForChangedBinding(paneId: UUID) {}
    func retire(paneId: UUID) {
        retiredPanes.insert(paneId)
        observations[paneId] = nil
    }
    func setBinding(_ binding: ForegroundPaneBinding) { bindings = [binding] }
    func seed(_ observation: PaneForegroundLook) { observations[observation.paneId] = observation }
    func admit(_ observation: PaneForegroundLook) -> ForegroundEvidenceAdmission {
        guard !retiredPanes.contains(observation.paneId) else { return .retiredPane }
        guard
            bindings.first(where: { $0.paneId == observation.paneId })?.bindingGenerationId
                == observation.bindingGenerationId
        else {
            return .bindingChanged
        }
        if let previous = observations[observation.paneId], previous.observerLaunchId == observation.observerLaunchId,
            previous.sequence >= observation.sequence
        {
            return .olderLook
        }
        observations[observation.paneId] = observation
        writeCount += 1
        return .admitted
    }
}

actor ForegroundScriptedProbe: TerminalForegroundProbing {
    private var snapshots: [ZmxSessionID: ForegroundSnapshot]
    private var nextHold: HeldStep<[ZmxSessionID: ForegroundSnapshot]>?
    init(snapshots: [ZmxSessionID: ForegroundSnapshot]) { self.snapshots = snapshots }
    func replace(_ snapshots: [ZmxSessionID: ForegroundSnapshot]) { self.snapshots = snapshots }
    func holdNext(_ step: HeldStep<[ZmxSessionID: ForegroundSnapshot]>) { nextHold = step }
    func probeForeground(of sessions: [ZmxSessionID]) async throws -> [ZmxSessionID: ForegroundSnapshot] {
        let captured = snapshots.filter { sessions.contains($0.key) }
        let held = nextHold
        nextHold = nil
        if let held { try await held.arrive(captured) }
        return captured
    }
}

final class ForegroundScriptedExitWatcher: ProcessExitWatching, Sendable {
    private struct State {
        var failures: [ProcessExitWatchFailure] = []
        var streams: [UUID: AsyncStream<ProcessExitWatchEvent>.Continuation] = [:]
        var cancelled: [UUID] = []
        var nextHeldEvent: HeldStep<ProcessExitWatchEvent>?
    }
    private let state = Mutex(State())
    func setFailures(_ failures: [ProcessExitWatchFailure]) { state.withLock { $0.failures = failures } }
    func holdNextEvent(_ step: HeldStep<ProcessExitWatchEvent>) { state.withLock { $0.nextHeldEvent = step } }
    func watchExit(of process: ProcessIncarnation, watchId: UUID) -> ProcessExitWatch {
        let held = state.withLock { state -> HeldStep<ProcessExitWatchEvent>? in
            defer { state.nextHeldEvent = nil }
            return state.nextHeldEvent
        }
        if let held {
            let failure = state.withLock { state in state.failures.isEmpty ? nil : state.failures.removeFirst() }
            let event: ProcessExitWatchEvent =
                failure.map { .unavailable(watchId: watchId, $0) } ?? .exited(watchId: watchId)
            let delivery = HeldForegroundExitDelivery(event: event, step: held)
            return ProcessExitWatch(
                events: AsyncStream(unfolding: { await delivery.next() }),
                cancel: { [self] in state.withLock { $0.cancelled.append(watchId) } })
        }
        let stream = AsyncStream.makeStream(of: ProcessExitWatchEvent.self, bufferingPolicy: .unbounded)
        let failure = state.withLock { state -> ProcessExitWatchFailure? in
            state.streams[watchId] = stream.continuation
            return state.failures.isEmpty ? nil : state.failures.removeFirst()
        }
        if let failure {
            stream.continuation.yield(.unavailable(watchId: watchId, failure))
            stream.continuation.finish()
        }
        // Deliberately retain an already-delivered old event across cancellation.
        // The observer's watchId guard, not stream cancellation, is under test.
        return ProcessExitWatch(
            events: stream.stream, cancel: { [self] in state.withLock { $0.cancelled.append(watchId) } })
    }
    func emit(_ event: ProcessExitWatchEvent, watchId: UUID) {
        state.withLock { $0.streams[watchId] }?.yield(event)
    }
    func cancelledWatchIds() -> [UUID] { state.withLock { $0.cancelled } }
    func finish() {
        let continuations = state.withLock { state in
            let continuations = Array(state.streams.values)
            state.streams.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.finish() }
    }
}

/// Swift's unfolding AsyncStream returns the result of an in-flight produce
/// closure even after cancellation; only subsequent next calls become nil.
/// The held step therefore models an event already read before replacement.
private final class HeldForegroundExitDelivery: Sendable {
    private let event: ProcessExitWatchEvent
    private let step: HeldStep<ProcessExitWatchEvent>
    private let delivered = Mutex(false)
    init(event: ProcessExitWatchEvent, step: HeldStep<ProcessExitWatchEvent>) {
        self.event = event
        self.step = step
    }
    func next() async -> ProcessExitWatchEvent? {
        guard
            delivered.withLock({ delivered in
                defer { delivered = true }
                return !delivered
            })
        else { return nil }
        do {
            try await step.arrive(event)
            return event
        } catch { return nil }
    }
}

/// Watch events have their own operation scope, even after their creating look
/// closes. Record those IDs before delivery so look discovery cannot claim them.
final class ForegroundRecordingExitWatcher: ProcessExitWatching, Sendable {
    private let wrapped: any ProcessExitWatching
    private let watchIds = Mutex<Set<UUID>>([])

    init(wrapping wrapped: any ProcessExitWatching) { self.wrapped = wrapped }

    func watchExit(of process: ProcessIncarnation, watchId: UUID) -> ProcessExitWatch {
        watchIds.withLock { _ = $0.insert(watchId) }
        return wrapped.watchExit(of: process, watchId: watchId)
    }

    func isWatchOperation(_ operationId: UUID) -> Bool { watchIds.withLock { $0.contains(operationId) } }
}

struct ForegroundObserverFixture: Sendable {
    let paneId = UUIDv7.generate()
    let sessionId = ZmxSessionID.generateUUIDv7()
    let generationId = UUIDv7.generate()
    let launchId = UUIDv7.generate()
    let clock = TestPushClock()
    let repository: ForegroundMemoryRepository
    let probe: ForegroundScriptedProbe
    let watcher = ForegroundScriptedExitWatcher()
    let recordingWatcher: ForegroundRecordingExitWatcher
    let recorder: FactRecorder<ForegroundObserverFactScope, ForegroundObserverFact>
    let observer: PaneForegroundObserver<TestPushClock>

    init(
        program: ForegroundProgram = .claudeCode, exitWatcher: (any ProcessExitWatching)? = nil,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) throws {
        let source = LocalFactSource(
            vocabulary: FactVocabulary<ForegroundObserverFactScope, ForegroundObserverFact>(
                describeScope: { "\($0.paneId)/\($0.operationId)" }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in if case .closed = fact { true } else { false } }))
        recorder = try source.attach()
        repository = ForegroundMemoryRepository(
            binding: .init(paneId: paneId, sessionId: sessionId, bindingGenerationId: generationId))
        probe = ForegroundScriptedProbe(snapshots: [sessionId: try Self.snapshot(program: program)])
        recordingWatcher = ForegroundRecordingExitWatcher(wrapping: exitWatcher ?? watcher)
        observer = PaneForegroundObserver(
            clock: clock,
            policy: .init(lookSettleDelay: .seconds(5), lookMaxDelay: .seconds(60), quitLookDeadline: .seconds(1)),
            repository: repository, probe: probe, exitWatcher: recordingWatcher, observerLaunchId: launchId,
            performanceTraceRecorder: performanceTraceRecorder,
            factSink: source.sink)
    }

    static func snapshot(program: ForegroundProgram, leaderPid: Int32 = 4100) throws -> ForegroundSnapshot {
        ForegroundSnapshot(
            sessionIdentity: try foregroundTestIdentity(leaderPid: leaderPid),
            foregroundProcess: program == .claudeCode || program == .codex
                ? foregroundTestProcess(pid: leaderPid + 10) : nil,
            program: program)
    }

    func expectScheduled() async throws {
        let pane = paneId
        let watches = recordingWatcher
        let scope = try await recorder.expectNextOperation(
            matching: { $0.paneId == pane && !watches.isWatchOperation($0.operationId) },
            opening: { $0 == .scheduled }, "scheduled demand")
        try await recorder.expectNext(in: scope, .scheduled)
        try await recorder.expectNext(in: scope, .closed(.scheduled))
    }

    func expectLookStarted(sequence: UInt64) async throws -> ForegroundObserverFactScope {
        let pane = paneId
        let watches = recordingWatcher
        let scope = try await recorder.expectNextOperation(
            matching: { $0.paneId == pane && !watches.isWatchOperation($0.operationId) },
            opening: { $0 == .snapshotStarted(sequence: sequence) }, "foreground snapshot \(sequence)")
        try await recorder.expectNext(in: scope, .snapshotStarted(sequence: sequence))
        return scope
    }

    func finishLook(scope: ForegroundObserverFactScope, agent: Bool, failure: ProcessExitWatchFailure? = nil)
        async throws -> UUID?
    {
        try await recorder.expectNext(in: scope, .observation(.admitted))
        var watchId: UUID?
        if agent || failure != nil {
            let fact = try await recorder.expectNext(
                in: scope, where: { if case .watchRegistered = $0 { true } else { false } }, "current watch registered")
            if case .watchRegistered(let identifier) = fact { watchId = identifier }
        }
        try await recorder.expectNext(in: scope, .closed(.looked))
        if let failure, let watchId {
            let eventScope = ForegroundObserverFactScope(paneId: paneId, operationId: watchId)
            try await recorder.expectNext(in: eventScope, .watchUnavailable(failure))
            try await recorder.expectNext(in: eventScope, .closed(.looked))
        }
        return watchId
    }

    func close() async throws {
        await observer.shutdown()
        watcher.finish()
        try await recorder.finish()
    }
}

func withForegroundObserverFixture(
    program: ForegroundProgram = .claudeCode,
    performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
    _ operation: @Sendable (ForegroundObserverFixture) async throws -> Void
) async throws {
    let fixture = try ForegroundObserverFixture(program: program, performanceTraceRecorder: performanceTraceRecorder)
    do {
        try await operation(fixture)
        try await fixture.close()
    } catch {
        try? await fixture.close()
        throw error
    }
}
