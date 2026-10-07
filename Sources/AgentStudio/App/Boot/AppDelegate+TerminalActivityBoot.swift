import AgentStudioCore
import AgentStudioTerminal
import Foundation

extension AppDelegate {
    func bootStartTerminalActivityRouter(bus: EventBus<RuntimeEnvelope>) {
        let paneActivityClock = PaneActivityClock { [weak self] batch in
            self?.atomStore.core.paneActivityTime.apply(batch)
        }
        self.paneActivityClock = paneActivityClock
        workspaceSurfaceCoordinator?.paneActivityClock = paneActivityClock
        Task { await paneActivityClock.start() }
        Ghostty.ActionRouter.bindAttachClientExitedHandler { [weak self] paneID in
            self?.workspaceSurfaceCoordinator?.receivePostAttachChildExited(paneID: paneID)
        }
        terminalActivityRouter = TerminalActivityRouter(
            bus: bus,
            activityAtom: atomStore.terminalActivity,
            attendedPane: atomStore.core.attendedPane,
            traceRuntime: traceRuntime,
            startupTraceRecorder: startupTraceRecorder,
            // A6 (advisor review 2026-10-01; PD rev 21 item 5, Lead
            // decision: push, not pull): the existing `.firstRender`
            // outcome arm's own new callback -- composed here since the
            // coordinator has no reference to this router or its
            // privately-owned projector. No new actor hop: both are
            // `@MainActor`.
            onFirstRender: { [weak self] paneID in
                self?.workspaceSurfaceCoordinator?.receivePostAttachFirstRender(paneID: paneID)
            },
            isPaneCurrentlyAttended: { [weak self] paneId in
                self?.isPaneCurrentlyAttendedForTerminalActivity(paneId) ?? false
            },
            isPaneAgentClassified: { [weak self] paneId, paneKind in
                if paneKind == .agent { return true }
                return self?.store.paneAtom.pane(paneId)?.metadata.contentType == .agent
            },
            recordSettledActivityStatus: { [weak self] paneId, lastOutputLine in
                self?.atomStore.core.paneActivityStatus.recordSettledActivity(
                    paneId: paneId,
                    lastOutputLine: lastOutputLine
                )
            },
            clearPaneActivityStatus: { [weak self] paneId in
                self?.atomStore.core.paneActivityStatus.clear(paneId: paneId)
            },
            activityOccurrenceSink: { occurrence in
                paneActivityClock.submit(occurrence)
            },
            closeReadDurationSink: { [performanceTraceRecorder] duration in
                performanceTraceRecorder?.recordTerminalActivityCloseRead(duration)
            }
        )
        Task { @MainActor [weak self] in
            await self?.terminalActivityRouter.start()
        }
    }

    private func isPaneCurrentlyAttendedForTerminalActivity(_ paneId: UUID) -> Bool {
        PaneObservationResolver.isPaneCurrentlyAttended(
            paneId: paneId,
            attendedPaneId: atomStore.core.attendedPane.attendedPaneId,
            pane: { store.paneAtom.pane($0) }
        )
    }
}
