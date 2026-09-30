import Foundation

package protocol IPCMethodDescriptorRepresentation: Sendable {
    var methodName: String { get }
    var erasedDescriptor: IPCAnyMethodDescriptor { get }
}

package struct IPCAnyMethodDescriptor: Sendable {
    package let metadata: IPCMethodCatalogEntry
    package let catalogEntrySchema: IPCJSONSchema
    private let parameterNormalizer: @Sendable (Data) throws -> IPCValidatedJSON
    private let resultNormalizer: @Sendable (Data) throws -> IPCValidatedJSON

    package init<Parameters, Result>(
        erasing descriptor: IPCMethodDescriptor<Parameters, Result>
    ) throws where Parameters: Codable & Sendable, Result: Codable & Sendable {
        let parameterSchema = descriptor.contract.parameterSchema
        let resultSchema = descriptor.contract.resultSchema
        // `IPCMethodDescriptor` validates each example when it is initialized.
        // Erasure projects those validated examples into the catalog wire form;
        // validating them again here repeats the same full-schema work.
        let examples = try descriptor.examples.map { example in
            let parameterData = try JSONEncoder().encode(example.parameters)
            let resultData = try JSONEncoder().encode(example.result)
            return try IPCMethodExampleDocument(
                description: example.description,
                parameters: parameterData,
                result: resultData
            )
        }
        metadata = IPCMethodCatalogEntry(
            name: descriptor.name,
            description: descriptor.description,
            parameterSchema: parameterSchema,
            resultSchema: resultSchema,
            examples: examples,
            exposure: descriptor.exposure,
            requiredPrivileges: descriptor.requiredPrivileges.sorted { $0.rawValue < $1.rawValue },
            dataScope: descriptor.dataScope,
            allowedTargetKinds: descriptor.allowedTargetKinds.sorted { $0.rawValue < $1.rawValue },
            commandRelationship: descriptor.commandRelationship,
            executionOwner: descriptor.executionOwner,
            principalAvailability: descriptor.principalAvailability,
            resultSemantics: descriptor.resultSemantics,
            documentedErrors: descriptor.documentedErrors,
            isMutating: descriptor.isMutating,
            correlationPolicy: descriptor.correlationPolicy,
            responseDelivery: descriptor.responseDelivery,
            offlineEligibility: descriptor.offlineEligibility,
            modelCalls: descriptor.modelCalls,
            agentEligibility: descriptor.agentEligibility
        )
        catalogEntrySchema = try IPCMethodCatalogEntry.schemaForExamples(
            methodName: descriptor.name,
            examples: descriptor.examples
        )
        parameterNormalizer = { data in try descriptor.contract.normalizedParameters(from: data) }
        resultNormalizer = { data in try descriptor.contract.normalizedResult(from: data) }
        _ = try catalogEntrySchema.decode(
            IPCMethodCatalogEntry.self,
            from: JSONEncoder().encode(metadata)
        )
    }

    package func normalizeResult(_ data: Data) throws -> IPCValidatedJSON {
        try resultNormalizer(data)
    }

    package func normalizeParameters(_ data: Data) throws -> IPCValidatedJSON {
        try parameterNormalizer(data)
    }
}

/// Keeps a typed method descriptor paired with the validated catalog
/// representation produced from it, so composition consumers can reuse both
/// without repeating schema validation during registration.
package struct IPCMethodDescriptorRepresentations<
    Parameters: Codable & Sendable,
    Result: Codable & Sendable
>: IPCMethodDescriptorRepresentation {
    package let typedDescriptor: IPCMethodDescriptor<Parameters, Result>
    package let erasedDescriptor: IPCAnyMethodDescriptor

    package var methodName: String { typedDescriptor.name }

    package init(typedDescriptor: IPCMethodDescriptor<Parameters, Result>) throws {
        self.typedDescriptor = typedDescriptor
        erasedDescriptor = try IPCAnyMethodDescriptor(erasing: typedDescriptor)
    }
}

package enum IPCMethodDescriptorRepresentationLookupError: Error, Equatable, Sendable {
    case missingMethod(String)
    case descriptorTypeMismatch(String)
}
