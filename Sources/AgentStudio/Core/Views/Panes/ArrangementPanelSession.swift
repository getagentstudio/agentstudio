import AgentStudioInfrastructure
import Foundation
import Observation

/// One popover's transient presentation. No source state or persistence is owned here.
@MainActor
@Observable
package final class ArrangementPanelSession {
    // Deliberately not Equatable: the worker is the sole content comparator, as in AtomLib's unconstrained values.
    private struct PublishedProjection {
        let value: ArrangementTableProjection
    }

    private var publishedProjection: PublishedProjection?
    package var presentation: ArrangementTableProjection? { publishedProjection?.value }
    @ObservationIgnored private let sources: ArrangementPanelSources
    @ObservationIgnored private let project:
        @Sendable (ArrangementTableInput) async throws -> ArrangementTableProjection
    @ObservationIgnored private let onCompletion: @MainActor @Sendable (Bool) -> Void
    private struct ProjectionTimeSource: Sendable {
        let delay: AsyncDelay
        let wallNow: @Sendable () -> Date
    }

    private struct ProjectionCallbacks: Sendable {
        let capture: @MainActor @Sendable () -> (ArrangementTableInput, UInt64)?
        let apply: @MainActor @Sendable (ArrangementTableProjection, UInt64) -> Bool
        let completed: @MainActor @Sendable (Bool) -> Void
    }

    @ObservationIgnored private let timeSource: ProjectionTimeSource
    @ObservationIgnored private var opening: UUID?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var continuation: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var producer: Task<Void, Never>?

    package init(sources: ArrangementPanelSources) {
        self.sources = sources
        timeSource = .init(delay: .taskSleep, wallNow: { Date() })
        project = { try await ArrangementTableProjector.project($0) }
        onCompletion = { _ in }
    }

    init(
        sources: ArrangementPanelSources,
        project: @escaping @Sendable (ArrangementTableInput) async throws -> ArrangementTableProjection,
        onCompletion: @escaping @MainActor @Sendable (Bool) -> Void,
        delay: AsyncDelay = .taskSleep, wallNow: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sources = sources
        self.project = project
        timeSource = .init(delay: delay, wallNow: wallNow)
        self.onCompletion = onCompletion
    }

    package func beginArrangementProjection(tabId: UUID) -> Task<Void, Never> {
        let previous = retireArrangementProjection()
        let identity = UUIDv7.generate()
        opening = identity
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = stream.continuation
        stream.continuation.yield()
        record("admission")
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.record("retired") }
            guard self.opening == identity, !Task.isCancelled else {
                self.record("cancelled")
                return
            }
            await Self.consume(
                stream.stream, project: self.project, recorder: self.sources.recorder, timeSource: self.timeSource,
                callbacks: .init(
                    capture: { [weak self] in self?.capture(tabId: tabId, opening: identity) },
                    apply: { [weak self] value, generation in
                        self?.apply(value, opening: identity, generation: generation) ?? false
                    },
                    completed: { [weak self] accepted in self?.onCompletion(accepted) }))
        }
        producer = task
        return task
    }

    /// Revoke synchronously; callers and the next opening join this exact producer.
    package func retireArrangementProjection() -> Task<Void, Never>? {
        opening = nil
        generation &+= 1
        continuation?.finish()
        continuation = nil
        producer?.cancel()
        if publishedProjection != nil { publishedProjection = nil }
        return producer
    }

    private func capture(tabId: UUID, opening identity: UUID) -> (ArrangementTableInput, UInt64)? {
        guard opening == identity, !Task.isCancelled else { return nil }
        let started = ContinuousClock.now
        let captured = withObservationTracking {
            sources.capture(tabId: tabId)
        } onChange: { [weak self] in
            // All captured writers are MainActor owners. Revoke at willSet, copy on the stream's next turn.
            MainActor.assumeIsolated { self?.invalidate(opening: identity) }
        }
        recordHeld("capture", since: started)
        return (captured, generation)
    }

    private func invalidate(opening identity: UUID) {
        guard opening == identity else { return }
        generation &+= 1
        let result = continuation?.yield()
        switch result {
        case .dropped?: record("coalesced")
        case .enqueued?: record("observed")
        case .terminated?, nil: break
        @unknown default: break
        }
    }

    private func apply(_ value: ArrangementTableProjection, opening identity: UUID, generation requested: UInt64)
        -> Bool
    {
        guard opening == identity, generation == requested, !Task.isCancelled else {
            record("superseded")
            return false
        }
        let started = ContinuousClock.now
        publishedProjection = PublishedProjection(value: value)
        recordHeld("publication", since: started)
        return true
    }

    @concurrent nonisolated private static func consume(
        _ stream: AsyncStream<Void>,
        project: @Sendable (ArrangementTableInput) async throws -> ArrangementTableProjection,
        recorder: AgentStudioPerformanceTraceRecorder?, timeSource: ProjectionTimeSource,
        callbacks: ProjectionCallbacks
    ) async {
        let updates = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { updates.continuation.finish() }
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    updates.continuation.yield()
                }
            }
            await projectUpdates(
                updates.stream, project: project, recorder: recorder, timeSource: timeSource,
                callbacks: callbacks, invalidated: { updates.continuation.yield() })
            group.cancelAll()
        }
    }

    @concurrent nonisolated private static func projectUpdates(
        _ stream: AsyncStream<Void>,
        project: @Sendable (ArrangementTableInput) async throws -> ArrangementTableProjection,
        recorder: AgentStudioPerformanceTraceRecorder?, timeSource: ProjectionTimeSource,
        callbacks: ProjectionCallbacks,
        invalidated: @escaping @Sendable () -> Void
    ) async {
        let defaultShell = SessionConfiguration.defaultShell()
        var previous: ArrangementTableProjection?
        var ageDeadline: Task<Void, Never>?
        for await _ in stream {
            guard !Task.isCancelled, let (captured, generation) = await callbacks.capture() else { break }
            ageDeadline?.cancel()
            await ageDeadline?.value
            ageDeadline = nil
            var input = captured
            input.referenceDate = timeSource.wallNow()
            if input.shellExecutablePath == nil { input.shellExecutablePath = defaultShell }
            let start = ContinuousClock.now
            do {
                let value = try await project(input)
                record(recorder, stage: "projection", duration: start.duration(to: .now))
                guard !Task.isCancelled else {
                    record(recorder, stage: "cancelled")
                    break
                }
                if value == previous {
                    record(recorder, stage: "equal")
                    await callbacks.completed(false)
                } else {
                    let accepted = await callbacks.apply(value, generation)
                    if accepted { previous = value }
                    await callbacks.completed(accepted)
                }
                if let nextChange = value.nextAgeChange {
                    record(recorder, stage: "age_scheduled")
                    ageDeadline = Task {
                        let delay = Duration.seconds(max(0, nextChange.timeIntervalSince(timeSource.wallNow())))
                        do { try await timeSource.delay.wait(delay) } catch { return }
                        guard !Task.isCancelled else { return }
                        record(recorder, stage: "age_fired")
                        invalidated()
                    }
                }
            } catch {
                record(recorder, stage: "cancelled")
                guard !Task.isCancelled else { break }
                await callbacks.completed(false)
            }
        }
        ageDeadline?.cancel()
        await ageDeadline?.value
    }

    private func record(_ stage: String) { Self.record(sources.recorder, stage: stage) }

    private func recordHeld(_ stage: String, since start: ContinuousClock.Instant) {
        sources.recorder?.recordDuration(
            .paneContextPopoverMainActorHeld, duration: start.duration(to: .now),
            attributes: Self.attributes(stage))
    }

    nonisolated private static func record(
        _ recorder: AgentStudioPerformanceTraceRecorder?, stage: String, duration: Duration? = nil
    ) {
        if let duration {
            recorder?.recordDuration(.paneContextPopover, duration: duration, attributes: attributes(stage))
        } else {
            recorder?.record(.paneContextPopover, attributes: attributes(stage))
        }
    }

    nonisolated private static func attributes(_ stage: String) -> [String: AgentStudioTraceValue] {
        [
            "agentstudio.performance.pane_context.popover.surface": .string("arrangements"),
            "agentstudio.performance.pane_context.popover.stage": .string(stage),
            "agentstudio.performance.pane_context.popover.kind": .string("none"),
        ]
    }
}
