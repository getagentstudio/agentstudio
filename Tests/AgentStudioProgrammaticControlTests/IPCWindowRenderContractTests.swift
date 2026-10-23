import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("Window render and resize contracts")
struct IPCWindowRenderContractTests {
    @Test("window methods retain the complete reviewed transport classification")
    func windowMethodsDeclareDiagnosticTransportContract() throws {
        let catalog = try IPCBuiltInMethodCatalog(inputs: IPCBuiltInMethodCatalogTestFixture.makeInputs())
        let render = try #require(catalog.erasedDescriptors.first { $0.metadata.name == "window.render" }).metadata
        let resize = try #require(catalog.erasedDescriptors.first { $0.metadata.name == "window.resize" }).metadata
        for metadata in [render, resize] {
            #expect(metadata.exposure == .debugTesting)
            #expect(metadata.agentEligibility == .notYetAllowed)
            #expect(metadata.allowedTargetKinds == [.window])
            #expect(metadata.dataScope == .uiSurface)
            #expect(metadata.commandRelationship == .noInteractiveIdentity)
            #expect(metadata.principalAvailability == .authenticated)
            #expect(metadata.resultSemantics == .applied)
            #expect(metadata.responseDelivery == .single)
            #expect(metadata.offlineEligibility == .never)
            #expect(metadata.modelCalls.isEmpty)
            #expect(metadata.documentedErrors.contains { $0.reason == "notYetAllowed" })
        }
        #expect(render.callIntent == .read)
        #expect(render.requiredPrivileges == [.workspaceRead])
        #expect(render.executionOwner == .queryReader)
        #expect(!render.isMutating)
        #expect(render.correlationPolicy == .notAccepted)
        #expect(resize.callIntent == .control)
        #expect(resize.requiredPrivileges == [.layoutMutate])
        #expect(resize.executionOwner == .uiPresentation)
        #expect(resize.isMutating)
        #expect(resize.correlationPolicy == .required)
    }

    @Test("typed window requests reject invalid size, missing identity, correlation and extra fields")
    func windowRequestSchemasRejectInvalidWireValues() throws {
        let windowId = UUIDv7.generate().uuidString
        let correlationId = UUIDv7.generate().uuidString
        let catalog = try IPCBuiltInMethodCatalog(inputs: IPCBuiltInMethodCatalogTestFixture.makeInputs())
        let resize = try #require(catalog.erasedDescriptors.first { $0.metadata.name == "window.resize" })
        let render = try #require(catalog.erasedDescriptors.first { $0.metadata.name == "window.render" })
        let valid: [String: Any] = [
            "workspaceWindowId": windowId, "contentWidth": 520.25, "contentHeight": 600, "correlationId": correlationId,
        ]
        _ = try resize.normalizeParameters(JSONSerialization.data(withJSONObject: valid))
        for field in ["contentWidth", "contentHeight"] {
            for invalid: Any in [0, -1, "NaN", "Infinity"] {
                var parameters = valid
                parameters[field] = invalid
                #expect(throws: IPCSchemaValidationError.self) {
                    try resize.normalizeParameters(JSONSerialization.data(withJSONObject: parameters))
                }
            }
        }
        for field in ["workspaceWindowId", "correlationId", "contentWidth", "contentHeight"] {
            var parameters = valid
            parameters.removeValue(forKey: field)
            #expect(throws: IPCSchemaValidationError.self) {
                try resize.normalizeParameters(JSONSerialization.data(withJSONObject: parameters))
            }
        }
        for parameters: [String: Any] in [
            ["workspaceWindowId": "invalid"],
            ["workspaceWindowId": windowId, "correlationId": correlationId],
            ["workspaceWindowId": windowId, "path": "/caller/chosen"],
        ] {
            #expect(throws: IPCSchemaValidationError.self) {
                try render.normalizeParameters(JSONSerialization.data(withJSONObject: parameters))
            }
        }
    }

    @Test("render results validate actual image dimensions and closed result fields")
    func windowResultSchemaRejectsMalformedImage() throws {
        let result = IPCWindowRenderResult(
            workspaceWindowId: UUIDv7.generate(),
            image: .init(
                path: "/fixture/renders/result.png", pixelWidth: 1040, pixelHeight: 1200,
                scale: 2, imagePointSize: .init(width: 520, height: 600)),
            contentSize: .init(width: 520, height: 600))
        let schema = try IPCWindowRenderResult.ipcSchema()
        let bytes = try JSONEncoder().encode(result)
        #expect(try schema.decode(IPCWindowRenderResult.self, from: bytes) == result)
        var object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var image = try #require(object["image"] as? [String: Any])
        image["pixelWidth"] = 0
        object["image"] = image
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(JSONSerialization.data(withJSONObject: object))
        }
        object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["unexpected"] = true
        #expect(throws: IPCSchemaValidationError.self) {
            try schema.normalize(JSONSerialization.data(withJSONObject: object))
        }
    }
}
