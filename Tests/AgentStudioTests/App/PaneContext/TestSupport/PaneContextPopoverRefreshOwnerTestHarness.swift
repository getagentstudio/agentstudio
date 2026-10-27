import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

struct PopoverOwnerProofScope: Hashable, Sendable {
    enum Channel: Hashable, Sendable {
        case owner(PaneContextPopoverOwnerScope)
        case lifetime(PaneContextPopoverConsumerKey, UInt64)
    }
    let channel: Channel
}
enum PopoverOwnerProofFact: Equatable, Sendable {
    case owner(PaneContextPopoverOwnerFact)
    case clockRegistered(TestPushClock.Instant)
    case producerEnded
}

final class PopoverOwnerFactBridge: Sendable {
    private struct State {
        var timerSequence: UInt64 = 0
        var openings: [PaneContextPopoverConsumerKey: UInt64] = [:]
        var completed: Set<PaneContextPopoverOwnerScope> = []
    }
    private let state = Mutex(State())
    let facts = FactRecorder<PopoverOwnerProofScope, PopoverOwnerProofFact>(
        vocabulary: .init(
            describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
            isClosing: { scope, fact in
                if fact == .producerEnded { return true }
                guard case .owner(let value) = fact else { return false }
                if case .lifetime = scope.channel { return value == .retired }
                switch value {
                case .finished, .deadlineEnded, .inputFinished, .pageFinished, .retired: return true
                default: return false
                }
            }))

    func observe(_ scope: PaneContextPopoverOwnerScope, _ fact: PaneContextPopoverOwnerFact) {
        let lifetime = state.withLock { state -> PopoverOwnerProofScope? in
            switch fact {
            case .finished, .deadlineEnded, .pageFinished, .retired, .inputFinished: state.completed.insert(scope)
            default: break
            }
            switch scope {
            case .consumer(let key, let opening):
                state.openings[key] = opening
                return fact == .retired ? .init(channel: .lifetime(key, opening)) : nil
            case .execution(let key, _):
                return state.openings[key].map { .init(channel: .lifetime(key, $0)) }
            case .deadline(let sequence):
                if fact == .deadlineArmed { state.timerSequence = sequence }
                return nil
            case .input, .page: return nil
            }
        }
        facts.append(scope: .init(channel: .owner(scope)), fact: .owner(fact))
        if let lifetime { facts.append(scope: lifetime, fact: .owner(fact)) }
    }

    func didFinish(_ scope: PaneContextPopoverOwnerScope) -> Bool {
        state.withLock { $0.completed.contains(scope) }
    }

    func observeClock(_ fact: TestPushClock.PendingSleepFact) {
        guard case .registrationSettled(let deadline, _) = fact else { return }
        let sequence = state.withLock { $0.timerSequence }
        facts.append(scope: .init(channel: .owner(.deadline(sequence))), fact: .clockRegistered(deadline))
    }
}

actor PopoverOwnerInvalidationPorts: PaneContextInvalidationReading {
    private var generations: [PaneId: UInt64] = [:]
    private var continuations: [UUID: (Set<PaneId>, AsyncStream<PaneContextSourceInvalidation>.Continuation)] = [:]

    func invalidations(for sources: Set<PaneId>) -> AsyncStream<PaneContextSourceInvalidation> {
        let channel = AsyncStream<PaneContextSourceInvalidation>.makeStream(bufferingPolicy: .unbounded)
        continuations[UUIDv7.generate()] = (sources, channel.continuation)
        return channel.stream
    }
    private var tokenHold: HeldStep<Void>?
    func holdNextTokenRead(at step: HeldStep<Void>) { tokenHold = step }
    func invalidationGenerations(for sources: Set<PaneId>) async -> [PaneId: UInt64] {
        let result = Dictionary(uniqueKeysWithValues: sources.map { ($0, generations[$0] ?? 0) })
        let held = tokenHold
        tokenHold = nil
        if let held { try? await held.arrive(()) }
        return result
    }
    func bump(_ source: PaneId, emit: Bool) {
        let next = (generations[source] ?? 0) + 1
        generations[source] = next
        if emit {
            for (sources, continuation) in continuations.values where sources.contains(source) {
                continuation.yield(.init(sourcePaneId: source, generation: next))
            }
        }
    }
    func finish() {
        for (_, continuation) in continuations.values { continuation.finish() }
        continuations.removeAll()
    }
}

final class PopoverOwnerCapture: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var serviceEpoch: UUID?
        var title = "Owner"
        var overrides: [PaneId: PopoverSourceCapture.Source] = [:]
    }
    private let state = Mutex(State())

    func setSource(_ source: PopoverSourceCapture.Source, for pane: PaneId) {
        state.withLock {
            $0.generation += 1
            $0.overrides[pane] = source
        }
    }
    func setServiceEpoch(_ epoch: UUID?) {
        state.withLock {
            $0.generation += 1
            $0.serviceEpoch = epoch
        }
    }
    func restartRegistration(serviceEpoch: UUID) {
        state.withLock {
            $0.generation = 0
            $0.serviceEpoch = serviceEpoch
            $0.title = "Replacement"
        }
    }
    func setTitle(_ title: String) {
        state.withLock {
            $0.generation += 1
            $0.title = title
        }
    }
    func snapshot(for sources: Set<PaneId>) -> PopoverSourceCapture {
        state.withLock { state in
            .init(
                observationGeneration: state.generation, serviceEpoch: state.serviceEpoch,
                sources: Dictionary(
                    uniqueKeysWithValues: sources.map {
                        (
                            $0,
                            state.overrides[$0]
                                ?? .init(
                                    structuralFacts: nil, title: state.title, note: nil, session: nil, display: nil,
                                    activity: nil)
                        )
                    }))
        }
    }
}

final class PopoverProjectionRevocation: Sendable {
    private let value = Mutex<UInt64>(0)
    var current: UInt64 { value.withLock { $0 } }
    func invalidate() { value.withLock { $0 &+= 1 } }
}

actor PopoverOwnerProjectionSink {
    private(set) var requests: [PaneContextPopoverSnapshot] = []
    private(set) var shapes: [PaneContextPopoverConsumerKey: PaneContextPopoverShape] = [:]
    private(set) var failures: [PaneContextPopoverConsumerKey: StorageFailureSummary] = [:]
    private var held: [PaneContextPopoverConsumerKey: HeldStep<PaneContextPopoverSnapshot>] = [:]

    func holdNext(_ key: PaneContextPopoverConsumerKey, at step: HeldStep<PaneContextPopoverSnapshot>) {
        held[key] = step
    }

    func port(for key: PaneContextPopoverConsumerKey) -> PaneContextPopoverProjectionPort {
        let revision = PopoverProjectionRevocation()
        return .init(
            admit: { [weak self] snapshot in
                guard let self else { return .cancelled }
                return await self.project(snapshot, revision: revision)
            },
            invalidate: { revision.invalidate() },
            retire: { [weak self] in
                revision.invalidate()
                await self?.remove(key)
            })
    }
    private func remove(_ key: PaneContextPopoverConsumerKey) {
        shapes.removeValue(forKey: key)
    }
    private func project(
        _ snapshot: PaneContextPopoverSnapshot, revision: PopoverProjectionRevocation
    ) async -> PaneContextPopoverProjectionOutcome {
        let epoch = revision.current
        if let step = held.removeValue(forKey: snapshot.identity.key) { try? await step.arrive(snapshot) }
        requests.append(snapshot)
        let shape: PaneContextPopoverShape?
        let next: Date?
        let loaded: PaneContextPopoverSnapshot.Loaded?
        let failure: StorageFailureSummary?
        switch snapshot.state {
        case .ready(let value):
            loaded = value
            failure = nil
        case .unavailable(let error, let value):
            loaded = value
            failure = error
        case .paneGone:
            loaded = nil
            failure = nil
        }
        switch loaded {
        case .detail(let detail, _)?:
            let target: PaneContextMessagesTarget
            let content: PaneManagementIdentityCapture.PopoverContent
            switch snapshot.demand.content {
            case .messages(let requested):
                target = requested
                content = .messages
            case .agentLine:
                target = .top
                content = .agentLine
            case .card, .toolbar:
                target = .top
                content = .messages
            }
            let prepared = PaneContextPopoverShapingKernel.shape(
                detail, sourceTitles: snapshot.capture.sources.compactMapValues(\.title), counts: .zero,
                messagesTarget: target, now: snapshot.wallNow)
            let refreshed = PaneContextPopoverShapingKernel.refresh(prepared, content: content, now: snapshot.wallNow)
            shape = prepared
            next = refreshed.nextChange
        case .compact?, nil:
            shape = nil
            next = nil
        }
        guard epoch == revision.current, !Task.isCancelled else { return .superseded }
        let equal = shapes[snapshot.identity.key] == shape && failures[snapshot.identity.key] == failure
        shapes[snapshot.identity.key] = shape
        failures[snapshot.identity.key] = failure
        let metadata = PaneContextPopoverProjectionOutcome.Accepted(
            nextAgeBoundary: next, openingWidth: snapshot.frozenWidth ?? 480)
        return equal ? .equal(metadata) : .published(metadata)
    }
}

final class PopoverOwnerHarness: Sendable {
    typealias Owner = PaneContextPopoverRefreshOwner<TestPushClock>
    let bridge = PopoverOwnerFactBridge()
    let capture = PopoverOwnerCapture()
    let projections = PopoverOwnerProjectionSink()
    let invalidations = PopoverOwnerInvalidationPorts()
    let ports: PaneContextPopoverTestPorts
    let clock: TestPushClock
    let time: PaneContextTestTime
    let owner: Owner
    let key: PaneContextPopoverConsumerKey
    private let consumedExecutions = Mutex<Set<UUID>>([])
    private let monitors = Mutex<[Task<Void, Never>]>([])

    init(
        detail: PaneContextDetail, heldReads: Set<Int> = [], service: PaneContextPopoverServicePorts? = nil
    ) {
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        let ports = PaneContextPopoverTestPorts(detail, heldReads: heldReads)
        self.clock = clock
        self.time = time
        self.ports = ports
        key = .init(hostId: UUIDv7.generate(), surface: .paneMessages, paneId: detail.paneId)
        let captures = capture
        let service =
            service
            ?? .init(
                epoch: UUIDv7.generate(), reader: ports, invalidations: invalidations, person: ports)
        captures.setServiceEpoch(service.epoch)
        owner = Owner(
            clock: clock, wallNow: { time.now }, service: service,
            capture: { _, _, sources in captures.snapshot(for: sources) }, observe: bridge.observe)
    }

    func open(
        _ selected: PaneContextPopoverConsumerKey? = nil,
        content: PaneContextPopoverDemand.Content = .messages(.top)
    ) async throws -> Owner.Opening {
        let key = selected ?? key
        let port = await projections.port(for: key)
        return try #require(
            await owner.open(
                key, demand: .init(content: content, location: .pane, includingDrawers: true, screenVisibleWidth: 1400),
                projection: port))
    }

    func completed(_ execution: Owner.Execution, for key: PaneContextPopoverConsumerKey? = nil) async throws
        -> PaneContextPopoverOwnerFact.Finish
    {
        await execution.task.value
        try #require(
            consumedExecutions.withLock { $0.insert(execution.id).inserted },
            "The same execution terminal outcome was consumed twice")
        try #require(
            bridge.didFinish(.execution(key ?? self.key, execution.id)),
            "The execution producer ended without its terminal owner fact")
        let scope = PopoverOwnerProofScope(channel: .lifetime(key ?? self.key, execution.opening))
        while true {
            let next = try await bridge.facts.expectNext(
                in: scope, where: { _ in true }, "execution's own terminal outcome")
            if case .owner(.finished(let result)) = next { return result }
        }
    }

    func timer() async throws -> (sequence: UInt64, deadline: TestPushClock.Instant, task: Task<Void, Never>) {
        let timer = try #require(await owner.scheduledWake(), "Demand has no scheduled useful deadline")
        let scope = PopoverOwnerProofScope(channel: .owner(.deadline(timer.sequence)))
        let bridge = bridge
        let monitor = Task {
            await timer.task.value
            if !bridge.didFinish(.deadline(timer.sequence)) { bridge.facts.append(scope: scope, fact: .producerEnded) }
        }
        monitors.withLock { $0.append(monitor) }
        try await bridge.facts.expectNext(in: scope, .owner(.deadlineArmed))
        try await bridge.facts.expectNext(in: scope, .clockRegistered(timer.deadline))
        return timer
    }

    func readStarted(_ number: Int, producer: Owner.Execution) async throws {
        let ports = ports
        let monitor = Task {
            await producer.task.value
            await ports.detailProducerEnded(beforeRead: number)
        }
        monitors.withLock { $0.append(monitor) }
        try await ports.reads.expectNext(in: number, .started(.init(paneId: key.paneId, page: .first)))
    }

    func arrived<Arrival: Sendable>(at step: HeldStep<Arrival>, producer: Owner.Execution) async throws -> Arrival {
        let monitor = Task {
            await producer.task.value
            step.retire()
        }
        monitors.withLock { $0.append(monitor) }
        return try await step.firstArrival()
    }

    func pageFinished(_ id: UUID, expected: PaneContextPopoverOwnerFact.PageFinish) async throws {
        try #require(bridge.didFinish(.page(id)), "The execution ended without completing or refusing this page")
        let scope = PopoverOwnerProofScope(channel: .owner(.page(id)))
        try await bridge.facts.expectNext(in: scope, .owner(.observed))
        try await bridge.facts.expectNext(in: scope, .owner(.pageFinished(expected)))
    }

    func finish() async throws {
        await owner.stop()
        for monitor in monitors.withLock({ $0 }) { await monitor.value }
        await invalidations.finish()
        try await ports.finish()
        bridge.facts.receive(.ended)
        try await bridge.facts.finish()
    }
}
