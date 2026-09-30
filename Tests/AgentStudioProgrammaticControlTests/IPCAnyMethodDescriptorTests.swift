import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC erased method descriptors")
struct IPCAnyMethodDescriptorTests {
    @Test("one heterogeneous catalog retains distinct concrete contracts")
    func heterogeneousCatalogRetainsDistinctContracts() throws {
        let catalog: [IPCAnyMethodDescriptor] = [
            try IPCAnyMethodDescriptor(erasing: textDescriptor()),
            try IPCAnyMethodDescriptor(erasing: countDescriptor(maximumCount: 7)),
        ]

        #expect(catalog.map(\.metadata.name) == ["example.text", "example.count"])
        let expectedParameters = try TextParameters.ipcSchema()
        let expectedResult = try CountResult.ipcSchema()
        #expect(catalog[0].metadata.parameterSchema == expectedParameters)
        #expect(catalog[1].metadata.resultSchema == expectedResult)
        #expect(catalog[0].metadata.examples.count == 1)
        #expect(catalog[1].metadata.examples.count == 1)
    }

    @Test("erased invocation normalizes through the captured typed contract")
    func erasedInvocationRejectsCodableIgnoredFields() throws {
        let descriptor = try IPCAnyMethodDescriptor(erasing: textDescriptor())
        let normalized = try descriptor.normalizeParameters(
            Data(#"{"text":"hello"}"#.utf8)
        )
        #expect(try JSONDecoder().decode(TextParameters.self, from: normalized.data).text == "hello")

        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.normalizeParameters(
                Data(#"{"text":"hello","ignored":"would Codable discard this?"}"#.utf8)
            )
        }
    }

    @Test("catalog examples serialize as JSON objects rather than opaque bytes")
    func examplesAreReadableJSONDocuments() throws {
        let descriptor = try IPCAnyMethodDescriptor(erasing: textDescriptor())
        let encoded = try JSONEncoder().encode(descriptor.metadata)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let examples = try #require(object["examples"] as? [[String: Any]])
        let example = try #require(examples.first)
        let parameters = try #require(example["parameters"] as? [String: Any])
        let result = try #require(example["result"] as? [String: Any])

        #expect(parameters["text"] as? String == "hello")
        #expect(result["echoed"] as? String == "hello")
        #expect(example["parameters"] is [String: Any])
        #expect(!(example["parameters"] is String))
    }

    @Test("catalog metadata rejects unknown fields through its own finite schema")
    func metadataSchemaRejectsUnknownFields() throws {
        let descriptor = try IPCAnyMethodDescriptor(erasing: textDescriptor())
        let encoded = try JSONEncoder().encode(descriptor.metadata)
        _ = try descriptor.catalogEntrySchema.decode(
            IPCMethodCatalogEntry.self,
            from: encoded
        )

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["privateExtension"] = true
        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.catalogEntrySchema.normalize(
                JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("descriptor-specific metadata rejects fields absent from its typed examples")
    func metadataSchemaRejectsTamperedExampleFields() throws {
        let descriptor = try IPCAnyMethodDescriptor(erasing: textDescriptor())
        let encoded = try JSONEncoder().encode(descriptor.metadata)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var examples = try #require(object["examples"] as? [[String: Any]])
        var example = try #require(examples.first)
        var parameters = try #require(example["parameters"] as? [String: Any])
        parameters["untypedParameter"] = "not declared"
        example["parameters"] = parameters
        examples[0] = example
        object["examples"] = examples

        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.catalogEntrySchema.normalize(
                JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("metadata schemas use the finite schema-document leaf")
    func metadataSchemaDescribesSchemasWithoutRecursiveExpansion() throws {
        let descriptor = try IPCAnyMethodDescriptor(erasing: textDescriptor())
        let schema = descriptor.catalogEntrySchema
        guard case .object(let fields) = schema else {
            Issue.record("Expected catalog metadata to be an object")
            return
        }

        #expect(fields.first { $0.name == "parameterSchema" }?.schema == .schemaDocument)
        #expect(fields.first { $0.name == "resultSchema" }?.schema == .schemaDocument)
        guard case .array(let exampleSchema, _, _) = fields.first(where: { $0.name == "examples" })?.schema else {
            Issue.record("Expected exact example documents")
            return
        }
        let exampleProjection = try #require(
            JSONSerialization.jsonObject(with: exampleSchema.jsonSchemaData()) as? [String: Any]
        )
        #expect(exampleProjection["const"] is [String: Any])
        #expect(try schema.jsonSchemaData().count < 32_768)
    }

    @Test("metadata with no examples admits only an empty examples array")
    func emptyExamplesNeedNoArbitraryItemSchema() throws {
        let examples: [IPCMethodExample<TextParameters, TextResult>] = []
        let schema = try IPCMethodCatalogEntry.schemaForExamples(
            methodName: "example.empty",
            examples: examples
        )
        guard case .object(let fields) = schema,
            case .array(_, let minimumCount, let maximumCount) = fields.first(where: { $0.name == "examples" })?.schema
        else {
            Issue.record("Expected a zero-length examples array")
            return
        }

        #expect(minimumCount == 0)
        #expect(maximumCount == 0)
    }

    @Test("dynamic examples are admitted only after typed validation")
    func erasedExamplesCannotBypassTypedValidation() throws {
        #expect(throws: IPCSchemaValidationError.self) {
            try IPCAnyMethodDescriptor(erasing: mismatchedExampleDescriptor())
        }
    }

    @Test("caller-supplied limits shape the typed contract before erasure")
    func policyComposedLimitsAreInjectedWithoutAnErasedDefault() throws {
        let suppliedMaximum = 7
        let descriptor = try IPCAnyMethodDescriptor(
            erasing: countDescriptor(maximumCount: suppliedMaximum)
        )

        _ = try descriptor.normalizeParameters(Data(#"{"count":7}"#.utf8))
        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.normalizeParameters(Data(#"{"count":8}"#.utf8))
        }
        let document =
            try JSONSerialization.jsonObject(
                with: descriptor.metadata.parameterSchema.jsonSchemaData()
            ) as? [String: Any]
        let properties = document?["properties"] as? [String: [String: Any]]
        #expect(properties?["count"]?["maximum"] as? Int == suppliedMaximum)
    }

    @Test("explicit schemas support composition-dependent result types without static fallback")
    func dynamicResultSchemaIsComposedBeforeErasure() throws {
        let resultSchema = DynamicCatalogResult.schema(
            methodNames: ["example.text", "example.count"]
        )
        let descriptor = try IPCMethodDescriptor<TextParameters, DynamicCatalogResult>(
            name: "example.dynamic-catalog",
            description: "Return metadata assembled from the active composition.",
            parameterSchema: try TextParameters.ipcSchema(),
            resultSchema: resultSchema,
            examples: [
                .init(
                    description: "Two active methods",
                    parameters: TextParameters(text: "active"),
                    result: DynamicCatalogResult(methodNames: ["example.text", "example.count"])
                )
            ],
            exposure: .allChannels,
            requiredPrivileges: [.systemRead],
            dataScope: .unspecified,
            allowedTargetKinds: [],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .queryReader,
            principalAvailability: .authenticated,
            resultSemantics: .applied,
            documentedErrors: [],
            isMutating: false,
            correlationPolicy: .notAccepted
        )
        let erased = try IPCAnyMethodDescriptor(erasing: descriptor)
        let encodedMetadata = try JSONEncoder().encode(erased.metadata)

        #expect(erased.metadata.resultSchema == resultSchema)
        _ = try erased.catalogEntrySchema.decode(
            IPCMethodCatalogEntry.self,
            from: encodedMetadata
        )
    }

    @Test("dynamic composed schemas still reject typed example drift before erasure")
    func dynamicResultExampleMustMatchComposedSchema() throws {
        let resultSchema = DynamicCatalogResult.schema(methodNames: ["example.text"])

        #expect(throws: IPCSchemaValidationError.self) {
            try IPCMethodDescriptor<TextParameters, DynamicCatalogResult>(
                name: "example.dynamic-drift",
                description: "Reject a result not admitted by the active composition.",
                parameterSchema: try TextParameters.ipcSchema(),
                resultSchema: resultSchema,
                examples: [
                    .init(
                        description: "Stale composed method",
                        parameters: TextParameters(text: "active"),
                        result: DynamicCatalogResult(methodNames: ["example.count"])
                    )
                ],
                exposure: .allChannels,
                requiredPrivileges: [.systemRead],
                dataScope: .unspecified,
                allowedTargetKinds: [],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .queryReader,
                principalAvailability: .authenticated,
                resultSemantics: .applied,
                documentedErrors: [],
                isMutating: false,
                correlationPolicy: .notAccepted
            )
        }
    }

    @Test("erased results decode through the captured concrete result contract")
    func erasedResultsUseConcreteResultDecoder() throws {
        let descriptor = try IPCAnyMethodDescriptor(erasing: textDescriptor())
        let normalized = try descriptor.normalizeResult(Data(#"{"echoed":"hello"}"#.utf8))
        #expect(try JSONDecoder().decode(TextResult.self, from: normalized.data).echoed == "hello")
        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.normalizeResult(Data(#"{"echoed":"hello","privateField":"private-value"}"#.utf8))
        }

        let resultSchema = IPCJSONSchema.object(fields: [
            .init(name: "echoed", description: "Echoed text", schema: .string()),
            .init(name: "requiredContext", description: "Context retained by the typed result", schema: .string()),
        ])
        let contract = try IPCMethodContract<TextParameters, TextResult>(
            parameterSchema: TextParameters.ipcSchema(), resultSchema: resultSchema
        )
        let payload = Data(#"{"echoed":"hello","requiredContext":"present on wire"}"#.utf8)
        _ = try resultSchema.normalize(payload)
        #expect(throws: IPCSchemaValidationError.self) {
            try contract.decodeResult(from: payload)
        }
    }

    @Test("subscription response delivery survives erasure and schema projection")
    func subscriptionDeliveryIsDescriptorOwned() throws {
        let descriptor = try IPCAnyMethodDescriptor(erasing: textDescriptor(responseDelivery: .subscription))
        #expect(descriptor.metadata.responseDelivery == .subscription)
        _ = try descriptor.catalogEntrySchema.decode(
            IPCMethodCatalogEntry.self, from: JSONEncoder().encode(descriptor.metadata)
        )
        #expect(try IPCAnyMethodDescriptor(erasing: textDescriptor()).metadata.responseDelivery == .single)
    }

    private func textDescriptor(
        responseDelivery: IPCMethodResponseDelivery = .single
    ) throws -> IPCMethodDescriptor<TextParameters, TextResult> {
        try IPCMethodDescriptor(
            name: "example.text",
            description: "Echo one exact text value.",
            examples: [
                .init(
                    description: "Echo text",
                    parameters: TextParameters(text: "hello"),
                    result: TextResult(echoed: "hello")
                )
            ],
            exposure: .allChannels,
            requiredPrivileges: [.systemRead],
            dataScope: .unspecified,
            allowedTargetKinds: [],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .queryReader,
            principalAvailability: .authenticated,
            resultSemantics: .applied,
            documentedErrors: [
                .init(reason: "invalidParams", description: "Text does not satisfy the declared contract.")
            ],
            isMutating: false,
            correlationPolicy: .notAccepted,
            responseDelivery: responseDelivery
        )
    }

    private func countDescriptor(
        maximumCount: Int
    ) throws -> IPCMethodDescriptor<CountParameters, CountResult> {
        try IPCMethodDescriptor(
            name: "example.count",
            description: "Accept a caller-bounded count.",
            parameterSchema: CountParameters.ipcSchema(maximumCount: maximumCount),
            resultSchema: CountResult.ipcSchema(),
            examples: [
                .init(
                    description: "Highest accepted count",
                    parameters: CountParameters(count: maximumCount),
                    result: CountResult(acceptedCount: maximumCount)
                )
            ],
            exposure: .allChannels,
            requiredPrivileges: [.systemRead],
            dataScope: .unspecified,
            allowedTargetKinds: [],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .queryReader,
            principalAvailability: .authenticated,
            resultSemantics: .applied,
            documentedErrors: [
                .init(reason: "invalidParams", description: "Count exceeds the composed limit.")
            ],
            isMutating: false,
            correlationPolicy: .notAccepted
        )
    }

    private func mismatchedExampleDescriptor() throws
        -> IPCMethodDescriptor<MismatchedParameters, TextResult>
    {
        try IPCMethodDescriptor(
            name: "example.mismatch",
            description: "Prove typed validation precedes erasure.",
            examples: [
                .init(
                    description: "Invalid typed example",
                    parameters: MismatchedParameters(text: "hello", undeclared: true),
                    result: TextResult(echoed: "hello")
                )
            ],
            exposure: .allChannels,
            requiredPrivileges: [.systemRead],
            dataScope: .unspecified,
            allowedTargetKinds: [],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .queryReader,
            principalAvailability: .authenticated,
            resultSemantics: .applied,
            documentedErrors: [],
            isMutating: false,
            correlationPolicy: .notAccepted
        )
    }
}

private struct TextParameters: IPCSchemaProviding, Equatable {
    let text: String

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "text", description: "Exact input text", schema: .string(minimumLength: 1))
        ])
    }
}

private struct TextResult: IPCSchemaProviding, Equatable {
    let echoed: String

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "echoed", description: "Exact echoed text", schema: .string())
        ])
    }
}

private struct CountParameters: IPCSchemaProviding, Equatable {
    let count: Int

    static func ipcSchema() throws -> IPCJSONSchema {
        ipcSchema(maximumCount: 1)
    }

    static func ipcSchema(maximumCount: Int) -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "count", description: "Caller-bounded count",
                schema: .integer(minimum: 0, maximum: Int64(maximumCount)))
        ])
    }
}

private struct CountResult: IPCSchemaProviding, Equatable {
    let acceptedCount: Int

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(name: "acceptedCount", description: "Accepted count", schema: .integer(minimum: 0))
        ])
    }
}

private struct MismatchedParameters: IPCSchemaProviding, Equatable {
    let text: String
    let undeclared: Bool

    static func ipcSchema() throws -> IPCJSONSchema {
        try TextParameters.ipcSchema()
    }
}

private struct DynamicCatalogResult: Codable, Equatable, Sendable {
    let methodNames: [String]

    static func schema(methodNames: [String]) -> IPCJSONSchema {
        IPCDynamicSchema.object(methodNames: methodNames)
    }
}

private enum IPCDynamicSchema {
    static func object(methodNames: [String]) -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "methodNames",
                description: "Method names in the active composition",
                schema: .array(items: .string(allowedValues: methodNames), minimumCount: 1)
            )
        ])
    }
}
