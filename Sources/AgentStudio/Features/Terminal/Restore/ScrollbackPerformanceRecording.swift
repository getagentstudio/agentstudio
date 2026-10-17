import AgentStudioInfrastructure
import Foundation

/// Aggregate pass cost, with no terminal content or pane/session identity.
package struct ScrollbackPassMeasurement: Equatable, Sendable {
    package let reason: ScrollbackPassReason
    package let paneCount: Int
    package let capturedBytes: Int
    package let writtenBytes: Int
    package let outcomeCounts: [ScrollbackSnapshotDisposition: Int]
    package let duration: Duration
}

package enum ScrollbackPerformanceObservation: Equatable, Sendable {
    case started(ScrollbackPassReason)
    case finished(ScrollbackPassMeasurement)
}

package protocol ScrollbackPerformanceRecording: Sendable {
    func recordScrollbackPassObservation(_ observation: ScrollbackPerformanceObservation)
}

extension AgentStudioPerformanceTraceRecorder: ScrollbackPerformanceRecording {
    package func recordScrollbackPassObservation(_ observation: ScrollbackPerformanceObservation) {
        switch observation {
        case .started(let reason):
            record(
                .scrollbackPass,
                attributes: [
                    "agentstudio.performance.scrollback.pass.phase": .string("started"),
                    "agentstudio.performance.scrollback.pass.reason": .string(reason.performanceName),
                ])
        case .finished(let measurement):
            var attributes: [String: AgentStudioTraceValue] = [
                "agentstudio.performance.scrollback.pass.phase": .string("finished"),
                "agentstudio.performance.scrollback.pass.reason": .string(measurement.reason.performanceName),
                "agentstudio.performance.scrollback.pass.pane.count": .int(measurement.paneCount),
                "agentstudio.performance.scrollback.pass.captured.bytes": .int(measurement.capturedBytes),
                "agentstudio.performance.scrollback.pass.written.bytes": .int(measurement.writtenBytes),
            ]
            // Error payloads never become labels. Distinct errno/status cases
            // are summed into the same bounded outcome kind.
            var countsByKind: [String: Int] = [:]
            for (outcome, count) in measurement.outcomeCounts {
                countsByKind[outcome.performanceKind, default: 0] += count
            }
            for (kind, count) in countsByKind {
                attributes["agentstudio.performance.scrollback.pass.outcome.\(kind).count"] = .int(count)
            }
            recordDuration(.scrollbackPass, duration: measurement.duration, attributes: attributes)
        }
    }
}

extension ScrollbackPassReason {
    fileprivate var performanceName: String {
        switch self {
        case .periodic: "periodic"
        case .quit: "quit"
        }
    }
}

extension ScrollbackSnapshotDisposition {
    fileprivate var performanceKind: String {
        switch self {
        case .written: "written"
        case .invalidUTF8: "invalid_utf8"
        case .keepPrevious: "keep_previous"
        case .unchanged: "unchanged"
        case .empty: "empty"
        case .deadlineExceeded: "deadline_exceeded"
        case .exceededCeiling: "exceeded_ceiling"
        case .launchFailed: "launch_failed"
        case .readFailed: "read_failed"
        case .exitedNonZero: "exited_nonzero"
        case .retired: "retired"
        case .cancelled: "cancelled"
        case .writeFailed: "write_failed"
        }
    }
}
