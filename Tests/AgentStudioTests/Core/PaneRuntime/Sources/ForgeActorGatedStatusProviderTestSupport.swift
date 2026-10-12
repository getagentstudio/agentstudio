import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioCore

actor GatedForgeStatusProvider: ForgeStatusProvider {
    private struct PendingCall {
        let origin: String
        let demandedBranches: Set<String>
        let step: HeldStep<Void>
        var outcome: ForgePullRequestQueryOutcome?
    }

    private struct CallCountWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var calls: [PendingCall] = []
    private var callCountWaiters: [CallCountWaiter] = []
    private var activeCallCount = 0
    private(set) var maximumActiveCallCount = 0

    var callCount: Int { calls.count }
    var origins: [String] { calls.map(\.origin) }
    var demandedBranchSets: [Set<String>] { calls.map(\.demandedBranches) }

    func pullRequests(
        origin: String,
        demandedBranches: Set<String>
    ) async -> ForgePullRequestQueryOutcome {
        activeCallCount += 1
        maximumActiveCallCount = max(maximumActiveCallCount, activeCallCount)
        defer { activeCallCount -= 1 }
        let callIndex = calls.count
        let step = HeldStep<Void>("forge provider call \(callIndex)", cancellation: .holdThroughCancellation)
        calls.append(PendingCall(origin: origin, demandedBranches: demandedBranches, step: step, outcome: nil))
        resumeSatisfiedCallCountWaiters()
        try? await step.arrive(())
        return calls[callIndex].outcome ?? .failed(message: "provider step ended without outcome")
    }

    func resolve(callAt index: Int, with outcome: ForgePullRequestQueryOutcome) {
        guard calls.indices.contains(index) else {
            Issue.record("No Forge provider call at index \(index); recorded \(calls.count)")
            return
        }
        if calls[index].outcome == nil {
            calls[index].outcome = outcome
            calls[index].step.release()
        }
    }

    func resolveIfPresent(callAt index: Int, with outcome: ForgePullRequestQueryOutcome) {
        guard calls.indices.contains(index) else { return }
        if calls[index].outcome == nil {
            calls[index].outcome = outcome
            calls[index].step.release()
        }
    }

    func waitForCallCount(_ expectedCount: Int) async -> Bool {
        if calls.count < expectedCount {
            await withCheckedContinuation { continuation in
                callCountWaiters.append(
                    CallCountWaiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                )
            }
        }
        return true
    }

    private func resumeSatisfiedCallCountWaiters() {
        var remainingWaiters: [CallCountWaiter] = []
        for waiter in callCountWaiters {
            if calls.count >= waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        callCountWaiters = remainingWaiters
    }
}
