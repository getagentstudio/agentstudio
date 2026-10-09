import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCommandBar

@MainActor
@Suite("Command Bar command targeting", .serialized)
struct CommandBarCommandTargetingTests {
    private let recentsDefaultsFixture = CommandBarRecentsDefaultsFixture()

    init() {
        installTestCoreAtomsIfNeeded()
    }

    private let dispatcher = FakeAppCommandDispatcher()

    @Test("special-scope targeted rows follow declared target kinds")
    func specialScopeTargetedRowsFollowDeclaredTargetKinds() {
        #expect(
            CommandBarCommandPresentation.targetedSpec(
                for: .focusPane,
                targetType: .pane
            )?.command == .focusPane
        )
        #expect(
            CommandBarCommandPresentation.targetedSpec(
                for: .removeRepo,
                targetType: .worktree
            ) == nil
        )
    }

    @Test("special-scope contextual rows omit retired and non-contextual commands")
    func specialScopeContextualRowsOmitRetiredAndNonContextualCommands() {
        #expect(
            CommandBarCommandPresentation.contextualSpec(
                for: .clearReadInboxNotifications,
                commandContext: .empty
            ) == nil
        )
        #expect(
            CommandBarCommandPresentation.contextualSpec(
                for: .setInboxRowStateFilter,
                commandContext: .empty
            ) == nil
        )
        #expect(
            CommandBarCommandPresentation.contextualSpec(
                for: .openWorktree,
                commandContext: .empty
            ) == nil
        )
        #expect(
            CommandBarCommandPresentation.contextualSpec(
                for: .closeTab,
                commandContext: .empty
            ) == nil
        )
    }

    @Test("contextual-and-targeted target-selection command drills into declared targets")
    func contextualAndTargetedTargetSelectionCommandDrillsIntoDeclaredTargets() throws {
        let store = WorkspaceStore()
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)

        let items = commandItems(store: store)

        let closeTabItem = try #require(items.first { $0.id == "cmd-closeTab" })
        guard case .navigate(let targetLevel) = closeTabItem.action else {
            Issue.record("Expected target-selection-preferred Close Tab command to drill in")
            return
        }
        #expect(closeTabItem.hasChildren)
        #expect(targetLevel.items.map(\.id) == ["target-tab-\(tab.id.uuidString)"])
    }

    @Test("targeted-only command drills into target selection")
    func targetedOnlyCommandDrillsIntoTargetSelection() throws {
        let fixture = makeWorktreeFixture(includePane: false)

        let items = commandItems(store: fixture.store)

        let openWorktreeItem = try #require(items.first { $0.id == "cmd-openWorktree" })
        guard case .navigate(let targetLevel) = openWorktreeItem.action else {
            Issue.record("Expected targeted-only Open Worktree command to drill in")
            return
        }
        #expect(openWorktreeItem.hasChildren)
        #expect(targetLevel.items.map(\.id) == ["target-worktree-\(fixture.worktree.id.uuidString)"])
    }

    @Test("target builder omits undeclared target kinds")
    func targetBuilderOmitsUndeclaredTargetKinds() throws {
        let fixture = makeWorktreeFixture(includePane: true)

        let items = commandItems(store: fixture.store)

        let openWorktreeItem = try #require(items.first { $0.id == "cmd-openWorktree" })
        guard case .navigate(let targetLevel) = openWorktreeItem.action else {
            Issue.record("Expected targeted-only Open Worktree command to drill in")
            return
        }
        #expect(!targetLevel.items.isEmpty)
        #expect(targetLevel.items.allSatisfy { $0.id.hasPrefix("target-worktree-") })
    }

    @Test("targeted-only root stays enabled and opens its target level")
    func targetedOnlyRootStaysEnabledAndOpensTargetLevel() throws {
        let fixture = makeWorktreeFixture(includePane: false)
        let targetingAwareDispatcher = TargetingAwareCommandBarDispatcher()
        let state = CommandBarState()
        state.show(prefix: ">")
        let resultSession = CommandBarResultSession(
            store: fixture.store,
            repoCache: RepoCacheAtom(),
            dispatcher: targetingAwareDispatcher
        )
        let controller = CommandBarPanelController(
            store: fixture.store,
            octiconLoader: OcticonLoader(
                resourceRootURL: testAgentStudioResourceRootURL(from: #filePath)
            ),
            repoCache: RepoCacheAtom(),
            dispatcher: targetingAwareDispatcher,
            quickOpenDirectoryHandler: { _, _ in },
            commandBarSurface: CommandBarSurfaceAtom(),
            recentsDefaults: recentsDefaultsFixture.makeDefaults()
        )
        controller.state.show(prefix: ">")

        let snapshot = resultSession.snapshot(state: state)
        let openWorktreeItem = try #require(
            snapshot.displayedItems.first { $0.id == "cmd-openWorktree" }
        )
        controller.executeItem(openWorktreeItem)

        #expect(!snapshot.dimmedItemIds.contains(openWorktreeItem.id))
        #expect(
            controller.state.currentLevel?.items.map(\.id)
                == ["target-worktree-\(fixture.worktree.id.uuidString)"]
        )
    }

    @Test("targeted leaves use targeted capability for dimming")
    func targetedLeavesUseTargetedCapabilityForDimming() {
        let allowedTargetID = UUID()
        let blockedTargetID = UUID()
        let targetingAwareDispatcher = TargetingAwareCommandBarDispatcher(
            blockedTargetIDs: [blockedTargetID]
        )
        let state = CommandBarState()
        state.pushLevel(
            CommandBarLevel(
                id: "open-worktree-targets",
                title: "Open Worktree",
                items: [
                    CommandBarItem(
                        id: "allowed-worktree",
                        title: "Allowed",
                        group: "Worktrees",
                        groupPriority: 0,
                        action: .dispatchTargeted(
                            .openWorktree,
                            target: allowedTargetID,
                            targetType: .worktree
                        ),
                        command: .openWorktree
                    ),
                    CommandBarItem(
                        id: "blocked-worktree",
                        title: "Blocked",
                        group: "Worktrees",
                        groupPriority: 0,
                        action: .dispatchTargeted(
                            .openWorktree,
                            target: blockedTargetID,
                            targetType: .worktree
                        ),
                        command: .openWorktree
                    ),
                ]
            )
        )
        let resultSession = CommandBarResultSession(
            store: WorkspaceStore(),
            repoCache: RepoCacheAtom(),
            dispatcher: targetingAwareDispatcher
        )

        let snapshot = resultSession.snapshot(state: state)

        #expect(!snapshot.dimmedItemIds.contains("allowed-worktree"))
        #expect(snapshot.dimmedItemIds.contains("blocked-worktree"))
    }

    private func commandItems(store: WorkspaceStore) -> [CommandBarItem] {
        CommandBarDataSource.items(
            scope: .commands,
            store: store,
            repoCache: RepoCacheAtom(),
            dispatcher: dispatcher
        )
    }

    private func makeWorktreeFixture(
        includePane: Bool
    ) -> (store: WorkspaceStore, worktree: Worktree) {
        let store = WorkspaceStore()
        let repositoryPath = URL(filePath: "/tmp/command-bar-targeting-\(UUID().uuidString)")
        let repository = store.addRepo(at: repositoryPath)
        let worktree = Worktree(
            repoId: repository.id,
            name: "main",
            path: repositoryPath,
            isMainWorktree: true
        )
        store.reconcileDiscoveredWorktrees(repository.id, worktrees: [worktree])
        guard
            let resolvedWorktree = store.repositoryTopologyAtom
                .repo(repository.id)?
                .worktrees
                .first(where: \.isMainWorktree)
        else {
            preconditionFailure("Expected repository fixture to retain a main worktree")
        }

        if includePane {
            let pane = store.createPane(
                launchDirectory: resolvedWorktree.path,
                facets: PaneContextFacets(
                    repoId: repository.id,
                    worktreeId: resolvedWorktree.id,
                    cwd: resolvedWorktree.path
                )
            )
            let tab = Tab(paneId: pane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
        }

        return (store, resolvedWorktree)
    }
}

@MainActor
private final class TargetingAwareCommandBarDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    private let blockedTargetIDs: Set<UUID>

    init(blockedTargetIDs: Set<UUID> = []) {
        self.blockedTargetIDs = blockedTargetIDs
    }

    func dispatch(_: AppCommand) -> Bool { false }

    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}

    func canDispatch(_ command: AppCommand) -> Bool {
        command.definition.targeting.supportsContextualInvocation
    }

    func canDispatch(
        _ command: AppCommand,
        target: UUID,
        targetType: SearchItemType
    ) -> Bool {
        command.definition.targeting.supports(targetType: targetType)
            && !blockedTargetIDs.contains(target)
    }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? {
        nil
    }

    func dispatchMovePaneToTab(
        sourcePaneId _: UUID,
        sourceTabId _: UUID?,
        targetTabId _: UUID
    ) {}
}
