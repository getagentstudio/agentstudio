import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@Suite(.serialized)
@MainActor
struct AppBootSequenceTests {
    @Test("boot sequence exposes only composition prerequisites before presentation")
    func presentationPrerequisitesMatchArchitectureContract() {
        #expect(
            WorkspaceBootSequence.presentationPrerequisiteSteps == [
                .prepareDatabases,
                .loadCanonicalStore,
                .establishRuntimeBus,
            ])
        #expect(
            WorkspaceBootSequence.postPresentationSteps == [
                .loadCacheStore,
                .loadUIStore,
                .startFilesystemActor,
                .startGitProjector,
                .startForgeActor,
                .startCacheCoordinator,
                .armPersistenceObservation,
                .triggerInitialTopologySync,
                .readyForReactiveSidebar,
            ])
    }

    @Test("presentation runner cannot execute post-presentation work")
    func presentationRunnerExecutesOnlyPrerequisites() {
        var recorded: [WorkspaceBootStep] = []
        WorkspaceBootSequence.runPresentationPrerequisites { step in
            recorded.append(step)
        }
        #expect(recorded == WorkspaceBootSequence.presentationPrerequisiteSteps)
        #expect(!recorded.contains(.loadCacheStore))
        #expect(!recorded.contains(.loadUIStore))
        #expect(!recorded.contains(.triggerInitialTopologySync))
    }

    @Test("every boot step explains why it exists")
    func bootStepsDocumentTheirPurpose() {
        for step in WorkspaceBootSequence.presentationPrerequisiteSteps
            + WorkspaceBootSequence.postPresentationSteps
        {
            #expect(!step.purpose.isEmpty, "Missing boot purpose for \(step.rawValue)")
        }
    }

    @Test("window presentation precedes independent cache and topology startup")
    func windowPresentationPrecedesIndependentStartupLanes() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let appDelegateSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate.swift"),
            encoding: .utf8
        )
        let presentation = try #require(
            appDelegateSource.range(of: "self.presentWindowAfterWorkspaceComposition()")
        )
        let postPresentation = try #require(
            appDelegateSource.range(of: "await self.bootWorkspacePostPresentationServices(")
        )

        #expect(presentation.lowerBound < postPresentation.lowerBound)
    }

    @Test("boot observation step arms every autosaving persistence store")
    func bootObservationStepArmsEveryAutosavingPersistenceStore() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let appDelegateSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"),
            encoding: .utf8
        )

        #expect(appDelegateSource.contains("case .armPersistenceObservation:"))
        #expect(appDelegateSource.contains("bootArmPersistenceObservation()"))
        #expect(appDelegateSource.contains("store.startObserving()"))
        #expect(appDelegateSource.contains("repoCacheStore.startObserving()"))
        #expect(appDelegateSource.contains("sidebarCacheStore.startObserving()"))
        #expect(appDelegateSource.contains("uiStateStore.startObserving()"))
        #expect(appDelegateSource.contains("workspaceSettingsStore.startObserving()"))
        #expect(appDelegateSource.contains("assertBootPersistenceObservationArmed()"))
    }

    @Test("boot loads settings with UI-scoped persistence stores")
    func bootLoadsSettingsWithUIScopedPersistenceStores() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let appDelegateSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"),
            encoding: .utf8
        )

        #expect(
            appDelegateSource.contains(
                "workspaceSettingsStore = makeWorkspaceSettingsStore(sqliteDatastore: sqliteDatastore)"
            )
        )
        #expect(
            appDelegateSource.contains("await workspaceSettingsStore.restoreAsync(for: store.identityAtom.workspaceId)")
        )
    }

    @Test("boot injects SQLite datastore into canonical stores")
    func bootInjectsSQLiteDatastoreIntoCanonicalStores() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let appDelegateSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"),
            encoding: .utf8
        )
        let datastoreFactorySource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteDatastoreFactory.swift"
            ),
            encoding: .utf8
        )
        let normalizedDatastoreFactorySource =
            datastoreFactorySource
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let expectedDatastoreConstruction = [
            "WorkspaceSQLiteDatastoreActor(",
            "configuration: configuration,",
            "traceRuntime: traceRuntime,",
            "localDatabaseReplacementObserver: localDatabaseReplacementObserver",
            ")",
        ].joined(separator: " ")

        #expect(!appDelegateSource.contains("traceRuntime = .fromEnvironment()"))
        #expect(appDelegateSource.contains("makeWorkspaceSQLiteDatastore(traceRuntime: traceRuntime)"))
        #expect(appDelegateSource.contains("workspaceSQLiteDatastore = sqliteDatastore"))
        #expect(appDelegateSource.contains("sqliteDatastore: sqliteDatastore"))
        #expect(appDelegateSource.contains("await store.loadCanonicalComposition()"))
        #expect(appDelegateSource.contains("await repoCacheStore.restoreAsync("))
        #expect(appDelegateSource.contains("await sidebarCacheStore.restoreAsync("))
        #expect(appDelegateSource.contains("await uiStateStore.restoreAsync("))
        #expect(!appDelegateSource.contains("workspaceSQLiteStoreBackend"))
        #expect(!appDelegateSource.contains("workspaceLocalSQLiteStoreBackend"))
        #expect(datastoreFactorySource.contains("WorkspaceSQLiteDatastoreConfiguration("))
        #expect(
            normalizedDatastoreFactorySource.contains(expectedDatastoreConstruction)
        )
    }

    @Test("topology rejection emits a bounded reason before flushing and stopping boot")
    func topologyRejectionEmitsBoundedReasonBeforeFlushingAndStoppingBoot() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let workspaceBootSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"),
            encoding: .utf8
        )
        let prepareFunction = try #require(
            workspaceBootSource.range(of: "private func bootPrepareDatabases() async")
        )
        let loadFunction = try #require(
            workspaceBootSource.range(
                of: "private func bootLoadCanonicalStore() async",
                range: prepareFunction.upperBound..<workspaceBootSource.endIndex
            )
        )
        let prepareBody = workspaceBootSource[prepareFunction.lowerBound..<loadFunction.lowerBound]
        let topologyRejectedBranch = try #require(prepareBody.range(of: "case .topologyRejected:"))
        let flush = try #require(prepareBody.range(of: "try? await traceRuntime.flush()"))
        let fatalStop = try #require(prepareBody.range(of: "preconditionFailure("))
        let topologyRejectedBody = prepareBody[topologyRejectedBranch.lowerBound..<flush.lowerBound]

        #expect(topologyRejectedBody.contains("await recordPaneTopologyPersistenceReason("))
        #expect(topologyRejectedBody.contains(".topologyNormalizationRejected"))
        #expect(topologyRejectedBody.contains("severity: .error"))
        #expect(flush.lowerBound < fatalStop.lowerBound)
    }

    @Test("boot injects feature SQLite adapter into inbox notification store")
    func bootInjectsFeatureSQLiteAdapterIntoInboxNotificationStore() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let appDelegateSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate.swift"),
            encoding: .utf8
        )
        let inboxBootSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/App/Boot/AppDelegate+InboxNotificationBoot.swift"),
            encoding: .utf8
        )

        #expect(appDelegateSource.contains("var workspaceSQLiteDatastore: WorkspaceSQLiteDatastoreActor?"))
        #expect(!appDelegateSource.contains("var workspaceLocalSQLiteStoreBackend"))
        #expect(!appDelegateSource.contains("var workspaceSQLiteStoreBackend"))
        #expect(inboxBootSource.contains("InboxNotificationSQLiteDatastoreAdapter("))
        #expect(inboxBootSource.contains("workspaceId: workspaceId"))
        #expect(inboxBootSource.contains("sqliteAdapter: sqliteAdapter"))
        #expect(!inboxBootSource.contains("workspaceLocalSQLiteStoreBackend"))
        #expect(!inboxBootSource.contains("InboxNotificationSQLiteRepository("))
        #expect(!inboxBootSource.contains("Legacy"))
        #expect(!inboxBootSource.contains("legacy"))
    }

    @Test("pre-boot reopen reports missing main-window dependencies without force-unwrapping them")
    func preBootReopenReportsMainWindowDependencies() throws {
        let delegate = AppDelegate()

        let missingDependencies = delegate.mainWindowCreationMissingDependencyNames()

        #expect(missingDependencies.contains("store"))
        #expect(missingDependencies.contains("executor"))
        #expect(missingDependencies.contains("workspaceSurfaceCoordinator"))
    }

    @Test("reopen window creation uses resolved dependencies")
    func reopenWindowCreationUsesResolvedDependencies() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let appDelegateSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate.swift"),
            encoding: .utf8
        )
        let mainWindowCreationSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/App/Boot/AppDelegate+MainWindowCreation.swift"
            ),
            encoding: .utf8
        )
        let showWindowFunction = try #require(
            appDelegateSource.range(of: "private func showOrCreateMainWindow()")
        )
        let helperFunction = try #require(
            mainWindowCreationSource.range(of: "func makeMainWindowController")
        )
        let terminationFunction = try #require(
            appDelegateSource.range(of: "func applicationShouldTerminate(_ sender")
        )
        let reopenFunctionBody = String(
            appDelegateSource[showWindowFunction.lowerBound..<terminationFunction.lowerBound]
        )
        let helperFunctionBody = String(mainWindowCreationSource[helperFunction.lowerBound...])

        #expect(reopenFunctionBody.contains("mainWindowCreationDependencies(caller:"))
        #expect(helperFunctionBody.contains("workspaceActionExecutor: dependencies.executor"))
        #expect(!helperFunctionBody.contains("scheduleSidebarVisibleWorktreesUpdate()"))
        #expect(!helperFunctionBody.contains("syncFilesystemRootsAndActivity()"))
        #expect(!reopenFunctionBody.contains("workspaceActionExecutor: executor"))
    }

    @Test("each main-window factory call owns a distinct live tab bar adapter")
    func mainWindowFactoryCreatesDistinctLiveTabBarAdapters() async {
        let atoms = makeTestAtomRegistry()
        let store = WorkspaceStore(
            identityAtom: atoms.core.workspaceIdentity,
            windowMemoryAtom: atoms.core.workspaceWindowMemory,
            repositoryTopologyAtom: atoms.core.workspaceRepositoryTopology,
            paneAtom: atoms.core.workspacePane,
            tabLayoutAtom: atoms.core.workspaceTabLayout,
            mutationCoordinator: atoms.core.workspaceMutationCoordinator
        )
        let viewRegistry = ViewRegistry()
        let appLifecycleStore = AppLifecycleAtom()
        let coordinator = WorkspaceSurfaceCoordinator(
            store: store,
            viewRegistry: viewRegistry,
            runtime: SessionRuntime(atom: atoms.core.sessionRuntime, store: store),
            surfaceManager: HarnessSurfaceManager(),
            terminalSurfaceCommandDispatcher: AppTerminalFixtureSurfaceCommands(),
            terminalSurfaceOperations: makeAppTerminalFixtureMountOperations(),
            runtimeRegistry: RuntimeRegistry(),
            windowLifecycleStore: atoms.core.windowLifecycle,
            appLifecycleStore: appLifecycleStore,
            ipcLifecycle: .testUnavailable,
            bridgePaneAttendance: atoms.bridgePaneAttendance
        )
        let applicationLifecycleMonitor = ApplicationLifecycleMonitor(
            appLifecycleStore: appLifecycleStore,
            windowLifecycleStore: atoms.core.windowLifecycle
        )
        let performanceTraceRecorder = AgentStudioPerformanceTraceRecorder(
            traceRuntime: AgentStudioTraceRuntime(
                configuration: AgentStudioTraceConfiguration.from(environment: [
                    "AGENTSTUDIO_TRACE_TAGS": "off",
                    "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                ])
            )
        )
        let delegate = AppDelegate()

        await withAsyncTestCoreAtoms(using: atoms.core) { _ in
            let commandDispatcher = CommandDispatcherFixtureConfiguration().makeDispatcher()
            let dependencies = AppDelegateMainWindowCreationDependencies(
                store: store,
                repoCache: atoms.core.repoCache,
                octiconLoader: makeTestOcticonLoader(),
                commandDispatcher: commandDispatcher,
                resolveCommandCapabilities: commandDispatcher.repoExplorerCommandPresentationSnapshot,
                executionOwnerIdentities: commandDispatcher.executionOwnerIdentities,
                synchronizeRuntimeFocus: { _ in },
                executor: WorkspaceActionExecutor(coordinator: coordinator, store: store),
                workspaceSurfaceCoordinator: coordinator,
                applicationLifecycleMonitor: applicationLifecycleMonitor,
                appLifecycleStore: appLifecycleStore,
                viewRegistry: viewRegistry,
                bridgePaneAttendance: atoms.bridgePaneAttendance,
                editorChooser: atoms.editorChooser,
                repoExplorerSidebarPrefs: atoms.repoExplorerSidebarPrefs,
                performanceTraceRecorder: performanceTraceRecorder,
                closeTransitionCoordinator: PaneCloseTransitionCoordinator()
            )
            let pane = store.createPane(title: "Materialized projection")
            store.appendTab(Tab(paneId: pane.id, name: "Materialized projection"))
            let firstController = delegate.makeMainWindowController(dependencies: dependencies)
            let reopenedController = delegate.makeMainWindowController(dependencies: dependencies)
            defer {
                (firstController.window?.contentViewController as? MainSplitViewController)?.shutdown()
                (reopenedController.window?.contentViewController as? MainSplitViewController)?.shutdown()
                firstController.close()
                reopenedController.close()
            }
            guard
                let firstAdapter = tabBarAdapterOwnedByWindowController(firstController),
                let reopenedAdapter = tabBarAdapterOwnedByWindowController(reopenedController),
                let firstProjection = firstAdapter.materializedProjections.first,
                let reopenedProjection = reopenedAdapter.materializedProjections.first
            else {
                Issue.record("Window controller did not materialize its tab-bar projection")
                return
            }

            firstController.windowWillClose(
                Notification(name: NSWindow.willCloseNotification, object: firstController.window)
            )

            #expect(ObjectIdentifier(firstAdapter) != ObjectIdentifier(reopenedAdapter))
            #expect(ObjectIdentifier(firstProjection) != ObjectIdentifier(reopenedProjection))
            #expect(firstProjection.freshness == .stopped)
            #expect(reopenedProjection.freshness != .stopped)
        }

        await coordinator.shutdown()
    }

    @Test("canonical boot exhaustively handles strict SQLite load results")
    func canonicalBootExhaustivelyHandlesStrictSQLiteLoadResults() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let workspaceBootSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"),
            encoding: .utf8
        )
        let workspaceStoreSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceStore.swift"
            ),
            encoding: .utf8
        )

        #expect(workspaceStoreSource.contains("func loadCanonicalComposition() async -> WorkspaceStoreLoadResult"))
        #expect(workspaceStoreSource.contains("case loaded(WorkspacePreparedCompositionAcceptance)"))
        #expect(
            workspaceStoreSource.contains("case initializedDefaultWorkspace(WorkspacePreparedCompositionAcceptance)"))
        #expect(workspaceStoreSource.contains("case failed(WorkspaceStoreLoadFailure)"))
        #expect(workspaceBootSource.contains("switch await store.loadCanonicalComposition()"))
        #expect(
            workspaceBootSource.contains(
                "case .loaded(let acceptance), .initializedDefaultWorkspace(let acceptance):"
            )
        )
        #expect(
            workspaceBootSource.contains(
                "acceptWorkspacePreparedContentMountCohort(acceptance.contentMountCohort)"
            )
        )
        #expect(workspaceBootSource.contains("case .failed(let failure):"))
        #expect(workspaceBootSource.contains("preconditionFailure(\"Workspace startup invariant violated:"))
        #expect(!workspaceBootSource.contains("restoreFromLegacyJSON"))
        #expect(!workspaceBootSource.contains("saveImportedLegacySnapshot"))
        #expect(!workspaceBootSource.contains("legacyImportStatus"))
        #expect(!workspaceBootSource.contains("WorkspaceLegacyArchiveCoordinator"))
    }

    @Test("authoritative core load installs topology before deferred topology replay")
    func authoritativeCoreLoadInstallsTopologyBeforeDeferredTopologyReplay() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let workspaceBootSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"),
            encoding: .utf8
        )
        let workspaceStoreSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceStore.swift"
            ),
            encoding: .utf8
        )
        let canonicalLoad = try #require(
            workspaceBootSource.range(of: "switch await store.loadCanonicalComposition()")
        )
        let deferredTopologyTask = try #require(
            workspaceBootSource.range(of: "initialTopologySyncTask = Task { @MainActor [weak self] in")
        )
        let initialReplay = try #require(
            workspaceBootSource.range(of: "await self.replayBootTopology(")
        )

        #expect(workspaceStoreSource.contains("loadAuthoritativeCoreSnapshot()"))
        #expect(workspaceStoreSource.contains("applyPreparedRepositoryTopology("))
        #expect(canonicalLoad.lowerBound < deferredTopologyTask.lowerBound)
        #expect(deferredTopologyTask.lowerBound < initialReplay.lowerBound)
        #expect(!workspaceBootSource.contains("repositoryTopologyLoadTask"))
    }

    @Test("persistence observation passes a real topology flush barrier before deferred repair")
    func persistenceObservationPrecedesDeferredTopologyRepair() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let workspaceBootSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"),
            encoding: .utf8
        )
        let startObserving = try #require(workspaceBootSource.range(of: "repositoryTopologyStore.startObserving()"))
        let flush = try #require(workspaceBootSource.range(of: "try await repositoryTopologyStore.flushAsync()"))
        let barrier = try #require(
            workspaceBootSource.range(of: "didPassInitialTopologyPersistenceBarrier = true")
        )
        let deferredLane = try #require(
            workspaceBootSource.range(
                of: "startDeferredRepositoryTopologyLaneIfRequested()",
                range: barrier.upperBound..<workspaceBootSource.endIndex
            )
        )

        #expect(startObserving.lowerBound < flush.lowerBound)
        #expect(flush.lowerBound < barrier.lowerBound)
        #expect(barrier.lowerBound < deferredLane.lowerBound)
        #expect(workspaceBootSource.contains(".topologyBootNormalizationFlushFailed"))
        #expect(workspaceBootSource.contains("await self.repairUnavailableRepositoriesMissingMain()"))
        #expect(workspaceBootSource.contains("RepoScanner().scan(in: repository.repoPath, maxDepth: 0)"))
    }

    @Test("topology flush failure suppresses repair but preserves independent boot work")
    func topologyFlushFailureSuppressesRepairButPreservesIndependentBootWork() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let workspaceBootSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"),
            encoding: .utf8
        )
        let barrierFailure = try #require(
            workspaceBootSource.range(of: "didPassInitialTopologyPersistenceBarrier = false")
        )
        let boundedReason = try #require(
            workspaceBootSource.range(
                of: ".topologyBootNormalizationFlushFailed",
                range: barrierFailure.upperBound..<workspaceBootSource.endIndex
            )
        )
        let cacheObservation = try #require(
            workspaceBootSource.range(
                of: "repoCacheStore.startObserving()",
                range: boundedReason.upperBound..<workspaceBootSource.endIndex
            )
        )
        let cachePrune = try #require(
            workspaceBootSource.range(
                of: "if pruneStaleCache(store: store, repoCache: repoCache)",
                range: cacheObservation.upperBound..<workspaceBootSource.endIndex
            )
        )

        #expect(workspaceBootSource.contains("didPassInitialTopologyPersistenceBarrier"))
        #expect(workspaceBootSource.contains("else { return }"))
        #expect(barrierFailure.lowerBound < boundedReason.lowerBound)
        #expect(boundedReason.lowerBound < cacheObservation.lowerBound)
        #expect(cacheObservation.lowerBound < cachePrune.lowerBound)
    }

    @Test("exact-root repair preserves existing identities and linked worktrees")
    func exactRootRepairPreservesExistingTopologyIdentity() throws {
        // Arrange
        let repositoryID = UUIDv7.generate()
        let rootWorktreeID = UUIDv7.generate()
        let linkedWorktreeID = UUIDv7.generate()
        let repositoryPath = URL(filePath: "/tmp/agentstudio-boot-repair")
        let linkedPath = URL(filePath: "/tmp/agentstudio-boot-repair-linked")
        let repository = Repo(
            id: repositoryID,
            name: "agentstudio-boot-repair",
            repoPath: repositoryPath,
            worktrees: [
                Worktree(
                    id: rootWorktreeID,
                    repoId: repositoryID,
                    name: "stale-root-name",
                    path: repositoryPath,
                    isMainWorktree: false
                ),
                Worktree(
                    id: linkedWorktreeID,
                    repoId: repositoryID,
                    name: "linked",
                    path: linkedPath,
                    isMainWorktree: true
                ),
            ]
        )
        let scan = authoritativeScan(
            entries: [
                RepoScanner.ResolvedGitEntry(
                    path: repositoryPath,
                    kind: .cloneRoot,
                    repositoryKey: "boot-repair"
                )
            ]
        )

        // Act
        let repairedWorktrees = try #require(
            AppDelegate.repairedWorktrees(for: repository, from: scan)
        )

        // Assert
        let repairedRoot = try #require(repairedWorktrees.first(where: { $0.id == rootWorktreeID }))
        let preservedLinked = try #require(repairedWorktrees.first(where: { $0.id == linkedWorktreeID }))
        #expect(repairedRoot.path == repositoryPath)
        #expect(repairedRoot.name == repositoryPath.lastPathComponent)
        #expect(repairedRoot.isMainWorktree)
        #expect(preservedLinked.path == linkedPath)
        #expect(!preservedLinked.isMainWorktree)
        #expect(
            AppDelegate.hasValidMainWorktree(
                Repo(
                    id: repositoryID,
                    name: repository.name,
                    repoPath: repositoryPath,
                    worktrees: repairedWorktrees
                )))
    }

    @Test("exact-root repair creates one UUIDv7 root only from authoritative clone evidence")
    func exactRootRepairRequiresAuthoritativeCloneEvidence() throws {
        // Arrange
        let repositoryID = UUIDv7.generate()
        let repositoryPath = URL(filePath: "/tmp/agentstudio-boot-repair-new-root")
        let linkedPath = URL(filePath: "/tmp/agentstudio-boot-repair-new-root-linked")
        let linkedWorktreeID = UUIDv7.generate()
        let repository = Repo(
            id: repositoryID,
            name: repositoryPath.lastPathComponent,
            repoPath: repositoryPath,
            worktrees: [
                Worktree(
                    id: linkedWorktreeID,
                    repoId: repositoryID,
                    name: "linked",
                    path: linkedPath,
                    note: "linked note survives"
                )
            ]
        )
        let acceptedScan = authoritativeScan(
            entries: [
                RepoScanner.ResolvedGitEntry(
                    path: repositoryPath,
                    kind: .cloneRoot,
                    repositoryKey: "new-root"
                )
            ]
        )
        let mismatchedScan = authoritativeScan(
            entries: [
                RepoScanner.ResolvedGitEntry(
                    path: repositoryPath.appending(path: "nested"),
                    kind: .cloneRoot,
                    repositoryKey: "mismatch"
                )
            ]
        )
        let linkedOnlyScan = authoritativeScan(
            entries: [
                RepoScanner.ResolvedGitEntry(
                    path: repositoryPath,
                    kind: .linkedWorktree(parentClonePath: linkedPath),
                    repositoryKey: "linked-only"
                )
            ]
        )

        // Act
        let repairedWorktrees = try #require(
            AppDelegate.repairedWorktrees(for: repository, from: acceptedScan)
        )

        // Assert
        let createdRoot = try #require(repairedWorktrees.filter(\.isMainWorktree).single)
        let preservedLinked = try #require(repairedWorktrees.first(where: { $0.id == linkedWorktreeID }))
        #expect(UUIDv7.isV7(createdRoot.id))
        #expect(createdRoot.path == repositoryPath)
        #expect(!preservedLinked.isMainWorktree)
        #expect(preservedLinked.note == "linked note survives")
        #expect(AppDelegate.repairedWorktrees(for: repository, from: mismatchedScan) == nil)
        #expect(AppDelegate.repairedWorktrees(for: repository, from: linkedOnlyScan) == nil)
        #expect(
            AppDelegate.repairedWorktrees(
                for: repository,
                from: .cancelled(
                    CancelledRepoScan(
                        verifiedEntries: [],
                        counts: emptyRepoScannerEvidenceCounts,
                        serviceMetrics: .zero
                    )
                )
            ) == nil
        )
    }

    @Test("termination checks workspace flush success before shutdown completes")
    func terminationChecksWorkspaceFlushSuccessBeforeShutdownCompletes() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let terminationSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Boot/AppDelegate+Termination.swift"),
            encoding: .utf8
        )

        #expect(terminationSource.contains("workspaceSettingsStore.flush(for: store.identityAtom.workspaceId)"))
        #expect(terminationSource.contains("if !(await store.flushAsync()).succeeded"))
        #expect(terminationSource.contains("Workspace flush failed at termination"))
    }

    @Test("scoped pane topology recovery paths contain no traps or force unwraps")
    func scopedPaneTopologyRecoveryPathsContainNoTrapsOrForceUnwraps() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let relativePaths = [
            "Sources/AgentStudio/Core/Models/PaneFilesystemLocationPolicy.swift",
            "Sources/AgentStudio/Core/State/MainActor/Atoms/RepositoryTopologyAtom.swift",
            "Sources/AgentStudio/Core/State/MainActor/Coordination/RepositoryTopologyReplacement.swift",
            "Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspacePersistenceTransformer.swift",
            "Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceSQLiteStoreBackend.swift",
            "Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceSQLiteStoreBackend+Datastore.swift",
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: projectRoot.appending(path: relativePath),
                encoding: .utf8
            )
            #expect(!source.contains("preconditionFailure("), "Unexpected trap in \(relativePath)")
            #expect(!source.contains("fatalError("), "Unexpected fatal error in \(relativePath)")
            #expect(!source.contains("try!"), "Unexpected forced try in \(relativePath)")
        }
    }

    @Test("dormant Inbox boot is not composed into application startup")
    func dormantInboxBootIsNotComposedIntoApplicationStartup() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let inboxBootSourceURL = projectRoot.appending(
            path: "Sources/AgentStudio/App/Boot/AppDelegate+InboxNotificationBoot.swift"
        )
        let appDelegateSource = try String(
            contentsOf: inboxBootSourceURL,
            encoding: .utf8
        )

        #expect(appDelegateSource.contains("Inbox presentation and ingestion are intentionally retired"))

        let workspaceBootSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/App/Boot/AppDelegate+WorkspaceBoot.swift"
            ),
            encoding: .utf8
        )
        #expect(!workspaceBootSource.contains("bootLoadInboxNotificationStore()"))
        #expect(!workspaceBootSource.contains("bootStartInboxNotificationRouter"))
    }

    @Test("production code avoids generic clock-based sleep overloads")
    func productionCodeAvoidsGenericClockBasedSleep() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let sourceRoot = projectRoot.appending(path: "Sources/AgentStudio")
        let sourceFiles =
            FileManager.default
            .enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        var offenders: [String] = []

        for sourceFile in sourceFiles {
            let relativePath = sourceFile.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
            guard relativePath != "Sources/AgentStudio/Infrastructure/Extensions/FoundationExtensions.swift" else {
                continue
            }
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            for (lineIndex, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where Self.isGenericClockSleep(line) {
                offenders.append("\(relativePath):\(lineIndex + 1): \(line)")
            }
        }

        #expect(
            offenders.isEmpty,
            """
            macOS 26.4 release startup reproduced swift_task_dealloc crashes in the \
            generic clock-based sleep path. Use Duration.nanosecondsForTaskSleep \
            with Task.sleep(nanoseconds:) for production sleeps instead.

            \(offenders.joined(separator: "\n"))
            """
        )
    }

    private static func isGenericClockSleep(_ line: Substring) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard !trimmedLine.hasPrefix("//") else { return false }
        return trimmedLine.contains("Task.sleep(for:")
            || trimmedLine.contains(".sleep(for:")
    }
}

private let emptyRepoScannerEvidenceCounts = RepoScannerEvidenceCounts(
    directoryVisitCount: 0,
    directoryTraversalFailureCount: 0,
    entryMetadataFailureCount: 0,
    gitCandidateCount: 0,
    validationSuccessCount: 0,
    validationAuthoritativeNegativeCount: 0,
    validationTimeoutCount: 0,
    validationCancellationCount: 0,
    validationFailureCount: 0,
    scannerServiceInvocationCount: 0
)

private func authoritativeScan(entries: [RepoScanner.ResolvedGitEntry]) -> RepoScannerResult {
    .completeAuthoritative(
        CompleteRepoScan(
            verifiedEntries: entries,
            counts: emptyRepoScannerEvidenceCounts,
            serviceMetrics: .zero
        )
    )
}

@MainActor
private func tabBarAdapterOwnedByWindowController(
    _ windowController: MainWindowController
) -> TabBarAdapter? {
    guard
        let splitViewController = windowController.window?.contentViewController
            as? MainSplitViewController
    else {
        return nil
    }
    splitViewController.loadViewIfNeeded()
    guard
        let paneTabViewController = splitViewController.splitViewItems
            .compactMap({ $0.viewController as? PaneTabViewController })
            .first
    else {
        return nil
    }
    return paneTabViewController.makeTabBarHostingView().tabBarAdapter
}
