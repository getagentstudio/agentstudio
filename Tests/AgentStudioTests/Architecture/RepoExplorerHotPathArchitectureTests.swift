import Foundation
import Testing

@testable import AgentStudioTestSupport

@Suite("RepoExplorerHotPathArchitectureTests")
struct RepoExplorerHotPathArchitectureTests {
    @Test("Repo Explorer repository activity admission carries stable keys without fleet searches")
    func repositoryActivityAdmissionCarriesStableKeysWithoutFleetSearches() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let featureRoot = projectRoot.appending(
            path: "Sources/AgentStudio/Features/RepoExplorer"
        )
        let observationSource = try String(
            contentsOf: featureRoot.appending(
                path: "RepoExplorerProjectionInputCapture+Observation.swift"
            ),
            encoding: .utf8
        )
        let captureSource = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerProjectionInputCapture.swift"),
            encoding: .utf8
        )
        let observationActivitySlice = try #require(
            observationSource.repoExplorerSlice(
                from: "        case .repositoryActivity",
                to: "    func observationTokens"
            )
        )
        let captureActivitySlice = try #require(
            captureSource.repoExplorerSlice(
                from: "    private func captureRepositoryActivity(",
                to: "    private func captureRepositoryChange("
            )
        )

        #expect(
            observationSource.contains(
                "case repositoryActivity(repositoryID: UUID, stableKey: String)"
            )
        )
        #expect(!observationActivitySlice.contains("snapshot.repos.first(where:"))
        #expect(!captureActivitySlice.contains("snapshot.repos.first(where:"))
    }

    @Test("Repo Explorer observes stable identity without reading identity maps")
    func observesStableIdentityRevisionWithoutIdentityMapReads() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let observationSource = try String(
            contentsOf: projectRoot.appending(
                path:
                    "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionInputCapture+Observation.swift"
            ),
            encoding: .utf8
        )
        let stableIdentitySlice = try #require(
            observationSource.repoExplorerSlice(
                from: "        case .stableIdentity:",
                to: "        case .repository"
            )
        )

        #expect(stableIdentitySlice.contains("repositoryTopologyAtom.stableIdentityRevision"))
        #expect(!stableIdentitySlice.contains("repositoryStableKeysByID"))
        #expect(!stableIdentitySlice.contains("worktreeStableKeysByID"))
        #expect(!stableIdentitySlice.contains("watchedPathStableKeysByID"))
    }

    @Test("RepoExplorer model files are pure and do not read atoms")
    func repoExplorerModelFilesDoNotReadAtoms() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let modelsDirectory = projectRoot.appending(path: "Sources/AgentStudio/Features/RepoExplorer/Models")
        let modelFiles = try FileManager.default.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }

        #expect(modelFiles.map(\.lastPathComponent).contains("RepoExplorerSnapshot.swift"))
        #expect(modelFiles.map(\.lastPathComponent).contains("RepoExplorerProjection.swift"))
        #expect(modelFiles.map(\.lastPathComponent).contains("RepoExplorerRowIndex.swift"))
        #expect(modelFiles.map(\.lastPathComponent).contains("RepoExplorerProjectionWorker.swift"))

        for file in modelFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("atom("), "\(file.lastPathComponent) must stay free of atom reads")
        }
    }

    @Test("Repo Explorer row identity is typed and constructed before MainActor publication")
    func repoExplorerRowIdentityIsTypedAndWorkerOwned() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let identitySource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerRowIdentity.swift"
            ),
            encoding: .utf8
        )
        let listEntrySource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerListEntry.swift"
            ),
            encoding: .utf8
        )
        let workerSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerProjectionWorker.swift"
            ),
            encoding: .utf8
        )
        let adapterSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionAdapter.swift"
            ),
            encoding: .utf8
        )

        #expect(identitySource.contains("enum RepoExplorerRowID: Hashable, Sendable"))
        #expect(!identitySource.contains("uuidString"))
        #expect(!identitySource.contains("\\("))
        #expect(listEntrySource.contains("var id: RepoExplorerRowID"))
        #expect(!listEntrySource.contains("var id: String"))
        #expect(adapterSource.contains("case unresolved(RepoExplorerRowID)"))
        #expect(!adapterSource.contains("case unresolved(String)"))
        #expect(workerSource.contains("RepoExplorerMaterializationSnapshot.build("))
        #expect(!adapterSource.contains("uuidString"))

        // The current View's previous/next row-ID arrays remain explicitly deferred to Slice 11.
        // This slice proves only that new identity construction/materialization stays off MainActor.
    }

    @Test("Repo Explorer materialization requires a registered acknowledged host")
    func repoExplorerMaterializationRequiresRegisteredAcknowledgedHost() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let brokerSource = try String(
            contentsOf: projectRoot.appending(
                path:
                    "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionAdapter+MaterializationBroker.swift"
            ),
            encoding: .utf8
        )

        #expect(!brokerSource.contains("SLICE-11-CUTOVER"))
        #expect(!brokerSource.contains("guard materializationHost == nil"))
        #expect(!brokerSource.contains("return .immediateAccepted(result)"))
        #expect(brokerSource.contains("return .equalCurrent(result)"))
        #expect(brokerSource.contains("let acknowledgedMaterializationBaseline,"))
    }

    @Test("Repo Explorer native plans remain inseparable through the sole production applier")
    func repoExplorerNativePlanTransportHasOneOwnerAndNoRediff() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let featureRoot = projectRoot.appending(
            path: "Sources/AgentStudio/Features/RepoExplorer"
        )
        let hostModels = try String(
            contentsOf: featureRoot.appending(path: "Models/RepoExplorerMaterializationHostModels.swift"),
            encoding: .utf8
        )
        let broker = try String(
            contentsOf: featureRoot.appending(
                path: "RepoExplorerProjectionAdapter+MaterializationBroker.swift"
            ),
            encoding: .utf8
        )
        let host = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerMaterializationHost.swift"),
            encoding: .utf8
        )
        let applier = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerNativeTransactionApplier.swift"),
            encoding: .utf8
        )
        let productionSources = try FileManager.default.contentsOfDirectory(
            at: featureRoot,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")

        #expect(hostModels.contains("let nativeUpdatePlan: RepoExplorerNativeUpdatePlan"))
        #expect(hostModels.contains("struct RepoExplorerMaterializationContentCandidate"))
        #expect(hostModels.contains("let tableUpdatePlan: RepoExplorerNativeTableUpdatePlan"))
        #expect(hostModels.contains("func apply(\n        _ candidate: RepoExplorerMaterializationContentCandidate"))
        #expect(broker.contains("nativeUpdatePlan: nativeUpdatePlan"))
        #expect(!broker.contains("RepoExplorerNativeUpdatePlan.validating"))
        #expect(!host.contains("RepoExplorerNativeUpdatePlan.validating"))
        #expect(!host.contains("longestCommonSubsequence"))
        #expect(applier.components(separatedBy: "enum RepoExplorerNativeTransactionApplier").count == 2)
        #expect(
            productionSources.components(
                separatedBy: "enum RepoExplorerNativeTransactionApplier"
            ).count == 2
        )
    }

    @Test("native table materialization consumes worker plans without fleet derivation or fallback reload")
    func nativeTableMaterializationStaysBoundedToRepresentedRows() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let featureRoot = projectRoot.appending(
            path: "Sources/AgentStudio/Features/RepoExplorer"
        )
        let materializer = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerTableMaterializer.swift"),
            encoding: .utf8
        )
        let nativePlan = try String(
            contentsOf: featureRoot.appending(path: "Models/RepoExplorerNativeUpdatePlan.swift"),
            encoding: .utf8
        )

        #expect(materializer.contains("RepoExplorerNativeTransactionApplier.apply("))
        #expect(materializer.contains("pendingReloadRows.intersection(represented)"))
        #expect(
            materializer.contains(
                "tableView.noteHeightOfRows(withIndexesChanged: pendingHeightRows)"
            )
        )
        #expect(materializer.contains("membership.anchorFallbacks.targetRowID("))
        #expect(nativePlan.contains("private static func makeAnchorFallbacks("))
        #expect(!materializer.contains("tableView.reloadData()"))
        #expect(!materializer.contains("RepoExplorerNativeUpdatePlan.validating"))
        #expect(!materializer.contains("longestCommonSubsequence"))
        #expect(!materializer.contains("RepoExplorerVisibleRowsBridge"))
        #expect(!materializer.contains("enclosingScrollView"))
        #expect(!materializer.contains("projectionAdapter"))
        #expect(!materializer.contains("atom("))
        #expect(!materializer.contains("snapshot.rows.map"))
        #expect(!materializer.contains("snapshot.rows.filter"))
        #expect(!materializer.contains("snapshot.rows.enumerated"))
        #expect(!materializer.contains("for row in snapshot.rows"))
    }

    @Test("native table owns Repo Explorer contextual-menu lifetime")
    func nativeTableOwnsContextMenuLifetime() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let featureRoot = projectRoot.appending(
            path: "Sources/AgentStudio/Features/RepoExplorer"
        )
        let materializer = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerTableMaterializer.swift"),
            encoding: .utf8
        )
        let presenter = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerContextMenuPresenter.swift"),
            encoding: .utf8
        )
        let renderer = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerMaterializedRowView.swift"),
            encoding: .utf8
        )
        let worktreeRow = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerWorktreeRow.swift"),
            encoding: .utf8
        )

        #expect(materializer.contains("let tableView = RepoExplorerTableView()"))
        #expect(!materializer.contains("package let tableView"))
        #expect(!materializer.contains("public let tableView"))
        #expect(materializer.contains("contextMenuPresenter?.makeMenu("))
        #expect(presenter.contains("override func menu(for event: NSEvent) -> NSMenu?"))
        #expect(presenter.contains("isRowCurrent(rowID)"))
        #expect(!materializer.contains("NSMenu.didBeginTrackingNotification"))
        #expect(!materializer.contains("NSMenu.didEndTrackingNotification"))
        #expect(!renderer.contains(".contextMenu {"))
        #expect(!worktreeRow.contains(".contextMenu {"))
    }

    @Test("production presentation host is the sole live Repo Explorer row owner")
    func productionPresentationHostIsStableAndOwnsTheLiveTree() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let featureRoot = projectRoot.appending(
            path: "Sources/AgentStudio/Features/RepoExplorer"
        )
        let presentationHost = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerPresentationHostView.swift"),
            encoding: .utf8
        )
        let repoExplorerView = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerView.swift"),
            encoding: .utf8
        )
        let updateBody = try #require(
            presentationHost.components(separatedBy: "    func updateNSView(").dropFirst().first?
                .components(separatedBy: "    static func dismantleNSView(").first
        )
        let dismantleBody = try #require(
            presentationHost.components(separatedBy: "        func dismantle(").dropFirst().first?
                .components(separatedBy: "\n        }").first
        )

        #expect(presentationHost.contains("RepoExplorerMaterializationHost("))
        #expect(presentationHost.contains("RepoExplorerTableMaterializer("))
        #expect(presentationHost.contains("registerMaterializationHost(host)"))
        #expect(presentationHost.contains("unregisterMaterializationHost("))
        #expect(
            try #require(dismantleBody.range(of: "unregisterMaterializationHost")).lowerBound
                < #require(dismantleBody.range(of: "materializationHost.detach()")).lowerBound
        )
        #expect(!updateBody.contains("makeHost"))
        #expect(!updateBody.contains("registerMaterializationHost"))
        #expect(!updateBody.contains("rows"))
        #expect(repoExplorerView.contains("RepoExplorerPresentationHostView("))
        #expect(!repoExplorerView.contains("List {"))
        #expect(!repoExplorerView.contains("ForEach(rowIndex.entries)"))
        #expect(!repoExplorerView.contains("RepoExplorerVisibleRowsBridge("))
        #expect(!repoExplorerView.contains("previousRowIDs"))
        #expect(!repoExplorerView.contains("nextRowIDs"))
        #expect(!repoExplorerView.contains("measureOutlineApplyProxy"))
        #expect(!repoExplorerView.contains("currentProjection.emptyState != .content"))
    }

    @Test("hosted row cells keep one root and accept only injected command presentation")
    func hostedRowCellsArePersistentBoundedAndCommandInjected() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let featureRoot = projectRoot.appending(
            path: "Sources/AgentStudio/Features/RepoExplorer"
        )
        let cell = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerTableRowCell.swift"),
            encoding: .utf8
        )
        let renderer = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerMaterializedRowView.swift"),
            encoding: .utf8
        )
        let table = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerTableMaterializer.swift"),
            encoding: .utf8
        )
        let repoExplorerView = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerView.swift"),
            encoding: .utf8
        )
        let hostedSources = cell + renderer

        #expect(cell.components(separatedBy: "NSHostingView(").count == 2)
        #expect(cell.contains(".id(binding.identity.rowID)"))
        #expect(cell.contains("guard currentBindingIdentity == identity"))
        #expect(cell.contains("commandPresentationSnapshot.generation == commandGeneration"))
        #expect(!cell.contains("rootView ="))
        #expect(table.contains("tableView.makeView("))
        #expect(table.contains("rebindRepresentedCells()"))
        #expect(table.contains("delta.target == currentVisibleSnapshot.target"))
        #expect(table.contains("makeIfNecessary: false"))
        #expect(table.contains("snapshot.rowIDsByWorktreeID"))
        #expect(table.contains("snapshot.rowIDsByRepoID"))
        #expect(!table.contains("snapshot.rows.map"))
        #expect(!renderer.contains("worktree.repo.isPinned"))
        #expect(repoExplorerView.contains("RepoExplorerPresentationHostView("))
        #expect(renderer.contains("onToggleGroup(group.groupID)"))
        #expect(renderer.contains("onFocusPane(pane.destination.paneId)"))
        for forbidden in [
            "atom(",
            "RepoCache",
            "RepoExplorerProjectionAdapter",
            "RepoExplorerView",
            "AppCommandDispatcher",
            "repoExplorerCommandPresentationSnapshot(",
        ] {
            #expect(!hostedSources.contains(forbidden))
        }
        for presentationCase in [
            ".sectionHeader",
            ".loadingSectionHeader",
            ".loadingRepository",
            ".groupHeader",
            ".worktree",
            ".pane",
            ".unassociatedPane",
            ".topologyFault",
            ".unresolved",
        ] {
            #expect(renderer.contains("case \(presentationCase)"))
        }
    }

    @Test("RepoExplorerView delegates row materialization to the persistent host")
    func repoExplorerViewDelegatesRowsToPersistentHost() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("RepoExplorerProjectionAdapter("))
        #expect(source.contains("RepoExplorerPresentationHostView("))
        #expect(!source.contains("private var currentRowIndex"))
        #expect(!source.contains("private var groupList"))
        #expect(!source.contains("ForEach(rowIndex.entries)"))
        #expect(!source.contains("private var sidebarProjection: SidebarProjection"))
        #expect(!source.contains("private var sidebarRowIndex: RepoExplorerRowIndex"))
        #expect(!source.contains("private func resolvedWorktreeContext("))
        #expect(!source.contains(".id(sidebarProjectionFingerprint)"))
    }

    @Test("Repo Explorer MainActor adapter performs only constant-time candidate currentness checks")
    func repoExplorerAdapterDoesNotTraverseProjectionFleets() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let featureRoot = projectRoot.appending(
            path: "Sources/AgentStudio/Features/RepoExplorer"
        )
        let adapterSource = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerProjectionAdapter.swift"),
            encoding: .utf8
        )
        let brokerSource = try String(
            contentsOf: featureRoot.appending(
                path: "RepoExplorerProjectionAdapter+MaterializationBroker.swift"
            ),
            encoding: .utf8
        )
        let intentSource = try String(
            contentsOf: featureRoot.appending(
                path: "Models/RepoExplorerProjectionIntent.swift"
            ),
            encoding: .utf8
        )
        let mainActorCurrentnessSources = adapterSource + brokerSource

        for forbidden in [
            "request.snapshot ==",
            "result.snapshot ==",
            "hasEqualRenderedContent",
            "renderedRows(in:",
            "RepoExplorerProjectionStructuralTarget(result:",
        ] {
            #expect(!mainActorCurrentnessSources.contains(forbidden))
        }
        #expect(!intentSource.contains("pendingDelta.structuralTarget == latestDelta.structuralTarget"))
        #expect(brokerSource.contains("case .equal = nativeUpdatePlan.kind"))
        #expect(brokerSource.contains("return .equalCurrent(result)"))
        #expect(brokerSource.contains("stage: \"materialize\""))
        #expect(brokerSource.contains("outcome: \"materialized\""))
    }

    @Test("projection adapter owns demand observation capture and deadlines")
    func projectionAdapterOwnsTheCompleteInputLifecycle() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift"),
            encoding: .utf8
        )
        let adapterSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionAdapter.swift"
            ),
            encoding: .utf8
        )
        let adapterInputLifecycleSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionAdapter+InputLifecycle.swift"
            ),
            encoding: .utf8
        )
        let completeAdapterSource = adapterSource + adapterInputLifecycleSource
        let captureSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionInputCapture.swift"
            ),
            encoding: .utf8
        )
        let sidebarHostSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/App/Windows/SidebarSurfaceHost.swift"
            ),
            encoding: .utf8
        )

        #expect(!source.contains(".onChange(of: projectionRequestKey)"))
        #expect(!source.contains("withObservationTracking"))
        #expect(!source.contains("private func observeProjectionInputs("))
        #expect(completeAdapterSource.contains("withObservationTracking"))
        #expect(completeAdapterSource.contains("func updateDemand("))
        #expect(completeAdapterSource.contains("func suspendDemand()"))
        #expect(completeAdapterSource.contains("RepoExplorerObservationRegistration"))
        #expect(completeAdapterSource.contains("scheduleRecencyDeadline"))
        #expect(completeAdapterSource.contains("RepoExplorerPendingInvalidation"))
        #expect(completeAdapterSource.contains("registerObservation("))
        #expect(!source.contains("projectionInputRevision"))
        #expect(!source.contains("private var projectionRequest:"))
        #expect(!source.contains("private func startProjectionObservation"))
        #expect(!source.contains("private func captureProjectionInputs"))
        #expect(!source.contains("@State private var projectionGeneration"))
        #expect(!source.contains("@State private var cachedProjectionRequest"))
        #expect(!source.contains("@State private var recencyDeadlineTask"))
        #expect(!source.contains("let request = withObservationTracking"))
        #expect(captureSource.contains("repoCache.isPullRequestLoading(forRepository: repositoryID)"))
        #expect(captureSource.contains("repoCache.isPullRequestDataUnavailable(forRepository: repositoryID)"))
        #expect(!source.contains("repoCache.loadingPullRequestRepoIds"))
        #expect(!source.contains("repoCache.unavailablePullRequestRepoIds"))
        #expect(!source.contains("paneRecencyDisplayCadence"))
        #expect(!source.contains("while !Task.isCancelled"))
        #expect(completeAdapterSource.contains("admitDelta("))
        #expect(completeAdapterSource.contains("stage: \"affected_row\""))
        #expect(captureSource.contains("coreAtoms.paneActivityTime.value(for: paneID)"))
        #expect(source.contains(".onChange(of: filterText)"))
        #expect(source.contains("projectionAdapter.updateDemand("))
        #expect(sidebarHostSource.contains("isProjectionDemanded: !sidebarState.sidebarCollapsed"))
    }

    @Test("Repo Explorer capture consumes stored topology identity")
    func repoExplorerCaptureConsumesStoredTopologyIdentity() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let captureSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionInputCapture.swift"
            ),
            encoding: .utf8
        )
        let presentationSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/Core/Models/RepoPresentation.swift"),
            encoding: .utf8
        )
        let rowIndexSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerRowIndex.swift"
            ),
            encoding: .utf8
        )

        let sidebarReposBody = try #require(
            captureSource.repoExplorerSlice(
                from: "private func sidebarRepos() -> [RepoPresentationItem]",
                to: "func makeSidebarSnapshot("
            )
        )
        let repoInitializerBody = try #require(
            presentationSource.repoExplorerSlice(
                from: "package init(\n        repo: Repo,",
                to: "package struct RepoIdentityMetadata"
            )
        )

        #expect(sidebarReposBody.contains("repositoryStableKey(for:"))
        #expect(sidebarReposBody.contains("worktreeStableKeysByID"))
        #expect(!repoInitializerBody.contains("repo.stableKey"))
        #expect(!rowIndexSource.contains("worktree.stableKey"))
        for source in [sidebarReposBody, repoInitializerBody, rowIndexSource] {
            #expect(!source.contains("StableKey.fromPath"))
            #expect(!source.contains("resolvingSymlinksInPath"))
            #expect(!source.contains("FileManager"))
        }
    }

    @Test("projection inputs exclude removed Repo Explorer visibility semantics")
    func projectionInputsExcludeRemovedRepoExplorerVisibilitySemantics() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let repoExplorerViewSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift"),
            encoding: .utf8
        )
        let repoExplorerViewHelperSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+ProjectionHelpers.swift"
            ),
            encoding: .utf8
        )
        let performanceMetricsSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioOTLPPerformanceMetrics.swift"),
            encoding: .utf8
        )
        let snapshotSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerSnapshot.swift"
            ),
            encoding: .utf8
        )
        let commandPresentationSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerCommandPresentation.swift"
            ),
            encoding: .utf8
        )

        #expect(repoExplorerViewHelperSource.contains("previous.snapshot.groupingMode != next.snapshot.groupingMode"))
        #expect(repoExplorerViewHelperSource.contains("previous.snapshot.sortOrder != next.snapshot.sortOrder"))
        for source in [
            repoExplorerViewSource,
            repoExplorerViewHelperSource,
            performanceMetricsSource,
            snapshotSource,
            commandPresentationSource,
        ] {
            #expect(!source.contains("RepoExplorerVisibilityMode"))
            #expect(!source.contains("visibilityMode"))
            #expect(!source.contains("setRepoSidebarVisibilityMode"))
        }
    }

    @Test("repo rows render from cached projection facts instead of recomputing all worktree status")
    func repoRowsRenderFromCachedProjectionFacts() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let repoExplorerViewSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift"),
            encoding: .utf8
        )
        let projectionWorkerSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerProjectionWorker.swift"),
            encoding: .utf8
        )
        let materializationSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerMaterializationSnapshot.swift"
            ),
            encoding: .utf8
        )
        let rendererSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerMaterializedRowView.swift"
            ),
            encoding: .utf8
        )

        #expect(!repoExplorerViewSource.contains("private var worktreeStatusById"))
        #expect(!repoExplorerViewSource.contains("private func branchName(for worktree: Worktree)"))
        #expect(!repoExplorerViewSource.contains("branchStatusByWorktreeId"))
        #expect(!repoExplorerViewSource.contains("branchNameByWorktreeId"))
        #expect(materializationSource.contains("branchStatus: inputs.branchStatusByWorktreeID"))
        #expect(materializationSource.contains("branchName: inputs.branchNameByWorktreeID"))
        #expect(rendererSource.contains("branchStatus: worktree.branchStatus"))
        #expect(rendererSource.contains("branchName: worktree.branchName"))
        #expect(projectionWorkerSource.contains("branchStatusByWorktreeId"))
        #expect(projectionWorkerSource.contains("branchNameByWorktreeId"))
    }

    @Test("pane rows render only immutable worker projection values")
    func paneRowsRenderOnlyImmutableWorkerProjectionValues() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let rowSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerPaneNavigation.swift"
            ),
            encoding: .utf8
        )
        let helperSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+ProjectionHelpers.swift"
            ),
            encoding: .utf8
        )
        let workerSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerProjectionWorker.swift"
            ),
            encoding: .utf8
        )

        #expect(rowSource.contains("let row: RepoExplorerProjectedPaneRow"))
        #expect(!rowSource.contains("atom("))
        #expect(!helperSource.contains("atom(\\.paneDisplay)"))
        #expect(workerSource.contains("paneRowFactsByPaneId"))
        // The source contract proves projection stays off MainActor.
        // swiftlint:disable:next no_task_detached
        #expect(workerSource.contains("Task.detached(priority: .userInitiated)"))
    }

    @Test("repo pinned rows read the current App-owned command delta")
    func repoPinnedRowsReadCurrentCommandDelta() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let repoExplorerViewSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift"),
            encoding: .utf8
        )
        let rendererSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerMaterializedRowView.swift"
            ),
            encoding: .utf8
        )

        #expect(!repoExplorerViewSource.contains("repositoryTopologyAtom.repo"))
        #expect(rendererSource.contains("commandPresentationSnapshot.pinnedStateByRepositoryID"))
        #expect(rendererSource.contains("isPinned: isPinned"))
    }

    @Test("repo pinned mutations enter through targeted app commands")
    func repoPinnedMutationsEnterThroughTargetedAppCommands() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let rendererSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerMaterializedRowView.swift"
            ),
            encoding: .utf8
        )

        #expect(!rendererSource.contains("repositoryTopologyAtom.setRepoPinned"))
        #expect(rendererSource.contains(".pinRepo"))
        #expect(rendererSource.contains(".unpinRepo"))
        #expect(rendererSource.contains("onCommandRequest(request)"))
    }

    @Test("repo sidebar product controls route through App command composition")
    func repoSidebarProductControlsRouteThroughAppCommandComposition() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let viewSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift"),
            encoding: .utf8
        )
        let commandToolbarSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+CommandToolbar.swift"
            ),
            encoding: .utf8
        )
        let featureSource = viewSource + commandToolbarSource
        let appCompositionSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Windows/SidebarSurfaceHost.swift"),
            encoding: .utf8
        )

        #expect(!featureSource.contains("repoExplorerPrefs.setRepoVisibilityMode"))
        #expect(!featureSource.contains("RepoExplorerVisibilityButton"))
        #expect(!featureSource.contains("onSetVisibilityMode"))
        #expect(!featureSource.contains("repoExplorerPrefs.toggleSortOrder"))
        #expect(!featureSource.contains("repoExplorerPrefs.setGroupingMode(candidate)"))
        #expect(featureSource.contains(".toggleReposSortDirection"))
        #expect(!featureSource.contains(".togglePanesSortDirection"))
        #expect(!featureSource.contains(".setPanesGroupingActivity"))
        #expect(featureSource.contains(".togglePanesShowsPinned"))
        #expect(featureSource.contains(".setReposGroupingActivity"))
        #expect(featureSource.contains("presentation.command(command)?.isEnabled == true"))
        #expect(featureSource.contains("commandDispatcher.dispatch(command)"))
        #expect(!featureSource.contains("AppCommandDispatcher.shared"))
        #expect(appCompositionSource.contains("commandDispatcher: commandDispatcher"))
        #expect(!featureSource.contains("repoExplorerPrefs.setSortDirection"))
        #expect(!featureSource.contains("repoExplorerPrefs.setShowsPinned"))
        #expect(!appCompositionSource.contains("setRepoSidebarVisibilityMode"))
        #expect(!appCompositionSource.contains("repoSidebarVisibilityMode"))
    }

    @Test("Repo Explorer body consumes immutable command presentation without live capability reads")
    func repoExplorerBodyConsumesImmutableCommandPresentation() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let featureSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView.swift"),
            encoding: .utf8
        )
        let presentationSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerCommandPresentation.swift"),
            encoding: .utf8
        )

        #expect(featureSource.contains("commandPresentationDelta"))
        #expect(!featureSource.contains("visibilityCommand"))
        #expect(!featureSource.contains("canSetSortOrder"))
        #expect(!presentationSource.contains("dispatcher.canDispatch"))
    }

    @Test("Repo Explorer native viewport is the only App command-presentation target")
    func repoExplorerNativeViewportOwnsCommandPresentationTargeting() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let featureRoot = projectRoot.appending(
            path: "Sources/AgentStudio/Features/RepoExplorer"
        )
        let commandPresentationSource = try String(
            contentsOf: featureRoot.appending(path: "RepoExplorerCommandPresentation.swift"),
            encoding: .utf8
        )
        let commandBatchSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/App/Windows/RepoExplorerCommandPresentationBatch.swift"
            ),
            encoding: .utf8
        )
        let sidebarHostSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/AgentStudio/App/Windows/SidebarSurfaceHost.swift"),
            encoding: .utf8
        )

        #expect(!commandPresentationSource.contains("legacyList"))
        #expect(!commandBatchSource.contains("usesNativeVisibleSnapshot"))
        #expect(!commandBatchSource.contains("legacyVisibleRevision"))
        #expect(!commandBatchSource.contains("visibleWorktrees.visibleWorktreeIds"))
        #expect(sidebarHostSource.contains("latestDelta"))
        #expect(sidebarHostSource.contains("acceptVisibleWorktreeSnapshot"))
    }
}

extension String {
    fileprivate func repoExplorerSlice(from startMarker: String, to endMarker: String) -> String? {
        guard let start = range(of: startMarker)?.lowerBound,
            let end = range(of: endMarker, range: start..<endIndex)?.lowerBound
        else {
            return nil
        }
        return String(self[start..<end])
    }
}
