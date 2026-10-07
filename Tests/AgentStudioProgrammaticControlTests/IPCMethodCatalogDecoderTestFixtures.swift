import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

struct IPCMethodCatalogDecoderFixture {
    let composition: IPCSystemCapabilitiesComposition

    init() throws {
        let examples = IPCBuiltInMethodExampleContext(
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
        let catalog = try IPCBuiltInMethodCatalog(
            inputs: IPCBuiltInMethodCatalogInputs(
                relationships: relationships,
                examples: examples
            )
        )
        let ping = try requireValue(
            catalog.erasedDescriptors.first { $0.metadata.name == "system.ping" }
        )
        composition = try IPCSystemCapabilitiesDescriptorFactory.compose(
            compatibility: .current,
            availableDescriptors: catalog.erasedDescriptors,
            illustrativeDescriptor: ping
        )
    }

    func encodedResult() throws -> Data {
        try JSONEncoder().encode(composition.result)
    }

    func encodedResult(
        mutating mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var object = try requireValue(
            JSONSerialization.jsonObject(with: encodedResult()) as? [String: Any]
        )
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func mutateMethod(
        named methodName: String,
        in object: inout [String: Any],
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var methods = try requireValue(object["methods"] as? [[String: Any]])
        let index = try requireValue(
            methods.firstIndex { $0["name"] as? String == methodName }
        )
        try mutation(&methods[index])
        object["methods"] = methods
    }
}

private func requireValue<Value>(_ value: Value?) throws -> Value {
    guard let value else {
        throw IPCMethodCatalogDecoderFixtureError.missingFixtureValue
    }
    return value
}

private enum IPCMethodCatalogDecoderFixtureError: Error {
    case missingFixtureValue
}
