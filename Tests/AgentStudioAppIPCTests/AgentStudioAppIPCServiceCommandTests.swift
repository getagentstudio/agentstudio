import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("AgentStudio App IPC typed command port")
struct AgentStudioAppIPCServiceCommandTests {
    @Test("typed command preparation rejects unknown command identity without execution")
    @MainActor
    func preparationRejectsUnknownIdentityWithoutExecution() async throws {
        let port = FakeCommandPort()
        let request = IPCCommandExecutionRequest(
            commandId: IPCCommandIdentifier(rawValue: "futureCommand"),
            correlationId: UUIDv7.generate(),
            arguments: .noArguments
        )

        do {
            _ = try await port.prepareCommand(
                IPCRawCommandExecutionRequest(typedRequest: request), principal: diagnosticCommandPrincipal(),
                tools: unusedCommandTargetTools())
            Issue.record("Expected the unknown command identity to be rejected")
        } catch let error as AgentStudioAppIPCRequestError {
            #expect(error.code == -32_003)
            #expect(
                error.data
                    == .object([
                        "reason": .string("unknownCommand"), "commandId": .string("futureCommand"),
                        "closestMatches": .array([]),
                    ]))
        }
        #expect(port.receivedExecutionRequests.isEmpty)
    }

    @Test("typed command preparation rejects a wrong argument variant without execution")
    @MainActor
    func preparationRejectsWrongVariantWithoutExecution() async throws {
        let commandId = IPCCommandIdentifier(rawValue: "fixtureCommand")
        let correlationId = UUIDv7.generate()
        let result = IPCCommandExecutionResult.applied(
            IPCCommandAppliedResult(commandId: commandId, correlationId: correlationId))
        let descriptor = try makeFakeCommandDescriptor(
            FakeCommandDescriptorInput(
                id: commandId,
                executionMode: .headless,
                arguments: .noArguments,
                requiredPrivileges: [.appCommandExecute],
                dataScope: .unspecified,
                allowedTargetKinds: [],
                result: result
            )
        )
        let port = FakeCommandPort(commands: [descriptor])
        let request = IPCCommandExecutionRequest(
            commandId: commandId,
            correlationId: correlationId,
            arguments: .repository(IPCRepositoryCommandArguments(repoId: UUIDv7.generate()))
        )

        do {
            _ = try await port.prepareCommand(
                IPCRawCommandExecutionRequest(typedRequest: request), principal: diagnosticCommandPrincipal(),
                tools: unusedCommandTargetTools())
            Issue.record("Expected the typed command variant to be rejected")
        } catch let error as AgentStudioAppIPCRequestError {
            #expect(error.code == -32_602)
            guard case .object(let fields) = error.data else {
                Issue.record("Expected raw argument correction")
                return
            }
            #expect(fields["fieldPath"] == .string("$.arguments.kind"))
            #expect(fields["reason"] == .string("invalidArguments"))
            #expect(fields["expected"] == .string("one admitted argument kind: noArguments"))
        }
        #expect(port.receivedExecutionRequests.isEmpty)
    }

    @Test("typed command preparation preserves descriptor scopes and execution result")
    @MainActor
    func preparationPreservesScopesAndExecutionResult() async throws {
        let commandId = IPCCommandIdentifier(rawValue: "fixtureCommand")
        let correlationId = UUIDv7.generate()
        let result = IPCCommandExecutionResult.presented(
            IPCCommandPresentedResult(commandId: commandId, correlationId: correlationId))
        let descriptor = try makeFakeCommandDescriptor(
            FakeCommandDescriptorInput(
                id: commandId,
                executionMode: .uiPresentation,
                arguments: .noArguments,
                requiredPrivileges: [.appCommandExecute, .uiPresent],
                dataScope: .uiSurface,
                allowedTargetKinds: [],
                result: result
            )
        )
        let port = FakeCommandPort(
            commands: [descriptor],
            executionResultsByCommandId: [commandId.rawValue: result],
            requiredPermissionTargetByPrivilege: [
                .appCommandExecute: .app,
                .uiPresent: .app,
            ]
        )
        let request = IPCCommandExecutionRequest(
            commandId: commandId,
            correlationId: correlationId,
            arguments: .noArguments
        )

        let prepared = try await port.prepareCommand(
            IPCRawCommandExecutionRequest(typedRequest: request),
            principal: diagnosticCommandPrincipal(),
            tools: unusedCommandTargetTools()
        )
        let executed = try await port.executeCommand(prepared.request, ownPaneAssertion: nil)

        #expect(prepared.target == .app)
        #expect(
            prepared.requiredScopes
                == [
                    IPCPermissionScope(privilege: .appCommandExecute, target: .app, dataScope: .uiSurface),
                    IPCPermissionScope(privilege: .uiPresent, target: .app, dataScope: .uiSurface),
                ]
        )
        #expect(executed == result)
        #expect(port.receivedExecutionRequests == [request])
    }
}

private func diagnosticCommandPrincipal() -> IPCPrincipal {
    IPCPrincipal(
        principalId: UUIDv7.generate(),
        runtimeId: UUIDv7.generate(),
        accessMode: .automationSameUser,
        kind: .automationClient,
        approvalAuthority: .noApprovalAuthority
    )
}

private func unusedCommandTargetTools() -> AppIPCTargetResolutionTools {
    AppIPCTargetResolutionTools(canonicalizePaneHandle: { _ in
        throw AppIPCCommandError(reason: .targetNotFound)
    })
}
