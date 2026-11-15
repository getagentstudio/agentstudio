import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite(.serialized)
@MainActor
struct PaneManagementContextTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("pane identity is present even without a repository or verified session")
    func alwaysIncludesPaneIdentity() throws {
        try withTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Standalone")

            let context = PaneManagementContext.project(paneId: pane.id, store: store)

            let identity = try #require(context.identityRows.first { $0.id == "pane" })
            #expect(identity.text == pane.id.uuidString)
            #expect(identity.toolTip == pane.id.uuidString)
            #expect(!context.identityRows.contains { $0.id == "session" })
        }
    }

    @Test
    func targetPath_prefersLiveCwd_thenFallsBackToWorktreeRoot() {
        withTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology,
                graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)

            let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/agent-studio"))
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }

            let pane = store.createPane(
                launchDirectory: worktree.path,
                title: "Terminal",
                facets: PaneContextFacets(
                    repoId: repo.id,
                    worktreeId: worktree.id,
                    cwd: URL(fileURLWithPath: "/tmp/agent-studio/subdir")
                )
            )
            store.paneAtom.updatePaneNote(pane.id, note: "Watch release logs")
            atoms.repoCache.setWorktreeEnrichment(
                WorktreeEnrichment(
                    worktreeId: worktree.id,
                    repoId: repo.id,
                    branch: "main"
                )
            )
            let branchKey = RepoBranchKey(repoId: repo.id, branch: "main")!
            atoms.repoCache.applyPullRequestFacts([
                branchKey: PullRequestFacts(openCount: 2, exactOpenURL: nil)
            ])

            let context = PaneManagementContext.project(
                paneId: pane.id,
                store: store
            )

            #expect(context.targetPath?.path == "/tmp/agent-studio/subdir")
            #expect(store.paneAtom.graphAtom.paneStructuralFacts(pane.id)?.cwd == context.targetPath)
            #expect(context.identityRows.first(where: { $0.id == "repo" })?.text == repo.name)
            #expect(context.identityRows.first(where: { $0.id == "branch" })?.text == "main")
            #expect(context.identityRows.first(where: { $0.id == "cwd" })?.text == "subdir")
            #expect(context.identityRows.last?.id == "pane")
            #expect(!context.identityRows.contains { $0.id == "note" })
            #expect(context.statusChips?.branchStatus.prCount == 2)
        }
    }

    @Test
    func targetPath_fallsBackToWorktreeRoot_whenCwdMissing() {
        withTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology,
                graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)

            let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/agent-studio"))
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }

            let pane = store.createPane(
                launchDirectory: worktree.path,
                title: "Terminal",
                facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: worktree.path),
            )

            let context = PaneManagementContext.project(paneId: pane.id, store: store)

            #expect(context.targetPath?.path == worktree.path.path)
            #expect(store.paneAtom.graphAtom.paneStructuralFacts(pane.id)?.cwd == context.targetPath)
            #expect(context.identityRows.first(where: { $0.id == "branch" })?.text == "detached HEAD")
            #expect(context.identityRows.first(where: { $0.id == "cwd" })?.text == worktree.path.lastPathComponent)
        }
    }

    @Test
    func contextFreeTerminalUsesHomeFallbackWithoutWorkspaceStatus() {
        withTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology,
                graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)

            let pane = store.createPane(
                title: "Floating"
            )

            let context = PaneManagementContext.project(paneId: pane.id, store: store)

            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            let cwdRow = context.identityRows.first(where: { $0.id == "cwd" })
            #expect(context.targetPath == homeDirectory)
            #expect(store.paneAtom.graphAtom.paneStructuralFacts(pane.id)?.cwd == context.targetPath)
            #expect(cwdRow?.text == homeDirectory.path)
            #expect(cwdRow?.toolTip == homeDirectory.path)
            #expect(context.statusChips == nil)
            #expect(context.showsIdentityBlock == true)
        }
    }

    @Test
    func standaloneCwdUsesAbsolutePathWhenNoWorktreeContextExists() {
        withTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology,
                graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)

            let cwd = URL(filePath: "/Users/dev/project-dev", directoryHint: .isDirectory)
            let pane = store.createPane(
                launchDirectory: cwd,
                title: "Floating",
                facets: PaneContextFacets(cwd: cwd)
            )

            let context = PaneManagementContext.project(paneId: pane.id, store: store)

            let cwdRow = context.identityRows.first { $0.id == "cwd" }
            #expect(context.targetPath == cwd)
            #expect(cwdRow?.text == "/Users/dev/project-dev")
            #expect(cwdRow?.toolTip == "/Users/dev/project-dev")
            #expect(context.identityRows.contains { $0.id == "repo" } == false)
            #expect(context.identityRows.contains { $0.id == "worktree" } == false)
        }
    }

    @Test
    func genericBrowserPane_hidesIdentityBlock_whenNoWorkspaceAssociationExists() {
        withTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology,
                graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)

            let pane = store.createPane(
                content: .webview(WebviewState(url: URL(string: "https://github.com")!)),
                metadata: PaneMetadata(
                    contentType: .browser,
                    title: "GitHub"
                )
            )

            let context = PaneManagementContext.project(paneId: pane.id, store: store)

            #expect(context.showsIdentityBlock == false)
        }
    }

    @Test
    func contextualBrowserPane_showsIdentityBlock_whenWorkspaceAssociationExists() {
        withTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology,
                graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)

            let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/agent-studio"))
            guard let worktree = store.repos.first(where: { $0.id == repo.id })?.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }

            let pane = store.createPane(
                content: .webview(WebviewState(url: URL(string: "https://github.com/ShravanSunder/agentstudio")!)),
                metadata: PaneMetadata(
                    contentType: .browser,
                    launchDirectory: worktree.path,
                    title: "GitHub",
                    facets: PaneContextFacets(
                        repoId: repo.id,
                        repoName: repo.name,
                        worktreeId: worktree.id,
                        worktreeName: worktree.name,
                        cwd: worktree.path
                    )
                )
            )

            let context = PaneManagementContext.project(paneId: pane.id, store: store)

            #expect(context.showsIdentityBlock == true)
        }
    }

    @Test
    func danglingAssociationDoesNotRecoverWorkspaceIdentityFromCwd() {
        withTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology,
                graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/agent-studio"))
            guard let worktree = repo.worktrees.first else {
                Issue.record("Expected main worktree")
                return
            }
            let pane = Pane(
                content: .terminal(
                    TerminalState(
                        provider: .zmx,
                        lifetime: .persistent,
                        zmxSessionID: .generateUUIDv7()
                    )
                ),
                metadata: PaneMetadata(
                    launchDirectory: worktree.path,
                    title: "Dangling",
                    facets: PaneContextFacets(
                        repoId: UUIDv7.generate(),
                        worktreeId: worktree.id,
                        cwd: worktree.path
                    )
                )
            )
            #expect(store.paneAtom.insertRestoredPane(pane))

            let context = PaneManagementContext.project(paneId: pane.id, store: store)

            #expect(context.identityRows.contains { $0.id == "repo" } == false)
            #expect(context.identityRows.contains { $0.id == "worktree" } == false)
            #expect(context.statusChips == nil)
        }
    }
}
