import AppKit
import Observation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("Command hosts observe selected execution owners", .serialized)
struct AppCommandDispatcherHostObservationTests {
    @Test("constructing the selected lookup never forces an unavailable native engine")
    func selectedLookupPreservesUnavailableEngine() {
        let delegate = AppDelegate()
        guard case .unavailable = delegate.engineAvailabilityForBoot() else {
            Issue.record("A fixture without native initialization must be unavailable")
            return
        }
        let lookup = delegate.terminalLookupForBoot()
        let result = lookup.createSurface(
            config: .init(initialFrame: .init(x: 0, y: 0, width: 800, height: 600)),
            metadata: .init(title: "Unavailable engine fixture")
        )
        switch result {
        case .failure(let error):
            guard case .ghosttyNotInitialized = error else {
                Issue.record("Unavailable engine must preserve the existing surface creation failure")
                return
            }
        case .success:
            Issue.record("Unavailable engine cannot create a native surface")
        }
        #expect(lookup.activeSurfaces.isEmpty)
        guard case .unavailable = delegate.engineAvailabilityForBoot() else {
            Issue.record("Lookup demand must not construct a fallback native engine")
            return
        }
    }

    @Test("the real watch-folder host observes the shell installation transition")
    func watchFolderHostObservesShellInstallation() throws {
        try withTestCoreAtoms { coreAtoms in
            let delegate = AppDelegate()
            delegate.atomStore = AtomRegistry(core: coreAtoms)
            let dispatcher = delegate.commandDispatcherForBoot()
            let host = WatchFolderTabBarMenu(commandDispatcher: dispatcher)
            let invalidated = Mutex(false)
            let before = try #require(
                ShellTabBarCommandPresentation(
                    command: .watchFolder, surface: .toolbar(.app), commandContext: .empty, dispatcher: dispatcher
                ))
            #expect(!before.isEnabled)
            withObservationTracking {
                _ = host.body
            } onChange: {
                invalidated.withLock { $0 = true }
            }

            delegate.markShellRuntimeOwnersInstalled()

            #expect(invalidated.withLock { $0 })
            let after = try #require(
                ShellTabBarCommandPresentation(
                    command: .watchFolder, surface: .toolbar(.app), commandContext: .empty, dispatcher: dispatcher
                ))
            #expect(after.isEnabled)
            #expect(dispatcher.canDispatch(.watchFolder))
        }
    }

    @Test("the real management host observes window installation and removal with dispatch")
    func managementHostObservesWindowOwnerTransitions() async throws {
        let delegate = AppDelegate()
        let dispatcher = delegate.commandDispatcherForBoot()
        try await withMainSplitViewControllerHarness(
            withRepos: false, paneTabRegistersAsCommandHandler: true, commandDispatcher: dispatcher,
            body: { harness in
                delegate.atomStore = harness.atoms
                delegate.store = harness.store
                let host = TabBarManagementLayerButton(commandDispatcher: dispatcher)
                let installed = Mutex(false)
                withObservationTracking {
                    _ = host.body
                } onChange: {
                    installed.withLock { $0 = true }
                }
                #expect(!dispatcher.dispatch(.toggleManagementLayer))
                let owner = MainWindowController(window: harness.window, commandDispatcher: dispatcher)
                delegate.mainWindowController = owner
                defer { delegate.mainWindowController = nil }
                #expect(installed.withLock { $0 })
                let presentation = try #require(
                    ShellTabBarCommandPresentation(
                        command: .toggleManagementLayer, surface: .toolbar(.app), commandContext: .empty,
                        dispatcher: dispatcher
                    ))
                #expect(presentation.isEnabled)
                #expect(!harness.atoms.core.managementLayer.isActive)

                presentation.perform()

                #expect(harness.atoms.core.managementLayer.isActive)
                let removed = Mutex(false)
                withObservationTracking {
                    _ = host.body
                } onChange: {
                    removed.withLock { $0 = true }
                }
                delegate.mainWindowController = nil
                #expect(removed.withLock { $0 })
                let unavailable = try #require(
                    ShellTabBarCommandPresentation(
                        command: .toggleManagementLayer, surface: .toolbar(.app), commandContext: .empty,
                        dispatcher: dispatcher
                    ))
                #expect(!unavailable.isEnabled)
                #expect(!dispatcher.dispatch(.toggleManagementLayer))
                #expect(harness.atoms.core.managementLayer.isActive)
            }
        )
    }
}
