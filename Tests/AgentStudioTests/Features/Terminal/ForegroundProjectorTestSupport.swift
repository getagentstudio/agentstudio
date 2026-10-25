import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

private enum ForegroundProducerEdge: Equatable, Sendable { case began, settled }

final class ForegroundProducerLedger: Sendable {
    private struct State {
        var opened: [UUID] = []
        var closed: [UUID] = []
        var heldClose: HeldStep<ForegroundLookTrigger>?
    }
    private let state = Mutex(State())
    private let source: LocalFactSource<UUID, ForegroundProducerEdge>
    private let recorder: FactRecorder<UUID, ForegroundProducerEdge>

    init() throws {
        source = LocalFactSource(
            vocabulary: .init(
                describeScope: { $0.uuidString },
                describeFact: { String(describing: $0) }, isClosing: { _, fact in fact == .settled }))
        recorder = try source.attach()
    }
    func holdNextClose(_ step: HeldStep<ForegroundLookTrigger>) { state.withLock { $0.heldClose = step } }
    func opened() -> [UUID] { state.withLock { $0.opened } }
    func closed() -> [UUID] { state.withLock { $0.closed } }

    func deliver(_ trigger: ForegroundLookTrigger, pane: UUID, observer: PaneForegroundObserver<TestPushClock>) async {
        if case .outputSettled = trigger {
            let step = state.withLock { state in
                defer { state.heldClose = nil }
                return state.heldClose
            }
            if let step { try? await step.arrive(trigger) }
        }
        await observer.note(trigger, pane: pane)
        switch trigger {
        case .outputBegan(let identifier):
            state.withLock { $0.opened.append(identifier) }
            source.sink(identifier, .began)
        case .outputSettled(let identifier):
            state.withLock { $0.closed.append(identifier) }
            source.sink(identifier, .settled)
        default: break
        }
    }
    func expectBegin(_ identifier: UUID) async throws { try await recorder.expectNext(in: identifier, .began) }
    func expectClose(_ identifier: UUID) async throws { try await recorder.expectNext(in: identifier, .settled) }
    func finish() async throws { try await recorder.finish() }
}

final class ForegroundCompactLedger: Sendable {
    private let updates = Mutex<[TerminalActivityCompactUpdate]>([])
    func append(_ update: TerminalActivityCompactUpdate) { updates.withLock { $0.append(update) } }
    func snapshot() -> [TerminalActivityCompactUpdate] { updates.withLock { $0 } }
}

@MainActor
final class ForegroundProjectorFixture {
    let foreground: ForegroundObserverFixture
    let edges: ForegroundProducerLedger
    let projector: TerminalActivityProjector
    let compact = ForegroundCompactLedger()
    let surfaceId = UUIDv7.generate()
    let quietDuration: Duration

    init(quietDuration: Duration = .seconds(1), configureActivityConsumer: Bool = false) throws {
        foreground = try ForegroundObserverFixture()
        edges = try ForegroundProducerLedger()
        self.quietDuration = quietDuration
        let foregroundObserver: PaneForegroundObserver<TestPushClock> = foreground.observer
        let edgeLedger: ForegroundProducerLedger = edges
        let ignoredActivity: @Sendable (PaneActivityOccurrence) -> Void = { _ in }
        let activitySink: (@Sendable (PaneActivityOccurrence) -> Void)? =
            configureActivityConsumer ? ignoredActivity : nil
        let foregroundLookSink: @Sendable (ForegroundLookTrigger, UUID) async -> Void = { trigger, pane in
            await edgeLedger.deliver(trigger, pane: pane, observer: foregroundObserver)
        }
        projector = TerminalActivityProjector(
            unseenQuietDuration: quietDuration, clock: foreground.clock,
            activitySink: activitySink, foregroundLookSink: foregroundLookSink)
    }

    func configure() async {
        await projector.configure { [compact] outcomes in
            for case .compactStateChanged(let update) in outcomes { compact.append(update) }
        }
    }

    func grow(first: Int, latest: Int, surface: UUID? = nil) async throws -> UUID {
        await ingest(first: first, latest: latest, surface: surface)
        return try #require(edges.opened().last, "the real projector must emit outputBegan before ingest returns")
    }

    func ingest(first: Int, latest: Int, surface: UUID? = nil) async {
        var aggregate = TerminalScrollbarActivityAggregate(
            state: ScrollbarState(top: max(0, first - 40), bottom: first, total: first), observedAtMilliseconds: 1000)
        aggregate.merge(
            state: ScrollbarState(top: max(0, latest - 40), bottom: latest, total: latest),
            observedAtMilliseconds: 1100)
        await projector.ingest(
            surfaceID: surface ?? surfaceId, paneID: foreground.paneId,
            aggregate: aggregate, latestState: ScrollbarState(top: max(0, latest - 40), bottom: latest, total: latest),
            context: .init(isAttended: true, isAgentClassified: false, outputBurstThreshold: 30))
    }

    func finishLook(sequence: UInt64) async throws {
        let scope = try await foreground.expectLookStarted(sequence: sequence)
        _ = try await foreground.finishLook(scope: scope, agent: true)
    }

    func close() async throws {
        await projector.reset()
        await foreground.observer.shutdown()
        foreground.watcher.finish()
        try await foreground.recorder.finish()
        try await edges.finish()
    }
}

@MainActor
func withForegroundProjectorFixture(
    quietDuration: Duration = .seconds(1),
    activityConsumer: Bool = false, _ operation: (ForegroundProjectorFixture) async throws -> Void
) async throws {
    let fixture = try ForegroundProjectorFixture(
        quietDuration: quietDuration, configureActivityConsumer: activityConsumer)
    await fixture.configure()
    do {
        try await operation(fixture)
        try await fixture.close()
    } catch {
        try? await fixture.close()
        throw error
    }
}
