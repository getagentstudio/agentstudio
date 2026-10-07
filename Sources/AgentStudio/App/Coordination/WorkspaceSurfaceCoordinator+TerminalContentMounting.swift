import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import AppKit
import Foundation

struct MountedTerminalContent {
    let view: TerminalPaneMountView
    let surfaceID: UUID
}

/// A6 (advisor review 2026-10-01; PD rev 21 item 5, Lead decision: push,
/// not pull): one warm/unverified pane's post-attach recreation check,
/// registered at mount time by `beginPostAttachRecreationCheckIfNeeded` and
/// started later by `receivePostAttachFirstRender(paneID:)` once the pane's
/// first render arrives. Carries exactly what `resolveRecreationVerdictOffMain`
/// needs, since the check itself no longer starts at registration time.
/// `Sendable` so it can cross into the `Task { @MainActor in ... }`
/// `receivePostAttachFirstRender` starts, matching `TerminalRestoreKindResolver
/// .ZmxPaneCapture`'s own precedent for a capture struct crossing an async
/// boundary.
struct PendingPostAttachRecreationCheck: Sendable {
    let sessionID: ZmxSessionID
    let baselineIdentity: Data?
    let observeDerivationExecutionContext: @Sendable () -> Void
}

enum TopologyIndependentTerminalMountFailure {
    case trustedInitialFrameUnavailable
    case startupPreparationFailed
    case surfaceCreationFailed
    case surfaceAttachmentFailed
}

enum TopologyIndependentTerminalMountResult {
    case mounted(MountedTerminalContent)
    case failed(TopologyIndependentTerminalMountFailure)
}

@MainActor
extension WorkspaceSurfaceCoordinator: PreparedTerminalMountHandling {
    /// Mount a terminal selected by a steady-state user action.
    ///
    /// Steady-state creation may enrich the terminal from current repository
    /// topology. Prepared startup activation uses the topology-independent
    /// sibling below instead.
    ///
    /// `authority` is a compile-time witness the caller must already hold
    /// (from `ViewRegistry.terminalSurfaceCreationAuthority(for:generation:)`);
    /// there is no default value, so a call site that skipped the custody
    /// question does not build.
    @discardableResult
    func mountCurrentTerminalContent(
        pane: Pane,
        initialFrame: NSRect? = nil,
        treatAsRestoredSessionStart: Bool = false,
        authority: TerminalSurfaceCreationAuthority
    ) -> NSView? {
        guard case .terminal = pane.content else {
            preconditionFailure("nonterminal pane entered the terminal content owner")
        }
        viewRegistry.ensureSlot(for: pane.id)

        let mountedView: NSView?
        if let worktreeID = pane.worktreeId,
            let repoID = pane.repoId,
            let worktree = store.repositoryTopologyAtom.worktree(worktreeID),
            let repo = store.repositoryTopologyAtom.repo(repoID)
        {
            mountedView = createView(
                for: pane,
                worktree: worktree,
                repo: repo,
                initialFrame: initialFrame,
                treatAsRestoredSessionStart: treatAsRestoredSessionStart
            )
        } else if let parentPaneID = pane.parentPaneId,
            let parentPane = store.paneAtom.pane(parentPaneID),
            let worktreeID = parentPane.worktreeId,
            let repoID = parentPane.repoId,
            let worktree = store.repositoryTopologyAtom.worktree(worktreeID),
            let repo = store.repositoryTopologyAtom.repo(repoID)
        {
            mountedView = createView(
                for: pane,
                worktree: worktree,
                repo: repo,
                initialFrame: initialFrame,
                treatAsRestoredSessionStart: treatAsRestoredSessionStart
            )
        } else {
            switch createTopologyIndependentTerminalView(
                for: pane,
                initialFrame: initialFrame,
                treatAsRestoredSessionStart: treatAsRestoredSessionStart,
                authority: authority
            ) {
            case .mounted(let mountedContent):
                mountedView = mountedContent.view
            case .failed:
                mountedView = nil
            }
        }
        guard let mountedView else { return nil }
        registerPaneFilesystemContextIfNeeded(for: pane)
        return mountedView
    }

    /// Mount a terminal from accepted composition without consulting repository
    /// topology or canonical atoms for identity, launch, or content selection.
    ///
    /// `authority` is a compile-time witness only. `PreparedTerminalMountAdmissionPort`
    /// mints and passes `.prepared(claim)` here after its own successful
    /// `pending -> mounting` claim; there is no default value.
    @discardableResult
    func mountPreparedTerminalContent(
        admission: TerminalActivationAdmission,
        initialFrame: NSRect?,
        authority: TerminalSurfaceCreationAuthority
    ) async -> TerminalActivationAttemptResult {
        let pane = admission.descriptor.pane
        guard case .terminal = pane.content else {
            preconditionFailure("nonterminal pane entered prepared terminal activation")
        }
        if pane.provider == .zmx, initialFrame == nil {
            return .failed(
                failure: .surfaceCreationFailed(code: "trusted_initial_frame_unavailable"),
                retry: .doNotRetry
            )
        }

        // SR6b (Program Design item 13): a cold pane arms its restore phase
        // and awaits the acknowledgment before its surface is ever created —
        // never an unarmed cold surface. Warm, unverified and nil kinds skip
        // this entirely; they never suspend here.
        var armedRestoreGeneration: RestoreGeneration?
        var coldStartObserver: ColdStartObserver?
        var coldStartPlan: TerminalColdRestorePlan?
        if case .cold(let plan) = admission.restoreKind {
            let generation = allocateRestoreGeneration()
            let acknowledgment = await Ghostty.ActionRouter.armRestorePhase(
                paneID: pane.id,
                restoreGeneration: generation
            )
            guard acknowledgment == .armed else {
                return .failed(
                    failure: .surfaceCreationFailed(code: "restore_phase_unarmed"),
                    retry: .doNotRetry
                )
            }
            armedRestoreGeneration = generation

            // Program Design item 3: never a cold surface with no pending
            // startup-window observer either. Registered before the surface
            // (and the attach command that could exit fast) exists, so a
            // `showChildExited` racing registration is never missed.
            let observer = ColdStartObserver()
            Ghostty.ActionRouter.registerColdStartAttachExitObserver(paneID: pane.id, observer: observer)
            coldStartObserver = observer
            coldStartPlan = plan
        }

        viewRegistry.ensureSlot(for: pane.id)
        switch createTopologyIndependentTerminalView(
            for: pane,
            initialFrame: initialFrame,
            treatAsRestoredSessionStart: true,
            authority: authority,
            restoreKind: admission.restoreKind,
            armedRestoreGeneration: armedRestoreGeneration
        ) {
        case .mounted(let mountedContent):
            if let coldStartObserver, let coldStartPlan {
                beginObservingColdStart(paneID: pane.id, plan: coldStartPlan, observer: coldStartObserver)
            } else {
                beginPostAttachRecreationCheckIfNeeded(pane: pane, restoreKind: admission.restoreKind)
            }
            return .ready(surfaceID: mountedContent.surfaceID)
        case .failed(.surfaceAttachmentFailed):
            if coldStartObserver != nil {
                Ghostty.ActionRouter.unregisterColdStartAttachExitObserver(paneID: pane.id)
            }
            return .failed(
                failure: .surfaceAttachmentFailed(code: "prepared_surface_attachment_failed"),
                retry: .retry
            )
        case .failed:
            if coldStartObserver != nil {
                Ghostty.ActionRouter.unregisterColdStartAttachExitObserver(paneID: pane.id)
            }
            return .failed(
                failure: .surfaceCreationFailed(code: "prepared_mount_failed"),
                retry: .retry
            )
        }
    }

    /// Program Design item 4 ("Staggered starts"): the existing single-worker
    /// activation drain (`TerminalActivationScheduler`,
    /// `restoreMaximumConcurrentAdmissions == 1`) already starts cold panes
    /// one at a time, visible first — a separate start slot would only
    /// stall every other queued pane behind a blocked cold one, since that
    /// worker cannot skip a candidate and come back to it. A dedicated start
    /// limit is added only if a future measurement shows it's needed.
    /// Runs detached from `mountPreparedTerminalContent`'s own return so a
    /// slow or pending window never delays activation settlement. Owned by
    /// `coldStartObservationTasksByPaneID` so retirement and coordinator
    /// teardown can cancel it, and a test can await its outcome fact instead
    /// of idling.
    /// Not `private`: a dedicated test suite calls this directly with a
    /// scripted `ColdStartObserverSyscalls` to prove the task-ownership and
    /// fact-sink wiring without needing surface creation to succeed (see
    /// `WorkspaceSurfaceCoordinatorColdStartObservationTests`).
    func beginObservingColdStart(
        paneID: UUID,
        plan: TerminalColdRestorePlan,
        observer: ColdStartObserver
    ) {
        let observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome: ColdStartOutcome
            if let bootID = try? await WorkspaceUndoJournalClock.current().bootID {
                let socketPath = plan.zmxDirectory.appending(path: plan.sessionID.rawValue).path
                outcome = await observer.observeColdStart(
                    zmxDirectory: plan.zmxDirectory,
                    socketPath: socketPath,
                    bootID: bootID,
                    attemptID: plan.attemptID
                )
            } else {
                outcome = .unobservable(.identityUnverifiable)
            }
            Ghostty.ActionRouter.unregisterColdStartAttachExitObserver(paneID: paneID)
            self.coldStartObservationTasksByPaneID.removeValue(forKey: paneID)
            self.handleColdStartOutcome(outcome, paneID: paneID)
        }
        coldStartObservationTasksByPaneID[paneID] = observationTask
    }

    /// SR5: the specific failure reason still needs the existing
    /// overlay-owner wiring (Program Design item 3's "existing placeholder
    /// and overlay owner"); `.unobservable` never reaches the person at all
    /// ("the reason goes to telemetry only" — `RestoreTrace.log` here is
    /// this restore code path's own established local-diagnostic channel,
    /// gated behind `AGENTSTUDIO_RESTORE_TRACE`, not OTLP). The fact sink
    /// runs after the task above already removed itself from the dictionary
    /// (`docs/specs/2026-09-28-typed-fact-test-harness`) — no suspension
    /// between the outcome settling and a test observing it.
    private func handleColdStartOutcome(_ outcome: ColdStartOutcome, paneID: UUID) {
        switch outcome {
        case .handedOff:
            RestoreTrace.log("coldStart handedOff pane=\(paneID)")
        case .failed(let failure):
            RestoreTrace.log("coldStart failed pane=\(paneID) failure=\(failure)")
            surfaceManager.reportColdRestoreFailure(paneID: paneID, failure: failure)
        case .unobservable(let reason):
            RestoreTrace.log("coldStart unobservable pane=\(paneID) reason=\(reason)")
        }
        coldStartObservationFactSink?(paneID, outcome)
    }

    /// SR2a; Program Design item 5: "For warm and unverified panes, one
    /// off-main observe after the attach settles is compared by identity
    /// with the warm baseline... A different identity means zmx recreated
    /// the session ... a missing baseline or a failed observation means
    /// 'couldn't check.'" Cold panes are excluded: they run their own
    /// startup-window observer instead (`beginObservingColdStart`), and a
    /// steady-state mount (`restoreKind == nil`) is outside restore
    /// entirely. Detection only — no UI; Program Design item 5's own stop
    /// ("presenting a notice over a live warm surface needs a new UI
    /// mechanism") and `InboxNotificationRouter`'s retirement both still
    /// apply. Owned by `postAttachRecreationCheckTasksByPaneID` so
    /// retirement and coordinator teardown can cancel it, mirroring
    /// `beginObservingColdStart`'s task-ownership shape.
    ///
    /// A6 (advisor review 2026-10-01; PD rev 21 item 5, Lead decision: push,
    /// not pull): registers this pane for its check instead of starting it
    /// at native-mount completion, and the check only starts when
    /// `receivePostAttachFirstRender(paneID:)` is notified of the pane's
    /// first render (`TerminalActivityRouter`'s existing `.firstRender`
    /// outcome arm). A pane that retires, exits or unmounts before that
    /// notification is removed in `retirePanesPermanently` instead,
    /// recording `.uncheckable(.paneUnavailableBeforeFirstRender)` without
    /// ever probing.
    ///
    /// R2-3 (Lead decision 2026-10-02): first render is not attach
    /// completion -- Ghostty's renderer emits it unconditionally on its
    /// first frame, independent of whether the PTY has delivered any byte
    /// (traced and confirmed against the pinned vendor source). Attach
    /// completion itself is not observable through any existing contract
    /// (no zmx attached-client query, no Ghostty PTY event, and the
    /// handoff-token check can't distinguish "this attach created the
    /// session" from "a still-alive session's leader never carried our
    /// token" for a session that was already alive at check time). The
    /// comparison below is still honest about this: see
    /// `PaneRecreationCheckOutcome.matchedAtFirstRender`'s own doc comment.
    ///
    /// Not `private`: a dedicated test suite calls this directly with a
    /// scripted `ZmxSessionRestoreProbing` to prove the comparison and
    /// task-ownership wiring without a real zmx daemon (see
    /// `PostAttachRecreationCheckWiringTests`).
    func beginPostAttachRecreationCheckIfNeeded(
        pane: Pane,
        restoreKind: TerminalRestoreKind?,
        observeDerivationExecutionContext: @escaping @Sendable () -> Void = {}
    ) {
        let baselineIdentity: Data?
        switch restoreKind {
        case .warm(let identity, _):
            baselineIdentity = identity
        case .unverified:
            baselineIdentity = nil
        case .cold, nil:
            return
        }
        guard let sessionID = pane.terminalState?.zmxSessionID else { return }
        guard postAttachRecreationProbe != nil else { return }
        pendingPostAttachRecreationChecksByPaneID[pane.id] = PendingPostAttachRecreationCheck(
            sessionID: sessionID,
            baselineIdentity: baselineIdentity,
            observeDerivationExecutionContext: observeDerivationExecutionContext
        )
    }

    /// Closes a still-pending warm/unverified check when Ghostty reports the
    /// attach child exited. The Process Exited view remains mounted; only
    /// the check tied to its not-yet-rendered mount is removed.
    func receivePostAttachChildExited(paneID: UUID) {
        closePendingPostAttachRecreationCheck(paneID: paneID)
    }

    /// Shared one-disposition close for child exit and ordinary view teardown.
    func closePendingPostAttachRecreationCheck(paneID: UUID) {
        guard pendingPostAttachRecreationChecksByPaneID.removeValue(forKey: paneID) != nil else { return }
        postAttachRecreationCheckFactSink?(paneID, .uncheckable(.paneUnavailableBeforeFirstRender))
    }

    /// A6 (Lead decision, push design): called by `TerminalActivityRouter`'s
    /// injected `onFirstRender` callback -- a synchronous set-lookup plus a
    /// task start, no new actor hop (both types are `@MainActor`). A pane
    /// not registered here (never mounted warm/unverified, already
    /// checked, or already retired through `retirePanesPermanently`) is
    /// ignored.
    func receivePostAttachFirstRender(paneID: UUID) {
        guard let pending = pendingPostAttachRecreationChecksByPaneID.removeValue(forKey: paneID) else { return }
        guard let probe = postAttachRecreationProbe else { return }
        // A1 (advisor review 2026-10-01): the comparison itself
        // (`PaneRecreationChecker.checkForRecreation`) is pure -- it needs
        // no actor, only `probe.observeSessionIdentity`'s own I/O does.
        // `probe` and `pending` are captured by value (both `Sendable`)
        // before this task, not read through `self` inside it, so the
        // off-main body never touches MainActor state; only the
        // completion step (removing this task from
        // `postAttachRecreationCheckTasksByPaneID` and firing the fact
        // sink) hops back to `self` on MainActor.
        let checkTask = Task { @MainActor [weak self] in
            let outcome = await Self.resolveRecreationVerdictOffMain(
                probe: probe, sessionID: pending.sessionID, baselineIdentity: pending.baselineIdentity,
                observeDerivationExecutionContext: pending.observeDerivationExecutionContext)
            guard let self else { return }
            self.postAttachRecreationCheckTasksByPaneID.removeValue(forKey: paneID)
            self.postAttachRecreationCheckFactSink?(paneID, outcome)
        }
        postAttachRecreationCheckTasksByPaneID[paneID] = checkTask
    }

    /// A1: off-main derivation for `beginPostAttachRecreationCheckIfNeeded`
    /// — the observe I/O and the pure comparison both run here, away from
    /// MainActor. `@concurrent nonisolated static` so it carries no actor
    /// affinity of its own; the caller still decides where to resume
    /// (`Task { @MainActor in await Self.resolveRecreationVerdictOffMain(...) }`
    /// hops back only for the completion step).
    ///
    /// `observeDerivationExecutionContext` (test technique amendment, Lead
    /// 2026-10-01): same seam as `TerminalRestoreKindResolver`'s own —
    /// a no-op in production, called right before the pure comparison so a
    /// test can record a structural "not on MainActor" fact instead of
    /// racing this call against other MainActor work.
    ///
    /// A6: captures *why* a thrown observation couldn't check (instead of
    /// `try?`'s silent `nil`), without changing `PaneRecreationChecker`
    /// .checkForRecreation`'s own pure, reason-free comparison. A thrown
    /// observation takes priority over a merely-missing baseline when a
    /// `.couldNotCheck` comparison could honestly point at either --
    /// something actually failed, which is the more actionable fact.
    @concurrent nonisolated private static func resolveRecreationVerdictOffMain(
        probe: any ZmxSessionRestoreProbing,
        sessionID: ZmxSessionID,
        baselineIdentity: Data?,
        observeDerivationExecutionContext: @Sendable () -> Void = {}
    ) async -> PaneRecreationCheckOutcome {
        let observedIdentity: Data?
        var observationFailureReason: PaneRecreationUncheckableReason?
        do {
            observedIdentity = try await probe.observeSessionIdentity(sessionID)
        } catch let failure as ZmxSessionControlFailure {
            observedIdentity = nil
            observationFailureReason = .observationFailed(failure)
        } catch {
            observedIdentity = nil
            observationFailureReason = .observationFailedUnrecognized
        }
        observeDerivationExecutionContext()
        let comparison = PaneRecreationChecker.checkForRecreation(
            baselineIdentity: baselineIdentity,
            observedIdentity: observedIdentity
        )
        let outcome: PaneRecreationCheckOutcome
        switch comparison {
        case .unchanged:
            outcome = .matchedAtFirstRender
        case .recreated:
            outcome = .recreated
        case .couldNotCheck:
            outcome = .uncheckable(observationFailureReason ?? .missingBaseline)
        }
        // SR2a: telemetry only, scrubbing raw ids -- this local trace line
        // is this restore code path's own established diagnostic channel
        // (matching `handleColdStartOutcome` above), gated behind
        // `AGENTSTUDIO_RESTORE_TRACE`, not OTLP.
        RestoreTrace.log("postAttachRecreationCheck result=\(outcome)")
        return outcome
    }
}
