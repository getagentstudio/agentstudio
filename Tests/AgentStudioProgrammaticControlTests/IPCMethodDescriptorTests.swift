import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC typed method descriptor")
struct IPCMethodDescriptorTests {
    @Test("dynamic command relationship must name a declared required string field")
    func dynamicCommandRelationshipValidatesParameterField() throws {
        for field in ["", "undeclared", "explanation"] {
            #expect(throws: IPCMethodDescriptorError.invalidCommandIdentifier) {
                try makeDescriptor(
                    correlationId: UUIDv7.generate(),
                    commandRelationship: .appCommandParameter(field: field)
                )
            }
        }
        let descriptor = try makeDescriptor(
            correlationId: UUIDv7.generate(), commandRelationship: .appCommandParameter(field: "operation")
        )
        let encoded = try JSONEncoder().encode(descriptor.metadata.commandRelationship)
        #expect(
            try JSONDecoder().decode(IPCCommandRelationship.self, from: encoded)
                == .appCommandParameter(field: "operation"))
    }

    @Test("an agent-eligible method cannot be debug-only; a not-yet-allowed one can")
    func agentEligibleMethodMustReachEveryChannel() throws {
        for eligibility in [IPCAgentEligibility.ownPane, .anyTarget] {
            #expect(throws: IPCMethodDescriptorError.agentEligibleMethodMustBeExposedOnAllChannels) {
                try makeDescriptor(
                    correlationId: UUIDv7.generate(), exposure: .debugTesting, agentEligibility: eligibility)
            }
        }
        let refused = try makeDescriptor(
            correlationId: UUIDv7.generate(), exposure: .debugTesting, agentEligibility: .notYetAllowed)
        let established = try makeDescriptor(correlationId: UUIDv7.generate(), exposure: .debugTesting)

        #expect(refused.metadata.agentEligibility == .notYetAllowed)
        #expect(established.metadata.agentEligibility == nil)
    }

    @Test("descriptor uses one typed contract for examples, admission, and results")
    func descriptorUsesOneTypedContract() throws {
        let correlationId = UUIDv7.generate()
        let descriptor = try makeDescriptor(correlationId: correlationId)
        let parameters = try descriptor.decodeParameters(
            from: Data(
                "{\"operation\":\"needsYou\",\"explanation\":\"hello\",\"correlationId\":\"\(correlationId.uuidString)\"}"
                    .utf8
            )
        )
        let encodedResult = try descriptor.encodeResult(
            DescriptorFixtureResult(disposition: "saved")
        )

        #expect(
            parameters
                == DescriptorFixtureParameters(
                    operation: .needsYou,
                    explanation: "hello",
                    correlationId: correlationId
                )
        )
        #expect(
            try JSONDecoder().decode(DescriptorFixtureResult.self, from: encodedResult)
                == DescriptorFixtureResult(disposition: "saved")
        )
        #expect(descriptor.examples.count == 1)
    }

    @Test("construction rejects a typed example that disagrees with its declared schema")
    func constructionRejectsInvalidTypedExample() throws {
        #expect(throws: IPCSchemaValidationError.self) {
            try IPCMethodDescriptor<DescriptorInvalidParameters, DescriptorFixtureResult>(
                name: "example.invalid",
                description: "Exercise typed example validation.",
                examples: [
                    IPCMethodExample(
                        description: "Invalid fixture",
                        parameters: DescriptorInvalidParameters(
                            operation: .needsYou,
                            correlationId: UUIDv7.generate(),
                            undeclaredValue: true
                        ),
                        result: DescriptorFixtureResult(disposition: "saved")
                    )
                ],
                exposure: .allChannels,
                requiredPrivileges: [.paneContextRead],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .queryReader,
                principalAvailability: .authenticated,
                resultSemantics: .accepted,
                documentedErrors: fixtureErrors,
                isMutating: false,
                correlationPolicy: .required,
                offlineEligibility: .never,
                modelCalls: []
            )
        }
    }

    @Test("metadata keeps authority, execution ownership, and command identity separate")
    func metadataKeepsAuthorityAndIdentitySeparate() throws {
        let descriptor = try makeDescriptor(
            correlationId: UUIDv7.generate(),
            commandRelationship: .appCommand(identifier: "exampleCommand")
        )

        #expect(descriptor.name == "example.mutation")
        #expect(descriptor.exposure == .allChannels)
        #expect(descriptor.requiredPrivileges == [.layoutMutate])
        #expect(descriptor.dataScope == .paneContext)
        #expect(descriptor.allowedTargetKinds == [.pane])
        #expect(descriptor.commandRelationship == .appCommand(identifier: "exampleCommand"))
        #expect(descriptor.executionOwner == .workspaceAction)
        #expect(descriptor.principalAvailability == .authenticated)
        #expect(descriptor.resultSemantics == .applied)
        #expect(descriptor.documentedErrors == fixtureErrors)
        #expect(descriptor.isMutating)
        #expect(descriptor.correlationPolicy == .required)
    }

    @Test("catalog metadata is Codable while examples remain typed")
    func catalogMetadataIsCodableWithTypedExamples() throws {
        let descriptor = try makeDescriptor(correlationId: UUIDv7.generate())
        let encoded = try JSONEncoder().encode(descriptor.metadata)
        let decoded = try JSONDecoder().decode(
            IPCMethodDescriptorMetadata<DescriptorFixtureParameters, DescriptorFixtureResult>.self,
            from: encoded
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(decoded.name == descriptor.name)
        #expect(decoded.examples.first?.parameters == descriptor.examples.first?.parameters)
        #expect(object["parameterSchema"] is [String: Any])
        #expect(object["resultSchema"] is [String: Any])
        #expect(object["examples"] is [[String: Any]])
    }

    @Test("mutation metadata requires a required non-null UUID correlation field")
    func mutationRequiresMatchingCorrelationSchema() throws {
        for invalidPolicy in [IPCCorrelationPolicy.notAccepted, .optional] {
            #expect(throws: IPCMethodDescriptorError.self) {
                try makeDescriptor(
                    correlationId: UUIDv7.generate(),
                    correlationPolicy: invalidPolicy
                )
            }
        }

        #expect(throws: IPCMethodDescriptorError.self) {
            try IPCMethodDescriptor<DescriptorOptionalCorrelationParameters, DescriptorFixtureResult>(
                name: "example.optional-correlation",
                description: "Exercise correlation schema validation.",
                examples: [
                    IPCMethodExample(
                        description: "Optional correlation fixture",
                        parameters: DescriptorOptionalCorrelationParameters(correlationId: nil),
                        result: DescriptorFixtureResult(disposition: "saved")
                    )
                ],
                exposure: .allChannels,
                requiredPrivileges: [.layoutMutate],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .workspaceAction,
                principalAvailability: .authenticated,
                resultSemantics: .applied,
                documentedErrors: fixtureErrors,
                isMutating: true,
                correlationPolicy: .required,
                offlineEligibility: .never,
                modelCalls: []
            )
        }
    }

    @Test("mutation correlation rejects a sentinel-only UUID spelling schema")
    func mutationRejectsSentinelOnlyCorrelationSchema() throws {
        let sentinel = try #require(
            UUID(uuidString: "01941f29-7c00-7000-8000-000000000001")
        )

        #expect(throws: IPCMethodDescriptorError.self) {
            try IPCMethodDescriptor<DescriptorSentinelCorrelationParameters, DescriptorFixtureResult>(
                name: "example.sentinel-correlation",
                description: "Exercise structural UUID schema validation.",
                examples: [
                    IPCMethodExample(
                        description: "Sentinel-only correlation fixture",
                        parameters: DescriptorSentinelCorrelationParameters(correlationId: sentinel),
                        result: DescriptorFixtureResult(disposition: "saved")
                    )
                ],
                exposure: .allChannels,
                requiredPrivileges: [.layoutMutate],
                dataScope: .paneContext,
                allowedTargetKinds: [.pane],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .workspaceAction,
                principalAvailability: .authenticated,
                resultSemantics: .applied,
                documentedErrors: fixtureErrors,
                isMutating: true,
                correlationPolicy: .required,
                offlineEligibility: .never,
                modelCalls: []
            )
        }
    }

    @Test("one method can project several field-mapped model invocations")
    func oneMethodProjectsSeveralModelCalls() throws {
        let correlationId = UUIDv7.generate()
        let descriptor = try makeDescriptor(
            correlationId: correlationId,
            offlineEligibility: .modelCallVariants([.needsYou, .done]),
            modelCalls: reportModelCalls
        )

        #expect(descriptor.modelCalls.map(\.variant) == [.needsYou, .needsYouClear, .done])
        #expect(descriptor.modelCalls[0].selectors == [.init(parameterField: "operation", equals: "needsYou")])
        #expect(descriptor.modelCalls[0].scalarArguments.first?.parameterField == "explanation")
        #expect(descriptor.offlineEligibility == .modelCallVariants([.needsYou, .done]))
        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.decodeParameters(
                from: Data(
                    "{\"operation\":\"done\",\"explanation\":\"not a done field\",\"correlationId\":\"\(correlationId.uuidString)\"}"
                        .utf8
                )
            )
        }
    }

    @Test("offline eligibility excludes clear and variants absent from model projections")
    func offlineEligibilityRejectsIneligibleVariants() throws {
        for invalidEligibility in [
            IPCMethodOfflineEligibility.modelCallVariants([.needsYouClear]),
            .modelCallVariants([.message]),
        ] {
            #expect(throws: IPCMethodDescriptorError.self) {
                try makeDescriptor(
                    correlationId: UUIDv7.generate(),
                    offlineEligibility: invalidEligibility,
                    modelCalls: reportModelCalls
                )
            }
        }
    }

    @Test("model selectors and scalar arguments must name declared parameter fields")
    func modelProjectionFieldsMustExist() throws {
        var invalidCalls = reportModelCalls
        invalidCalls[0] = IPCModelCallProjection(
            variant: .needsYou,
            selectors: [.init(parameterField: "missingSelector", equals: "needsYou")],
            scalarArguments: [
                .init(
                    name: "explanation",
                    parameterField: "missingArgument",
                    description: "Exact private explanation",
                    isRequired: true)
            ],
            successReply: "Needs you recorded.",
            queuedReply: "Report queued."
        )

        #expect(throws: IPCMethodDescriptorError.self) {
            try makeDescriptor(
                correlationId: UUIDv7.generate(),
                modelCalls: invalidCalls
            )
        }
    }

    @Test("the model-call vocabulary is closed to the four settled invocations")
    func modelCallVocabularyIsClosed() {
        #expect(
            IPCModelCallVariant.allCases.map(\.rawValue) == [
                "message", "needs-you", "needs-you --clear", "done",
            ]
        )
    }

    private var fixtureErrors: [IPCMethodErrorCase] {
        [
            .init(reason: "invalidParams", description: "A declared parameter is missing or invalid."),
            .init(reason: "missingGrant", description: "The principal lacks the required target scope."),
        ]
    }

    private var reportModelCalls: [IPCModelCallProjection] {
        [
            .init(
                variant: .needsYou,
                selectors: [.init(parameterField: "operation", equals: "needsYou")],
                scalarArguments: [
                    .init(
                        name: "explanation",
                        parameterField: "explanation",
                        description: "Exact private explanation",
                        isRequired: true)
                ],
                successReply: "Needs you recorded.",
                queuedReply: "Report queued."
            ),
            .init(
                variant: .needsYouClear,
                selectors: [.init(parameterField: "operation", equals: "clear")],
                scalarArguments: [],
                successReply: "Needs you cleared.",
                queuedReply: nil
            ),
            .init(
                variant: .done,
                selectors: [.init(parameterField: "operation", equals: "done")],
                scalarArguments: [],
                successReply: "Done recorded.",
                queuedReply: "Report queued."
            ),
        ]
    }

    @Test("schema definitions are checked before model metadata indexes fields")
    func duplicateSchemaFieldsAreRejectedBeforeModelIndexing() throws {
        let operation = IPCObjectField(
            name: "operation", description: "Report operation",
            schema: .string(allowedValues: ["needsYou", "clear", "done"])
        )
        let schema = IPCJSONSchema.object(fields: [
            operation,
            operation,
            .init(name: "correlationId", description: "Logical mutation", schema: IPCSchemaScalars.uuid),
            .optional("explanation", description: "Report explanation", schema: .string()),
        ])
        #expect(throws: IPCSchemaValidationError.self) {
            try makeDescriptor(
                correlationId: UUIDv7.generate(),
                modelCalls: reportModelCalls,
                parameterSchema: schema
            )
        }
    }

    private func makeDescriptor(
        correlationId: UUID,
        commandRelationship: IPCCommandRelationship = .noInteractiveIdentity,
        correlationPolicy: IPCCorrelationPolicy = .required,
        offlineEligibility: IPCMethodOfflineEligibility = .never,
        modelCalls: [IPCModelCallProjection] = [],
        parameterSchema: IPCJSONSchema? = nil,
        exposure: IPCMethodExposure = .allChannels,
        agentEligibility: IPCAgentEligibility? = nil
    ) throws -> IPCMethodDescriptor<DescriptorFixtureParameters, DescriptorFixtureResult> {
        try IPCMethodDescriptor(
            name: "example.mutation",
            description: "Perform a fixture mutation with typed input and output.",
            parameterSchema: try parameterSchema ?? DescriptorFixtureParameters.ipcSchema(),
            resultSchema: try DescriptorFixtureResult.ipcSchema(),
            examples: [
                IPCMethodExample(
                    description: "Accepted fixture mutation",
                    parameters: DescriptorFixtureParameters(
                        operation: .needsYou,
                        explanation: "hello",
                        correlationId: correlationId
                    ),
                    result: DescriptorFixtureResult(disposition: "saved")
                )
            ],
            exposure: exposure,
            requiredPrivileges: [.layoutMutate],
            dataScope: .paneContext,
            allowedTargetKinds: [.pane],
            commandRelationship: commandRelationship,
            executionOwner: .workspaceAction,
            principalAvailability: .authenticated,
            resultSemantics: .applied,
            documentedErrors: fixtureErrors,
            isMutating: true,
            correlationPolicy: correlationPolicy,
            offlineEligibility: offlineEligibility,
            modelCalls: modelCalls,
            agentEligibility: agentEligibility
        )
    }
}

private enum DescriptorFixtureOperation: String, CaseIterable, Codable, Sendable {
    case needsYou
    case clear
    case done
}

extension DescriptorFixtureOperation: IPCSchemaProviding {}

private struct DescriptorFixtureParameters: IPCSchemaProviding, Equatable {
    let operation: DescriptorFixtureOperation
    let explanation: String?
    let correlationId: UUID

    static func ipcSchema() throws -> IPCJSONSchema {
        .oneOf([
            .object(fields: [
                .init(
                    name: "operation", description: "Fixture operation variant",
                    schema: .string(allowedValues: [DescriptorFixtureOperation.needsYou.rawValue])),
                .init(name: "explanation", description: "Exact private explanation", schema: .string()),
                .init(
                    name: "correlationId", description: "Logical mutation UUID",
                    schema: IPCSchemaScalars.uuid),
            ]),
            .object(fields: [
                .init(
                    name: "operation", description: "Fixture operation variant",
                    schema: .string(allowedValues: [DescriptorFixtureOperation.clear.rawValue])),
                .init(
                    name: "correlationId", description: "Logical mutation UUID",
                    schema: IPCSchemaScalars.uuid),
            ]),
            .object(fields: [
                .init(
                    name: "operation", description: "Fixture operation variant",
                    schema: .string(allowedValues: [DescriptorFixtureOperation.done.rawValue])),
                .init(
                    name: "correlationId", description: "Logical mutation UUID",
                    schema: IPCSchemaScalars.uuid),
            ]),
        ])
    }
}

private struct DescriptorInvalidParameters: IPCSchemaProviding, Equatable {
    let operation: DescriptorFixtureOperation
    let correlationId: UUID
    let undeclaredValue: Bool

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "operation", description: "Fixture operation variant",
                schema: try DescriptorFixtureOperation.ipcSchema()),
            .init(name: "correlationId", description: "Logical mutation UUID", schema: IPCSchemaScalars.uuid),
        ])
    }
}

private struct DescriptorOptionalCorrelationParameters: IPCSchemaProviding, Equatable {
    let correlationId: UUID?

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .optional("correlationId", description: "Optional logical mutation UUID", schema: IPCSchemaScalars.uuid)
        ])
    }
}

private struct DescriptorSentinelCorrelationParameters: IPCSchemaProviding, Equatable {
    let correlationId: UUID

    init(correlationId: UUID) {
        self.correlationId = correlationId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCorrelationId = try container.decode(String.self, forKey: .correlationId)
        guard let correlationId = UUID(uuidString: rawCorrelationId) else {
            throw DecodingError.dataCorruptedError(
                forKey: .correlationId,
                in: container,
                debugDescription: "Fixture correlation must be a UUID"
            )
        }
        self.correlationId = correlationId
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(correlationId.uuidString.lowercased(), forKey: .correlationId)
    }

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "correlationId",
                description: "One sentinel UUID spelling rather than the UUID contract",
                schema: .string(allowedValues: ["01941f29-7c00-7000-8000-000000000001"]))
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case correlationId
    }
}

private struct DescriptorFixtureResult: IPCSchemaProviding, Equatable {
    let disposition: String

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "disposition", description: "Fixture operation disposition",
                schema: .string(allowedValues: ["saved"]))
        ])
    }
}
