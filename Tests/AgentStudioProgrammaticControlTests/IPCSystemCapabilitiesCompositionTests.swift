import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC system capabilities composition")
struct IPCSystemCapabilitiesCompositionTests {
    @Test("composition-dependent result schemas cover empty single and multiple catalogs")
    func resultSchemaCardinality() throws {
        let catalog = try makeBuiltInCatalog()
        let ping = try #require(
            catalog.erasedDescriptors.first { $0.metadata.name == "system.ping" }
        )
        let version = try #require(
            catalog.erasedDescriptors.first { $0.metadata.name == "system.version" }
        )

        let emptySchema = try IPCMethodCatalogResult.schema(
            compatibility: compatibility,
            methodSchemas: []
        )
        _ = try emptySchema.decode(
            IPCMethodCatalogResult.self,
            from: JSONEncoder().encode(
                IPCMethodCatalogResult(compatibility: compatibility, methods: [])
            )
        )
        #expect(throws: IPCSchemaValidationError.self) {
            try emptySchema.normalize(
                JSONEncoder().encode(
                    IPCMethodCatalogResult(
                        compatibility: compatibility,
                        methods: [ping.metadata]
                    )
                )
            )
        }

        let singleSchema = try IPCMethodCatalogResult.schema(
            compatibility: compatibility,
            methodSchemas: [ping.catalogEntrySchema]
        )
        _ = try singleSchema.decode(
            IPCMethodCatalogResult.self,
            from: JSONEncoder().encode(
                IPCMethodCatalogResult(
                    compatibility: compatibility,
                    methods: [ping.metadata]
                )
            )
        )

        let multipleSchema = try IPCMethodCatalogResult.schema(
            compatibility: compatibility,
            methodSchemas: [ping.catalogEntrySchema, version.catalogEntrySchema]
        )
        _ = try multipleSchema.decode(
            IPCMethodCatalogResult.self,
            from: JSONEncoder().encode(
                IPCMethodCatalogResult(
                    compatibility: compatibility,
                    methods: [ping.metadata, version.metadata]
                )
            )
        )
    }

    @Test("factory returns a sorted catalog containing capabilities exactly once")
    func factoryComposesFiniteSelfEntry() throws {
        let catalog = try makeBuiltInCatalog()
        let ping = try illustrativePing(in: catalog)
        let composition = try IPCSystemCapabilitiesDescriptorFactory.compose(
            compatibility: compatibility,
            availableDescriptors: catalog.erasedDescriptors,
            illustrativeDescriptor: ping
        )
        let names = composition.result.methods.map(\.name)

        #expect(names == names.sorted())
        #expect(names.count == 48)
        #expect(names.filter { $0 == "system.capabilities" }.count == 1)
        #expect(composition.erasedDescriptor.metadata.name == "system.capabilities")
        _ = try composition.descriptor.encodeResult(composition.result)
        _ = try composition.erasedDescriptor.catalogEntrySchema.decode(
            IPCMethodCatalogEntry.self,
            from: JSONEncoder().encode(composition.erasedDescriptor.metadata)
        )
    }

    @Test("factory rejects duplicate methods and an illustrative descriptor outside the composition")
    func factoryRejectsInvalidCompositionInputs() throws {
        let catalog = try makeBuiltInCatalog()
        let ping = try illustrativePing(in: catalog)
        let duplicate = try #require(catalog.erasedDescriptors.first)

        #expect(throws: IPCSystemCapabilitiesCompositionError.self) {
            try IPCSystemCapabilitiesDescriptorFactory.compose(
                compatibility: compatibility,
                availableDescriptors: catalog.erasedDescriptors + [duplicate],
                illustrativeDescriptor: ping
            )
        }
        #expect(throws: IPCSystemCapabilitiesCompositionError.self) {
            try IPCSystemCapabilitiesDescriptorFactory.compose(
                compatibility: compatibility,
                availableDescriptors: catalog.erasedDescriptors.filter {
                    $0.metadata.name != ping.metadata.name
                },
                illustrativeDescriptor: ping
            )
        }
    }

    @Test("the composed schema rejects a mismatched protocol or catalog identity")
    func compatibilityIdentityIsExact() throws {
        let catalog = try makeBuiltInCatalog()
        let ping = try illustrativePing(in: catalog)
        let schema = try IPCMethodCatalogResult.schema(
            compatibility: compatibility,
            methodSchemas: [ping.catalogEntrySchema]
        )
        for mismatch in [
            IPCProtocolCatalogCompatibility(
                wireProtocolIdentifier: "agentstudio-ipc-jsonrpc-1",
                catalogIdentifier: compatibility.catalogIdentifier
            ),
            IPCProtocolCatalogCompatibility(
                wireProtocolIdentifier: compatibility.wireProtocolIdentifier,
                catalogIdentifier: "agentstudio-ipc-v1"
            ),
        ] {
            #expect(throws: IPCSchemaValidationError.self) {
                try schema.normalize(
                    JSONEncoder().encode(
                        IPCMethodCatalogResult(
                            compatibility: mismatch,
                            methods: [ping.metadata]
                        )
                    )
                )
            }
        }
    }

    @Test("tampered catalog metadata fails with content-free correction data")
    func metadataTamperingDoesNotEchoPrivateInput() throws {
        let composition = try makeComposition()
        let encoded = try JSONEncoder().encode(composition.result)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var methods = try #require(object["methods"] as? [[String: Any]])
        methods[0]["privateCredentialField"] = "private-value"
        object["methods"] = methods

        do {
            _ = try composition.descriptor.contract.resultSchema.normalize(
                JSONSerialization.data(withJSONObject: object)
            )
            Issue.record("Expected tampered metadata to fail")
        } catch let error as IPCSchemaValidationError {
            let correction = try #require(
                String(bytes: JSONEncoder().encode(error), encoding: .utf8)
            )
            #expect(!correction.contains("privateCredentialField"))
            #expect(!correction.contains("private-value"))
        }
    }

    @Test("the actual 47-method catalog response fits the existing one MiB frame budget")
    func actualCatalogFitsExistingFrameBudget() throws {
        let composition = try makeComposition()
        let resultObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(composition.result)
        )
        let responseObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "result": resultObject,
        ]
        let responseBytes = try JSONSerialization.data(
            withJSONObject: responseObject,
            options: [.sortedKeys]
        )
        let ndjsonFrameByteCount = responseBytes.count + 1
        let existingFrameBudgetBytes = 1_048_576

        #expect(
            ndjsonFrameByteCount <= existingFrameBudgetBytes,
            "Actual capabilities frame is \(ndjsonFrameByteCount) bytes"
        )
    }

    private var compatibility: IPCProtocolCatalogCompatibility {
        .current
    }

    private func illustrativePing(
        in catalog: IPCBuiltInMethodCatalog
    ) throws -> IPCAnyMethodDescriptor {
        try #require(
            catalog.erasedDescriptors.first { $0.metadata.name == "system.ping" }
        )
    }

    private func makeComposition() throws -> IPCSystemCapabilitiesComposition {
        let catalog = try makeBuiltInCatalog()
        return try IPCSystemCapabilitiesDescriptorFactory.compose(
            compatibility: compatibility,
            availableDescriptors: catalog.erasedDescriptors,
            illustrativeDescriptor: try illustrativePing(in: catalog)
        )
    }

    private func makeBuiltInCatalog() throws -> IPCBuiltInMethodCatalog {
        let context = IPCBuiltInMethodExampleContext(
            runtimeId: UUIDv7.generate(),
            windowId: UUIDv7.generate(),
            workspaceId: UUIDv7.generate(),
            repositoryId: UUIDv7.generate(),
            worktreeId: UUIDv7.generate(),
            tabId: UUIDv7.generate(),
            paneId: UUIDv7.generate(),
            commandId: UUIDv7.generate(),
            correlationId: UUIDv7.generate(),
            subscriptionId: UUIDv7.generate()
        )
        let relationships = IPCBuiltInMethodRelationshipInputs(
            paneFocus: .appCommand(identifier: "fixture.pane-focus"),
            paneClose: .appCommand(identifier: "fixture.pane-close"),
            drawerToggle: .appCommand(identifier: "fixture.drawer-toggle"),
            drawerAddPane: .appCommand(identifier: "fixture.drawer-add"),
            bridgeDiffLoad: .appCommand(identifier: "fixture.bridge-review-open"),
            bridgeFileViewOpen: .appCommand(identifier: "fixture.bridge-files-open")
        )
        return try IPCBuiltInMethodCatalog(
            inputs: IPCBuiltInMethodCatalogInputs(
                relationships: relationships,
                examples: context
            )
        )
    }
}
