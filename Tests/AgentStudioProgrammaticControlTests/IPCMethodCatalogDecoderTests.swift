import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC method catalog decoder")
struct IPCMethodCatalogDecoderTests {
    @Test("decodes the actual factory catalog without reproducing illustrative identifiers")
    func actualFactoryCatalogDecodes() throws {
        let fixture = try IPCMethodCatalogDecoderFixture()
        let data = try fixture.encodedResult()

        let decoded = try IPCMethodCatalogDecoder.decode(data)

        #expect(decoded == fixture.composition.result)
        #expect(decoded.compatibility == .current)
        #expect(decoded.methods.map(\.name) == decoded.methods.map(\.name).sorted())
        #expect(decoded.methods.filter { $0.name == "system.capabilities" }.count == 1)
    }

    @Test("unknown outer and metadata fields are rejected from original wire bytes")
    func unknownFieldsCannotBeDiscardedByProvisionalCodableDecode() throws {
        let fixture = try IPCMethodCatalogDecoderFixture()
        let outer = try fixture.encodedResult { object in
            object["privateOuterField"] = "private-outer-value"
        }
        let metadata = try fixture.encodedResult { object in
            try fixture.mutateMethod(named: "system.ping", in: &object) { method in
                method["privateMetadataField"] = "private-metadata-value"
            }
        }

        for data in [outer, metadata] {
            do {
                _ = try IPCMethodCatalogDecoder.decode(data)
                Issue.record("Expected an unknown catalog field to fail")
            } catch let error as IPCSchemaValidationError {
                let correctionData = try JSONEncoder().encode(error)
                let correction = try #require(
                    String(bytes: correctionData, encoding: .utf8)
                )
                #expect(!correction.contains("privateOuterField"))
                #expect(!correction.contains("private-outer-value"))
                #expect(!correction.contains("privateMetadataField"))
                #expect(!correction.contains("private-metadata-value"))
            }
        }
    }

    @Test("missing required metadata fields are rejected")
    func missingMetadataFieldFails() throws {
        let fixture = try IPCMethodCatalogDecoderFixture()
        let data = try fixture.encodedResult { object in
            try fixture.mutateMethod(named: "system.ping", in: &object) { method in
                method.removeValue(forKey: "description")
            }
        }

        #expect(throws: IPCSchemaValidationError.self) {
            try IPCMethodCatalogDecoder.decode(data)
        }
    }

    @Test("received examples must satisfy their declared parameter and result schemas")
    func receivedExampleCannotApproveItsOwnDrift() throws {
        let fixture = try IPCMethodCatalogDecoderFixture()
        let invalidParameters = try fixture.encodedResult { object in
            try fixture.mutateMethod(named: "system.ping", in: &object) { method in
                var examples = try #require(method["examples"] as? [[String: Any]])
                examples[0]["parameters"] = ["undeclared": true]
                method["examples"] = examples
            }
        }
        let invalidResult = try fixture.encodedResult { object in
            try fixture.mutateMethod(named: "system.ping", in: &object) { method in
                var examples = try #require(method["examples"] as? [[String: Any]])
                var result = try #require(examples[0]["result"] as? [String: Any])
                result["ok"] = false
                examples[0]["result"] = result
                method["examples"] = examples
            }
        }

        for data in [invalidParameters, invalidResult] {
            #expect(throws: IPCSchemaValidationError.self) {
                try IPCMethodCatalogDecoder.decode(data)
            }
        }
    }

    @Test("an invalid example in a middle catalog entry is rejected")
    func invalidExampleInMiddleCatalogEntryIsRejected() throws {
        let fixture = try IPCMethodCatalogDecoderFixture()
        let methodCount = fixture.composition.result.methods.count
        let candidates = fixture.composition.result.methods.enumerated().filter { candidate in
            guard candidate.offset > 0, candidate.offset < methodCount - 1,
                !candidate.element.examples.isEmpty
            else {
                return false
            }
            if case .object = candidate.element.parameterSchema { return true }
            return false
        }
        let middleCandidate = try #require(candidates.dropFirst(candidates.count / 2).first)
        let data = try fixture.encodedResult { object in
            try fixture.mutateMethod(named: middleCandidate.element.name, in: &object) { method in
                var examples = try #require(method["examples"] as? [[String: Any]])
                examples[0]["parameters"] = ["unadvertisedMiddleValue": true]
                method["examples"] = examples
            }
        }

        #expect(throws: IPCSchemaValidationError.self) {
            try IPCMethodCatalogDecoder.decode(data)
        }
    }

    @Test("duplicate unsorted or missing capabilities entries are rejected")
    func catalogIdentityInvariantsAreRequired() throws {
        let fixture = try IPCMethodCatalogDecoderFixture()
        let duplicate = try fixture.encodedResult { object in
            var methods = try #require(object["methods"] as? [[String: Any]])
            methods.append(try #require(methods.first))
            object["methods"] = methods
        }
        let unsorted = try fixture.encodedResult { object in
            var methods = try #require(object["methods"] as? [[String: Any]])
            methods.reverse()
            object["methods"] = methods
        }
        let missingCapabilities = try fixture.encodedResult { object in
            var methods = try #require(object["methods"] as? [[String: Any]])
            methods.removeAll { $0["name"] as? String == "system.capabilities" }
            object["methods"] = methods
        }

        for data in [duplicate, unsorted, missingCapabilities] {
            #expect(throws: IPCSchemaValidationError.self) {
                try IPCMethodCatalogDecoder.decode(data)
            }
        }
    }

    @Test("foreign compatibility identities are rejected")
    func compatibilityMustBeCurrent() throws {
        let fixture = try IPCMethodCatalogDecoderFixture()
        let data = try fixture.encodedResult { object in
            var compatibility = try #require(
                object["compatibility"] as? [String: Any]
            )
            compatibility["catalogIdentifier"] = "agentstudio-ipc-v1"
            object["compatibility"] = compatibility
        }

        #expect(throws: IPCSchemaValidationError.self) {
            try IPCMethodCatalogDecoder.decode(data)
        }
    }

    @Test("malformed received schema documents are rejected")
    func malformedSchemaDefinitionFails() throws {
        let fixture = try IPCMethodCatalogDecoderFixture()
        let data = try fixture.encodedResult { object in
            try fixture.mutateMethod(named: "system.ping", in: &object) { method in
                method["parameterSchema"] = [
                    "type": "integer",
                    "minimum": 8,
                    "maximum": 3,
                ]
            }
        }

        #expect(throws: IPCSchemaValidationError.self) {
            try IPCMethodCatalogDecoder.decode(data)
        }
    }

    @Test("received metadata must satisfy descriptor metadata invariants")
    func metadataInvariantsAreSharedWithDescriptorConstruction() throws {
        let fixture = try IPCMethodCatalogDecoderFixture()
        let data = try fixture.encodedResult { object in
            try fixture.mutateMethod(named: "system.ping", in: &object) { method in
                method["isMutating"] = true
                method["correlationPolicy"] = "notAccepted"
            }
        }

        #expect(throws: IPCSchemaValidationError.self) {
            try IPCMethodCatalogDecoder.decode(data)
        }
    }

    @Test("validated catalog round-trips through a finite schema derived from received entries")
    func decodedCatalogHasFiniteCorrectSchema() throws {
        let fixture = try IPCMethodCatalogDecoderFixture()
        let decoded = try IPCMethodCatalogDecoder.decode(fixture.encodedResult())
        let entrySchemas = try decoded.methods.map { entry in
            try IPCMethodCatalogEntry.schemaForReceivedEntry(entry)
        }
        let schema = try IPCMethodCatalogResult.schema(
            compatibility: .current,
            methodSchemas: entrySchemas
        )
        let encoded = try JSONEncoder().encode(decoded)
        let roundTripped = try schema.decode(IPCMethodCatalogResult.self, from: encoded)
        let schemaData = try schema.jsonSchemaData()
        let discoveredSchema = try JSONDecoder().decode(IPCJSONSchema.self, from: schemaData)

        #expect(roundTripped == decoded)
        #expect(discoveredSchema == schema)
    }
}
