import AgentStudioInfrastructure
import Foundation
import Observation

/// One popover's transient presentation. No source state or persistence is owned here.
@MainActor
@Observable
package final class ArrangementPanelSession {
    package private(set) var presentation: ArrangementTableProjection?
    @ObservationIgnored private let sources: ArrangementPanelSources
    @ObservationIgnored private let project:
        @Sendable (ArrangementTableInput) async throws -> ArrangementTableProjection
    @ObservationIgnored private let onCompletion: @MainActor @Sendable (Bool) -> Void
    @ObservationIgnored private var opening: UUID?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var continuation: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var producer: Task<Void, Never>?

    package init(sources: ArrangementPanelSources) {
        self.sources = sources
        project = { try await ArrangementTableProjector.project($0) }
        onCompletion = { _ in }
    }

    init(
        sources: ArrangementPanelSources,
        project: @escaping @Sendable (ArrangementTableInput) async throws -> ArrangementTableProjection,
        onCompletion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        self.sources = sources
        self.project = project
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
                stream.stream, project: self.project, recorder: self.sources.recorder,
                capture: { [weak self] in self?.capture(tabId: tabId, opening: identity) },
                apply: { [weak self] value, generation in
                    self?.apply(value, opening: identity, generation: generation) ?? false
                },
                completed: { [weak self] accepted in self?.onCompletion(accepted) })
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
        presentation = nil
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
        presentation = value
        recordHeld("publication", since: started)
        return true
    }

    @concurrent nonisolated private static func consume(
        _ stream: AsyncStream<Void>,
        project: @Sendable (ArrangementTableInput) async throws -> ArrangementTableProjection,
        recorder: AgentStudioPerformanceTraceRecorder?,
        capture: @MainActor @Sendable () -> (ArrangementTableInput, UInt64)?,
        apply: @MainActor @Sendable (ArrangementTableProjection, UInt64) -> Bool,
        completed: @MainActor @Sendable (Bool) -> Void
    ) async {
        let defaultShell = SessionConfiguration.defaultShell()
        var previous: ArrangementTableProjection?
        for await _ in stream {
            guard !Task.isCancelled, let (captured, generation) = await capture() else { return }
            var input = captured
            if input.shellExecutablePath == nil { input.shellExecutablePath = defaultShell }
            let start = ContinuousClock.now
            do {
                let value = try await project(input)
                record(recorder, stage: "projection", duration: start.duration(to: .now))
                guard !Task.isCancelled else {
                    record(recorder, stage: "cancelled")
                    return
                }
                if value == previous {
                    record(recorder, stage: "equal")
                    await completed(false)
                } else {
                    let accepted = await apply(value, generation)
                    if accepted { previous = value }
                    await completed(accepted)
                }
            } catch {
                record(recorder, stage: "cancelled")
                guard !Task.isCancelled else { return }
                await completed(false)
            }
        }
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
