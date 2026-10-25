import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Dispatch
import Foundation
import Testing

@testable import AgentStudioTerminal

/// Measures the actual input entry, without a native engine or clipboard access.
/// Durations are diagnostic output; correctness never depends on machine speed.
@MainActor
@Suite("Restore paste input admission benchmark", .serialized)
struct GhosttyRestoreInputBenchmarkTests {
    @Test("actual paste handler reports steady and armed admission cost")
    func pasteHandlerAdmissionBenchmark() async throws {
        try await withGhosttyActionRouterTestFixture { fixture in
            let surface = Ghostty.SurfaceView(
                managedSurfaceID: fixture.surfaceID, appCommandDispatcher: RestoreBenchmarkCommandDispatcher(),
                callbackHandling: fixture.handler)
            #expect(surface.surface == nil)
            let generation = RestoreGeneration(rawValue: 1)
            var measurements: [String: [UInt64]] = [:]
            for armed in [false, true] {
                var samples: [UInt64] = []
                for _ in 0..<200 {
                    fixture.handler.retireLocalActions(for: fixture.surfaceID)
                    surface.restorePhaseLatch = armed ? generation : nil
                    let began = DispatchTime.now().uptimeNanoseconds
                    surface.paste(nil)
                    let finished = DispatchTime.now().uptimeNanoseconds
                    samples.append(finished - began)
                    #expect(surface.restorePhaseLatch == nil)
                }
                measurements[armed ? "armed" : "steady"] = samples
            }
            let stage = ProcessInfo.processInfo.environment["R3_INPUT_BENCHMARK_STAGE"] ?? "unspecified"
            for label in ["steady", "armed"] {
                let samples = try #require(measurements[label])
                let summary = await summarizeRestoreInputMeasurements(samples)
                print(
                    "R3_INPUT_BENCHMARK stage=\(stage) handler=paste engine=absent path=\(label) "
                        + "samples=\(summary.sampleCount) median_ns=\(summary.medianNanoseconds) "
                        + "p95_ns=\(summary.p95Nanoseconds)")
            }
        }
    }

}

private struct RestoreInputMeasurementSummary: Sendable {
    let sampleCount: Int
    let medianNanoseconds: UInt64
    let p95Nanoseconds: UInt64
}

@MainActor
private final class RestoreBenchmarkCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}
    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}

@concurrent private func summarizeRestoreInputMeasurements(_ samples: [UInt64]) async -> RestoreInputMeasurementSummary
{
    let ordered = samples.sorted()
    return .init(
        sampleCount: ordered.count, medianNanoseconds: ordered[ordered.count / 2],
        p95Nanoseconds: ordered[ordered.count * 95 / 100])
}
