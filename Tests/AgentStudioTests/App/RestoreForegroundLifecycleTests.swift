import AgentStudioInfrastructure
import AgentStudioTestHarness
import AppKit
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("Restore foreground lifecycle", .serialized)
struct RestoreForegroundLifecycleTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("the actual first activation ingress re-registers the current watch once per launch")
    func activationReregistersOnce() async throws {
        let fixture = try ForegroundLifecycleFixture()
        let ingress = AsyncStream.makeStream(of: ForegroundLookTrigger.self, bufferingPolicy: .unbounded)
        let relay = Task { await consumeRestoreForegroundLifecycle(ingress.stream, observer: fixture.observer) }
        let delegate = AppDelegate()
        delegate.applicationLifecycleMonitor = ApplicationLifecycleMonitor(
            appLifecycleStore: AppLifecycleAtom(), windowLifecycleStore: WindowLifecycleAtom(),
            notificationCenter: NotificationCenter())
        delegate.restoreForegroundTriggerSink = { ingress.continuation.yield($0) }
        do {
            await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
            let firstWatch = try await fixture.expectLook(sequence: 1)
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            ingress.continuation.finish()
            await relay.value
            try #require(
                fixture.counts.scheduled() == 2, "the lifecycle relay must request a fresh look before closing")
            let secondWatch = try await fixture.expectLook(sequence: 2)
            #expect(secondWatch != firstWatch)
            #expect(fixture.watcher.watchIds().count == 2)
            #expect(fixture.watcher.cancelled().filter { $0 == firstWatch }.count == 1)
            #expect(await fixture.observer.currentWatch(paneId: fixture.paneId)?.watchId == secondWatch)
            await fixture.observer.shutdown()
            try await fixture.facts.finish()
            delegate.applicationLifecycleMonitor = nil
        } catch {
            ingress.continuation.finish()
            relay.cancel()
            await relay.value
            await fixture.observer.shutdown()
            try? await fixture.facts.finish()
            delegate.applicationLifecycleMonitor = nil
            throw error
        }
    }

    @Test("applicationShouldTerminate forwards one quit value before returning even when no workspace store exists")
    func shouldTerminateForwardsQuit() {
        let delegate = AppDelegate()
        let ingress = LifecycleTriggerLedger()
        delegate.restoreForegroundTriggerSink = { ingress.record($0) }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(ingress.quitCount() == 1)
    }
}

private final class LifecycleTriggerLedger: Sendable {
    private let quitCalls = Mutex(0)
    func record(_ trigger: ForegroundLookTrigger) {
        if case .appQuitting = trigger { quitCalls.withLock { $0 += 1 } }
    }
    func quitCount() -> Int { quitCalls.withLock { $0 } }
}

private final class ForegroundLifecycleCounts: Sendable {
    private let scheduledCount = Mutex(0)
    func record(_ fact: ForegroundObserverFact) { if fact == .scheduled { scheduledCount.withLock { $0 += 1 } } }
    func scheduled() -> Int { scheduledCount.withLock { $0 } }
}

private actor LifecycleObservationRepository: PaneForegroundEvidenceRepository {
    let binding: ForegroundPaneBinding
    private var observation: PaneForegroundLook?
    init(binding: ForegroundPaneBinding) { self.binding = binding }
    func eligiblePanes() -> [ForegroundPaneBinding] { [binding] }
    func admit(_ value: PaneForegroundLook) -> ForegroundEvidenceAdmission {
        observation = value
        return .admitted
    }
    func load(paneId: UUID) -> PaneForegroundLook? { observation }
    func loadEvidence(paneId: UUID) -> PaneForegroundEvidence? { observation?.evidence }
    func clearReportedEvidenceForChangedBinding(paneId: UUID) {}
    func retire(paneId: UUID) { observation = nil }
}

private struct LifecycleForegroundProbe: TerminalForegroundProbing {
    let sessionId: ZmxSessionID
    let snapshot: ForegroundSnapshot
    func probeForeground(of sessions: [ZmxSessionID]) -> [ZmxSessionID: ForegroundSnapshot] {
        sessions.contains(sessionId) ? [sessionId: snapshot] : [:]
    }
}

private final class LifecycleExitWatcher: ProcessExitWatching, Sendable {
    private struct State {
        var ids: [UUID] = []
        var cancelled: [UUID] = []
        var streams: [UUID: AsyncStream<ProcessExitWatchEvent>.Continuation] = [:]
    }
    private let state = Mutex(State())
    func watchExit(of process: ProcessIncarnation, watchId: UUID) -> ProcessExitWatch {
        let stream = AsyncStream.makeStream(of: ProcessExitWatchEvent.self, bufferingPolicy: .bufferingOldest(1))
        state.withLock {
            $0.ids.append(watchId)
            $0.streams[watchId] = stream.continuation
        }
        return ProcessExitWatch(
            events: stream.stream,
            cancel: { [self] in
                let continuation = state.withLock { state in
                    state.cancelled.append(watchId)
                    return state.streams.removeValue(forKey: watchId)
                }
                continuation?.finish()
            })
    }
    func watchIds() -> [UUID] { state.withLock { $0.ids } }
    func cancelled() -> [UUID] { state.withLock { $0.cancelled } }
}

private struct ForegroundLifecycleFixture: Sendable {
    let paneId = UUIDv7.generate()
    let watcher = LifecycleExitWatcher()
    let counts = ForegroundLifecycleCounts()
    let observer: PaneForegroundObserver<TestPushClock>
    let facts: FactRecorder<ForegroundObserverFactScope, ForegroundObserverFact>

    init() throws {
        let sessionId = ZmxSessionID.generateUUIDv7()
        let identity = ZmxSessionIdentity(
            version: 1, bootID: "lifecycle-boot",
            daemon: .init(pid: 7300, startSeconds: 1, startMicroseconds: 1),
            terminalLeader: .init(pid: 7301, startSeconds: 1, startMicroseconds: 2), processGroupID: 7301,
            sessionCreatedAt: 1)
        let snapshot = ForegroundSnapshot(
            sessionIdentity: try identity.encoded(),
            foregroundProcess: .init(pid: 7400, startSeconds: 1, startMicroseconds: 3), program: .codex)
        let source = LocalFactSource(
            vocabulary: FactVocabulary<ForegroundObserverFactScope, ForegroundObserverFact>(
                describeScope: { "\($0.paneId)/\($0.operationId)" }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in if case .closed = fact { true } else { false } }))
        facts = try source.attach()
        let counts = counts
        observer = PaneForegroundObserver(
            clock: TestPushClock(),
            policy: .init(lookSettleDelay: .seconds(5), lookMaxDelay: .seconds(60), quitLookDeadline: .seconds(1)),
            repository: LifecycleObservationRepository(
                binding: .init(paneId: paneId, sessionId: sessionId, bindingGenerationId: UUIDv7.generate())),
            probe: LifecycleForegroundProbe(sessionId: sessionId, snapshot: snapshot), exitWatcher: watcher,
            observerLaunchId: UUIDv7.generate(),
            factSink: { scope, fact in
                counts.record(fact)
                source.sink(scope, fact)
            })
    }
    func expectLook(sequence: UInt64) async throws -> UUID {
        let pane = paneId
        let schedule = try await facts.expectNextOperation(
            matching: { $0.paneId == pane }, opening: { $0 == .scheduled }, "lifecycle demand")
        try await facts.expectNext(in: schedule, .scheduled)
        try await facts.expectNext(in: schedule, .closed(.scheduled))
        let look = try await facts.expectNextOperation(
            matching: { $0.paneId == pane },
            opening: { $0 == .snapshotStarted(sequence: sequence) }, "lifecycle look")
        try await facts.expectNext(in: look, .snapshotStarted(sequence: sequence))
        try await facts.expectNext(in: look, .observation(.admitted))
        let registered = try await facts.expectNext(
            in: look,
            where: { if case .watchRegistered = $0 { true } else { false } }, "lifecycle watch registered")
        try await facts.expectNext(in: look, .closed(.looked))
        guard case .watchRegistered(let identifier) = registered else { throw LifecycleTestError.noWatch }
        return identifier
    }
}

private enum LifecycleTestError: Error { case noWatch }
