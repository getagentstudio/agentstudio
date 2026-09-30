import Foundation
import Testing

@testable import AgentStudioTestSupport

@Suite("Application entrypoint architecture")
struct ApplicationEntrypointArchitectureTests {
    @Test("manual NSApplication setup uses a single run loop")
    func manualNSApplicationSetupUsesSingleRunLoop() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let mainSourceURL = projectRoot.appending(path: "Sources/AgentStudio/main.swift")
        let source = try String(contentsOf: mainSourceURL, encoding: .utf8)

        #expect(source.contains("let app = NSApplication.shared"))
        #expect(source.contains("app.delegate = delegate"))
        #expect(source.contains("UserDefaults.standard.set(false, forKey: \"NSQuitAlwaysKeepsWindows\")"))
        #expect(source.contains("app.run()"))
        #expect(!source.contains("NSApplicationMain("))
    }

    @Test("structured tracing is bootstrapped before Ghostty initialization")
    func structuredTracingBootstrapsBeforeGhosttyInitialization() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let mainSourceURL = projectRoot.appending(path: "Sources/AgentStudio/main.swift")
        let appDelegateURL = projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate.swift")
        let workspaceBootURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift")

        let mainSource = try String(contentsOf: mainSourceURL, encoding: .utf8)
        let appDelegateSource = try String(contentsOf: appDelegateURL, encoding: .utf8)
        let workspaceBootSource = try String(contentsOf: workspaceBootURL, encoding: .utf8)

        let preferencesBootstrapIndex = try #require(
            mainSource.range(of: "let globalPreferences = GlobalPreferencesBootstrap.load()")?.lowerBound)
        let traceBootstrapIndex = try #require(
            mainSource.range(of: "let traceRuntime = AgentStudioTraceRuntime.fromEnvironment(")?.lowerBound)
        let preferenceTraceIndex = try #require(
            mainSource.range(
                of: "GlobalPreferencesStartupTelemetry.recordLoaded(globalPreferences, recorder: startupTraceRecorder)"
            )?.lowerBound)
        let ghosttyInitIndex = try #require(mainSource.range(of: "ghostty_init(argc, argv)")?.lowerBound)
        let appDelegateInjectionIndex = try #require(
            mainSource.range(of: "startupTraceRecorder: startupTraceRecorder")?.lowerBound)

        #expect(preferencesBootstrapIndex < traceBootstrapIndex)
        #expect(traceBootstrapIndex < preferenceTraceIndex)
        #expect(preferenceTraceIndex < ghosttyInitIndex)
        #expect(traceBootstrapIndex < ghosttyInitIndex)
        #expect(appDelegateInjectionIndex > ghosttyInitIndex)
        #expect(appDelegateSource.contains("startupTraceRecorder: AgentStudioStartupTraceRecorder"))
        #expect(mainSource.contains("preferenceLayer: globalPreferences.tracePreferenceLayer"))
        #expect(mainSource.contains("GlobalPreferencesStartupTelemetry.recordLoaded"))
        #expect(!appDelegateSource.contains("GlobalPreferencesBootstrap.load()"))
        #expect(mainSource.contains("startupTraceRecorder: startupTraceRecorder"))
        #expect(!workspaceBootSource.contains("traceRuntime = .fromEnvironment()"))
        #expect(workspaceBootSource.contains("makeWorkspaceSQLiteDatastore(traceRuntime: traceRuntime)"))
    }

    @Test("global preferences boot boundary stays separated from diagnostics runtime")
    func globalPreferencesBootBoundaryStaysSeparatedFromDiagnosticsRuntime() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let diagnosticsPaths = [
            "Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioTraceConfiguration.swift",
            "Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioTraceRuntime.swift",
            "Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioTracePreferenceLayer.swift",
            "Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioOTLPTraceProjection.swift",
        ]
        let forbiddenDiagnosticsSymbols = [
            "GlobalPreferencesBootstrap",
            "GlobalPreferencesPayload",
            "GlobalObservabilityPreferencesPayload",
            "GlobalPreferencesStartupTelemetry",
        ]

        for diagnosticsPath in diagnosticsPaths {
            let source = try String(
                contentsOf: projectRoot.appending(path: diagnosticsPath),
                encoding: .utf8)
            for symbol in forbiddenDiagnosticsSymbols {
                #expect(
                    !source.contains(symbol),
                    "\(diagnosticsPath) must not reference App/Boot preference type \(symbol)")
            }
        }

        let bootPaths = [
            "Sources/AgentStudio/App/Boot/GlobalPreferencesBootstrap.swift",
            "Sources/AgentStudio/App/Boot/GlobalPreferencesPayload.swift",
        ]
        let forbiddenBootSymbols = [
            "AgentStudioTraceConfiguration",
            "AgentStudioTraceRuntime",
            "AgentStudioOTLPTraceProjection",
            "AgentStudioOTLPTraceSink",
            "AgentStudioJSONLTraceWriter",
        ]

        for bootPath in bootPaths {
            let source = try String(
                contentsOf: projectRoot.appending(path: bootPath),
                encoding: .utf8)
            for symbol in forbiddenBootSymbols {
                #expect(
                    !source.contains(symbol),
                    "\(bootPath) must not reference diagnostics runtime type \(symbol)")
            }
        }
    }

    @Test("startup diagnostic trigger is opt in and routes through AppCommandDispatcher")
    func startupDiagnosticTriggerIsOptInAndRoutesThroughCommandDispatcher() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let appDelegateURL = projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate.swift")
        let startupDiagnosticsURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Boot/AppDelegate+StartupDiagnostics.swift")
        let reviewStartupDiagnosticsURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Boot/AppDelegate+BridgeReviewStartupDiagnostics.swift")
        let diagnosticActionURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Boot/AgentStudioStartupDiagnosticAction.swift")
        let appPoliciesURL = projectRoot.appending(path: "Sources/AgentStudio/Infrastructure/AppPolicies.swift")
        let paneTabViewControllerURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Panes/PaneTabViewController.swift")

        let appDelegateSource = try String(contentsOf: appDelegateURL, encoding: .utf8)
        let startupDiagnosticsSource = try String(contentsOf: startupDiagnosticsURL, encoding: .utf8)
        let reviewStartupDiagnosticsSource = try String(
            contentsOf: reviewStartupDiagnosticsURL,
            encoding: .utf8
        )
        let diagnosticActionSource = try String(contentsOf: diagnosticActionURL, encoding: .utf8)
        let appPoliciesSource = try String(contentsOf: appPoliciesURL, encoding: .utf8)
        let paneTabViewControllerSource = try String(contentsOf: paneTabViewControllerURL, encoding: .utf8)

        let presentationCompleteIndex = try #require(
            appDelegateSource.range(of: "mainWindowController?.completeLaunchPresentation()")?.lowerBound)
        let diagnosticTriggerIndex = try #require(
            appDelegateSource.range(of: "runStartupDiagnosticActionIfRequested()")?.lowerBound)

        #expect(presentationCompleteIndex < diagnosticTriggerIndex)
        #expect(diagnosticActionSource.contains("AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION"))
        let actionDebugGuardIndex = try #require(diagnosticActionSource.range(of: "#if DEBUG")?.lowerBound)
        let actionSmokeCaseIndex = try #require(
            diagnosticActionSource.range(of: "case crossTabMoveGeometrySmoke")?.lowerBound)
        let actionIPCSmokeCaseIndex = try #require(
            diagnosticActionSource.range(of: "case ipcTerminalSmoke")?.lowerBound)
        let actionDebugEndIndex = try #require(diagnosticActionSource.range(of: "#endif")?.lowerBound)
        #expect(actionDebugGuardIndex < actionSmokeCaseIndex)
        #expect(actionSmokeCaseIndex < actionDebugEndIndex)
        #expect(actionDebugGuardIndex < actionIPCSmokeCaseIndex)
        #expect(actionIPCSmokeCaseIndex < actionDebugEndIndex)
        #expect(startupDiagnosticsSource.contains("AgentStudioStartupDiagnosticAction.fromEnvironment()"))
        #expect(startupDiagnosticsSource.contains("\"agentstudio.performance.sidebar.surface\": .string(\"repo\")"))
        #expect(startupDiagnosticsSource.contains(".string(projectionTrigger.rawValue)"))
        #expect(startupDiagnosticsSource.contains("AppCommandDispatcher.shared.dispatch(.newTab)"))
        #expect(startupDiagnosticsSource.contains("AppCommandDispatcher.shared.dispatch(.showCommandBarEverything)"))
        #expect(startupDiagnosticsSource.contains("commandBarController.setQueryText(\"# repo\")"))
        try assertCommandBarRepoFilterEmitsTerminalCompletion(startupDiagnosticsSource)
        #expect(startupDiagnosticsSource.contains("handleWatchFolderRequested(startingAt: folderURL)"))
        let diagnosticTaskIndex = try #require(
            startupDiagnosticsSource.range(of: "Task { @MainActor")?.lowerBound)
        let diagnosticDispatchRecordIndex = try #require(
            startupDiagnosticsSource.range(of: "app.startup_diagnostic_action.dispatched")?.lowerBound)
        let diagnosticFirstYieldIndex = try #require(
            startupDiagnosticsSource.range(of: "await Task.yield()")?.lowerBound)
        #expect(diagnosticTaskIndex < diagnosticDispatchRecordIndex)
        #expect(diagnosticDispatchRecordIndex < diagnosticFirstYieldIndex)
        let diagnosticSwitchIndex = try #require(
            startupDiagnosticsSource.range(of: "switch action.kind {")?.lowerBound)
        let dispatchDebugGuardIndex = try #require(
            startupDiagnosticsSource.range(
                of: "#if DEBUG",
                range: diagnosticSwitchIndex..<startupDiagnosticsSource.endIndex
            )?.lowerBound)
        let dispatchSmokeCaseIndex = try #require(
            startupDiagnosticsSource.range(of: "case .crossTabMoveGeometrySmoke")?.lowerBound)
        let dispatchIPCSmokeCaseIndex = try #require(
            startupDiagnosticsSource.range(of: "case .ipcTerminalSmoke")?.lowerBound)
        let dispatchDebugEndIndex = try #require(
            startupDiagnosticsSource.range(
                of: "#endif",
                range: dispatchDebugGuardIndex..<startupDiagnosticsSource.endIndex
            )?.lowerBound)
        #expect(dispatchDebugGuardIndex < dispatchSmokeCaseIndex)
        #expect(dispatchSmokeCaseIndex < dispatchDebugEndIndex)
        #expect(dispatchDebugGuardIndex < dispatchIPCSmokeCaseIndex)
        #expect(dispatchIPCSmokeCaseIndex < dispatchDebugEndIndex)
        try assertStartupDiagnosticActivationPrecedesOpeningTerminal(
            startupDiagnosticsSource: startupDiagnosticsSource)
        try assertBridgeReviewSmokeDiagnosticSuppressesLaunchRestore(
            appDelegateSource: appDelegateSource,
            startupDiagnosticsSource: startupDiagnosticsSource,
            reviewStartupDiagnosticsSource: reviewStartupDiagnosticsSource,
            diagnosticActionSource: diagnosticActionSource,
            paneTabViewControllerSource: paneTabViewControllerSource
        )
        #expect(appPoliciesSource.contains("bridgeReviewSmokeReadinessTimeout"))
        #expect(
            reviewStartupDiagnosticsSource.contains(
                "AppPolicies.StartupDiagnostic.bridgeReviewSmokeReadinessTimeout"))
        #expect(
            !reviewStartupDiagnosticsSource.contains(
                "AppPolicies.StartupDiagnostic.ipcTerminalSmokeReadinessTimeout"))
        #expect(startupDiagnosticsSource.contains("app.startup_diagnostic_action.command_exercised"))
        #expect(startupDiagnosticsSource.contains("app.startup_diagnostic_action.blocked"))
        let diagnosticDispatchIndex = try #require(
            startupDiagnosticsSource.range(of: "app.startup_diagnostic_action.dispatched")?.lowerBound)
        let firstDiagnosticYieldIndex = try #require(
            startupDiagnosticsSource.range(of: "await Task.yield()")?.lowerBound)
        #expect(diagnosticDispatchIndex < firstDiagnosticYieldIndex)
        #expect(!startupDiagnosticsSource.contains("for _ in 0..<80"))
        #expect(diagnosticActionSource.contains("AGENTSTUDIO_STARTUP_WATCH_FOLDER"))
        #expect(!appDelegateSource.contains("AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION"))
    }

    @Test("Repo Explorer mutation diagnostic opens the sidebar idempotently")
    func repoExplorerMutationDiagnosticOpensSidebarIdempotently() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let diagnosticURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Boot/AppDelegate+RepoExplorerKeyMutationStartupDiagnostics.swift")
        let diagnosticSource = try String(contentsOf: diagnosticURL, encoding: .utf8)

        #expect(
            diagnosticSource.contains(
                "atomStore.core.workspaceSidebarState.setSidebarSurface(.repos)"))
        #expect(diagnosticSource.contains("mainWindowController?.expandSidebar()"))
        #expect(!diagnosticSource.contains("AppCommandDispatcher.shared.dispatch(.showWorktreeSidebar)"))
        #expect(
            diagnosticSource.contains(
                "await waitForRepoExplorerProjectionReadiness(fixture: fixture)"))
        let readinessIndex = try #require(
            diagnosticSource.range(
                of: "await settleRepoExplorerProjection("
            )?.lowerBound)
        let mutationIndex = try #require(
            diagnosticSource.range(of: "self.runRenderedRepoPinnedMutations()")?.lowerBound)
        #expect(readinessIndex < mutationIndex)
        #expect(
            !diagnosticSource.contains(
                "atomStore.core.sidebarVisibleWorktreesRuntime.visibleWorktreeIds"))
        #expect(diagnosticSource.contains("repositoryTopologyAtom.repositoryIdsInOrder"))
        #expect(diagnosticSource.contains("repositoryTopologyAtom.worktreeIdsInOrder"))
        #expect(diagnosticSource.contains("AppPolicies.StartupDiagnostic.appActivationTimeout"))
    }

    private func assertCommandBarRepoFilterEmitsTerminalCompletion(
        _ startupDiagnosticsSource: String
    ) throws {
        let caseStart = try #require(
            startupDiagnosticsSource.range(of: "case .commandBarRepoFilter:")?.lowerBound)
        let caseEnd = try #require(
            startupDiagnosticsSource.range(
                of: "case .tccUpgradeProbe:",
                range: caseStart..<startupDiagnosticsSource.endIndex
            )?.lowerBound)
        let commandBarRepoFilterCase = startupDiagnosticsSource[caseStart..<caseEnd]
        let queryIndex = try #require(
            commandBarRepoFilterCase.range(of: "commandBarController.setQueryText(\"# repo\")")?.lowerBound)
        let exercisedIndex = try #require(
            commandBarRepoFilterCase.range(of: "app.startup_diagnostic_action.command_exercised")?.lowerBound)
        let completedIndex = try #require(
            commandBarRepoFilterCase.range(of: "app.startup_diagnostic_action.completed")?.lowerBound)
        #expect(queryIndex < exercisedIndex)
        #expect(exercisedIndex < completedIndex)
        #expect(commandBarRepoFilterCase.contains("phase: \"startup_diagnostic_action\""))
        #expect(commandBarRepoFilterCase.contains("outcome: \"succeeded\""))
        #expect(commandBarRepoFilterCase.contains("attributes: self.startupDiagnosticTraceAttributes(for: action)"))
    }

    private func assertStartupDiagnosticActivationPrecedesOpeningTerminal(
        startupDiagnosticsSource: String
    ) throws {
        #expect(startupDiagnosticsSource.contains("WindowRestoreBridge(windowLifecycleStore: windowLifecycleStore)"))
        #expect(startupDiagnosticsSource.contains("isReadyForLaunchRestore"))
        let diagnosticActivateIndex = try #require(
            startupDiagnosticsSource.range(of: "NSApp.activate(ignoringOtherApps: true)")?.lowerBound)
        let diagnosticKeyWindowIndex = try #require(
            startupDiagnosticsSource.range(of: "mainWindowController?.window?.makeKeyAndOrderFront(nil)")?.lowerBound)
        let diagnosticActivationWaitIndex = try #require(
            startupDiagnosticsSource.range(of: "await waitForStartupDiagnosticAppActivation()")?.lowerBound)
        let diagnosticOpenTerminalIndex = try #require(
            startupDiagnosticsSource.range(of: "workspaceSurfaceCoordinator.openFloatingTerminal(")?.lowerBound)
        #expect(diagnosticActivateIndex < diagnosticKeyWindowIndex)
        #expect(diagnosticKeyWindowIndex < diagnosticActivationWaitIndex)
        #expect(diagnosticActivationWaitIndex < diagnosticOpenTerminalIndex)
        #expect(startupDiagnosticsSource.contains("AppPolicies.StartupDiagnostic.appActivationTimeout"))
        #expect(startupDiagnosticsSource.contains("workspaceSurfaceCoordinator.openFloatingTerminal("))
        #expect(startupDiagnosticsSource.contains("provider: .zmx"))
    }

    private func assertBridgeReviewSmokeDiagnosticSuppressesLaunchRestore(
        appDelegateSource: String,
        startupDiagnosticsSource: String,
        reviewStartupDiagnosticsSource: String,
        diagnosticActionSource: String,
        paneTabViewControllerSource: String
    ) throws {
        #expect(diagnosticActionSource.contains("suppressesAutomaticLaunchPaneRestore"))
        #expect(diagnosticActionSource.contains("kind == .bridgeReviewObservabilitySmoke"))
        #expect(appDelegateSource.contains("suppressesAutomaticLaunchPaneRestore == true"))
        #expect(appDelegateSource.contains("launchRestoreObservationState.complete()"))
        #expect(paneTabViewControllerSource.contains("suppressesAutomaticLaunchPaneRestore == true"))
        #expect(paneTabViewControllerSource.contains("skipped visible view restore for startup diagnostic"))
        #expect(startupDiagnosticsSource.contains("runBridgeReviewObservabilitySmokeDiagnostic(action: action)"))

        let bridgeDiagnosticIndex = try #require(
            reviewStartupDiagnosticsSource.range(of: "func runBridgeReviewObservabilitySmokeDiagnostic")?.lowerBound)
        let bridgeDiagnosticEndIndex = try #require(
            reviewStartupDiagnosticsSource.range(
                of: "private func recordBridgeReviewObservabilitySmokePhase",
                range: bridgeDiagnosticIndex..<reviewStartupDiagnosticsSource.endIndex
            )?.lowerBound)
        let bridgeDiagnosticKeyWindowIndex = try #require(
            reviewStartupDiagnosticsSource.range(
                of: "mainWindowController?.window?.makeKeyAndOrderFront(nil)",
                range: bridgeDiagnosticIndex..<reviewStartupDiagnosticsSource.endIndex
            )?.lowerBound)
        let bridgeDiagnosticActivationWaitIndex = try #require(
            reviewStartupDiagnosticsSource.range(
                of: "await waitForStartupDiagnosticAppActivation()",
                range: bridgeDiagnosticIndex..<reviewStartupDiagnosticsSource.endIndex
            )?.lowerBound)
        let bridgeDiagnosticBoundsWaitIndex = try #require(
            reviewStartupDiagnosticsSource.range(
                of: "recordBridgeReviewObservabilitySmokePhase(\"bounds_wait_started\"",
                range: bridgeDiagnosticIndex..<reviewStartupDiagnosticsSource.endIndex
            )?.lowerBound)

        #expect(bridgeDiagnosticIndex < bridgeDiagnosticKeyWindowIndex)
        #expect(bridgeDiagnosticKeyWindowIndex < bridgeDiagnosticActivationWaitIndex)
        #expect(bridgeDiagnosticActivationWaitIndex < bridgeDiagnosticBoundsWaitIndex)
        #expect(
            reviewStartupDiagnosticsSource.range(
                of: "workspaceSurfaceCoordinator.restoreVisiblePaneIfNeeded(pane.id",
                range: bridgeDiagnosticIndex..<bridgeDiagnosticEndIndex
            ) != nil)
        #expect(
            reviewStartupDiagnosticsSource.range(
                of: "restoreAllViews",
                range: bridgeDiagnosticIndex..<bridgeDiagnosticEndIndex
            ) == nil)
    }

    @Test("AppKit persistent UI restoration is disabled")
    func appKitPersistentUIRestorationIsDisabled() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let appDelegateURL = projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate.swift")
        let mainWindowControllerURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Windows/MainWindowController.swift")

        let appDelegateSource = try String(contentsOf: appDelegateURL, encoding: .utf8)
        let mainWindowControllerSource = try String(contentsOf: mainWindowControllerURL, encoding: .utf8)
        let secureRestorationDisabled =
            "    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {\n"
            + "        false\n"
            + "    }"

        #expect(appDelegateSource.contains(secureRestorationDisabled))
        #expect(mainWindowControllerSource.contains("window.isRestorable = false"))
    }

    @Test("App IPC server is composed at app boot and stopped on termination")
    func appIPCServerIsComposedAtAppBootAndStoppedOnTermination() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let appDelegateURL = projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate.swift")
        let ipcBootURL = projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+IPC.swift")
        let launchRestoreURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Boot/AppDelegate+LaunchRestore.swift")
        let workspaceBootURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift")
        let terminationURL = projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+Termination.swift")
        let mainWindowControllerURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Windows/MainWindowController.swift")
        let splitViewControllerURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Windows/MainSplitViewController.swift")

        let appDelegateSource = try String(contentsOf: appDelegateURL, encoding: .utf8)
        let ipcBootSource = try String(contentsOf: ipcBootURL, encoding: .utf8)
        let launchRestoreSource = try String(contentsOf: launchRestoreURL, encoding: .utf8)
        let workspaceBootSource = try String(contentsOf: workspaceBootURL, encoding: .utf8)
        let terminationSource = try String(contentsOf: terminationURL, encoding: .utf8)
        let mainWindowControllerSource = try String(contentsOf: mainWindowControllerURL, encoding: .utf8)
        let splitViewControllerSource = try String(contentsOf: splitViewControllerURL, encoding: .utf8)

        let suppressedScheduleIndex = try #require(
            appDelegateSource.range(of: "scheduleAppIPCInitialization()")?.lowerBound)
        let terminalReleaseIndex = try #require(
            launchRestoreSource.range(of: "await preparedMountOwners.coordinator.releaseTerminalActivation()")?
                .lowerBound)
        let normalScheduleIndex = try #require(
            launchRestoreSource.range(of: "scheduleAppIPCInitialization()")?.lowerBound)
        let appIPCStopIndex = try #require(
            terminationSource.range(of: "await self?.stopAcceptingAppIPCConnections()")?.lowerBound)
        let flushStoresIndex = try #require(terminationSource.range(of: "await store.flushAsync()")?.lowerBound)
        let appIPCDrainIndex = try #require(
            terminationSource.range(of: "await self?.drainAppIPCCredentialPersistence()")?.lowerBound)
        let identityAuthorityIndex = try #require(
            workspaceBootSource.range(of: "installAppIPCIdentityAuthority(datastore:")?.lowerBound)
        let surfaceCoordinatorIndex = try #require(
            workspaceBootSource.range(of: "workspaceSurfaceCoordinator = WorkspaceSurfaceCoordinator(")?.lowerBound)
        let undoRecoveryIndex = try #require(
            workspaceBootSource.range(of: "workspaceSurfaceCoordinator.installUndoJournalRecovery(")?.lowerBound)

        #expect(appDelegateSource.contains("import AgentStudioAppIPC"))
        #expect(appDelegateSource.contains("var appIPCServer: AgentStudioAppIPCServer?"))
        #expect(!appDelegateSource.contains("startAppIPCServer()"))
        #expect(appDelegateSource.contains("var appIPCInitializationTask: Task<Void, Never>?"))
        #expect(appDelegateSource.contains("appIPCInitializationTask?.cancel()"))
        #expect(suppressedScheduleIndex < appDelegateSource.endIndex)
        #expect(terminalReleaseIndex < normalScheduleIndex)
        #expect(identityAuthorityIndex < surfaceCoordinatorIndex)
        #expect(surfaceCoordinatorIndex < undoRecoveryIndex)
        #expect(ipcBootSource.contains("prepareOptionalApplicationLocalSchema()"))
        #expect(ipcBootSource.contains("waitUntilFirstInteractiveFramePublished()"))
        #expect(ipcBootSource.contains("let initializationTask = appIPCInitializationTask"))
        #expect(ipcBootSource.contains("initializationTask?.cancel()"))
        #expect(ipcBootSource.contains("await initializationTask?.value"))
        #expect(ipcBootSource.contains("await finishAppIPCSessionsIngestion()"))
        #expect(!ipcBootSource.contains("func stopAppIPCServer()"))

        // Connection handlers are joined in the durable drain, before the
        // credential drain runs, and never in the ingress-only stop — a
        // handler mid-request can still enqueue persistence work, so the
        // credential drain must not start until every handler has quiesced.
        let stopAcceptingRange = try #require(
            ipcBootSource.range(of: "func stopAcceptingAppIPCConnections() async {"))
        // Ends at drainAppIPCCredentialPersistence()'s own doc comment, not its
        // func line: that comment (legitimately) names joinConnectionHandlers
        // in prose, and a range ending at the func line would sweep it into
        // stopAcceptingBody.
        let drainDocCommentRange = try #require(
            ipcBootSource.range(of: "/// The durable half,"))
        let stopAcceptingBody = ipcBootSource[stopAcceptingRange.lowerBound..<drainDocCommentRange.lowerBound]
        #expect(!stopAcceptingBody.contains("joinConnectionHandlers"))
        #expect(ipcBootSource.contains("await server.joinConnectionHandlers()"))
        let credentialDrainCallIndex = try #require(
            ipcBootSource.range(of: "await server.drainCredentialPersistence()")?.lowerBound)
        let joinConnectionHandlersIndex = try #require(
            ipcBootSource.range(of: "await server.joinConnectionHandlers()")?.lowerBound)
        #expect(joinConnectionHandlersIndex < credentialDrainCallIndex)
        #expect(ipcBootSource.contains("let paneIPCIdentityOwner = paneIPCIdentityOwner!"))
        #expect(!ipcBootSource.contains("self.appIPCInitializationTask = nil"))
        #expect(
            ipcBootSource.components(separatedBy: "guard appIPCServer == nil else { return }").count - 1
                == 2)
        #expect(ipcBootSource.contains("import AgentStudioAppIPC"))
        #expect(ipcBootSource.contains("import AgentStudioProgrammaticControl"))
        #expect(ipcBootSource.contains("AppIPCBuiltInMethodRegistrations.make("))
        #expect(ipcBootSource.contains("AppIPCCommandMethodRegistrations.make("))
        #expect(ipcBootSource.contains("AppIPCMethodRegistry("))
        #expect(
            ipcBootSource.contains(
                "let recognizedCommands = commandCatalogProjectionInputs.recognizedCommands"))
        #expect(ipcBootSource.contains("recognizedCommands: recognizedCommands"))
        #expect(ipcBootSource.contains("ownPaneScopePort: WorkspaceOwnPaneScopePort("))
        #expect(
            ipcBootSource.contains(
                "workspaceStore: store, performanceTraceRecorder: performanceTraceRecorder)"))
        #expect(ipcBootSource.contains("agentAuthorizationTelemetry: AgentStudioIPCAgentAuthorizationTelemetry("))
        #expect(ipcBootSource.contains("methodRegistry: registry"))
        #expect(ipcBootSource.contains("rootDirectory: AppDataPaths.rootDirectory()"))
        #expect(ipcBootSource.contains("socketDirectory: Self.appIPCSocketDirectory()"))
        #expect(ipcBootSource.contains("ProcessInfo.processInfo.environment[\"AGENTSTUDIO_IPC_SOCKET_DIR\"]"))
        #expect(ipcBootSource.contains("makePaneFocusAppControl(store: store)"))
        #expect(ipcBootSource.contains("server.start()"))
        // Ingress closes before the flush so no late request can mutate state
        // the flush has written; the durable drain runs after it so it can
        // never spend the flush's budget.
        #expect(appIPCStopIndex < flushStoresIndex)
        #expect(flushStoresIndex < appIPCDrainIndex)
        #expect(mainWindowControllerSource.contains("splitViewController?.loadViewIfNeeded()"))
        #expect(mainWindowControllerSource.contains("makePaneFocusAppControl(store: WorkspaceStore)"))
        #expect(splitViewControllerSource.contains("makePaneFocusAppControl(store: WorkspaceStore)"))
        #expect(splitViewControllerSource.contains("PaneTabViewControllerPaneFocusAppControl"))
    }
}
