import AgentStudioInfrastructure
import AgentStudioTerminal
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct MainSplitViewControllerCompositeCommandTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("visibility-only sidebar show preserves the exact terminal responder")
    func visibilityOnlySidebarShowPreservesTerminalResponder() async throws {
        try await withMainSplitViewControllerHarness(
            withRepos: true,
            configureUIState: { $0.setSidebarCollapsed(true) },
            body: { harness in
                let terminalResponder = try installMainSplitTerminalResponder(in: harness)
                #expect(harness.window.makeFirstResponder(terminalResponder))

                harness.controller.toggleSidebarFromCommand()

                #expect(!harness.controller.isSidebarCollapsed)
                #expect(harness.window.firstResponder === terminalResponder)
            }
        )
    }

    @Test("repeated focus-sidebar command restores its origin")
    func repeatedFocusSidebarCommandRestoresOrigin() async throws {
        try await withMainSplitViewControllerHarness(
            withRepos: true,
            configureUIState: { $0.setSidebarCollapsed(true) },
            body: { harness in
                let terminalResponder = try installMainSplitTerminalResponder(in: harness)
                #expect(harness.window.makeFirstResponder(terminalResponder))

                harness.controller.focusSidebarFromCommand()

                await eventually("focus command should expand and focus the sidebar host") {
                    !harness.controller.isSidebarCollapsed
                        && (harness.window.firstResponder as? NSView)?.identifier
                            == RepoExplorerView.focusTargetIdentifier
                }

                harness.controller.focusSidebarFromCommand()

                #expect(!harness.controller.isSidebarCollapsed)
                #expect(harness.window.firstResponder === terminalResponder)
            }
        )
    }

    @Test("Escape from the focused sidebar restores its origin")
    func escapeFromFocusedSidebarRestoresOrigin() async throws {
        try await withMainSplitViewControllerHarness(
            withRepos: true,
            configureUIState: { $0.setSidebarCollapsed(true) },
            body: { harness in
                let terminalResponder = try installMainSplitTerminalResponder(in: harness)
                #expect(harness.window.makeFirstResponder(terminalResponder))

                harness.controller.focusSidebarFromCommand()
                await eventually("focus command should expand and focus the sidebar host") {
                    !harness.controller.isSidebarCollapsed
                        && (harness.window.firstResponder as? NSView)?.identifier
                            == RepoExplorerView.focusTargetIdentifier
                }

                let escapeEvent = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: harness.window.windowNumber,
                        context: nil,
                        characters: "\u{1B}",
                        charactersIgnoringModifiers: "\u{1B}",
                        isARepeat: false,
                        keyCode: 53
                    )
                )
                harness.window.sendEvent(escapeEvent)

                #expect(!harness.controller.isSidebarCollapsed)
                #expect(harness.window.firstResponder === terminalResponder)
            }
        )
    }

    @Test("Escape through the Panes window responder returns to its mounted pane and cancels preview")
    func panesEscapeReturnsToMountedPane() async throws {
        try await withMainSplitViewControllerHarness(
            withRepos: true,
            configureUIState: {
                $0.setSidebarSurface(.panes)
                $0.setSidebarCollapsed(true)
            },
            body: { harness in
                let terminalResponder = try installMainSplitTerminalResponder(in: harness)
                #expect(harness.window.makeFirstResponder(terminalResponder))

                harness.controller.focusSidebarFromCommand()
                await eventually("Panes list should become the window responder") {
                    !harness.controller.isSidebarCollapsed
                        && (harness.window.firstResponder as? NSView)?.identifier
                            == RepoExplorerView.focusTargetIdentifier
                }
                let previewState = try #require(harness.controller.heldPanePreviewState)
                #expect(previewState.beginSpaceHold(requestedTarget: nil))

                let escapeEvent = try #require(
                    NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: harness.window.windowNumber,
                        context: nil,
                        characters: "\u{1B}",
                        charactersIgnoringModifiers: "\u{1B}",
                        isARepeat: false,
                        keyCode: 53
                    )
                )
                harness.window.sendEvent(escapeEvent)

                #expect(harness.window.firstResponder === terminalResponder)
                #expect(!previewState.isHeld)
            }
        )
    }

    @Test("hiding a focused sidebar restores the terminal responder")
    func hidingFocusedSidebarRestoresTerminalResponder() async throws {
        try await withMainSplitViewControllerHarness(
            withRepos: true,
            body: { harness in
                let terminalResponder = try installMainSplitTerminalResponder(in: harness)
                #expect(harness.window.makeFirstResponder(terminalResponder))

                harness.controller.focusSidebarFromCommand()
                await eventually("focus command should focus the sidebar host") {
                    (harness.window.firstResponder as? NSView)?.identifier
                        == RepoExplorerView.focusTargetIdentifier
                }

                harness.controller.toggleSidebarFromCommand()

                #expect(harness.controller.isSidebarCollapsed)
                #expect(harness.window.firstResponder === terminalResponder)
            }
        )
    }

    @Test("accepted R and P commands rebuild the sidebar then restore the exact terminal origin")
    func sidebarScreenCommandsRestoreTerminalOriginAfterSurfaceChange() async throws {
        let interactionProbe = MainSplitSidebarCommandInteractionProbe()
        let shellOwner = MainSplitSidebarShellCommandOwner()
        let dispatcher = CommandDispatcherFixtureConfiguration(shellOwner: shellOwner).makeDispatcher()
        var previewEligibilityLoss: (@MainActor () -> Void)?

        try await withMainSplitViewControllerHarness(
            withRepos: true,
            paneTabRegistersAsCommandHandler: true,
            commandDispatcher: dispatcher,
            configureUIState: { $0.setSidebarSurface(.repos) },
            configureSidebarDependencies: { dependencies in
                previewEligibilityLoss = dependencies.onPreviewEligibilityLoss
            },
            sidebarRootViewBuilder: { uiState, onReturn in
                AnyView(
                    MainSplitSidebarCommandTestView(
                        uiState: uiState,
                        interactionProbe: interactionProbe,
                        onReturn: onReturn,
                        onPreviewEligibilityLoss: { previewEligibilityLoss?() },
                        onCommandRequest: { dispatcher.dispatch($0) }
                    )
                )
            },
            body: { harness in
                let pane = harness.store.createPane()
                let tab = Tab(paneId: pane.id)
                harness.store.appendTab(tab)
                let drawerPane = try #require(
                    harness.store.paneAtom.addDrawerPane(
                        to: pane.id,
                        parentFallbackCWD: nil,
                        zmxSessionID: .generateUUIDv7()
                    )
                )
                harness.store.panePresentationAtom.enterZoom(
                    inTab: tab.id,
                    sourcePaneId: pane.id,
                    viewerPresentation: .unavailable
                )
                let terminalResponder = TerminalPaneMountView(
                    surfaceOperations: makeAppTerminalFixtureMountOperations(), paneId: pane.id, title: "Terminal")
                terminalResponder.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
                let paneView = try #require(harness.controller.splitViewItems.last?.viewController.view)
                paneView.addSubview(terminalResponder)
                shellOwner.controller = harness.controller

                try await withCommandDispatcher(
                    dispatcher,
                    body: { _ in
                        for (key, keyCode, destination) in [
                            ("p", UInt16(35), SidebarSurface.panes),
                            ("r", UInt16(15), SidebarSurface.repos),
                        ] {
                            #expect(harness.window.makeFirstResponder(terminalResponder))
                            harness.controller.focusSidebarFromCommand()
                            await eventually("sidebar list should become the active keyboard owner") {
                                interactionProbe.interaction?.isListKeyboardActive == true
                            }
                            let previewState = try #require(harness.controller.heldPanePreviewState)
                            #expect(previewState.beginSpaceHold(requestedTarget: nil))
                            #expect(previewState.isHeld)

                            let host = try #require(
                                firstMainSplitCommandDescendant(
                                    RepoExplorerMaterializationHost.self,
                                    in: harness.controller.view
                                )
                            )
                            host.keyDown(
                                with: try #require(
                                    NSEvent.keyEvent(
                                        with: .keyDown,
                                        location: .zero,
                                        modifierFlags: [],
                                        timestamp: 0,
                                        windowNumber: harness.window.windowNumber,
                                        context: nil,
                                        characters: key,
                                        charactersIgnoringModifiers: key,
                                        isARepeat: false,
                                        keyCode: keyCode
                                    )
                                )
                            )

                            #expect(harness.atoms.core.workspaceSidebarState.sidebarSurface == destination)
                            #expect(harness.window.firstResponder === terminalResponder)
                            #expect(interactionProbe.interaction?.isListKeyboardActive == false)
                            #expect(!previewState.isHeld)
                            #expect(
                                harness.store.panePresentationAtom.zoomPresentation(forTab: tab.id)?
                                    .sourcePaneId == pane.id
                            )
                            #expect(harness.store.paneAtom.pane(pane.id)?.drawer?.paneIds == [drawerPane.id])
                        }
                    }
                )
            }
        )
    }

    @Test("sidebar filter focuses Panes without switching screens")
    func sidebarFilterPreservesPanesScreen() async {
        await withMainSplitViewControllerHarness(
            withRepos: true,
            configureUIState: {
                $0.setSidebarSurface(.panes)
                $0.setFilterVisible(false)
            },
            body: { harness in
                harness.controller.showSidebarFilter()
                #expect(harness.atoms.core.workspaceSidebarState.sidebarSurface == .panes)
                #expect(harness.atoms.core.workspaceSidebarState.isFilterVisible)
            }
        )
    }

    @Test("retired Inbox commands have no interactive presentation")
    func retiredInboxCommandsHaveNoInteractivePresentation() {
        #expect(AppCommand.showInboxNotifications.definition.surfacePolicy == .notPresented)
        #expect(AppCommand.clearReadInboxNotifications.definition.surfacePolicy == .notPresented)
        #expect(AppCommand.showPaneInboxNotifications.definition.surfacePolicy == .notPresented)
        #expect(AppCommand.clearPaneInboxNotifications.definition.surfacePolicy == .notPresented)
    }

    @Test("legacy Inbox sidebar state normalizes before controller composition")
    func legacyInboxSidebarStateNormalizesBeforeControllerComposition() async {
        await withMainSplitViewControllerHarness(
            withRepos: true,
            configureUIState: {
                $0.setSidebarCollapsed(true)
                $0.setSidebarSurface(.inbox)
            },
            body: { harness in
                #expect(harness.atoms.core.workspaceSidebarState.sidebarSurface == .repos)

                harness.controller.showWorktreeSidebar()

                await eventually("Repo Explorer should expand from legacy restored state") {
                    harness.controller.isSidebarCollapsed == false
                        && harness.atoms.core.workspaceSidebarState.sidebarCollapsed == false
                        && harness.atoms.core.workspaceSidebarState.sidebarSurface == .repos
                }
            }
        )
    }

    @Test("showWorktreeSidebar toggles the sole visible sidebar")
    func showWorktreeSidebarTogglesSoleVisibleSidebar() async {
        await withMainSplitViewControllerHarness(
            withRepos: true,
            body: { harness in
                #expect(harness.controller.isSidebarCollapsed == false)
                #expect(harness.atoms.core.workspaceSidebarState.sidebarSurface == .repos)

                harness.controller.showWorktreeSidebar()

                await eventually("visible Repo Explorer should collapse on toggle") {
                    harness.controller.isSidebarCollapsed
                        && harness.atoms.core.workspaceSidebarState.sidebarCollapsed
                        && harness.atoms.core.workspaceSidebarState.sidebarHasFocus == false
                }
            }
        )
    }
}

@MainActor
private func installMainSplitTerminalResponder(
    in harness: MainSplitViewControllerHarness
) throws -> TerminalPaneMountView {
    let pane = harness.store.createPane()
    let tab = Tab(paneId: pane.id)
    harness.store.appendTab(tab)
    harness.store.setActiveTab(tab.id)
    let terminalResponder = TerminalPaneMountView(
        surfaceOperations: makeAppTerminalFixtureMountOperations(), paneId: pane.id, title: "Terminal")
    terminalResponder.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    let paneView = try #require(
        harness.controller.splitViewItems.last?.viewController.view
    )
    paneView.addSubview(terminalResponder)
    return terminalResponder
}

@MainActor
private func firstMainSplitCommandDescendant<ViewType: NSView>(
    _ type: ViewType.Type,
    in view: NSView
) -> ViewType? {
    if let match = view as? ViewType { return match }
    for subview in view.subviews {
        if let match = firstMainSplitCommandDescendant(type, in: subview) {
            return match
        }
    }
    return nil
}

@MainActor
private final class MainSplitSidebarCommandInteractionProbe {
    weak var interaction: RepoExplorerKeyboardInteraction?
}

private struct MainSplitSidebarCommandTestView: NSViewRepresentable {
    let uiState: WorkspaceSidebarState
    let interactionProbe: MainSplitSidebarCommandInteractionProbe
    let onReturn: () -> Void
    let onPreviewEligibilityLoss: () -> Void
    let onCommandRequest: @MainActor (AppCommand) -> Bool

    func makeCoordinator() -> RepoExplorerKeyboardInteraction {
        let interaction = RepoExplorerKeyboardInteraction()
        interactionProbe.interaction = interaction
        return interaction
    }

    func makeNSView(context: Context) -> RepoExplorerMaterializationHost {
        let host = RepoExplorerMaterializationHost(
            lifetimeID: RepoExplorerMaterializationHostLifetimeID(rawValue: UUIDv7.generate()),
            initialDemandEpoch: 1,
            initialPresentation: .noRepositories,
            makeContentChild: { preconditionFailure("Command integration fixture remains rowless") },
            onFeedback: { _ in }
        )
        host.identifier = RepoExplorerView.focusTargetIdentifier
        configure(context.coordinator)
        host.installKeyboardInteraction(context.coordinator)
        return host
    }

    func updateNSView(_ nsView: RepoExplorerMaterializationHost, context: Context) {
        configure(context.coordinator)
    }

    static func dismantleNSView(
        _ nsView: RepoExplorerMaterializationHost,
        coordinator: RepoExplorerKeyboardInteraction
    ) {
        MainActor.assumeIsolated { nsView.detach() }
    }

    private func configure(_ interaction: RepoExplorerKeyboardInteraction) {
        interaction.configure(
            RepoExplorerKeyboardCallbacks(
                canInterpretListInput: { true },
                onPreviewEligibilityLoss: onPreviewEligibilityLoss,
                onReturnFocusRequest: onReturn,
                onSidebarFocusChange: { uiState.setSidebarHasFocus($0) },
                onCommandRequest: onCommandRequest
            )
        )
    }
}

@MainActor
private final class MainSplitSidebarShellCommandOwner: ShellCommandHandling {
    weak var controller: MainSplitViewController?
    private var sidebarState: WorkspaceSidebarState { atom(\.workspaceSidebarState) }

    func canExecute(_ command: AppCommand) -> Bool {
        command == .showReposSidebar || command == .showPanesSidebar
    }

    func execute(_ command: AppCommand) -> Bool {
        let surface: SidebarSurface
        switch command {
        case .showReposSidebar:
            surface = .repos
        case .showPanesSidebar:
            surface = .panes
        default:
            return false
        }
        sidebarState.setSidebarSurface(surface)
        controller?.expandSidebar()
        return sidebarState.sidebarSurface == surface && !sidebarState.sidebarCollapsed
    }

    func execute(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool {
        false
    }

    func showRepoCommandBar() {}
    func refreshWorktrees() {}
    func refocusActivePane() {}
}
