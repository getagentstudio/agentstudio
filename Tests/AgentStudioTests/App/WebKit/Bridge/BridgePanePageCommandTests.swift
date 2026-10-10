import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgePanePageCommandTests {
        init() { installTestCoreAtomsIfNeeded() }

        @Test("a pre-session page reload dispatches exactly once to its own pane")
        func pageReloadDispatchesToControllerPaneWithoutSession() async throws {
            let owner = BridgePageReloadExecutionRecorder()
            let paneId = UUIDv7.generate()
            try await withCommandDispatcherFixture(
                configure: {
                    $0.shellOwner = owner
                },
                body: { dispatcher in
                    let controller = BridgePaneController(
                        paneId: paneId,
                        state: BridgePaneState(
                            panelKind: .diffViewer, source: .workspace(rootPath: "/tmp/worktree", baseline: .staged)),
                        appRootURL: testBridgeAppRootURL(),
                        initialPaneActivity: .dormant,
                        pageCommandRunner: WorkspaceSurfaceCoordinator.makeBridgePageCommandRunner(
                            dispatcher: dispatcher)
                    )
                    do {
                        let handler = BridgeReadyMessageHandler()
                        controller.configureReadyMessageHandler(handler)
                        let requestId = UUIDv7.generate().uuidString
                        let json =
                            "{\"jsonrpc\":\"2.0\",\"id\":\"\(requestId)\",\"method\":\"bridge.pageCommand.run\",\"params\":{\"command\":\"reloadBridgeWebView\"}}"
                        let message = try #require(BridgeReadyMessageHandler.decodeBootstrapMessage(from: json))
                        let delivery = try #require(handler.receiveValidatedBootstrapMessage(message))
                        await delivery.value
                        #expect(!controller.isBridgeReady)
                        #expect(!controller.hasPublishedProductSessionBootstrap)
                        #expect(
                            owner.executions == [
                                .init(command: .reloadBridgeWebView, paneId: paneId, targetType: .pane)
                            ])
                    } catch {
                        #expect(await controller.beginTeardown().value)
                        throw error
                    }
                    #expect(await controller.beginTeardown().value)
                })
        }
    }
}

@MainActor
private final class BridgePageReloadExecutionRecorder: ShellCommandHandling {
    struct Execution: Equatable {
        let command: AppCommand
        let paneId: UUID
        let targetType: SearchItemType
    }
    var executions: [Execution] = []
    func canExecute(_ command: AppCommand) -> Bool { false }
    func canExecute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool { true }
    func execute(_ command: AppCommand) -> Bool { false }
    func execute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        executions.append(.init(command: command, paneId: target, targetType: targetType))
        return true
    }
    func showRepoCommandBar() {}
    func refreshWorktrees() {}
    func refocusActivePane() {}
}
