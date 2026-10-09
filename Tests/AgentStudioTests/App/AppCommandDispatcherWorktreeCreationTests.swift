import AgentStudioWorktreeOperations
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("App command dispatcher worktree creation")
struct AppCommandDispatcherWorktreeCreationTests {
    @Test("creation request reaches the shell owner after the targeted preflight for its command")
    func creationRequestRoutesToShellOwner() async throws {
        let shellOwner = RecordingWorktreeCreationShellOwner(outcome: .accepted(operationId: nil))
        let request = try Self.makeRequest(kind: .fromDefault)

        let accepted = try await withCommandDispatcherFixture(
            configure: { configuration in configuration.shellOwner = shellOwner },
            body: { dispatcher in dispatcher.dispatchWorktreeCreation(request) }
        )

        #expect(accepted)
        #expect(
            shellOwner.interactions == [
                .targetedCapability(command: .newWorktreeFromDefault, target: request.targetId),
                .creation(request),
            ])
    }

    @Test("a named branch request uses the branch command identity for targeted preflight")
    func branchRequestUsesBranchCommand() async throws {
        let shellOwner = RecordingWorktreeCreationShellOwner(outcome: .accepted(operationId: nil))
        let request = try Self.makeRequest(kind: .fromBranch(referenceName: "refs/heads/source"))

        let accepted = try await withCommandDispatcherFixture(
            configure: { configuration in configuration.shellOwner = shellOwner },
            body: { dispatcher in dispatcher.dispatchWorktreeCreation(request) }
        )

        #expect(accepted)
        #expect(
            shellOwner.interactions == [
                .targetedCapability(command: .newWorktreeFromBranch, target: request.targetId),
                .creation(request),
            ])
    }

    @Test("a refused preflight never reaches the creation owner")
    func refusedPreflightSkipsCreationOwner() async throws {
        let shellOwner = RecordingWorktreeCreationShellOwner(
            capabilityResult: false,
            outcome: .accepted(operationId: nil)
        )
        let request = try Self.makeRequest(kind: .fork)

        let accepted = try await withCommandDispatcherFixture(
            configure: { configuration in configuration.shellOwner = shellOwner },
            body: { dispatcher in dispatcher.dispatchWorktreeCreation(request) }
        )

        #expect(!accepted)
        #expect(
            shellOwner.interactions == [
                .targetedCapability(command: .forkWorktree, target: request.targetId)
            ])
    }

    @Test("an owner that does not accept reports the dispatch as not accepted")
    func unacceptedOutcomeIsNotAccepted() async throws {
        let shellOwner = RecordingWorktreeCreationShellOwner(outcome: .unavailable(.featureUnavailable))
        let request = try Self.makeRequest(kind: .fork)

        let accepted = try await withCommandDispatcherFixture(
            configure: { configuration in configuration.shellOwner = shellOwner },
            body: { dispatcher in dispatcher.dispatchWorktreeCreation(request) }
        )

        #expect(!accepted)
    }

    private static func makeRequest(kind: WorktreeCreationKind) throws -> WorktreeCreationRequest {
        WorktreeCreationRequest(
            kind: kind,
            targetId: UUIDv7.generate(),
            branchName: try WorktreeBranchName.validated("feature/dispatch").get()
        )
    }
}

private enum WorktreeCreationShellInteraction: Equatable {
    case targetedCapability(command: AppCommand, target: UUID)
    case creation(WorktreeCreationRequest)
}

@MainActor
private final class RecordingWorktreeCreationShellOwner: ShellCommandHandling {
    private let capabilityResult: Bool
    private let outcome: AppCommandExecutionOutcome
    private(set) var interactions: [WorktreeCreationShellInteraction] = []

    init(capabilityResult: Bool = true, outcome: AppCommandExecutionOutcome) {
        self.capabilityResult = capabilityResult
        self.outcome = outcome
    }

    func canExecute(_: AppCommand) -> Bool { false }

    func canExecute(_ command: AppCommand, target: UUID, targetType _: SearchItemType) -> Bool {
        interactions.append(.targetedCapability(command: command, target: target))
        return capabilityResult
    }

    func execute(_: AppCommand) -> Bool { false }

    func execute(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }

    func executeWorktreeCreation(_ request: WorktreeCreationRequest) -> AppCommandExecutionOutcome {
        interactions.append(.creation(request))
        return outcome
    }

    func showRepoCommandBar() {}

    func refreshWorktrees() {}

    func refocusActivePane() {}
}
