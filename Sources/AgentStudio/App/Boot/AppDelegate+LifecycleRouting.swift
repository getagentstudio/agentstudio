import AgentStudioInfrastructure
import AgentStudioTerminal
import AppKit
import os.log

private let appDelegateLifecycleLogger = Logger(subsystem: "com.agentstudio", category: "AppDelegate")

@MainActor
extension AppDelegate {
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let applicationLifecycleMonitor else {
            appDelegateLifecycleLogger.info("Skipping applicationDidBecomeActive before lifecycle monitor is ready")
            RestoreTrace.log("applicationDidBecomeActive skipped monitor=nil")
            return
        }
        applicationLifecycleMonitor.handleApplicationDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard let applicationLifecycleMonitor else {
            appDelegateLifecycleLogger.info("Skipping applicationDidResignActive before lifecycle monitor is ready")
            RestoreTrace.log("applicationDidResignActive skipped monitor=nil")
            return
        }
        applicationLifecycleMonitor.handleApplicationDidResignActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
            sidebarPerformanceProofSession?.completeIdlePopulationForTermination()
        #endif
        mainWindowController?.shutdown()
        managementLayerMonitor?.stopMonitoring()
        guard let applicationLifecycleMonitor else {
            appDelegateLifecycleLogger.warning("Skipping applicationWillTerminate before lifecycle monitor is ready")
            RestoreTrace.log("applicationWillTerminate skipped monitor=nil")
            return
        }
        applicationLifecycleMonitor.handleApplicationWillTerminate { [weak self] in
            guard
                let splitViewController = self?.mainWindowController?.window?.contentViewController
                    as? MainSplitViewController
            else { return }
            splitViewController.savePersistentUIState()
        }
    }

    func synchronizeApplicationLifecycleStateAfterWorkspaceBoot(isApplicationActive: Bool) {
        guard let applicationLifecycleMonitor else {
            appDelegateLifecycleLogger.warning(
                "Skipping lifecycle state synchronization before lifecycle monitor is ready"
            )
            RestoreTrace.log("synchronizeApplicationLifecycleStateAfterWorkspaceBoot skipped monitor=nil")
            return
        }

        RestoreTrace.log(
            "synchronizeApplicationLifecycleStateAfterWorkspaceBoot isActive=\(isApplicationActive)"
        )
        if isApplicationActive {
            applicationLifecycleMonitor.handleApplicationDidBecomeActive()
        } else {
            applicationLifecycleMonitor.handleApplicationDidResignActive()
        }
    }

    func wireLifecycleConsumers() {
        if case .available(let engine) = engineAvailabilityForBoot() {
            engine.bindApplicationLifecycleStore(appLifecycleStore)
        }
    }

    func paneTabViewController() -> PaneTabViewController? {
        guard
            let splitViewController = mainWindowController?.window?.contentViewController
                as? MainSplitViewController,
            splitViewController.splitViewItems.count > 1,
            let paneTabViewController = splitViewController.splitViewItems[1].viewController
                as? PaneTabViewController
        else { return nil }

        return paneTabViewController
    }

    func handleRefreshWorktreesRequested() async {
        let watchedPaths = store.repositoryTopologyAtom.watchedPaths
        guard !watchedPaths.isEmpty else { return }
        _ = await watchedFolderCommands.refreshRegisteredWorktreesAndWatchedFolders(watchedPaths)
        workspaceSurfaceCoordinator.syncFilesystemRootsAndActivity()
    }

    @objc func showCommandBarRepos() {
        self.commandDispatcherForBoot().dispatch(.showCommandBarRepos)
    }

    func showRepoCommandBar() {
        self.commandDispatcherForBoot().dispatch(.showCommandBarRepos)
    }

    func refreshWorktrees() {
        Task { await handleRefreshWorktreesRequested() }
    }

    func refocusActivePane() {
        mainWindowController?.refocusActivePane()
    }
}
