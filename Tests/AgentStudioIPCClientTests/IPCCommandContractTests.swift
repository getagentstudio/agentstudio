import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("App-composed command contract round trips")
struct IPCCommandContractTests {
    @Test("command.list and system.ping preserve typed normalized round trips")
    func typedCommandListAndPingRoundTrips() throws {
        let fixture = try IPCCommandContractFixture.make()
        let commandListResult = fixture.commandComposition.catalogResult
        let commandListContract = fixture.commandComposition.list.contract
        let validatedCommandList = try commandListContract.validatedResult(
            from: JSONEncoder().encode(commandListResult)
        )

        #expect(validatedCommandList.value == commandListResult)
        #expect(try commandListContract.decodeResult(from: validatedCommandList.json) == commandListResult)

        let pingResult = IPCSystemPingResult(runtimeId: UUIDv7.generate())
        let pingContract = try IPCMethodContract<IPCEmptyParams, IPCSystemPingResult>(
            parameterSchema: IPCEmptyParams.ipcSchema(),
            resultSchema: IPCSystemPingResult.ipcSchema()
        )
        let lowercasePingPayload = Data(
            "{\"ok\":true,\"runtimeId\":\"\(pingResult.runtimeId.uuidString.lowercased())\"}".utf8
        )
        let validatedPing = try pingContract.validatedResult(from: lowercasePingPayload)

        #expect(validatedPing.value == pingResult)
        #expect(try pingContract.decodeResult(from: validatedPing.json) == pingResult)
        #expect(validatedPing.json.data == (try pingContract.encodeResult(pingResult)))
    }
}

private struct IPCCommandContractFixture {
    let noArgumentsCommandId: IPCCommandIdentifier
    let paneCommandId: IPCCommandIdentifier
    let correlationId: UUID
    let workspaceWindowId: UUID
    let commandComposition: IPCCommandMethodComposition

    static func make(recognizedUnexposedCommands: [IPCRecognizedUnexposedName] = []) throws -> Self {
        let noArgumentsCommandId = IPCCommandIdentifier(rawValue: "fixture.noArguments")
        let paneCommandId = IPCCommandIdentifier(rawValue: "fixture.pane")
        let correlationId = UUIDv7.generate()
        let workspaceWindowId = UUIDv7.generate()
        let paneArguments = IPCCommandArguments.pane(
            IPCPaneCommandArguments(
                workspaceWindowId: workspaceWindowId,
                paneSelector: try IPCPaneSelector(rawValue: "self")
            )
        )
        let noArgumentsRequest = IPCCommandExecutionRequest(
            commandId: noArgumentsCommandId,
            correlationId: correlationId,
            arguments: .noArguments
        )
        let paneRequest = IPCCommandExecutionRequest(
            commandId: paneCommandId,
            correlationId: correlationId,
            arguments: paneArguments
        )
        let commands = try [
            IPCCommandDescriptorFactory.make(
                IPCCommandDescriptorInput(
                    id: noArgumentsCommandId,
                    title: "Fixture No Arguments",
                    description: "Apply a fixture command with no command-specific arguments.",
                    exposure: .allChannels,
                    executionMode: .headless,
                    argumentVariants: [.noArguments],
                    requiredPrivileges: [.appCommandExecute],
                    dataScope: .uiSurface,
                    allowedTargetKinds: [],
                    resultVariants: [.applied],
                    examples: [
                        IPCCommandExample(
                            description: "Apply the no-arguments fixture command.",
                            request: noArgumentsRequest,
                            result: .applied(
                                IPCCommandAppliedResult(
                                    commandId: noArgumentsCommandId,
                                    correlationId: correlationId
                                )
                            )
                        )
                    ],
                    agentEligibility: .notYetAllowed
                )
            ),
            IPCCommandDescriptorFactory.make(
                IPCCommandDescriptorInput(
                    id: paneCommandId,
                    title: "Fixture Pane",
                    description: "Accept a fixture command for one pane.",
                    exposure: .debugTesting,
                    executionMode: .headless,
                    argumentVariants: [.pane],
                    requiredPrivileges: [.appCommandExecute],
                    dataScope: .terminalInput,
                    allowedTargetKinds: [.pane],
                    resultVariants: [.accepted],
                    examples: [
                        IPCCommandExample(
                            description: "Accept the pane fixture command.",
                            request: paneRequest,
                            result: .accepted(
                                IPCCommandAcceptedResult(
                                    commandId: paneCommandId,
                                    correlationId: correlationId,
                                    operationId: UUIDv7.generate()
                                )
                            )
                        )
                    ],
                    agentEligibility: .notYetAllowed
                )
            ),
        ]
        let commandComposition = try IPCCommandMethodComposition(
            compatibility: .current,
            commands: commands,
            recognizedUnexposedCommands: recognizedUnexposedCommands
        )
        return Self(
            noArgumentsCommandId: noArgumentsCommandId,
            paneCommandId: paneCommandId,
            correlationId: correlationId,
            workspaceWindowId: workspaceWindowId,
            commandComposition: commandComposition
        )
    }
}
