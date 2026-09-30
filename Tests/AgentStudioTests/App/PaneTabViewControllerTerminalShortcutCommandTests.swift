import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneTabViewControllerTerminalShortcutCommandTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("seven terminal navigation keys target the focused drawer pane")
    func terminalNavigationKeysTargetFocusedDrawerPane() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            configureMainWindowKeyboardOwner(atoms)

            let parentPane = harness.store.createPane()
            let tab = Tab(paneId: parentPane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(parentPane.id, inTab: tab.id)

            let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
            let drawerId = try #require(harness.store.pane(parentPane.id)?.drawer?.drawerId)
            harness.store.tabArrangementAtom.addDrawerPaneView(
                drawerId: drawerId,
                parentPaneId: parentPane.id,
                drawerPaneId: drawerPane.id,
                inTab: tab.id
            )
            harness.store.setActiveDrawerPane(drawerPane.id, in: parentPane.id)
            atoms.workspaceFocusOwner.focusDrawerPane(parentPaneId: parentPane.id, paneId: drawerPane.id)

            let parentRuntime = RecordingCommandPaneRuntime(paneId: PaneId(existingUUID: parentPane.id))
            let drawerRuntime = RecordingCommandPaneRuntime(paneId: PaneId(existingUUID: drawerPane.id))
            harness.runtimeRegistry.register(parentRuntime)
            harness.runtimeRegistry.register(drawerRuntime)

            let events = try makeTerminalNavigationKeyEvents()

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = harness.controller
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    for (index, event) in events.enumerated() {
                        #expect(harness.controller.handleAppOwnedKeyEvent(event))
                        await waitForRecordedCommands(on: drawerRuntime, count: index + 1)
                    }
                    #expect(parentRuntime.receivedCommands.isEmpty)
                    #expect(drawerRuntime.receivedCommands.count == 7)
                    for command in drawerRuntime.receivedCommands {
                        #expect(command.targetPaneId == PaneId(existingUUID: drawerPane.id))
                    }
                    expectSettledTerminalNavigationCommands(drawerRuntime.receivedCommands)
                }
            )
        }
    }

    @Test("cmd k through controller key path is swallowed")
    func handleAppOwnedKeyEvent_cmdK_swallowsClearScrollback() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            configureMainWindowKeyboardOwner(atoms)

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.command],
                    characters: "k",
                    charactersIgnoringModifiers: "k",
                    keyCode: 40
                )
            )

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = harness.controller
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    #expect(harness.controller.handleAppOwnedKeyEvent(event))
                }
            )
        }
    }

    @Test("cmd shift k is swallowed when sidebar owns keyboard")
    func handleAppOwnedKeyEvent_cmdShiftK_sidebarFocusSwallowsWithoutDispatch() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            configureMainWindowKeyboardOwner(atoms)
            atoms.workspaceSidebarState.setSidebarSurface(.inbox)
            atoms.workspaceSidebarState.setSidebarHasFocus(true)

            let pane = harness.store.createPane()
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(pane.id, inTab: tab.id)
            atoms.workspaceFocusOwner.focusMainPane(pane.id)

            let runtime = RecordingCommandPaneRuntime(paneId: PaneId(existingUUID: pane.id))
            harness.runtimeRegistry.register(runtime)

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.command, .shift],
                    characters: "K",
                    charactersIgnoringModifiers: "k",
                    keyCode: 40
                )
            )

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = harness.controller
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    #expect(harness.controller.handleAppOwnedKeyEvent(event))
                    await waitForRecordedCommands(on: runtime, count: 1, maxTurns: 5)
                    #expect(runtime.receivedCommands.isEmpty)
                }
            )
        }
    }

    @Test("cmd shift k is swallowed when focused pane is not terminal")
    func handleAppOwnedKeyEvent_cmdShiftK_nonTerminalPaneSwallowsWithoutDispatch() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            configureMainWindowKeyboardOwner(atoms)

            let pane = harness.store.createPane(
                content: .webview(WebviewState(url: try #require(URL(string: "https://example.com")))),
                metadata: PaneMetadata(
                    contentType: .browser,
                    title: "Browser"
                )
            )
            let tab = Tab(paneId: pane.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            harness.store.setActivePane(pane.id, inTab: tab.id)
            atoms.workspaceFocusOwner.focusMainPane(pane.id)

            let runtime = RecordingCommandPaneRuntime(paneId: PaneId(existingUUID: pane.id))
            harness.runtimeRegistry.register(runtime)

            let event = try #require(
                makeKeyEvent(
                    modifierFlags: [.command, .shift],
                    characters: "K",
                    charactersIgnoringModifiers: "k",
                    keyCode: 40
                )
            )

            try await withIsolatedCommandDispatcher(
                configure: {
                    AppCommandDispatcher.shared.handler = harness.controller
                    AppCommandDispatcher.shared.appCommandRouter = nil
                },
                body: {
                    #expect(harness.controller.handleAppOwnedKeyEvent(event))
                    await waitForRecordedCommands(on: runtime, count: 1, maxTurns: 5)
                    #expect(runtime.receivedCommands.isEmpty)
                }
            )
        }
    }

    @Test("targeted terminal navigation targets the requested drawer pane")
    func executeTargetedTerminalNavigation_targetsRequestedDrawerPane() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }

        let parentPane = harness.store.createPane()
        let tab = Tab(paneId: parentPane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(parentPane.id, inTab: tab.id)

        let drawerPane = try #require(harness.store.addDrawerPane(to: parentPane.id))
        let drawerId = try #require(harness.store.pane(parentPane.id)?.drawer?.drawerId)
        harness.store.tabArrangementAtom.addDrawerPaneView(
            drawerId: drawerId,
            parentPaneId: parentPane.id,
            drawerPaneId: drawerPane.id,
            inTab: tab.id
        )
        harness.store.setActiveDrawerPane(drawerPane.id, in: parentPane.id)
        atom(\.workspaceFocusOwner).focusMainPane(parentPane.id)

        let parentRuntime = RecordingCommandPaneRuntime(paneId: PaneId(existingUUID: parentPane.id))
        let drawerRuntime = RecordingCommandPaneRuntime(paneId: PaneId(existingUUID: drawerPane.id))
        harness.runtimeRegistry.register(parentRuntime)
        harness.runtimeRegistry.register(drawerRuntime)

        harness.controller.execute(.scrollToBottom, target: drawerPane.id, targetType: .pane)
        harness.controller.execute(.scrollSmallStepDown, target: drawerPane.id, targetType: .pane)

        await waitForRecordedCommands(on: drawerRuntime, count: 2)
        #expect(parentRuntime.receivedCommands.isEmpty)
        #expect(drawerRuntime.receivedCommands.count == 2)
        for command in drawerRuntime.receivedCommands {
            #expect(command.targetPaneId == PaneId(existingUUID: drawerPane.id))
        }
        guard case .terminal(.scrollToBottom) = drawerRuntime.receivedCommands[0].command else {
            Issue.record("Expected targeted drawer pane to receive scrollToBottom")
            return
        }
        expectFractionalScroll(
            drawerRuntime.receivedCommands[1],
            fraction: AppPolicies.TerminalNavigation.smallStepFraction
        )
    }

    @Test("headless scroll commands issue the interactive fractions without moving focus or selection")
    func headlessScrollCommandsUseInteractiveFractions() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let parentPane = harness.store.createPane()
        let tab = Tab(paneId: parentPane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)
        harness.store.setActivePane(parentPane.id, inTab: tab.id)
        let selectedChild = try #require(harness.store.addDrawerPane(to: parentPane.id))
        let scrolledChild = try #require(harness.store.addDrawerPane(to: parentPane.id))
        harness.store.setActiveDrawerPane(selectedChild.id, in: parentPane.id)
        atom(\.workspaceFocusOwner).focusMainPane(parentPane.id)
        let scrolledRuntime = RecordingCommandPaneRuntime(paneId: PaneId(existingUUID: scrolledChild.id))
        harness.runtimeRegistry.register(scrolledRuntime)
        let focusOwnerBefore = atom(\.workspaceFocusOwner).owner

        var outcomes: [AppCommandExecutionOutcome] = []
        for command in [AppCommand.scrollPageDown, .scrollSmallStepUp, .scrollSmallStepDown] {
            outcomes.append(try await harness.executeHeadlessPaneCommand(command, paneId: scrolledChild.id))
        }

        #expect(outcomes == [.applied, .applied, .applied])
        #expect(scrolledRuntime.receivedCommands.count == 3)
        let fractions = [
            AppPolicies.TerminalNavigation.pageFraction,
            -AppPolicies.TerminalNavigation.smallStepFraction,
            AppPolicies.TerminalNavigation.smallStepFraction,
        ]
        for (envelope, fraction) in zip(scrolledRuntime.receivedCommands, fractions) {
            #expect(envelope.targetPaneId == PaneId(existingUUID: scrolledChild.id))
            expectFractionalScroll(envelope, fraction: fraction)
        }
        #expect(atom(\.workspaceFocusOwner).owner == focusOwnerBefore)
        #expect(harness.store.drawerView(forParent: parentPane.id)?.activeChildId == selectedChild.id)
        #expect(harness.store.tabLayoutAtom.tab(tab.id)?.activePaneId == parentPane.id)
    }

    private func makeTerminalNavigationKeyEvents() throws -> [NSEvent] {
        let bindings: [(NSEvent.ModifierFlags, String, UInt16)] = [
            ([.command, .shift], "I", 34),
            ([.command, .shift], "K", 40),
            ([.command, .shift], "J", 38),
            ([.command, .shift], "L", 37),
            ([.option, .shift], "J", 38),
            ([.option, .shift], "L", 37),
            ([.command, .option], "k", 40),
        ]
        return try bindings.map { modifiers, characters, keyCode in
            try #require(
                makeKeyEvent(
                    modifierFlags: modifiers,
                    characters: characters,
                    charactersIgnoringModifiers: characters.lowercased(),
                    keyCode: keyCode
                )
            )
        }
    }

    private func expectSettledTerminalNavigationCommands(_ envelopes: [RuntimeCommandEnvelope]) {
        guard envelopes.count == 7 else { return }
        expectFractionalScroll(envelopes[0], fraction: -AppPolicies.TerminalNavigation.pageFraction)
        expectFractionalScroll(envelopes[1], fraction: AppPolicies.TerminalNavigation.pageFraction)
        expectFractionalScroll(envelopes[2], fraction: -AppPolicies.TerminalNavigation.smallStepFraction)
        expectFractionalScroll(envelopes[3], fraction: AppPolicies.TerminalNavigation.smallStepFraction)
        guard case .terminal(.jumpToPrompt(delta: -1)) = envelopes[4].command else {
            Issue.record("Expected previous-prompt command")
            return
        }
        guard case .terminal(.jumpToPrompt(delta: 1)) = envelopes[5].command else {
            Issue.record("Expected next-prompt command")
            return
        }
        guard case .terminal(.scrollToBottom) = envelopes[6].command else {
            Issue.record("Expected scroll-to-bottom command")
            return
        }
    }

    private func expectFractionalScroll(_ envelope: RuntimeCommandEnvelope, fraction: Double) {
        guard case .terminal(.scrollPageFractional(let actualFraction)) = envelope.command else {
            Issue.record("Expected fractional scroll command")
            return
        }
        #expect(actualFraction == fraction)
    }
}
