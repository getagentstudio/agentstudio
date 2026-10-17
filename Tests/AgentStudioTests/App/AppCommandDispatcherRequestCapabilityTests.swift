import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("App command dispatcher request capability")
struct AppCommandDispatcherRequestCapabilityTests {
    @Test("no-argument requests preserve workspace-handler routing")
    func requestsWithoutArgumentsPreserveWorkspaceHandlerRouting() async throws {

        let handler = MockCommandHandler()
        let request = AppCommandExecutionRequest(
            command: .closeTab,
            arguments: .noArguments
        )

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.workspaceOwner = handler
                configuration.shellOwner = nil
            },
            body: { dispatcher in
                let outcome = dispatcher.dispatch(request)

                #expect(outcome == .applied)
                #expect(handler.executedCommands.map(\.0) == [.closeTab])
            }
        )
    }
}
