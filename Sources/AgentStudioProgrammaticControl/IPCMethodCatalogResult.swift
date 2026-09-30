import Foundation

package struct IPCProtocolCatalogCompatibility: Codable, Equatable, Sendable {
    package static let current = Self(
        wireProtocolIdentifier: "agentstudio-ipc-jsonrpc-2",
        catalogIdentifier: "agentstudio-ipc-v2"
    )

    package let wireProtocolIdentifier: String
    package let catalogIdentifier: String

    package init(
        wireProtocolIdentifier: String,
        catalogIdentifier: String
    ) {
        self.wireProtocolIdentifier = wireProtocolIdentifier
        self.catalogIdentifier = catalogIdentifier
    }
}

package struct IPCMethodCatalogResult: Codable, Equatable, Sendable {
    package let compatibility: IPCProtocolCatalogCompatibility
    package let methods: [IPCMethodCatalogEntry]
    /// Recognized methods this channel does not expose, with their eligibility.
    package let recognizedUnexposedMethods: [IPCRecognizedUnexposedName]

    package init(
        compatibility: IPCProtocolCatalogCompatibility,
        methods: [IPCMethodCatalogEntry],
        recognizedUnexposedMethods: [IPCRecognizedUnexposedName] = []
    ) {
        self.compatibility = compatibility
        self.methods = methods
        self.recognizedUnexposedMethods = recognizedUnexposedMethods
    }

    private enum CodingKeys: String, CodingKey {
        case compatibility
        case methods
        case recognizedUnexposedMethods
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        compatibility = try container.decode(IPCProtocolCatalogCompatibility.self, forKey: .compatibility)
        methods = try container.decode([IPCMethodCatalogEntry].self, forKey: .methods)
        recognizedUnexposedMethods =
            try container.decodeIfPresent([IPCRecognizedUnexposedName].self, forKey: .recognizedUnexposedMethods)
            ?? []
    }

    package static func schema(
        compatibility: IPCProtocolCatalogCompatibility,
        methodSchemas: [IPCJSONSchema]
    ) throws -> IPCJSONSchema {
        let methodsSchema: IPCJSONSchema
        switch methodSchemas.count {
        case 0:
            methodsSchema = .array(items: .null, maximumCount: 0)
        case 1:
            methodsSchema = .array(items: methodSchemas[0])
        default:
            methodsSchema = .array(items: .oneOf(methodSchemas))
        }
        return .object(fields: [
            .init(
                name: "compatibility",
                description: "Exact wire protocol and typed catalog compatibility identity",
                schema: try IPCJSONSchema.literal(compatibility)
            ),
            .init(
                name: "methods",
                description: "Complete available typed method metadata in name order",
                schema: methodsSchema
            ),
            try IPCRecognizedUnexposedName.discoveryField(
                "recognizedUnexposedMethods",
                description: "Recognized methods this channel does not expose, with their agent eligibility"
            ),
        ])
    }
}
