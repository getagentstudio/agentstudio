import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Off-main owner for one immutable terminal activation cohort.
///
/// A fixed worker fleet performs bounded MainActor admissions. The scheduler
/// never derives terminal identity or reads mutable composition/topology state.
package actor TerminalActivationScheduler {
    private enum Lifecycle {
        case idle
        case activating
        case settled(TerminalActivationSettlement)
    }

    enum MemberExecution {
        /// Held until `installGeometryEligibility` (pre-`activate()`) or
        /// `acceptLaterGeometry` (post-quiescence) names this pane. Not a
        /// `nextQueuedCandidate()` candidate and not promotable — priority is
        /// read from `Member.descriptor.visibilityPriority` when this member
        /// is finally admitted to `.queued`.
        case waitingForGeometry
        case queued(priority: TerminalActivationVisibilityPriority, attempt: Int)
        case attaching(priority: TerminalActivationVisibilityPriority, attempt: Int)
        case terminal(TerminalActivationTerminalOutcome)
    }

    struct Member {
        let descriptor: TerminalActivationDescriptor
        let originalOrdinal: Int
        var resumeEligibility: ResumeEligibility
        var execution: MemberExecution
        /// The rank assigned by the latest applied visibility snapshot,
        /// `nil` until the first snapshot is applied to this member. Once
        /// non-nil, this member's rank is always this value, never the
        /// static initial-visible/background formula: a demoted member
        /// returns to its background rank, never back to "initial visible."
        var promotedRank: QueueRank?
    }

    private let cohort: TerminalActivationCohort
    let admissionPort: any TerminalActivationAdmissionPort
    private let releaseSignal: any TerminalActivationReleaseSignal
    private var lifecycle = Lifecycle.idle
    var membersByPaneID: [PaneId: Member]
    var eligibilityWaiter: AsyncStream<Void>.Continuation?
    private var activationWaiters: [CheckedContinuation<TerminalActivationSettlement, Never>] = []
    private var currentSimultaneousAdmissions = 0
    private var maximumSimultaneousAdmissions = 0
    private var workerCount = 0
    private var yieldCount = 0
    private var activationDeferralOutcome: StartupDeferralOutcome?
    /// The latest visibility revision this scheduler has applied. Every
    /// proposal carries it so the admission port can prove (G2) that any
    /// snapshot recorded before the proposal has already been applied here.
    /// Starts at the same zero-ordinal baseline the port starts from, so the
    /// first proposal always matches until a real observation is recorded.
    private var appliedVisibilityRevision: TerminalVisibilityRevision
    /// The complete current visible queued set from the latest applied
    /// snapshot, `nil` until the first one is applied (SPEC R3, R3
    /// remediation). `applyVisibilitySnapshot` re-ranks every currently
    /// `.queued` member against it; `admitWaitingMembers` consults it too, so
    /// a member admitted from `waitingForGeometry` after this snapshot was
    /// applied is ranked by the same observation instead of falling back to
    /// its static descriptor priority.
    private var lastAppliedVisibleQueuedTerminals: TerminalVisibleQueuedTerminals?
    /// True while a worker fleet spawned by `acceptLaterGeometry` after the
    /// original `activate()` drain went quiescent is still running. Guards
    /// against a second supplemental fleet: while this is true, or while the
    /// original `activate()` drain is still running, a newly queued member is
    /// only ever observed by the one fleet already looping.
    private var isSupplementalDrainActive = false

    package init(
        cohort: TerminalActivationCohort,
        admissionPort: any TerminalActivationAdmissionPort,
        requiresRestoreClassification: Set<PaneId> = [],
        releaseSignal: any TerminalActivationReleaseSignal = TerminalActivationReleaseGate(
            isReleased: true
        )
    ) {
        let paneIDs = cohort.input.entries.map(\.paneID)
        precondition(Set(paneIDs).count == paneIDs.count, "terminal activation cohort contains duplicate panes")

        self.cohort = cohort
        self.admissionPort = admissionPort
        self.releaseSignal = releaseSignal
        appliedVisibilityRevision = TerminalVisibilityRevision(generation: cohort.generation, ordinal: 0)
        membersByPaneID = Dictionary(
            uniqueKeysWithValues: cohort.input.entries.enumerated().map { ordinal, descriptor in
                (
                    descriptor.paneID,
                    Member(
                        descriptor: descriptor,
                        originalOrdinal: ordinal,
                        resumeEligibility: requiresRestoreClassification.contains(descriptor.paneID)
                            ? .awaitingClassification : .ready,
                        execution: .waitingForGeometry,
                        promotedRank: nil
                    )
                )
            }
        )
    }

    package func activate() async -> TerminalActivationSettlement {
        switch lifecycle {
        case .settled(let settlement):
            return settlement
        case .activating:
            return await withCheckedContinuation { continuation in
                activationWaiters.append(continuation)
            }
        case .idle:
            lifecycle = .activating
        }

        activationDeferralOutcome = await releaseSignal.waitUntilReleased()

        let maximumWorkerCount = min(
            membersByPaneID.count,
            AppPolicies.TerminalActivation.restoreMaximumConcurrentAdmissions
        )
        workerCount = maximumWorkerCount

        await drainWithWorkerFleet(count: maximumWorkerCount)

        // A worker decides it is done (`nextQueuedCandidate()` is nil) and
        // this actor turn resuming after `await withTaskGroup` above are two
        // separate turns — nothing prevents a concurrent `acceptLaterGeometry`
        // call (S9's geometry-reevaluation tail, or any other caller) from
        // requeuing a member in between. `ensureADrainObservesNewlyQueuedMembers`'s
        // `.activating` branch assumes this fleet will still observe such a
        // requeue; that assumption is only true if draining again here
        // actually happens. Checking for a queued member immediately before
        // `makeSettlement()`, with no `await` between the check and the call,
        // is what makes "no unfinished members" a fact instead of a race.
        while hasQueuedMember() || hasPendingResumeEligibility() {
            if hasQueuedMember() {
                await drainWithWorkerFleet(count: 1)
            } else {
                let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
                eligibilityWaiter = continuation
                for await _ in stream { break }
                continuation.finish()
                eligibilityWaiter = nil
            }
        }

        let settlement = makeSettlement()
        lifecycle = .settled(settlement)
        let waiters = activationWaiters
        activationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: settlement)
        }
        return settlement
    }

    package func recordedActivationDeferralOutcome() -> StartupDeferralOutcome? {
        activationDeferralOutcome
    }

    /// Single-shot: called once, before `activate()`, with the cohort-wide
    /// set of panes whose geometry is already safe. Moves exactly those
    /// still-`waitingForGeometry` members to `queued` at their descriptor's
    /// static priority and attempt 1; a pane not currently waiting (already
    /// queued, attaching, or terminal) is left untouched. Performs no
    /// scheduling itself — `activate()`'s own drain observes the move.
    /// Returns the accepted subset of `paneIDs`.
    @discardableResult
    package func installGeometryEligibility(_ paneIDs: Set<PaneId>) -> Set<PaneId> {
        admitWaitingMembers(paneIDs)
    }

    /// SPEC R5 retry: called any time after `installGeometryEligibility`,
    /// including after the original `activate()` drain has gone quiescent,
    /// with panes whose geometry has since become safe. Moves exactly those
    /// still-`waitingForGeometry` members to `queued`, then ensures exactly
    /// one drain is running to observe them — starting a new one-worker
    /// drain if the scheduler is quiescent, or relying on the drain already
    /// looping (the original `activate()` fleet, or a prior supplemental
    /// drain still in flight) to pick them up at its next claim boundary.
    /// Returns the accepted subset of `paneIDs`.
    @discardableResult
    package func acceptLaterGeometry(for paneIDs: Set<PaneId>) -> Set<PaneId> {
        let acceptedPaneIDs = admitWaitingMembers(paneIDs)
        guard !acceptedPaneIDs.isEmpty else { return acceptedPaneIDs }
        ensureADrainObservesNewlyQueuedMembers()
        return acceptedPaneIDs
    }

    /// Moves every still-`waitingForGeometry` member named in `paneIDs` to
    /// `queued` at its descriptor's static priority and attempt 1. Pure
    /// state mutation shared by `installGeometryEligibility` (pre-`activate()`)
    /// and `acceptLaterGeometry` (post-quiescence); neither starts a drain
    /// here — `acceptLaterGeometry` does so separately, only when it must.
    private func admitWaitingMembers(_ paneIDs: Set<PaneId>) -> Set<PaneId> {
        var acceptedPaneIDs: Set<PaneId> = []
        for paneID in paneIDs {
            guard var member = membersByPaneID[paneID] else { continue }
            guard case .waitingForGeometry = member.execution else { continue }
            member.execution = .queued(priority: member.descriptor.visibilityPriority, attempt: 1)
            // A visibility snapshot already applied before this member left
            // `waitingForGeometry` still governs its rank (R3 remediation):
            // without this, the member would keep its static descriptor
            // priority even though the current visible queued set already
            // named it, and the snapshot that would have corrected it is
            // equality-suppressed at the port when the visible set is
            // otherwise unchanged.
            if let terminals = lastAppliedVisibleQueuedTerminals {
                member.promotedRank = promotedRank(for: member, in: terminals)
            }
            membersByPaneID[paneID] = member
            acceptedPaneIDs.insert(paneID)
        }
        return acceptedPaneIDs
    }

    /// Starts exactly one supplemental one-worker drain when the scheduler
    /// has already gone quiescent (the original `activate()` fleet exited
    /// its task group). While `activate()`'s own drain is still in flight
    /// (`.idle`, not yet started, or `.activating`, already looping), that
    /// fleet will observe the newly queued members itself at its next
    /// `nextQueuedCandidate()` call — no second worker is ever spawned.
    private func ensureADrainObservesNewlyQueuedMembers() {
        switch lifecycle {
        case .idle, .activating:
            return
        case .settled:
            guard !isSupplementalDrainActive else { return }
            isSupplementalDrainActive = true
            Task { [weak self] in
                await self?.runWorker()
                await self?.markSupplementalDrainFinished()
            }
        }
    }

    private func markSupplementalDrainFinished() {
        isSupplementalDrainActive = false
    }

    func memberState(for paneID: PaneId) -> TerminalActivationMemberState? {
        guard let member = membersByPaneID[paneID] else { return nil }
        if isTerminalExecution(member.execution), member.resumeEligibility != .retired {
            return publicState(for: member.execution)
        }
        switch member.resumeEligibility {
        case .awaitingClassification: return .awaitingClassification
        case .awaitingResumeReadiness, .installing: return .awaitingResumeReadiness
        case .retired: return .retired
        case .ready: return publicState(for: member.execution)
        }
    }

    func diagnostics() -> TerminalActivationSchedulerDiagnostics {
        TerminalActivationSchedulerDiagnostics(
            currentSimultaneousAdmissions: currentSimultaneousAdmissions,
            maximumSimultaneousAdmissions: maximumSimultaneousAdmissions,
            workerCount: workerCount,
            yieldCount: yieldCount
        )
    }

    func cancelAndReplace(
        with replacement: WorkspaceContentMountGeneration
    ) {
        precondition(replacement != cohort.generation, "replacement activation generation must differ")

        for (paneID, var member) in membersByPaneID {
            switch member.execution {
            case .waitingForGeometry, .queued, .attaching:
                member.execution = .terminal(.cancelledReplaced(replacement: replacement))
                membersByPaneID[paneID] = member
            case .terminal:
                break
            }
        }

        eligibilityWaiter?.yield(())
        if case .idle = lifecycle {
            lifecycle = .settled(makeSettlement())
        }
    }

    package func promote(
        paneID: PaneId,
        to priority: TerminalActivationVisibilityPriority
    ) -> TerminalActivationPromotionResult {
        guard var member = membersByPaneID[paneID] else { return .paneNotFound }
        switch member.execution {
        case .queued(let currentPriority, let attempt):
            guard currentPriority != priority else { return .unchanged(priority: priority) }
            member.execution = .queued(priority: priority, attempt: attempt)
            membersByPaneID[paneID] = member
            return .promoted(from: currentPriority, to: priority)
        case .waitingForGeometry, .attaching, .terminal:
            return .memberNotQueued(state: publicState(for: member.execution))
        }
    }

    /// Proposes, claims, marks attaching, and activates one candidate at a
    /// time until no queued member remains. `AppPolicies.TerminalActivation
    /// .restoreMaximumConcurrentAdmissions == 1` means `activate()` spawns at
    /// most one worker, so `nextQueuedCandidate()`'s pure selection can never
    /// race a concurrent `markAttaching(_:)` mutation from another worker.
    private func runWorker() async {
        while let candidate = nextQueuedCandidate() {
            let proposal = TerminalAdmissionProposal(
                generation: cohort.generation,
                paneID: candidate.paneID,
                attempt: candidate.attempt,
                appliedVisibilityRevision: appliedVisibilityRevision
            )
            let outcome = await admissionPort.claimPreparedTerminal(proposal)
            switch outcome {
            case .claimed(let claim):
                // No `await` between claim receipt and marking attaching: the
                // admission counter must reflect only claims the port granted.
                markAttaching(candidate)
                let activationOutcome = await admissionPort.activateClaimedTerminal(claim)
                complete(paneID: candidate.paneID, attempt: candidate.attempt, with: activationOutcome)
                yieldCount += 1
                await Task.yield()
            case .visibilityChanged(let snapshot):
                appliedVisibilityRevision = snapshot.revision
                applyVisibilitySnapshot(snapshot.terminals)
            case .rejected(let rejection):
                resolveRejectedProposal(paneID: candidate.paneID, attempt: candidate.attempt, rejection: rejection)
            }
        }
    }

    /// Runs `count` workers to quiescence — the initial fleet size for
    /// `activate()`'s own drain, or a single worker for each retry round
    /// that catches a member `acceptLaterGeometry` requeued after the
    /// previous round decided none remained.
    private func drainWithWorkerFleet(count: Int) async {
        await withTaskGroup(of: Void.self) { taskGroup in
            for _ in 0..<count {
                taskGroup.addTask {
                    await self.runWorker()
                }
            }
        }
    }

    /// Whether any member is currently `.queued` — awaiting a claim, not yet
    /// picked up by a worker. Read synchronously immediately before
    /// `makeSettlement()`, with no intervening `await`, so the answer cannot
    /// go stale between the check and the settlement it gates.
    private func hasQueuedMember() -> Bool {
        membersByPaneID.values.contains { member in
            if case .queued = member.execution, member.resumeEligibility == .ready { return true }
            return false
        }
    }

    /// Pure selection: the highest-ranked queued member, or nil. Performs no
    /// mutation, so a caller may inspect the candidate before deciding whether
    /// a claim was actually granted.
    private func nextQueuedCandidate() -> QueuedCandidate? {
        membersByPaneID.values.compactMap { member -> QueuedCandidate? in
            guard member.resumeEligibility == .ready,
                case .queued(let priority, let attempt) = member.execution
            else { return nil }
            let rank = member.promotedRank ?? QueueRank(placement: member.descriptor.hostPlacement, priority: priority)
            return QueuedCandidate(
                paneID: member.descriptor.paneID,
                priority: priority,
                rank: rank,
                attempt: attempt,
                originalOrdinal: member.originalOrdinal
            )
        }.min { lhs, rhs in
            if lhs.rank == rhs.rank {
                return lhs.originalOrdinal < rhs.originalOrdinal
            }
            return lhs.rank < rhs.rank
        }
    }

    /// Reclassifies every still-queued member's rank from a newly observed
    /// complete current visible queued set (SPEC R3). Attaching, ready,
    /// failed, replaced, and waiting members are untouched — promotion never
    /// re-ranks them. A member absent from every tier is demoted straight to
    /// its background rank; it never falls back to an "initial visible" rank
    /// once a real observation has been applied. Promotion never alters
    /// identity, placement, frame, generation, or attempt count.
    private func applyVisibilitySnapshot(_ terminals: TerminalVisibleQueuedTerminals) {
        lastAppliedVisibleQueuedTerminals = terminals
        for (paneID, var member) in membersByPaneID {
            guard case .queued = member.execution else { continue }
            member.promotedRank = promotedRank(for: member, in: terminals)
            membersByPaneID[paneID] = member
        }
    }

    /// The tier `terminals` assigns `member`: one of the four promoted tiers
    /// if `member`'s pane appears in one, else its background rank. Shared by
    /// `applyVisibilitySnapshot` (every currently `.queued` member) and
    /// `admitWaitingMembers` (a member admitted after this snapshot was
    /// already applied) so both rank against the identical classification.
    private func promotedRank(
        for member: Member,
        in terminals: TerminalVisibleQueuedTerminals
    ) -> QueueRank {
        let paneID = member.descriptor.paneID
        if terminals.activeMainPaneIDs.contains(paneID) {
            return .promotedActiveMain
        } else if terminals.visibleMainSiblingPaneIDs.contains(paneID) {
            return .promotedMainSibling
        } else if terminals.activeDrawerPaneIDs.contains(paneID) {
            return .promotedActiveDrawer
        } else if terminals.visibleDrawerSiblingPaneIDs.contains(paneID) {
            return .promotedDrawerSibling
        } else {
            return QueueRank.backgroundRank(for: member.descriptor.hostPlacement)
        }
    }

    /// Moves a claimed candidate to `attaching` and only now counts it toward
    /// the simultaneous-admission bound. Called exactly once per granted claim.
    private func markAttaching(_ candidate: QueuedCandidate) {
        guard var member = membersByPaneID[candidate.paneID] else { return }
        member.execution = .attaching(priority: candidate.priority, attempt: candidate.attempt)
        membersByPaneID[candidate.paneID] = member
        currentSimultaneousAdmissions += 1
        maximumSimultaneousAdmissions = max(
            maximumSimultaneousAdmissions,
            currentSimultaneousAdmissions
        )
    }

    private func complete(
        paneID: PaneId,
        attempt: Int,
        with outcome: ClaimedTerminalActivationOutcome
    ) {
        precondition(currentSimultaneousAdmissions > 0, "terminal activation admission count underflow")
        currentSimultaneousAdmissions -= 1

        guard var member = membersByPaneID[paneID] else { return }
        guard
            case .attaching(let priority, let memberAttempt) = member.execution,
            memberAttempt == attempt
        else {
            return
        }

        switch outcome {
        case .attempted(let result):
            switch result {
            case .ready(let surfaceID):
                member.execution = .terminal(.ready(surfaceID: surfaceID))
            case .failed(let failure, .doNotRetry):
                member.execution = .terminal(
                    .failedTerminal(
                        failure: failure,
                        retry: .notRequested(attemptCount: attempt)
                    )
                )
            case .failed(let failure, .retry):
                if attempt == 1 {
                    member.execution = .queued(priority: priority, attempt: 2)
                } else {
                    member.execution = .terminal(
                        .failedTerminal(
                            failure: failure,
                            retry: .exhausted(attemptCount: attempt)
                        )
                    )
                }
            }
        case .rejected(let rejection):
            // Defensive: the port refused to activate a claim this scheduler
            // just received. Resolve exactly like a non-retryable failure.
            member.execution = .terminal(
                .failedTerminal(
                    failure: activationRejectionFailure(rejection),
                    retry: .notRequested(attemptCount: attempt)
                )
            )
        }
        membersByPaneID[paneID] = member
    }

    /// A `.rejected` claim outcome resolves the member exactly as `complete`
    /// resolves a `.doNotRetry` failure: no second attempt is made.
    private func resolveRejectedProposal(
        paneID: PaneId,
        attempt: Int,
        rejection: TerminalAdmissionClaimRejection
    ) {
        guard var member = membersByPaneID[paneID] else { return }
        guard
            case .queued(_, let memberAttempt) = member.execution,
            memberAttempt == attempt
        else {
            return
        }
        member.execution = .terminal(
            .failedTerminal(
                failure: claimRejectionFailure(rejection),
                retry: .notRequested(attemptCount: attempt)
            )
        )
        membersByPaneID[paneID] = member
    }

    private func claimRejectionFailure(_ rejection: TerminalAdmissionClaimRejection) -> TerminalActivationFailure {
        switch rejection {
        case .staleGeneration:
            return .attachmentRejected(code: "stale_generation")
        case .paneNotInCohort:
            return .attachmentRejected(code: "pane_not_in_cohort")
        case .trustedFrameUnavailable:
            return .attachmentRejected(code: "trusted_frame_unavailable")
        case .custodyUnavailableForClaim:
            return .attachmentRejected(code: "custody_unavailable_for_claim")
        case .retryClaimMismatch:
            return .attachmentRejected(code: "retry_claim_mismatch")
        }
    }

    private func activationRejectionFailure(
        _ rejection: ClaimedTerminalActivationRejection
    ) -> TerminalActivationFailure {
        switch rejection {
        case .claimAlreadyConsumed:
            return .attachmentRejected(code: "claim_already_consumed")
        case .claimNotIssued:
            return .attachmentRejected(code: "claim_not_issued")
        case .custodyReplaced:
            return .attachmentRejected(code: "custody_replaced")
        }
    }

    private func publicState(for execution: MemberExecution) -> TerminalActivationMemberState {
        switch execution {
        case .waitingForGeometry:
            return .waitingForGeometry
        case .queued(let priority, _):
            return .queued(priority: priority)
        case .attaching:
            return .attaching
        case .terminal(let outcome):
            switch outcome {
            case .ready(let surfaceID):
                return .ready(surfaceID: surfaceID)
            case .failedTerminal(let failure, let retry):
                return .failedTerminal(failure: failure, retry: retry)
            case .cancelledReplaced(let replacement):
                return .cancelledReplaced(replacement: replacement)
            case .waitingForGeometry:
                // Unreachable by construction: `.terminal(...)` never wraps
                // `.waitingForGeometry` — that outcome is produced only by
                // `makeSettlement()`'s separate `MemberExecution.waitingForGeometry`
                // case, never stored inside `.terminal(...)`. Exhaustiveness only.
                return .waitingForGeometry
            }
        }
    }

    /// A still-`waitingForGeometry` member is a settled outcome for this
    /// startup settlement, not a precondition failure — it simply has no
    /// geometry to admit on yet (SPEC R5, R1's deferral half). It remains
    /// live: `acceptLaterGeometry` can still requeue it, and `memberState(for:)`
    /// always reflects that live state, independent of this frozen snapshot.
    /// A still-`queued` or `attaching` member at drain quiescence remains a
    /// genuine invariant violation.
    private func makeSettlement() -> TerminalActivationSettlement {
        let outcomesByPaneID = membersByPaneID.mapValues { member -> TerminalActivationTerminalOutcome in
            switch member.execution {
            case .terminal(let outcome):
                return outcome
            case .waitingForGeometry:
                return .waitingForGeometry
            case .queued, .attaching:
                preconditionFailure("terminal activation cohort settled with unfinished members")
            }
        }
        return TerminalActivationSettlement(
            generation: cohort.generation,
            outcomesByPaneID: outcomesByPaneID
        )
    }
}
