import Foundation
import Synchronization

package final class AgentStudioTraceEventQueue: @unchecked Sendable {
    package struct CompletenessSnapshot: Equatable, Sendable {
        package let droppedRecordCount: Int
        package let highWaterMark: Int
        package let pendingRequestCount: Int
    }

    private struct CompletenessState: Sendable {
        var droppedRecordCount = 0
        var highWaterMark = 0
        var pendingRequestCount = 0
    }

    private final class CompletenessTracker: Sendable {
        private let state = Mutex(CompletenessState())
        private let statistics: AgentStudioTraceQueueStatistics
        private let queueID: AgentStudioTraceQueueStatistics.QueueID
        private let bufferLimit: Int

        init(statistics: AgentStudioTraceQueueStatistics, bufferLimit: Int) {
            self.statistics = statistics
            self.queueID = statistics.register()
            self.bufferLimit = bufferLimit
        }

        func enqueue(
            _ request: TraceRequest,
            continuation: AsyncStream<TraceRequest>.Continuation
        ) -> AsyncStream<TraceRequest>.Continuation.YieldResult {
            state.withLock { state in
                // Serialize yield accounting with worker dequeue accounting. A
                // worker cannot report an older snapshot after this report.
                state.pendingRequestCount += 1
                let result = continuation.yield(request)
                switch result {
                case .enqueued(let remainingCapacity):
                    state.highWaterMark = max(state.highWaterMark, bufferLimit - remainingCapacity)
                case .dropped(let droppedRequest):
                    state.highWaterMark = bufferLimit
                    state.pendingRequestCount = max(0, state.pendingRequestCount - 1)
                    if case .record = droppedRequest { state.droppedRecordCount += 1 }
                case .terminated:
                    state.pendingRequestCount = max(0, state.pendingRequestCount - 1)
                    if case .record = request { state.droppedRecordCount += 1 }
                @unknown default:
                    state.pendingRequestCount = max(0, state.pendingRequestCount - 1)
                }
                report(state)
                return result
            }
        }

        func takeRequest() -> CompletenessSnapshot {
            state.withLock { state in
                state.pendingRequestCount = max(0, state.pendingRequestCount - 1)
                report(state)
                return snapshot(state)
            }
        }

        func snapshot() -> CompletenessSnapshot {
            state.withLock { snapshot($0) }
        }

        func retire() {
            statistics.retire(queueID)
        }

        private func report(_ state: CompletenessState) {
            statistics.report(
                queueID,
                snapshot: .init(
                    droppedRecordCount: state.droppedRecordCount,
                    pendingRequestCount: state.pendingRequestCount,
                    // Pending includes an AsyncStream handoff until the worker
                    // claims it. Backlog is the admitted work up to buffer capacity;
                    // executing records have already left both counts.
                    backlog: min(bufferLimit, state.pendingRequestCount)
                )
            )
        }

        private func snapshot(_ state: CompletenessState) -> CompletenessSnapshot {
            CompletenessSnapshot(
                droppedRecordCount: state.droppedRecordCount,
                highWaterMark: state.highWaterMark,
                pendingRequestCount: state.pendingRequestCount
            )
        }
    }

    private enum TraceRequest: Sendable {
        case record(RecordRequest)
        case flush(UnsafeContinuation<Void, Error>)
    }

    private struct RecordRequest: Sendable {
        var tag: AgentStudioTraceTag
        var body: String
        var traceID: String?
        var spanID: String?
        var parentSpanID: String?
        var eventTimeUnixNano: UInt64?
        var attributes: [String: AgentStudioTraceValue]
    }

    private let traceRuntime: AgentStudioTraceRuntime
    private let bufferLimit: Int
    private let lock = NSLock()
    private var continuation: AsyncStream<TraceRequest>.Continuation?
    private var workerTask: Task<Void, Never>?
    private var isClosed = false
    private let completenessTracker: CompletenessTracker

    package convenience init(traceRuntime: AgentStudioTraceRuntime) {
        self.init(
            traceRuntime: traceRuntime,
            bufferLimit: AppPolicies.Diagnostics.traceEventQueueBufferLimit
        )
    }

    package init(traceRuntime: AgentStudioTraceRuntime, bufferLimit: Int) {
        precondition(bufferLimit > 0)
        self.traceRuntime = traceRuntime
        self.bufferLimit = bufferLimit
        self.completenessTracker = CompletenessTracker(
            statistics: traceRuntime.queueStatistics, bufferLimit: bufferLimit
        )
    }

    deinit {
        cancel()
    }

    package func record(
        tag: AgentStudioTraceTag,
        body: String,
        traceID: String? = nil,
        spanID: String? = nil,
        parentSpanID: String? = nil,
        eventTimeUnixNano: UInt64? = nil,
        attributes: [String: AgentStudioTraceValue]
    ) {
        let request = RecordRequest(
            tag: tag,
            body: body,
            traceID: traceID,
            spanID: spanID,
            parentSpanID: parentSpanID,
            eventTimeUnixNano: eventTimeUnixNano,
            attributes: attributes
        )
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        ensureWorkerStartedLocked()
        let yieldResult = continuation.map { completenessTracker.enqueue(.record(request), continuation: $0) }
        lock.unlock()
        guard let yieldResult else { return }
        let droppedFlushContinuation = Self.displacedFlushContinuation(yieldResult)
        droppedFlushContinuation?.resume(throwing: CancellationError())
    }

    package func flush() async throws {
        let isOpen: Bool = lock.withLock {
            guard !isClosed else { return false }
            ensureWorkerStartedLocked()
            return true
        }
        guard isOpen else {
            try await traceRuntime.flush()
            return
        }

        try await withUnsafeThrowingContinuation { (flushContinuation: UnsafeContinuation<Void, Error>) in
            lock.lock()
            guard !isClosed, let continuation else {
                lock.unlock()
                flushContinuation.resume(throwing: CancellationError())
                return
            }
            let yieldResult = completenessTracker.enqueue(.flush(flushContinuation), continuation: continuation)
            lock.unlock()
            let droppedFlushContinuation = Self.displacedFlushContinuation(yieldResult)
            let didTerminate: Bool
            switch yieldResult {
            case .terminated:
                didTerminate = true
            case .enqueued, .dropped:
                didTerminate = false
            @unknown default:
                didTerminate = true
            }
            droppedFlushContinuation?.resume(throwing: CancellationError())
            if didTerminate {
                flushContinuation.resume(throwing: CancellationError())
            }
        }
    }

    package func drain() async throws {
        let (continuation, workerTask) = closeForDrain()
        continuation?.finish()
        await workerTask?.value
        completenessTracker.retire()
        try await traceRuntime.flush()
    }

    package func cancel() {
        lock.lock()
        isClosed = true
        let continuation = continuation
        self.continuation = nil
        let workerTask = workerTask
        self.workerTask = nil
        lock.unlock()
        continuation?.finish()
        workerTask?.cancel()
        completenessTracker.retire()
    }

    package func completenessSnapshot() -> CompletenessSnapshot {
        completenessTracker.snapshot()
    }

    private func closeForDrain() -> (
        AsyncStream<TraceRequest>.Continuation?, Task<Void, Never>?
    ) {
        lock.lock()
        isClosed = true
        let continuation = continuation
        self.continuation = nil
        let workerTask = workerTask
        self.workerTask = nil
        lock.unlock()
        return (continuation, workerTask)
    }

    private func ensureWorkerStartedLocked() {
        guard workerTask == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(
            of: TraceRequest.self,
            bufferingPolicy: .bufferingNewest(bufferLimit)
        )
        self.continuation = continuation
        let traceRuntime = traceRuntime
        let completenessTracker = completenessTracker
        // Detached worker avoids inheriting MainActor while trace I/O drains.
        // swiftlint:disable:next no_task_detached
        workerTask = Task.detached(priority: .utility) {
            for await request in stream {
                let requestBacklogSnapshot = completenessTracker.takeRequest()
                switch request {
                case .record(let request):
                    var attributes = request.attributes
                    if request.tag == .performance {
                        attributes["agentstudio.performance.trace_queue.dropped_record.count"] = .int(
                            requestBacklogSnapshot.droppedRecordCount
                        )
                        attributes["agentstudio.performance.trace_queue.high_watermark"] = .int(
                            requestBacklogSnapshot.highWaterMark
                        )
                        attributes["agentstudio.performance.trace_queue.pending_request.count"] = .int(
                            requestBacklogSnapshot.pendingRequestCount
                        )
                    }
                    let completeAttributes = attributes
                    await traceRuntime.record(
                        tag: request.tag,
                        body: request.body,
                        traceID: request.traceID,
                        spanID: request.spanID,
                        parentSpanID: request.parentSpanID,
                        eventTimeUnixNano: request.eventTimeUnixNano,
                        attributes: completeAttributes
                    )
                case .flush(let continuation):
                    do {
                        await traceRuntime.record(
                            tag: .performance,
                            body: "performance.trace_queue.completeness",
                            attributes: [
                                "agentstudio.performance.trace_queue.dropped_record.count": .int(
                                    requestBacklogSnapshot.droppedRecordCount
                                ),
                                "agentstudio.performance.trace_queue.high_watermark": .int(
                                    requestBacklogSnapshot.highWaterMark
                                ),
                                "agentstudio.performance.trace_queue.pending_request.count": .int(
                                    requestBacklogSnapshot.pendingRequestCount
                                ),
                            ]
                        )
                        try await traceRuntime.flush()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private static func displacedFlushContinuation(
        _ yieldResult: AsyncStream<TraceRequest>.Continuation.YieldResult
    ) -> UnsafeContinuation<Void, Error>? {
        guard case .dropped(.flush(let continuation)) = yieldResult else { return nil }
        return continuation
    }
}
