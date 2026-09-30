import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@MainActor
@Suite("Workspace SQLite save coordinator", .serialized)
struct WorkspaceSQLiteSaveCoordinatorTests {
    @Test("workspace save failures map to bounded persistence reasons")
    func workspaceSaveFailuresMapToBoundedReasons() {
        let missingTabID = UUIDv7.generate()
        let compositionFailure = WorkspaceSQLiteSaveCoordinatorFailure.compositionRejected(
            .activeTabNotFound(missingTabID)
        )
        let bridgeFailure = WorkspaceSQLiteSaveCoordinatorFailure.datastore(
            WorkspaceSQLiteDatastoreFailure(WorkspaceSQLiteStateBridgeError.invalidPayloadJSON)
        )
        let databaseFailure = WorkspaceSQLiteSaveCoordinatorFailure.datastore(
            WorkspaceSQLiteDatastoreFailure(WorkspaceSQLiteDatastoreError.databasesNotPrepared)
        )

        #expect(
            WorkspaceStore.persistenceFailureReason(for: compositionFailure)
                == .workspaceSaveCompositionRejected
        )
        #expect(
            WorkspaceStore.persistenceFailureReason(for: bridgeFailure)
                == .workspaceSaveBridgeFailed
        )
        #expect(
            WorkspaceStore.persistenceFailureReason(for: databaseFailure)
                == .workspaceSaveDatabaseFailed
        )
    }

    @Test("shallow capture prepares the exact current composition off-main")
    func shallowCapturePreparesExactCurrentCompositionOffMain() async throws {
        // Arrange
        let fixture = try await makeFixture()
        let persistedAt = Date(timeIntervalSince1970: 1_784_000_004)
        let expectedTabs = fixture.tabLayoutAtom.tabs

        // Act
        let capture = fixture.coordinator.captureCurrentSaveState(persistedAt: persistedAt)
        let prepared = await WorkspaceSQLiteSavePreparation.prepareOffMain(capture)

        // Assert
        #expect(
            prepared.workspace.id
                == fixture.coordinator.captureCurrentSaveState(persistedAt: persistedAt).workspaceID
        )
        #expect(prepared.workspace.panes.count == 1)
        #expect(prepared.workspace.tabs == expectedTabs)
        #expect(
            prepared.captureRevision?.topologyContextRevision
                == fixture.repositoryTopologyAtom.lifecycleRevision
        )
    }

    @Test("valid save writes the exact current composition bundle")
    func validSaveWritesExactCurrentCompositionBundle() async throws {
        // Arrange
        let fixture = try await makeFixture()
        let persistedAt = Date(timeIntervalSince1970: 1_784_000_000)
        let expected = await fixture.coordinator.captureCurrentSaveBundle(persistedAt: persistedAt)

        // Act
        let saved = try await fixture.coordinator.save(persistedAt: persistedAt)
        let reloadDatastore = try await preparedWorkspaceSQLiteDatastore(
            coreRepository: fixture.coreRepository,
            preparedApplicationLocalRepository: fixture.preparedApplicationLocalRepository
        )
        let loadedWorkspace = await reloadDatastore.loadWorkspaceSnapshot()

        // Assert
        #expect(saved == expected)
        guard case .loaded(let workspace) = loadedWorkspace else {
            Issue.record("Expected saved workspace to load")
            return
        }
        #expect(workspace == expected.workspace)
        #expect(await fixture.probe.events.contains(.saveWorkspaceSnapshot))
    }

    @Test(
        "a background drawer terminal creation's preserved live selection survives an ordinary save and reload"
    )
    func backgroundDrawerInsertionPreservedSelectionSurvivesSaveAndReload() async throws {
        // Arrange
        let fixture = try await makeFixture()
        let mutationCoordinator = WorkspaceMutationCoordinator(
            repositoryTopologyAtom: fixture.repositoryTopologyAtom,
            workspacePaneAtom: fixture.workspacePaneAtom,
            workspaceTabShellAtom: fixture.tabLayoutAtom.shellAtom,
            workspaceTabArrangementAtom: fixture.tabLayoutAtom.arrangementAtom
        )
        let drawerChildCWD = URL(
            filePath: "/tmp/agentstudio-save-regression/drawer-cursor-roundtrip", directoryHint: .isDirectory)
        let makeDrawerChild: (String) -> Pane? = { title in
            fixture.workspacePaneAtom.addDrawerPane(
                to: fixture.rootPaneID,
                content: .terminal(
                    TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())
                ),
                metadata: PaneMetadata(
                    launchDirectory: drawerChildCWD, title: title,
                    facets: PaneContextFacets(cwd: drawerChildCWD))
            )
        }
        let childA = try #require(makeDrawerChild("A"))
        let childB = try #require(makeDrawerChild("B"))
        let drawerID = try #require(fixture.workspacePaneAtom.pane(fixture.rootPaneID)?.drawer?.drawerId)
        fixture.tabLayoutAtom.arrangementAtom.addDrawerPaneView(
            drawerId: drawerID, parentPaneId: fixture.rootPaneID, drawerPaneId: childA.id, inTab: fixture.tabID)
        fixture.tabLayoutAtom.arrangementAtom.addDrawerPaneView(
            drawerId: drawerID, parentPaneId: fixture.rootPaneID, drawerPaneId: childB.id, inTab: fixture.tabID)
        fixture.tabLayoutAtom.arrangementAtom.setActiveDrawerPane(childA.id, drawerId: drawerID, inTab: fixture.tabID)

        // Capture the tab exactly as `commitTerminalCreation` would before its
        // awaited off-main prepare and SQLite save: A selected, no C yet.
        let capturedTab = try #require(fixture.tabLayoutAtom.tab(fixture.tabID))
        let capturedState = TabArrangementState(
            tabId: capturedTab.id, allPaneIds: capturedTab.allPaneIds,
            arrangements: capturedTab.arrangements, activeArrangementId: capturedTab.activeArrangementId
        )
        let childC = Pane(
            content: .terminal(
                TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata(title: "Drawer"),
            kind: .drawerChild(parentPaneId: fixture.rootPaneID)
        )
        // Build the published proposal's tab the same way production's
        // off-main composition does (`preparePlacementOffMain`): insert the
        // new child without selecting it, since this is a background creation.
        let insertedState = try #require(
            TabArrangementMutationRules.insertingNewDrawerPane(
                childC.id, in: capturedState,
                insertion: .init(
                    parentPaneId: fixture.rootPaneID, drawerId: drawerID, targetDrawerPaneId: nil,
                    direction: .right, sizingMode: .halveTarget, selectsInsertedChild: false
                )
            )
        )
        let publishedTab = Tab(
            id: capturedTab.id, name: capturedTab.name,
            allPaneIds: insertedState.allPaneIds, arrangements: insertedState.arrangements,
            activeArrangementId: insertedState.activeArrangementId, colorHex: capturedTab.colorHex
        )

        // Act
        // The race: a human selects B in the drawer after the capture above,
        // while the background creation's save is still (hypothetically) in flight.
        fixture.tabLayoutAtom.arrangementAtom.setActiveDrawerPane(childB.id, drawerId: drawerID, inTab: fixture.tabID)
        let proposal = WorkspaceTerminalCreationProposal(
            bundle: .init(workspace: .init(id: UUIDv7.generate())),
            pane: childC, tab: publishedTab, associationOutcome: .freeNil,
            placement: .drawer(
                .init(
                    tabID: fixture.tabID, parentID: fixture.rootPaneID, anchorID: nil,
                    direction: .right, sizingMode: .halveTarget,
                    childID: childC.id, presentation: .background
                ))
        )
        mutationCoordinator.applyCommittedTerminalCreation(proposal)
        _ = try await fixture.coordinator.save(persistedAt: Date(timeIntervalSince1970: 1_784_000_200))
        let reloadDatastore = try await preparedWorkspaceSQLiteDatastore(
            coreRepository: fixture.coreRepository,
            preparedApplicationLocalRepository: fixture.preparedApplicationLocalRepository
        )
        let loadedWorkspace = await reloadDatastore.loadWorkspaceSnapshot()

        // Assert
        guard case .loaded(let workspace) = loadedWorkspace else {
            Issue.record("Expected saved workspace to reload")
            return
        }
        #expect(workspace.panes.contains { $0.id == childC.id })
        let reloadedArrangement = try #require(
            workspace.tabs.first { $0.id == fixture.tabID }?.arrangements.first {
                $0.id == capturedTab.activeArrangementId
            }
        )
        #expect(reloadedArrangement.drawerViews[drawerID]?.layout.contains(childC.id) == true)
        #expect(reloadedArrangement.drawerViews[drawerID]?.activeChildId == childB.id)
    }

    @Test("direct worktree unregistration commits later workspace snapshot")
    func directWorktreeUnregistrationCommitsLaterWorkspaceSnapshot() async throws {
        // Arrange
        let scenario = try await makeDirectWorktreeUnregistrationScenario()
        try await unregisterLinkedWorktree(in: scenario)
        let drawerPaneIDs = try addLaterDrawerPanes(in: scenario)

        // Act
        let saved = try await scenario.fixture.coordinator.save(
            persistedAt: Date(timeIntervalSince1970: 1_784_000_103)
        )
        let reloadDatastore = try await preparedWorkspaceSQLiteDatastore(
            coreRepository: scenario.fixture.coreRepository,
            preparedApplicationLocalRepository: scenario.fixture.preparedApplicationLocalRepository
        )
        let loadedWorkspace = await reloadDatastore.loadWorkspaceSnapshot()

        // Assert
        guard case .loaded(let workspace) = loadedWorkspace else {
            Issue.record("Expected latest workspace snapshot to reload")
            return
        }
        expectSavedWorkspaceWithRemovedContextCleared(
            workspace,
            saved: saved.workspace,
            scenario: scenario,
            drawerPaneIDs: drawerPaneIDs
        )
    }

    @Test("scanned worktree removal commits later workspace snapshot")
    func scannedWorktreeRemovalCommitsLaterWorkspaceSnapshot() async throws {
        // Arrange
        let scenario = try await makeDirectWorktreeUnregistrationScenario()
        try await reconcileScannedWorktreeRemoval(in: scenario)
        let drawerPaneIDs = try addLaterDrawerPanes(in: scenario)

        // Act
        let saved = try await scenario.fixture.coordinator.save(
            persistedAt: Date(timeIntervalSince1970: 1_784_000_104)
        )
        let reloadDatastore = try await preparedWorkspaceSQLiteDatastore(
            coreRepository: scenario.fixture.coreRepository,
            preparedApplicationLocalRepository: scenario.fixture.preparedApplicationLocalRepository
        )
        let loadedWorkspace = await reloadDatastore.loadWorkspaceSnapshot()

        // Assert
        guard case .loaded(let workspace) = loadedWorkspace else {
            Issue.record("Expected post-scan workspace snapshot to reload")
            return
        }
        expectSavedWorkspaceWithRemovedContextCleared(
            workspace,
            saved: saved.workspace,
            scenario: scenario,
            drawerPaneIDs: drawerPaneIDs
        )
    }

    @Test("topology changes cannot change captured composition")
    func topologyChangesCannotChangeCapturedComposition() async throws {
        // Arrange
        let fixture = try await makeFixture()
        let persistedAt = Date(timeIntervalSince1970: 1_784_000_003)
        let beforeTopologyChange = await fixture.coordinator.captureCurrentSaveBundle(
            persistedAt: persistedAt
        )

        // Act
        let preparation = RepositoryTopologyReplacement.prepare(
            repositories: [],
            watchedPaths: [
                WatchedPath(
                    id: UUIDv7.generate(),
                    path: URL(filePath: "/tmp/topology-only-change")
                )
            ],
            unavailableRepositoryIDs: []
        )
        guard case .prepared(let replacement) = preparation else {
            Issue.record("Expected valid topology-only replacement")
            return
        }
        fixture.repositoryTopologyAtom.replaceTopology(replacement)
        let afterTopologyChange = await fixture.coordinator.captureCurrentSaveBundle(
            persistedAt: persistedAt
        )

        // Assert
        #expect(afterTopologyChange.workspace == beforeTopologyChange.workspace)
        #expect(afterTopologyChange.captureRevision?.panes == beforeTopologyChange.captureRevision?.panes)
        #expect(afterTopologyChange.captureRevision?.tabShells == beforeTopologyChange.captureRevision?.tabShells)
        #expect(afterTopologyChange.captureRevision?.tabGraphs == beforeTopologyChange.captureRevision?.tabGraphs)
        #expect(
            afterTopologyChange.captureRevision?.topologyContextRevision
                == beforeTopologyChange.captureRevision?.topologyContextRevision.map { $0 + 1 }
        )
    }

    @Test("invalid current composition is rejected before datastore write")
    func invalidCurrentCompositionIsRejectedBeforeDatastoreWrite() async throws {
        // Arrange
        let fixture = try await makeFixture()
        let missingTabID = UUIDv7.generate()
        fixture.tabLayoutAtom.shellAtom.cursorAtom.replaceActiveTab(missingTabID)

        // Act
        do {
            _ = try await fixture.coordinator.save(
                persistedAt: Date(timeIntervalSince1970: 1_784_000_001)
            )
            Issue.record("Expected invalid active tab rejection")
        } catch {
            #expect(error == .compositionRejected(.activeTabNotFound(missingTabID)))
        }

        // Assert
        #expect(!(await fixture.probe.events.contains(.saveWorkspaceSnapshot)))
    }

    @Test("successful save acknowledgement does not mutate canonical atoms or cursors")
    func successfulSaveAcknowledgementDoesNotMutateCanonicalAtomsOrCursors() async throws {
        // Arrange
        let fixture = try await makeFixture()
        let persistedAt = Date(timeIntervalSince1970: 1_784_000_002)
        let before = await fixture.coordinator.captureCurrentSaveBundle(persistedAt: persistedAt)

        // Act
        _ = try await fixture.coordinator.save(persistedAt: persistedAt)

        // Assert
        let after = await fixture.coordinator.captureCurrentSaveBundle(persistedAt: persistedAt)
        #expect(after == before)
    }

    @Test("save bundle omits panes explicitly held for pending undo")
    func saveBundleOmitsExplicitPendingUndoPanes() async throws {
        // Arrange
        let fixture = try await makeFixture()
        let pendingUndoPane = makeUnownedPane(
            title: "Pending undo",
            residency: .pendingUndo(expiresAt: Date(timeIntervalSince1970: 1_784_000_300))
        )
        fixture.workspacePaneAtom.addPane(pendingUndoPane)

        // Act
        let bundle = await fixture.coordinator.captureCurrentSaveBundle(
            persistedAt: Date(timeIntervalSince1970: 1_784_000_003)
        )

        // Assert
        #expect(!bundle.workspace.panes.contains(where: { $0.id == pendingUndoPane.id }))
    }

    @Test("pending undo projection preserves strict rejection for an active unowned pane")
    func pendingUndoProjectionPreservesStrictRejectionForActiveUnownedPane() async throws {
        // Arrange
        let fixture = try await makeFixture()
        let activeUnownedPane = makeUnownedPane(title: "Active unowned", residency: .active)
        fixture.workspacePaneAtom.addPane(activeUnownedPane)

        // Act
        do {
            _ = try await fixture.coordinator.save(
                persistedAt: Date(timeIntervalSince1970: 1_784_000_004)
            )
            Issue.record("Expected active unowned pane rejection")
        } catch {
            #expect(error == .compositionRejected(.paneNotOwnedByTab(activeUnownedPane.id)))
        }

        // Assert
        #expect(!(await fixture.probe.events.contains(.saveWorkspaceSnapshot)))
    }
}

@MainActor
private struct DirectWorktreeUnregistrationScenario {
    let fixture: WorkspaceSQLiteSaveCoordinatorFixture
    let repositoryID: UUID
    let mainWorktreeID: UUID
    let repositoryPath: URL
    let paneCWD: URL
}

@MainActor
private func makeDirectWorktreeUnregistrationScenario() async throws
    -> DirectWorktreeUnregistrationScenario
{
    let repositoryID = UUIDv7.generate()
    let mainWorktreeID = UUIDv7.generate()
    let removedWorktreeID = UUIDv7.generate()
    let repositoryPath = URL(
        filePath: "/tmp/agentstudio-save-regression/repository",
        directoryHint: .isDirectory
    )
    let removedWorktreePath = URL(
        filePath: "/tmp/agentstudio-save-regression/linked",
        directoryHint: .isDirectory
    )
    let paneCWD = URL(
        filePath: removedWorktreePath.appending(path: "Sources").path,
        directoryHint: .isDirectory
    )
    let topologySnapshot = RepositoryTopologySQLiteSnapshot(
        repos: [CanonicalRepo(id: repositoryID, name: "save-regression", repoPath: repositoryPath)],
        worktrees: [
            CanonicalWorktree(
                id: mainWorktreeID,
                repoId: repositoryID,
                name: "main",
                path: repositoryPath,
                isMainWorktree: true
            ),
            CanonicalWorktree(
                id: removedWorktreeID,
                repoId: repositoryID,
                name: "linked",
                path: removedWorktreePath
            ),
        ],
        updatedAt: Date(timeIntervalSince1970: 1_784_000_100)
    )
    let fixture = try await makeFixture(
        launchDirectory: paneCWD,
        paneFacets: PaneContextFacets(repoId: repositoryID, worktreeId: removedWorktreeID, cwd: paneCWD),
        topologySnapshot: topologySnapshot
    )
    _ = try await fixture.coordinator.save(persistedAt: Date(timeIntervalSince1970: 1_784_000_101))
    return DirectWorktreeUnregistrationScenario(
        fixture: fixture,
        repositoryID: repositoryID,
        mainWorktreeID: mainWorktreeID,
        repositoryPath: repositoryPath,
        paneCWD: paneCWD
    )
}

@MainActor
private func unregisterLinkedWorktree(in scenario: DirectWorktreeUnregistrationScenario) async throws {
    let fixture = scenario.fixture
    let mutationCoordinator = WorkspaceMutationCoordinator(
        repositoryTopologyAtom: fixture.repositoryTopologyAtom,
        workspacePaneAtom: fixture.workspacePaneAtom,
        workspaceTabShellAtom: fixture.tabLayoutAtom.shellAtom,
        workspaceTabArrangementAtom: fixture.tabLayoutAtom.arrangementAtom
    )
    guard
        case .accepted = mutationCoordinator.unregisterWorktree(
            try #require(
                fixture.repositoryTopologyAtom.repo(scenario.repositoryID)?.worktrees.first(where: {
                    $0.id != scenario.mainWorktreeID
                })?.id
            ),
            from: scenario.repositoryID
        )
    else {
        Issue.record("Expected direct linked-worktree unregistration to be accepted")
        return
    }
    let topologyAfterUnregistration =
        await WorkspacePersistenceTransformer.makeRepositoryTopologySQLiteSnapshotOffMain(
            repositories: fixture.repositoryTopologyAtom.repos,
            unavailableRepositoryIDs: fixture.repositoryTopologyAtom.unavailableRepoIds,
            watchedPaths: fixture.repositoryTopologyAtom.watchedPaths,
            persistedAt: Date(timeIntervalSince1970: 1_784_000_102)
        )
    try await fixture.datastore.saveRepositoryTopologySnapshot(
        topologyAfterUnregistration,
        captureRevision: fixture.repositoryTopologyAtom.lifecycleRevision
    )
}

@MainActor
private func reconcileScannedWorktreeRemoval(in scenario: DirectWorktreeUnregistrationScenario) async throws {
    let fixture = scenario.fixture
    let mutationCoordinator = WorkspaceMutationCoordinator(
        repositoryTopologyAtom: fixture.repositoryTopologyAtom,
        workspacePaneAtom: fixture.workspacePaneAtom,
        workspaceTabShellAtom: fixture.tabLayoutAtom.shellAtom,
        workspaceTabArrangementAtom: fixture.tabLayoutAtom.arrangementAtom
    )
    guard
        case .accepted = mutationCoordinator.reconcileScannedWorktrees(
            scenario.repositoryID,
            scannedWorktrees: RepositoryScannedWorktrees(
                main: RepositoryScannedMainWorktree(
                    name: "main",
                    path: scenario.repositoryPath
                ),
                linked: []
            ),
            traceId: UUIDv7.generate()
        )
    else {
        Issue.record("Expected authoritative scan removal to be accepted")
        return
    }
    let topologyAfterScan =
        await WorkspacePersistenceTransformer.makeRepositoryTopologySQLiteSnapshotOffMain(
            repositories: fixture.repositoryTopologyAtom.repos,
            unavailableRepositoryIDs: fixture.repositoryTopologyAtom.unavailableRepoIds,
            watchedPaths: fixture.repositoryTopologyAtom.watchedPaths,
            persistedAt: Date(timeIntervalSince1970: 1_784_000_102)
        )
    try await fixture.datastore.saveRepositoryTopologySnapshot(
        topologyAfterScan,
        captureRevision: fixture.repositoryTopologyAtom.lifecycleRevision
    )
}

@MainActor
private func addLaterDrawerPanes(in scenario: DirectWorktreeUnregistrationScenario) throws -> [UUID] {
    let fixture = scenario.fixture
    let makeDrawerPane: (String) -> Pane? = { title in
        fixture.workspacePaneAtom.addDrawerPane(
            to: fixture.rootPaneID,
            content: .terminal(
                TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())
            ),
            metadata: PaneMetadata(
                launchDirectory: scenario.repositoryPath,
                title: title,
                facets: PaneContextFacets(cwd: scenario.repositoryPath)
            )
        )
    }
    let firstDrawerPane = try #require(makeDrawerPane("Later drawer first"))
    let secondDrawerPane = try #require(makeDrawerPane("Later drawer second"))
    let drawerID = try #require(fixture.workspacePaneAtom.pane(fixture.rootPaneID)?.drawer?.drawerId)
    fixture.tabLayoutAtom.arrangementAtom.addDrawerPaneView(
        drawerId: drawerID,
        parentPaneId: fixture.rootPaneID,
        drawerPaneId: firstDrawerPane.id,
        inTab: fixture.tabID
    )
    fixture.tabLayoutAtom.arrangementAtom.addDrawerPaneView(
        drawerId: drawerID,
        parentPaneId: fixture.rootPaneID,
        drawerPaneId: secondDrawerPane.id,
        inTab: fixture.tabID,
        targetDrawerPaneId: firstDrawerPane.id
    )
    return [firstDrawerPane.id, secondDrawerPane.id]
}

private func expectSavedWorkspaceWithRemovedContextCleared(
    _ loaded: WorkspaceSQLiteSnapshot,
    saved: WorkspaceSQLiteSnapshot,
    scenario: DirectWorktreeUnregistrationScenario,
    drawerPaneIDs: [UUID]
) {
    let savedPanesByID = Dictionary(uniqueKeysWithValues: saved.panes.map { ($0.id, $0) })
    let loadedPanesByID = Dictionary(uniqueKeysWithValues: loaded.panes.map { ($0.id, $0) })
    #expect(loadedPanesByID.keys == savedPanesByID.keys)
    for (paneID, savedPane) in savedPanesByID {
        guard let loadedPane = loadedPanesByID[paneID] else {
            Issue.record("Expected pane \(paneID) to survive save and reload")
            continue
        }
        #expect(loadedPane.content == savedPane.content)
        #expect(loadedPane.metadata.paneId == savedPane.metadata.paneId)
        #expect(loadedPane.metadata.contentType == savedPane.metadata.contentType)
        #expect(loadedPane.metadata.launchDirectory == savedPane.metadata.launchDirectory)
        #expect(loadedPane.metadata.executionBackend == savedPane.metadata.executionBackend)
        #expect(loadedPane.metadata.title == savedPane.metadata.title)
        if let worktreeID = savedPane.metadata.facets.worktreeId, worktreeID != scenario.mainWorktreeID {
            #expect(loadedPane.metadata.facets == PaneContextFacets(cwd: savedPane.metadata.facets.cwd))
        } else {
            #expect(loadedPane.metadata.facets == savedPane.metadata.facets)
        }
        #expect(loadedPane.metadata.checkoutRef == savedPane.metadata.checkoutRef)
        #expect(loadedPane.metadata.note == savedPane.metadata.note)
        #expect(loadedPane.residency == savedPane.residency)
        #expect(loadedPane.kind == savedPane.kind)
    }
    #expect(loaded.tabs == saved.tabs)
    #expect(loaded.activeTabId == saved.activeTabId)
    #expect(loaded.sidebarWidth == saved.sidebarWidth)
    #expect(loaded.windowFrame == saved.windowFrame)
    #expect(loaded.panes.count == 3)
    #expect(loaded.panes.first(where: { $0.id == scenario.fixture.rootPaneID })?.metadata.cwd == scenario.paneCWD)
    #expect(loaded.panes.first(where: { $0.id == scenario.fixture.rootPaneID })?.drawer?.paneIds == drawerPaneIDs)
}

@MainActor
private struct WorkspaceSQLiteSaveCoordinatorFixture {
    let rootPaneID: UUID
    let tabID: UUID
    let repositoryTopologyAtom: RepositoryTopologyAtom
    let workspacePaneAtom: WorkspacePaneAtom
    let tabLayoutAtom: WorkspaceTabLayoutAtom
    let coreRepository: WorkspaceCoreRepository
    let preparedApplicationLocalRepository: WorkspaceLocalRepository
    let datastore: WorkspaceSQLiteDatastoreActor
    let coordinator: WorkspaceSQLiteSaveCoordinator
    let probe: WorkspaceSQLiteSaveCoordinatorProbe
}

@MainActor
private func makeFixture(
    launchDirectory: URL? = nil,
    paneFacets: PaneContextFacets = .empty,
    topologySnapshot: RepositoryTopologySQLiteSnapshot? = nil
) async throws -> WorkspaceSQLiteSaveCoordinatorFixture {
    let workspaceID = UUIDv7.generate()
    let paneID = PaneId.generateUUIDv7().uuid
    let drawerID = UUIDv7.generate()
    let arrangementID = UUIDv7.generate()
    let tabID = UUIDv7.generate()
    let createdAt = Date(timeIntervalSince1970: 1_783_000_000)
    let pane = Pane(
        id: paneID,
        content: .terminal(
            TerminalState(
                provider: .zmx,
                lifetime: .persistent,
                zmxSessionID: .generateUUIDv7()
            )
        ),
        metadata: PaneMetadata(
            launchDirectory: launchDirectory,
            createdAt: createdAt,
            title: "Exact pane",
            facets: paneFacets
        ),
        kind: .layout(
            drawer: Drawer(
                drawerId: drawerID,
                parentPaneId: paneID
            )
        )
    )
    let arrangement = PaneArrangement(
        id: arrangementID,
        layout: Layout(paneId: paneID),
        activePaneId: paneID
    )
    let tab = Tab(
        id: tabID,
        name: "Exact tab",
        allPaneIds: [paneID],
        arrangements: [arrangement],
        activeArrangementId: arrangementID
    )
    let identityAtom = WorkspaceIdentityAtom(
        workspaceId: workspaceID,
        workspaceName: "Exact workspace",
        createdAt: createdAt
    )
    let windowMemoryAtom = WorkspaceWindowMemoryAtom(sidebarWidth: 312)
    let repositoryTopologyAtom = RepositoryTopologyAtom()
    if let topologySnapshot {
        WorkspacePersistenceTransformer.hydrateRepositoryTopology(
            topologySnapshot,
            repositoryTopologyAtom: repositoryTopologyAtom
        )
    }
    let workspacePaneAtom = WorkspacePaneAtom(repositoryTopologyAtom: repositoryTopologyAtom)
    workspacePaneAtom.addPane(pane)
    let tabLayoutAtom = WorkspaceTabLayoutAtom()
    tabLayoutAtom.appendTab(tab)
    tabLayoutAtom.setActiveTab(tabID)

    let coreQueue = try SQLiteDatabaseFactory.makeInMemoryQueue(
        label: "AgentStudio.sqlite.save-coordinator.core"
    )
    let localQueue = try SQLiteDatabaseFactory.makeInMemoryQueue(
        label: "AgentStudio.sqlite.save-coordinator.local"
    )
    try WorkspaceCoreMigrations.migrate(coreQueue)
    try WorkspaceLocalMigrations.migrate(localQueue)
    let probe = WorkspaceSQLiteSaveCoordinatorProbe()
    let coreRepository = WorkspaceCoreRepository(databaseWriter: coreQueue)
    let preparedApplicationLocalRepository = WorkspaceLocalRepository(
        workspaceId: workspaceID,
        databaseWriter: localQueue
    )
    let datastore = try await preparedWorkspaceSQLiteDatastore(
        coreRepository: coreRepository,
        preparedApplicationLocalRepository: preparedApplicationLocalRepository,
        probe: { event in await probe.record(event) }
    )
    if let topologySnapshot {
        try await datastore.saveRepositoryTopologySnapshot(topologySnapshot, captureRevision: 1)
    }
    return WorkspaceSQLiteSaveCoordinatorFixture(
        rootPaneID: paneID,
        tabID: tabID,
        repositoryTopologyAtom: repositoryTopologyAtom,
        workspacePaneAtom: workspacePaneAtom,
        tabLayoutAtom: tabLayoutAtom,
        coreRepository: coreRepository,
        preparedApplicationLocalRepository: preparedApplicationLocalRepository,
        datastore: datastore,
        coordinator: WorkspaceSQLiteSaveCoordinator(
            identityAtom: identityAtom,
            windowMemoryAtom: windowMemoryAtom,
            workspacePaneAtom: workspacePaneAtom,
            workspaceTabLayoutAtom: tabLayoutAtom,
            repositoryTopologyAtom: repositoryTopologyAtom,
            sqliteDatastore: datastore
        ),
        probe: probe
    )
}

private func makeUnownedPane(title: String, residency: SessionResidency) -> Pane {
    Pane(
        content: .terminal(
            TerminalState(
                provider: .zmx,
                lifetime: .persistent,
                zmxSessionID: .generateUUIDv7()
            )
        ),
        metadata: PaneMetadata(title: title),
        residency: residency
    )
}

private actor WorkspaceSQLiteSaveCoordinatorProbe {
    private(set) var events: [WorkspaceSQLiteDatastoreActor.ProbeEvent] = []

    func record(_ event: WorkspaceSQLiteDatastoreActor.ProbeEvent) {
        events.append(event)
    }
}
