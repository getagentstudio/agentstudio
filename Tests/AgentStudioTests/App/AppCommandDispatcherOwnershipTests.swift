import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Fixture-owned command dispatch")
struct AppCommandDispatcherOwnershipTests {
    @Test("constructing another dispatcher cannot redirect the first fixture's commands")
    func anotherDispatcherCannotRedirectCommands() {
        let firstOwner = RecordingDispatcherShellCommandOwner(executionResult: true)
        let secondOwner = RecordingDispatcherShellCommandOwner(executionResult: true)
        let first = AppCommandDispatcher(
            dependencies: .init(
                shellOwnerAccess: { firstOwner }, workspaceOwnerAccess: { nil },
                interactionProbeAccess: { nil }, commandRefreshAccepted: { _ in }
            ))
        let second = AppCommandDispatcher(
            dependencies: .init(
                shellOwnerAccess: { secondOwner }, workspaceOwnerAccess: { nil },
                interactionProbeAccess: { nil }, commandRefreshAccepted: { _ in }
            ))

        #expect(first.dispatch(.toggleSidebar))
        #expect(firstOwner.interactions.contains(.contextualExecution(command: .toggleSidebar)))
        #expect(secondOwner.interactions.isEmpty)
        #expect(second.dispatch(.toggleSidebar))
        #expect(secondOwner.interactions.contains(.contextualExecution(command: .toggleSidebar)))
        #expect(firstOwner.interactions.filter { $0 == .contextualExecution(command: .toggleSidebar) }.count == 1)
    }

    @Test("fixed shell access stays absent until its owner installs shell services")
    func shellAccessRemainsAbsentUntilInstalled() {
        let owner = RecordingDispatcherShellCommandOwner(executionResult: true)
        let readiness = ShellOwnerTestReadiness()
        let dispatcher = AppCommandDispatcher(
            dependencies: .init(
                shellOwnerAccess: { readiness.isInstalled ? owner : nil }, workspaceOwnerAccess: { nil },
                interactionProbeAccess: { nil }, commandRefreshAccepted: { _ in }
            ))
        #expect(!dispatcher.canDispatch(.toggleSidebar))
        #expect(!dispatcher.dispatch(.toggleSidebar))
        #expect(owner.interactions.isEmpty)

        readiness.isInstalled = true

        #expect(dispatcher.canDispatch(.toggleSidebar))
        #expect(dispatcher.dispatch(.toggleSidebar))
        #expect(owner.interactions.filter { $0 == .contextualExecution(command: .toggleSidebar) }.count == 1)
    }
}

@MainActor
private final class ShellOwnerTestReadiness {
    var isInstalled = false
}
