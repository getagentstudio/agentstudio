import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneTabViewControllerZoomDrawerSideCommandTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    private struct ZoomDrawerFixture {
        let harness: Harness
        let sourcePane: Pane
        let drawerChild: Pane
        let tab: Tab
    }

    private func makeZoomDrawerFixture(entersZoom: Bool = true) throws -> ZoomDrawerFixture {
        let harness = makeHarness()
        let sourcePane = harness.store.createPane()
        let tab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        let drawerChild = try #require(harness.store.addDrawerPane(to: sourcePane.id))
        if entersZoom {
            harness.store.panePresentationAtom.enterZoom(
                inTab: tab.id,
                sourcePaneId: sourcePane.id,
                viewerPresentation: .unavailableVisible
            )
        }
        return ZoomDrawerFixture(harness: harness, sourcePane: sourcePane, drawerChild: drawerChild, tab: tab)
    }

    private func zoomSide(_ fixture: ZoomDrawerFixture) -> DrawerZoomSide {
        fixture.harness.store.paneAtom.drawerPresentationPreference(forOwner: fixture.sourcePane.id).zoomSide
    }

    @Test("side command from the terminal targets the Zoom source drawer")
    func sideCommandFromTerminalFocus() async throws {
        let fixture = try makeZoomDrawerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.harness.tempDir) }
        atom(\.workspaceFocusOwner).focusMainPane(fixture.sourcePane.id)

        #expect(fixture.harness.controller.canExecute(.moveZoomDrawerToBridge))
        await fixture.harness.executeCommand(.moveZoomDrawerToBridge)

        #expect(zoomSide(fixture) == .bridge)
        await fixture.harness.executeCommand(.moveZoomDrawerToTerminal)
        #expect(zoomSide(fixture) == .terminal)
    }

    @Test("side command with a drawer child focused still targets the Zoom source")
    func sideCommandFromDrawerChildFocus() async throws {
        let fixture = try makeZoomDrawerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.harness.tempDir) }
        atom(\.workspaceFocusOwner).focusDrawerPane(
            parentPaneId: fixture.sourcePane.id,
            paneId: fixture.drawerChild.id
        )

        await fixture.harness.executeCommand(.moveZoomDrawerToBridge)

        #expect(zoomSide(fixture) == .bridge)
        #expect(
            fixture.harness.store.paneAtom.drawerPresentationPreference(forOwner: fixture.drawerChild.id)
                == .default
        )
    }

    @Test("side command with the Zoom companion Bridge focused still targets the Zoom source")
    func sideCommandFromBridgeCompanionFocus() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePane = harness.store.createPane()
        let tab = Tab(paneId: sourcePane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        _ = try #require(harness.store.addDrawerPane(to: sourcePane.id))
        let companion = ZoomCompanionMetadata(
            owningTabId: tab.id,
            resolvedWorktreeId: UUIDv7.generate(),
            companionPaneId: UUIDv7.generate(),
            lastZoomVisibility: .visible
        )
        harness.store.panePresentationAtom.cacheZoomCompanion(companion, forSourcePane: sourcePane.id)
        harness.store.panePresentationAtom.enterZoom(
            inTab: tab.id,
            sourcePaneId: sourcePane.id,
            viewerPresentation: .retainedVisible(companionPaneId: companion.companionPaneId)
        )
        let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let companionHost = try attachPaneHost(paneId: companion.companionPaneId, in: harness, to: window)
        #expect(window.makeFirstResponder(companionHost))
        atom(\.workspaceFocusOwner).focusMainPane(companion.companionPaneId)

        #expect(harness.controller.canExecute(.moveZoomDrawerToBridge))
        await harness.executeCommand(.moveZoomDrawerToBridge)

        #expect(window.firstResponder === companionHost)
        #expect(harness.store.paneAtom.drawerPresentationPreference(forOwner: sourcePane.id).zoomSide == .bridge)
        #expect(
            harness.store.paneAtom.drawerPresentationPreference(forOwner: companion.companionPaneId) == .default
        )

        await harness.executeCommand(.moveZoomDrawerToTerminal)
        #expect(harness.store.paneAtom.drawerPresentationPreference(forOwner: sourcePane.id).zoomSide == .terminal)
    }

    @Test("side commands are unavailable and inert outside Pane Zoom")
    func sideCommandRejectedOutsideZoom() async throws {
        let fixture = try makeZoomDrawerFixture(entersZoom: false)
        defer { try? FileManager.default.removeItem(at: fixture.harness.tempDir) }
        atom(\.workspaceFocusOwner).focusMainPane(fixture.sourcePane.id)

        #expect(!fixture.harness.controller.canExecute(.moveZoomDrawerToBridge))
        #expect(
            !fixture.harness.controller.canExecute(
                .moveZoomDrawerToBridge,
                target: fixture.sourcePane.id,
                targetType: .pane
            )
        )
        await fixture.harness.executeCommand(.moveZoomDrawerToBridge)
        await fixture.harness.executeCommand(
            .moveZoomDrawerToBridge,
            target: fixture.sourcePane.id,
            targetType: .pane
        )

        #expect(zoomSide(fixture) == .terminal)
        #expect(fixture.harness.store.paneAtom.drawerCursorAtom.presentationPreferenceRevision == 0)
    }

    @Test("targeted side command and a repeated side are an equal write")
    func targetedSideCommandEqualWrite() async throws {
        let fixture = try makeZoomDrawerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.harness.tempDir) }

        #expect(
            fixture.harness.controller.canExecute(
                .moveZoomDrawerToBridge,
                target: fixture.sourcePane.id,
                targetType: .pane
            )
        )
        await fixture.harness.executeCommand(
            .moveZoomDrawerToBridge,
            target: fixture.sourcePane.id,
            targetType: .pane
        )
        let revisionAfterMove = fixture.harness.store.paneAtom.drawerCursorAtom.presentationPreferenceRevision
        await fixture.harness.executeCommand(
            .moveZoomDrawerToBridge,
            target: fixture.sourcePane.id,
            targetType: .pane
        )

        #expect(zoomSide(fixture) == .bridge)
        #expect(revisionAfterMove == 1)
        #expect(fixture.harness.store.paneAtom.drawerCursorAtom.presentationPreferenceRevision == revisionAfterMove)
    }

    @Test("headless IPC side command applies in Zoom and is refused outside it")
    func headlessSideCommand() async throws {
        let zoomed = try makeZoomDrawerFixture()
        defer { try? FileManager.default.removeItem(at: zoomed.harness.tempDir) }
        let appliedOutcome = await zoomed.harness.controller.executeHeadlessIPC(
            try drawerParentRequest(.moveZoomDrawerToBridge, parentPaneId: zoomed.sourcePane.id)
        )
        #expect(appliedOutcome == .applied)
        #expect(zoomSide(zoomed) == .bridge)

        let normal = try makeZoomDrawerFixture(entersZoom: false)
        defer { try? FileManager.default.removeItem(at: normal.harness.tempDir) }
        let refusedOutcome = await normal.harness.controller.executeHeadlessIPC(
            try drawerParentRequest(.moveZoomDrawerToBridge, parentPaneId: normal.sourcePane.id)
        )
        #expect(refusedOutcome != .applied)
        #expect(zoomSide(normal) == .terminal)
    }

    @Test("side commands classify for IPC exactly like their drawer siblings")
    func sideCommandIPCClassificationMatchesToggleDrawer() {
        let sibling = AppCommand.toggleDrawer.ipcSpec
        for command in [AppCommand.moveZoomDrawerToTerminal, .moveZoomDrawerToBridge] {
            let spec = command.ipcSpec
            #expect(spec.exposure == .debugTesting)
            #expect(spec.exposure == sibling.exposure)
            #expect(spec.executionMode == sibling.executionMode)
            #expect(spec.argumentVariants == [.drawerParent])
            #expect(spec.requiredPrivilege == sibling.requiredPrivilege)
            #expect(spec.allowedTargetKinds == [.window, .pane])
            #expect(spec.resultVariants == sibling.resultVariants)
        }
    }

    @Test("move control appears only in Pane Zoom with the management layer and offers the other side")
    func moveControlPresence() {
        let command = DrawerPanelOverlay.moveControlCommand
        #expect(command(.zoom(effectiveSide: .terminal), true) == .moveZoomDrawerToBridge)
        #expect(command(.zoom(effectiveSide: .bridge), true) == .moveZoomDrawerToTerminal)
        #expect(command(.zoom(effectiveSide: .terminal), false) == nil)
        #expect(command(.normal, true) == nil)
    }

    enum ZoomAuthorityChange: CaseIterable, Sendable {
        case cancelZoom
        case retargetZoom
    }

    @Test(
        "move control task key changes when Zoom authority changes with the same command and target",
        arguments: [AppCommand.moveZoomDrawerToTerminal, .moveZoomDrawerToBridge], ZoomAuthorityChange.allCases
    )
    func moveControlKeyTracksZoomAuthority(command: AppCommand, authorityChange: ZoomAuthorityChange) async throws {
        let fixture = try makeZoomDrawerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.harness.tempDir) }
        try await withWorkspaceCommandHarness(fixture.harness) {
            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = fixture.harness.controller
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    let store = fixture.harness.store
                    let alternateSource = store.createPane()
                    #expect(
                        store.insertPane(
                            alternateSource.id, inTab: fixture.tab.id, at: fixture.sourcePane.id,
                            direction: .horizontal, position: .after, sizingMode: .halveTarget))
                    let windowId = UUIDv7.generate()
                    @MainActor func resolutionKey() -> DrawerPanelOverlay.MoveControlResolutionKey {
                        DrawerPanelOverlay.makeMoveControlResolutionKey(
                            command: command,
                            ownerPaneId: fixture.sourcePane.id,
                            tabId: fixture.tab.id,
                            workspaceWindowId: windowId,
                            zoomPresentation: store.panePresentationAtom.zoomPresentation(forTab: fixture.tab.id)
                        )
                    }
                    @MainActor func resolveAction() -> TargetedCommandControlAction? {
                        TargetedCommandControlAction.resolve(
                            command: command, surface: .inlineControl,
                            target: fixture.sourcePane.id, targetType: .pane,
                            dispatcher: AppCommandDispatcher.shared
                        )
                    }
                    let initialKey = resolutionKey()
                    let initialAction = try #require(resolveAction())
                    #expect(initialAction.isEnabled)

                    switch authorityChange {
                    case .cancelZoom:
                        store.panePresentationAtom.cancelZoom(inTab: fixture.tab.id)
                    case .retargetZoom:
                        #expect(
                            store.panePresentationAtom.retargetZoom(
                                inTab: fixture.tab.id, to: alternateSource.id,
                                viewerPresentation: .unavailableVisible))
                    }

                    let changedAction = try #require(resolveAction())
                    #expect(!changedAction.isEnabled)
                    let changedKey = resolutionKey()
                    #expect(changedKey != initialKey)
                    #expect(changedKey.command == initialKey.command)
                    #expect(changedKey.ownerPaneId == initialKey.ownerPaneId)
                    #expect(changedKey.tabId == initialKey.tabId)
                    #expect(changedKey.workspaceWindowId == initialKey.workspaceWindowId)

                    store.panePresentationAtom.enterZoom(
                        inTab: fixture.tab.id, sourcePaneId: fixture.sourcePane.id,
                        viewerPresentation: .unavailableVisible)
                    let restoredAction = try #require(resolveAction())
                    #expect(restoredAction.isEnabled)
                    #expect(resolutionKey() == initialKey)
                    #expect(resolutionKey() != changedKey)
                }
            )
        }
    }

    @Test("move control task key ignores viewer and split-ratio changes that preserve Zoom authority")
    func moveControlKeyIgnoresNonAuthorityZoomChanges() async throws {
        let fixture = try makeZoomDrawerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.harness.tempDir) }
        await withWorkspaceCommandHarness(fixture.harness) {
            let store = fixture.harness.store
            @MainActor func resolutionKey() -> DrawerPanelOverlay.MoveControlResolutionKey {
                DrawerPanelOverlay.makeMoveControlResolutionKey(
                    command: .moveZoomDrawerToBridge,
                    ownerPaneId: fixture.sourcePane.id,
                    tabId: fixture.tab.id,
                    workspaceWindowId: nil,
                    zoomPresentation: store.panePresentationAtom.zoomPresentation(forTab: fixture.tab.id)
                )
            }
            let initialKey = resolutionKey()

            #expect(store.panePresentationAtom.setZoomSplitRatio(0.5, inTab: fixture.tab.id))
            store.panePresentationAtom.enterZoom(
                inTab: fixture.tab.id, sourcePaneId: fixture.sourcePane.id,
                viewerPresentation: .retryable)

            #expect(resolutionKey() == initialKey)
        }
    }

    @Test("each side command's catalog icon points where the drawer will go")
    func sideCommandIconsPointTowardTheDestination() {
        #expect(AppCommand.moveZoomDrawerToBridge.definition.icon == .system(.arrowRight))
        #expect(AppCommand.moveZoomDrawerToTerminal.definition.icon == .system(.arrowLeft))
    }

    private func drawerParentRequest(
        _ command: AppCommand,
        parentPaneId: UUID
    ) throws -> AppCommandExecutionRequest {
        AppCommandExecutionRequest(
            command: command,
            arguments: .typedIPC(
                .drawerParent(
                    .init(
                        workspaceWindowId: UUIDv7.generate(),
                        parentPaneSelector: try IPCPaneSelector(rawValue: parentPaneId.uuidString)
                    )
                )
            ),
            executionContext: .headlessIPC(admitsDebugTestingCommands: true)
        )
    }
}
