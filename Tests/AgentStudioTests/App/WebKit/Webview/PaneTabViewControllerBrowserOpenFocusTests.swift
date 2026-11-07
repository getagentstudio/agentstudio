import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioProgrammaticControl
@testable import AgentStudioTestSupport
@testable import AgentStudioWebview

/// R6: a person's browser open gives the browser focus in the same gesture,
/// so its commands, such as the tab picker, target it with no click; a
/// minimized browser comes back on reopen. The controller owns that focus; the
/// open route only presents.
extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct PaneTabViewControllerBrowserOpenFocusTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        /// A main terminal in the active tab, holding focus.
        private func makeFocusedTerminal(in harness: PaneTabViewControllerCommandHarness) -> Pane {
            let terminal = harness.store.createPane()
            let tab = Tab(paneId: terminal.id)
            harness.store.appendTab(tab)
            harness.store.setActiveTab(tab.id)
            atom(\.workspaceFocusOwner).focusMainPane(terminal.id)
            return terminal
        }

        private func drawerBrowserId(of parentPaneId: UUID, in harness: PaneTabViewControllerCommandHarness) -> UUID? {
            harness.coordinator.drawerBrowserPaneId(parentPaneId: parentPaneId)
        }

        @Test("opening a browser from a focused main terminal gives the browser focus, so the picker targets it")
        func openWebviewCommandFocusesTheDrawerBrowser() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange
                let harness = makeHarness()
                retirement.track(harness.viewRegistry)
                defer { try? FileManager.default.removeItem(at: harness.tempDir) }
                let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let terminal = makeFocusedTerminal(in: harness)
                try attachPaneHost(paneId: terminal.id, in: harness, to: window)
                #expect(!harness.controller.canExecute(.showBrowserTabs))

                // Act: the AppCommand, with no click.
                await harness.executeCommand(.openWebview)

                // Assert
                let browser = try #require(drawerBrowserId(of: terminal.id, in: harness), "the open created a browser")
                #expect(harness.store.pane(terminal.id)?.drawer?.isExpanded == true)
                #expect(harness.store.drawerView(forParent: terminal.id)?.activeChildId == browser)
                #expect(
                    atom(\.workspaceFocusOwner).owner == .drawerPane(parentPaneId: terminal.id, paneId: browser),
                    "focus owner: \(atom(\.workspaceFocusOwner).owner), terminal \(terminal.id), browser \(browser)")
                #expect(harness.controller.canExecute(.showBrowserTabs), "the picker command must target the browser")
            }
        }

        @Test("reopening a minimized browser brings it back and focuses it")
        func reopeningMinimizedBrowserExpandsAndFocusesIt() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange: a browser beside a drawer terminal, minimized, focus back on the main terminal.
                let harness = makeHarness()
                retirement.track(harness.viewRegistry)
                defer { try? FileManager.default.removeItem(at: harness.tempDir) }
                let window = makePaneTabViewControllerCommandWindow(for: harness.controller)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let terminal = makeFocusedTerminal(in: harness)
                try attachPaneHost(paneId: terminal.id, in: harness, to: window)
                _ = try #require(harness.store.addDrawerPane(to: terminal.id))
                await harness.executeCommand(.openWebview)
                let browser = try #require(drawerBrowserId(of: terminal.id, in: harness))
                let minimized = await harness.executor.submitGesture { execute in
                    await execute(.minimizeDrawerPane(parentPaneId: terminal.id, drawerPaneId: browser))
                }.value
                #expect(minimized)
                #expect(harness.store.drawerView(forParent: terminal.id)?.minimizedPaneIds.contains(browser) == true)
                atom(\.workspaceFocusOwner).focusMainPane(terminal.id)

                // Act
                await harness.executeCommand(.openWebview)

                // Assert
                #expect(harness.store.drawerView(forParent: terminal.id)?.minimizedPaneIds.contains(browser) == false)
                #expect(drawerBrowserId(of: terminal.id, in: harness) == browser, "the open reused the browser")
                #expect(atom(\.workspaceFocusOwner).owner == .drawerPane(parentPaneId: terminal.id, paneId: browser))
            }
        }

        @Test("a headless open with no window to focus still gives the browser drawer focus")
        func headlessOpenWithoutWindowFocusesTheDrawerBrowser() async throws {
            try await WebviewRetirementScope.run { retirement in
                // Arrange: no window, so there is no first responder to take.
                let windowId = UUIDv7.generate()
                let harness = makeHarness(workspaceWindowId: windowId)
                retirement.track(harness.viewRegistry)
                defer { try? FileManager.default.removeItem(at: harness.tempDir) }
                let terminal = makeFocusedTerminal(in: harness)

                // Act
                let outcome = await harness.controller.executeHeadlessIPC(
                    AppCommandExecutionRequest(
                        command: .openWebview,
                        arguments: .typedIPC(.webview(.init(workspaceWindowId: windowId, url: "https://example.com/"))),
                        executionContext: .headlessIPC(admitsDebugTestingCommands: true)
                    )
                )

                // Assert
                let browser = try #require(drawerBrowserId(of: terminal.id, in: harness), "the open created a browser")
                #expect(outcome == harness.controller.headlessIPCOutcome(true, for: .openWebview))
                #expect(harness.store.pane(terminal.id)?.drawer?.isExpanded == true)
                #expect(atom(\.workspaceFocusOwner).owner == .drawerPane(parentPaneId: terminal.id, paneId: browser))
            }
        }
    }
}
