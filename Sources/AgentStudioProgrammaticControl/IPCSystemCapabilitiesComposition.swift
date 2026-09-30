import Foundation

package enum IPCSystemCapabilitiesCompositionError: Error, Equatable, Sendable {
    case incompatibleIdentity
    case duplicateMethodName(String)
    case capabilitiesAlreadyPresent
    case invalidIllustrativeDescriptor
    case illustrativeDescriptorMissing
}

package struct IPCSystemCapabilitiesComposition: Sendable {
    package let descriptorRepresentations: IPCMethodDescriptorRepresentations<IPCEmptyParams, IPCMethodCatalogResult>
    package let encodedResult: Data
    package let result: IPCMethodCatalogResult

    package var descriptor: IPCMethodDescriptor<IPCEmptyParams, IPCMethodCatalogResult> {
        descriptorRepresentations.typedDescriptor
    }

    package var erasedDescriptor: IPCAnyMethodDescriptor {
        descriptorRepresentations.erasedDescriptor
    }
}

package enum IPCSystemCapabilitiesDescriptorFactory {
    package static func compose(
        compatibility: IPCProtocolCatalogCompatibility,
        availableDescriptors: [IPCAnyMethodDescriptor],
        illustrativeDescriptor: IPCAnyMethodDescriptor,
        recognizedUnexposedMethods: [IPCRecognizedUnexposedName] = []
    ) throws -> IPCSystemCapabilitiesComposition {
        guard compatibility == .current else {
            throw IPCSystemCapabilitiesCompositionError.incompatibleIdentity
        }
        try validateAvailableDescriptors(
            availableDescriptors,
            illustrativeDescriptor: illustrativeDescriptor
        )
        let sortedAvailableDescriptors = availableDescriptors.sorted {
            $0.metadata.name < $1.metadata.name
        }

        let illustrativeExample = IPCMethodExample(
            description: "Catalog containing the runtime identity method",
            parameters: IPCEmptyParams(),
            result: IPCMethodCatalogResult(
                compatibility: compatibility,
                methods: [illustrativeDescriptor.metadata]
            )
        )
        let selfEntrySchema = try IPCMethodCatalogEntry.schemaForExamples(
            methodName: "system.capabilities",
            examples: [illustrativeExample]
        )
        let resultSchema = try IPCMethodCatalogResult.schema(
            compatibility: compatibility,
            methodSchemas: sortedAvailableDescriptors.map(\.catalogEntrySchema) + [selfEntrySchema]
        )
        let descriptor = try IPCMethodDescriptor(
            name: "system.capabilities",
            description: "Return compatibility identity and the complete available typed method catalog.",
            parameterSchema: try IPCEmptyParams.ipcSchema(),
            resultSchema: resultSchema,
            examples: [illustrativeExample],
            exposure: .allChannels,
            requiredPrivileges: [.systemRead],
            dataScope: .unspecified,
            allowedTargetKinds: [],
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .queryReader,
            principalAvailability: .authenticated,
            resultSemantics: .applied,
            documentedErrors: [
                .init(
                    reason: "unsupportedVersion",
                    description: "The client and runtime compatibility identities do not match."
                )
            ],
            isMutating: false,
            correlationPolicy: .notAccepted,
            agentEligibility: .anyTarget
        )
        let descriptorRepresentations = try IPCMethodDescriptorRepresentations(typedDescriptor: descriptor)
        let erasedDescriptor = descriptorRepresentations.erasedDescriptor
        let result = IPCMethodCatalogResult(
            compatibility: compatibility,
            methods: (sortedAvailableDescriptors.map(\.metadata) + [erasedDescriptor.metadata])
                .sorted { $0.name < $1.name },
            recognizedUnexposedMethods: recognizedUnexposedMethods.sorted { $0.name < $1.name }
        )

        // Keep the full result validation and exact encoded bytes from this
        // composed catalog. The type-erased descriptor already validates its
        // metadata against catalogEntrySchema during erasure.
        let encodedResult = try descriptorRepresentations.typedDescriptor.encodeResult(result)
        return IPCSystemCapabilitiesComposition(
            descriptorRepresentations: descriptorRepresentations,
            encodedResult: encodedResult,
            result: result
        )
    }

    private static func validateAvailableDescriptors(
        _ availableDescriptors: [IPCAnyMethodDescriptor],
        illustrativeDescriptor: IPCAnyMethodDescriptor
    ) throws {
        var observedNames: Set<String> = []
        for descriptor in availableDescriptors {
            guard descriptor.metadata.name != "system.capabilities" else {
                throw IPCSystemCapabilitiesCompositionError.capabilitiesAlreadyPresent
            }
            guard observedNames.insert(descriptor.metadata.name).inserted else {
                throw IPCSystemCapabilitiesCompositionError.duplicateMethodName(
                    descriptor.metadata.name
                )
            }
        }
        guard illustrativeDescriptor.metadata.name == "system.ping" else {
            throw IPCSystemCapabilitiesCompositionError.invalidIllustrativeDescriptor
        }
        guard
            availableDescriptors.filter({ $0.metadata == illustrativeDescriptor.metadata }).count == 1
        else {
            throw IPCSystemCapabilitiesCompositionError.illustrativeDescriptorMissing
        }
    }
}
