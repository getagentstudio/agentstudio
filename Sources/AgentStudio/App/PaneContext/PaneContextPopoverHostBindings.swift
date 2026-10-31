import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

struct PaneContextPopoverConsumerHandle: Sendable {
    let key: PaneContextPopoverConsumerKey
    let opening: PaneContextPopoverOpening
    let atom: PaneContextPopoverDetailAtom
}

/// App composition joins host lifetimes to the actor, canonical capture and materialized slots.
@MainActor
final class PaneContextPopoverHostBindings {
    private struct Setup {
        let id: UUID
        let task: Task<PaneContextPopoverConsumerHandle?, Never>
    }
    let family: PaneContextPopoverDetailFamily
    let owner: any PaneContextPopoverRefreshing
    let inputs: PaneContextPopoverInputCapture
    private let performance: PaneContextPopoverPerformance
    private let serviceProvider: @MainActor () -> PaneContextUIAdapter?
    private var setups: [PaneContextPopoverConsumerKey: Setup] = [:]
    private var auxiliaryTasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private var currentServicePorts: PaneContextPopoverServicePorts?

    init<SourceClock: Clock>(
        clock: SourceClock, wallNow: @escaping @Sendable () -> Date,
        readSource: @escaping PaneContextPopoverInputCapture.SourceReader,
        serviceProvider: @escaping @MainActor () -> PaneContextUIAdapter?,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        bodyLayoutObserver: (@Sendable (PaneContextMessageBodyMeasurement.Observation) -> Void)? = nil,
        observe: @escaping PaneContextPopoverOwnerObserver = { _, _ in }
    ) where SourceClock.Duration == Duration {
        self.serviceProvider = serviceProvider
        let performance = PaneContextPopoverPerformance(
            recorder: performanceTraceRecorder, bodyLayoutObserver: bodyLayoutObserver)
        self.performance = performance
        family = .init(performance: performance)
        let inputs = PaneContextPopoverInputCapture(
            serviceEpoch: { nil }, readSource: readSource, performance: performance)
        self.inputs = inputs
        let owner = PaneContextPopoverRefreshOwner(
            clock: clock, wallNow: wallNow, service: nil,
            capture: { key, opening, generation, sources in
                await inputs.capture(key, opening: opening, requestGeneration: generation, sources: sources)
            },
            performance: performance, observe: observe)
        self.owner = owner
        inputs.setServiceEpochProvider { [weak self] in self?.currentServicePorts?.epoch }
        inputs.connect { [weak owner] key, opening, captured in
            await owner?.receive(captured, for: key, opening: opening)
        }
        inputs.connectGeometry { [weak owner] key, opening, row, capture, operation in
            await owner?.receiveBodyGeometry(capture, row: row, for: key, opening: opening, operation: operation)
        }
    }

    /// Setup tasks form a per-host chain; a new opening joins its predecessor before replacing the slot.
    func beginOpen(
        _ key: PaneContextPopoverConsumerKey, demand: PaneContextPopoverDemand
    ) -> Task<PaneContextPopoverConsumerHandle?, Never> {
        guard !stopped else { return Task { nil } }
        let previous = setups[key]
        previous?.task.cancel()
        let id = UUIDv7.generate()
        let task = Task<PaneContextPopoverConsumerHandle?, Never> { @MainActor [weak self] in
            let prior = await previous?.task.value
            guard let self else { return nil }
            if let prior { await self.retire(prior) }
            guard !self.stopped, !Task.isCancelled, self.setups[key]?.id == id else { return nil }
            await self.owner.replaceService(self.resolveServicePorts())
            guard !self.stopped, !Task.isCancelled, self.setups[key]?.id == id else { return nil }
            guard let atom = self.family.materialize(for: key), let port = self.family.projectionPort(for: key) else {
                return nil
            }
            guard let opening = await self.owner.open(key, demand: demand, projection: port) else {
                await port.retire()
                return nil
            }
            let handle = PaneContextPopoverConsumerHandle(key: key, opening: opening, atom: atom)
            guard !self.stopped, !Task.isCancelled, self.setups[key]?.id == id else {
                await self.retire(handle)
                return nil
            }
            return handle
        }
        setups[key] = .init(id: id, task: task)
        return task
    }

    func beginClose(_ key: PaneContextPopoverConsumerKey) -> Task<Void, Never> {
        let previous = setups[key]
        previous?.task.cancel()
        let id = UUIDv7.generate()
        let barrier = Task<PaneContextPopoverConsumerHandle?, Never> { @MainActor [weak self] in
            let handle = await previous?.task.value
            if let handle { await self?.retire(handle) }
            return nil
        }
        setups[key] = .init(id: id, task: barrier)
        return retain {
            _ = await barrier.value
            if self.setups[key]?.id == id { self.setups.removeValue(forKey: key) }
        }
    }

    /// Exposes the owned lifecycle producer; a close barrier returns nil after retirement drains.
    func lifecycleProducer(for key: PaneContextPopoverConsumerKey) -> Task<PaneContextPopoverConsumerHandle?, Never>? {
        setups[key]?.task
    }

    func retire(_ handle: PaneContextPopoverConsumerHandle) async {
        await owner.close(handle.key, opening: handle.opening.epoch)
        await inputs.close(handle.key, opening: handle.opening.epoch)
        performance.record(.retired, key: handle.key)
    }

    func serviceDidChange() -> Task<Void, Never> {
        let ports = resolveServicePorts()
        return retain { await self.owner.replaceService(ports) }
    }

    func performPerson(
        _ intent: PaneContextPopoverPersonIntent, handle: PaneContextPopoverConsumerHandle
    ) async -> PaneContextPopoverPersonCompletion {
        let previousEpoch = currentServicePorts?.epoch
        let ports = resolveServicePorts()
        await owner.replaceService(ports)
        if previousEpoch != ports?.epoch {
            await joinServiceReplacement(for: handle)
        }
        return await owner.performPerson(intent, for: handle.key, opening: handle.opening.epoch)
    }

    func loadPage(
        _ scope: PaneContextPopoverPageScope, handle: PaneContextPopoverConsumerHandle
    ) async -> PaneContextPopoverOwnerFact.PageFinish {
        await owner.replaceService(resolveServicePorts())
        return await owner.loadPage(scope, for: handle.key, opening: handle.opening.epoch)
    }

    private func joinServiceReplacement(for handle: PaneContextPopoverConsumerHandle) async {
        var joinedProducer: UUID?
        while let producer = await owner.latestExecution(for: handle.key),
            producer.opening == handle.opening.epoch, producer.id != joinedProducer
        {
            // Only a changed service needs this barrier; ordinary pending form validation still refuses actions.
            joinedProducer = producer.id
            await producer.task.value
        }
    }

    private func resolveServicePorts() -> PaneContextPopoverServicePorts? {
        let ports = serviceProvider()?.popoverPorts
        currentServicePorts = ports
        return ports
    }

    private func retain(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUIDv7.generate()
        let task = Task { @MainActor [weak self] in
            defer { self?.auxiliaryTasks.removeValue(forKey: id) }
            await operation()
        }
        auxiliaryTasks[id] = task
        return task
    }

    func stop() async {
        stopped = true
        let pending = setups.values.map(\.task)
        setups.removeAll()
        for task in pending { task.cancel() }
        for task in pending {
            if let handle = await task.value { await retire(handle) }
        }
        let updates = Array(auxiliaryTasks.values)
        for task in updates { await task.value }
        await owner.stop()
        await inputs.stop()
        await family.stop()
    }
}
