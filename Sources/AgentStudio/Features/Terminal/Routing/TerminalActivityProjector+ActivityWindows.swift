import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

// Window admission, contraction, closure and ordered foreground edges stay on the projector actor.
extension TerminalActivityProjector {
    struct ActivityWindow: Sendable {
        let id: UUID
        let surfaceID: UUID
        let paneID: UUID
        let thresholdRows: Int
        let startedAtMilliseconds: Int64
        var lastObservedAtMilliseconds: Int64
        var eventCount: Int
        var rowsAdded: Int
        var baselineRows: Int
        var latestRows: Int
        var latestIsPinnedToBottom: Bool
        var generation: UInt64
    }

    struct ActivityWindowCloseTarget: Sendable {
        let windowID: UUID
        let surfaceID: UUID
        let paneID: UUID
        let generation: UInt64
        let unseenWindow: ActivityWindow?
        let activityWindow: ActivityWindow?

        init(
            windowID: UUID,
            surfaceID: UUID,
            paneID: UUID,
            generation: UInt64,
            unseenWindow: ActivityWindow? = nil,
            activityWindow: ActivityWindow? = nil
        ) {
            self.windowID = windowID
            self.surfaceID = surfaceID
            self.paneID = paneID
            self.generation = generation
            self.unseenWindow = unseenWindow
            self.activityWindow = activityWindow
        }
    }

    func mergeWindow(
        _ existing: ActivityWindow?,
        surfaceID: UUID,
        paneID: UUID,
        threshold: Int,
        aggregate: TerminalScrollbarActivityAggregate,
        latestState: ScrollbarState
    ) -> ActivityWindow {
        let crossAggregatePositiveRowGrowth =
            existing.map {
                max(0, aggregate.firstTotalRows - $0.latestRows)
            } ?? 0
        var window =
            existing
            ?? ActivityWindow(
                id: UUIDv7.generate(),
                surfaceID: surfaceID,
                paneID: paneID,
                thresholdRows: threshold,
                startedAtMilliseconds: aggregate.firstObservedAtMilliseconds,
                lastObservedAtMilliseconds: aggregate.firstObservedAtMilliseconds,
                eventCount: 0,
                rowsAdded: 0,
                baselineRows: aggregate.firstTotalRows,
                latestRows: aggregate.firstTotalRows,
                latestIsPinnedToBottom: aggregate.firstIsPinnedToBottom,
                generation: 0
            )
        window.lastObservedAtMilliseconds = aggregate.latestObservedAtMilliseconds
        window.eventCount += aggregate.sampleCount
        window.rowsAdded += crossAggregatePositiveRowGrowth + aggregate.cumulativePositiveRowGrowth
        window.latestRows = aggregate.latestTotalRows
        window.latestIsPinnedToBottom = latestState.isPinnedToBottom
        window.generation &+= 1
        return window
    }

    private func admittedActivityWindow(
        current: ActivityWindow?,
        surfaceID: UUID,
        paneID: UUID,
        aggregate: TerminalScrollbarActivityAggregate,
        latestState: ScrollbarState,
        context: TerminalActivityProjectionContext
    ) -> ActivityWindow? {
        guard activitySink != nil || foregroundLookSink != nil else { return nil }
        let next = mergeWindow(
            current,
            surfaceID: surfaceID,
            paneID: paneID,
            threshold: context.outputBurstThreshold,
            aggregate: aggregate,
            latestState: latestState
        )
        return next.rowsAdded > (current?.rowsAdded ?? 0) ? next : current
    }

    func admitOutputWindows(
        state: inout PaneState,
        surfaceID: UUID,
        paneID: UUID,
        aggregate: TerminalScrollbarActivityAggregate,
        latestState: ScrollbarState,
        context: TerminalActivityProjectionContext
    ) {
        let previousActivityWindow = state.activityWindow
        state.activityWindow = admittedActivityWindow(
            current: state.activityWindow,
            surfaceID: surfaceID,
            paneID: paneID,
            aggregate: aggregate,
            latestState: latestState,
            context: context
        )
        if previousActivityWindow == nil, let window = state.activityWindow, foregroundLookSink != nil {
            pendingForegroundEdges.append((.outputBegan(burstWindowId: window.id), paneID))
        }
        if context.isAttended {
            state.unseenWindow = nil
        } else {
            state.unseenWindow = mergeWindow(
                state.unseenWindow,
                surfaceID: surfaceID,
                paneID: paneID,
                threshold: context.outputBurstThreshold,
                aggregate: aggregate,
                latestState: latestState
            )
        }
        scheduleUnseenClose(for: paneID, state: state)
    }

    func closeUnseenWindow(target: ActivityWindowCloseTarget) async -> Bool {
        guard !isRestorePhaseActive(paneID: target.paneID) else { return false }
        guard var state = paneStates[target.paneID],
            state.surfaceID == target.surfaceID
        else { return false }
        let unseenWindow = state.unseenWindow.flatMap { window in
            target.unseenWindow?.id == window.id && target.unseenWindow?.generation == window.generation
                ? window : nil
        }
        let activityWindow = state.activityWindow.flatMap { window in
            target.activityWindow?.id == window.id && target.activityWindow?.generation == window.generation
                ? window : nil
        }
        guard unseenWindow != nil || activityWindow != nil else { return false }
        unseenCloseTasks[target.paneID] = nil
        if unseenWindow != nil { state.unseenWindow = nil }
        if activityWindow != nil {
            queueForegroundClose(activityWindow)
            state.activityWindow = nil
        }
        paneStates[target.paneID] = state
        await deliverForegroundEdges()
        guard (unseenWindow?.rowsAdded ?? 0) > 0 || (activityWindow?.rowsAdded ?? 0) > 0 else { return true }
        let readStartedAt = ContinuousClock.now
        let lastOutputLine = await resolveLastOutputLine(
            surfaceID: target.surfaceID,
            paneID: target.paneID
        )
        guard !Task.isCancelled, !isRestorePhaseActive(paneID: target.paneID) else { return false }
        closeReadDurationSink?(readStartedAt.duration(to: .now))
        if let unseenWindow, unseenWindow.rowsAdded > 0 {
            await emit([
                .unseenActivitySettled(
                    surfaceID: unseenWindow.surfaceID,
                    paneID: target.paneID,
                    activity: settledActivity(
                        unseenWindow,
                        quietDuration: unseenQuietDuration,
                        lastOutputLine: lastOutputLine
                    )
                )
            ])
        }
        return true
    }

    func closeAgentCandidate(target: ActivityWindowCloseTarget) async -> Bool {
        guard !isRestorePhaseActive(paneID: target.paneID) else { return false }
        guard var state = paneStates[target.paneID],
            state.surfaceID == target.surfaceID,
            let candidate = state.agentCandidate,
            candidate.id == target.windowID,
            candidate.surfaceID == target.surfaceID,
            candidate.paneID == target.paneID,
            candidate.generation == target.generation
        else { return false }
        agentCloseTasks[target.paneID] = nil
        state.agentCandidate = nil
        guard isAgentSettledCandidate(candidate) else {
            paneStates[target.paneID] = state
            return true
        }
        state.agentSettledLatestRows = candidate.latestRows
        paneStates[target.paneID] = state
        let lastOutputLine = await resolveLastOutputLine(
            surfaceID: candidate.surfaceID,
            paneID: target.paneID
        )
        guard !Task.isCancelled, !isRestorePhaseActive(paneID: target.paneID) else { return false }
        await emit([
            .agentSettledActivityPromoted(
                surfaceID: candidate.surfaceID,
                paneID: target.paneID,
                activity: settledActivity(
                    candidate,
                    quietDuration: agentSettledQuietDuration,
                    lastOutputLine: lastOutputLine
                )
            )
        ])
        return true
    }

    /// Reads the literal trailing non-empty viewport line and applies unchanged-line suppression.
    /// Always re-fetches pane state after the reader's MainActor hop because the actor is reentrant
    /// across that suspension point.
    func resolveLastOutputLine(
        surfaceID: UUID,
        paneID: UUID
    ) async -> String? {
        // SR6b gates the persisted activity path too: activitySink feeds PaneActivityClock,
        // whose live admissions take precedence over the activity restored at boot.
        guard !Task.isCancelled, !isRestorePhaseActive(paneID: paneID) else { return nil }
        guard let lastOutputLineReader else { return nil }
        let readResult = await lastOutputLineReader(surfaceID)
        guard !Task.isCancelled, !isRestorePhaseActive(paneID: paneID) else { return nil }
        guard case .value(let rawText) = readResult else { return nil }

        var state: PaneState
        if let existingState = paneStates[paneID], existingState.surfaceID == surfaceID {
            state = existingState
        } else {
            // A commandFinished-driven settle can be the first thing this pane
            // ever sees (no prior scrollbar ingestion, e.g. right after boot) —
            // still track state so the learned signature persists into later
            // settles, matching the default-state pattern `consumeAggregateState`
            // already uses for a pane's first scrollbar sample.
            state = PaneState(surfaceID: surfaceID, outputBurst: .unknown)
        }
        let candidate = TerminalLastOutputLineContract.contractedLastLine(fromRawViewportText: rawText)
        let isUnchanged = candidate == state.previousLastOutputLine
        state.previousLastOutputLine = candidate
        if candidate != nil && !isUnchanged {
            if state.hasReadableActivityBaseline {
                activitySink?(
                    PaneActivityOccurrence(
                        paneId: paneID,
                        source: .terminal,
                        orderingInstant: continuousNow(),
                        wallTime: wallNow()
                    )
                )
            } else {
                state.hasReadableActivityBaseline = true
            }
        }
        paneStates[paneID] = state
        return isUnchanged ? nil : candidate
    }

    func isAgentSettledCandidate(_ candidate: ActivityWindow) -> Bool {
        guard candidate.rowsAdded >= AppPolicies.InboxNotification.agentSettledMinimumRows else { return false }
        let activeDuration = candidate.lastObservedAtMilliseconds - candidate.startedAtMilliseconds
        let minimumCandidate = Self.milliseconds(
            AppPolicies.InboxNotification.agentSettledMinimumCandidateDuration
        )
        guard activeDuration >= Int64(minimumCandidate) else { return false }
        let minimumActive = Self.milliseconds(AppPolicies.InboxNotification.agentSettledMinimumActiveDuration)
        return candidate.rowsAdded >= AppPolicies.InboxNotification.agentSettledHighConfidenceRows
            || activeDuration >= Int64(minimumActive)
    }

    func settledActivity(
        _ window: ActivityWindow,
        quietDuration: Duration,
        lastOutputLine: String?
    ) -> TerminalSettledActivity {
        let debounceMilliseconds = Self.milliseconds(quietDuration)
        return TerminalSettledActivity(
            burstWindowId: window.id,
            thresholdRows: window.thresholdRows,
            debounceMilliseconds: debounceMilliseconds,
            startedAtMilliseconds: window.startedAtMilliseconds,
            settledAtMilliseconds: window.lastObservedAtMilliseconds + Int64(debounceMilliseconds),
            eventCount: window.eventCount,
            rowsAdded: window.rowsAdded,
            baselineRows: window.baselineRows,
            latestRows: window.latestRows,
            isPinnedToBottom: window.latestIsPinnedToBottom,
            lastOutputLine: lastOutputLine
        )
    }

    func queueForegroundClose(_ window: ActivityWindow?) {
        guard foregroundLookSink != nil, let window else { return }
        pendingForegroundEdges.append((.outputSettled(burstWindowId: window.id), window.paneID))
    }

    func deliverForegroundEdges() async {
        let pending = pendingForegroundEdges
        pendingForegroundEdges.removeAll()
        guard let foregroundLookSink else { return }
        for (trigger, paneID) in pending { await foregroundLookSink(trigger, paneID) }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
