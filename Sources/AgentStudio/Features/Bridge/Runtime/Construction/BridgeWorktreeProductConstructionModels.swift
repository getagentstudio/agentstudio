import Foundation

package struct BridgeWorktreeFreshnessEpoch: Hashable, Sendable {
    let rawValue: UInt64
}

enum BridgeWorktreeProductKind: String, Sendable {
    case file
    case review
}

enum BridgeWorktreeProductConstructionArtifact: Sendable {
    case fileSnapshot(BridgeSharedFileSnapshotBuild)
    case reviewTemplate(BridgeSharedReviewPackageTemplate)

    var productKind: BridgeWorktreeProductKind {
        switch self {
        case .fileSnapshot:
            return .file
        case .reviewTemplate:
            return .review
        }
    }

    var retainedByteCount: Int {
        switch self {
        case .fileSnapshot(let snapshot):
            return snapshot.retainedByteCount
        case .reviewTemplate(let template):
            return template.retainedByteCount
        }
    }

    var contentLocatorCount: Int {
        switch self {
        case .fileSnapshot:
            return 0
        case .reviewTemplate(let template):
            return template.contentLocatorCount
        }
    }

    func invalidateBacking() {
        guard case .reviewTemplate(let template) = self else { return }
        template.invalidateBacking()
    }
}

enum BridgeReviewConstructionPhase: Hashable, Sendable {
    case contributionResolved
    case endpointsResolved
    case comparisonResolved
    case treeRead
    case descriptorRead
    case packageBuilt
    case sharedContentCaptured
    case artifactAcquired
    case sharedContentInstalled
}

typealias BridgeReviewConstructionProgressSink = @Sendable (BridgeReviewConstructionPhase) -> Void
typealias BridgeReviewConstructionProgressReporter = @Sendable (BridgeReviewConstructionPhase) async -> Void

struct BridgeWorktreeProductConstructionContext: Sendable {
    let key: BridgeWorktreeProductConstructionKey
    let epoch: BridgeWorktreeFreshnessEpoch
    let entryNonce: UInt64
    let reviewProgress: BridgeReviewConstructionProgressReporter

    init(
        key: BridgeWorktreeProductConstructionKey,
        epoch: BridgeWorktreeFreshnessEpoch,
        entryNonce: UInt64,
        reviewProgress: @escaping BridgeReviewConstructionProgressReporter = { _ in }
    ) {
        self.key = key
        self.epoch = epoch
        self.entryNonce = entryNonce
        self.reviewProgress = reviewProgress
    }
}

struct BridgeWorktreeProductConstructionFreshnessContext: Sendable {
    let worktree: BridgeWorktreeIdentityKey
    let epoch: BridgeWorktreeFreshnessEpoch
}

struct BridgeWorktreeProductConstructionLease: Sendable {
    let key: BridgeWorktreeProductConstructionKey
    let epoch: BridgeWorktreeFreshnessEpoch
    let entryNonce: UInt64
    let leaseNonce: UInt64
    let artifact: BridgeWorktreeProductConstructionArtifact
}

enum BridgeWorktreeProductConstructionLeaseRelease: Sendable {
    case retainedByOtherLeases
    case artifactInvalidated
    case noMatchingLease

    var requiresArtifactCleanupDrain: Bool {
        switch self {
        case .retainedByOtherLeases:
            return false
        case .artifactInvalidated, .noMatchingLease:
            return true
        }
    }
}

struct BridgeSharedFileSnapshotConsumerLease: Equatable, Sendable {
    let key: BridgeFileConstructionKey
    let epoch: BridgeWorktreeFreshnessEpoch
    let entryNonce: UInt64
    let leaseNonce: UInt64
}

struct BridgeSharedFileSnapshotCursor: Equatable, Sendable {
    let nextWindowOrdinal: Int
}

enum BridgeSharedFileSnapshotRead: Sendable {
    case window(BridgeSharedFileSnapshotWindow)
    case completed(BridgeSharedFileSnapshotBuild)
}

struct BridgeSharedFileSnapshotPublisher: Sendable {
    private let preparationSink: @Sendable (BridgeSharedFileSnapshotPreparation) async throws -> Void
    private let windowSink: @Sendable (BridgeSharedFileSnapshotWindow) async throws -> Void

    init(
        preparationSink:
            @escaping @Sendable (BridgeSharedFileSnapshotPreparation) async throws -> Void,
        windowSink: @escaping @Sendable (BridgeSharedFileSnapshotWindow) async throws -> Void
    ) {
        self.preparationSink = preparationSink
        self.windowSink = windowSink
    }

    func publishPreparation(_ preparation: BridgeSharedFileSnapshotPreparation) async throws {
        try await preparationSink(preparation)
    }

    func append(_ window: BridgeSharedFileSnapshotWindow) async throws {
        try await windowSink(window)
    }
}

typealias BridgeSharedFileSnapshotBuildOperation =
    @Sendable (
        BridgeWorktreeProductConstructionContext,
        BridgeSharedFileSnapshotPublisher
    ) async throws -> BridgeSharedFileSnapshotCompletion

enum BridgeWorktreeProductConstructionError: Error, Equatable, Sendable {
    case coordinatorClosed
    case invalidated
    case freshnessEpochMismatch
    case artifactKindMismatch
    case acquisitionModeMismatch
    case invalidFileConsumerLease
    case invalidFileSnapshotCursor
    case filePreparationReadRequired
    case preparationRequired
    case preparationAlreadyPublished
    case noncontiguousFileWindow
    case fileWindowAfterFinal
    case finalFileWindowRequired
    case fileReadAlreadyPending
    case invalidRetainedByteCount
}

enum BridgeWorktreeProductConstructionEventKind: String, Sendable {
    case buildStarted
    case consumerJoined
    case consumerCancelled
    case invalidated
    case buildReady
    case filePreparationPublished
    case fileWindowAppended
    case buildFailed
    case staleCompletionDropped
    case tombstoneCreated
    case leaseReleased
    case entryRemoved
}

package struct BridgeWorktreeProductConstructionEvent: Sendable {
    let kind: BridgeWorktreeProductConstructionEventKind
    let productKind: BridgeWorktreeProductKind
    let epoch: BridgeWorktreeFreshnessEpoch
    let entryNonce: UInt64
    let leaseNonce: UInt64?
    let worktreeHash: String
    let snapshot: BridgeWorktreeProductConstructionSnapshot
}

package typealias BridgeWorktreeProductConstructionEventSink =
    @Sendable (
        BridgeWorktreeProductConstructionEvent
    ) -> Void

struct BridgeWorktreeProductConstructionSnapshot: Sendable {
    let entryCount: Int
    let waiterCount: Int
    let leaseCount: Int
    let payloadCount: Int
    let inFlightCount: Int
    let locatorCount: Int
    let drainingTombstoneCount: Int
    let retainedArtifactByteCount: Int
}
