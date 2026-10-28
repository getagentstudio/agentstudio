import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation
import Observation

/// Registers keyed canonical reads and forwards plain copies to the off-main owner.
@MainActor
final class PaneContextPopoverInputCapture {
    typealias SourceReader = @MainActor (PaneId) -> PopoverSourceCapture.Source
    typealias Sink = @Sendable (PaneContextPopoverConsumerKey, UInt64, PopoverSourceCapture) async -> Void
    typealias GeometrySink =
        @Sendable (
            PaneContextPopoverConsumerKey, UInt64, MessageRowModel.Key, PaneContextMessageBodyGeometry, UUID
        ) async -> Void

    private struct Registration {
        let opening: UInt64
        var requestGeneration: UInt64
        let sources: Set<PaneId>
        var trackingId: UUID
        var generation: UInt64
        var observing: Bool
    }
    private struct Forwarding {
        let opening: UInt64
        let task: Task<Void, Never>
    }
    private let readSource: SourceReader
    private let performance: PaneContextPopoverPerformance
    private var serviceEpoch: @MainActor () -> UUID?
    private var changed: Sink?
    private var geometryChanged: GeometrySink?
    private var registrations: [PaneContextPopoverConsumerKey: Registration] = [:]
    private var forwarding: [PaneContextPopoverConsumerKey: [UUID: Forwarding]] = [:]
    private var observationSequence: UInt64 = 0
    private var stopped = false

    init(
        serviceEpoch: @escaping @MainActor () -> UUID?, readSource: @escaping SourceReader,
        performance: PaneContextPopoverPerformance = .init(recorder: nil)
    ) {
        self.performance = performance
        self.serviceEpoch = serviceEpoch
        self.readSource = readSource
    }

    func connect(_ sink: @escaping Sink) { changed = sink }
    func connectGeometry(_ sink: @escaping GeometrySink) { geometryChanged = sink }

    /// Captures plain UI values; the detached forwarder never performs a MainActor transform.
    func forwardBodyGeometry(
        _ geometry: PaneContextMessageBodyGeometry, row: MessageRowModel.Key,
        for key: PaneContextPopoverConsumerKey, opening: UInt64
    ) -> Task<Void, Never>? {
        guard !stopped, registrations[key]?.opening == opening else { return nil }
        let operation = UUIDv7.generate()
        let sink = geometryChanged
        // Delivery must escape UI isolation; this task forwards captured values to the existing actor only.
        // swiftlint:disable:next no_task_detached
        let task = Task.detached { [weak self] in
            await sink?(key, opening, row, geometry, operation)
            await self?.removeForwarding(operation, for: key)
        }
        forwarding[key, default: [:]][operation] = .init(opening: opening, task: task)
        return task
    }
    func setServiceEpochProvider(_ provider: @escaping @MainActor () -> UUID?) { serviceEpoch = provider }

    func capture(
        _ key: PaneContextPopoverConsumerKey, opening: UInt64, requestGeneration: UInt64, sources: Set<PaneId>
    ) -> PopoverSourceCapture {
        performance.mainActorHeld(.capture, key: key) {
            guard !stopped else {
                return .init(observationGeneration: observationSequence, serviceEpoch: nil, sources: [:])
            }
            if let current = registrations[key],
                current.opening > opening
                    || (current.opening == opening && current.requestGeneration > requestGeneration)
            {
                return copyValues(current.sources, generation: current.generation)
            }
            if registrations[key]?.opening != opening || registrations[key]?.sources != sources {
                observationSequence &+= 1
                registrations[key] = .init(
                    opening: opening, requestGeneration: requestGeneration, sources: sources,
                    trackingId: UUIDv7.generate(),
                    generation: observationSequence,
                    observing: false)
            }
            guard var registration = registrations[key] else {
                preconditionFailure("Capture registration was not installed")
            }
            registration.requestGeneration = requestGeneration
            registrations[key] = registration
            if registration.observing { return copyValues(sources, generation: registration.generation) }
            registration.trackingId = UUIDv7.generate()
            registration.observing = true
            registrations[key] = registration
            let trackingId = registration.trackingId
            return withObservationTracking {
                copyValues(sources, generation: registration.generation)
            } onChange: { [weak self] in
                // Every producer read here publishes on MainActor. Defer the value copy past willSet.
                MainActor.assumeIsolated { self?.sourceWillChange(key, opening: opening, trackingId: trackingId) }
            }
        }
    }

    private func copyValues(_ sources: Set<PaneId>, generation: UInt64) -> PopoverSourceCapture {
        var values: [PaneId: PopoverSourceCapture.Source] = [:]
        for source in sources { values[source] = readSource(source) }
        return .init(observationGeneration: generation, serviceEpoch: serviceEpoch(), sources: values)
    }

    private func sourceWillChange(_ key: PaneContextPopoverConsumerKey, opening: UInt64, trackingId: UUID) {
        guard !stopped, var registration = registrations[key], registration.opening == opening,
            registration.trackingId == trackingId
        else { return }
        observationSequence &+= 1
        registration.generation = observationSequence
        registration.observing = false
        registrations[key] = registration
        let operation = UUIDv7.generate()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.removeForwarding(operation, for: key) }
            guard !Task.isCancelled, !self.stopped, let current = self.registrations[key],
                current.opening == opening, current.trackingId == trackingId
            else { return }
            let captured = self.capture(
                key, opening: opening, requestGeneration: current.requestGeneration, sources: current.sources)
            await self.changed?(key, opening, captured)
        }
        forwarding[key, default: [:]][operation] = .init(opening: opening, task: task)
    }

    private func removeForwarding(_ operation: UUID, for key: PaneContextPopoverConsumerKey) {
        forwarding[key]?.removeValue(forKey: operation)
        if forwarding[key]?.isEmpty == true { forwarding.removeValue(forKey: key) }
    }

    func forwardingTasks(for key: PaneContextPopoverConsumerKey, opening: UInt64) -> [Task<Void, Never>] {
        (forwarding[key] ?? [:]).values.filter { $0.opening == opening }.map(\.task)
    }

    /// The refresh owner drains this opening before its composition removes the registrations.
    func close(_ key: PaneContextPopoverConsumerKey, opening: UInt64) async {
        if registrations[key]?.opening == opening { registrations.removeValue(forKey: key) }
        let pending = forwardingTasks(for: key, opening: opening)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
    }

    func stop() async {
        stopped = true
        registrations.removeAll()
        changed = nil
        geometryChanged = nil
        let pending = forwarding.values.flatMap { $0.values.map(\.task) }
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        forwarding.removeAll()
    }
}
