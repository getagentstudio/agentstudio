import Foundation

struct GoodEventDrivenWaitTest {
    /// Awaits the specific element on the stream: the loop suspends on delivery,
    /// it does not re-read a condition.
    func awaitsFirstMatchingElement(stream: AsyncStream<Int>) async -> Int? {
        for await value in stream where value > 0 {
            return value
        }
        return nil
    }

    /// Awaits a completion event through the async sequence, not a poll.
    func awaitsCompletionGate(completions: AsyncStream<Void>) async {
        for await _ in completions {
            return
        }
    }

    /// An ordinary loop over recorded values: no yield, no sleep, no clock read.
    func totalOfRecordedEvents(events: [Int]) -> Int {
        var total = 0
        for event in events {
            total += event
        }
        return total
    }

    /// A fixed `Date` is a fixture value, not a wall-clock read.
    func stampsRecordedEvents(events: [Int]) -> [Date] {
        var stamps: [Date] = []
        for _ in events {
            stamps.append(Date(timeIntervalSince1970: 0))
        }
        return stamps
    }
}
