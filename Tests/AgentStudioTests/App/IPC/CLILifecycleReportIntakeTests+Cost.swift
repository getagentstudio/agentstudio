import AgentStudioInfrastructure
import AgentStudioTestSupport
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension CLILifecycleReportIntakeTests {
    @Test("real lifecycle import and its Sessions transaction emit off-main cost slices")
    func storedEndImportRecordsOffMainSlices() async throws {
        let trace = RestoreCostTraceTestFixture()
        defer { trace.cleanup() }
        do {
            try await withPaneCLIOutboxDrainHarness(performanceTraceRecorder: trace.recorder) { harness in
                let pane = UUIDv7.generate()
                let session = UUIDv7.generate().uuidString
                try await harness.seedUnconfirmedLifecycleMain(pane: pane, session: session)
                _ = try await harness.appendLifecycle(pane: pane, session: session, event: .sessionEnd, at: 2)
                let report = await harness.drain()
                #expect(report.admittedEntryCount == 1)
                #expect(try await harness.lifecycleContext(pane: pane).currentBinding?.status == .ended)
            }
            let records = try await trace.finish()
            #expect(!records.isEmpty)
            for record in records {
                #expect(record.body == "performance.restore.outbox.import")
                #expect(record.attributes.executions == 1)
                #expect(record.attributes.mainThreadExecutions == 0)
                #expect(record.attributes.mainThreadMilliseconds == 0)
            }
        } catch {
            try? await trace.recorder.drain()
            throw error
        }
    }
}
