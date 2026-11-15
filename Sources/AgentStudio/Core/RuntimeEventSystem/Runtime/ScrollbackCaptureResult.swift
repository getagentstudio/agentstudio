import Foundation

/// Only accepted raw bytes may replace a pane's previous snapshot (SR8).
package enum ScrollbackCaptureResult: Equatable, Sendable {
    case accepted(Data)
    case empty
    case deadlineExceeded
    case exceededCeiling
    case launchFailed(errno: Int32)
    case readFailed
    case exitedNonZero(Int32)

    static func classify(standardOutput: Data, exitStatus: Int32, readFailed: Bool) -> Self {
        guard !readFailed else { return .readFailed }
        guard exitStatus == 0 else { return .exitedNonZero(exitStatus) }
        return standardOutput.isEmpty ? .empty : .accepted(standardOutput)
    }
}
