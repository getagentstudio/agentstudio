import AgentStudioCore
import AgentStudioTerminal
import Foundation

extension AppDelegate {
    func bootStartTerminalActivityRouter(bus: EventBus<RuntimeEnvelope>) {
        let datastore = workspaceSQLiteDatastore
        let paneActivityClock = PaneActivityClock(
            sink: makePaneActivitySink { commit in
                guard let datastore else { return }
                try await datastore.commitPaneActivity(commit)
            }
        )
        self.paneActivityClock = paneActivityClock
        workspaceSurfaceCoordinator?.paneActivityClock = paneActivityClock
        Task { await paneActivityClock.start() }
        terminalActivityRouter = TerminalActivityRouter(
            bus: bus,
            activityAtom: atomStore.terminalActivity,
            attendedPane: atomStore.core.attendedPane,
            traceRuntime: traceRuntime,
            startupTraceRecorder: startupTraceRecorder,
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

    func makePaneActivitySink(
        commit: @escaping @Sendable (PaneActivityCommit) async throws -> Void
    ) -> @MainActor @Sendable ([PaneActivityTimeMutation]) async -> Void {
        { [weak self] batch in
            guard let self else { return }
            atomStore.core.paneActivityTime.apply(batch)
            do {
                try await commit(PaneActivityCommit(mutations: batch))
            } catch {
                appLogger.warning("Pane activity save failed: \(String(describing: error), privacy: .private)")
            }
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
