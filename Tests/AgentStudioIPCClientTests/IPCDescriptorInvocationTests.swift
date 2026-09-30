import AgentStudioIPCClientCore
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("Descriptor-driven IPC CLI invocation")
struct IPCDescriptorInvocationTests {
    @Test("plain method options derive names and scalar types from the descriptor schema")
    func plainMethodOptionsDeriveNamesAndScalarTypes() throws {
        let generatedCorrelation = UUIDv7.generate()
        let correlationGenerator = IPCDescriptorInvocationCorrelationGenerator(generatedCorrelation)

        let invocation = try parse(
            [
                "fixture.control",
                "--retry-count", "3",
                "--is-enabled", "true",
                "--display-name", "Terminal \u{1F680}",
            ],
            correlationGenerator: correlationGenerator
        )

        #expect(invocation.descriptor.metadata.name == "fixture.control")
        #expect(invocation.presentation == .tooling)
        #expect(
            try decodeIPCDescriptorInvocationParameters(
                IPCDescriptorInvocationToolingParameters.self, from: invocation.normalizedParameters.data)
                == IPCDescriptorInvocationToolingParameters(
                    retryCount: 3,
                    isEnabled: true,
                    displayName: "Terminal \u{1F680}",
                    displayMode: .compact,
                    tags: nil,
                    correlationId: generatedCorrelation
                )
        )
        #expect(correlationGenerator.invocationCount == 1)
    }

    @Test("schema defaults survive typed normalization")
    func schemaDefaultsSurviveTypedNormalization() throws {
        let invocation = try parse(
            [
                "fixture.control",
                "--retry-count", "1",
                "--is-enabled", "false",
                "--display-name", "defaulted",
            ],
            correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(UUIDv7.generate())
        )

        let parameters = try decodeIPCDescriptorInvocationParameters(
            IPCDescriptorInvocationToolingParameters.self, from: invocation.normalizedParameters.data)
        #expect(parameters.displayMode == .compact)
        #expect(parameters.isEnabled == false)
    }

    @Test("caller correlation is retained and does not invoke the generator")
    func callerCorrelationIsRetainedWithoutGeneration() throws {
        let callerCorrelation = UUIDv7.generate()
        let correlationGenerator = IPCDescriptorInvocationCorrelationGenerator(UUIDv7.generate())

        let invocation = try parse(
            [
                "fixture.control",
                "--retry-count", "2",
                "--is-enabled", "true",
                "--display-name", "caller supplied",
                "--correlation-id", callerCorrelation.uuidString,
            ],
            correlationGenerator: correlationGenerator
        )

        let parameters = try decodeIPCDescriptorInvocationParameters(
            IPCDescriptorInvocationToolingParameters.self, from: invocation.normalizedParameters.data)
        #expect(parameters.correlationId == callerCorrelation)
        #expect(correlationGenerator.invocationCount == 0)
    }

    @Test("JSON and stdin enter the same typed normalization path")
    func jsonAndStandardInputShareTypedNormalization() throws {
        let correlation = UUIDv7.generate()
        let payload = Data(
            """
            {
              "retryCount": 4,
              "isEnabled": true,
              "displayName": "line one\\nline two \u{96EA}",
              "tags": ["alpha", "\u{03B2}"],
              "correlationId": "\(correlation.uuidString)"
            }
            """.utf8
        )
        let unusedGenerator = IPCDescriptorInvocationCorrelationGenerator(UUIDv7.generate())
        let jsonPayload = try #require(String(data: payload, encoding: .utf8))

        let jsonInvocation = try parse(
            ["fixture.control", "--json", jsonPayload],
            correlationGenerator: unusedGenerator
        )
        let standardInputInvocation = try parse(
            ["fixture.control", "--stdin"],
            correlationGenerator: unusedGenerator,
            standardInput: payload
        )

        #expect(jsonInvocation.normalizedParameters == standardInputInvocation.normalizedParameters)
        #expect(
            try decodeIPCDescriptorInvocationParameters(
                IPCDescriptorInvocationToolingParameters.self, from: jsonInvocation.normalizedParameters.data)
                == IPCDescriptorInvocationToolingParameters(
                    retryCount: 4,
                    isEnabled: true,
                    displayName: "line one\nline two \u{96EA}",
                    displayMode: .compact,
                    tags: ["alpha", "\u{03B2}"],
                    correlationId: correlation
                )
        )
        #expect(unusedGenerator.invocationCount == 0)
    }

    @Test("object and array fields require JSON or stdin")
    func complexFieldsDoNotGainAnAdHocScalarSyntax() throws {
        let error = try captureIPCDescriptorInvocationError {
            try parse(
                [
                    "fixture.control",
                    "--retry-count", "2",
                    "--is-enabled", "true",
                    "--display-name", "complex",
                    "--tags", #"["one","two"]"#,
                ],
                correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(UUIDv7.generate())
            )
        }

        #expect(error.reason == .unsupportedScalarField)
        #expect(error.fieldPath == "$.tags")
        #expect(error.expected == "JSON or standard input for object and array fields")
    }

    @Test("unknown methods fields and invalid values return controlled corrections")
    func failuresDoNotEchoPrivateInput() throws {
        let privateMethod = "private.method.\u{1F512}"
        let privateField = "--private-field-\u{1F512}"
        let privateValue = "PRIVATE-VALUE-\u{1F512}"

        let unknownMethod = try captureIPCDescriptorInvocationError {
            try parse(
                [privateMethod],
                correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(UUIDv7.generate())
            )
        }
        let unknownField = try captureIPCDescriptorInvocationError {
            try parse(
                ["fixture.control", privateField, privateValue],
                correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(UUIDv7.generate())
            )
        }
        let invalidValue = try captureIPCDescriptorInvocationError {
            try parse(
                [
                    "fixture.control",
                    "--retry-count", privateValue,
                    "--is-enabled", "true",
                    "--display-name", "private",
                ],
                correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(UUIDv7.generate())
            )
        }

        #expect(unknownMethod.reason == .unknownMethod)
        #expect(unknownMethod.fieldPath == "$")
        #expect(unknownMethod.expected == "a declared method or model invocation")
        #expect(unknownField.reason == .unknownField)
        #expect(unknownField.fieldPath == "$")
        #expect(unknownField.expected == "a declared method option")
        #expect(invalidValue.reason == .invalidValue)
        #expect(invalidValue.fieldPath == "$.retryCount")
        #expect(invalidValue.expected == "integer")

        for controlledError in [unknownMethod, unknownField, invalidValue] {
            let renderedError = String(describing: controlledError)
            #expect(!renderedError.contains(privateMethod))
            #expect(!renderedError.contains(privateField))
            #expect(!renderedError.contains(privateValue))
        }
    }

    @Test("model vocabulary is projected only from descriptor metadata")
    func modelVocabularyBuildsSelectorsAndExactScalarArguments() throws {
        let messageCorrelation = UUIDv7.generate()
        let needsYouCorrelation = UUIDv7.generate()
        let doneCorrelation = UUIDv7.generate()
        let messageText = "first line\nsecond line \u{1F642}"
        let explanation = "Blocked on \u{30C7}\u{30FC}\u{30BF}\nNeed a decision."

        let message = try parse(
            ["message", messageText],
            correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(messageCorrelation)
        )
        let needsYou = try parse(
            ["needs-you", explanation],
            correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(needsYouCorrelation)
        )
        let done = try parse(
            ["done"],
            correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(doneCorrelation)
        )

        #expect(message.descriptor.metadata.name == "fixture.note")
        #expect(
            try decodeIPCDescriptorInvocationParameters(
                IPCDescriptorInvocationMessageParameters.self, from: message.normalizedParameters.data)
                == IPCDescriptorInvocationMessageParameters(
                    text: messageText, correlationId: messageCorrelation)
        )
        #expect(
            message.presentation
                == .model(
                    IPCModelInvocationPresentation(
                        variant: .message,
                        successReply: "Fixture message saved.",
                        queuedReply: "Fixture message queued.",
                        isOfflineEligible: true,
                        showsDetail: false
                    )
                )
        )
        #expect(
            try decodeIPCDescriptorInvocationParameters(
                IPCDescriptorInvocationReportParameters.self, from: needsYou.normalizedParameters.data)
                == IPCDescriptorInvocationReportParameters(
                    operation: .needsYou,
                    explanation: explanation,
                    correlationId: needsYouCorrelation
                )
        )
        #expect(needsYou.presentation.modelInvocation?.variant == .needsYou)
        #expect(needsYou.presentation.modelInvocation?.successReply == "Fixture help recorded.")
        #expect(needsYou.presentation.modelInvocation?.queuedReply == "Fixture report queued.")
        #expect(needsYou.presentation.modelInvocation?.isOfflineEligible == true)
        #expect(
            try decodeIPCDescriptorInvocationParameters(
                IPCDescriptorInvocationReportParameters.self, from: done.normalizedParameters.data)
                == IPCDescriptorInvocationReportParameters(
                    operation: .done,
                    explanation: nil,
                    correlationId: doneCorrelation
                )
        )
        #expect(done.presentation.modelInvocation?.variant == .done)
        #expect(done.presentation.modelInvocation?.successReply == "Fixture done recorded.")
        #expect(done.presentation.modelInvocation?.queuedReply == "Fixture report queued.")
        #expect(done.presentation.modelInvocation?.isOfflineEligible == true)
    }

    @Test("longest model prefix selects clear and clear is never offline eligible")
    func longestModelPrefixSelectsClear() throws {
        let correlation = UUIDv7.generate()

        let invocation = try parse(
            ["needs-you", "--clear"],
            correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(correlation)
        )

        #expect(
            try decodeIPCDescriptorInvocationParameters(
                IPCDescriptorInvocationReportParameters.self, from: invocation.normalizedParameters.data)
                == IPCDescriptorInvocationReportParameters(
                    operation: .clear,
                    explanation: nil,
                    correlationId: correlation
                )
        )
        #expect(
            invocation.presentation
                == .model(
                    IPCModelInvocationPresentation(
                        variant: .needsYouClear,
                        successReply: "Fixture help cleared.",
                        queuedReply: nil,
                        isOfflineEligible: false,
                        showsDetail: false
                    )
                )
        )
    }

    @Test("detail changes presentation while delimiter preserves flag-shaped model text")
    func detailAndDelimiterRemainPresentationSyntax() throws {
        let literalDetail = try parse(
            ["message", "--", "--detail"],
            correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(UUIDv7.generate())
        )
        let literalClear = try parse(
            ["needs-you", "--detail", "--", "--clear"],
            correlationGenerator: IPCDescriptorInvocationCorrelationGenerator(UUIDv7.generate())
        )

        #expect(
            try decodeIPCDescriptorInvocationParameters(
                IPCDescriptorInvocationMessageParameters.self, from: literalDetail.normalizedParameters.data
            ).text == "--detail")
        #expect(
            try decodeIPCDescriptorInvocationParameters(
                IPCDescriptorInvocationReportParameters.self, from: literalClear.normalizedParameters.data
            ).explanation
                == "--clear"
        )
        #expect(literalDetail.presentation.modelInvocation?.showsDetail == false)
        #expect(literalClear.presentation.modelInvocation?.variant == .needsYou)
        #expect(literalClear.presentation.modelInvocation?.showsDetail == true)
    }

    private func parse(
        _ arguments: [String],
        correlationGenerator: IPCDescriptorInvocationCorrelationGenerator,
        standardInput: Data? = nil
    ) throws -> IPCDescriptorInvocation {
        try IPCDescriptorInvocationParser.parse(
            arguments,
            descriptors: try fixtureDescriptors(),
            correlationIDGenerator: correlationGenerator.generate,
            standardInput: standardInput
        )
    }

    private func fixtureDescriptors() throws -> [IPCAnyMethodDescriptor] {
        [
            try IPCAnyMethodDescriptor(erasing: toolingDescriptor()),
            try IPCAnyMethodDescriptor(erasing: messageDescriptor()),
            try IPCAnyMethodDescriptor(erasing: reportDescriptor()),
        ]
    }

    private func toolingDescriptor() throws
        -> IPCMethodDescriptor<IPCDescriptorInvocationToolingParameters, IPCDescriptorInvocationFixtureResult>
    {
        try IPCMethodDescriptor(
            name: "fixture.control",
            description: "Exercise descriptor-derived scalar tooling invocation.",
            examples: [],
            exposure: .debugTesting,
            requiredPrivileges: [.debugUnsafe],
            dataScope: .unspecified,
            allowedTargetKinds: [],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .queryReader,
            principalAvailability: .authenticated,
            resultSemantics: .applied,
            documentedErrors: [],
            isMutating: true,
            correlationPolicy: .required
        )
    }

    private func messageDescriptor() throws
        -> IPCMethodDescriptor<IPCDescriptorInvocationMessageParameters, IPCDescriptorInvocationFixtureResult>
    {
        try IPCMethodDescriptor(
            name: "fixture.note",
            description: "Exercise a descriptor-projected exact message.",
            examples: [],
            exposure: .allChannels,
            requiredPrivileges: [.paneContextRead],
            dataScope: .paneContext,
            allowedTargetKinds: [.pane],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .queryReader,
            principalAvailability: .authenticated,
            resultSemantics: .durable,
            documentedErrors: [],
            isMutating: true,
            correlationPolicy: .required,
            offlineEligibility: .modelCallVariants([.message]),
            modelCalls: [
                .init(
                    variant: .message,
                    selectors: [],
                    scalarArguments: [
                        .init(
                            name: "text",
                            parameterField: "text",
                            description: "Exact private message text",
                            isRequired: true
                        )
                    ],
                    successReply: "Fixture message saved.",
                    queuedReply: "Fixture message queued."
                )
            ]
        )
    }

    private func reportDescriptor() throws
        -> IPCMethodDescriptor<IPCDescriptorInvocationReportParameters, IPCDescriptorInvocationFixtureResult>
    {
        try IPCMethodDescriptor(
            name: "fixture.status",
            description: "Exercise several descriptor-projected report variants.",
            examples: [],
            exposure: .allChannels,
            requiredPrivileges: [.paneContextRead],
            dataScope: .paneContext,
            allowedTargetKinds: [.pane],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .queryReader,
            principalAvailability: .authenticated,
            resultSemantics: .durable,
            documentedErrors: [],
            isMutating: true,
            correlationPolicy: .required,
            offlineEligibility: .modelCallVariants([.needsYou, .done]),
            modelCalls: [
                .init(
                    variant: .needsYou,
                    selectors: [.init(parameterField: "operation", equals: "needsYou")],
                    scalarArguments: [
                        .init(
                            name: "explanation",
                            parameterField: "explanation",
                            description: "Exact private explanation",
                            isRequired: true
                        )
                    ],
                    successReply: "Fixture help recorded.",
                    queuedReply: "Fixture report queued."
                ),
                .init(
                    variant: .needsYouClear,
                    selectors: [.init(parameterField: "operation", equals: "clear")],
                    scalarArguments: [],
                    successReply: "Fixture help cleared.",
                    queuedReply: nil
                ),
                .init(
                    variant: .done,
                    selectors: [.init(parameterField: "operation", equals: "done")],
                    scalarArguments: [],
                    successReply: "Fixture done recorded.",
                    queuedReply: "Fixture report queued."
                ),
            ]
        )
    }
}
