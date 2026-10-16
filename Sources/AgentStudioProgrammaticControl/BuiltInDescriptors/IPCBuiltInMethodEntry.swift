import Foundation

/// A typed recipe stores display metadata now and constructs its contract only when called.
struct IPCBuiltInMethodEntry<Parameters: IPCSchemaProviding, Result: Codable & Sendable>: Sendable {
    let name: String
    let summary: String
    let modelCalls: [IPCModelCallProjection]
    let correlationPolicy: IPCCorrelationPolicy
    let agentEligibility: IPCAgentEligibility?
    private let parameterSchemaFactory: @Sendable () throws -> IPCJSONSchema
    private let descriptorFactory:
        @Sendable (String, String, [IPCModelCallProjection], IPCAgentEligibility?, IPCBuiltInMethodCatalogInputs) throws
            -> IPCMethodDescriptor<Parameters, Result>

    init(
        name: String, summary: String, modelCalls: [IPCModelCallProjection],
        correlationPolicy: IPCCorrelationPolicy,
        agentEligibility: IPCAgentEligibility?,
        parameterSchema: @escaping @Sendable () throws -> IPCJSONSchema = { try Parameters.ipcSchema() },
        makeDescriptor:
            @escaping @Sendable (
                String, String, [IPCModelCallProjection], IPCAgentEligibility?, IPCBuiltInMethodCatalogInputs
            ) throws
            -> IPCMethodDescriptor<Parameters, Result>
    ) {
        self.name = name
        self.summary = summary
        self.modelCalls = modelCalls
        self.correlationPolicy = correlationPolicy
        self.agentEligibility = agentEligibility
        parameterSchemaFactory = parameterSchema
        descriptorFactory = makeDescriptor
    }

    func makeDescriptor(inputs: IPCBuiltInMethodCatalogInputs) throws -> IPCMethodDescriptor<Parameters, Result> {
        try descriptorFactory(name, summary, modelCalls, agentEligibility, inputs)
    }

    var erased: IPCBuiltInMethodIndexEntry {
        IPCBuiltInMethodIndexEntry(
            name: name, summary: summary, modelCalls: modelCalls, correlationPolicy: correlationPolicy,
            agentEligibility: agentEligibility,
            parameterSchema: parameterSchemaFactory,
            makeRepresentation: { inputs in
                try IPCMethodDescriptorRepresentations(typedDescriptor: self.makeDescriptor(inputs: inputs))
            })
    }

    func typedDescriptor(in representations: [String: any IPCMethodDescriptorRepresentation]) throws
        -> IPCMethodDescriptor<Parameters, Result>
    {
        guard let representation = representations[name] else {
            throw IPCMethodDescriptorRepresentationLookupError.missingMethod(name)
        }
        guard let typed = representation as? IPCMethodDescriptorRepresentations<Parameters, Result> else {
            throw IPCMethodDescriptorRepresentationLookupError.descriptorTypeMismatch(name)
        }
        return typed.typedDescriptor
    }
}

/// Erases the recipe's generic arguments, preserving its deferred factory boundary.
package struct IPCBuiltInMethodIndexEntry: Sendable {
    package let name: String
    package let summary: String
    package let modelCalls: [IPCModelCallProjection]
    package let correlationPolicy: IPCCorrelationPolicy
    /// Nil retains the established bound-pane privilege baseline.
    package let agentEligibility: IPCAgentEligibility?
    private let parameterSchemaFactory: @Sendable () throws -> IPCJSONSchema
    private let representationFactory:
        @Sendable (IPCBuiltInMethodCatalogInputs) throws -> any IPCMethodDescriptorRepresentation

    package init(
        name: String, summary: String, modelCalls: [IPCModelCallProjection],
        correlationPolicy: IPCCorrelationPolicy,
        agentEligibility: IPCAgentEligibility?,
        parameterSchema: @escaping @Sendable () throws -> IPCJSONSchema,
        makeRepresentation:
            @escaping @Sendable (IPCBuiltInMethodCatalogInputs) throws -> any IPCMethodDescriptorRepresentation
    ) {
        self.name = name
        self.summary = summary
        self.modelCalls = modelCalls
        self.correlationPolicy = correlationPolicy
        self.agentEligibility = agentEligibility
        parameterSchemaFactory = parameterSchema
        representationFactory = makeRepresentation
    }

    package func parameterSchema() throws -> IPCJSONSchema { try parameterSchemaFactory() }

    package func makeRepresentation(inputs: IPCBuiltInMethodCatalogInputs) throws
        -> any IPCMethodDescriptorRepresentation
    {
        try representationFactory(inputs)
    }
}
