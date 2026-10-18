import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Total order over visibility observations within one accepted generation.
/// A counter, never a timestamp: no wall-clock value enters this contract.
package struct TerminalVisibilityRevision: Comparable, Hashable, Sendable {
    package let generation: WorkspaceContentMountGeneration
    package let ordinal: UInt64

    package init(generation: WorkspaceContentMountGeneration, ordinal: UInt64) {
        self.generation = generation
        self.ordinal = ordinal
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

/// The complete current visible queued set, classified into the four promotion
/// tiers. Never a delta. Order within each tier is the caller's stable order.
package struct TerminalVisibleQueuedTerminals: Equatable, Sendable {
    package let generation: WorkspaceContentMountGeneration
    package let activeMainPaneIDs: [PaneId]
    package let visibleMainSiblingPaneIDs: [PaneId]
    package let activeDrawerPaneIDs: [PaneId]
    package let visibleDrawerSiblingPaneIDs: [PaneId]

    package init(
        generation: WorkspaceContentMountGeneration,
        activeMainPaneIDs: [PaneId],
        visibleMainSiblingPaneIDs: [PaneId],
        activeDrawerPaneIDs: [PaneId],
        visibleDrawerSiblingPaneIDs: [PaneId]
    ) {
        self.generation = generation
        self.activeMainPaneIDs = activeMainPaneIDs
        self.visibleMainSiblingPaneIDs = visibleMainSiblingPaneIDs
        self.activeDrawerPaneIDs = activeDrawerPaneIDs
        self.visibleDrawerSiblingPaneIDs = visibleDrawerSiblingPaneIDs
    }
}

package struct TerminalVisibleQueuedSnapshot: Equatable, Sendable {
    package let revision: TerminalVisibilityRevision
    package let terminals: TerminalVisibleQueuedTerminals

    package init(revision: TerminalVisibilityRevision, terminals: TerminalVisibleQueuedTerminals) {
        self.revision = revision
        self.terminals = terminals
    }
}

package struct TerminalAdmissionProposal: Equatable, Sendable {
    package let generation: WorkspaceContentMountGeneration
    package let paneID: PaneId
    package let attempt: Int
    package let appliedVisibilityRevision: TerminalVisibilityRevision

    package init(
        generation: WorkspaceContentMountGeneration,
        paneID: PaneId,
        attempt: Int,
        appliedVisibilityRevision: TerminalVisibilityRevision
    ) {
        self.generation = generation
        self.paneID = paneID
        self.attempt = attempt
        self.appliedVisibilityRevision = appliedVisibilityRevision
    }
}

/// One-shot authority to perform exactly one mount effect. Only the admission
/// port can mint one; `claimID` is a `UUIDv7` the port records and consumes.
package struct ClaimedTerminalAdmission: Equatable, Sendable {
    package let claimID: UUID
    package let admission: TerminalActivationAdmission
    package let acknowledgedVisibilityRevision: TerminalVisibilityRevision

    package init(
        claimID: UUID,
        admission: TerminalActivationAdmission,
        acknowledgedVisibilityRevision: TerminalVisibilityRevision
    ) {
        self.claimID = claimID
        self.admission = admission
        self.acknowledgedVisibilityRevision = acknowledgedVisibilityRevision
    }
}

package enum TerminalAdmissionClaimRejection: Equatable, Sendable {
    case staleGeneration
    case paneNotInCohort
    case trustedFrameUnavailable
    case custodyUnavailableForClaim
    case retryClaimMismatch
}

package enum TerminalAdmissionClaimOutcome: Equatable, Sendable {
    case claimed(ClaimedTerminalAdmission)
    case visibilityChanged(TerminalVisibleQueuedSnapshot)
    case rejected(TerminalAdmissionClaimRejection)
}

package enum ClaimedTerminalActivationRejection: Equatable, Sendable {
    case claimAlreadyConsumed
    case claimNotIssued
    /// A newer generation's cohort replaced this pane's custody in
    /// `ViewRegistry` between the claim and this activation attempt; the
    /// issued claim is honored as revoked rather than mounted (R1).
    case custodyReplaced
}

package enum ClaimedTerminalActivationOutcome: Equatable, Sendable {
    case attempted(TerminalActivationAttemptResult)
    case rejected(ClaimedTerminalActivationRejection)
}

/// Propose/claim/activate handshake between the off-main
/// `TerminalActivationScheduler` and the MainActor admission boundary. This is
/// an actor-to-MainActor call boundary, not a new signal: no bus case, command
/// enum, or event type is added for it.
///
/// Guarantees a caller may rely on (see the program design's "MainActor
/// admission" section for the full rationale):
///
/// - G1 ordering: `TerminalVisibilityRevision` strictly increases within one
///   generation; a proposal carrying another generation's revision is
///   `.rejected(.staleGeneration)`.
/// - G2 acknowledgement: any snapshot recorded before a `claimPreparedTerminal`
///   call is returned to the caller by that call before a claim can succeed.
/// - G3 single-turn atomicity: `claimPreparedTerminal` contains no suspension
///   point; the revision comparison, the trusted-frame check, and the
///   `pending -> mounting` custody transition either all happen or none do.
/// - G4 idempotence: `claimID` is consumed on first use. A replayed claim is
///   `.rejected(.claimAlreadyConsumed)`; a claim this port never minted is
///   `.rejected(.claimNotIssued)`.
/// - G5 retry: attempt two reuses the custody already held in `mounting`
///   rather than re-claiming, and receives the same installed trusted frame.
/// - G6 duplicate and late claims: an older-revision proposal returns
///   `.visibilityChanged` and never claims; a proposal for a pane whose
///   custody is not `pending` returns `.rejected(.custodyUnavailableForClaim)`.
/// - G7 cancellation: nothing cancels an issued claim; the port settles the
///   ledger from inside the mount effect, on both the success and failure exits.
/// - G8 fail-closed frames: a pane declared frame-eligible whose installed
///   frame is missing returns `.rejected(.trustedFrameUnavailable)` before any
///   surface effect.
@MainActor
package protocol TerminalActivationAdmissionPort: AnyObject, Sendable {
    /// Replaces the latest-state visibility snapshot. Contains no `await`.
    /// Returns the existing revision unchanged when `terminals` equals the
    /// currently recorded set, so repeated equal observations mint no revision.
    @discardableResult
    func recordCurrentVisibleQueuedTerminals(
        _ terminals: TerminalVisibleQueuedTerminals
    ) -> TerminalVisibilityRevision

    /// Installs this generation's restore-kind map (SR1; Program Design item
    /// 1). `mount()` calls this once, before the terminal lane activates, so
    /// every claim minted afterward carries its pane's decided kind. Contains
    /// no `await`. The default (below) is a no-op, so fakes and harnesses
    /// that never wire restore decisions keep compiling unchanged.
    func installRestoreKinds(_ restoreKindsByPaneID: [PaneId: TerminalRestoreKind])

    /// Compare-and-claim. Contains no `await`, so the revision comparison and
    /// the `ViewRegistry` custody transition occur in one MainActor turn.
    func claimPreparedTerminal(
        _ proposal: TerminalAdmissionProposal
    ) -> TerminalAdmissionClaimOutcome

    /// Performs the one mount effect authorized by `claim` and consumes it.
    func activateClaimedTerminal(
        _ claim: ClaimedTerminalAdmission
    ) async -> ClaimedTerminalActivationOutcome
}

@MainActor
extension TerminalActivationAdmissionPort {
    package func installRestoreKinds(_ restoreKindsByPaneID: [PaneId: TerminalRestoreKind]) {}
}
