import Foundation

package enum IPCCommandDescriptorError: Error, Equatable, Sendable {
    case invalidCommandIdentifier
    case missingTitle
    case missingDescription
    case missingArgumentVariant
    case duplicateArgumentVariant
    case missingResultVariant
    case duplicateResultVariant
    case missingAppCommandExecutePrivilege
    case missingExample
    case invalidExampleDescription
    case exampleCommandIdentifierMismatch
    case exampleCorrelationMismatch
    case exampleArgumentVariantNotAllowed
    case exampleResultVariantNotAllowed
    case agentEligibleCommandMustBeExposedOnAllChannels
}

/// One executable example retains the complete envelope and result so command
/// identity and correlation agreement are validated before discovery.
package struct IPCCommandExample: Codable, Equatable, Sendable {
    package let description: String
    package let request: IPCCommandExecutionRequest
    package let result: IPCCommandExecutionResult

    package init(
        description: String,
        request: IPCCommandExecutionRequest,
        result: IPCCommandExecutionResult
    ) {
        self.description = description
        self.request = request
        self.result = result
    }
}

/// App supplies one complete descriptor input from its exhaustive command
/// projection. Keeping the fields together makes construction explicit without
/// hiding them behind positional factory arguments.
package struct IPCCommandDescriptorInput: Sendable {
    package let id: IPCCommandIdentifier
    package let title: String
    package let description: String
    package let exposure: IPCMethodExposure
    package let executionMode: IPCCommandExecutionMode
    package let argumentVariants: [IPCCommandArgumentVariant]
    package let requiredPrivileges: Set<IPCPrivilegeClass>
    package let dataScope: IPCDataScope
    package let allowedTargetKinds: Set<IPCHandleKind>
    package let resultVariants: [IPCCommandResultVariant]
    package let examples: [IPCCommandExample]
    package let agentEligibility: IPCAgentEligibility

    package init(
        id: IPCCommandIdentifier,
        title: String,
        description: String,
        exposure: IPCMethodExposure,
        executionMode: IPCCommandExecutionMode,
        argumentVariants: [IPCCommandArgumentVariant],
        requiredPrivileges: Set<IPCPrivilegeClass>,
        dataScope: IPCDataScope,
        allowedTargetKinds: Set<IPCHandleKind>,
        resultVariants: [IPCCommandResultVariant],
        examples: [IPCCommandExample],
        agentEligibility: IPCAgentEligibility
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.exposure = exposure
        self.executionMode = executionMode
        self.argumentVariants = argumentVariants
        self.requiredPrivileges = requiredPrivileges
        self.dataScope = dataScope
        self.allowedTargetKinds = allowedTargetKinds
        self.resultVariants = resultVariants
        self.examples = examples
        self.agentEligibility = agentEligibility
    }
}

/// Metadata for one open App-owned command identity. This value carries no
/// shared identity table; App constructs it from its exhaustive projection.
package struct IPCCommandDescriptor: Codable, Equatable, Sendable {
    package let id: IPCCommandIdentifier
    package let title: String
    package let description: String
    package let exposure: IPCMethodExposure
    package let executionMode: IPCCommandExecutionMode
    package let argumentVariants: [IPCCommandArgumentVariant]
    package let argumentSchema: IPCJSONSchema
    package let requiredPrivileges: [IPCPrivilegeClass]
    package let dataScope: IPCDataScope
    package let allowedTargetKinds: [IPCHandleKind]
    package let resultVariants: [IPCCommandResultVariant]
    package let resultSchema: IPCJSONSchema
    package let examples: [IPCCommandExample]
    /// What a pane-bound agent may do with this command.
    package let agentEligibility: IPCAgentEligibility

    package var catalogEntrySchema: IPCJSONSchema {
        get throws {
            guard !examples.isEmpty else {
                throw IPCSchemaValidationError(
                    fieldPath: "$.examples",
                    reason: .invalidDefinition,
                    expected: "at least one validated command example"
                )
            }
            let exampleSchemas = try examples.map { try IPCJSONSchema.literal($0) }
            let exampleSchema =
                exampleSchemas.count == 1
                ? exampleSchemas[0]
                : .oneOf(exampleSchemas)
            return .object(fields: [
                .init(
                    name: "id",
                    description: "Open App-owned command identifier",
                    schema: .string(allowedValues: [id.rawValue])
                ),
                .init(
                    name: "title",
                    description: "Concise command title",
                    schema: .string(minimumLength: 1)
                ),
                .init(
                    name: "description",
                    description: "Agent-facing command description",
                    schema: .string(minimumLength: 1)
                ),
                .init(
                    name: "exposure",
                    description: "Application channel exposure",
                    schema: try IPCMethodExposure.ipcSchema()
                ),
                .init(
                    name: "executionMode",
                    description: "Command execution boundary",
                    schema: try IPCCommandExecutionMode.ipcSchema()
                ),
                .init(
                    name: "argumentVariants",
                    description: "Closed argument variants accepted by this command",
                    schema: .array(
                        items: try IPCCommandArgumentVariant.ipcSchema(),
                        minimumCount: 1
                    )
                ),
                .init(
                    name: "argumentSchema",
                    description: "Complete typed argument JSON Schema",
                    schema: .schemaDocument
                ),
                .init(
                    name: "requiredPrivileges",
                    description: "Complete privileges required for command admission",
                    schema: .array(
                        items: try IPCPrivilegeClass.ipcSchema(),
                        minimumCount: 1
                    )
                ),
                .init(
                    name: "dataScope",
                    description: "Data category accessed by the command",
                    schema: try IPCDataScope.ipcSchema()
                ),
                .init(
                    name: "allowedTargetKinds",
                    description: "Durable target kinds accepted by command admission",
                    schema: .array(items: try IPCHandleKind.ipcSchema())
                ),
                .init(
                    name: "resultVariants",
                    description: "Closed result boundaries this command may return",
                    schema: .array(
                        items: try IPCCommandResultVariant.ipcSchema(),
                        minimumCount: 1
                    )
                ),
                .init(
                    name: "resultSchema",
                    description: "Complete typed command-result JSON Schema",
                    schema: .schemaDocument
                ),
                .init(
                    name: "examples",
                    description: "Validated typed command request and result examples",
                    schema: .array(items: exampleSchema, minimumCount: 1)
                ),
                .init(
                    name: "agentEligibility",
                    description: "What a pane-bound agent may do with this command",
                    schema: try IPCAgentEligibility.ipcSchema()
                ),
            ])
        }
    }

    init(
        id: IPCCommandIdentifier,
        title: String,
        description: String,
        exposure: IPCMethodExposure,
        executionMode: IPCCommandExecutionMode,
        argumentVariants: [IPCCommandArgumentVariant],
        argumentSchema: IPCJSONSchema,
        requiredPrivileges: [IPCPrivilegeClass],
        dataScope: IPCDataScope,
        allowedTargetKinds: [IPCHandleKind],
        resultVariants: [IPCCommandResultVariant],
        resultSchema: IPCJSONSchema,
        examples: [IPCCommandExample],
        agentEligibility: IPCAgentEligibility
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.exposure = exposure
        self.executionMode = executionMode
        self.argumentVariants = argumentVariants
        self.argumentSchema = argumentSchema
        self.requiredPrivileges = requiredPrivileges
        self.dataScope = dataScope
        self.allowedTargetKinds = allowedTargetKinds
        self.resultVariants = resultVariants
        self.resultSchema = resultSchema
        self.examples = examples
        self.agentEligibility = agentEligibility
    }
}

extension IPCCommandExecutionMode: IPCSchemaProviding {}
extension IPCCommandArgumentVariant: IPCSchemaProviding {}
extension IPCCommandResultVariant: IPCSchemaProviding {}

package enum IPCCommandDescriptorFactory {
    package static func make(_ input: IPCCommandDescriptorInput) throws -> IPCCommandDescriptor {
        try validateDefinition(
            DescriptorValidationInput(
                id: input.id,
                title: input.title,
                description: input.description,
                argumentVariants: input.argumentVariants,
                requiredPrivileges: input.requiredPrivileges,
                resultVariants: input.resultVariants,
                examples: input.examples,
                exposure: input.exposure,
                agentEligibility: input.agentEligibility
            )
        )

        let sortedArgumentVariants = input.argumentVariants.sorted { $0.rawValue < $1.rawValue }
        let sortedResultVariants = input.resultVariants.sorted { $0.rawValue < $1.rawValue }
        let argumentSchema = try IPCCommandArguments.ipcSchema(allowing: sortedArgumentVariants)
        let requestSchema = try IPCCommandExecutionRequest.ipcSchema(allowing: sortedArgumentVariants)
        let resultSchema = try IPCCommandExecutionResult.ipcSchema(allowing: sortedResultVariants)

        for example in input.examples {
            _ = try requestSchema.decode(
                IPCCommandExecutionRequest.self,
                from: JSONEncoder().encode(example.request)
            )
            _ = try resultSchema.decode(
                IPCCommandExecutionResult.self,
                from: JSONEncoder().encode(example.result)
            )
        }

        return IPCCommandDescriptor(
            id: input.id,
            title: input.title,
            description: input.description,
            exposure: input.exposure,
            executionMode: input.executionMode,
            argumentVariants: sortedArgumentVariants,
            argumentSchema: argumentSchema,
            requiredPrivileges: input.requiredPrivileges.sorted { $0.rawValue < $1.rawValue },
            dataScope: input.dataScope,
            allowedTargetKinds: input.allowedTargetKinds.sorted { $0.rawValue < $1.rawValue },
            resultVariants: sortedResultVariants,
            resultSchema: resultSchema,
            examples: input.examples,
            agentEligibility: input.agentEligibility
        )
    }

    private static func validateDefinition(_ input: DescriptorValidationInput) throws {
        guard !input.id.rawValue.isEmpty else { throw IPCCommandDescriptorError.invalidCommandIdentifier }
        guard !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IPCCommandDescriptorError.missingTitle
        }
        guard !input.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IPCCommandDescriptorError.missingDescription
        }
        guard !input.argumentVariants.isEmpty else { throw IPCCommandDescriptorError.missingArgumentVariant }
        guard Set(input.argumentVariants).count == input.argumentVariants.count else {
            throw IPCCommandDescriptorError.duplicateArgumentVariant
        }
        guard !input.resultVariants.isEmpty else { throw IPCCommandDescriptorError.missingResultVariant }
        guard Set(input.resultVariants).count == input.resultVariants.count else {
            throw IPCCommandDescriptorError.duplicateResultVariant
        }
        guard input.requiredPrivileges.contains(.appCommandExecute) else {
            throw IPCCommandDescriptorError.missingAppCommandExecutePrivilege
        }
        guard !input.examples.isEmpty else { throw IPCCommandDescriptorError.missingExample }
        if input.agentEligibility.requiresAllChannelExposure, input.exposure != .allChannels {
            throw IPCCommandDescriptorError.agentEligibleCommandMustBeExposedOnAllChannels
        }

        for example in input.examples {
            guard !example.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IPCCommandDescriptorError.invalidExampleDescription
            }
            guard example.request.commandId == input.id, example.result.commandId == input.id else {
                throw IPCCommandDescriptorError.exampleCommandIdentifierMismatch
            }
            guard example.request.correlationId == example.result.correlationId else {
                throw IPCCommandDescriptorError.exampleCorrelationMismatch
            }
            guard input.argumentVariants.contains(example.request.arguments.variant) else {
                throw IPCCommandDescriptorError.exampleArgumentVariantNotAllowed
            }
            guard input.resultVariants.contains(example.result.variant) else {
                throw IPCCommandDescriptorError.exampleResultVariantNotAllowed
            }
        }
    }
}

private struct DescriptorValidationInput {
    let id: IPCCommandIdentifier
    let title: String
    let description: String
    let argumentVariants: [IPCCommandArgumentVariant]
    let requiredPrivileges: Set<IPCPrivilegeClass>
    let resultVariants: [IPCCommandResultVariant]
    let examples: [IPCCommandExample]
    let exposure: IPCMethodExposure
    let agentEligibility: IPCAgentEligibility
}
