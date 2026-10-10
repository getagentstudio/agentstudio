import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioInfrastructure
@testable import AgentStudioSharedComponents

@MainActor
@Suite("Pane surface toolbar pull request action", .serialized)
struct PaneSurfaceToolbarHostPullRequestTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    @Test("exact branch PR mounts Open PR and dispatches its pane-targeted command")
    func exactPullRequestMountsAndDispatchesPaneTargetedCommand() throws {
        let exactURL = URL(string: "https://github.com/ShravanSunder/agentstudio/pull/264")!
        let fixture = try makeFixture(
            pullRequestFacts: PullRequestFacts(openCount: 1, exactOpenURL: exactURL)
        )
        let dispatcher = PullRequestCommandDispatcher(enabledPaneIds: [fixture.paneId])
        let mount = mountToolbar(fixture: fixture, dispatcher: dispatcher)
        defer {
            mount.window.orderOut(nil)
            mount.window.close()
        }

        let button = try #require(
            findAccessibilityPressBridge(
                in: mount.hostingView,
                identifier: "paneSurfaceToolbar.pullRequest"
            )
        )

        #expect(button.accessibilityLabel() == "Open PR, checks unknown")
        #expect(button.isAccessibilityEnabled())
        #expect(button.accessibilityPerformPress())
        #expect(
            dispatcher.dispatchedCommands == [
                .init(command: .openPullRequest, target: fixture.paneId, targetType: .pane)
            ]
        )
    }

    @Test("PR control remains visible and disabled without an exact URL")
    func pullRequestControlWithoutExactURLIsVisibleAndDisabled() throws {
        for pullRequestFacts in [nil, PullRequestFacts(openCount: 0, exactOpenURL: nil)] {
            let fixture = try makeFixture(pullRequestFacts: pullRequestFacts)
            let dispatcher = PullRequestCommandDispatcher(enabledPaneIds: [])
            let mount = mountToolbar(fixture: fixture, dispatcher: dispatcher)
            defer {
                mount.window.orderOut(nil)
                mount.window.close()
            }

            let button = try #require(
                findAccessibilityPressBridge(
                    in: mount.hostingView,
                    identifier: "paneSurfaceToolbar.pullRequest"
                )
            )
            #expect(!button.isAccessibilityEnabled())
            #expect(!button.accessibilityPerformPress())
            #expect(dispatcher.dispatchedCommands.isEmpty)
        }
    }

    @Test("non-CI blocker mounts beside the independently clickable PR action")
    func nonCIBlockerMountsBesideIndependentlyClickablePullRequestAction() throws {
        let exactURL = URL(string: "https://github.com/ShravanSunder/agentstudio/pull/264")!
        let fixture = try makeFixture(
            pullRequestFacts: PullRequestFacts(
                openCount: 1,
                exactOpenURL: exactURL,
                exactReadiness: PullRequestReadiness(
                    isDraft: false,
                    checkStatus: .passed,
                    reviewStatus: .changesRequested,
                    mergeability: .mergeable,
                    mergeState: .blocked
                )
            )
        )
        let dispatcher = PullRequestCommandDispatcher(enabledPaneIds: [fixture.paneId])
        let mount = mountToolbar(fixture: fixture, dispatcher: dispatcher)
        defer {
            mount.window.orderOut(nil)
            mount.window.close()
        }

        let blockerIndicator = try #require(
            findAccessibilityLabelBridge(
                in: mount.hostingView,
                identifier: "paneSurfaceToolbar.pullRequestBlocker"
            )
        )
        let pullRequestButton = try #require(
            findAccessibilityPressBridge(
                in: mount.hostingView,
                identifier: "paneSurfaceToolbar.pullRequest"
            )
        )

        #expect(blockerIndicator.accessibilityLabel() == "Changes requested")
        #expect(pullRequestButton.accessibilityLabel() == "Open PR, checks passed")
        #expect(pullRequestButton.accessibilityPerformPress())
        #expect(
            dispatcher.dispatchedCommands == [
                .init(command: .openPullRequest, target: fixture.paneId, targetType: .pane)
            ]
        )
    }

    private func makeFixture(pullRequestFacts: PullRequestFacts?) throws -> PullRequestToolbarFixture {
        let store = WorkspaceStore()
        let cache = RepoCacheAtom()
        let repo = store.addRepo(at: URL(fileURLWithPath: "/tmp/agentstudio-pr-button"))
        let worktree = try #require(
            store.repos.first(where: { $0.id == repo.id })?.worktrees.first
        )
        let pane = store.createPane(
            launchDirectory: worktree.path,
            title: "Terminal",
            facets: PaneContextFacets(
                repoId: repo.id,
                worktreeId: worktree.id,
                cwd: worktree.path
            )
        )
        store.appendTab(Tab(paneId: pane.id))
        cache.setRepoEnrichment(
            .resolvedRemote(
                repoId: repo.id,
                raw: RawRepoOrigin(
                    origin: "git@github.com:ShravanSunder/agentstudio.git",
                    upstream: nil
                ),
                identity: RepoIdentity(
                    groupKey: "remote:ShravanSunder/agentstudio",
                    remoteSlug: "ShravanSunder/agentstudio",
                    organizationName: "ShravanSunder",
                    displayName: "agentstudio"
                ),
                updatedAt: Date()
            )
        )
        cache.setWorktreeEnrichment(
            WorktreeEnrichment(
                worktreeId: worktree.id,
                repoId: repo.id,
                branch: "feature/pr-toolbar"
            )
        )
        if let pullRequestFacts {
            let branchKey = RepoBranchKey(repoId: repo.id, branch: "feature/pr-toolbar")!
            cache.applyPullRequestFacts([branchKey: pullRequestFacts])
        }

        return PullRequestToolbarFixture(
            store: store,
            cache: cache,
            paneId: pane.id
        )
    }

    private func mountToolbar(
        fixture: PullRequestToolbarFixture,
        dispatcher: PullRequestCommandDispatcher
    ) -> MountedToolbar {
        let hostingView = NSHostingView(
            rootView: AnyView(
                PaneSurfaceToolbarHost(
                    anchorPaneId: fixture.paneId,
                    locationTargetPaneId: fixture.paneId,
                    toolbarSurface: .pane,
                    drawer: nil,
                    leadingToolbarActions: [],
                    contextToolbarActions: [],
                    store: fixture.store,
                    repoCache: fixture.cache,
                    octiconLoader: makeTestOcticonLoader(),
                    editorChooser: EditorChooserState(),
                    paneInboxPresentation: nil,
                    workspaceWindowId: nil,
                    actionDispatcher: PaneTabActionDispatcher(
                        dispatch: { _ in },
                        shouldHandleSplitDragPayload: { _ in false },
                        shouldAcceptDrop: { _, _, _, _ in false },
                        handleDrop: { _, _, _, _ in }
                    ),
                    commandDispatcher: AppTerminalFixtureCommandDispatcher(), onPaneFocusTrigger: { _ in },
                    targetedCommandActionResolver: { command, surface, target, targetType in
                        TargetedCommandControlAction.resolve(
                            command: command,
                            surface: surface,
                            target: target,
                            targetType: targetType,
                            dispatcher: dispatcher
                        )
                    }
                )
                .frame(width: 640, height: 44)
            )
        )
        hostingView.frame = CGRect(x: 0, y: 0, width: 640, height: 44)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        return MountedToolbar(hostingView: hostingView, window: window)
    }

    private func findAccessibilityPressBridge(
        in root: NSView,
        identifier: String
    ) -> AccessibilityPressBridgeView? {
        if let bridge = root as? AccessibilityPressBridgeView,
            bridge.accessibilityIdentifier() == identifier
        {
            return bridge
        }
        for subview in root.subviews {
            if let bridge = findAccessibilityPressBridge(in: subview, identifier: identifier) {
                return bridge
            }
        }
        return nil
    }

    private func findAccessibilityLabelBridge(
        in root: NSView,
        identifier: String
    ) -> AccessibilityLabelBridgeView? {
        if let bridge = root as? AccessibilityLabelBridgeView,
            bridge.accessibilityIdentifier() == identifier
        {
            return bridge
        }
        for subview in root.subviews {
            if let bridge = findAccessibilityLabelBridge(in: subview, identifier: identifier) {
                return bridge
            }
        }
        return nil
    }
}

@MainActor
private struct PullRequestToolbarFixture {
    let store: WorkspaceStore
    let cache: RepoCacheAtom
    let paneId: UUID
}

@MainActor
private struct MountedToolbar {
    let hostingView: NSHostingView<AnyView>
    let window: NSWindow
}

@MainActor
private struct PullRequestDispatchedCommand: Equatable {
    let command: AppCommand
    let target: UUID
    let targetType: SearchItemType
}

@MainActor
private final class PullRequestCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    let enabledPaneIds: Set<UUID>
    private(set) var dispatchedCommands: [PullRequestDispatchedCommand] = []

    init(enabledPaneIds: Set<UUID>) {
        self.enabledPaneIds = enabledPaneIds
    }

    func dispatch(_: AppCommand) -> Bool { false }

    func dispatch(_ command: AppCommand, target: UUID, targetType: SearchItemType) {
        dispatchedCommands.append(
            PullRequestDispatchedCommand(
                command: command,
                target: target,
                targetType: targetType
            )
        )
    }

    func canDispatch(_: AppCommand) -> Bool {
        false
    }

    func canDispatch(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        command == .openPullRequest && targetType == .pane && enabledPaneIds.contains(target)
    }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }

    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
