import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import Foundation

struct WorkspacePreparedContentMountSettlement: Equatable, Sendable {
    let generation: WorkspaceContentMountGeneration
    let terminal: TerminalActivationSettlement
    let nonterminal: NonterminalContentMountSettlement
}

struct TerminalPlaceholderPublication: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        case published
        case joinedExistingPublication
    }

    let paneIDs: [PaneId]
    let disposition: Disposition
}

/// Joins the single-scheduler terminal lane and the phase-ordered nonterminal
/// startup lane for one accepted composition generation.
@MainActor
final class WorkspacePreparedContentMountCoordinator {
    private enum Lifecycle {
        case idle
        case mounting
        case settled(WorkspacePreparedContentMountSettlement)
    }

    private let cohort: WorkspacePreparedContentMountCohort
    private let viewRegistry: ViewRegistry
    private let terminalActivationReleaseGate: TerminalActivationReleaseGate
    /// One scheduler owns the complete terminal cohort — foreground and
    /// hidden, main and drawer alike. Its private `QueueRank` reproduces the
    /// former four-phase admission order without four scheduler instances, so
    /// the whole-cohort concurrency bound (R4) can no longer be exceeded by
    /// summing several schedulers' individual bounds.
    private let terminalScheduler: TerminalActivationScheduler
    /// Held so `handleVisibilitySignals` can record the complete current
    /// visible queued set synchronously (R3, G2) instead of the retired
    /// fire-and-forget per-pane promotion task.
    private let terminalAdmissionPort: any TerminalActivationAdmissionPort
    /// Placement lookup for classifying a signaled pane into the four
    /// promotion tiers. Built once from the accepted cohort's descriptors,
    /// which never change for the life of this generation.
    private let terminalDescriptorsByPaneID: [PaneId: TerminalActivationDescriptor]
    /// Nonterminal startup keeps its existing two-phase order (main before
    /// drawer) and ledger semantics, unchanged by this slice. Hidden
    /// nonterminal panes are excluded before this array is built.
    private let nonterminalPhaseOwners: [NonterminalContentMountOwner]
    private var lifecycle = Lifecycle.idle
    private var didPublishTerminalPlaceholders = false
    private var waiters: [CheckedContinuation<WorkspacePreparedContentMountSettlement, Never>] = []
    private var deferredVisibilityIntentPaneIDs: Set<PaneId> = []
    private var deferredVisibilityIntentOrder: [PaneId] = []
    /// The sole path this coordinator has to reach
    /// `WorkspaceSurfaceCoordinator.registerTerminalPlaceholderIfNeeded(for:mode:)`,
    /// which remains the only actual placeholder writer — this closure never
    /// writes a view itself. Defaults to a no-op so existing fakes and
    /// harnesses that construct this coordinator without a real surface
    /// coordinator keep compiling unchanged; production wiring is assigned
    /// at construction in `AppDelegate+WorkspaceBoot.swift`.
    private let placeholderTransitionHandler: (Pane, TerminalStatusPlaceholderMode) -> Void
    /// SR1: decides every zmx-provider pane's restore kind (Program Design
    /// item 1), awaited inside `mount()` before the terminal lane activates.
    /// Defaults to an empty map so existing fakes and harnesses that
    /// construct this coordinator without restore wiring keep compiling
    /// unchanged; production wiring is assigned at construction in
    /// `AppDelegate+WorkspaceBoot.swift`.
    private let resolveTerminalRestoreKinds: ([TerminalActivationDescriptor]) async -> [PaneId: TerminalRestoreKind]

    init(
        cohort: WorkspacePreparedContentMountCohort,
        viewRegistry: ViewRegistry,
        terminalAdmissionPort: any TerminalActivationAdmissionPort,
        nonterminalAdmissionPort: any NonterminalContentMountAdmissionPort,
        placeholderTransitionHandler: @escaping (Pane, TerminalStatusPlaceholderMode) -> Void = { _, _ in },
        resolveTerminalRestoreKinds: @escaping ([TerminalActivationDescriptor]) async -> [PaneId: TerminalRestoreKind] =
            WorkspacePreparedContentMountCoordinator.noRestoreKindsResolved
    ) {
        // Hidden nonterminal panes stay outside the startup ledger so later
        // demand falls through to the existing steady-state content mount
        // owner. Terminals remain in the startup cohort — foreground and
        // hidden alike — and the scheduler's own rank orders them.
        let startupCohort = WorkspacePreparedContentMountCohort(
            generation: cohort.generation,
            terminalActivationInput: cohort.terminalActivationInput,
            nonterminalContentMountInput: NonterminalContentMountInput(
                entries: cohort.nonterminalContentMountInput.entries.filter { $0.visibilityPriority != .hidden }
            )
        )
        self.cohort = startupCohort
        self.viewRegistry = viewRegistry
        self.terminalAdmissionPort = terminalAdmissionPort
        self.placeholderTransitionHandler = placeholderTransitionHandler
        self.resolveTerminalRestoreKinds = resolveTerminalRestoreKinds
        terminalDescriptorsByPaneID = Dictionary(
            uniqueKeysWithValues: startupCohort.terminalActivationInput.entries.map { ($0.paneID, $0) }
        )
        let terminalActivationReleaseGate = TerminalActivationReleaseGate(isReleased: true)
        self.terminalActivationReleaseGate = terminalActivationReleaseGate
        terminalScheduler = TerminalActivationScheduler(
            cohort: TerminalActivationCohort(
                generation: startupCohort.generation,
                input: startupCohort.terminalActivationInput
            ),
            admissionPort: terminalAdmissionPort,
            releaseSignal: terminalActivationReleaseGate
        )
        nonterminalPhaseOwners = [false, true].map { selectingDrawerEntries in
            NonterminalContentMountOwner(
                generation: startupCohort.generation,
                input: NonterminalContentMountInput(
                    entries: startupCohort.nonterminalContentMountInput.entries.filter {
                        Self.isDrawerPlacement($0.hostPlacement) == selectingDrawerEntries
                    }
                ),
                admissionPort: nonterminalAdmissionPort
            )
        }
        viewRegistry.installPreparedContentMountCohort(startupCohort)
    }

    func holdTerminalActivationUntilReleased() async {
        await terminalActivationReleaseGate.hold()
    }

    func releaseTerminalActivation() async {
        await terminalActivationReleaseGate.release()
    }

    func terminalActivationDeferralOutcome() async -> StartupDeferralOutcome? {
        await terminalScheduler.recordedActivationDeferralOutcome()
    }

    /// Forwards the port's launch-time eligible pane set to the one
    /// scheduler, unlocking exactly those still-waiting members for
    /// admission. The port has already performed its own `deferredGeometry`
    /// custody bookkeeping for everything not in this set; this call only
    /// carries the eligible set into the scheduler and awaits its
    /// acknowledgement of the waiting-to-queued move. Must be called before
    /// `mount()`'s terminal lane activates, so `installGeometryEligibility`'s
    /// single-shot, pre-`activate()` contract is honored (SPEC R5, R1's
    /// deferral half).
    func installTerminalGeometryAvailability(_ eligiblePaneIDs: Set<PaneId>) async {
        _ = await terminalScheduler.installGeometryEligibility(eligiblePaneIDs)
    }

    /// SPEC R5 retry: forwards a port's later-arriving eligible pane set to
    /// the one scheduler, requeuing exactly the still-waiting members it
    /// names. Safe to call at any point after `mount()` — including long
    /// after its settlement — since the scheduler starts its own
    /// supplemental drain when it has already gone quiescent.
    func acceptTerminalGeometry(_ paneIDs: Set<PaneId>) async {
        let requeuedPaneIDs = await terminalScheduler.acceptLaterGeometry(for: paneIDs)
        for paneID in requeuedPaneIDs {
            guard let pane = terminalDescriptorsByPaneID[paneID]?.pane else { continue }
            // A pane this requeue accepted can already have been mounted or
            // failed by the time this `await` resumes — a concurrent drain
            // on the same scheduler can finish it first. Re-read live
            // custody immediately before writing so a `.preparing`
            // placeholder is never overlaid on an already-settled pane's
            // live terminal view, which nothing ever clears.
            switch viewRegistry.preparedContentMountState(for: paneID, generation: cohort.generation) {
            case .pending(owner: .terminal), .mounting(owner: .terminal):
                placeholderTransitionHandler(pane, .preparing)
            case .deferredGeometry, .completed, .pending(owner: .nonterminal), .mounting(owner: .nonterminal), nil:
                continue
            }
        }
    }

    func mount() async -> WorkspacePreparedContentMountSettlement {
        switch lifecycle {
        case .settled(let settlement):
            return settlement
        case .mounting:
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        case .idle:
            lifecycle = .mounting
        }

        // SR1: decided before the terminal lane activates, never after
        // (`terminalScheduler.activate()` below is what actually attaches).
        // This costs no extra wall-clock time in practice: that lane already
        // blocks on the launch-owned release gate until the first
        // interactive frame is published, so the probe runs inside a window
        // that was otherwise idle-waiting regardless.
        let restoreKindsByPaneID = await resolveTerminalRestoreKinds(cohort.terminalActivationInput.entries)
        terminalAdmissionPort.installRestoreKinds(restoreKindsByPaneID)

        async let terminalSettlement = terminalScheduler.activate()

        var nonterminalOutcomesByPaneID: [PaneId: NonterminalContentMountOutcome] = [:]
        for nonterminalOwner in nonterminalPhaseOwners {
            let phaseNonterminal = await nonterminalOwner.mount()
            nonterminalOutcomesByPaneID.merge(phaseNonterminal.outcomesByPaneID) { _, _ in
                preconditionFailure("nonterminal pane admitted by multiple restore phases")
            }
        }

        let settlement = WorkspacePreparedContentMountSettlement(
            generation: cohort.generation,
            terminal: await terminalSettlement,
            nonterminal: NonterminalContentMountSettlement(
                generation: cohort.generation,
                outcomesByPaneID: nonterminalOutcomesByPaneID
            )
        )
        requireCompleteSettlement(settlement)
        notifyWaitingForGeometryPlaceholders(in: settlement)
        viewRegistry.completeInitialRestore()
        lifecycle = .settled(settlement)

        let completedWaiters = waiters
        waiters.removeAll()
        for waiter in completedWaiters {
            waiter.resume(returning: settlement)
        }
        return settlement
    }

    /// Publishes the accepted restore cohort in stable order without starting
    /// terminal activation. The caller owns the concrete placeholder host.
    func publishTerminalPlaceholders(
        using publish: (TerminalActivationDescriptor) -> Void
    ) -> TerminalPlaceholderPublication {
        let descriptors = cohort.terminalActivationInput.entries
        guard !didPublishTerminalPlaceholders else {
            return TerminalPlaceholderPublication(
                paneIDs: descriptors.map(\.paneID),
                disposition: .joinedExistingPublication
            )
        }
        precondition(
            {
                if case .idle = lifecycle { return true }
                return false
            }(),
            "terminal placeholders must publish before prepared content mounting"
        )
        didPublishTerminalPlaceholders = true
        for descriptor in descriptors {
            publish(descriptor)
        }
        return TerminalPlaceholderPublication(
            paneIDs: descriptors.map(\.paneID),
            disposition: .published
        )
    }

    /// Records the complete current visible queued set synchronously, then
    /// returns which signaled panes the prepared lane still owns. Replaces
    /// the retired fire-and-forget per-pane promotion task: acknowledgement
    /// now happens inline, before this call returns, with no `Task` hop.
    func handleVisibilitySignals(for visibleQueuedSet: PreparedContentVisibleQueuedSet) -> Set<PaneId> {
        var handledPaneIDs: Set<PaneId> = []
        var queuedTerminalPaneIDs: Set<PaneId> = []
        for paneID in visibleQueuedSet.visiblePaneIDs {
            guard
                let state = viewRegistry.preparedContentMountState(
                    for: paneID,
                    generation: cohort.generation
                )
            else {
                continue
            }
            switch state {
            case .pending(owner: .terminal), .deferredGeometry(owner: .terminal):
                // A pane waiting on geometry is treated exactly like a pending
                // pane here: the prepared lane still owns it, and this signal
                // records intent and enters the current visible queued set
                // this scheduler will apply its four-tier promotion from.
                handledPaneIDs.insert(paneID)
                recordDeferredVisibilityIntent(for: paneID)
                queuedTerminalPaneIDs.insert(paneID)
            case .mounting(owner: .terminal), .pending(owner: .nonterminal), .mounting(owner: .nonterminal),
                .deferredGeometry(owner: .nonterminal):
                handledPaneIDs.insert(paneID)
                recordDeferredVisibilityIntent(for: paneID)
            case .completed(owner: _, disposition: .failed):
                handledPaneIDs.insert(paneID)
                recordDeferredVisibilityIntent(for: paneID)
            case .completed:
                handledPaneIDs.insert(paneID)
            }
        }
        // Recorded unconditionally, including an empty queued-terminal subset:
        // the port's own equality suppression already collapses repeats, and
        // discarding an empty observation here would strand a previously
        // promoted member at its stale rank instead of letting it demote.
        terminalAdmissionPort.recordCurrentVisibleQueuedTerminals(
            classifyVisibleQueuedTerminals(visibleQueuedSet, queuedTerminalPaneIDs: queuedTerminalPaneIDs)
        )
        return handledPaneIDs
    }

    /// Classifies `visibleQueuedSet` into the four promotion tiers. "Active"
    /// is membership in `visibleQueuedSet.activePaneIDs` — never list
    /// position — so a caller may pass its visible panes in any order. Only
    /// members still in `queuedTerminalPaneIDs` (pending or deferred-geometry
    /// custody) enter a tier, so an already-mounted active pane cannot cause
    /// a sibling to be misclassified as active.
    private func classifyVisibleQueuedTerminals(
        _ visibleQueuedSet: PreparedContentVisibleQueuedSet,
        queuedTerminalPaneIDs: Set<PaneId>
    ) -> TerminalVisibleQueuedTerminals {
        var activeMainPaneIDs: [PaneId] = []
        var visibleMainSiblingPaneIDs: [PaneId] = []
        var activeDrawerPaneIDs: [PaneId] = []
        var visibleDrawerSiblingPaneIDs: [PaneId] = []
        for paneID in visibleQueuedSet.visiblePaneIDs {
            guard queuedTerminalPaneIDs.contains(paneID), let descriptor = terminalDescriptorsByPaneID[paneID] else {
                continue
            }
            let isDrawer = Self.isDrawerPlacement(descriptor.hostPlacement)
            let isActive = visibleQueuedSet.activePaneIDs.contains(paneID)
            switch (isDrawer, isActive) {
            case (false, true):
                activeMainPaneIDs.append(paneID)
            case (false, false):
                visibleMainSiblingPaneIDs.append(paneID)
            case (true, true):
                activeDrawerPaneIDs.append(paneID)
            case (true, false):
                visibleDrawerSiblingPaneIDs.append(paneID)
            }
        }
        return TerminalVisibleQueuedTerminals(
            generation: cohort.generation,
            activeMainPaneIDs: activeMainPaneIDs,
            visibleMainSiblingPaneIDs: visibleMainSiblingPaneIDs,
            activeDrawerPaneIDs: activeDrawerPaneIDs,
            visibleDrawerSiblingPaneIDs: visibleDrawerSiblingPaneIDs
        )
    }

    func takeDeferredSteadyStateRepairPaneIDs() -> [PaneId] {
        guard case .settled(let settlement) = lifecycle else {
            preconditionFailure("deferred steady-state repair read before aggregate settlement")
        }
        let failedPaneIDs = failedPaneIDs(in: settlement)
        let deferredPaneIDs = deferredVisibilityIntentOrder.filter { paneID in
            guard deferredVisibilityIntentPaneIDs.contains(paneID) else { return false }
            return failedPaneIDs.contains(paneID)
        }
        deferredVisibilityIntentPaneIDs.removeAll()
        deferredVisibilityIntentOrder.removeAll()
        return deferredPaneIDs
    }

    private func failedPaneIDs(
        in settlement: WorkspacePreparedContentMountSettlement
    ) -> Set<PaneId> {
        let failedTerminalPaneIDs = settlement.terminal.outcomesByPaneID.compactMap { paneID, outcome in
            switch outcome {
            case .failedTerminal:
                return paneID
            case .ready, .cancelledReplaced, .waitingForGeometry:
                // A waiting member has no outcome yet — it is not a failure,
                // and `acceptLaterGeometry` can still requeue it in this same
                // generation and scheduler (SPEC R5).
                return nil
            }
        }
        let failedNonterminalPaneIDs = settlement.nonterminal.outcomesByPaneID.compactMap { paneID, outcome in
            switch outcome {
            case .failedNonterminal:
                return paneID
            case .mounted, .cancelledReplaced:
                return nil
            }
        }
        return Set(failedTerminalPaneIDs).union(failedNonterminalPaneIDs)
    }

    private func recordDeferredVisibilityIntent(for paneID: PaneId) {
        guard deferredVisibilityIntentPaneIDs.insert(paneID).inserted else { return }
        deferredVisibilityIntentOrder.append(paneID)
    }

    /// Requests the `.preparing -> .waitingForGeometry` placeholder
    /// transition for every member the first drain settled as waiting (SPEC
    /// R5 presentation). `acceptTerminalGeometry` requests the reverse
    /// transition on requeue; this is the only other placeholder-transition
    /// request site, and neither ever writes a view directly.
    private func notifyWaitingForGeometryPlaceholders(in settlement: WorkspacePreparedContentMountSettlement) {
        for (paneID, outcome) in settlement.terminal.outcomesByPaneID {
            guard case .waitingForGeometry = outcome, let pane = terminalDescriptorsByPaneID[paneID]?.pane else {
                continue
            }
            // The frozen settlement snapshot can already be stale by the
            // time this loop runs: a concurrent `acceptTerminalGeometry` on
            // the same scheduler can have already admitted and mounted (or
            // failed) this exact pane. Re-read live custody immediately
            // before writing so `.waitingForGeometry` is never published
            // over an already-settled pane's live terminal view.
            guard
                viewRegistry.preparedContentMountState(for: paneID, generation: cohort.generation)
                    == .deferredGeometry(owner: .terminal)
            else {
                continue
            }
            placeholderTransitionHandler(pane, .waitingForGeometry)
        }
    }

    private func requireCompleteSettlement(_ settlement: WorkspacePreparedContentMountSettlement) {
        precondition(settlement.terminal.generation == cohort.generation)
        precondition(settlement.nonterminal.generation == cohort.generation)
        precondition(
            Set(settlement.terminal.outcomesByPaneID.keys)
                == Set(cohort.terminalActivationInput.entries.map(\.paneID))
        )
        precondition(
            Set(settlement.nonterminal.outcomesByPaneID.keys)
                == Set(cohort.nonterminalContentMountInput.entries.map(\.paneID))
        )
    }

    private static func isDrawerPlacement(_ placement: TerminalHostPlacementIdentity) -> Bool {
        if case .drawer = placement { return true }
        return false
    }

    /// Default for `resolveTerminalRestoreKinds`: no computed restore kind
    /// for any pane, so `TerminalRestoreRuntime.startupCommand` falls back to
    /// today's plain attach everywhere — existing fakes and harnesses that
    /// construct this coordinator without restore wiring keep compiling
    /// unchanged.
    private static func noRestoreKindsResolved(
        for descriptors: [TerminalActivationDescriptor]
    ) async -> [PaneId: TerminalRestoreKind] {
        [:]
    }
}
