import AgentStudioInfrastructure
import Foundation

struct FilesystemWatchedFolderRegistration: Sendable {
    let watchedPath: WatchedPath
    let registeredRoot: RegisteredRootDescriptor
    let legacyCallbackRoutingID: UUID
}

struct FilesystemWatchedFolderInventory: Sendable {
    let repoGroups: [RepoScanner.RepoScanGroup]
}

struct WatchedFolderScanBaseline: Sendable {
    let membershipRevision: UInt64
    let checkoutPaths: [URL]
}

struct FilesystemManualWatchedFolderRefreshWait: Sendable {
    let receiptsBySourceID: [FilesystemSourceID: WatchedFolderScanDemandReceipt]
    let continuation: CheckedContinuation<WatchedFolderRefreshSummary, Never>
}

enum FilesystemManualWatchedFolderRefreshState: Sendable {
    case idle
    case running(
        id: UUID,
        task: Task<WatchedFolderRefreshSummary, Never>
    )
    case waitingForResults(
        id: UUID,
        task: Task<WatchedFolderRefreshSummary, Never>,
        wait: FilesystemManualWatchedFolderRefreshWait
    )

    var task: Task<WatchedFolderRefreshSummary, Never>? {
        switch self {
        case .idle:
            nil
        case .running(_, let task), .waitingForResults(_, let task, _):
            task
        }
    }
}

enum FilesystemWatchedFolderResultDrainState: Sendable {
    case idle
    case bindingConsumer(id: UUID, task: Task<Void, Never>)
    case running(id: UUID, task: Task<Void, Never>)

    var task: Task<Void, Never>? {
        switch self {
        case .idle:
            nil
        case .bindingConsumer(_, let task), .running(_, let task):
            task
        }
    }
}

struct FilesystemWatchedFolderScanState: Sendable {
    var pacing = WatchedFolderScanPacing()
    var pacingDeadlineTask: Task<Void, Never>?
    let resultConsumer = WatchedFolderScanResultConsumerToken.make()
    var isShuttingDown = false
    var repositoryScanBaseline = WatchedFolderScanBaseline(membershipRevision: 0, checkoutPaths: [])
    var latestObservationReceipts: [FilesystemSourceID: WatchedFolderTopologyReceipt] = [:]
    var validatedPathsBySourceID: [FilesystemSourceID: Set<URL>] = [:]
    var registrationsBySourceID: [FilesystemSourceID: FilesystemWatchedFolderRegistration] = [:]
    var sourceIDByLegacyCallbackRoutingID: [UUID: FilesystemSourceID] = [:]
    var inventoryBySourceID: [FilesystemSourceID: FilesystemWatchedFolderInventory] = [:]
    var authoritativeSourceIDs: Set<FilesystemSourceID> = []
    var latestDemandCoverageBySourceID: [FilesystemSourceID: WatchedFolderScanDemandCoverage] = [:]
    var appliedDemandCoverageBySourceID: [FilesystemSourceID: WatchedFolderScanDemandCoverage] = [:]
    var lastAppliedResultIDBySourceID: [FilesystemSourceID: WatchedFolderScanResultID] = [:]
    var nextRegistrationGenerationBySourceID: [FilesystemSourceID: UInt64] = [:]
    var manualRefreshState: FilesystemManualWatchedFolderRefreshState = .idle
    /// Canonical destination paths a creation owner is still building; no scan publishes them.
    var publicationHoldPathsByID: [WatchedFolderPublicationHoldID: String] = [:]
    /// Highest scan submission sequence reserved so far; release records it as its watermark.
    var lastReservedScanSubmissionSequence: UInt64 = 0
    /// Released holds whose scans were requested before release; those results stay filtered.
    var releasedPublicationHoldsByID: [WatchedFolderPublicationHoldID: ReleasedWatchedFolderPublicationHold] = [:]
    var resultDrainState: FilesystemWatchedFolderResultDrainState = .idle
    var fallbackTask: Task<Void, Never>?
}
