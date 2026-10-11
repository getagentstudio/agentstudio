import AgentStudioInfrastructure
import Foundation

extension WatchedFolderScanScheduler {
    struct PendingDemand: Sendable {
        let request: WatchedFolderScanRequest
        let coverage: WatchedFolderScanDemandCoverage

        func merged(with newest: Self) -> Self {
            precondition(request.sourceID == newest.request.sourceID)
            guard coverage.registration == newest.coverage.registration else {
                return Self(request: newest.request, coverage: newest.coverage)
            }
            let highestCoverage =
                coverage.throughDemandGeneration >= newest.coverage.throughDemandGeneration
                ? coverage : newest.coverage
            return Self(request: newest.request, coverage: highestCoverage)
        }
    }

    struct QueuedNewScan: Sendable {
        let demand: PendingDemand
        let fifoOrdinal: UInt64
        let readyAt: Duration
        let startedFromDirtyFollowUp: Bool

        var request: WatchedFolderScanRequest { demand.request }
    }

    struct LogicalScan: Sendable {
        let request: WatchedFolderScanRequest
        let scanRunGeneration: UInt64
        let session: WatchedFolderScannerSessionPort
        let accumulatedQueueWaitDuration: Duration
        let quantumSelectionCount: UInt64
        let startedFromDirtyFollowUp: Bool
    }

    struct QueuedSuspendedScan: Sendable {
        let logicalScan: LogicalScan
        let fifoOrdinal: UInt64
        let readyAt: Duration
    }

    enum QueuedScan: Sendable {
        case new(QueuedNewScan)
        case suspended(QueuedSuspendedScan)

        var request: WatchedFolderScanRequest {
            switch self {
            case .new(let queued): queued.request
            case .suspended(let queued): queued.logicalScan.request
            }
        }

        var fifoOrdinal: UInt64 {
            switch self {
            case .new(let queued): queued.fifoOrdinal
            case .suspended(let queued): queued.fifoOrdinal
            }
        }
    }

    enum RunningSession: Sendable {
        case creating
        case existing(WatchedFolderScannerSessionPort)
    }

    struct RunningQuantum: Sendable {
        let request: WatchedFolderScanRequest
        let scanRunGeneration: UInt64
        let executionID: UUID
        let session: RunningSession
        let accumulatedQueueWaitDuration: Duration
        let quantumSelectionCount: UInt64
        let startedFromDirtyFollowUp: Bool
    }

    enum ValidationAdmissionDisposition: Equatable, Sendable {
        case submitting
        case cancellationRequested
    }

    struct InFlightValidationAdmission: Sendable {
        let scope: WatchedFolderScanValidationScope?
        let task: Task<Void, Never>
        var disposition: ValidationAdmissionDisposition
    }

    struct AwaitingValidation: Sendable {
        let logicalScan: LogicalScan
        let scannerRequest: RepoScannerValidationRequest
        let executorRequest: RepoDiscoveryValidationRequest
    }

    struct PendingResult: Sendable {
        let result: ScheduledWatchedFolderScanResult
        let completionOrdinal: UInt64
    }

    struct LeasedResult: Sendable {
        let pending: PendingResult
        let leaseID: WatchedFolderScanResultLeaseID
    }

    enum RootSchedulingState: Sendable {
        case queuedNew(QueuedNewScan)
        case queuedSuspended(QueuedSuspendedScan)
        case queuedSuspendedAndDirty(QueuedSuspendedScan, PendingDemand)
        case running(RunningQuantum)
        case runningAndDirty(RunningQuantum, PendingDemand)
        case awaitingValidation(AwaitingValidation)
        case awaitingValidationAndDirty(AwaitingValidation, PendingDemand)
        case pendingResult(PendingResult)
        case pendingResultAndDirty(PendingResult, PendingDemand)
        case leasedResult(LeasedResult)
        case leasedResultAndDirty(LeasedResult, PendingDemand)
    }

    struct StaleDropCounts: Sendable {
        var registration: UInt64 = 0
        var scanRun: UInt64 = 0
    }

    struct QuantumCompletion: Sendable {
        let sourceID: FilesystemSourceID
        let registration: FSEventRegistrationToken
        let scanRunGeneration: UInt64
        let executionID: UUID
        let session: WatchedFolderScannerSessionPort
        let outcome: RepoScannerQuantumOutcome
    }

    enum ResultWaiterWake: Sendable {
        case resultAvailable
        case cancelled
        case consumerUnbound
        case schedulerShutDown
    }

    struct ResultWaiter {
        let waiterID: UUID
        let consumer: WatchedFolderScanResultConsumerToken
        let continuation: CheckedContinuation<ResultWaiterWake, Never>
    }

    struct DispatchOutcomes {
        var startedSourceIDs: Set<FilesystemSourceID> = []
        var exhaustedBySourceID: [FilesystemSourceID: WatchedFolderScanSubmissionRejection] = [:]
    }

    struct StateCounts {
        var ready = 0
        var active = 0
        var awaitingValidation = 0
        var pending = 0
        var leased = 0
        var dirtyFollowUps = 0
    }

    struct ReadySelectionInspection: Equatable, Sendable {
        let selectionCount: UInt64
        let workUnitCount: UInt64
        let readyRootCount: Int
        let scheduledRootCount: Int
    }

    struct SchedulingStateStore: Sequence {
        private struct ReadyRootNode {
            var previousSourceID: FilesystemSourceID?
            var nextSourceID: FilesystemSourceID?
        }

        private var statesBySourceID: [FilesystemSourceID: RootSchedulingState] = [:]
        private var readyNodesBySourceID: [FilesystemSourceID: ReadyRootNode] = [:]
        private var firstReadySourceID: FilesystemSourceID?
        private var lastReadySourceID: FilesystemSourceID?
        private(set) var counts = StateCounts()
        private(set) var readySelectionCount: UInt64 = 0
        private(set) var readySelectionWorkUnitCount: UInt64 = 0

        subscript(sourceID: FilesystemSourceID) -> RootSchedulingState? {
            get { statesBySourceID[sourceID] }
            set { replaceState(for: sourceID, with: newValue) }
        }

        var scheduledRootCount: Int { statesBySourceID.count }

        @discardableResult
        mutating func removeValue(
            forKey sourceID: FilesystemSourceID
        ) -> RootSchedulingState? {
            let previous = statesBySourceID[sourceID]
            replaceState(for: sourceID, with: nil)
            return previous
        }

        mutating func oldestReadyScan() -> QueuedScan? {
            guard let sourceID = firstReadySourceID else { return nil }
            readySelectionCount = saturatingIncrement(readySelectionCount)
            readySelectionWorkUnitCount = saturatingIncrement(readySelectionWorkUnitCount)
            guard let state = statesBySourceID[sourceID], let queued = queuedScan(from: state) else {
                preconditionFailure("ready-root queue and scheduling state must remain synchronized")
            }
            return queued
        }

        func makeIterator() -> Dictionary<FilesystemSourceID, RootSchedulingState>.Iterator {
            statesBySourceID.makeIterator()
        }

        private mutating func replaceState(
            for sourceID: FilesystemSourceID,
            with replacement: RootSchedulingState?
        ) {
            let previous = statesBySourceID[sourceID]
            let previousWasReady = previous.map(isReady) ?? false
            let replacementIsReady = replacement.map(isReady) ?? false

            if let previous { removeCounts(for: previous) }
            if let replacement { addCounts(for: replacement) }

            switch (previousWasReady, replacementIsReady) {
            case (false, true):
                appendReadySourceID(sourceID)
            case (true, false):
                removeReadySourceID(sourceID)
            case (true, true):
                precondition(readyNodesBySourceID[sourceID] != nil)
            case (false, false):
                break
            }

            statesBySourceID[sourceID] = replacement
        }

        private mutating func appendReadySourceID(_ sourceID: FilesystemSourceID) {
            precondition(readyNodesBySourceID[sourceID] == nil)
            readyNodesBySourceID[sourceID] = ReadyRootNode(
                previousSourceID: lastReadySourceID,
                nextSourceID: nil
            )
            if let lastReadySourceID {
                readyNodesBySourceID[lastReadySourceID]?.nextSourceID = sourceID
            } else {
                firstReadySourceID = sourceID
            }
            lastReadySourceID = sourceID
        }

        private mutating func removeReadySourceID(_ sourceID: FilesystemSourceID) {
            guard let node = readyNodesBySourceID.removeValue(forKey: sourceID) else {
                preconditionFailure("ready-root removal requires queue membership")
            }
            if let previousSourceID = node.previousSourceID {
                readyNodesBySourceID[previousSourceID]?.nextSourceID = node.nextSourceID
            } else {
                firstReadySourceID = node.nextSourceID
            }
            if let nextSourceID = node.nextSourceID {
                readyNodesBySourceID[nextSourceID]?.previousSourceID = node.previousSourceID
            } else {
                lastReadySourceID = node.previousSourceID
            }
        }

        private func queuedScan(from state: RootSchedulingState) -> QueuedScan? {
            switch state {
            case .queuedNew(let queued):
                .new(queued)
            case .queuedSuspended(let queued), .queuedSuspendedAndDirty(let queued, _):
                .suspended(queued)
            default:
                nil
            }
        }

        private func isReady(_ state: RootSchedulingState) -> Bool {
            queuedScan(from: state) != nil
        }

        private mutating func addCounts(for state: RootSchedulingState) {
            adjustCounts(for: state, delta: 1)
        }

        private mutating func removeCounts(for state: RootSchedulingState) {
            adjustCounts(for: state, delta: -1)
        }

        private mutating func adjustCounts(for state: RootSchedulingState, delta: Int) {
            switch state {
            case .queuedNew, .queuedSuspended:
                counts.ready += delta
            case .queuedSuspendedAndDirty:
                counts.ready += delta
                counts.dirtyFollowUps += delta
            case .running:
                counts.active += delta
            case .runningAndDirty:
                counts.active += delta
                counts.dirtyFollowUps += delta
            case .awaitingValidation:
                counts.awaitingValidation += delta
            case .awaitingValidationAndDirty:
                counts.awaitingValidation += delta
                counts.dirtyFollowUps += delta
            case .pendingResult:
                counts.pending += delta
            case .pendingResultAndDirty:
                counts.pending += delta
                counts.dirtyFollowUps += delta
            case .leasedResult:
                counts.leased += delta
            case .leasedResultAndDirty:
                counts.leased += delta
                counts.dirtyFollowUps += delta
            }
        }

        private func saturatingIncrement(_ value: UInt64) -> UInt64 {
            let (incremented, overflow) = value.addingReportingOverflow(1)
            return overflow ? UInt64.max : incremented
        }
    }
}

enum RegistrationAdmissionResult {
    case accepted
    case rejected(WatchedFolderScanSubmissionRejection)
}
