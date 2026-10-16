import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC raw command wire contract")
struct IPCRawCommandWireTests {
    @Test("execute advertises a string dictionary rather than a typed argument union")
    func executeAdvertisesRawArgumentDictionary() throws {
        let composition = try fixtureComposition()
        guard case .object(let fields) = composition.execute.contract.parameterSchema else {
            Issue.record("execute envelope must be an object")
            return
        }
        #expect(fields.first { $0.name == "arguments" }?.schema == .dictionary(values: .string()))
    }

    @Test("a raw command map round-trips without requiring a kind discriminator")
    func rawMapRoundTripsWithoutKind() throws {
        let composition = try fixtureComposition()
        let correlationId = UUIDv7.generate()
        let input = try JSONSerialization.data(withJSONObject: [
            "commandId": "fixture.raw", "correlationId": correlationId.uuidString,
            "arguments": ["title": "value = next", "launchDirectory": "/tmp/a path"],
        ])
        let decoded = try composition.execute.decodeParameters(from: input)
        let encoded = try JSONEncoder().encode(decoded)
        let original = try JSONSerialization.jsonObject(with: input) as? NSDictionary
        let roundTripped = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary

        #expect(roundTripped == original)
    }

    @Test("non-string argument values are rejected after a valid raw-map positive control")
    func nonStringValuesAreRejected() throws {
        let composition = try fixtureComposition()
        let correlationId = UUIDv7.generate().uuidString
        _ = try composition.execute.decodeParameters(
            from: JSONSerialization.data(withJSONObject: [
                "commandId": "fixture.raw", "correlationId": correlationId, "arguments": [String: String](),
            ]))
        #expect(throws: IPCSchemaValidationError.self) {
            try composition.execute.decodeParameters(
                from: JSONSerialization.data(withJSONObject: [
                    "commandId": "fixture.raw", "correlationId": correlationId, "arguments": ["title": 42],
                ]))
        }
    }

    private func fixtureComposition() throws -> IPCCommandMethodComposition {
        let commandId = IPCCommandIdentifier(rawValue: "fixture.raw")
        let correlationId = UUIDv7.generate()
        let request = IPCCommandExecutionRequest(
            commandId: commandId, correlationId: correlationId, arguments: .noArguments)
        let result = IPCCommandExecutionResult.applied(.init(commandId: commandId, correlationId: correlationId))
        let descriptor = try IPCCommandDescriptorFactory.make(
            .init(
                id: commandId, title: "Raw command", description: "Raw command wire fixture", exposure: .debugTesting,
                executionMode: .headless, argumentVariants: [.noArguments], requiredPrivileges: [.appCommandExecute],
                dataScope: .unspecified, allowedTargetKinds: [], resultVariants: [.applied],
                examples: [.init(description: "Raw command example", request: request, result: result)],
                agentEligibility: .notYetAllowed))
        return try IPCCommandMethodComposition(compatibility: .current, commands: [descriptor])
    }
}
