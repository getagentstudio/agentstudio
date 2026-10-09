import AgentStudioTestHarness
import Foundation

@MainActor
private final class BridgeWebKitMilestoneResult<Value> {
    var result: Result<Value, any Error>?
}

/// Uses the runner's HeldStep ledger to name an event wait if its process bound fires.
@MainActor
func awaitBridgeWebKitMilestone<Value>(
    _ name: String,
    operation: @escaping @MainActor () async throws -> Value
) async throws -> Value {
    let milestone = HeldStep<Void>(name)
    let result = BridgeWebKitMilestoneResult<Value>()
    let observer = Task { @MainActor in
        do {
            result.result = .success(try await operation())
        } catch {
            result.result = .failure(error)
        }
        try? await milestone.arrive(())
    }
    defer { observer.cancel() }
    _ = try await milestone.firstArrival()
    milestone.release()
    await observer.value
    guard let outcome = result.result else {
        throw BridgeWebKitMilestoneHang(
            milestone: name,
            lastObservation: "operation settled without a result"
        )
    }
    return try outcome.get()
}
