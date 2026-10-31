import Synchronization
import Testing

@testable import AgentStudio

/// Keeps measurement keys in private test memory; none enter the trace sink.
final class PaneContextBodyLayoutRecorder: Sendable {
    struct Snapshot: Sendable {
        var requested: [PaneContextMessageBodyMeasurement.Key] = []
        var completed: [PaneContextMessageBodyMeasurement.Key] = []

        var distinctRequests: [PaneContextMessageBodyMeasurement.Key] {
            requested.reduce(into: []) { keys, next in
                if !keys.contains(next) { keys.append(next) }
            }
        }

        func assertExactlyOnce() {
            let keys = distinctRequests
            print(
                "POPOVER_LAYOUT_KEYS", "requests", requested.count, "distinct", keys.count,
                "completed", completed.count, "widths", Set(keys.map(\.effectiveWidth)).sorted(),
                "duplicateCounts", keys.map { key in completed.filter { $0 == key }.count }.filter { $0 > 1 })
            #expect(!keys.isEmpty, "Opening must exercise actual TextKit work")
            #expect(completed.count == keys.count, "Opening layouts must equal distinct requested keys")
            for key in keys {
                #expect(
                    completed.filter { $0 == key }.count == 1,
                    "Each requested body/width/font key must be laid out exactly once")
            }
            #expect(completed.allSatisfy { keys.contains($0) }, "No TextKit layout may occur without a request")
        }
    }

    private let state = Mutex(Snapshot())

    func observe(_ event: PaneContextMessageBodyMeasurement.Observation) {
        state.withLock {
            switch event {
            case .requested(let key): $0.requested.append(key)
            case .completed(let key): $0.completed.append(key)
            }
        }
    }

    var snapshot: Snapshot { state.withLock { $0 } }
}
