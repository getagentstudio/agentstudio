import Foundation
import Testing

@testable import AgentStudioCore

@Suite("WorkspaceCoreRepositoryPaneGraphValidationTests")
struct WorkspaceCoreRepositoryPaneGraphValidationTests {
    @Test("pane graph replace rejects duplicate pane ids before writing")
    func paneGraphReplaceRejectsDuplicatePaneIdsBeforeWriting() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002001")!
        let duplicatePaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002101")!
        try repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: "Duplicate Panes",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        #expect(throws: WorkspaceCoreRepositoryError.duplicatePaneId(duplicatePaneId)) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(id: duplicatePaneId),
                    makeFloatingPane(id: duplicatePaneId, title: "Duplicate"),
                ])
            )
        }
    }

    @Test("pane graph replace rejects duplicate drawer ids before writing")
    func paneGraphReplaceRejectsDuplicateDrawerIdsBeforeWriting() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002015")!
        let firstParentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002120")!
        let secondParentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002121")!
        let duplicateDrawerId = UUID(uuidString: "00000000-0000-0000-0000-000000002406")!
        try upsertWorkspace(repository, workspaceId: workspaceId, name: "Duplicate Drawers")

        #expect(throws: WorkspaceCoreRepositoryError.duplicateDrawerId(duplicateDrawerId)) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(
                        id: firstParentPaneId,
                        drawer: .init(
                            drawerId: duplicateDrawerId,
                            parentPaneId: firstParentPaneId,
                            childPaneIds: []
                        )
                    ),
                    makeFloatingPane(
                        id: secondParentPaneId,
                        drawer: .init(
                            drawerId: duplicateDrawerId,
                            parentPaneId: secondParentPaneId,
                            childPaneIds: []
                        )
                    ),
                ])
            )
        }
    }

    @Test("pane graph persistence stores CWD independently of current topology")
    func paneGraphPersistenceStoresCWDIndependentlyOfCurrentTopology() throws {
        let fixture = try makeWorkspaceCoreRepositoryFixture()
        let repository = fixture.repository
        let firstWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002002")!
        let foreignRepoId = UUID(uuidString: "00000000-0000-0000-0000-000000002201")!
        let foreignWorktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000002301")!
        try repository.upsertWorkspace(
            .init(
                id: firstWorkspaceId,
                name: "First",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try repository.replaceRepositoryTopology(
            .init(
                watchedPaths: [],
                repos: [
                    .init(
                        id: foreignRepoId,
                        name: "foreign",
                        repoPath: URL(fileURLWithPath: "/tmp/agentstudio/foreign"),
                        createdAt: Date(timeIntervalSince1970: 200),
                        worktrees: [
                            .init(
                                id: foreignWorktreeId,
                                repoId: foreignRepoId,
                                name: "foreign",
                                path: URL(fileURLWithPath: "/tmp/agentstudio/foreign"),
                                isMainWorktree: true
                            )
                        ]
                    )
                ],
                unavailableRepoIds: []
            )
        )
        let paneId = UUID(uuidString: "00000000-0000-0000-0000-000000002102")!

        let graph = WorkspaceCoreRepository.PaneGraphRecord(
            panes: [
                makeWorktreePane(
                    id: paneId,
                    repoId: foreignRepoId,
                    worktreeId: foreignWorktreeId
                )
            ]
        )
        try repository.replacePaneGraph(workspaceId: firstWorkspaceId, graph: graph)

        #expect(try repository.fetchPaneGraph(workspaceId: firstWorkspaceId) == graph)
    }

    @Test("pane graph replace rejects drawer child outside incoming graph")
    func paneGraphReplaceRejectsDrawerChildOutsideIncomingGraph() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002004")!
        let parentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002103")!
        let missingChildPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002104")!
        let drawerId = UUID(uuidString: "00000000-0000-0000-0000-000000002401")!
        try repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: "Missing Child",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        #expect(
            throws: WorkspaceCoreRepositoryError.drawerChildPaneMissing(
                drawerId: drawerId,
                childPaneId: missingChildPaneId
            )
        ) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(
                        id: parentPaneId,
                        drawer: .init(
                            drawerId: drawerId,
                            parentPaneId: parentPaneId,
                            childPaneIds: [missingChildPaneId]
                        )
                    )
                ])
            )
        }
    }

    @Test("pane graph replace rejects drawer child whose parent pane is missing")
    func paneGraphReplaceRejectsDrawerChildWhoseParentPaneIsMissing() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002016")!
        let childPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002122")!
        let missingParentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002123")!
        try upsertWorkspace(repository, workspaceId: workspaceId, name: "Missing Parent")

        #expect(
            throws: WorkspaceCoreRepositoryError.drawerChildMissingParent(
                childPaneId: childPaneId,
                parentPaneId: missingParentPaneId
            )
        ) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(id: childPaneId, placement: .drawerChild(parentPaneId: missingParentPaneId))
                ])
            )
        }
    }

    @Test("pane graph replace rejects drawer whose parent does not match owner pane")
    func paneGraphReplaceRejectsDrawerWhoseParentDoesNotMatchOwnerPane() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002017")!
        let ownerPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002124")!
        let otherParentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002125")!
        let drawerId = UUID(uuidString: "00000000-0000-0000-0000-000000002407")!
        try upsertWorkspace(repository, workspaceId: workspaceId, name: "Wrong Drawer Parent")

        #expect(
            throws: WorkspaceCoreRepositoryError.drawerParentMismatch(
                drawerId: drawerId,
                expectedParentPaneId: ownerPaneId,
                actualParentPaneId: otherParentPaneId
            )
        ) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(
                        id: ownerPaneId,
                        drawer: .init(drawerId: drawerId, parentPaneId: otherParentPaneId, childPaneIds: [])
                    )
                ])
            )
        }
    }

    @Test("pane graph replace rejects drawer child listed by multiple drawers")
    func paneGraphReplaceRejectsDrawerChildListedByMultipleDrawers() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002018")!
        let firstParentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002126")!
        let secondParentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002127")!
        let childPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002128")!
        let firstDrawerId = UUID(uuidString: "00000000-0000-0000-0000-000000002408")!
        let secondDrawerId = UUID(uuidString: "00000000-0000-0000-0000-000000002409")!
        try upsertWorkspace(repository, workspaceId: workspaceId, name: "Duplicate Child Membership")

        #expect(throws: WorkspaceCoreRepositoryError.drawerChildListedMultipleTimes(childPaneId: childPaneId)) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(
                        id: firstParentPaneId,
                        drawer: .init(
                            drawerId: firstDrawerId,
                            parentPaneId: firstParentPaneId,
                            childPaneIds: [childPaneId]
                        )
                    ),
                    makeFloatingPane(
                        id: secondParentPaneId,
                        drawer: .init(
                            drawerId: secondDrawerId,
                            parentPaneId: secondParentPaneId,
                            childPaneIds: [childPaneId]
                        )
                    ),
                    makeFloatingPane(id: childPaneId, placement: .drawerChild(parentPaneId: firstParentPaneId)),
                ])
            )
        }
    }

    @Test("pane graph replace rejects drawer child whose placement points at another parent")
    func paneGraphReplaceRejectsDrawerChildWhosePlacementPointsAtAnotherParent() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002005")!
        let parentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002105")!
        let otherParentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002106")!
        let childPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002107")!
        let drawerId = UUID(uuidString: "00000000-0000-0000-0000-000000002402")!
        try repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: "Mismatched Child",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        #expect(
            throws: WorkspaceCoreRepositoryError.drawerChildParentMismatch(
                childPaneId: childPaneId,
                expectedParentPaneId: parentPaneId,
                actualParentPaneId: otherParentPaneId
            )
        ) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(
                        id: parentPaneId,
                        drawer: .init(drawerId: drawerId, parentPaneId: parentPaneId, childPaneIds: [childPaneId])
                    ),
                    makeFloatingPane(
                        id: otherParentPaneId
                    ),
                    makeFloatingPane(
                        id: childPaneId,
                        placement: .drawerChild(parentPaneId: otherParentPaneId)
                    ),
                ])
            )
        }
    }

    @Test("pane graph replace rejects pane id owned by another workspace")
    func paneGraphReplaceRejectsPaneIdOwnedByAnotherWorkspace() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let firstWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002006")!
        let secondWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002007")!
        let paneId = UUID(uuidString: "00000000-0000-0000-0000-000000002108")!
        try upsertWorkspace(repository, workspaceId: firstWorkspaceId, name: "First")
        try upsertWorkspace(repository, workspaceId: secondWorkspaceId, name: "Second")
        try repository.replacePaneGraph(
            workspaceId: secondWorkspaceId,
            graph: .init(panes: [makeFloatingPane(id: paneId, title: "Foreign")])
        )

        #expect(
            throws: WorkspaceCoreRepositoryError.paneBelongsToDifferentWorkspace(
                paneId: paneId,
                expectedWorkspaceId: firstWorkspaceId,
                actualWorkspaceId: secondWorkspaceId
            )
        ) {
            try repository.replacePaneGraph(
                workspaceId: firstWorkspaceId,
                graph: .init(panes: [makeFloatingPane(id: paneId, title: "Hijack")])
            )
        }
        let foreignGraph = try repository.fetchPaneGraph(workspaceId: secondWorkspaceId)

        #expect(foreignGraph.panes.single?.metadata.title == "Foreign")
    }

    @Test("pane graph replace rejects drawer id owned by another workspace")
    func paneGraphReplaceRejectsDrawerIdOwnedByAnotherWorkspace() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let firstWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002008")!
        let secondWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002009")!
        let foreignParentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002109")!
        let foreignChildPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002110")!
        let localParentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002111")!
        let localChildPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002112")!
        let drawerId = UUID(uuidString: "00000000-0000-0000-0000-000000002403")!
        try upsertWorkspace(repository, workspaceId: firstWorkspaceId, name: "First Drawer")
        try upsertWorkspace(repository, workspaceId: secondWorkspaceId, name: "Second Drawer")
        try repository.replacePaneGraph(
            workspaceId: secondWorkspaceId,
            graph: makeDrawerGraph(
                parentPaneId: foreignParentPaneId,
                childPaneId: foreignChildPaneId,
                drawerId: drawerId
            )
        )

        #expect(
            throws: WorkspaceCoreRepositoryError.drawerBelongsToDifferentWorkspace(
                drawerId: drawerId,
                expectedWorkspaceId: firstWorkspaceId,
                actualWorkspaceId: secondWorkspaceId
            )
        ) {
            try repository.replacePaneGraph(
                workspaceId: firstWorkspaceId,
                graph: makeDrawerGraph(
                    parentPaneId: localParentPaneId,
                    childPaneId: localChildPaneId,
                    drawerId: drawerId
                )
            )
        }
    }

    @Test("pane graph persistence does not require repository topology")
    func paneGraphPersistenceDoesNotRequireRepositoryTopology() throws {
        let fixture = try makeWorkspaceCoreRepositoryFixture()
        let repository = fixture.repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002010")!
        let paneId = UUID(uuidString: "00000000-0000-0000-0000-000000002113")!
        try upsertWorkspace(repository, workspaceId: workspaceId, name: "Missing Facet Repo")
        let graph = WorkspaceCoreRepository.PaneGraphRecord(
            panes: [
                makeFloatingPane(
                    id: paneId,
                    durableFacets: .init(
                        cwd: URL(
                            filePath: "/tmp/agentstudio/missing-repo",
                            directoryHint: .isDirectory
                        )
                    )
                )
            ]
        )

        try repository.replacePaneGraph(workspaceId: workspaceId, graph: graph)

        #expect(try repository.fetchPaneGraph(workspaceId: workspaceId) == graph)
    }

    @Test("pane graph replace rejects content type changes for existing panes")
    func paneGraphReplaceRejectsContentTypeChangesForExistingPanes() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002021")!
        let paneId = UUID(uuidString: "00000000-0000-0000-0000-000000002131")!
        try upsertWorkspace(repository, workspaceId: workspaceId, name: "Stable Content")
        try repository.replacePaneGraph(
            workspaceId: workspaceId,
            graph: .init(panes: [
                makeFloatingPane(
                    id: paneId,
                    content: .terminal(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())
                )
            ])
        )

        #expect(
            throws: WorkspaceCoreRepositoryError.paneContentTypeIsImmutable(
                paneId: paneId,
                oldContentType: .terminal,
                newContentType: .browser
            )
        ) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(
                        id: paneId,
                        content: .browser(
                            activeWebviewId: paneId,
                            showNavigation: true,
                            webviews: [
                                WebviewTabSnapshot(
                                    id: paneId, url: URL(string: "https://agentstudio.dev")!, title: "Changed")
                            ]
                        )
                    )
                ])
            )
        }
        let restoredGraph = try repository.fetchPaneGraph(workspaceId: workspaceId)

        #expect(restoredGraph.panes.single?.content.contentType == .terminal)
    }

    @Test("pane graph replace rejects drawer child missing drawer membership")
    func paneGraphReplaceRejectsDrawerChildMissingDrawerMembership() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002012")!
        let parentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002115")!
        let childPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002116")!
        try upsertWorkspace(repository, workspaceId: workspaceId, name: "Missing Membership")

        #expect(
            throws: WorkspaceCoreRepositoryError.drawerChildMembershipMissing(
                childPaneId: childPaneId,
                parentPaneId: parentPaneId
            )
        ) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(id: parentPaneId),
                    makeFloatingPane(id: childPaneId, placement: .drawerChild(parentPaneId: parentPaneId)),
                ])
            )
        }
    }

    @Test("pane graph replace rejects drawer child owning a drawer")
    func paneGraphReplaceRejectsDrawerChildOwningADrawer() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002013")!
        let parentPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002117")!
        let childPaneId = UUID(uuidString: "00000000-0000-0000-0000-000000002118")!
        let drawerId = UUID(uuidString: "00000000-0000-0000-0000-000000002404")!
        let childDrawerId = UUID(uuidString: "00000000-0000-0000-0000-000000002405")!
        try upsertWorkspace(repository, workspaceId: workspaceId, name: "Nested Drawer")

        #expect(
            throws: WorkspaceCoreRepositoryError.drawerChildCannotOwnDrawer(
                childPaneId: childPaneId,
                drawerId: childDrawerId
            )
        ) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(
                        id: parentPaneId,
                        drawer: .init(drawerId: drawerId, parentPaneId: parentPaneId, childPaneIds: [childPaneId])
                    ),
                    makeFloatingPane(
                        id: childPaneId,
                        placement: .drawerChild(parentPaneId: parentPaneId),
                        drawer: .init(drawerId: childDrawerId, parentPaneId: childPaneId, childPaneIds: [])
                    ),
                ])
            )
        }
    }

    @Test("pane graph replace rejects non payload content type in payload route")
    func paneGraphReplaceRejectsNonPayloadContentTypeInPayloadRoute() throws {
        let repository = try makeWorkspaceCoreRepositoryFixture().repository
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000002014")!
        let paneId = UUID(uuidString: "00000000-0000-0000-0000-000000002119")!
        try upsertWorkspace(repository, workspaceId: workspaceId, name: "Payload Route")

        #expect(
            throws: WorkspaceCoreRepositoryError.panePayloadContentTypeUnsupported(
                paneId: paneId,
                contentType: .terminal
            )
        ) {
            try repository.replacePaneGraph(
                workspaceId: workspaceId,
                graph: .init(panes: [
                    makeFloatingPane(
                        id: paneId,
                        content: .payload(contentType: .terminal, payloadKind: "bad", payloadJSON: "{}")
                    )
                ])
            )
        }
    }

    private func makeFloatingPane(
        id: UUID,
        content: WorkspaceCoreRepository.PaneContentRecord = .terminal(
            provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7()),
        title: String = "Pane",
        placement: WorkspaceCoreRepository.PanePlacementRecord = .layout,
        drawer: WorkspaceCoreRepository.DrawerRecord? = nil,
        durableFacets: WorkspaceCoreRepository.DurableFacetsRecord = .init(
            cwd: URL(
                filePath: "/tmp/agentstudio/floating",
                directoryHint: .isDirectory
            )
        )
    ) -> WorkspaceCoreRepository.PaneRecord {
        .init(
            id: id,
            content: content,
            metadata: .init(
                executionBackend: .local,
                createdAt: Date(timeIntervalSince1970: 300),
                title: title,
                durableFacets: durableFacets
            ),
            residency: .active,
            placement: placement,
            drawer: drawer,
            updatedAt: Date(timeIntervalSince1970: 500)
        )
    }

    private func makeWorktreePane(
        id: UUID,
        repoId: UUID,
        worktreeId: UUID,
        durableFacets: WorkspaceCoreRepository.DurableFacetsRecord? = nil
    ) -> WorkspaceCoreRepository.PaneRecord {
        let normalizedFacets =
            durableFacets
            ?? WorkspaceCoreRepository.DurableFacetsRecord(
                cwd: URL(
                    filePath: "/tmp/agentstudio/worktree",
                    directoryHint: .isDirectory
                )
            )
        return .init(
            id: id,
            content: .terminal(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7()),
            metadata: .init(
                launchDirectory: URL(
                    filePath: "/tmp/agentstudio/worktree",
                    directoryHint: .isDirectory
                ),
                executionBackend: .local,
                createdAt: Date(timeIntervalSince1970: 300),
                title: "Worktree",
                durableFacets: normalizedFacets
            ),
            residency: .active,
            placement: .layout,
            updatedAt: Date(timeIntervalSince1970: 500)
        )
    }

    private func makeDrawerGraph(
        parentPaneId: UUID,
        childPaneId: UUID,
        drawerId: UUID
    ) -> WorkspaceCoreRepository.PaneGraphRecord {
        .init(panes: [
            makeFloatingPane(
                id: parentPaneId,
                drawer: .init(drawerId: drawerId, parentPaneId: parentPaneId, childPaneIds: [childPaneId])
            ),
            makeFloatingPane(id: childPaneId, placement: .drawerChild(parentPaneId: parentPaneId)),
        ])
    }

    private func makeTopology(
        repos: [(repoId: UUID, worktreeId: UUID?, path: String)]
    ) -> WorkspaceCoreRepository.RepositoryTopologyRecord {
        .init(
            watchedPaths: [],
            repos: repos.map { repo in
                .init(
                    id: repo.repoId,
                    name: repo.repoId.uuidString,
                    repoPath: URL(fileURLWithPath: repo.path),
                    createdAt: Date(timeIntervalSince1970: 200),
                    worktrees: repo.worktreeId.map { worktreeId in
                        [
                            .init(
                                id: worktreeId,
                                repoId: repo.repoId,
                                name: "main",
                                path: URL(fileURLWithPath: repo.path),
                                isMainWorktree: true
                            )
                        ]
                    } ?? []
                )
            },
            unavailableRepoIds: []
        )
    }

    private func upsertWorkspace(
        _ repository: WorkspaceCoreRepository,
        workspaceId: UUID,
        name: String
    ) throws {
        try repository.upsertWorkspace(
            .init(
                id: workspaceId,
                name: name,
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
    }
}
