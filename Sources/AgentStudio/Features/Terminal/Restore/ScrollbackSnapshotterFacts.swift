import AgentStudioCore
import Foundation

/// Owner-local operation facts, not EventBus cases. No captured bytes occur
/// in this vocabulary; the sink can report only dispositions and counts.
package enum ScrollbackSnapshotterScope: Hashable, Sendable {
    case scheduler
    case pass(UUID)
    case capture(paneID: PaneId, attemptID: UUID)
    case retirement(UUID)
    case quit(UUID)
}

package enum ScrollbackPassReason: Equatable, Sendable { case periodic, quit }
package enum ScrollbackPassOutcome: Equatable, Sendable {
    case completed, inventoryUnavailable, bindingsUnavailable, cancelled
}
package enum ScrollbackQuitOutcome: Equatable, Sendable { case completed, deadlineExceeded, cancelled }

package enum ScrollbackSnapshotDisposition: Hashable, Sendable {
    case written
    case invalidUTF8
    case keepPrevious
    case unchanged
    case empty
    case deadlineExceeded
    case exceededCeiling
    case launchFailed(errno: Int32)
    case readFailed
    case exitedNonZero(Int32)
    case retired
    case cancelled
    case writeFailed
}

package enum ScrollbackSnapshotterFact: Equatable, Sendable {
    case firstFrameGateWaiting
    case firstFrameGatePassed
    case scheduled
    case passStarted(ScrollbackPassReason)
    case captureAdmitted(ScrollbackPaneBinding)
    case captureJoined(ScrollbackPaneBinding)
    case passFinished(outcome: ScrollbackPassOutcome, capturedPaneCount: Int)
    case captureStarted(ScrollbackPaneBinding)
    case captureFinished(ScrollbackSnapshotDisposition)
    case retirementStarted(Set<PaneId>)
    case retirementFinished
    case quitStarted
    case quitFinished(ScrollbackQuitOutcome)
    case stopped
}
