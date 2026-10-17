import Foundation

struct IPCMethodMetadataValidationInput {
    let name: String
    let description: String
    let parameterSchema: IPCJSONSchema
    let requiredPrivileges: [IPCPrivilegeClass]
    let allowedTargetKinds: [IPCHandleKind]
    let commandRelationship: IPCCommandRelationship
    let documentedErrors: [IPCMethodErrorCase]
    let isMutating: Bool
    let correlationPolicy: IPCCorrelationPolicy
    let offlineEligibility: IPCMethodOfflineEligibility
    let modelCalls: [IPCModelCallProjection]
}

enum IPCMethodMetadataValidator {
    static func validate(_ input: IPCMethodMetadataValidationInput) throws {
        try validateMethodName(input.name)
        guard !input.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IPCMethodDescriptorError.missingDescription
        }
        guard !input.requiredPrivileges.isEmpty else {
            throw IPCMethodDescriptorError.missingPrivilegeClass
        }
        guard input.requiredPrivileges == sortedUnique(input.requiredPrivileges) else {
            throw IPCMethodDescriptorError.missingPrivilegeClass
        }
        guard input.allowedTargetKinds == sortedUnique(input.allowedTargetKinds) else {
            throw IPCMethodDescriptorError.invalidModelCallMetadata
        }
        try validateCommandRelationship(input.commandRelationship, parameterSchema: input.parameterSchema)
        try validateDocumentedErrors(input.documentedErrors)
        if input.isMutating {
            guard input.correlationPolicy == .required else {
                throw IPCMethodDescriptorError.mutationRequiresCorrelation
            }
            try validateRequiredCorrelationField(in: input.parameterSchema)
        }
        try validateModelCalls(input.modelCalls, parameterSchema: input.parameterSchema)
        try validateOfflineEligibility(input.offlineEligibility, methodName: input.name)
    }

    private static func sortedUnique<RawValue>(
        _ values: [RawValue]
    ) -> [RawValue] where RawValue: RawRepresentable & Hashable, RawValue.RawValue == String {
        Array(Set(values)).sorted { $0.rawValue < $1.rawValue }
    }

    private static func validateMethodName(_ name: String) throws {
        let reservedBackendPrefix = ["z", "m", "x"].joined() + "."
        guard name.contains("."), !name.hasPrefix("."), !name.hasSuffix("."),
            !name.hasPrefix(reservedBackendPrefix)
        else {
            throw IPCMethodDescriptorError.invalidMethodName
        }
    }

    private static func validateCommandRelationship(
        _ relationship: IPCCommandRelationship,
        parameterSchema: IPCJSONSchema
    ) throws {
        switch relationship {
        case .noInteractiveIdentity:
            return
        case .appCommand(let identifier):
            guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IPCMethodDescriptorError.invalidCommandIdentifier
            }
        case .appCommandParameter(let field):
            let alternatives = try rootObjectAlternatives(
                in: parameterSchema, invalidShapeError: .invalidCommandIdentifier)
            guard !field.isEmpty,
                alternatives.allSatisfy({ fields in
                    guard let definition = fields.first(where: { $0.name == field }),
                        case .required = definition.presence, case .string = definition.schema
                    else { return false }
                    return true
                })
            else { throw IPCMethodDescriptorError.invalidCommandIdentifier }
        }
    }

    private static func validateDocumentedErrors(
        _ documentedErrors: [IPCMethodErrorCase]
    ) throws {
        for errorCase in documentedErrors {
            guard !errorCase.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !errorCase.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw IPCMethodDescriptorError.invalidDocumentedError
            }
        }
        guard Set(documentedErrors.map(\.reason)).count == documentedErrors.count else {
            throw IPCMethodDescriptorError.duplicateDocumentedErrorReason
        }
    }

    private static func validateRequiredCorrelationField(
        in parameterSchema: IPCJSONSchema
    ) throws {
        let alternatives = try rootObjectAlternatives(
            in: parameterSchema,
            invalidShapeError: .invalidCorrelationField
        )
        for fields in alternatives {
            guard
                let correlationField = fields.first(where: { $0.name == "correlationId" }),
                case .required = correlationField.presence,
                correlationField.schema == IPCSchemaScalars.uuid
            else {
                throw IPCMethodDescriptorError.invalidCorrelationField
            }
        }
    }

    private static func validateModelCalls(
        _ modelCalls: [IPCModelCallProjection],
        parameterSchema: IPCJSONSchema
    ) throws {
        guard Set(modelCalls.map(\.variant)).count == modelCalls.count else {
            throw IPCMethodDescriptorError.duplicateModelCallVariant
        }
        guard !modelCalls.isEmpty else { return }
        let alternatives = try rootObjectAlternatives(
            in: parameterSchema,
            invalidShapeError: .parametersMustBeAnObjectForModelCalls
        )

        for modelCall in modelCalls {
            guard !modelCall.successReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                Set(modelCall.selectors.map(\.parameterField)).count == modelCall.selectors.count,
                Set(modelCall.scalarArguments.map(\.name)).count == modelCall.scalarArguments.count,
                Set(modelCall.scalarArguments.map(\.parameterField)).count == modelCall.scalarArguments.count
            else {
                throw IPCMethodDescriptorError.invalidModelCallMetadata
            }
            for selector in modelCall.selectors {
                let candidateFields = alternatives.compactMap { fields in
                    fields.first(where: { $0.name == selector.parameterField })
                }
                guard !candidateFields.isEmpty else {
                    throw IPCMethodDescriptorError.unknownModelParameterField(selector.parameterField)
                }
                guard
                    candidateFields.contains(where: { field in
                        (try? field.schema.normalize(JSONEncoder().encode(selector.equals))) != nil
                    })
                else {
                    throw IPCMethodDescriptorError.invalidModelSelectorValue(selector.parameterField)
                }
            }
            let matchingAlternatives = alternatives.filter { fields in
                let fieldsByName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
                return modelCall.selectors.allSatisfy { selector in
                    guard let field = fieldsByName[selector.parameterField] else { return false }
                    return (try? field.schema.normalize(JSONEncoder().encode(selector.equals))) != nil
                }
            }
            guard matchingAlternatives.count == 1, let selectedFields = matchingAlternatives.first else {
                throw IPCMethodDescriptorError.modelSelectorsMustMatchOneAlternative
            }
            let selectedFieldsByName = Dictionary(
                uniqueKeysWithValues: selectedFields.map { ($0.name, $0) }
            )
            for argument in modelCall.scalarArguments {
                guard !argument.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !argument.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw IPCMethodDescriptorError.invalidModelCallMetadata
                }
                guard selectedFieldsByName[argument.parameterField] != nil else {
                    throw IPCMethodDescriptorError.unknownModelParameterField(argument.parameterField)
                }
            }
        }
    }

    private static func rootObjectAlternatives(
        in schema: IPCJSONSchema,
        invalidShapeError: IPCMethodDescriptorError
    ) throws -> [[IPCObjectField]] {
        switch schema {
        case .object(let fields):
            return [fields]
        case .oneOf(let schemas):
            return try schemas.map { alternative in
                guard case .object(let fields) = alternative else { throw invalidShapeError }
                return fields
            }
        case .dictionary, .array, .string, .integer, .number, .boolean, .booleanConstant, .literalValue, .null,
            .schemaDocument:
            throw invalidShapeError
        }
    }

    private static func validateOfflineEligibility(_ eligibility: IPCMethodOfflineEligibility, methodName: String)
        throws
    {
        guard eligibility != .noticeOnly || methodName == "pane.message.send" else {
            throw IPCMethodDescriptorError.invalidOfflineEligibility
        }
    }
}
