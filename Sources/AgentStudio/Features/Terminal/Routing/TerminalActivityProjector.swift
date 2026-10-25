import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

struct TerminalActivityProjectionContext: Sendable, Equatable {
    let isAttended: Bool
    let isAgentClassified: Bool
    let outputBurstThreshold: Int
}

struct TerminalActivityAggregateInput: Sendable, Equatable {
    let aggregate: TerminalScrollbarActivityAggregate
    let latestState: ScrollbarState
    let context: TerminalActivityProjectionContext
}

enum TerminalActivityOrderedControl: Sendable, Equatable {
    case contextChanged(TerminalActivityProjectionContext)
    case observed
    case semanticSignal
    case commandFinished
    case surfaceClosed
    /// SR6b, the surface route: the cold `GhosttySurfaceView` latch recorded
    /// person input under `TerminalLocalActionAccumulator`'s lock, which
    /// detached the pre-input aggregate ahead of this control (Program
    /// Design item 13). Gating on `restorePhaseByPane` is Panes' consumer.
    case restorePhaseEnded(RestoreGeneration)
}

struct TerminalActivityCompactUpdate: Sendable, Equatable {
    let surfaceID: UUID
    let paneID: UUID
    let scrollbarState: ScrollbarState
    let outputBurst: TerminalOutputBurstState
}

enum TerminalActivityProjectionOutcome: Sendable, Equatable {
    case compactStateChanged(TerminalActivityCompactUpdate)
    /// Named for what this actually is -- the pane's first scrollbar
    /// sample with a positive row total, which Ghostty's own renderer
    /// emits on its unconditional first frame (`PageList.zig:687`'s
    /// viewport-sized `total_rows`, `scrollbar()` returning it with zero
    /// scrollback, `Thread.zig:242-243`'s initial wakeup firing
    /// independent of the IO thread that owns the PTY) -- never a claim
    /// that the PTY has delivered a byte.
    case firstRender(surfaceID: UUID, paneID: UUID)
    case paneObservationChanged(surfaceID: UUID, paneID: UUID, isPinnedToBottom: Bool)
    case unseenActivitySettled(surfaceID: UUID, paneID: UUID, activity: TerminalSettledActivity)
    case agentSettledActivityPromoted(surfaceID: UUID, paneID: UUID, activity: TerminalSettledActivity)
    case agentSettledActivityRevoked(surfaceID: UUID, paneID: UUID)
    case surfaceClosed(surfaceID: UUID, paneID: UUID?)
}

enum TerminalActivitySourceInput: Sendable, Equatable {
    case aggregate(
        surfaceID: UUID,
        paneID: UUID,
        input: TerminalActivityAggregateInput
    )
    case orderedControl(
        surfaceID: UUID,
        paneID: UUID,
        precedingAggregate: TerminalActivityAggregateInput?,
        control: TerminalActivityOrderedControl
    )
    /// SR6b: terminal activation arms a cold pane's restore phase before
    /// `createSurface` (Program Design item 13). Pane-keyed, not
    /// surface-keyed: no surface exists yet at arm time.
    case restorePhaseArmed(paneID: UUID, restoreGeneration: RestoreGeneration, resumeInvocation: ResumeInvocation?)
    /// SR6b, the no-surface route: a resumed agent's SessionStart fact can
    /// end the phase (R3) without going through a surface's ordered ingress.
    /// The live resumed-start adapter uses this fallback only when there is
    /// no current surface to carry the accumulator-ordered end.
    case restorePhaseEnded(paneID: UUID, restoreGeneration: RestoreGeneration)
    /// SR6b: permanent pane retirement — `WorkspaceSurfaceCoordinator
    /// .retirePanesPermanently`, "the shared final-retirement edge for undo
    /// expiry and committed direct discards" — is pane-keyed and distinct
    /// from `.surfaceClosed`, which also fires on ordinary surface
    /// replacement (`consumeAggregateState`'s `replacedSurfaceID` branch).
    /// Only this input clears `restorePhaseByPane`; a replaced surface keeps
    /// the pane's restore phase (Panes' consumer, requested via Main
    /// 2026-09-30).
    case paneRetiredPermanently(paneID: UUID)
}

/// Owns terminal activity derivation and quiet timers off MainActor.
/// Admission is bounded by the upstream per-surface accumulator: its drain awaits
/// each ingestion, so a live surface can have at most one actor call plus one
/// coalesced follow-up batch.
package actor TerminalActivityProjector {
    typealias OutcomeSink = @MainActor @Sendable ([TerminalActivityProjectionOutcome]) -> Void
    /// Reads the raw trailing viewport text for a surface, bounded to a
    /// small row window — one Ghostty call per settled burst. The projector
    /// owns all Contract 7 line-level contraction on that text
    /// (`TerminalLastOutputLineContract`): learned prompt-signature
    /// exclusion and unchanged-line suppression both need per-pane settle
    /// state that only the projector holds.
    typealias LastOutputLineReader = @MainActor @Sendable (_ surfaceID: UUID) -> TerminalViewportTextReadResult

    struct PaneState {
        let surfaceID: UUID
        var outputBurst: TerminalOutputBurstState
        var scrollbarState: ScrollbarState?
        var isPinnedToBottom: Bool?
        var didObserveFirstRender = false
        var unseenWindow: ActivityWindow?
        var activityWindow: ActivityWindow?
        var agentCandidate: ActivityWindow?
        var agentSettledLatestRows: Int?
        var isAgentSettledSuppressed = false
        /// The last contracted output-line candidate published at this
        /// pane's previous settle, used to suppress an unchanged repeat.
        var previousLastOutputLine: String?
        var hasReadableActivityBaseline = false
    }

    let unseenQuietDuration: Duration
    let agentSettledQuietDuration: Duration
    let deadlineClock: TerminalActivityDeadlineClock
    let factSink: TerminalActivityProjectorFactSink?
    var openDeadlineScopes: Set<TerminalActivityDeadlineScope> = []
    var unseenDeadlineScopes: [UUID: TerminalActivityDeadlineScope] = [:]
    var agentDeadlineScopes: [UUID: TerminalActivityDeadlineScope] = [:]
    private let nowMilliseconds: @Sendable () -> Int64
    let continuousNow: @Sendable () -> ContinuousClock.Instant
    let wallNow: @Sendable () -> Date
    let foregroundLookSink: (@Sendable (ForegroundLookTrigger, UUID) async -> Void)?
    var pendingForegroundEdges: [(ForegroundLookTrigger, UUID)] = []
    let activitySink: (@Sendable (PaneActivityOccurrence) -> Void)?
    let closeReadDurationSink: (@Sendable (Duration) -> Void)?
    private var outcomeSink: OutcomeSink?
    var lastOutputLineReader: LastOutputLineReader?
    var paneStates: [UUID: PaneState] = [:]
    /// SR6b (Program Design item 13, choice 13, step 3). Separate from
    /// `paneStates`/`PaneState` so surface replacement mid-phase does not
    /// clear it: only `endRestorePhase` (person input reaching the surface)
    /// and `retirePanePermanently` (permanent close) clear an entry; a plain
    /// `.surfaceClosed` never does. The map drives the Panes-owned consumer
    /// gating inside `consumeAggregateState`.
    private struct RestorePhaseArm {
        let generation: RestoreGeneration
        var pendingResume: ResumeInvocation?
        let validity = RestorePhaseArmValidity()
    }

    private var restorePhaseByPane: [UUID: RestorePhaseArm] = [:]
    var unseenCloseTasks: [UUID: Task<Void, Never>] = [:]
    var agentCloseTasks: [UUID: Task<Void, Never>] = [:]
    var unseenRetirementTasks: [UUID: Task<Void, Never>] = [:]
    var agentRetirementTasks: [UUID: Task<Void, Never>] = [:]

    init(
        unseenQuietDuration: Duration = AppPolicies.InboxNotification.terminalActivityQuietDebounceDuration,
        agentSettledQuietDuration: Duration = AppPolicies.InboxNotification.agentSettledQuietDuration,
        clock: (any Clock<Duration> & Sendable)? = nil,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        },
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        wallNow: @escaping @Sendable () -> Date = Date.init,
        activitySink: (@Sendable (PaneActivityOccurrence) -> Void)? = nil,
        closeReadDurationSink: (@Sendable (Duration) -> Void)? = nil,
        foregroundLookSink: (@Sendable (ForegroundLookTrigger, UUID) async -> Void)? = nil,
        factSink: TerminalActivityProjectorFactSink? = nil
    ) {
        self.unseenQuietDuration = unseenQuietDuration
        self.agentSettledQuietDuration = agentSettledQuietDuration
        deadlineClock = TerminalActivityDeadlineClock(clock)
        self.factSink = factSink
        self.nowMilliseconds = nowMilliseconds
        self.continuousNow = continuousNow
        self.wallNow = wallNow
        self.foregroundLookSink = foregroundLookSink
        self.activitySink = activitySink
        self.closeReadDurationSink = closeReadDurationSink
    }

    func configure(
        lastOutputLineReader: LastOutputLineReader? = nil,
        outcomeSink: @escaping OutcomeSink
    ) {
        self.lastOutputLineReader = lastOutputLineReader
        self.outcomeSink = outcomeSink
    }

    func ingest(
        surfaceID: UUID,
        paneID: UUID,
        aggregate: TerminalScrollbarActivityAggregate,
        latestState: ScrollbarState,
        context: TerminalActivityProjectionContext
    ) async {
        let outcomes = consumeAggregateState(
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: aggregate,
            latestState: latestState,
            context: context
        )
        await emit(outcomes)
    }

    /// A `terminal.commandFinished` shell-integration signal is a contracted semantic "this pane's
    /// current command just completed" fact (Contract 7 exact-fact route) — independent of
    /// scrollbar-derived activity evidence, and not gated by attention state. The scrollbar/unseen-
    /// window path above deliberately excludes attended panes (see `consumeAggregateState`'s
    /// `context.isAttended` branch), which is exactly the common case this signal exists to cover:
    /// typing into the pane you're looking at. It settles the pane's current burst immediately — if
    /// scrollbar evidence was already accumulating, close that window now instead of waiting out its
    /// remaining debounce; otherwise synthesize a minimal settle carrying just the resolved
    /// last-output-line, so a pane with zero scrollbar signal still reaches the existing settle path
    /// (status-fact write, notification lane, and all of that lane's suppression rules) unchanged.
    func commandFinished(surfaceID: UUID, paneID: UUID) async {
        await emit(await commandFinishedOutcomes(surfaceID: surfaceID, paneID: paneID))
    }

    private func commandFinishedOutcomes(
        surfaceID: UUID,
        paneID: UUID
    ) async -> [TerminalActivityProjectionOutcome] {
        guard !isRestorePhaseActive(paneID: paneID) else { return [] }

        queueForegroundClose(paneStates[paneID].flatMap { $0.surfaceID == surfaceID ? $0.activityWindow : nil })
        var closedWindow: ActivityWindow?
        if var state = paneStates[paneID], state.surfaceID == surfaceID,
            let window = state.unseenWindow, window.rowsAdded > 0
        {
            cancelUnseenWindow(for: paneID)
            state.unseenWindow = nil
            state.activityWindow = nil
            paneStates[paneID] = state
            closedWindow = window
        } else if var state = paneStates[paneID], state.surfaceID == surfaceID,
            state.activityWindow != nil
        {
            cancelUnseenWindow(for: paneID)
            state.activityWindow = nil
            paneStates[paneID] = state
        }

        await deliverForegroundEdges()
        let lastOutputLine = await resolveLastOutputLine(
            surfaceID: surfaceID,
            paneID: paneID
        )
        guard closedWindow != nil || lastOutputLine != nil else { return [] }

        let activity: TerminalSettledActivity
        if let closedWindow {
            activity = settledActivity(closedWindow, quietDuration: unseenQuietDuration, lastOutputLine: lastOutputLine)
        } else {
            let now = nowMilliseconds()
            let scrollbarState = paneStates[paneID]?.scrollbarState
            activity = TerminalSettledActivity(
                burstWindowId: UUIDv7.generate(),
                thresholdRows: AppPolicies.InboxNotification.terminalActivityOutputBurstThresholdRows,
                debounceMilliseconds: 0,
                startedAtMilliseconds: now,
                settledAtMilliseconds: now,
                eventCount: 0,
                rowsAdded: 0,
                baselineRows: scrollbarState?.total ?? 0,
                latestRows: scrollbarState?.total ?? 0,
                isPinnedToBottom: paneStates[paneID]?.isPinnedToBottom ?? true,
                lastOutputLine: lastOutputLine
            )
        }
        return [.unseenActivitySettled(surfaceID: surfaceID, paneID: paneID, activity: activity)]
    }

    private func consumeAggregateState(
        surfaceID: UUID,
        paneID: UUID,
        aggregate: TerminalScrollbarActivityAggregate,
        latestState: ScrollbarState,
        context: TerminalActivityProjectionContext
    ) -> [TerminalActivityProjectionOutcome] {
        var state: PaneState
        var replacedSurfaceID: UUID?
        if let existingState = paneStates[paneID], existingState.surfaceID != surfaceID {
            queueForegroundClose(existingState.activityWindow)
            cancelTimers(for: paneID)
            paneStates.removeValue(forKey: paneID)
            replacedSurfaceID = existingState.surfaceID
            state = PaneState(surfaceID: surfaceID, outputBurst: .unknown)
        } else {
            state =
                paneStates[paneID]
                ?? PaneState(surfaceID: surfaceID, outputBurst: .unknown)
        }

        let outputBurst = nextOutputBurst(
            current: state.outputBurst,
            aggregate: aggregate,
            threshold: context.outputBurstThreshold
        )
        let compactStateChanged = state.scrollbarState != latestState || state.outputBurst != outputBurst
        state.outputBurst = outputBurst
        let previousPinned = state.isPinnedToBottom
        let observationTransitions = pinnedObservationTransitions(
            previousIsPinnedToBottom: previousPinned,
            aggregate: aggregate,
            latestIsPinnedToBottom: latestState.isPinnedToBottom
        )
        state.isPinnedToBottom = latestState.isPinnedToBottom
        state.scrollbarState = latestState

        let isInRestorePhase = isRestorePhaseActive(paneID: paneID)
        if isInRestorePhase {
            state.unseenWindow = nil
            state.activityWindow = nil
        } else {
            admitOutputWindows(
                state: &state,
                surfaceID: surfaceID,
                paneID: paneID,
                aggregate: aggregate,
                latestState: latestState,
                context: context
            )
        }

        var shouldRevokeAgentSettledActivity = false
        if state.agentSettledLatestRows != nil {
            state.agentSettledLatestRows = nil
            state.isAgentSettledSuppressed = true
            shouldRevokeAgentSettledActivity = true
        }
        if isInRestorePhase {
            state.agentCandidate = nil
        } else if context.isAgentClassified, !state.isAgentSettledSuppressed {
            state.agentCandidate = mergeWindow(
                state.agentCandidate,
                surfaceID: surfaceID,
                paneID: paneID,
                threshold: context.outputBurstThreshold,
                aggregate: aggregate,
                latestState: latestState
            )
            scheduleAgentClose(for: paneID, state: state)
        } else {
            cancelAgentCandidate(for: paneID)
            state.agentCandidate = nil
        }

        let isFirstRender = aggregate.latestTotalRows > 0 && !state.didObserveFirstRender
        state.didObserveFirstRender = state.didObserveFirstRender || aggregate.latestTotalRows > 0
        paneStates[paneID] = state
        var outcomes: [TerminalActivityProjectionOutcome] = []
        if let replacedSurfaceID {
            outcomes.append(.surfaceClosed(surfaceID: replacedSurfaceID, paneID: paneID))
        }
        if shouldRevokeAgentSettledActivity {
            outcomes.append(.agentSettledActivityRevoked(surfaceID: surfaceID, paneID: paneID))
        }
        if compactStateChanged {
            outcomes.append(
                .compactStateChanged(
                    TerminalActivityCompactUpdate(
                        surfaceID: surfaceID,
                        paneID: paneID,
                        scrollbarState: latestState,
                        outputBurst: outputBurst
                    )
                )
            )
        }
        if isFirstRender, !isInRestorePhase {
            outcomes.append(.firstRender(surfaceID: surfaceID, paneID: paneID))
        }
        for isPinnedToBottom in observationTransitions {
            outcomes.append(
                .paneObservationChanged(
                    surfaceID: surfaceID,
                    paneID: paneID,
                    isPinnedToBottom: isPinnedToBottom
                )
            )
        }
        return outcomes
    }

    func applyOrderedControl(
        surfaceID: UUID,
        paneID: UUID,
        precedingAggregate: TerminalActivityAggregateInput?,
        control: TerminalActivityOrderedControl
    ) async {
        var outcomes: [TerminalActivityProjectionOutcome] = []
        if let precedingAggregate {
            outcomes.append(
                contentsOf: consumeAggregateState(
                    surfaceID: surfaceID,
                    paneID: paneID,
                    aggregate: precedingAggregate.aggregate,
                    latestState: precedingAggregate.latestState,
                    context: precedingAggregate.context
                )
            )
        }
        switch control {
        case .contextChanged(let context):
            applyContextChange(surfaceID: surfaceID, paneID: paneID, context: context)
        case .observed:
            markObserved(surfaceID: surfaceID, paneID: paneID)
        case .semanticSignal:
            semanticSignal(surfaceID: surfaceID, paneID: paneID)
        case .commandFinished:
            semanticSignal(surfaceID: surfaceID, paneID: paneID)
            outcomes.append(
                contentsOf: await commandFinishedOutcomes(
                    surfaceID: surfaceID,
                    paneID: paneID
                )
            )
        case .surfaceClosed:
            closeSurfaceState(surfaceID: surfaceID, paneID: paneID)
            outcomes.append(.surfaceClosed(surfaceID: surfaceID, paneID: paneID))
        case .restorePhaseEnded(let generation):
            await endRestorePhase(paneID: paneID, generation: generation)
        }
        await emit(outcomes)
    }

    // The restore-phase extension owns the consumer operations. These narrow
    // module-local helpers keep the restore-generation map private to this source file.
    func recordRestorePhaseGeneration(
        _ generation: RestoreGeneration, for paneID: UUID, resumeInvocation: ResumeInvocation?
    ) {
        restorePhaseByPane[paneID]?.validity.invalidate()
        restorePhaseByPane[paneID] = .init(generation: generation, pendingResume: resumeInvocation)
    }

    func restorePhaseGeneration(for paneID: UUID) -> RestoreGeneration? {
        restorePhaseByPane[paneID]?.generation
    }

    func pendingResumeInvocation(for paneID: UUID) -> ResumeInvocation? {
        restorePhaseByPane[paneID]?.pendingResume
    }

    func restorePhaseGenerationClaim(for paneID: UUID) -> RestorePhaseGenerationClaim? {
        restorePhaseByPane[paneID].map { .init(generation: $0.generation, validity: $0.validity) }
    }

    func consumePendingResumeInvocation(for paneID: UUID) {
        restorePhaseByPane[paneID]?.pendingResume = nil
    }

    @discardableResult
    func endRestorePhaseGenerationIfMatching(
        paneID: UUID,
        generation: RestoreGeneration
    ) -> Bool {
        guard restorePhaseByPane[paneID]?.generation == generation else { return false }
        restorePhaseByPane[paneID]?.validity.invalidate()
        restorePhaseByPane.removeValue(forKey: paneID)
        return true
    }

    func clearRestorePhaseGeneration(for paneID: UUID) {
        restorePhaseByPane[paneID]?.validity.invalidate()
        restorePhaseByPane.removeValue(forKey: paneID)
    }

    func discardOpenActivityWindowsForRestorePhaseArm(for paneID: UUID) {
        cancelUnseenWindow(for: paneID)
        cancelAgentCandidate(for: paneID)
        if var state = paneStates[paneID] {
            queueForegroundClose(state.activityWindow)
            state.unseenWindow = nil
            state.activityWindow = nil
            state.agentCandidate = nil
            paneStates[paneID] = state
        }
    }

    func resetPaneActivityBaselineAfterRestorePhaseEnd(for paneID: UUID) {
        cancelUnseenWindow(for: paneID)
        cancelAgentCandidate(for: paneID)
        if var state = paneStates[paneID] {
            queueForegroundClose(state.activityWindow)
            state.outputBurst = outputBurstBaselineAfterRestorePhaseEnd(from: state.outputBurst)
            state.unseenWindow = nil
            state.activityWindow = nil
            state.agentCandidate = nil
            state.previousLastOutputLine = nil
            state.hasReadableActivityBaseline = false
            paneStates[paneID] = state
        }
    }

    /// Test-only snapshot of the restore map; production reads it through
    /// `isRestorePhaseActive`.
    var restorePhaseGenerationsByPane: [UUID: RestoreGeneration] { restorePhaseByPane.mapValues(\.generation) }

    func retirePaneStatePermanently(for paneID: UUID) {
        queueForegroundClose(paneStates[paneID]?.activityWindow)
        cancelTimers(for: paneID)
        paneStates.removeValue(forKey: paneID)
    }

    func markObserved(surfaceID: UUID, paneID: UUID) {
        guard var state = paneStates[paneID], state.surfaceID == surfaceID else { return }
        if state.activityWindow == nil { cancelUnseenWindow(for: paneID) }
        cancelAgentCandidate(for: paneID)
        state.unseenWindow = nil
        state.agentCandidate = nil
        state.agentSettledLatestRows = nil
        state.isAgentSettledSuppressed = false
        paneStates[paneID] = state
    }

    func semanticSignal(surfaceID: UUID, paneID: UUID) {
        guard var state = paneStates[paneID], state.surfaceID == surfaceID else { return }
        cancelAgentCandidate(for: paneID)
        state.agentCandidate = nil
        paneStates[paneID] = state
    }

    private func applyContextChange(
        surfaceID: UUID,
        paneID: UUID,
        context: TerminalActivityProjectionContext
    ) {
        guard var state = paneStates[paneID], state.surfaceID == surfaceID else { return }
        if context.isAttended {
            if state.activityWindow == nil { cancelUnseenWindow(for: paneID) }
            state.unseenWindow = nil
        }
        if !context.isAgentClassified {
            cancelAgentCandidate(for: paneID)
            state.agentCandidate = nil
        }
        paneStates[paneID] = state
    }

    func closeSurface(surfaceID: UUID, paneID: UUID?) async {
        closeSurfaceState(surfaceID: surfaceID, paneID: paneID)
        await emit([.surfaceClosed(surfaceID: surfaceID, paneID: paneID)])
    }

    private func closeSurfaceState(surfaceID: UUID, paneID: UUID?) {
        if let paneID, paneStates[paneID]?.surfaceID == surfaceID {
            queueForegroundClose(paneStates[paneID]?.activityWindow)
            cancelTimers(for: paneID)
            paneStates.removeValue(forKey: paneID)
        }
    }

    func emit(_ outcomes: [TerminalActivityProjectionOutcome]) async {
        await deliverForegroundEdges()
        guard !outcomes.isEmpty, let outcomeSink else { return }
        await outcomeSink(outcomes)
    }

    func reset() async {
        let closeTasks = Array(unseenCloseTasks.values) + Array(agentCloseTasks.values)
        let retirementTasks = Array(unseenRetirementTasks.values) + Array(agentRetirementTasks.values)
        for task in closeTasks { task.cancel() }
        closeAllDeadlineFacts()
        unseenCloseTasks.removeAll()
        agentCloseTasks.removeAll()
        unseenRetirementTasks.removeAll()
        agentRetirementTasks.removeAll()
        for state in paneStates.values { queueForegroundClose(state.activityWindow) }
        paneStates.removeAll()
        // SR6b: without this, a pane armed when the router stops (e.g. app
        // shutdown mid-restore) would leave its entry in restorePhaseByPane
        // forever — this actor is reused across a later start() rather than
        // recreated, so nothing else ever clears it. No `.restorePhaseEnded`
        // is coming for a router that isn't running.
        for arm in restorePhaseByPane.values { arm.validity.invalidate() }
        restorePhaseByPane.removeAll()
        await deliverForegroundEdges()
        outcomeSink = nil
        lastOutputLineReader = nil
        for task in closeTasks { await task.value }
        for task in retirementTasks { await task.value }
    }

    var retainedPaneCount: Int { paneStates.count }
    /// Legacy notification-timer diagnostic: activity-only waits do not change its contract.
    var scheduledTimerCount: Int {
        unseenCloseTasks.keys.count { paneStates[$0]?.unseenWindow != nil } + agentCloseTasks.count
    }

    /// Joins the current output close, including its viewport read and activity admission.
    func activitySettled() async {
        let pendingCloseTasks = Array(unseenCloseTasks.values)
        for task in pendingCloseTasks { await task.value }
    }

}
