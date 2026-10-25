import AgentStudioInfrastructure
import Testing

@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

extension PaneForegroundObserverTests {
    @Test("actual actor scheduling emits synchronous off-main slices")
    func observerSchedulingRecordsOffMainSlices() async throws {
        let trace = RestoreCostTraceTestFixture()
        defer { trace.cleanup() }
        do {
            try await withForegroundObserverFixture(performanceTraceRecorder: trace.recorder) { fixture in
                await fixture.observer.note(.bindingChanged, pane: fixture.paneId)
                try await fixture.expectScheduled()
                let look = try await fixture.expectLookStarted(sequence: 1)
                _ = try await fixture.finishLook(scope: look, agent: true)
            }
            let records = try await trace.finish()
            #expect(!records.isEmpty)
            for record in records {
                #expect(record.body == "performance.restore.foreground.schedule")
                #expect(record.attributes.mainThreadExecutions == 0)
                #expect(record.attributes.mainThreadMilliseconds == 0)
            }
        } catch {
            try? await trace.recorder.drain()
            throw error
        }
    }
}
