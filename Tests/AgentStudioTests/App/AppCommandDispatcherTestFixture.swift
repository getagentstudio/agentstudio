import Foundation

@testable import AgentStudio
@testable import AgentStudioInfrastructure

@MainActor
struct CommandDispatcherFixtureConfiguration {
    var workspaceOwner: (any WorkspaceCommandHandling)?
    var shellOwner: (any ShellCommandHandling)?
    var interactionProbe: AgentStudioInteractionPerformanceProbe?
    var commandRefreshAccepted: @MainActor (UUID) -> Void = { _ in }

    func makeDispatcher() -> AppCommandDispatcher {
        AppCommandDispatcher(
            dependencies: .init(
                shellOwnerAccess: { [shellOwner] in shellOwner },
                workspaceOwnerAccess: { [workspaceOwner] in workspaceOwner },
                interactionProbeAccess: { [interactionProbe] in interactionProbe },
                commandRefreshAccepted: commandRefreshAccepted
            ))
    }
}

@MainActor
func withCommandDispatcherFixture<Output>(
    configure: @MainActor (inout CommandDispatcherFixtureConfiguration) -> Void,
    body: @MainActor (AppCommandDispatcher) async throws -> Output
) async throws -> Output {
    var configuration = CommandDispatcherFixtureConfiguration()
    configure(&configuration)
    let dispatcher = configuration.makeDispatcher()
    return try await body(dispatcher)
}

@MainActor
func withCommandDispatcher<Output>(
    _ dispatcher: AppCommandDispatcher,
    body: @MainActor (AppCommandDispatcher) async throws -> Output
) async throws -> Output {
    try await body(dispatcher)
}
