import Foundation

package enum IPCMethodCatalogDecoder {
    package static func decode(_ data: Data) throws -> IPCMethodCatalogResult {
        let schemaContext = IPCMethodCatalogSchemaContext()
        let provisional = try decodeProvisional(data, schemaContext: schemaContext)
        try validateCatalogIdentity(provisional)
        let entrySchemas = try provisional.methods.enumerated().map { index, entry in
            try IPCMethodCatalogEntry.schemaForReceivedEntry(
                entry,
                validatedSchemas: schemaContext.validatedSchemas(forMethodAt: index)
            )
        }
        let catalogSchema = try IPCMethodCatalogResult.schema(
            compatibility: .current,
            methodSchemas: entrySchemas
        )
        let validatedCatalogSchema = try IPCValidatedJSONSchema(schema: catalogSchema)
        let normalized = try validatedCatalogSchema.normalize(
            data,
            schemaDocumentValuesByPath: schemaContext.schemaDocumentsByCatalogPath()
        )
        let decoded = try decodeProvisional(normalized, schemaContext: schemaContext)
        guard decoded == provisional else {
            throw failure(
                .decodingMismatch,
                path: "$",
                expected: "the validated typed method catalog"
            )
        }
        return decoded
    }

    private static func decodeProvisional(
        _ data: Data,
        schemaContext: IPCMethodCatalogSchemaContext
    ) throws -> IPCMethodCatalogResult {
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[IPCMethodCatalogSchemaContext.userInfoKey] = schemaContext
            return try decoder.decode(IPCMethodCatalogResult.self, from: data)
        } catch let error as IPCSchemaValidationError {
            throw error
        } catch {
            throw failure(
                .decodingMismatch,
                path: "$",
                expected: "a complete typed method catalog"
            )
        }
    }

    private static func validateCatalogIdentity(
        _ catalog: IPCMethodCatalogResult
    ) throws {
        guard catalog.compatibility == .current else {
            throw failure(
                .invalidValue,
                path: "$.compatibility",
                expected: "the current protocol and catalog compatibility identity"
            )
        }
        let methodNames = catalog.methods.map(\.name)
        guard Set(methodNames).count == methodNames.count else {
            throw failure(
                .invalidValue,
                path: "$.methods",
                expected: "unique method names"
            )
        }
        guard methodNames == methodNames.sorted() else {
            throw failure(
                .invalidValue,
                path: "$.methods",
                expected: "method names in ascending order"
            )
        }
        guard methodNames.filter({ $0 == "system.capabilities" }).count == 1 else {
            throw failure(
                .invalidValue,
                path: "$.methods",
                expected: "exactly one system capabilities method"
            )
        }
    }

    private static func failure(
        _ reason: IPCSchemaValidationError.Reason,
        path: String,
        expected: String
    ) -> IPCSchemaValidationError {
        IPCSchemaValidationError(
            fieldPath: path,
            reason: reason,
            expected: expected
        )
    }
}

/// Mutated only by one synchronous `JSONDecoder.decode` call and never shared
/// across tasks; unchecked sendability satisfies JSONDecoder's userInfo value.
final class IPCMethodCatalogSchemaContext: @unchecked Sendable {
    static let userInfoKey = CodingUserInfoKey(rawValue: "AgentStudio.IPCMethodCatalogSchemaContext")!

    private enum SchemaField: String, Hashable {
        case parameterSchema
        case resultSchema
    }

    private struct SchemaKey: Hashable {
        let methodIndex: Int
        let field: SchemaField

        init(methodIndex: Int, field: SchemaField) {
            self.methodIndex = methodIndex
            self.field = field
        }

        init?(codingPath: [any CodingKey]) {
            guard let methodsIndex = codingPath.firstIndex(where: { $0.stringValue == "methods" }),
                methodsIndex + 2 < codingPath.count,
                let methodIndex = codingPath[methodsIndex + 1].intValue,
                let field = SchemaField(rawValue: codingPath[methodsIndex + 2].stringValue)
            else {
                return nil
            }
            self.methodIndex = methodIndex
            self.field = field
        }

        var catalogPath: String {
            "$.methods[\(methodIndex)].\(field.rawValue)"
        }
    }

    private var validatedSchemas: [SchemaKey: IPCValidatedJSONSchema] = [:]

    func capture(_ validatedSchema: IPCValidatedJSONSchema, codingPath: [any CodingKey]) {
        guard let key = SchemaKey(codingPath: codingPath) else { return }
        validatedSchemas[key] = validatedSchema
    }

    func cachedSchema(for codingPath: [any CodingKey]) -> IPCJSONSchema? {
        guard let key = SchemaKey(codingPath: codingPath) else { return nil }
        return validatedSchemas[key]?.schema
    }

    func validatedSchemas(forMethodAt index: Int) throws -> IPCValidatedMethodCatalogSchemas {
        guard let parameterSchema = validatedSchemas[SchemaKey(methodIndex: index, field: .parameterSchema)],
            let resultSchema = validatedSchemas[SchemaKey(methodIndex: index, field: .resultSchema)]
        else {
            throw missingValidatedMethodSchemas()
        }
        return IPCValidatedMethodCatalogSchemas(
            parameterSchema: parameterSchema,
            resultSchema: resultSchema
        )
    }

    func schemaDocumentsByCatalogPath() throws -> [String: IPCSchemaValue] {
        var documents: [String: IPCSchemaValue] = [:]
        for key in validatedSchemas.keys {
            guard let validatedSchema = validatedSchemas[key] else {
                throw missingValidatedMethodSchemas()
            }
            documents[key.catalogPath] = validatedSchema.documentValue
        }
        return documents
    }

    private func missingValidatedMethodSchemas() -> IPCSchemaValidationError {
        IPCSchemaValidationError(
            fieldPath: "$.methods",
            reason: .invalidDefinition,
            expected: "a validated parameter and result schema for every catalog entry"
        )
    }
}
