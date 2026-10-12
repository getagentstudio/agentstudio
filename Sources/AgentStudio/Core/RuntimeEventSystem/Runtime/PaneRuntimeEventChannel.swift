import AgentStudioInfrastructure
import Foundation
import os

/// Shared event channel for pane runtimes:
/// - Tracks envelope sequence numbers
/// - Manages subscriber fanout streams
/// - Stores replayable envelopes
/// - Posts envelopes to the app-wide pane event bus
@MainActor
package final class PaneRuntimeEventChannel {
    package typealias OutboundPost = @Sendable (RuntimeEnvelope) async -> EventBus<RuntimeEnvelope>.PostResult

    private static let logger = Logger(subsystem: "com.agentstudio", category: "PaneRuntimeEventChannel")
    private let clock: ContinuousClock
    private let replayBuffer: EventReplayBuffer
    private let performanceReporter: RuntimeDeliveryPerformanceReporter
    private let performanceChannelToken: RuntimeDeliveryChannelToken
    private let busContinuation: AsyncStream<RuntimeEnvelope>.Continuation
    private let busConsumerTask: Task<Void, Never>

    private var sequence: UInt64 = 0
    private var nextSubscriberId: UInt64 = 0
    private var subscribers: [UInt64: AsyncStream<RuntimeEnvelope>.Continuation] = [:]

    package init(
        clock: ContinuousClock = ContinuousClock(),
        replayBuffer: EventReplayBuffer = EventReplayBuffer(),
        paneEventBus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared,
        performanceReporter: RuntimeDeliveryPerformanceReporter = PaneRuntimeEventBus.performanceReporter,
        outboundPost: OutboundPost? = nil
    ) {
        self.clock = clock
        self.replayBuffer = replayBuffer
        self.performanceReporter = performanceReporter
        let performanceChannelToken = RuntimeDeliveryChannelToken.make()
        self.performanceChannelToken = performanceChannelToken
        performanceReporter.registerRuntimeChannel(performanceChannelToken)

        let (stream, continuation) = AsyncStream.makeStream(
            of: RuntimeEnvelope.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        self.busContinuation = continuation
        let outboundPost =
            outboundPost ?? { envelope in
                await paneEventBus.post(envelope)
            }
        // swiftlint:disable:next no_task_detached
        self.busConsumerTask = Task.detached {
            await Self.consumeOutboundBusStream(
                stream,
                outboundPost: outboundPost,
                performanceReporter: performanceReporter,
                performanceChannelToken: performanceChannelToken
            )
        }
    }

    deinit {
        busContinuation.finish()
        busConsumerTask.cancel()
    }

    package var lastSequence: UInt64 {
        sequence
    }

    package func subscribe(isTerminated: Bool) -> AsyncStream<RuntimeEnvelope> {
        let (stream, continuation) = AsyncStream.makeStream(of: RuntimeEnvelope.self)
        guard !isTerminated else {
            continuation.finish()
            return stream
        }

        let subscriberId = nextSubscriberId
        nextSubscriberId += 1
        subscribers[subscriberId] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.subscribers.removeValue(forKey: subscriberId)
            }
        }

        return stream
    }

    package func eventsSince(seq: UInt64) -> EventReplayBuffer.ReplayResult {
        replayBuffer.eventsSince(seq: seq)
    }

    package func snapshot(
        paneId: PaneId,
        metadata: PaneMetadata,
        lifecycle: PaneRuntimeLifecycle,
        capabilities: Set<PaneCapability>
    ) -> PaneRuntimeSnapshot {
        PaneRuntimeSnapshot(
            paneId: paneId,
            metadata: metadata,
            lifecycle: lifecycle,
            capabilities: capabilities,
            lastSeq: sequence,
            timestamp: Date()
        )
    }

    package func finishSubscribers() {
        let activeSubscribers = Array(subscribers.values)
        subscribers.removeAll(keepingCapacity: true)
        for continuation in activeSubscribers {
            continuation.finish()
        }
        busContinuation.finish()
        busConsumerTask.cancel()
    }

    /// Finishes subscriber streams and awaits the owned outbound worker.
    /// Buffered cancellation keeps finish's existing behavior; call outside that worker.
    /// Completion covers the outbound worker, not subscriber onTermination cleanup.
    package func finishAndJoinOutboundDelivery() async {
        finishSubscribers()
        await busConsumerTask.value
    }

    @concurrent nonisolated private static func consumeOutboundBusStream(
        _ stream: AsyncStream<RuntimeEnvelope>,
        outboundPost: OutboundPost,
        performanceReporter: RuntimeDeliveryPerformanceReporter,
        performanceChannelToken: RuntimeDeliveryChannelToken
    ) async {
        let detachedLogger = Logger(subsystem: "com.agentstudio", category: "PaneRuntimeEventChannel")
        defer {
            performanceReporter.retireRuntimeChannel(performanceChannelToken)
        }
        for await envelope in stream {
            guard !Task.isCancelled else { break }
            let postResult = await outboundPost(envelope)
            performanceReporter.recordRuntimeChannelOutboundPosted(performanceChannelToken)
            if postResult.droppedCount > 0 {
                detachedLogger.warning(
                    "Dropped pane runtime bus event for \(postResult.droppedCount, privacy: .public) subscriber(s); seq=\(envelope.seq, privacy: .public)"
                )
            }
        }
    }

    package func emit(
        paneId: PaneId,
        metadata: PaneMetadata,
        paneKind: PaneContentType,
        commandId: UUID? = nil,
        correlationId: UUID? = nil,
        event: PaneRuntimeEvent,
        persistForReplay: Bool = true,
        timestamp: ContinuousClock.Instant? = nil
    ) {
        sequence += 1
        let envelope = RuntimeEnvelope.pane(
            PaneEnvelope(
                source: .pane(paneId),
                seq: sequence,
                timestamp: timestamp ?? clock.now,
                correlationId: correlationId,
                commandId: commandId,
                paneId: paneId,
                paneKind: paneKind,
                event: event
            )
        )

        if persistForReplay {
            replayBuffer.append(envelope)
        }

        for (subscriberId, continuation) in subscribers {
            switch continuation.yield(envelope) {
            case .enqueued:
                continue
            case .dropped:
                Self.logger.warning(
                    "Dropped local runtime envelope for subscriberId=\(subscriberId, privacy: .public) seq=\(envelope.seq, privacy: .public)"
                )
            case .terminated:
                Self.logger.debug(
                    "Skipped terminated subscriberId=\(subscriberId, privacy: .public) seq=\(envelope.seq, privacy: .public)"
                )
            @unknown default:
                Self.logger.warning(
                    "Encountered unknown AsyncStream.YieldResult for local subscriberId=\(subscriberId, privacy: .public) seq=\(envelope.seq, privacy: .public)"
                )
                continue
            }
        }

        switch busContinuation.yield(envelope) {
        case .enqueued:
            performanceReporter.recordRuntimeChannelOutboundEnqueued(performanceChannelToken)
        case .dropped(let droppedEnvelope):
            performanceReporter.recordRuntimeChannelOutboundDropped()
            Self.logger.warning(
                "Dropped pane runtime outbound buffer event seq=\(droppedEnvelope.seq, privacy: .public)"
            )
        case .terminated:
            Self.logger.debug(
                "Skipped pane runtime outbound buffer event after termination; seq=\(envelope.seq, privacy: .public)"
            )
        @unknown default:
            Self.logger.warning(
                "Encountered unknown AsyncStream.YieldResult for outbound buffer; seq=\(envelope.seq, privacy: .public)"
            )
        }

        _ = metadata
    }
}
