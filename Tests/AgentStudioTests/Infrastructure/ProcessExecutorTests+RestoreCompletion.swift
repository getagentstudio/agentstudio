import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioInfrastructure

extension ProcessExecutorTests {
    @Test("scoped process cost is enqueued before its caller can close the recorder")
    func scopedCostPrecedesCallerCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("process-completion-cost-\(UUIDv7.generate())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let completionOrder = ProcessCompletionOrder()
        let configuration = AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "jsonl", "AGENTSTUDIO_TRACE_DIR": directory.path,
            "AGENTSTUDIO_TRACE_NAME": "process-completion-cost", "AGENTSTUDIO_TRACE_TAGS": "performance",
        ])
        let runtime = AgentStudioTraceRuntime(
            configuration: configuration, processIdentifier: 921,
            timeUnixNano: {
                completionOrder.recordTimestamp()
                return 121
            })
        let sampled = AsyncStream.makeStream(of: Void.self)
        let recorder = AgentStudioPerformanceTraceRecorder(
            traceRuntime: runtime,
            processMemorySampleWait: {
                sampled.continuation.yield(())
                sampled.continuation.finish()
                return false
            })
        var initialSample = sampled.stream.makeAsyncIterator()
        _ = await initialSample.next()
        try await recorder.flush()
        let immediateExecutor = ProcessCompletionInlineExecutor(order: completionOrder)
        let processExecutor = makeRestoreCostExecutor(
            recorder: recorder, beforeLaunch: { completionOrder.beforeLaunch() })
        do {
            // Observe the continuation's enqueue itself, before its consumer can
            // run. The launch seam waits for the caller's initial job to suspend;
            // no resume-before-suspend optimization can hide the wrong order.
            let caller = Task(executorPreference: immediateExecutor) {
                let result = try await AgentStudioPerformanceTraceRecorder.withRestorePhaseScope(
                    .restoreOutboxImport
                ) {
                    try await processExecutor.execute(command: "true", args: [], cwd: nil, environment: nil)
                }
                try await recorder.drain()
                return result
            }
            let result = try await caller.value
            #expect(result.succeeded)
            #expect(
                completionOrder.initialJobReturned.recordedArrivals.count == 1,
                "the real native launch seam must reach the caller-suspension barrier")
            #expect(
                completionOrder.firstResumeFollowedRecord() == true,
                "the scoped cost must be recorded before the caller continuation is enqueued")
            let output = try #require(runtime.outputFileURL)
            let contents =
                FileManager.default.fileExists(atPath: output.path)
                ? try String(contentsOf: output, encoding: .utf8) : ""
            let probeRecords = contents.split(separator: "\n").filter {
                $0.contains("\"body\":\"performance.restore.outbox.import\"")
            }
            #expect(probeRecords.count == 1, "execute must enqueue exactly one scoped cost before resuming its caller")
        } catch {
            try? await recorder.drain()
            throw error
        }
    }
}

/// Observes the real continuation enqueue rather than hoping its consumer wins
/// the race against subsequent producer code. No production seam is added.
private final class ProcessCompletionInlineExecutor: TaskExecutor {
    let order: ProcessCompletionOrder
    init(order: ProcessCompletionOrder) { self.order = order }
    func enqueue(_ job: consuming ExecutorJob) {
        order.observeEnqueue()
        job.runSynchronously(on: asUnownedTaskExecutor())
        order.initialJobReturned.release()
    }
}

private final class ProcessCompletionOrder: Sendable {
    private struct State {
        var launched = false
        var timestamped = false
        var firstResumeFollowedRecord: Bool?
    }
    private let state = Mutex(State())
    let initialJobReturned = HeldStep<Void>("process caller suspended before launch")
    func beforeLaunch() {
        try? initialJobReturned.arriveBlocking(())
        state.withLock {
            $0.launched = true
            $0.timestamped = false
        }
    }
    func recordTimestamp() { state.withLock { $0.timestamped = true } }
    func observeEnqueue() {
        state.withLock { state in
            if state.launched, state.firstResumeFollowedRecord == nil {
                state.firstResumeFollowedRecord = state.timestamped
            }
        }
    }
    func firstResumeFollowedRecord() -> Bool? { state.withLock { $0.firstResumeFollowedRecord } }
}
