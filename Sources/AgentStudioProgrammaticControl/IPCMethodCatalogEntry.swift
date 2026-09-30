import Foundation

extension IPCMethodExposure: IPCSchemaProviding {}
extension IPCHandleKind: IPCSchemaProviding {}
extension IPCExecutionOwner: IPCSchemaProviding {}
extension IPCPrincipalAvailability: IPCSchemaProviding {}
extension IPCResultSemantics: IPCSchemaProviding {}
extension IPCCorrelationPolicy: IPCSchemaProviding {}
extension IPCMethodResponseDelivery: IPCSchemaProviding {}
extension IPCModelCallVariant: IPCSchemaProviding {}

package struct IPCMethodExampleDocument: Codable, Equatable, Sendable {
    package let description: String
    let parameters: IPCSchemaValue
    let result: IPCSchemaValue

    init(description: String, parameters: Data, result: Data) throws {
        self.description = description
        self.parameters = try JSONDecoder().decode(IPCSchemaValue.self, from: parameters)
        self.result = try JSONDecoder().decode(IPCSchemaValue.self, from: result)
    }
}

package struct IPCMethodCatalogEntry: Codable, Equatable, Sendable {
    package let name: String
    package let description: String
    package let parameterSchema: IPCJSONSchema
    package let resultSchema: IPCJSONSchema
    package let examples: [IPCMethodExampleDocument]
    package let exposure: IPCMethodExposure
    package let requiredPrivileges: [IPCPrivilegeClass]
    package let dataScope: IPCDataScope
    package let allowedTargetKinds: [IPCHandleKind]
    package let commandRelationship: IPCCommandRelationship
    package let executionOwner: IPCExecutionOwner
    package let principalAvailability: IPCPrincipalAvailability
    package let resultSemantics: IPCResultSemantics
    package let documentedErrors: [IPCMethodErrorCase]
    package let isMutating: Bool
    package let correlationPolicy: IPCCorrelationPolicy
    package let responseDelivery: IPCMethodResponseDelivery
    package let offlineEligibility: IPCMethodOfflineEligibility
    package let modelCalls: [IPCModelCallProjection]
    /// Absent for methods that keep the established Agent IPC v2 admission.
    package let agentEligibility: IPCAgentEligibility?
}

extension IPCMethodCatalogEntry {
    package static func schemaForExamples<Parameters, Result>(
        methodName: String,
        examples: [IPCMethodExample<Parameters, Result>]
    ) throws -> IPCJSONSchema where Parameters: Codable & Sendable, Result: Codable & Sendable {
        let examplesSchema: IPCJSONSchema
        if examples.isEmpty {
            examplesSchema = .array(items: .null, maximumCount: 0)
        } else {
            let literalSchemas = try examples.map { try IPCJSONSchema.literal($0) }
            let itemSchema = literalSchemas.count == 1 ? literalSchemas[0] : .oneOf(literalSchemas)
            examplesSchema = .array(items: itemSchema)
        }

        return try metadataSchema(
            methodName: methodName,
            examplesSchema: examplesSchema
        )
    }

    package static func schemaForReceivedEntry(
        _ entry: IPCMethodCatalogEntry
    ) throws -> IPCJSONSchema {
        let validatedSchemas = try IPCValidatedMethodCatalogSchemas(validating: entry)
        return try schemaForReceivedEntry(entry, validatedSchemas: validatedSchemas)
    }

    static func schemaForReceivedEntry(
        _ entry: IPCMethodCatalogEntry,
        validatedSchemas: IPCValidatedMethodCatalogSchemas
    ) throws -> IPCJSONSchema {
        try entry.validateReceivedMetadataAndExamples(using: validatedSchemas)
        let examplesSchema: IPCJSONSchema
        if entry.examples.isEmpty {
            examplesSchema = .array(items: .null, maximumCount: 0)
        } else {
            let literalSchemas = try entry.examples.map { try IPCJSONSchema.literal($0) }
            let itemSchema = literalSchemas.count == 1 ? literalSchemas[0] : .oneOf(literalSchemas)
            examplesSchema = .array(items: itemSchema)
        }
        return try metadataSchema(
            methodName: entry.name,
            examplesSchema: examplesSchema
        )
    }

    private func validateReceivedMetadataAndExamples(
        using validatedSchemas: IPCValidatedMethodCatalogSchemas
    ) throws {
        do {
            try IPCMethodMetadataValidator.validate(
                IPCMethodMetadataValidationInput(
                    name: name,
                    description: description,
                    parameterSchema: parameterSchema,
                    requiredPrivileges: requiredPrivileges,
                    allowedTargetKinds: allowedTargetKinds,
                    commandRelationship: commandRelationship,
                    documentedErrors: documentedErrors,
                    isMutating: isMutating,
                    correlationPolicy: correlationPolicy,
                    offlineEligibility: offlineEligibility,
                    modelCalls: modelCalls
                )
            )
        } catch {
            throw IPCSchemaValidationError(
                fieldPath: "$",
                reason: .invalidDefinition,
                expected: "consistent typed method metadata"
            )
        }
        for example in examples {
            guard !example.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IPCSchemaValidationError(
                    fieldPath: "$.examples",
                    reason: .invalidDefinition,
                    expected: "a described typed method example"
                )
            }
            _ = try validatedSchemas.parameterSchema.normalize(example.parameters.encoded())
            _ = try validatedSchemas.resultSchema.normalize(example.result.encoded())
        }
    }

    private static func metadataSchema(
        methodName: String,
        examplesSchema: IPCJSONSchema
    ) throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "name", description: "Open method name", schema: .string(allowedValues: [methodName])),
            .init(
                name: "description", description: "Agent-facing method description", schema: .string(minimumLength: 1)),
            .init(name: "parameterSchema", description: "Complete parameter JSON Schema", schema: .schemaDocument),
            .init(name: "resultSchema", description: "Complete result JSON Schema", schema: .schemaDocument),
            .init(
                name: "examples", description: "Typed executable method examples",
                schema: examplesSchema),
            .init(
                name: "exposure", description: "Application channel exposure", schema: try IPCMethodExposure.ipcSchema()
            ),
            .init(
                name: "requiredPrivileges", description: "Privileges required for admission",
                schema: .array(items: try IPCPrivilegeClass.ipcSchema(), minimumCount: 1)),
            .init(
                name: "dataScope", description: "Data category accessed by the method",
                schema: try IPCDataScope.ipcSchema()),
            .init(
                name: "allowedTargetKinds", description: "Durable target handle kinds accepted by the method",
                schema: .array(items: try IPCHandleKind.ipcSchema())),
            .init(
                name: "commandRelationship", description: "Relationship to interactive AppCommand identity",
                schema: try IPCCommandRelationship.ipcSchema()),
            .init(
                name: "executionOwner", description: "Owner that applies or reads the request",
                schema: try IPCExecutionOwner.ipcSchema()),
            .init(
                name: "principalAvailability", description: "Authentication state required for invocation",
                schema: try IPCPrincipalAvailability.ipcSchema()),
            .init(
                name: "resultSemantics", description: "Boundary established by a successful result",
                schema: try IPCResultSemantics.ipcSchema()),
            .init(
                name: "documentedErrors", description: "Stable method-specific failure cases",
                schema: .array(items: try IPCMethodErrorCase.ipcSchema())),
            .init(name: "isMutating", description: "Whether the method may change application state", schema: .boolean),
            .init(
                name: "correlationPolicy", description: "Logical request correlation requirement",
                schema: try IPCCorrelationPolicy.ipcSchema()),
            .init(
                name: "responseDelivery", description: "Single response or subscription stream consumption",
                schema: try IPCMethodResponseDelivery.ipcSchema()),
            .init(
                name: "offlineEligibility", description: "Notification variants eligible for offline collection",
                schema: try IPCMethodOfflineEligibility.ipcSchema()),
            .init(
                name: "modelCalls", description: "Small model-facing scalar projections",
                schema: .array(items: try IPCModelCallProjection.ipcSchema())),
            .optional(
                "agentEligibility", description: "What a pane-bound agent may do with this method",
                schema: try IPCAgentEligibility.ipcSchema()),
        ])
    }
}

struct IPCValidatedMethodCatalogSchemas {
    let parameterSchema: IPCValidatedJSONSchema
    let resultSchema: IPCValidatedJSONSchema

    init(validating entry: IPCMethodCatalogEntry) throws {
        parameterSchema = try IPCValidatedJSONSchema(schema: entry.parameterSchema)
        resultSchema = try IPCValidatedJSONSchema(schema: entry.resultSchema)
    }

    init(parameterSchema: IPCValidatedJSONSchema, resultSchema: IPCValidatedJSONSchema) {
        self.parameterSchema = parameterSchema
        self.resultSchema = resultSchema
    }
}

extension IPCCommandRelationship: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(
                    name: "kind", description: "No interactive command identity",
                    schema: .string(allowedValues: ["noInteractiveIdentity"]))
            ]),
            .object(fields: [
                .init(
                    name: "kind", description: "Reuses one AppCommand identity",
                    schema: .string(allowedValues: ["appCommand"])),
                .init(name: "identifier", description: "Open AppCommand identifier", schema: .string(minimumLength: 1)),
            ]),
            .object(fields: [
                .init(
                    name: "kind", description: "AppCommand selected by a typed parameter",
                    schema: .string(allowedValues: ["appCommandParameter"])),
                .init(
                    name: "field", description: "Declared parameter carrying the open command identity",
                    schema: .string(minimumLength: 1)),
            ]),
        ])
    }
}

extension IPCMethodOfflineEligibility: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(
                    name: "kind", description: "No offline collection",
                    schema: .string(allowedValues: ["never"]))
            ]),
            .object(fields: [
                .init(
                    name: "kind", description: "Selected model-call variants may collect offline",
                    schema: .string(allowedValues: ["modelCallVariants"])),
                .init(
                    name: "variants", description: "Offline-eligible model-call variants",
                    schema: .array(items: try IPCModelCallVariant.ipcSchema(), minimumCount: 1)),
            ]),
        ])
    }
}

extension IPCMethodErrorCase: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "reason", description: "Stable open error reason", schema: .string(minimumLength: 1)),
            .init(name: "description", description: "Caller-facing failure meaning", schema: .string(minimumLength: 1)),
        ])
    }
}

extension IPCModelCallSelector: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "parameterField", description: "Declared selector parameter field",
                schema: .string(minimumLength: 1)),
            .init(name: "equals", description: "Declared selector value", schema: .string()),
        ])
    }
}

extension IPCModelScalarArgument: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "name", description: "Scalar CLI argument name", schema: .string(minimumLength: 1)),
            .init(
                name: "parameterField", description: "Declared parameter field receiving the scalar",
                schema: .string(minimumLength: 1)),
            .init(name: "description", description: "Scalar argument meaning", schema: .string(minimumLength: 1)),
            .init(name: "isRequired", description: "Whether the scalar must be supplied", schema: .boolean),
        ])
    }
}

extension IPCModelCallProjection: IPCSchemaProviding {
    package static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "variant", description: "Closed model-facing invocation",
                schema: try IPCModelCallVariant.ipcSchema()),
            .init(
                name: "selectors", description: "Fixed fields selecting the typed alternative",
                schema: .array(items: try IPCModelCallSelector.ipcSchema())),
            .init(
                name: "scalarArguments", description: "Plain scalar argument mappings",
                schema: .array(items: try IPCModelScalarArgument.ipcSchema())),
            .init(name: "successReply", description: "Short successful reply", schema: .string(minimumLength: 1)),
            .optional(
                "queuedReply", description: "Short durable-queue reply when eligible", schema: .string(minimumLength: 1)
            ),
        ])
    }
}
