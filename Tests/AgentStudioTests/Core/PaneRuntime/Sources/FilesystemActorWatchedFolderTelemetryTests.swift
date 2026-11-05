import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension FilesystemActorWatchedFolderTests {
    @Test("paced obligations remain logical debt until covering transfer or retirement", arguments: [false, true])
    func pacedObligationRemainsDebtUntilCompletionOrRetirement(retire: Bool) async throws {
        let telemetry = WatchedScanRecordingTelemetry()
        let fixture = try await WatchedFolderActorFixture(performanceTraceRecorder: telemetry.recorder)
        defer { fixture.removeTemporaryRoot() }
        do {
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
            try await retireDebtResultDrain(fixture)
            #expect(await fixture.actor.logicalDebtCount() == 0)
            try await telemetry.recorder.flush()
            await telemetry.sink.clear()
            fixture.submissionLog.reset()

            try await triggerWatchedFolderChange(fixture)
            #expect(await fixture.actor.logicalDebtCount() > 0)
            #expect(await fixture.actor.logicalDebtSnapshot().traceAttributes[pacedDebtKey] == .int(1))
            #expect(fixture.submissionLog.entries.isEmpty)
            try await telemetry.recorder.flush()
            #expect(await telemetry.sink.logicalDebtRecords().contains { $0.attributes[pacedDebtKey] == .int(1) })

            if retire {
                _ = await fixture.actor.refreshWatchedFolders([])
            } else {
                _ = try await fixture.advancePacingDeadline()
                let start = try await fixture.scanner.nextStart()
                #expect(await fixture.actor.logicalDebtSnapshot().traceAttributes[pacedDebtKey] == .int(1))
                let sequence = await fixture.actor.nextEnvelopeSequence + 1
                await fixture.scanner.finish(start, with: completeResult(entries: []))
                _ = try await fixture.consumeTopologyObservation(sequence: sequence)
                try await retireDebtResultDrain(fixture)
            }
            #expect(await fixture.actor.logicalDebtCount() == 0)
            #expect(await fixture.actor.logicalDebtSnapshot().traceAttributes[pacedDebtKey] == .int(0))
            try await telemetry.recorder.flush()
            let records = await telemetry.sink.logicalDebtRecords()
            #expect(records.last?.attributes[pacedDebtKey] == .int(0))
            let positive = try #require(records.first { $0.attributes[pacedDebtKey] == .int(1) })
            let projected = AgentStudioOTLPTraceProjection.project(positive)
            #expect(projected.attributes[pacedDebtKey] == .int(1))
            let metric = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projected))
            #expect(
                metric.samples.contains {
                    $0.label == pacedDebtKey.replacingOccurrences(of: ".", with: "_") && $0.value == 1
                })
        } catch {
            await fixture.shutdown()
            try? await telemetry.recorder.drain()
            throw error
        }
        await fixture.shutdown()
        try await telemetry.recorder.drain()
    }

    @Test("a trigger not covered by an older result remains debt after that result transfers")
    func uncoveredTriggerRetainsDebtAfterOlderResultTransfer() async throws {
        let telemetry = WatchedScanRecordingTelemetry()
        let fixture = try await WatchedFolderActorFixture(performanceTraceRecorder: telemetry.recorder)
        defer { fixture.removeTemporaryRoot() }
        var manual: Task<WatchedFolderRefreshSummary, Never>?
        do {
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
            try await retireDebtResultDrain(fixture)
            let refresh = Task { await fixture.actor.refreshWatchedFolders([fixture.watchedPath]) }
            manual = refresh
            let older = try await fixture.scanner.nextStart(producedBy: refresh)
            try await triggerWatchedFolderChange(fixture)
            let sequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(older, with: completeResult(entries: []))
            _ = try await fixture.consumeTopologyObservation(sequence: sequence)
            try await retireDebtResultDrain(fixture)
            _ = await refresh.value
            let snapshot = await fixture.actor.logicalDebtSnapshot()
            #expect(snapshot.watchedFolderActiveCount == 0)
            #expect(snapshot.logicalDebtCount == 1)
            #expect(snapshot.traceAttributes[pacedDebtKey] == .int(1))
            try await telemetry.recorder.flush()
            #expect(await telemetry.sink.logicalDebtRecords().last?.attributes[pacedDebtKey] == .int(1))

            _ = try await fixture.advancePacingDeadline()
            let covering = try await fixture.scanner.nextStart()
            let closingSequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(covering, with: completeResult(entries: []))
            _ = try await fixture.consumeTopologyObservation(sequence: closingSequence)
            try await retireDebtResultDrain(fixture)
            #expect(await fixture.actor.logicalDebtCount() == 0)
            try await telemetry.recorder.flush()
            #expect(await telemetry.sink.logicalDebtRecords().last?.attributes[pacedDebtKey] == .int(0))
        } catch {
            await fixture.shutdown()
            _ = await manual?.value
            try? await telemetry.recorder.drain()
            throw error
        }
        await fixture.shutdown()
        try await telemetry.recorder.drain()
    }

    @Test("watched scan telemetry describes exact trigger trace and completed runs through OTLP")
    func pacedTelemetryMatchesTriggerTraceAndCompletedRuns() async throws {
        let telemetry = WatchedScanRecordingTelemetry()
        let probe = try WatchedFolderScanPacingProbe()
        let fixture = try await WatchedFolderActorFixture(
            performanceTraceRecorder: telemetry.recorder, clock: probe.clock)
        defer { fixture.removeTemporaryRoot() }
        do {
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
            try await telemetry.recorder.flush()
            await telemetry.sink.clear()
            let origin = probe.clock.now
            try await triggerWatchedFolderChange(fixture)
            let firstProducer = try #require(await fixture.actor.watchedFolderScanState.pacingDeadlineTask)
            #expect(try await probe.nextSleep(producedBy: firstProducer) == origin.advanced(by: .seconds(2)))
            probe.clock.advance(to: origin.advanced(by: .seconds(1)))
            try await triggerWatchedFolderChange(fixture)
            probe.clock.advance(to: origin.advanced(by: .seconds(2)))
            #expect(try await probe.nextSleep(producedBy: firstProducer) == origin.advanced(by: .seconds(3)))
            probe.clock.advance(to: origin.advanced(by: .seconds(3)))
            await firstProducer.value
            let first = try await fixture.scanner.nextStart()

            probe.clock.advance(to: origin.advanced(by: .seconds(6)))
            try await triggerWatchedFolderChange(fixture)
            let secondProducer = try #require(await fixture.actor.watchedFolderScanState.pacingDeadlineTask)
            #expect(try await probe.nextSleep(producedBy: secondProducer) == origin.advanced(by: .seconds(8)))
            probe.clock.advance(to: origin.advanced(by: .seconds(8)))
            await secondProducer.value
            probe.clock.advance(to: origin.advanced(by: .seconds(10)))
            try await triggerWatchedFolderChange(fixture)
            let thirdProducer = try #require(await fixture.actor.watchedFolderScanState.pacingDeadlineTask)
            #expect(try await probe.nextSleep(producedBy: thirdProducer) == origin.advanced(by: .seconds(12)))
            probe.clock.advance(to: origin.advanced(by: .seconds(12)))
            await thirdProducer.value
            try await telemetry.recorder.flush()
            let beforeResults = await telemetry.sink.watchedRecords()
            #expect(beforeResults.filter { $0.body == watchedDemandBody }.count == 3)
            #expect(!beforeResults.contains { $0.body == watchedRunBody || $0.body == watchedObligationBody })

            var sequence = await fixture.actor.nextEnvelopeSequence + 1
            await fixture.scanner.finish(first, with: completeResult(entries: []))
            _ = try await fixture.consumeTopologyObservation(sequence: sequence)
            let second = try await fixture.scanner.nextStart()
            try await telemetry.recorder.flush()
            #expect(await telemetry.sink.watchedRecords().filter { $0.body == watchedRunBody }.count == 1)
            #expect(!(await telemetry.sink.watchedRecords().contains { $0.body == watchedObligationBody }))
            sequence = await fixture.actor.nextEnvelopeSequence + 1
            let measured = RepoScannerResult.completeAuthoritative(
                .init(
                    verifiedEntries: [], counts: scannerCounts(),
                    serviceMetrics: .init(
                        traversalServiceDuration: .milliseconds(5), validationServiceDuration: .milliseconds(7))))
            await fixture.scanner.finish(second, with: measured)
            _ = try await fixture.consumeTopologyObservation(sequence: sequence)
            try await telemetry.recorder.flush()
            try assertWatchedScanTrace(await telemetry.sink.watchedRecords(), first: first, second: second)
        } catch {
            await fixture.shutdown()
            try? await telemetry.recorder.drain()
            try? await probe.finish()
            throw error
        }
        await fixture.shutdown()
        try await telemetry.recorder.drain()
        try await probe.finish()
    }

    @Test(
        "an explicit covering demand is recorded once in either acceptance/result order", arguments: [false, true],
        [false, true])
    func explicitTelemetrySurvivesArrivalOrder(resultFirst: Bool, manual: Bool) async throws {
        let telemetry = WatchedScanRecordingTelemetry()
        let fixture = try await WatchedFolderActorFixture(performanceTraceRecorder: telemetry.recorder)
        defer { fixture.removeTemporaryRoot() }
        var submission: Task<Void, Never>?
        do {
            _ = try await fixture.performInitialRefresh(result: completeResult(entries: []))
            try await telemetry.recorder.flush()
            let initial = try #require(await telemetry.sink.watchedRecords().first { $0.body == watchedDemandBody })
            #expect(initial.attributes[watchedScanPrefix + "reason"] == .string("initial_add"))
            #expect(initial.attributes[watchedScanPrefix + "obligation_ordinal"] == nil)
            await telemetry.sink.clear()
            try await triggerWatchedFolderChange(fixture)
            await fixture.submissionGate.arm()
            let sourceID = FilesystemSourceID(kind: .watchedParentMembership, rootID: fixture.watchedPath.id)
            let producer = Task {
                await fixture.actor.submitWatchedFolderScan(sourceID: sourceID, cause: manual ? .manual : .fallback)
            }
            submission = producer
            _ = try await fixture.submissionGate.waitForHeldSubmission()
            let start = try await fixture.scanner.nextStart()
            let sequence = await fixture.actor.nextEnvelopeSequence + 1
            if !resultFirst {
                await fixture.submissionGate.open()
                await producer.value
            }
            await fixture.scanner.finish(start, with: completeResult(entries: []))
            _ = try await fixture.consumeTopologyObservation(sequence: sequence)
            await fixture.submissionGate.open()
            await producer.value
            try await telemetry.recorder.flush()
            let records = await telemetry.sink.watchedRecords()
            let demands = records.filter { $0.body == watchedDemandBody }
            #expect(demands.count == 1)
            let demand = try #require(demands.first)
            #expect(demand.attributes[watchedScanPrefix + "reason"] == .string(manual ? "manual" : "fallback"))
            #expect(demand.attributes[watchedScanPrefix + "obligation_wait_ms"] == .int(0))
            #expect(demand.attributes[watchedScanPrefix + "obligation_ordinal"] == .int(1))
            #expect(records.filter { $0.body == watchedRunBody }.count == 1)
            let closed = try #require(records.first { $0.body == watchedObligationBody })
            #expect(closed.attributes[watchedScanPrefix + "attributed_run_count"] == .int(0))
            #expect(closed.attributes[watchedScanPrefix + "span_ms"] == .int(0))
        } catch {
            await fixture.submissionGate.open()
            await submission?.value
            await fixture.shutdown()
            try? await telemetry.recorder.drain()
            throw error
        }
        await fixture.shutdown()
        try await telemetry.recorder.drain()
    }
}

private let watchedScanPrefix = "agentstudio.performance.filesystem.watched_scan."
private let pacedDebtKey = "agentstudio.performance.filesystem.watched_folder.paced_pending.count"
private let watchedDemandBody = "performance.filesystem.watched_scan_demand"
private let watchedRunBody = "performance.filesystem.watched_scan_run"
private let watchedObligationBody = "performance.filesystem.watched_scan_obligation"

/// Retire only the result producer after its applied fact, so its final lease resolution and debt publication
/// are joined without shutting down the actor or clearing its still-uncovered obligations.
private func retireDebtResultDrain(_ fixture: WatchedFolderActorFixture) async throws {
    let drain = try #require(await fixture.actor.watchedFolderScanState.resultDrainState.task)
    drain.cancel()
    await drain.value
    let transferred = try #require(await fixture.actor.resultLeaseConsumerObservations()?.beforeSwitch)
    #expect(transferred.outcome == .transferred)
}

private func assertWatchedScanTrace(
    _ records: [AgentStudioTraceRecord], first: ControlledActorWatchedFolderScanner.Start,
    second: ControlledActorWatchedFolderScanner.Start
) throws {
    let demands = records.filter { $0.body == watchedDemandBody }
    let runs = records.filter { $0.body == watchedRunBody }
    let closures = records.filter { $0.body == watchedObligationBody }
    try #require(demands.count == 3)
    try #require(runs.count == 2)
    try #require(closures.count == 1)
    let expectedDemands: [[String: AgentStudioTraceValue]] = [
        [
            "interval_ordinal": .int(1), "first_trigger_offset_ms": .int(0), "last_trigger_offset_ms": .int(1000),
            "folded_trigger_count": .int(2), "obligation_wait_ms": .int(3000),
        ],
        [
            "interval_ordinal": .int(2), "first_trigger_offset_ms": .int(6000), "last_trigger_offset_ms": .int(6000),
            "folded_trigger_count": .int(1), "obligation_wait_ms": .int(8000),
        ],
        [
            "interval_ordinal": .int(3), "first_trigger_offset_ms": .int(10_000),
            "last_trigger_offset_ms": .int(10_000),
            "folded_trigger_count": .int(1), "obligation_wait_ms": .int(12_000),
        ],
    ]
    for (demand, expected) in zip(demands, expectedDemands) {
        for (key, value) in expected { #expect(demand.attributes[watchedScanPrefix + key] == value) }
        #expect(demand.attributes[watchedScanPrefix + "quiet_gap_count"] == .int(0))
        #expect(demand.attributes[watchedScanPrefix + "reason"] == .string("relevant_change"))
        #expect(demand.attributes[watchedScanPrefix + "obligation_ordinal"] == .int(1))
    }
    let sources = [first, second]
    for (index, run) in runs.enumerated() {
        #expect(
            run.attributes[watchedScanPrefix + "submission_sequence"]
                == .int(Int(sources[index].request.submissionSequence)))
        #expect(
            run.attributes[watchedScanPrefix + "scan_run_generation"] == .int(Int(sources[index].scanRunGeneration)))
        #expect(run.attributes[watchedScanPrefix + "demand_generation"] == .int(index == 0 ? 2 : 4))
        #expect(run.attributes[watchedScanPrefix + "service_duration_ms"] == .int(index == 0 ? 0 : 12))
        #expect(
            demands[index == 0 ? 0 : 2].attributes[watchedScanPrefix + "submission_sequence"]
                == run.attributes[watchedScanPrefix + "submission_sequence"])
    }
    #expect(runs[0].attributes[watchedScanPrefix + "obligation_ordinal"] == nil)
    #expect(runs[1].attributes[watchedScanPrefix + "obligation_ordinal"] == .int(1))
    let closure = try #require(closures.first)
    #expect(closure.attributes[watchedScanPrefix + "phase"] == .string("closed"))
    #expect(closure.attributes[watchedScanPrefix + "span_ms"] == .int(10_000))
    #expect(closure.attributes[watchedScanPrefix + "quiet_gap_count"] == .int(2))
    #expect(closure.attributes[watchedScanPrefix + "attributed_run_count"] == .int(2))
    #expect(closure.attributes[watchedScanPrefix + "scan_run_generation"] == .int(Int(second.scanRunGeneration)))
    let expectedTag = AgentStudioTraceValue.string(WatchedFolderScanScheduler.diagnosticTag(first.request.sourceID))
    for record in records {
        #expect(record.attributes[watchedScanPrefix + "folder_tag"] == expectedTag)
        for value in record.attributes.values {
            if case .string(let text) = value {
                #expect(
                    !text.contains("/") && !text.contains("\\") && !text.contains("filesystem-actor-watched-folder"))
            }
        }
        let projected = AgentStudioOTLPTraceProjection.project(record)
        #expect(projected.body == record.body)
        for (key, value) in record.attributes { #expect(projected.attributes[key] == value) }
        let metrics = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projected))
        let labels = Set(metrics.samples.map(\.label))
        for suffix in [
            "first_trigger_offset_ms", "last_trigger_offset_ms", "quiet_gap_count", "folded_trigger_count",
            "obligation_wait_ms", "service_duration_ms", "span_ms", "attributed_run_count",
        ] {
            let key = watchedScanPrefix + suffix
            if record.attributes[key] != nil { #expect(labels.contains(key.replacingOccurrences(of: ".", with: "_"))) }
        }
        for suffix in [
            "obligation_ordinal", "interval_ordinal", "submission_sequence", "demand_generation", "scan_run_generation",
        ] {
            #expect(!labels.contains((watchedScanPrefix + suffix).replacingOccurrences(of: ".", with: "_")))
        }
    }
}

private struct WatchedScanRecordingTelemetry {
    let sink = WatchedScanRecordingSink()
    let recorder: AgentStudioPerformanceTraceRecorder
    init() {
        let sink = self.sink
        let runtime = AgentStudioTraceRuntime(
            configuration: .from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": FileManager.default.temporaryDirectory.path,
                "AGENTSTUDIO_TRACE_NAME": "watched-scan-telemetry", "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]), sinkFactory: .init(makeJSONLSink: { _ in sink }, makeOTLPSink: { _ in sink }))
        recorder = .init(traceRuntime: runtime, processMemorySampleWait: { false })
    }
}

private actor WatchedScanRecordingSink: AgentStudioTraceSink {
    private var records: [AgentStudioTraceRecord] = []
    func record(_ record: AgentStudioTraceRecord) { records.append(record) }
    func clear() { records.removeAll() }
    func watchedRecords() -> [AgentStudioTraceRecord] {
        records.filter { $0.body.hasPrefix("performance.filesystem.watched_scan_") }
    }
    func logicalDebtRecords() -> [AgentStudioTraceRecord] {
        records.filter { $0.body == "performance.filesystem.logical_debt" }
    }
    func flush() {}
    func shutdown() {}
    func diagnostics() -> AgentStudioTraceWriterDiagnostics { .empty }
}
