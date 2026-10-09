import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("AppDelegate menu presentation", .serialized)
struct AppDelegateMenuPresentationTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("main menu presence follows presentation policy before dispatcher enablement")
    func mainMenuPresencePrecedesDispatcherEnablement() {
        withTestCoreAtoms { coreAtoms in
            let commandHandler = MockCommandHandler()
            commandHandler.canExecuteResult = false
            let dispatcher = CommandDispatcherFixtureConfiguration(workspaceOwner: commandHandler).makeDispatcher()
            let trace = AgentStudioTraceRuntime.fromEnvironment()
            let delegate = AppDelegate(
                traceRuntime: trace, startupTraceRecorder: AgentStudioStartupTraceRecorder(traceRuntime: trace),
                commandDispatcher: dispatcher
            )
            delegate.atomStore = AtomRegistry(core: coreAtoms)
            delegate.store = WorkspaceStore()

            let closeTabMenuItem = makeMenuItem(command: .closeTab)

            #expect(!delegate.validateMenuItem(closeTabMenuItem))
            #expect(closeTabMenuItem.isHidden)

            let pane = delegate.store.createPane()
            let tab = Tab(paneId: pane.id)
            delegate.store.appendTab(tab)
            delegate.store.setActiveTab(tab.id)
            delegate.store.setActivePane(pane.id, inTab: tab.id)
            coreAtoms.workspaceFocusOwner.focusMainPane(pane.id)

            #expect(!delegate.validateMenuItem(closeTabMenuItem))
            #expect(!closeTabMenuItem.isHidden)

            commandHandler.canExecuteResult = true

            #expect(delegate.validateMenuItem(closeTabMenuItem))
            #expect(!closeTabMenuItem.isHidden)
        }
    }

    @Test("menu activation rechecks New Window and Close Window through dispatcher")
    func windowMenuActivationRechecksDispatcher() async throws {
        let rejectingRouter = RejectingWindowMenuRouter()

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = nil
                configuration.shellOwner = rejectingRouter
            },
            body: { dispatcher in
                let trace = AgentStudioTraceRuntime.fromEnvironment()
                let delegate = AppDelegate(
                    traceRuntime: trace, startupTraceRecorder: AgentStudioStartupTraceRecorder(traceRuntime: trace),
                    commandDispatcher: dispatcher
                )

                delegate.dispatchNewWindowMenuCommand()
                delegate.dispatchCloseWindowMenuCommand()

                #expect(rejectingRouter.capabilityCommands == [.newWindow, .closeWindow])
                #expect(rejectingRouter.executedCommands.isEmpty)
            }
        )
    }

    @Test("File menu routes New Window and Close Window through dispatcher selectors")
    func fileMenuRoutesWindowCommandsThroughDispatcherSelectors() throws {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/App/Boot/AppDelegate.swift"
            ),
            encoding: .utf8
        )

        #expect(
            source.contains(
                "menuItem(command: .newWindow, action: #selector(dispatchNewWindowMenuCommand))"
            )
        )
        #expect(
            source.contains(
                "menuItem(command: .closeWindow, action: #selector(dispatchCloseWindowMenuCommand))"
            )
        )
        #expect(source.contains("self.commandDispatcherForBoot().dispatch(.newWindow)"))
        #expect(source.contains("self.commandDispatcherForBoot().dispatch(.closeWindow)"))
    }

    private func makeMenuItem(command: AppCommand) -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: command.definition.label,
            action: nil,
            keyEquivalent: ""
        )
        menuItem.representedObject = command.rawValue
        return menuItem
    }
}

@MainActor
private final class RejectingWindowMenuRouter: ShellCommandHandling {
    private(set) var capabilityCommands: [AppCommand] = []
    private(set) var executedCommands: [AppCommand] = []

    func canExecute(_ command: AppCommand) -> Bool {
        capabilityCommands.append(command)
        return false
    }

    func canExecute(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool {
        false
    }

    func execute(_ command: AppCommand) -> Bool {
        executedCommands.append(command)
        return true
    }

    func execute(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool {
        false
    }

    func showRepoCommandBar() {}
    func refreshWorktrees() {}
    func refocusActivePane() {}
}
