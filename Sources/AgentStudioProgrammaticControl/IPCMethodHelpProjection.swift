import Foundation

/// Presentation-only projection of a composition-owned envelope, without its runtime result catalog.
package struct IPCMethodHelpProjection: Sendable {
    package enum AgentAccess: Sendable {
        case readOnly
        case selectedCommand
    }

    package enum ArgumentSyntax: Sendable {
        case schemaOptions
        case rawCommandStrings
    }

    package let name: String
    package let summary: String
    package let agentAccess: AgentAccess
    package let argumentSyntax: ArgumentSyntax
    private let parameterSchemaFactory: @Sendable () throws -> IPCJSONSchema
    private let exampleArgumentsFactory: @Sendable (IPCBuiltInMethodCatalogInputs) -> [String]

    init(
        name: String, summary: String, agentAccess: AgentAccess, argumentSyntax: ArgumentSyntax,
        parameterSchema: @escaping @Sendable () throws -> IPCJSONSchema,
        exampleArguments: @escaping @Sendable (IPCBuiltInMethodCatalogInputs) -> [String]
    ) {
        self.name = name
        self.summary = summary
        self.agentAccess = agentAccess
        self.argumentSyntax = argumentSyntax
        parameterSchemaFactory = parameterSchema
        exampleArgumentsFactory = exampleArguments
    }

    package func parameterSchema() throws -> IPCJSONSchema { try parameterSchemaFactory() }

    package func exampleArguments(inputs: IPCBuiltInMethodCatalogInputs) -> [String] {
        exampleArgumentsFactory(inputs)
    }
}
