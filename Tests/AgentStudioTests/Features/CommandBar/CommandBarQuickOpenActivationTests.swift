import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCommandBar
@testable import AgentStudioCore

@MainActor
@Suite(.serialized)
struct CommandBarQuickOpenActivationTests {
    private let recentsDefaultsFixture = CommandBarRecentsDefaultsFixture()

    init() {
        installTestCoreAtomsIfNeeded()
    }

    private func makeController(
        store: WorkspaceStore = WorkspaceStore(),
        dispatcher: any AppCommandDispatching,
        targetedSpecResolver:
            @escaping @Sendable (AppCommand, SearchItemType) -> AppCommandSpec? =
            CommandBarCommandPresentation.catalogTargetedSpecResolver,
        quickOpenDirectoryHandler:
            @escaping @MainActor @Sendable (URL, QuickOpenDirectoryPlacement) -> Void = { _, _ in }
    ) -> CommandBarPanelController {
        CommandBarPanelController(
            store: store,
            octiconLoader: makeSourceCatalogTestOcticonLoader(),
            repoCache: RepoCacheAtom(),
            dispatcher: dispatcher,
            targetedSpecResolver: targetedSpecResolver,
            quickOpenDirectoryHandler: quickOpenDirectoryHandler,
            commandBarSurface: CommandBarSurfaceAtom(),
            recentsDefaults: recentsDefaultsFixture.makeDefaults()
        )
    }

    @Test("Quick Open keeps the row visible when the catalog rejects worktree targeting")
    func quickOpenRequiresCatalogWorktreeAdmission() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let repository = store.addRepo(at: URL(filePath: "/tmp/command-bar-quick-open-catalog"))
            let worktree = try #require(repository.worktrees.first)
            let pane = store.createPane(title: "Current")
            let tab = Tab(paneId: pane.id, name: "Current")
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            store.setActivePane(pane.id, inTab: tab.id)
            let dispatcher = FakeAppCommandDispatcher()
            let controller = makeController(
                store: store,
                dispatcher: dispatcher,
                targetedSpecResolver: commandBarSurfaceRejectedTargetedSpecResolver
            )
            controller.state.show(defaultScope: .quickOpen)

            controller.executeItem(
                makeItem(
                    id: "quick-open-catalog-rejected",
                    action: .quickOpen(.worktree(worktreeStableKey: worktree.stableKey))
                )
            )

            #expect(dispatcher.targetedDispatches.isEmpty)
            #expect(controller.state.currentLevel?.id == "level-wt-\(worktree.id.uuidString)")
            #expect(controller.state.isVisible)
        }
    }

    private func makeItem(
        id: String,
        action: CommandBarAction
    ) -> CommandBarItem {
        CommandBarItem(
            id: id,
            title: id,
            group: "Test",
            groupPriority: 0,
            action: action
        )
    }

    @Test("Quick Open plain Return opens the live worktree in a new tab")
    func quickOpenPlainReturnUsesNewTabAndLiveIdentity() async throws {
        await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let repositoryPath = URL(filePath: "/tmp/command-bar-quick-open-live")
            let originalRepository = store.addRepo(at: repositoryPath)
            let target = CommandBarQuickOpenTarget.repository(
                repositoryStableKey: originalRepository.stableKey
            )
            let replacementRepositoryID = UUID()
            let replacementWorktree = Worktree(
                repoId: replacementRepositoryID,
                name: "replacement",
                path: repositoryPath,
                isMainWorktree: true
            )
            let replacementRepository = Repo(
                id: replacementRepositoryID,
                name: "replacement",
                repoPath: repositoryPath,
                worktrees: [replacementWorktree]
            )
            let preparation = RepositoryTopologyReplacement.prepare(
                repositories: [replacementRepository],
                watchedPaths: [],
                unavailableRepositoryIDs: []
            )
            guard case .prepared(let replacement) = preparation else {
                Issue.record("Expected valid replacement topology")
                return
            }
            store.repositoryTopologyAtom.replaceTopology(replacement)
            let pane = store.createPane(title: "Current")
            let tab = Tab(paneId: pane.id, name: "Current")
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            store.setActivePane(pane.id, inTab: tab.id)
            let dispatcher = FakeAppCommandDispatcher()
            let controller = makeController(store: store, dispatcher: dispatcher)
            controller.state.show(defaultScope: .quickOpen)

            controller.executeItem(
                makeItem(id: "quick-open-repository", action: .quickOpen(target))
            )

            #expect(dispatcher.targetedDispatches.count == 1)
            #expect(dispatcher.targetedDispatches.first?.command == .openNewTerminalInTab)
            #expect(dispatcher.targetedDispatches.first?.target == replacementWorktree.id)
            #expect(dispatcher.targetedDispatches.first?.targetType == .worktree)
            #expect(!controller.state.isVisible)
        }
    }

    @Test("Quick Open plain Return and Command-Return always use a new tab")
    func quickOpenNewTabVariants() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let repository = store.addRepo(at: URL(filePath: "/tmp/command-bar-quick-open-new-tab"))
            let worktree = try #require(repository.worktrees.first)
            let item = makeItem(
                id: "quick-open-worktree",
                action: .quickOpen(.worktree(worktreeStableKey: worktree.stableKey))
            )
            let dispatcher = FakeAppCommandDispatcher()
            let controller = makeController(store: store, dispatcher: dispatcher)
            controller.state.show(defaultScope: .quickOpen)
            controller.executeItem(item)

            #expect(dispatcher.targetedDispatches.first?.command == .openNewTerminalInTab)
            #expect(dispatcher.targetedDispatches.first?.target == worktree.id)
            #expect(dispatcher.targetedDispatches.first?.targetType == .worktree)

            let pane = store.createPane(title: "Current")
            let tab = Tab(paneId: pane.id, name: "Current")
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            store.setActivePane(pane.id, inTab: tab.id)
            controller.state.show(defaultScope: .quickOpen)
            controller.executeItem(item, modifier: .command)

            #expect(dispatcher.targetedDispatches.count == 2)
            #expect(dispatcher.targetedDispatches.last?.command == .openNewTerminalInTab)
            #expect(dispatcher.targetedDispatches.last?.target == worktree.id)
            #expect(dispatcher.targetedDispatches.last?.targetType == .worktree)
        }
    }

    @Test("Quick Open Option-Return is unavailable without a current tab")
    func quickOpenOptionReturnRequiresCurrentTab() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let repository = store.addRepo(at: URL(filePath: "/tmp/command-bar-quick-open-option"))
            let worktree = try #require(repository.worktrees.first)
            let dispatcher = FakeAppCommandDispatcher()
            let controller = makeController(store: store, dispatcher: dispatcher)
            controller.state.show(defaultScope: .quickOpen)

            controller.executeItem(
                makeItem(
                    id: "quick-open-option",
                    action: .quickOpen(.worktree(worktreeStableKey: worktree.stableKey))
                ),
                modifier: .option
            )

            #expect(dispatcher.targetedDispatches.isEmpty)
            #expect(controller.state.isVisible)

            let pane = store.createPane(title: "Current")
            let tab = Tab(paneId: pane.id, name: "Current")
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            store.setActivePane(pane.id, inTab: tab.id)
            controller.state.show(defaultScope: .quickOpen)
            controller.executeItem(
                makeItem(
                    id: "quick-open-option-active",
                    action: .quickOpen(.worktree(worktreeStableKey: worktree.stableKey))
                ),
                modifier: .option
            )

            #expect(dispatcher.targetedDispatches.count == 1)
            #expect(dispatcher.targetedDispatches.first?.command == .openWorktreeInPane)
            #expect(dispatcher.targetedDispatches.first?.target == worktree.id)
            #expect(dispatcher.targetedDispatches.first?.targetType == .worktree)
            #expect(!controller.state.isVisible)
        }
    }

    @Test("Quick Open directory Return uses the current tab while Command-Return uses a new tab")
    func quickOpenDirectoryReturnVariants() async throws {
        await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let pane = store.createPane(title: "Current")
            let tab = Tab(paneId: pane.id, name: "Current")
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            store.setActivePane(pane.id, inTab: tab.id)
            let directory = FileManager.default.temporaryDirectory.standardizedFileURL
            let item = makeItem(
                id: "quick-open-directory",
                action: .quickOpen(.directory(directory))
            )
            let dispatcher = FakeAppCommandDispatcher()
            let directoryRecorder = QuickOpenDirectoryRequestRecorder()
            let controller = makeController(
                store: store,
                dispatcher: dispatcher,
                quickOpenDirectoryHandler: directoryRecorder.record
            )
            controller.state.show(defaultScope: .quickOpen)
            controller.executeItem(item)

            #expect(directoryRecorder.requests.count == 1)
            #expect(directoryRecorder.requests.first?.directory == directory)
            #expect(directoryRecorder.requests.first?.placement == .currentTabPane)
            #expect(controller.state.recentItemIds.isEmpty)
            #expect(!controller.state.isVisible)

            controller.state.show(defaultScope: .quickOpen)
            controller.executeItem(item, modifier: .command)

            #expect(directoryRecorder.requests.count == 2)
            #expect(directoryRecorder.requests.last?.directory == directory)
            #expect(directoryRecorder.requests.last?.placement == .newTab)
            #expect(!controller.state.isVisible)
        }
    }

    @Test("Quick Open dispatches directory activation without synchronous filesystem validation")
    func quickOpenDispatchesDirectoryWithoutFilesystemValidation() async throws {
        await withAsyncTestCoreAtoms { _ in
            let missingDirectory = FileManager.default.temporaryDirectory
                .appending(path: "missing-quick-open-\(UUID().uuidString)")
            let dispatcher = FakeAppCommandDispatcher()
            let directoryRecorder = QuickOpenDirectoryRequestRecorder()
            let controller = makeController(
                dispatcher: dispatcher,
                quickOpenDirectoryHandler: directoryRecorder.record
            )
            controller.state.show(defaultScope: .quickOpen)
            controller.executeItem(
                makeItem(
                    id: "unchecked-quick-open-directory",
                    action: .quickOpen(.directory(missingDirectory))
                )
            )

            #expect(directoryRecorder.requests.count == 1)
            #expect(directoryRecorder.requests.first?.directory == missingDirectory.standardizedFileURL)
            #expect(!controller.state.isVisible)
        }
    }

    @Test("Quick Open actions enter the existing repository menu without dispatching")
    func quickOpenActionsEnterExistingMenu() async throws {
        await withAsyncTestCoreAtoms { _ in
            let store = WorkspaceStore()
            let repository = store.addRepo(at: URL(filePath: "/tmp/command-bar-quick-open-actions"))
            let dispatcher = FakeAppCommandDispatcher()
            let controller = makeController(store: store, dispatcher: dispatcher)
            controller.state.show(defaultScope: .quickOpen)

            controller.showActions(
                for: makeItem(
                    id: "quick-open-actions",
                    action: .quickOpen(
                        .repository(repositoryStableKey: repository.stableKey)
                    )
                )
            )

            #expect(dispatcher.dispatchedCommands.isEmpty)
            #expect(dispatcher.targetedDispatches.isEmpty)
            #expect(controller.state.currentLevel?.id == "level-repo-\(repository.id.uuidString)")
            #expect(controller.state.isVisible)
        }
    }
}

@MainActor
private final class QuickOpenDirectoryRequestRecorder {
    private(set) var requests: [(directory: URL, placement: QuickOpenDirectoryPlacement)] = []

    func record(
        directory: URL,
        placement: QuickOpenDirectoryPlacement
    ) {
        requests.append(
            (
                directory: directory,
                placement: placement
            )
        )
    }
}
