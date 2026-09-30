import AgentStudioProgrammaticControl
import Foundation

enum IPCCommandDescriptorTestFixtures {
    static let firstCommandId = IPCCommandIdentifier(rawValue: "alpha.futureCommand")
    static let secondCommandId = IPCCommandIdentifier(rawValue: "omega.futureCommand")
    static let firstCorrelationId = uuid("01994abc-3000-7000-8000-000000000001")
    static let secondCorrelationId = uuid("01994abc-3000-7000-8000-000000000002")
    static let operationId = uuid("01994abc-3000-7000-8000-000000000003")

    static func firstDescriptor(
        request: IPCCommandExecutionRequest? = nil,
        result: IPCCommandExecutionResult? = nil,
        argumentVariants: [IPCCommandArgumentVariant] = [.noArguments],
        resultVariants: [IPCCommandResultVariant] = [.applied],
        requiredPrivileges: Set<IPCPrivilegeClass> = [.appCommandExecute, .layoutMutate]
    ) throws -> IPCCommandDescriptor {
        let request = request ?? firstRequest()
        let result = result ?? firstResult()
        return try IPCCommandDescriptorFactory.make(
            IPCCommandDescriptorInput(
                id: firstCommandId,
                title: "Alpha Future Command",
                description: "Apply the first unrelated open command identity.",
                exposure: .allChannels,
                executionMode: .headless,
                argumentVariants: argumentVariants,
                requiredPrivileges: requiredPrivileges,
                dataScope: .uiSurface,
                allowedTargetKinds: [],
                resultVariants: resultVariants,
                examples: [
                    IPCCommandExample(
                        description: "Apply the command without command-specific arguments.",
                        request: request,
                        result: result
                    )
                ],
                agentEligibility: .notYetAllowed
            )
        )
    }

    static func secondDescriptor(
        agentEligibility: IPCAgentEligibility = .notYetAllowed
    ) throws -> IPCCommandDescriptor {
        let request = try secondRequest()
        return try IPCCommandDescriptorFactory.make(
            IPCCommandDescriptorInput(
                id: secondCommandId,
                title: "Omega Future Command",
                description: "Accept the second unrelated open command identity for one pane.",
                exposure: .debugTesting,
                executionMode: .headless,
                argumentVariants: [.pane],
                requiredPrivileges: [.appCommandExecute, .terminalInputWrite],
                dataScope: .terminalInput,
                allowedTargetKinds: [.pane],
                resultVariants: [.accepted],
                examples: [
                    IPCCommandExample(
                        description: "Accept the command for the caller's pane.",
                        request: request,
                        result: secondResult(correlationId: request.correlationId)
                    )
                ],
                agentEligibility: agentEligibility
            )
        )
    }

    static func firstRequest(
        commandId: IPCCommandIdentifier = firstCommandId,
        correlationId: UUID = firstCorrelationId,
        arguments: IPCCommandArguments = .noArguments
    ) -> IPCCommandExecutionRequest {
        IPCCommandExecutionRequest(
            commandId: commandId,
            correlationId: correlationId,
            arguments: arguments
        )
    }

    static func firstResult(
        commandId: IPCCommandIdentifier = firstCommandId,
        correlationId: UUID = firstCorrelationId
    ) -> IPCCommandExecutionResult {
        .applied(
            IPCCommandAppliedResult(
                commandId: commandId,
                correlationId: correlationId
            )
        )
    }

    static func secondRequest(
        commandId: IPCCommandIdentifier = secondCommandId,
        correlationId: UUID = secondCorrelationId
    ) throws -> IPCCommandExecutionRequest {
        IPCCommandExecutionRequest(
            commandId: commandId,
            correlationId: correlationId,
            arguments: .pane(
                IPCPaneCommandArguments(
                    workspaceWindowId: IPCCommandArgumentsTestFixtures.workspaceWindowId,
                    paneSelector: try IPCCommandArgumentsTestFixtures.paneSelector("self")
                )
            )
        )
    }

    static func secondResult(
        commandId: IPCCommandIdentifier = secondCommandId,
        correlationId: UUID = secondCorrelationId
    ) -> IPCCommandExecutionResult {
        .accepted(
            IPCCommandAcceptedResult(
                commandId: commandId,
                correlationId: correlationId,
                operationId: operationId
            )
        )
    }

    static func descriptors() throws -> [IPCCommandDescriptor] {
        try [secondDescriptor(), firstDescriptor()]
    }

    private static func uuid(_ rawValue: String) -> UUID {
        guard let identifier = UUID(uuidString: rawValue) else {
            preconditionFailure("Invalid command descriptor fixture UUID")
        }
        return identifier
    }
}
