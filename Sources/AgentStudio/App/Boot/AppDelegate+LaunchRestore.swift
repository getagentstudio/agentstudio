import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import os.log

private let launchRestoreLogger = Logger(subsystem: "com.agentstudio", category: "AppDelegate")

enum LaunchRestoreFocusTailPolicy {
    static func shouldRun(for disposition: TerminalPlaceholderPublication.Disposition) -> Bool {
        disposition == .published
    }
}

@MainActor
extension AppDelegate {
    func finishLaunchRestore(
        using restoreBounds: CGRect,
        source: StaticString
    ) async {
        guard !launchRestoreObservationState.didComplete else { return }
        let preparedMountOwners = installedWorkspacePreparedContentMountOwners
        let requiresTerminalGeometry = !preparedMountOwners.cohort.terminalActivationInput.entries.isEmpty
        guard !restoreBounds.isEmpty || !requiresTerminalGeometry else {
            RestoreTrace.log("launchRestore skipped reason=emptyBounds source=\(source)")
            launchRestoreLogger.error(
                "Launch restore attempted with empty bounds source=\(source, privacy: .public) storeBounds=\(NSStringFromRect(self.windowLifecycleStore.terminalContainerBounds), privacy: .public)"
            )
            return
        }

        RestoreTrace.log(
            "launchRestore triggered source=\(source) bounds=\(NSStringFromRect(restoreBounds)) windowFrame=\(NSStringFromRect(mainWindowController?.window?.frame ?? .zero)) contentRect=\(NSStringFromRect(mainWindowController?.window?.contentLayoutRect ?? .zero))"
        )
        let initialFramesByPaneID: [PaneId: NSRect]
        if requiresTerminalGeometry {
            let resolvedPaneFramesByTabID = workspaceSurfaceCoordinator.resolveInitialFramesByTabId(
                in: restoreBounds
            )
            initialFramesByPaneID = preparedMountOwners.cohort.terminalActivationInput.entries.reduce(
                into: [:]
            ) { framesByPaneID, descriptor in
                if let frame = workspaceSurfaceCoordinator.initialFrame(
                    for: descriptor.pane,
                    resolvedPaneFramesByTabId: resolvedPaneFramesByTabID
                ) {
                    framesByPaneID[descriptor.paneID] = frame
                }
            }
        } else {
            initialFramesByPaneID = [:]
        }
        let eligibleTerminalPaneIDs = preparedMountOwners.terminalAdmissionPort.installTrustedInitialFrames(
            initialFramesByPaneID
        )
        await preparedMountOwners.coordinator.installTerminalGeometryAvailability(eligibleTerminalPaneIDs)
        let placeholderOwner: WorkspaceSurfaceCoordinator = workspaceSurfaceCoordinator
        let placeholderPublication = preparedMountOwners.coordinator.publishTerminalPlaceholders { descriptor in
            placeholderOwner.registerPreparedTerminalPlaceholders(for: descriptor)
        }
        RestoreTrace.log(
            "launchRestore placeholders published count=\(placeholderPublication.paneIDs.count)"
        )
        await preparedMountOwners.coordinator.holdTerminalActivationUntilReleased()
        async let deferredSettlement = preparedMountOwners.coordinator.mount()
        let firstFrameDeferralOutcome = await windowLifecycleStore.waitUntilFirstInteractiveFramePublished()
        performanceTraceRecorder?.recordStartupDeferral(
            gate: "first_interactive_frame",
            outcome: firstFrameDeferralOutcome
        )
        await preparedMountOwners.coordinator.releaseTerminalActivation()
        scheduleAppIPCInitialization()
        let settlement = await deferredSettlement
        if let terminalDeferralOutcome = await preparedMountOwners.coordinator.terminalActivationDeferralOutcome() {
            performanceTraceRecorder?.recordStartupDeferral(
                gate: "terminal_activation_release",
                outcome: terminalDeferralOutcome
            )
        }
        if LaunchRestoreFocusTailPolicy.shouldRun(for: placeholderPublication.disposition) {
            syncFocusAfterPreparedContentMount(settlement)
        }
        for paneID in preparedMountOwners.coordinator.takeDeferredSteadyStateRepairPaneIDs() {
            workspaceSurfaceCoordinator.restoreVisiblePaneIfNeeded(
                paneID.uuid,
                forceWhenBoundsExist: true
            )
        }
        if LaunchRestoreFocusTailPolicy.shouldRun(for: placeholderPublication.disposition),
            let focusedPaneID = currentWorkspaceFocusedPaneID()
        {
            workspaceSurfaceCoordinator.focusVisiblePaneHost(focusedPaneID, reason: .restoreTail)
        }
        mainWindowController?.syncVisibleTerminalGeometry(reason: "postLaunchRestore")
        launchRestoreObservationState.complete()
        RestoreTrace.log("launchRestore end registeredViews=\(viewRegistry.registeredPaneIds.count)")
    }

    private func syncFocusAfterPreparedContentMount(
        _ settlement: WorkspacePreparedContentMountSettlement
    ) {
        guard let activePaneID = currentWorkspaceFocusedPaneID() else {
            workspaceSurfaceCoordinator.surfaceManager.syncFocus(activeSurfaceId: nil)
            return
        }
        let runtimePaneID = PaneId(existingUUID: activePaneID)
        guard case .ready(let surfaceID) = settlement.terminal.outcomesByPaneID[runtimePaneID] else {
            workspaceSurfaceCoordinator.surfaceManager.syncFocus(activeSurfaceId: nil)
            return
        }
        workspaceSurfaceCoordinator.surfaceManager.syncFocus(activeSurfaceId: surfaceID)
    }

    private func currentWorkspaceFocusedPaneID() -> UUID? {
        let workspaceTab = WorkspaceTabLayoutDerived(
            shellAtom: store.tabShellAtom,
            arrangementAtom: store.tabArrangementAtom
        )
        return atom(\.workspaceFocusedPane).resolve(
            workspaceTab: workspaceTab,
            workspacePane: store.paneAtom,
            requestedOwner: atom(\.workspaceFocusOwner).owner
        )?.paneId
    }

    func observeLaunchRestoreReadiness() {
        let bridge = WindowRestoreBridge(windowLifecycleStore: windowLifecycleStore)
        windowRestoreBridge = bridge
        launchRestoreObservationState.prepareForObservation()
        launchRestoreObservationTask?.cancel()
        launchRestoreObservationState.installDiagnosticTask(
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    launchRestoreLogger.warning("Unexpected error in launch restore diagnostic timer: \(error)")
                    return
                }
                guard !self.launchRestoreObservationState.didComplete else { return }
                launchRestoreLogger.error(
                    "Launch restore timed out — isSettled=\(self.windowLifecycleStore.isLaunchLayoutSettled, privacy: .public) bounds=\(NSStringFromRect(self.windowLifecycleStore.terminalContainerBounds), privacy: .public)"
                )
                let fallbackBounds = self.windowLifecycleStore.terminalContainerBounds
                guard !fallbackBounds.isEmpty else {
                    // Readiness remains observable; a later bounds publication can still restore.
                    return
                }
                launchRestoreLogger.error(
                    "Launch restore timeout recovery: attempting restore with stored bounds \(NSStringFromRect(fallbackBounds), privacy: .public)"
                )
                await self.finishLaunchRestore(
                    using: fallbackBounds,
                    source: "diagnosticTimeoutRecovery"
                )
            }
        )
        launchRestoreObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await bounds in bridge.stream {
                guard !Task.isCancelled else { break }
                let restoreBounds =
                    bounds.isEmpty
                    ? self.windowLifecycleStore.terminalContainerBounds
                    : bounds
                await self.finishLaunchRestore(
                    using: restoreBounds,
                    source: "windowRestoreBridge"
                )
                if self.launchRestoreObservationState.didComplete {
                    break
                }
            }
            if !self.launchRestoreObservationState.didComplete {
                launchRestoreLogger.error("Launch restore stream ended without completing restore")
                self.launchRestoreObservationState.cancelDiagnostics()
            }
        }
    }
}
