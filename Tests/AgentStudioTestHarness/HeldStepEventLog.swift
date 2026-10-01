import Foundation
import Synchronization

/// Where a `HeldStep` records that a test started waiting for it and that the
/// work first arrived at it.
///
/// A lane's hang bound ends a stuck test process with TERM and KILL, which
/// never cancels the waiting task, so the step's own error cannot name it. The
/// runner sets `AGENTSTUDIO_HELD_STEP_LOG` for each lane and, when the bound
/// fires, reports every step instance that has a `waiting` line and no
/// `arrived` line. Lines are tab-separated, because step names contain spaces,
/// and pair by the step's process-unique instance id, so an arrival at one
/// instance can never answer a wait on another instance with the same name:
///
///     waiting<TAB><instance id><TAB><step name><TAB><test>
///     arrived<TAB><instance id><TAB><step name>
///     wait_settled<TAB><instance id><TAB><waiter id><TAB><outcome>
///
/// Every record ends with a JSON metadata field carrying CLOCK_UPTIME_RAW
/// seconds/nanos, the framework test/case IDs, and the optional waiter ID.
/// Settlements distinguish a cancelled wait from a first arrival never reached.
///
/// Each line is one `write(2)` on a descriptor opened with `O_APPEND`, so a
/// process killed mid-test loses nothing it already logged and concurrent
/// steps never interleave within a line. With the variable unset nothing is
/// written.
package struct HeldStepEventLog: Sendable {
    package static let environmentVariableName = "AGENTSTUDIO_HELD_STEP_LOG"

    /// The log the lane asked for, or no log.
    package static let environment = Self(
        path: ProcessInfo.processInfo.environment[environmentVariableName].flatMap { $0.isEmpty ? nil : $0 }
    )

    package let path: String?

    package init(path: String?) {
        self.path = path
    }

    package func recordWaiting(instanceID: UInt64, waiterID: UInt64, stepName: String, test: String) {
        TestEventLogWriter.append("waiting\t\(instanceID)\t\(stepName)\t\(test)\n", path: path, waiterID: waiterID)
    }

    func recordArrived(instanceID: UInt64, stepName: String, identity: TestEventLogIdentity?) {
        TestEventLogWriter.append("arrived\t\(instanceID)\t\(stepName)\n", path: path, identity: identity)
    }

    func recordWaitSettled(instanceID: UInt64, waiterID: UInt64, outcome: FirstArrivalSettlement) {
        TestEventLogWriter.append(
            "wait_settled\t\(instanceID)\t\(waiterID)\t\(outcome.rawValue)\n", path: path, waiterID: waiterID
        )
    }

    enum FirstArrivalSettlement: String {
        case arrived
        case cancelled
        case threw
    }
}

/// Both harness logs share one failure signal because a failed log cannot
/// reliably record its own unavailability in that same file.
package enum TestEventLogWriter {
    private static let reportedUnavailable = Mutex(false)

    package static func append(
        _ line: String, path: String?, waiterID: UInt64? = nil, identity: TestEventLogIdentity? = nil
    ) {
        guard let path else { return }
        let observation = TestEventLogObservation(identity: identity, waiterID: waiterID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let metadata = try? encoder.encode(observation),
            let metadataText = String(bytes: metadata, encoding: .utf8)
        else {
            reportUnavailable(path: path, errorNumber: EIO)
            return
        }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            reportUnavailable(path: path, errorNumber: errno)
            return
        }
        defer { close(descriptor) }
        let bytes = Array((String(line.dropLast()) + "\t" + metadataText + "\n").utf8)
        let written = bytes.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        if written != bytes.count {
            reportUnavailable(path: path, errorNumber: written < 0 ? errno : EIO)
        }
    }

    private static func reportUnavailable(path: String, errorNumber: Int32) {
        let firstFailure = reportedUnavailable.withLock { reported -> Bool in
            guard !reported else { return false }
            reported = true
            return true
        }
        guard firstFailure else { return }
        let safePath = path.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        let line = "[agentstudio-test-log] unavailable path=\(safePath) errno=\(errorNumber)\n"
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { buffer in
            write(STDERR_FILENO, buffer.baseAddress, buffer.count)
        }
    }
}
