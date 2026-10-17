import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge content shared load")
struct BridgeContentSharedLoadTests {
    @Test("abandoned registration has a distinct error while the cancelled waiter keeps cancellation")
    func abandonedRegistrationIsDistinctFromWaiterCancellation() async throws {
        let handle = makeBridgeContentHandle(
            itemId: "shared-load-item",
            role: .head,
            reviewGeneration: 7,
            contentHash: bridgeSHA256ContentHash("shared"),
            sizeBytes: 6
        )
        let content = makeContentResult(handle: handle, data: "shared")
        let gate = HeldStep<Void>("shared provider", cancellation: .holdThroughCancellation)
        let arrival = Task { try await gate.firstArrival() }
        let provider = Task<BridgeContentLoadResult, any Error> {
            defer { arrival.cancel() }
            try await gate.arrive(())
            return content
        }
        let sharedLoad = BridgeContentSharedLoad(task: provider)
        let waiter = Task { try await sharedLoad.value() }
        do {
            try await arrival.value
        } catch {
            gate.release()
            waiter.cancel()
            sharedLoad.cancel()
            let waiterOutcome = await waiter.result
            _ = await provider.result
            Issue.record("Shared provider did not arrive; waiter ended as \(waiterOutcome)")
            throw error
        }

        waiter.cancel()
        let cancelledOutcome = await waiter.result
        let successor = Task { try await sharedLoad.value() }
        gate.release()
        let successorOutcome = await successor.result
        _ = await provider.result

        #expect(throws: CancellationError.self) {
            _ = try cancelledOutcome.get()
        }
        switch successorOutcome {
        case .success:
            Issue.record("Expected abandoned shared load to reject successor registration")
        case .failure(let error):
            #expect(!(error is CancellationError))
            // Keep this test runnable against main, where the new error type
            // does not exist yet; the expected nominal name is the contract.
            #expect(String(describing: type(of: error)) == "BridgeContentSharedLoadAbandoned")
        }
    }
}
