import Foundation
import Metrics

final class OTLPRecordingMetricsFactory: MetricsFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var countersByKey: [OTLPRecordingMetricKey: OTLPRecordingCounterHandler] = [:]
    private var recordersByKey: [OTLPRecordingMetricKey: OTLPRecordingRecorderHandler] = [:]

    func makeCounter(label: String, dimensions: [(String, String)]) -> any CounterHandler {
        lock.withLock {
            let key = OTLPRecordingMetricKey(label: label, dimensions: dimensions)
            if let counter = countersByKey[key] {
                return counter
            }
            let counter = OTLPRecordingCounterHandler()
            countersByKey[key] = counter
            return counter
        }
    }

    func makeRecorder(
        label: String,
        dimensions: [(String, String)],
        aggregate: Bool
    ) -> any RecorderHandler {
        lock.withLock {
            let key = OTLPRecordingMetricKey(label: label, dimensions: dimensions)
            if let recorder = recordersByKey[key] {
                return recorder
            }
            let recorder = OTLPRecordingRecorderHandler()
            recordersByKey[key] = recorder
            return recorder
        }
    }

    func makeTimer(label: String, dimensions: [(String, String)]) -> any TimerHandler {
        OTLPRecordingTimerHandler()
    }

    func destroyCounter(_ handler: any CounterHandler) {}

    func destroyRecorder(_ handler: any RecorderHandler) {}

    func destroyTimer(_ handler: any TimerHandler) {}

    func counter(label: String, dimensions: [(String, String)]) -> OTLPRecordingCounterHandler? {
        lock.withLock {
            countersByKey[OTLPRecordingMetricKey(label: label, dimensions: dimensions)]
        }
    }

    func recorder(label: String, dimensions: [(String, String)]) -> OTLPRecordingRecorderHandler? {
        lock.withLock {
            recordersByKey[OTLPRecordingMetricKey(label: label, dimensions: dimensions)]
        }
    }
}

private struct OTLPRecordingMetricKey: Hashable {
    let label: String
    let dimensions: [(String, String)]

    func hash(into hasher: inout Hasher) {
        hasher.combine(label)
        hasher.combine(Dictionary(uniqueKeysWithValues: dimensions))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label
            && Dictionary(uniqueKeysWithValues: lhs.dimensions) == Dictionary(uniqueKeysWithValues: rhs.dimensions)
    }
}

final class OTLPRecordingCounterHandler: CounterHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var increments: [Int64] = []

    func increment(by amount: Int64) {
        lock.withLock {
            increments.append(amount)
        }
    }

    func reset() {
        lock.withLock {
            increments.removeAll()
        }
    }

    var totalValue: Int64 {
        lock.withLock {
            increments.reduce(0, +)
        }
    }
}

final class OTLPRecordingRecorderHandler: RecorderHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Double] = []

    func record(_ value: Int64) {
        record(Double(value))
    }

    func record(_ value: Double) {
        lock.withLock {
            recordedValues.append(value)
        }
    }

    var values: [Double] {
        lock.withLock {
            recordedValues
        }
    }
}

private final class OTLPRecordingTimerHandler: TimerHandler, @unchecked Sendable {
    func recordNanoseconds(_ duration: Int64) {}
}
