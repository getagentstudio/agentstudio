import Foundation
import Testing

@testable import AgentStudioProgrammaticControl

@Suite("IPC typed JSON schema")
struct IPCJSONSchemaTests {
    @Test("every typed schema kind round-trips through its document representation")
    func everySchemaKindRoundTripsThroughItsDocument() throws {
        let defaultedObject = IPCJSONSchema.object(fields: [
            .init(
                name: "priority",
                description: "Default priority",
                schema: .integer(minimum: 1, maximum: 3),
                presence: try .defaulted(2)
            )
        ])
        let schemas: [IPCJSONSchema] = [
            .object(fields: [.init(name: "name", description: "Name", schema: .string())]),
            defaultedObject,
            .dictionary(values: .integer(minimum: 0, maximum: 10)),
            .array(items: .string(pattern: "^[a-z]+$"), minimumCount: 1, maximumCount: 3),
            .string(allowedValues: ["small", "large"], pattern: "^(small|large)$"),
            .integer(minimum: -1, maximum: 1),
            .number(minimum: 0.5, maximum: 1.5),
            .boolean,
            .booleanConstant(true),
            try IPCJSONSchema.literal("fixed"),
            .null,
            .oneOf([.array(items: .integer()), .null]),
            .schemaDocument,
        ]

        for schema in schemas {
            let document = try schema.jsonSchemaData()
            let decoded = try JSONDecoder().decode(IPCJSONSchema.self, from: document)
            #expect(decoded == schema)
        }
    }

    @Test("object field order survives discovery without hiding contract differences")
    func objectFieldOrderIsNotContractMeaning() throws {
        let title = IPCObjectField(name: "title", description: "Title", schema: .string())
        let count = IPCObjectField(name: "count", description: "Count", schema: .integer(minimum: 1))
        let schema = IPCJSONSchema.object(fields: [title, count])
        #expect(schema == .object(fields: [count, title]))
        #expect(try JSONDecoder().decode(IPCJSONSchema.self, from: schema.jsonSchemaData()) == schema)
        #expect(schema != .object(fields: [title]))
        #expect(
            schema
                != .object(fields: [title, .init(name: "count", description: "Count", schema: .integer(minimum: 2))]))
        #expect(
            schema != .object(fields: [title, .optional("count", description: "Count", schema: .integer(minimum: 1))]))
    }

    @Test("boolean discriminators enforce their literal value in discovery and admission")
    func booleanDiscriminatorsUseLiteralValues() throws {
        for expected in [true, false] {
            let schema = IPCJSONSchema.booleanConstant(expected)
            _ = try schema.normalize(JSONEncoder().encode(expected))
            #expect(throws: IPCSchemaValidationError.self) {
                try schema.normalize(JSONEncoder().encode(!expected))
            }
            let discovered = try JSONDecoder().decode(IPCJSONSchema.self, from: schema.jsonSchemaData())
            #expect(discovered == schema)
            #expect(throws: IPCSchemaValidationError.self) {
                try discovered.normalize(Data("null".utf8))
            }
        }
    }

    @Test("identifier patterns are advertised and enforced before typed decoding")
    func identifierPatternsMatchDiscovery() throws {
        let schema = IPCJSONSchema.string(pattern: "^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")
        let identifier = String(repeating: "a", count: 40)
        _ = try schema.normalize(JSONEncoder().encode(identifier))
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(JSONEncoder().encode(String(repeating: "a", count: 41)))
        }
        let discovered = try JSONDecoder().decode(IPCJSONSchema.self, from: schema.jsonSchemaData())
        #expect(throws: IPCSchemaValidationError.self) {
            try discovered.normalize(JSONEncoder().encode(String(repeating: "z", count: 40)))
        }
    }

    @Test("typed method contracts reject fields that Codable would silently ignore")
    func typedContractRejectsIgnoredFields() throws {
        let contract = try IPCMethodContract<SchemaTextOnlyParameters, SchemaTextOnlyParameters>(
            parameterSchema: messageSchema(),
            resultSchema: .object(fields: [
                .init(name: "text", description: "Exact response text", schema: .string())
            ])
        )

        do {
            _ = try contract.decodeParameters(from: Data(#"{"text":"hello","priority":2}"#.utf8))
            Issue.record("A schema field was ignored by the Swift parameter type")
        } catch let failure as IPCSchemaValidationError {
            #expect(failure.fieldPath == "$.priority")
            #expect(failure.reason == .decodingMismatch)
        }
    }

    @Test("typed method examples and result encoding use the declared contract")
    func typedExamplesUseDeclaredContract() throws {
        let contract = try IPCMethodContract<SchemaMessageParameters, SchemaTextOnlyParameters>(
            parameterSchema: messageSchema(),
            resultSchema: .object(fields: [
                .init(name: "text", description: "Exact response text", schema: .string())
            ])
        )
        let parameters = SchemaMessageParameters(text: "hello", priority: 2, urgent: true)
        try contract.validateExample(parameters: parameters, result: .init(text: "saved"))
        let result = try contract.encodeResult(.init(text: "saved"))
        #expect(try JSONDecoder().decode(SchemaTextOnlyParameters.self, from: result).text == "saved")
    }

    @Test("discovered schemas retain defaults and validation when read by a client")
    func discoveredSchemaRoundTripPreservesBehavior() throws {
        let schema = try messageSchema()
        let discovered = try JSONDecoder().decode(IPCJSONSchema.self, from: schema.jsonSchemaData())
        let input = Data(#"{"text":"hello"}"#.utf8)
        #expect(try discovered.normalize(input) == schema.normalize(input))
        #expect(throws: IPCSchemaValidationError.self) {
            try discovered.normalize(Data(#"{"text":"hello","priority":4}"#.utf8))
        }
    }

    @Test("dictionary entries have typed values without echoing caller-owned keys")
    func dictionaryEntriesHaveTypedValues() throws {
        let schema = IPCJSONSchema.dictionary(values: .integer(minimum: 0))
        let decoded = try schema.decode([String: Int].self, from: Data(#"{"count":3}"#.utf8))
        #expect(decoded == ["count": 3])
        do {
            _ = try schema.normalize(Data(#"{"private caller key":"wrong type"}"#.utf8))
            Issue.record("Expected a typed dictionary error")
        } catch let failure as IPCSchemaValidationError {
            #expect(failure.fieldPath == "$.*")
            #expect(failure.reason == .wrongType)
        }
    }

    @Test("declared defaults are applied by the same schema that discovery exposes")
    func declaredDefaultsMatchDecoding() throws {
        let schema = try messageSchema()

        let parameters = try schema.decode(
            SchemaMessageParameters.self,
            from: Data(#"{"text":"hello"}"#.utf8)
        )

        #expect(parameters == SchemaMessageParameters(text: "hello", priority: 1, urgent: false))
        let projection = try JSONSerialization.jsonObject(with: schema.jsonSchemaData()) as? [String: Any]
        let properties = projection?["properties"] as? [String: [String: Any]]
        #expect(properties?["priority"]?["default"] as? Int == 1)
        #expect(properties?["urgent"]?["default"] as? Bool == false)
        #expect(projection?["required"] as? [String] == ["text"])
        #expect(projection?["additionalProperties"] as? Bool == false)
    }

    @Test("field errors identify the correction without echoing private input")
    func invalidInputDoesNotEnterCorrectionData() throws {
        let schema = try messageSchema()

        do {
            _ = try schema.decode(
                SchemaMessageParameters.self,
                from: Data(#"{"text":"private message","priority":"private value"}"#.utf8)
            )
            Issue.record("Expected an integer correction")
        } catch let failure as IPCSchemaValidationError {
            #expect(failure.fieldPath == "$.priority")
            #expect(failure.reason == .wrongType)
            let encodedCorrection = try JSONEncoder().encode(failure)
            let correction = try #require(String(bytes: encodedCorrection, encoding: .utf8))
            #expect(!correction.contains("private message"))
            #expect(!correction.contains("private value"))
        }
    }

    @Test("integers reject booleans, fractional values and out-of-range values")
    func scalarKindsAndBoundsAreEnforced() throws {
        let schema = try messageSchema()
        for invalidPriority in ["true", "1.5", "0", "4"] {
            #expect(throws: IPCSchemaValidationError.self) {
                try schema.normalize(Data("{\"text\":\"hello\",\"priority\":\(invalidPriority)}".utf8))
            }
        }
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(Data(#"{"text":"hello","urgent":1}"#.utf8))
        }
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(Data(#"{"text":"hello","extra":"ignored?"}"#.utf8))
        }
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(Data(#"{"priority":1}"#.utf8))
        }
    }

    @Test("typed alternatives keep variant fields separate")
    func alternativesRejectMixedVariants() throws {
        let schema = IPCJSONSchema.oneOf([
            .object(fields: [
                .init(name: "kind", description: "Operation", schema: .string(allowedValues: ["message"])),
                .init(name: "text", description: "Private message", schema: .string()),
            ]),
            .object(fields: [
                .init(name: "kind", description: "Operation", schema: .string(allowedValues: ["done"]))
            ]),
        ])

        _ = try schema.normalize(Data(#"{"kind":"message","text":"exact\ntext"}"#.utf8))
        _ = try schema.normalize(Data(#"{"kind":"done"}"#.utf8))
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(Data(#"{"kind":"done","text":"not a done field"}"#.utf8))
        }
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(Data(#"{"kind":"future"}"#.utf8))
        }
    }

    @Test("prepared literal discriminators match try-all normalization and failures")
    func preparedLiteralDiscriminatorsMatchTryAllNormalization() throws {
        let schema = IPCJSONSchema.oneOf([
            .object(fields: [
                .init(name: "kind", description: "Operation", schema: .string(allowedValues: ["message"])),
                .init(name: "text", description: "Message text", schema: .string(minimumLength: 1)),
                .init(
                    name: "priority",
                    description: "Message priority",
                    schema: .integer(minimum: 1, maximum: 3),
                    presence: try .defaulted(1)
                ),
            ]),
            .object(fields: [
                .init(name: "kind", description: "Operation", schema: try IPCJSONSchema.literal("done")),
                .init(name: "completed", description: "Completion state", schema: .booleanConstant(true)),
            ]),
            .object(fields: [
                .init(name: "kind", description: "Operation", schema: .booleanConstant(true)),
                .init(name: "enabled", description: "Enabled state", schema: .boolean),
            ]),
        ])
        let preparedSchema = try IPCValidatedJSONSchema(schema: schema)
        let inputs = [
            #"{"kind":"message","text":"hello"}"#,
            #"{"kind":"done","completed":true}"#,
            #"{"kind":true,"enabled":false}"#,
            #"{"kind":"future","text":"hello"}"#,
            #"{"text":"missing operation"}"#,
            #"{"kind":42,"text":"wrong discriminator type"}"#,
            "42",
            #"{"kind":"message","text":42}"#,
        ]

        for input in inputs {
            let data = Data(input.utf8)
            #expect(
                normalizationOutcome { try preparedSchema.normalize(data) }
                    == normalizationOutcome { try schema.normalize(data) }
            )
        }
    }

    @Test("string-enum discriminator matches canonical string equality")
    func preparedStringEnumDiscriminatorMatchesCanonicalStringEquality() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let firstAlternative = stringEnumDiscriminatorFixtureAlternative(value: composed, payloadFieldName: "text")
        let schema = IPCJSONSchema.oneOf([
            firstAlternative,
            stringEnumDiscriminatorFixtureAlternative(value: "other", payloadFieldName: "enabled"),
        ])
        let preparedSchema = try IPCValidatedJSONSchema(schema: schema)
        let input = Data("{\"kind\":\"\(decomposed)\",\"text\":\"hello\"}".utf8)
        let preparedOutcome = normalizationOutcome { try preparedSchema.normalize(input) }
        let tryAllOutcome = normalizationOutcome { try schema.normalize(input) }

        #expect(preparedOutcome == tryAllOutcome)
        #expect(preparedOutcome == .success(try firstAlternative.normalize(input)))
    }

    @Test("canonically equivalent string-enum discriminators remain ambiguous")
    func preparedStringEnumDiscriminatorPreservesCanonicalAmbiguity() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let schema = IPCJSONSchema.oneOf([
            stringEnumDiscriminatorFixtureAlternative(value: composed, payloadFieldName: "value"),
            stringEnumDiscriminatorFixtureAlternative(value: decomposed, payloadFieldName: "value"),
        ])
        let preparedSchema = try IPCValidatedJSONSchema(schema: schema)
        let inputs = [composed, decomposed].map { kind in
            Data("{\"kind\":\"\(kind)\",\"value\":\"same\"}".utf8)
        }
        let ambiguous = IPCSchemaNormalizationOutcome.failure(
            path: "$",
            reason: IPCSchemaValidationError.Reason.ambiguousAlternative.rawValue
        )

        for input in inputs {
            let preparedOutcome = normalizationOutcome { try preparedSchema.normalize(input) }
            let tryAllOutcome = normalizationOutcome { try schema.normalize(input) }

            #expect(preparedOutcome == tryAllOutcome)
            #expect(preparedOutcome == ambiguous)
        }
    }

    @Test("string-enum discriminator matches Kelvin sign canonical equality")
    func preparedStringEnumDiscriminatorMatchesKelvinSign() throws {
        let firstAlternative = stringEnumDiscriminatorFixtureAlternative(value: "K", payloadFieldName: "value")
        let schema = IPCJSONSchema.oneOf([
            firstAlternative,
            stringEnumDiscriminatorFixtureAlternative(value: "other", payloadFieldName: "other"),
        ])
        let preparedSchema = try IPCValidatedJSONSchema(schema: schema)
        let input = Data("{\"kind\":\"\u{212A}\",\"value\":\"hello\"}".utf8)
        let preparedOutcome = normalizationOutcome { try preparedSchema.normalize(input) }
        let tryAllOutcome = normalizationOutcome { try schema.normalize(input) }

        #expect(preparedOutcome == tryAllOutcome)
        #expect(preparedOutcome == .success(try firstAlternative.normalize(input)))
    }

    @Test("mixed literal and string-enum discriminator preserves try-all outcomes")
    func preparedOneOfMixedDiscriminatorKindsMatchTryAll() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let literalAlternative = IPCJSONSchema.object(fields: [
            .init(name: "kind", description: "Operation", schema: try .literal(composed)),
            .init(name: "value", description: "Payload", schema: .string()),
        ])
        let enumAlternative = stringEnumDiscriminatorFixtureAlternative(value: decomposed, payloadFieldName: "value")
        let schema = IPCJSONSchema.oneOf([literalAlternative, enumAlternative])
        let preparedSchema = try IPCValidatedJSONSchema(schema: schema)
        let inputs = [composed, decomposed].map { kind in
            Data("{\"kind\":\"\(kind)\",\"value\":\"same\"}".utf8)
        }
        let ambiguous = IPCSchemaNormalizationOutcome.failure(
            path: "$",
            reason: IPCSchemaValidationError.Reason.ambiguousAlternative.rawValue
        )

        let composedOutcome = normalizationOutcome { try preparedSchema.normalize(inputs[0]) }
        #expect(composedOutcome == normalizationOutcome { try schema.normalize(inputs[0]) })
        #expect(composedOutcome == ambiguous)

        let decomposedOutcome = normalizationOutcome { try preparedSchema.normalize(inputs[1]) }
        #expect(decomposedOutcome == normalizationOutcome { try schema.normalize(inputs[1]) })
        #expect(decomposedOutcome == .success(try enumAlternative.normalize(inputs[1])))
    }

    @Test("prepared oneOf keeps try-all for schemas without a disjoint literal proof")
    func preparedOneOfFallsBackWhenLiteralProofIsIncomplete() throws {
        let duplicateLiteral = IPCJSONSchema.oneOf([
            discriminatorFixtureAlternative(literal: "same"),
            discriminatorFixtureAlternative(literal: "same"),
        ])
        let optionalDiscriminator = IPCJSONSchema.oneOf([
            .object(fields: [
                .init(
                    name: "kind",
                    description: "Operation",
                    schema: .string(allowedValues: ["optional"]),
                    presence: .optional
                ),
                .init(name: "value", description: "Value", schema: .string()),
            ]),
            discriminatorFixtureAlternative(literal: "required"),
        ])
        let nonObjectAlternative = IPCJSONSchema.oneOf([
            discriminatorFixtureAlternative(literal: "object"),
            .string(allowedValues: ["legacy"]),
        ])
        let alternativeMissingDiscriminator = IPCJSONSchema.oneOf([
            discriminatorFixtureAlternative(literal: "modern"),
            .object(fields: [
                .init(name: "legacy", description: "Legacy shape", schema: .boolean)
            ]),
        ])

        let cases: [(schema: IPCJSONSchema, input: String)] = [
            (duplicateLiteral, #"{"kind":"same","value":"ambiguous"}"#),
            (optionalDiscriminator, #"{"value":"matches the optional variant"}"#),
            (nonObjectAlternative, #""legacy"#),
            (alternativeMissingDiscriminator, #"{"legacy":true}"#),
        ]

        for testCase in cases {
            let preparedSchema = try IPCValidatedJSONSchema(schema: testCase.schema)
            let data = Data(testCase.input.utf8)
            #expect(
                normalizationOutcome { try preparedSchema.normalize(data) }
                    == normalizationOutcome { try testCase.schema.normalize(data) }
            )
        }
    }

    @Test("array and nullable schemas retain nested correction paths")
    func nestedCollectionsPreserveFieldPaths() throws {
        let schema = IPCJSONSchema.object(fields: [
            .init(
                name: "values",
                description: "Optional numeric values",
                schema: .array(items: .oneOf([.integer(minimum: 1), .null]), maximumCount: 3)
            )
        ])
        _ = try schema.normalize(Data(#"{"values":[1,null,2]}"#.utf8))
        do {
            _ = try schema.normalize(Data(#"{"values":[1,"bad"]}"#.utf8))
            Issue.record("Expected a nested field correction")
        } catch let failure as IPCSchemaValidationError {
            #expect(failure.fieldPath == "$.values[1]")
        }
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(Data(#"{"values":[1,2,3,4]}"#.utf8))
        }
    }

    private func messageSchema() throws -> IPCJSONSchema {
        try .object(fields: [
            .init(name: "text", description: "Exact private text", schema: .string(minimumLength: 1)),
            .init(
                name: "priority", description: "Bounded fixture priority", schema: .integer(minimum: 1, maximum: 3),
                presence: .defaulted(1)
            ),
            .init(name: "urgent", description: "Fixture switch", schema: .boolean, presence: .defaulted(false)),
        ])
    }
}

private func discriminatorFixtureAlternative(literal: String) -> IPCJSONSchema {
    .object(fields: [
        .init(name: "kind", description: "Operation", schema: .string(allowedValues: [literal])),
        .init(name: "value", description: "Value", schema: .string()),
    ])
}

private func stringEnumDiscriminatorFixtureAlternative(value: String, payloadFieldName: String) -> IPCJSONSchema {
    .object(fields: [
        .init(name: "kind", description: "Operation", schema: .string(allowedValues: [value])),
        .init(name: payloadFieldName, description: "Payload", schema: .string()),
    ])
}

private enum IPCSchemaNormalizationOutcome: Equatable {
    case success(Data)
    case failure(path: String, reason: String)
}

private func normalizationOutcome(_ operation: () throws -> Data) -> IPCSchemaNormalizationOutcome {
    do {
        return .success(try operation())
    } catch let error as IPCSchemaValidationError {
        return .failure(path: error.fieldPath, reason: error.reason.rawValue)
    } catch {
        return .failure(path: "<unexpected>", reason: String(reflecting: type(of: error)))
    }
}

private struct SchemaMessageParameters: Codable, Equatable, Sendable {
    let text: String
    let priority: Int
    let urgent: Bool
}

private struct SchemaTextOnlyParameters: Codable, Equatable, Sendable {
    let text: String
}
