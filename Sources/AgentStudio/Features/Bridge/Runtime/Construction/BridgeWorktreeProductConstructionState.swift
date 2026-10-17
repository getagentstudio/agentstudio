import Foundation

final class BridgeConstructionCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

struct BridgeConstructionBuildIdentity: Hashable {
    let key: BridgeWorktreeProductConstructionKey
    let epoch: BridgeWorktreeFreshnessEpoch
}

enum BridgeConstructionEntryPhase {
    case building
    case ready(BridgeWorktreeProductConstructionArtifact)
    case tombstone
}

enum BridgeConstructionEntryMode {
    case completionOnly
    case progressiveFile
}

struct BridgeConstructionWaiter {
    let leaseNonce: UInt64
    let cancellationState: BridgeConstructionCancellationState
    let continuation: CheckedContinuation<BridgeWorktreeProductConstructionLease, any Error>
    let reviewProgress: BridgeReviewConstructionProgressSink?
}

struct BridgeConstructionEntry {
    let identity: BridgeConstructionBuildIdentity
    let nonce: UInt64
    let mode: BridgeConstructionEntryMode
    var phase: BridgeConstructionEntryPhase
    var isInFlight: Bool
    var waiters: [UInt64: BridgeConstructionWaiter]
    var activeLeaseNonces: Set<UInt64>
    var preparedFileLeaseNonces: Set<UInt64>
    var progressiveFileState: BridgeProgressiveFileConstructionState?
    var progressiveBuildTask: Task<Void, Never>?
    var terminalFileBuildError: (any Error)?
    var completedReviewPhases: Set<BridgeReviewConstructionPhase> = []
}
