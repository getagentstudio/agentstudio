import Foundation

package enum IPCMethodDescriptorError: Error, Equatable, Sendable {
    case invalidMethodName
    case missingDescription
    case missingPrivilegeClass
    case invalidCommandIdentifier
    case invalidDocumentedError
    case duplicateDocumentedErrorReason
    case mutationRequiresCorrelation
    case invalidCorrelationField
    case parametersMustBeAnObjectForModelCalls
    case duplicateModelCallVariant
    case invalidModelCallMetadata
    case unknownModelParameterField(String)
    case invalidModelSelectorValue(String)
    case modelSelectorsMustMatchOneAlternative
    case invalidOfflineEligibility
    case agentEligibleMethodMustBeExposedOnAllChannels
}

package struct IPCMethodDescriptor<
    Parameters: Codable & Sendable,
    Result: Codable & Sendable
>: Sendable {
    package let name: String
    package let description: String
    package let contract: IPCMethodContract<Parameters, Result>
    package let examples: [IPCMethodExample<Parameters, Result>]
    package let exposure: IPCMethodExposure
    package let requiredPrivileges: Set<IPCPrivilegeClass>
    package let dataScope: IPCDataScope
    package let allowedTargetKinds: Set<IPCHandleKind>
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
    /// `nil` keeps the established Agent IPC v2 admission for pane agents.
    package let agentEligibility: IPCAgentEligibility?

    package init(
        name: String,
        description: String,
        examples: [IPCMethodExample<Parameters, Result>],
        exposure: IPCMethodExposure,
        requiredPrivileges: Set<IPCPrivilegeClass>,
        dataScope: IPCDataScope,
        allowedTargetKinds: Set<IPCHandleKind>,
        commandRelationship: IPCCommandRelationship,
        executionOwner: IPCExecutionOwner,
        principalAvailability: IPCPrincipalAvailability,
        resultSemantics: IPCResultSemantics,
        documentedErrors: [IPCMethodErrorCase],
        isMutating: Bool,
        correlationPolicy: IPCCorrelationPolicy,
        responseDelivery: IPCMethodResponseDelivery = .single,
        offlineEligibility: IPCMethodOfflineEligibility = .never,
        modelCalls: [IPCModelCallProjection] = [],
        agentEligibility: IPCAgentEligibility? = nil
    ) throws where Parameters: IPCSchemaProviding, Result: IPCSchemaProviding {
        try self.init(
            name: name,
            description: description,
            parameterSchema: Parameters.ipcSchema(),
            resultSchema: Result.ipcSchema(),
            examples: examples,
            exposure: exposure,
            requiredPrivileges: requiredPrivileges,
            dataScope: dataScope,
            allowedTargetKinds: allowedTargetKinds,
            commandRelationship: commandRelationship,
            executionOwner: executionOwner,
            principalAvailability: principalAvailability,
            resultSemantics: resultSemantics,
            documentedErrors: documentedErrors,
            isMutating: isMutating,
            correlationPolicy: correlationPolicy,
            responseDelivery: responseDelivery,
            offlineEligibility: offlineEligibility,
            modelCalls: modelCalls,
            agentEligibility: agentEligibility
        )
    }

    package init(
        name: String,
        description: String,
        parameterSchema: IPCJSONSchema,
        resultSchema: IPCJSONSchema,
        examples: [IPCMethodExample<Parameters, Result>],
        exposure: IPCMethodExposure,
        requiredPrivileges: Set<IPCPrivilegeClass>,
        dataScope: IPCDataScope,
        allowedTargetKinds: Set<IPCHandleKind>,
        commandRelationship: IPCCommandRelationship,
        executionOwner: IPCExecutionOwner,
        principalAvailability: IPCPrincipalAvailability,
        resultSemantics: IPCResultSemantics,
        documentedErrors: [IPCMethodErrorCase],
        isMutating: Bool,
        correlationPolicy: IPCCorrelationPolicy,
        responseDelivery: IPCMethodResponseDelivery = .single,
        offlineEligibility: IPCMethodOfflineEligibility = .never,
        modelCalls: [IPCModelCallProjection] = [],
        agentEligibility: IPCAgentEligibility? = nil
    ) throws {
        let contract = try IPCMethodContract<Parameters, Result>(
            parameterSchema: parameterSchema,
            resultSchema: resultSchema
        )
        try IPCMethodMetadataValidator.validate(
            IPCMethodMetadataValidationInput(
                name: name,
                description: description,
                parameterSchema: parameterSchema,
                requiredPrivileges: requiredPrivileges.sorted { $0.rawValue < $1.rawValue },
                allowedTargetKinds: allowedTargetKinds.sorted { $0.rawValue < $1.rawValue },
                commandRelationship: commandRelationship,
                documentedErrors: documentedErrors,
                isMutating: isMutating,
                correlationPolicy: correlationPolicy,
                offlineEligibility: offlineEligibility,
                modelCalls: modelCalls
            )
        )

        if agentEligibility?.requiresAllChannelExposure == true, exposure != .allChannels {
            throw IPCMethodDescriptorError.agentEligibleMethodMustBeExposedOnAllChannels
        }

        for example in examples {
            guard !example.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IPCMethodDescriptorError.invalidModelCallMetadata
            }
            try contract.validateExample(parameters: example.parameters, result: example.result)
        }

        self.name = name
        self.description = description
        self.contract = contract
        self.examples = examples
        self.exposure = exposure
        self.requiredPrivileges = requiredPrivileges
        self.dataScope = dataScope
        self.allowedTargetKinds = allowedTargetKinds
        self.commandRelationship = commandRelationship
        self.executionOwner = executionOwner
        self.principalAvailability = principalAvailability
        self.resultSemantics = resultSemantics
        self.documentedErrors = documentedErrors
        self.isMutating = isMutating
        self.correlationPolicy = correlationPolicy
        self.responseDelivery = responseDelivery
        self.offlineEligibility = offlineEligibility
        self.modelCalls = modelCalls
        self.agentEligibility = agentEligibility
    }

    package func decodeParameters(from data: Data) throws -> Parameters {
        try contract.decodeParameters(from: data)
    }

    package func encodeResult(_ result: Result) throws -> Data {
        try contract.encodeResult(result)
    }

    package var metadata: IPCMethodDescriptorMetadata<Parameters, Result> {
        .init(
            name: name,
            description: description,
            parameterSchema: contract.parameterSchema,
            resultSchema: contract.resultSchema,
            examples: examples,
            exposure: exposure,
            requiredPrivileges: requiredPrivileges.sorted { $0.rawValue < $1.rawValue },
            dataScope: dataScope,
            allowedTargetKinds: allowedTargetKinds.sorted { $0.rawValue < $1.rawValue },
            commandRelationship: commandRelationship,
            executionOwner: executionOwner,
            principalAvailability: principalAvailability,
            resultSemantics: resultSemantics,
            documentedErrors: documentedErrors,
            isMutating: isMutating,
            correlationPolicy: correlationPolicy,
            responseDelivery: responseDelivery,
            offlineEligibility: offlineEligibility,
            modelCalls: modelCalls,
            agentEligibility: agentEligibility
        )
    }

}
