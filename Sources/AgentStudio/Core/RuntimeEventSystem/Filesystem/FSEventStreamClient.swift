import CoreServices
import Foundation

package struct FSEventParticipant: Equatable, Hashable, Sendable {
    package let scopeKey: String
    package let generation: UInt64
    package let volumeIdentifier: String

    package init(scopeKey: String, generation: UInt64, volumeIdentifier: String) {
        self.scopeKey = scopeKey
        self.generation = generation
        self.volumeIdentifier = volumeIdentifier
    }
}

package struct FSEventParticipantBinding: Equatable, Hashable, Sendable {
    package let worktreeId: UUID
    package let participant: FSEventParticipant

    package init(worktreeId: UUID, participant: FSEventParticipant) {
        self.worktreeId = worktreeId
        self.participant = participant
    }
}

package struct FSEventActivityBarrier: Equatable, Sendable {
    package let bindings: [FSEventParticipantBinding]
    package let deliveredEventIDByParticipant: [FSEventParticipant: UInt64]

    package init(
        bindings: [FSEventParticipantBinding],
        deliveredEventIDByParticipant: [FSEventParticipant: UInt64]
    ) {
        self.bindings = bindings
        self.deliveredEventIDByParticipant = deliveredEventIDByParticipant
    }
}

package struct FSEventActivityProcessingFenceID: Equatable, Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package enum FSEventIngressItem: Sendable {
    case batch(FSEventBatch)
    case activityObservations(FSEventActivityObservationBatch)
    case activityProcessingFence(FSEventActivityProcessingFenceID)
}

package struct FSEventObservation: Equatable, Sendable {
    package let path: String
    package let eventID: UInt64
    package let flags: UInt32

    package init(path: String, eventID: UInt64, flags: UInt32) {
        self.path = path
        self.eventID = eventID
        self.flags = flags
    }

    package var hasCoverageLoss: Bool {
        let eventFlags = FSEventStreamEventFlags(flags)
        let coverageLossFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
        )
        return eventFlags & coverageLossFlags != 0
    }

    package var isOwnEvent: Bool {
        FSEventStreamEventFlags(flags)
            & FSEventStreamEventFlags(kFSEventStreamEventFlagOwnEvent) != 0
    }
}

package struct FSEventActivityObservationBatch: Equatable, Sendable {
    package let participant: FSEventParticipant
    package let processedThroughEventID: UInt64
    package let participantWorktreeIds: Set<UUID>
    package let qualifyingWorktreeIds: Set<UUID>
    package let coverageLostWorktreeIds: Set<UUID>

    package init(
        participant: FSEventParticipant,
        processedThroughEventID: UInt64,
        participantWorktreeIds: Set<UUID>,
        qualifyingWorktreeIds: Set<UUID>,
        coverageLostWorktreeIds: Set<UUID>
    ) {
        self.participant = participant
        self.processedThroughEventID = processedThroughEventID
        self.participantWorktreeIds = participantWorktreeIds
        self.qualifyingWorktreeIds = qualifyingWorktreeIds
        self.coverageLostWorktreeIds = coverageLostWorktreeIds
    }
}

package struct FSEventActivityOverflowRecovery: Equatable, Sendable {
    package let participant: FSEventParticipant
    package let processedThroughEventID: UInt64
    package let coverageLostWorktreeIds: Set<UUID>

    package init(
        participant: FSEventParticipant,
        processedThroughEventID: UInt64,
        coverageLostWorktreeIds: Set<UUID>
    ) {
        self.participant = participant
        self.processedThroughEventID = processedThroughEventID
        self.coverageLostWorktreeIds = coverageLostWorktreeIds
    }
}

package struct FSEventBatch: Sendable {
    let worktreeId: UUID
    let paths: [String]
    let participant: FSEventParticipant?
    let observations: [FSEventObservation]
    let requiresFullGitRefresh: Bool

    package init(
        worktreeId: UUID,
        paths: [String],
        participant: FSEventParticipant? = nil,
        observations: [FSEventObservation] = [],
        requiresFullGitRefresh: Bool = false
    ) {
        self.worktreeId = worktreeId
        self.paths = paths
        self.participant = participant
        self.observations = observations
        self.requiresFullGitRefresh = requiresFullGitRefresh
    }
}

package enum FSEventStreamRegistrationUnavailableReason: Sendable, Equatable {
    case streamCreationFailed
    case streamStartFailed
    case clientShutdown
}

package enum FSEventStreamRegistrationOutcome: Sendable, Equatable {
    case observing
    case unavailable(FSEventStreamRegistrationUnavailableReason)
}

package enum FSEventStreamRuntimeTerminal: Sendable, Equatable {
    case eventsEnded
}

package struct FSEventOverflowRecovery: Equatable, Sendable {
    package let worktreeId: UUID
    package let paths: Set<String>?
    package let observations: [FSEventObservation]
    package let requiresWatchedFolderScan: Bool
    package let requiresFullGitRefresh: Bool

    package init(
        worktreeId: UUID,
        paths: Set<String>?,
        observations: [FSEventObservation] = [],
        requiresWatchedFolderScan: Bool = false,
        requiresFullGitRefresh: Bool = false
    ) {
        self.worktreeId = worktreeId
        self.paths = paths
        self.observations = observations
        self.requiresWatchedFolderScan = requiresWatchedFolderScan
        self.requiresFullGitRefresh = requiresFullGitRefresh
    }
}

package protocol FSEventStreamClient: Sendable {
    func events() -> AsyncStream<FSEventIngressItem>
    func consumeOverflowRecoveries() -> [FSEventOverflowRecovery]
    func consumeActivityOverflowRecoveries() -> [FSEventActivityOverflowRecovery]
    func consumeCoarseActivityOverflowWorktreeIds() -> Set<UUID>
    @discardableResult
    func register(
        worktreeId: UUID,
        repoId: UUID,
        rootPath: URL
    ) -> FSEventStreamRegistrationOutcome
    func unregister(worktreeId: UUID)
    func beginActivityShutdown()
    func shutdown()
    func acknowledgeActivityProcessingFence(_ fenceID: FSEventActivityProcessingFenceID)
    func captureActivityBarrier() async -> FSEventActivityBarrier?
}

extension FSEventStreamClient {
    package func beginActivityShutdown() {}

    package func consumeActivityOverflowRecoveries() -> [FSEventActivityOverflowRecovery] { [] }

    package func consumeCoarseActivityOverflowWorktreeIds() -> Set<UUID> { [] }

    package func acknowledgeActivityProcessingFence(_: FSEventActivityProcessingFenceID) {}

    package func captureActivityBarrier() async -> FSEventActivityBarrier? {
        nil
    }
}
