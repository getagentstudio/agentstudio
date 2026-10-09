import AgentStudioTestHarness
import Foundation

@MainActor
enum BridgePaneControllerEventWaits {
    /// Suspends on the controller's observation notification and returns the
    /// exact value that satisfied the caller's predicate.
    static func waitForValue<Value>(_ readValue: @escaping @MainActor () -> Value?) async throws -> Value {
        while true {
            if let value = readValue() { return value }
            let changes = FactRecorder<String, Bool>(
                vocabulary: .init(
                    describeScope: { $0 }, describeFact: { "observation changed=\($0)" }, isClosing: { _, _ in false }))
            withObservationTracking {
                _ = readValue()
            } onChange: {
                changes.append(scope: "controller observation", fact: true)
            }
            try await changes.expectNext(in: "controller observation", true)
        }
    }

    static func waitForValue<Value: Sendable>(
        _ readValue: @escaping @MainActor () -> Value?,
        milestone: String,
        lastObservation: @escaping @MainActor () -> String
    ) async throws -> Value {
        try await awaitBridgeWebKitMilestone(
            "\(milestone); last=\(lastObservation())"
        ) {
            try await waitForValue(readValue)
        }
    }
}

struct BridgeWebKitMilestoneHang: Error, CustomStringConvertible {
    let milestone: String
    let lastObservation: String

    var description: String {
        "WebKit milestone \(milestone) did not settle; last=\(lastObservation)"
    }
}
