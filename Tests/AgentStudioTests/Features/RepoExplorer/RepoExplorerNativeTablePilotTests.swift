import Dispatch
import Foundation
import Testing

@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

@MainActor
@Suite("Repo Explorer native table pilot", .serialized)
struct RepoExplorerNativeTablePilotTests {
    @Test("fixed production pilot passes exact transaction and scale policy")
    func fixedProductionPilotPasses() async {
        let result = await RepoExplorerNativeTablePilot.run(performanceTraceRecorder: nil)
        #expect(result.policyID == "sidebar-native-table-pilot")
        #expect(result.policyVersion == 1)
        #expect(result.scaleCount == 2)
        #expect(result.livenessProjectionCount == 2)
        #expect(result.drainedScaleCount == 2)
        #expect(result.templatePairCount == 2)
        #expect(result.warmupTransactionCountPerScale == 20)
        #expect(result.measuredTransactionCountPerScale == 200)
        #expect(result.baselineMeasurementCount == 200)
        #expect(result.doubledMeasurementCount == 200)
        #expect(result.exactness)
        #expect(result.completed)
    }

    @Test("paired pilot alternates scale order to cancel block timing drift")
    func pairedPilotAlternatesScaleOrder() {
        #expect(
            RepoExplorerNativeTablePilot.pairedScaleOrder(transactionIndex: 0)
                == [.baseline, .doubled]
        )
        #expect(
            RepoExplorerNativeTablePilot.pairedScaleOrder(transactionIndex: 1)
                == [.doubled, .baseline]
        )
    }

    @Test("pilot replay measures mixed membership and displaced survivors")
    func pilotReplayMeasuresCorrectedMembershipPath() async {
        let sourceSnapshot = nativePlanSnapshot((0..<40).map { "row-\($0)" })
        let source = nativePlanContent(sourceSnapshot)
        let scenarioResult = await PilotReplayScenario.prepare(source: source)
        guard case .success(let scenario) = scenarioResult else {
            Issue.record("Expected pilot replay preparation")
            return
        }
        let baseline = nativePlanBaseline(snapshot: sourceSnapshot, revision: 1)
        let candidateResult = scenario.templates.forward.instantiate(
            baseline: baseline,
            candidateID: RepoExplorerMaterializationCandidateID(rawValue: 1),
            requestGeneration: 11,
            visibleGeneration: 11
        )
        guard case .success(let candidate) = candidateResult else {
            Issue.record("Expected pilot template instantiation")
            return
        }
        guard case .changed(let changed) = candidate.nativeUpdatePlan.kind,
            case .contentToContent(.membership(let membership)) = changed.presentation
        else {
            Issue.record("Expected a mixed membership pilot transaction")
            return
        }

        #expect(membership.removeRowsInOldSpace.count > 2)
        #expect(membership.insertRowsInNewSpace.count > 2)
        #expect(membership.movesFromOldToNewSpace.isEmpty)
    }

    @Test("injected deadline latches timeout and drains cooperative projection before return")
    func injectedDeadlineDrainsBeforeReturningFailure() async {
        let clock = TestPushClock()
        let gate = PilotBlockingProjectGate()
        async let pendingResult = RepoExplorerNativeTablePilot.run(
            performanceTraceRecorder: nil,
            clock: clock,
            project: { _ throws(CancellationError) in
                try gate.holdThenCancel()
            }
        )
        await gate.waitUntilStarted()
        await clock.waitForPendingSleepCount(atLeast: 1)

        clock.advance(by: .seconds(30))
        gate.release()
        let result = await pendingResult

        #expect(result.failureReason == .completionTimeout)
        #expect(!result.passed)
        #expect(!result.completed)
        #expect(result.livenessProjectionCount == 1)
        #expect(result.drainedScaleCount == 1)
        #expect(result.templatePairCount == 0)
        #expect(result.baselineMeasurementCount == 0)
        #expect(result.doubledMeasurementCount == 0)
    }
}

private final class PilotBlockingProjectGate: Sendable {
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    init() {
        (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func holdThenCancel() throws(CancellationError) -> RepoExplorerProjectionResult {
        startedContinuation.yield()
        releaseSemaphore.wait()
        throw CancellationError()
    }

    func waitUntilStarted() async {
        for await _ in started { return }
    }

    func release() {
        releaseSemaphore.signal()
        startedContinuation.finish()
    }
}
