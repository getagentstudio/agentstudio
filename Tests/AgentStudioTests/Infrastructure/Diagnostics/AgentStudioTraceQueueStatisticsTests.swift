import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioTraceQueueStatisticsTests {
    @Test
    func queueCopiesOnOtherEventsProduceNoPerEventSeries() throws {
        let record = AgentStudioOTLPPerformanceMetricsTests.metricDimensionRecord(
            eventName: "performance.git.status",
            attributes: [
                "agentstudio.performance.trace_queue.dropped_record.count": .int(2),
                "agentstudio.performance.trace_queue.pending_request.count": .int(3),
                "agentstudio.performance.trace_queue.high_watermark": .int(4),
            ]
        )
        let event = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))
        #expect(event.samples.isEmpty)
        #expect(event.measurements.count == 1)
        #expect(event.elapsedMilliseconds == 7.5)
        let factory = OTLPRecordingMetricsFactory()
        AgentStudioOTLPPerformanceMetrics(factory: factory).record(record)
        #expect(
            factory.recorder(
                label: "agentstudio_performance_event_elapsed_ms", dimensions: [("event", "performance.git.status")]
            )?.values == [7.5]
        )
        for label in [
            "agentstudio_performance_trace_queue_dropped_record_count",
            "agentstudio_performance_trace_queue_pending_request_count",
            "agentstudio_performance_trace_queue_high_watermark",
        ] {
            #expect(factory.recorder(label: label, dimensions: [("event", "performance.git.status")]) == nil)
        }
    }
    @Test
    func severalQueuesRetainLossAndRetirementRemovesOccupancy() {
        let statistics = AgentStudioTraceQueueStatistics()
        let first = statistics.register()
        let second = statistics.register()
        statistics.report(first, snapshot: .init(droppedRecordCount: 2, pendingRequestCount: 2, backlog: 2))
        statistics.report(second, snapshot: .init(droppedRecordCount: 3, pendingRequestCount: 3, backlog: 3))
        #expect(statistics.snapshot() == .init(droppedRecordCount: 5, pendingRequestCount: 5, highWaterMark: 5))
        statistics.report(first, snapshot: .init(droppedRecordCount: 2, pendingRequestCount: 0, backlog: 0))
        statistics.retire(second)
        #expect(statistics.snapshot() == .init(droppedRecordCount: 5, pendingRequestCount: 0, highWaterMark: 5))
        // A worker finishing after cancellation cannot resurrect a retired queue.
        statistics.report(second, snapshot: .init(droppedRecordCount: 4, pendingRequestCount: 1, backlog: 1))
        statistics.retire(second)
        #expect(statistics.snapshot() == .init(droppedRecordCount: 5, pendingRequestCount: 0, highWaterMark: 5))
        statistics.report(first, snapshot: .init(droppedRecordCount: 4, pendingRequestCount: 1, backlog: 1))
        statistics.retire(first)
        #expect(statistics.snapshot() == .init(droppedRecordCount: 7, pendingRequestCount: 0, highWaterMark: 5))
    }

    @Test
    func highWaterMarkIsPeakCombinedBacklogRatherThanSumOfIndividualPeaks() {
        let statistics = AgentStudioTraceQueueStatistics()
        let first = statistics.register()
        let second = statistics.register()
        statistics.report(first, snapshot: .init(pendingRequestCount: 4, backlog: 4))
        statistics.report(first, snapshot: .init())
        statistics.report(second, snapshot: .init(pendingRequestCount: 3, backlog: 3))
        #expect(statistics.snapshot().highWaterMark == 4)
        statistics.report(first, snapshot: .init(pendingRequestCount: 2, backlog: 2))
        #expect(statistics.snapshot().highWaterMark == 5)
        statistics.retire(first)
        statistics.retire(second)
        #expect(statistics.snapshot() == .init(droppedRecordCount: 0, pendingRequestCount: 0, highWaterMark: 5))
    }

    @Test
    func attachmentPublishesRetainedValuesAndDetachKeepsTotalsWithoutUpdatingOldGauges() throws {
        let statistics = AgentStudioTraceQueueStatistics()
        let queueID = statistics.register()
        statistics.report(queueID, snapshot: .init(droppedRecordCount: 2, pendingRequestCount: 3, backlog: 3))
        let factory = OTLPRecordingMetricsFactory()
        statistics.attach(gauges: .init(factory: factory))
        #expect(statistics.hasAttachedGauges)
        let pending = try #require(
            factory.recorder(label: "agentstudio_performance_trace_queue_pending_request_count", dimensions: [])
        )
        let dropped = try #require(
            factory.recorder(label: "agentstudio_performance_trace_queue_dropped_record_count", dimensions: [])
        )
        let peak = try #require(
            factory.recorder(label: "agentstudio_performance_trace_queue_high_watermark", dimensions: [])
        )
        #expect(pending.values == [3])
        #expect(dropped.values == [2])
        #expect(peak.values == [3])
        statistics.report(queueID, snapshot: .init(droppedRecordCount: 2))
        #expect(pending.values == [3, 0])
        statistics.detach()
        #expect(!statistics.hasAttachedGauges)
        statistics.report(queueID, snapshot: .init(droppedRecordCount: 4, pendingRequestCount: 1, backlog: 1))
        statistics.retire(queueID)
        #expect(dropped.values == [2, 2])
        #expect(pending.values == [3, 0])
        #expect(statistics.snapshot() == .init(droppedRecordCount: 4, pendingRequestCount: 0, highWaterMark: 3))
    }

    @Test
    func runtimeValueCopiesShareTheStatisticsOwner() {
        let runtime = AgentStudioTraceRuntime(configuration: .from(environment: ["AGENTSTUDIO_TRACE_TAGS": "off"]))
        let copy = runtime
        #expect(runtime.queueStatistics === copy.queueStatistics)
        let first = AgentStudioTraceEventQueue(traceRuntime: runtime)
        let second = AgentStudioTraceEventQueue(traceRuntime: copy)
        first.cancel()
        second.cancel()
        #expect(runtime.queueStatistics.snapshot() == .init())
        #expect(!runtime.queueStatistics.hasAttachedGauges)
    }

}
