import Foundation

enum BridgeReadyMethod {
    static let method = "bridge.ready"
}

enum BridgeActiveViewerMode: String, Decodable, Equatable, Sendable {
    case file
    case review
}

enum BridgeActiveViewerSourceProtocol: String, Decodable, Equatable, Sendable {
    case review
    case worktreeFile = "worktree-file"
}

struct BridgeActiveViewerSource: Decodable, Equatable, Sendable {
    let protocolId: BridgeActiveViewerSourceProtocol
    let streamId: String
    let generation: Int

    private enum CodingKeys: String, CodingKey {
        case protocolId = "protocol"
        case streamId
        case generation
    }
}

struct BridgeActiveViewerModeAcceptedSignal: Equatable, Sendable {
    let mode: BridgeActiveViewerMode
    let activeSource: BridgeActiveViewerSource
    let sequenceFloor: Int
}

struct BridgeActiveViewerModeSignalState: Equatable, Sendable {
    var sessionId: String?
    var lastSequence: Int?
    var acceptedMode: BridgeActiveViewerMode?
    var acceptedSignal: BridgeActiveViewerModeAcceptedSignal?
}

package enum BridgeReviewPackageBuildReason: String, Hashable, Sendable {
    case initialIntake = "initial_intake"
    case productResync = "product_resync"
    case filesystemRefresh = "filesystem_refresh"
}

package enum BridgePaneReviewBuildAdmissionInput: Hashable, Sendable {
    case initialIntake
    case productResync
    case explicitTarget
    case retainedPackageBuild
    case filesystemCatchUp(batchSequence: UInt64)
}

enum BridgePaneReviewComparisonEffectDisposition: Equatable, Sendable {
    case applied
    case superseded
    case rejected
}

package enum BridgePaneReviewBuildAdmissionScope: Hashable, Sendable {
    case hiddenInput(BridgePaneReviewBuildAdmissionInput)
    case pendingExplicitCommand(UUID)
    case attempt(UUID)
}

package enum BridgePaneReviewBuildAttemptOutcome: Equatable, Sendable {
    case succeeded
    case failed
    case stale
    case cancelled
    case streamReset
}

package enum BridgePanePendingExplicitReviewCommandOutcome: Equatable, Sendable {
    case completed
    case superseded
    case retired
}

package enum BridgePaneReviewPackageDeliveryFact: Equatable, Sendable {
    case deferred
    case failed
    case viewBatchSealed
}

package enum BridgePaneReviewBuildAdmissionFact: Equatable, Sendable {
    case admitted(attempt: UUID)
    case deferredHidden(input: BridgePaneReviewBuildAdmissionInput)
    case pendingExplicitCommandAwaitingPageMode(commandId: UUID)
    case pendingExplicitCommandResumptionScheduled(commandId: UUID)
    case pendingExplicitCommandResumptionPreflightRejected(commandId: UUID)
    case pendingExplicitCommandResumptionAdmissionAcquired(commandId: UUID)
    case pendingExplicitCommandResumptionAdmissionRejected(commandId: UUID)
    case explicitReviewPackageBuildStarted(commandId: UUID)
    case pendingExplicitCommandBuildStarted(commandId: UUID)
    case explicitReviewPackageDelivery(
        commandId: UUID,
        disposition: BridgePaneReviewPackageDeliveryFact
    )
    case pendingExplicitCommandEnded(
        commandId: UUID,
        outcome: BridgePanePendingExplicitReviewCommandOutcome
    )
    case attemptEnded(attempt: UUID, outcome: BridgePaneReviewBuildAttemptOutcome)
}

package typealias BridgePaneReviewBuildAdmissionFactSink =
    @Sendable (BridgePaneReviewBuildAdmissionScope, BridgePaneReviewBuildAdmissionFact) -> Void

@MainActor
extension BridgePaneController {
    func recordReviewBuildAdmissionFact(
        _ fact: BridgePaneReviewBuildAdmissionFact,
        scope: BridgePaneReviewBuildAdmissionScope
    ) {
        reviewBuildAdmissionFactSink(scope, fact)
    }
}

enum BridgeError: Error, LocalizedError, Sendable {
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .encoding(let message):
            return message
        }
    }
}
