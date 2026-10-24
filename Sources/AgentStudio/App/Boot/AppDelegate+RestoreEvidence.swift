import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import Foundation

extension AppDelegate {
    /// Called only after optional schema preparation; sink installation alone is insufficient.
    func replayBootRestoreRetirements() {
        workspaceSurfaceCoordinator.markRestoreForegroundRetirementReady()
    }

    func installRestoreEvidenceOwners(datastore: WorkspaceSQLiteDatastoreActor, sessionDirectory: String) async {
        guard restoreForegroundObserver == nil else { return }
        let launchId = UUIDv7.generate()
        let workspaceId = store.identityAtom.workspaceId
        let performanceRecorder = performanceTraceRecorder
        let repository =
            restoreForegroundEvidenceRepository
            ?? SQLitePaneForegroundEvidenceRepository(
                access: WorkspaceForegroundEvidenceSQLiteAccess(datastore: datastore), observerLaunchId: launchId,
                paneSessions: {
                    try await datastore.liveZmxSessionsByPane(
                        workspaceId: workspaceId, performanceTraceRecorder: performanceRecorder)
                })
        restoreForegroundEvidenceRepository = repository
        guard let bootId = try? await WorkspaceUndoJournalClock.current().bootID else { return }
        let watcher = DarwinProcessExitWatcher(performanceTraceRecorder: performanceRecorder)
        let observer = PaneForegroundObserver(
            clock: ContinuousClock(),
            policy: .init(
                lookSettleDelay: AppPolicies.Restore.lookSettleDelay, lookMaxDelay: AppPolicies.Restore.lookMaxDelay,
                quitLookDeadline: AppPolicies.Restore.quitLookDeadline),
            repository: repository,
            probe: DarwinTerminalForegroundProbe(
                sessionDirectory: sessionDirectory, bootId: bootId, performanceTraceRecorder: performanceRecorder),
            exitWatcher: watcher, observerLaunchId: launchId, performanceTraceRecorder: performanceRecorder)
        restoreForegroundExitWatcher = watcher
        restoreForegroundObserver = observer
        let (stream, continuation) = AsyncStream.makeStream(
            of: ForegroundLookTrigger.self, bufferingPolicy: .unbounded)
        restoreForegroundLifecycleStream = stream
        restoreForegroundLifecycleContinuation = continuation
        restoreForegroundTriggerSink = { continuation.yield($0) }
        workspaceSurfaceCoordinator.restorePaneRetirementSink = { [weak self] paneId in
            await observer.retire(paneId: paneId)
            await self?.retireColdResumePane(paneId)
        }
    }

    /// Optional local schema is prepared after the first frame. Retain early
    /// lifecycle values until then so a failed early read cannot consume relaunch.
    func startRestoreForegroundLifecycleConsumption() {
        guard restoreForegroundLifecycleTask == nil, let stream = restoreForegroundLifecycleStream,
            let observer = restoreForegroundObserver
        else { return }
        restoreForegroundLifecycleTask = Task { await consumeRestoreForegroundLifecycle(stream, observer: observer) }
    }

    func makeRestoreForegroundLookSink() -> (@Sendable (ForegroundLookTrigger, UUID) async -> Void)? {
        guard let observer = restoreForegroundObserver else { return nil }
        return { trigger, paneId in await observer.note(trigger, pane: paneId) }
    }

    @concurrent nonisolated private static func shutdownForegroundExitWatcher(_ watcher: DarwinProcessExitWatcher?)
        async
    {
        watcher?.shutdown()
    }

    func shutdownRestoreEvidenceOwners() async {
        await restoreResumeReadiness.shutdown()
        restoreForegroundLifecycleContinuation?.finish()
        restoreForegroundLifecycleTask?.cancel()
        await restoreForegroundLifecycleTask?.value
        await restoreForegroundObserver?.shutdown()
        await Self.shutdownForegroundExitWatcher(restoreForegroundExitWatcher)
        restoreForegroundLifecycleTask = nil
        restoreForegroundLifecycleContinuation = nil
        restoreForegroundLifecycleStream = nil
        restoreForegroundTriggerSink = nil
        restoreForegroundObserver = nil
        restoreForegroundExitWatcher = nil
        restoreForegroundEvidenceRepository = nil
    }
}

@concurrent nonisolated func consumeRestoreForegroundLifecycle<LifecycleClock: Clock<Duration>>(
    _ stream: AsyncStream<ForegroundLookTrigger>, observer: PaneForegroundObserver<LifecycleClock>
) async {
    for await trigger in stream { await observer.noteLifecycle(trigger) }
}
