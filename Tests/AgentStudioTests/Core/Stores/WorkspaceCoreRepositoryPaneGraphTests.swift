import Foundation
import GRDB
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("WorkspaceCoreRepositoryPaneGraphTests")
struct WorkspaceCoreRepositoryPaneGraphTests {
    @Test("pane graph round trips pane rows drawer membership and durable facets")
    func paneGraphRoundTripsPaneRowsDrawerMembershipAndDurableFacets() throws {
        let fixture = try makeWorkspaceCoreRepositoryFixture()
        let repository = fixture.repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000001001")!
        let repoId = UUID(uuidString: "00000000-0000-0000-0000-000000001101")!
        let worktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000001201")!
        let parentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000001301")!
        let childPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000001302")!
        let docsWebview = WebviewTabSnapshot(
            id: childPaneId, url: URL(string: "https://example.com/docs")!, title: "Docs")
        let drawerId = UUID(uuidString: "00000000-0000-0000-0000-000000001401")!
        try repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: "Pane Graph",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try repository.replaceRepositoryTopology(
            .init(
                watchedPaths: [],
                repos: [
                    .init(
                        id: repoId,
                        name: "repo",
                        repoPath: URL(fileURLWithPath: "/tmp/agentstudio/pane-graph-repo"),
                        createdAt: Date(timeIntervalSince1970: 200),
                        worktrees: [
                            .init(
                                id: worktreeId,
                                repoId: repoId,
                                name: "main",
                                path: URL(fileURLWithPath: "/tmp/agentstudio/pane-graph-repo"),
                                isMainWorktree: true
                            )
                        ]
                    )
                ],
                unavailableRepoIds: []
            )
        )
        let graph = WorkspaceCoreRepository.PaneGraphRecord(
            panes: [
                .init(
                    id: parentPaneId,
                    content: .terminal(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7()),
                    metadata: .init(
                        launchDirectory: URL(
                            filePath: "/tmp/agentstudio/pane-graph-repo",
                            directoryHint: .isDirectory
                        ),
                        executionBackend: .docker(image: "swift:latest"),
                        createdAt: Date(timeIntervalSince1970: 300),
                        title: "Parent",
                        note: "keep this note",
                        checkoutRef: "feature/pane-graph",
                        isPinned: true,
                        durableFacets: .init(
                            repoId: repoId,
                            worktreeId: worktreeId,
                            cwd: URL(
                                filePath: "/tmp/agentstudio/pane-graph-repo/Sources",
                                directoryHint: .isDirectory
                            )
                        )
                    ),
                    residency: .pendingUndo(expiresAt: Date(timeIntervalSince1970: 400)),
                    placement: .layout,
                    drawer: .init(drawerId: drawerId, parentPaneId: parentPaneId, childPaneIds: [childPaneId]),
                    updatedAt: Date(timeIntervalSince1970: 500)
                ),
                .init(
                    id: childPaneId,
                    content: .browser(activeWebviewId: childPaneId, showNavigation: false, webviews: [docsWebview]),
                    metadata: .init(
                        executionBackend: .local,
                        createdAt: Date(timeIntervalSince1970: 301),
                        title: "Child Web",
                        durableFacets: .init(
                            cwd: URL(
                                filePath: "/tmp/agentstudio/floating",
                                directoryHint: .isDirectory
                            )
                        )
                    ),
                    residency: .active,
                    placement: .drawerChild(parentPaneId: parentPaneId),
                    updatedAt: Date(timeIntervalSince1970: 501)
                ),
            ]
        )
        try repository.replacePaneGraph(workspaceId: workspaceId, graph: graph)
        let restoredGraph = try repository.fetchPaneGraph(workspaceId: workspaceId)

        #expect(restoredGraph == graph)
        #expect(restoredGraph.panes.first?.metadata.isPinned == true)
        #expect(restoredGraph.panes.last?.metadata.isPinned == false)
        #expect(restoredGraph.panes.first?.residency == .pendingUndo(expiresAt: Date(timeIntervalSince1970: 400)))
    }

    @Test("pane graph clears dangling optional associations without rejecting the pane")
    func paneGraphClearsDanglingSoftAssociation() throws {
        // Arrange
        let fixture = try makeWorkspaceCoreRepositoryFixture()
        let workspaceId = UUIDv7.generate()
        let paneId = UUIDv7.generate()
        let danglingRepoId = UUIDv7.generate()
        let danglingWorktreeId = UUIDv7.generate()
        try fixture.repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: "Dangling association",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        var pane = makeFloatingPane(id: paneId)
        pane.metadata.durableFacets.repoId = danglingRepoId
        pane.metadata.durableFacets.worktreeId = danglingWorktreeId
        let graph = WorkspaceCoreRepository.PaneGraphRecord(panes: [pane])

        // Act
        try fixture.repository.replacePaneGraph(workspaceId: workspaceId, graph: graph)
        let restoredGraph = try fixture.repository.fetchPaneGraph(workspaceId: workspaceId)

        // Assert
        var expected = graph
        expected.panes[0].metadata.durableFacets.repoId = nil
        expected.panes[0].metadata.durableFacets.worktreeId = nil
        #expect(restoredGraph == expected)
    }

    @Test("pane graph routes content variants to their schema-owned tables")
    func paneGraphRoutesContentVariantsToTheirSchemaOwnedTables() throws {
        let fixture = try makeWorkspaceCoreRepositoryFixture()
        let repository = fixture.repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000001002")!
        try repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: "Content Routes",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let terminalPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000001303")!
        let browserPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000001304")!
        let codePaneId = UUID(uuidString: "00000000-0000-0000-0000-000000001305")!
        let payloadPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000001306")!
        let graph = WorkspaceCoreRepository.PaneGraphRecord(
            panes: [
                makeFloatingPane(
                    id: terminalPaneId,
                    content: .terminal(provider: .ghostty, lifetime: .temporary, zmxSessionID: .generateUUIDv7())),
                makeFloatingPane(
                    id: browserPaneId,
                    content: .browser(
                        activeWebviewId: browserPaneId,
                        showNavigation: true,
                        webviews: [
                            WebviewTabSnapshot(
                                id: browserPaneId, url: URL(string: "https://agentstudio.dev")!, title: "AgentStudio")
                        ]
                    )
                ),
                makeFloatingPane(
                    id: codePaneId,
                    content: .codeViewer(
                        filePath: URL(fileURLWithPath: "/tmp/agentstudio/App.swift"),
                        scrollToLine: 42
                    )
                ),
                makeFloatingPane(
                    id: payloadPaneId,
                    content: .payload(
                        contentType: .diff,
                        payloadKind: "bridgePanel",
                        payloadJSON: #"{"panelKind":"diffViewer"}"#
                    ),
                    residency: .orphaned(worktreePath: "/tmp/agentstudio/missing-worktree")
                ),
            ]
        )

        try repository.replacePaneGraph(workspaceId: workspaceId, graph: graph)
        let contentCounts = try fixture.fetchPaneContentRouteCounts()
        let restoredGraph = try repository.fetchPaneGraph(workspaceId: workspaceId)

        #expect(contentCounts == .init(terminal: 1, webview: 1, codeViewer: 1, payload: 1))
        #expect(restoredGraph == graph)
    }

    @Test("pane graph update preserves tab membership for retained panes")
    func paneGraphUpdatePreservesTabMembershipForRetainedPanes() throws {
        let fixture = try makeWorkspaceCoreRepositoryFixture()
        let repository = fixture.repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000001003")!
        let paneId = UUID(uuidString: "00000000-0000-0000-0000-000000001307")!
        let tabId = UUID(uuidString: "00000000-0000-0000-0000-000000001501")!
        try repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: "Retained Tab",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try repository.replacePaneGraph(
            workspaceId: workspaceId,
            graph: .init(panes: [makeFloatingPane(id: paneId, title: "Before")])
        )
        try fixture.insertTabShell(workspaceId: workspaceId, tabId: tabId)
        try fixture.insertTabPane(tabId: tabId, paneId: paneId)

        try repository.replacePaneGraph(
            workspaceId: workspaceId,
            graph: .init(panes: [makeFloatingPane(id: paneId, title: "After")])
        )
        let tabPaneCount = try fixture.fetchTabPaneCount(tabId: tabId, paneId: paneId)
        let restoredGraph = try repository.fetchPaneGraph(workspaceId: workspaceId)

        #expect(tabPaneCount == 1)
        #expect(restoredGraph.panes.single?.metadata.title == "After")
    }

    @Test("pane graph replace rolls back after mutation failure")
    func paneGraphReplaceRollsBackAfterMutationFailure() throws {
        let fixture = try makeWorkspaceCoreRepositoryFixture()
        let repository = fixture.repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000001004")!
        let originalPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000001308")!
        let rejectedPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000001309")!
        try repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: "Rollback Pane Graph",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let originalGraph = WorkspaceCoreRepository.PaneGraphRecord(
            panes: [makeFloatingPane(id: originalPaneId, title: "Original")]
        )
        try repository.replacePaneGraph(workspaceId: workspaceId, graph: originalGraph)
        try fixture.databaseQueue.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER pane_graph_test_abort
                    BEFORE INSERT ON pane
                    WHEN NEW.id = '\(rejectedPaneId.uuidString)'
                    BEGIN
                        SELECT RAISE(ABORT, 'pane graph test abort');
                    END
                    """
            )
        }

        #expect(throws: Error.self) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [makeFloatingPane(id: rejectedPaneId, title: "Rejected")])
            )
        }
        let restoredGraph = try repository.fetchPaneGraph(workspaceId: workspaceId)

        #expect(restoredGraph == originalGraph)
    }

    @Test("pane graph round trips worktree source when durable facets are omitted")
    func paneGraphRoundTripsWorktreeSourceWhenDurableFacetsAreOmitted() throws {
        let fixture = try makeWorkspaceCoreRepositoryFixture()
        let repository = fixture.repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000001006")!
        let repoId = UUID(uuidString: "00000000-0000-0000-0000-000000001102")!
        let worktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000001202")!
        let paneId = UUID(uuidString: "00000000-0000-0000-0000-000000001310")!
        let launchDirectory = URL(
            filePath: "/tmp/agentstudio/source-fill",
            directoryHint: .isDirectory
        )
        try repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: "Source Fill",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try repository.replaceRepositoryTopology(
            .init(
                watchedPaths: [],
                repos: [
                    .init(
                        id: repoId,
                        name: "repo",
                        repoPath: launchDirectory,
                        createdAt: Date(timeIntervalSince1970: 200),
                        worktrees: [
                            .init(
                                id: worktreeId,
                                repoId: repoId,
                                name: "main",
                                path: launchDirectory,
                                isMainWorktree: true
                            )
                        ]
                    )
                ],
                unavailableRepoIds: []
            )
        )
        let graph = WorkspaceCoreRepository.PaneGraphRecord(
            panes: [
                .init(
                    id: paneId,
                    content: .terminal(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7()),
                    metadata: .init(
                        launchDirectory: launchDirectory,
                        executionBackend: .local,
                        createdAt: Date(timeIntervalSince1970: 300),
                        title: "Worktree",
                        durableFacets: .init(
                            cwd: launchDirectory
                        )
                    ),
                    residency: .active,
                    placement: .layout,
                    updatedAt: Date(timeIntervalSince1970: 500)
                )
            ]
        )

        try repository.replacePaneGraph(workspaceId: workspaceId, graph: graph)
        let restoredGraph = try repository.fetchPaneGraph(workspaceId: workspaceId)

        #expect(restoredGraph == graph)
    }

    @Test("pane graph fetch tolerates topology deleting worktree source ids")
    func paneGraphFetchToleratesTopologyDeletingWorktreeSourceIds() throws {
        let fixture = try makeWorkspaceCoreRepositoryFixture()
        let repository = fixture.repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000001007")!
        let repoId = UUID(uuidString: "00000000-0000-0000-0000-000000001103")!
        let worktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000001203")!
        let paneId = UUID(uuidString: "00000000-0000-0000-0000-000000001311")!
        let launchDirectory = URL(
            filePath: "/tmp/agentstudio/source-delete",
            directoryHint: .isDirectory
        )
        try repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: "Source Delete",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try repository.replaceRepositoryTopology(
            .init(
                watchedPaths: [],
                repos: [
                    .init(
                        id: repoId,
                        name: "repo",
                        repoPath: launchDirectory,
                        createdAt: Date(timeIntervalSince1970: 200),
                        worktrees: [
                            .init(
                                id: worktreeId,
                                repoId: repoId,
                                name: "main",
                                path: launchDirectory,
                                isMainWorktree: true
                            )
                        ]
                    )
                ],
                unavailableRepoIds: []
            )
        )
        try repository.replacePaneGraph(
            workspaceId: workspaceId,
            graph: .init(panes: [
                .init(
                    id: paneId,
                    content: .terminal(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7()),
                    metadata: .init(
                        launchDirectory: launchDirectory,
                        executionBackend: .local,
                        createdAt: Date(timeIntervalSince1970: 300),
                        title: "Worktree",
                        durableFacets: .init(cwd: launchDirectory)
                    ),
                    residency: .active,
                    placement: .layout,
                    updatedAt: Date(timeIntervalSince1970: 500)
                )
            ])
        )

        try repository.replaceRepositoryTopology(
            .init(watchedPaths: [], repos: [], unavailableRepoIds: [])
        )
        let restoredGraph = try repository.fetchPaneGraph(workspaceId: workspaceId)

        #expect(restoredGraph.panes.single?.metadata.launchDirectory == launchDirectory)
        #expect(restoredGraph.panes.single?.metadata.durableFacets.cwd == launchDirectory)
    }

    private func makeFloatingPane(
        id: UUID,
        content: WorkspaceCoreRepository.PaneContentRecord = .terminal(
            provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7()),
        title: String = "Pane",
        residency: WorkspaceCoreRepository.PaneResidencyRecord = .active
    ) -> WorkspaceCoreRepository.PaneRecord {
        .init(
            id: id,
            content: content,
            metadata: .init(
                executionBackend: .local,
                createdAt: Date(timeIntervalSince1970: 300),
                title: title,
                durableFacets: .init(
                    cwd: URL(
                        filePath: "/tmp/agentstudio/floating",
                        directoryHint: .isDirectory
                    )
                )
            ),
            residency: residency,
            placement: .layout,
            updatedAt: Date(timeIntervalSince1970: 500)
        )
    }
}
