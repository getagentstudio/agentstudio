import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("AgentStudio trace event queue")
struct AgentStudioTraceEventQueueTests {
    @Test("flush makes queued records visible without closing the queue")
    func flushMakesQueuedRecordsVisibleWithoutClosingQueue() async throws {
        let traceRuntime = makeTraceRuntime()
        let queue = AgentStudioTraceEventQueue(traceRuntime: traceRuntime)
        let outputFileURL = try #require(traceRuntime.outputFileURL)

        queue.record(tag: .inbox, body: "trace.queue.first", attributes: [:])
        try await queue.flush()

        let firstContents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(firstContents.contains("\"body\":\"trace.queue.first\""))

        queue.record(tag: .inbox, body: "trace.queue.second", attributes: [:])
        try await queue.flush()

        let secondContents = try String(contentsOf: outputFileURL, encoding: .utf8)
        #expect(secondContents.contains("\"body\":\"trace.queue.first\""))
        #expect(secondContents.contains("\"body\":\"trace.queue.second\""))

        queue.cancel()
    }

    @Test("queue reports dropped records and buffer high-water mark")
    func queueReportsDroppedRecordsAndBufferHighWaterMark() async throws {
        let blockingSink = BlockingTraceSink()
        await blockingSink.suspendRecords()
        let traceRuntime = makeTraceRuntime(sink: blockingSink)
        let queue = AgentStudioTraceEventQueue(traceRuntime: traceRuntime, bufferLimit: 1)

        queue.record(tag: .performance, body: "trace.queue.blocking", attributes: [:])
        await blockingSink.waitForRecordAttempt()
        queue.record(tag: .performance, body: "trace.queue.dropped", attributes: [:])
        queue.record(tag: .performance, body: "trace.queue.retained", attributes: [:])

        let completenessSnapshot = queue.completenessSnapshot()
        #expect(completenessSnapshot.droppedRecordCount == 1)
        #expect(completenessSnapshot.highWaterMark == 1)
        #expect(completenessSnapshot.pendingRequestCount == 1)
        #expect(
            traceRuntime.queueStatistics.snapshot()
                == .init(droppedRecordCount: 1, pendingRequestCount: 1, highWaterMark: 1)
        )

        await blockingSink.resumeRecords()
        try await queue.drain()
        #expect(
            traceRuntime.queueStatistics.snapshot()
                == .init(droppedRecordCount: 1, pendingRequestCount: 0, highWaterMark: 1)
        )

        let retainedAttributes = try #require(
            await blockingSink.attributes(forBody: "trace.queue.retained")
        )
        #expect(
            retainedAttributes["agentstudio.performance.trace_queue.dropped_record.count"] == .int(1)
        )
        #expect(
            retainedAttributes["agentstudio.performance.trace_queue.high_watermark"] == .int(1)
        )
        #expect(
            retainedAttributes["agentstudio.performance.trace_queue.pending_request.count"] == .int(0)
        )
    }

    @Test("flush exports completeness after displacing the last buffered performance record")
    func flushExportsTerminalDropCompleteness() async throws {
        let blockingSink = BlockingTraceSink()
        await blockingSink.suspendRecords()
        let traceRuntime = makeTraceRuntime(sink: blockingSink)
        let queue = AgentStudioTraceEventQueue(traceRuntime: traceRuntime, bufferLimit: 1)

        queue.record(tag: .performance, body: "trace.queue.blocking", attributes: [:])
        await blockingSink.waitForRecordAttempt()
        queue.record(tag: .performance, body: "trace.queue.displaced-by-flush", attributes: [:])
        let flushTask = Task {
            try await queue.flush()
        }

        let observedDrop = await waitUntil {
            queue.completenessSnapshot().droppedRecordCount == 1
        }
        #expect(observedDrop, "Flush did not displace the buffered performance record")

        await blockingSink.resumeRecords()
        try await flushTask.value
        try await queue.drain()

        let completenessAttributes = try #require(
            await blockingSink.attributes(forBody: "performance.trace_queue.completeness")
        )
        #expect(
            completenessAttributes["agentstudio.performance.trace_queue.dropped_record.count"] == .int(1)
        )
        #expect(
            completenessAttributes["agentstudio.performance.trace_queue.high_watermark"] == .int(1)
        )
        #expect(
            completenessAttributes["agentstudio.performance.trace_queue.pending_request.count"] == .int(0)
        )
    }

    private func makeTraceRuntime() -> AgentStudioTraceRuntime {
        AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": temporaryTraceDirectoryURL().path,
                "AGENTSTUDIO_TRACE_FLUSH": "immediate",
                "AGENTSTUDIO_TRACE_NAME": "trace-event-queue",
                "AGENTSTUDIO_TRACE_TAGS": "inbox",
            ]),
            processIdentifier: 620,
            sessionID: "trace-event-queue-session",
            timeUnixNano: { 6200 }
        )
    }

    private func makeTraceRuntime(sink: BlockingTraceSink) -> AgentStudioTraceRuntime {
        AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": temporaryTraceDirectoryURL().path,
                "AGENTSTUDIO_TRACE_FLUSH": "immediate",
                "AGENTSTUDIO_TRACE_NAME": "trace-event-queue-completeness",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 621,
            sessionID: "trace-event-queue-completeness-session",
            sinkFactory: AgentStudioTraceSinkFactory(
                makeJSONLSink: { _ in sink },
                makeOTLPSink: { _ in sink }
            ),
            timeUnixNano: { 6210 }
        )
    }

    private func temporaryTraceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-trace-event-queue-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func waitUntil(
        attempts: Int = 10_000,
        predicate: () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

private actor BlockingTraceSink: AgentStudioTraceSink {
    private var records: [AgentStudioTraceRecord] = []
    private var shouldSuspendRecords = false
    private var suspendedRecordContinuations: [CheckedContinuation<Void, Never>] = []
    private var recordAttemptCount = 0
    private var recordAttemptContinuations: [CheckedContinuation<Void, Never>] = []

    func record(_ record: AgentStudioTraceRecord) async throws {
        recordAttemptCount += 1
        let waitingContinuations = recordAttemptContinuations
        recordAttemptContinuations.removeAll()
        for continuation in waitingContinuations {
            continuation.resume()
        }
        if shouldSuspendRecords {
            await withCheckedContinuation { continuation in
                suspendedRecordContinuations.append(continuation)
            }
        }
        records.append(record)
    }

    func flush() throws {}

    func shutdown() throws {}

    func diagnostics() -> AgentStudioTraceWriterDiagnostics {
        .empty
    }

    func suspendRecords() {
        shouldSuspendRecords = true
    }

    func resumeRecords() {
        shouldSuspendRecords = false
        let continuations = suspendedRecordContinuations
        suspendedRecordContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForRecordAttempt() async {
        guard recordAttemptCount == 0 else { return }
        await withCheckedContinuation { continuation in
            recordAttemptContinuations.append(continuation)
        }
    }

    func attributes(forBody body: String) -> [String: AgentStudioTraceValue]? {
        records.first(where: { $0.body == body })?.attributes
    }
}
