import Foundation

package enum IPCMethodExposure: String, Codable, CaseIterable, Equatable, Sendable {
    case allChannels
    case debugTesting
}

package enum IPCMethodResponseDelivery: String, Codable, CaseIterable, Equatable, Sendable {
    case single
    case subscription
}

package enum IPCCorrelationPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case notAccepted
    case optional
    case required
}

package enum IPCModelCallVariant: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case message
    case needsYou = "needs-you"
    case needsYouClear = "needs-you --clear"
    case done
}

package enum IPCCommandRelationship: Codable, Equatable, Sendable {
    case noInteractiveIdentity
    case appCommand(identifier: String)
    case appCommandParameter(field: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case identifier
        case field
    }

    private enum Kind: String, Codable {
        case noInteractiveIdentity
        case appCommand
        case appCommandParameter
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .noInteractiveIdentity:
            self = .noInteractiveIdentity
        case .appCommand:
            self = .appCommand(
                identifier: try container.decode(String.self, forKey: .identifier)
            )
        case .appCommandParameter:
            self = .appCommandParameter(field: try container.decode(String.self, forKey: .field))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noInteractiveIdentity:
            try container.encode(Kind.noInteractiveIdentity, forKey: .kind)
        case .appCommand(let identifier):
            try container.encode(Kind.appCommand, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        case .appCommandParameter(let field):
            try container.encode(Kind.appCommandParameter, forKey: .kind)
            try container.encode(field, forKey: .field)
        }
    }
}

package enum IPCMethodOfflineEligibility: Codable, Equatable, Sendable {
    case never
    case modelCallVariants(Set<IPCModelCallVariant>)

    private enum CodingKeys: String, CodingKey {
        case kind
        case variants
    }

    private enum Kind: String, Codable {
        case never
        case modelCallVariants
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .never:
            self = .never
        case .modelCallVariants:
            self = .modelCallVariants(
                Set(try container.decode([IPCModelCallVariant].self, forKey: .variants))
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .never:
            try container.encode(Kind.never, forKey: .kind)
        case .modelCallVariants(let variants):
            try container.encode(Kind.modelCallVariants, forKey: .kind)
            try container.encode(
                variants.sorted { $0.rawValue < $1.rawValue },
                forKey: .variants
            )
        }
    }
}

package struct IPCMethodErrorCase: Codable, Equatable, Sendable {
    package let reason: String
    package let description: String

    package init(reason: String, description: String) {
        self.reason = reason
        self.description = description
    }
}

package struct IPCModelCallSelector: Codable, Equatable, Sendable {
    package let parameterField: String
    package let equals: String

    package init(parameterField: String, equals: String) {
        self.parameterField = parameterField
        self.equals = equals
    }
}

package struct IPCModelScalarArgument: Codable, Equatable, Sendable {
    package let name: String
    package let parameterField: String
    package let description: String
    package let isRequired: Bool

    package init(
        name: String,
        parameterField: String,
        description: String,
        isRequired: Bool
    ) {
        self.name = name
        self.parameterField = parameterField
        self.description = description
        self.isRequired = isRequired
    }
}

package struct IPCModelCallProjection: Codable, Equatable, Sendable {
    package let variant: IPCModelCallVariant
    package let selectors: [IPCModelCallSelector]
    package let scalarArguments: [IPCModelScalarArgument]
    package let successReply: String
    package let queuedReply: String?

    package init(
        variant: IPCModelCallVariant,
        selectors: [IPCModelCallSelector],
        scalarArguments: [IPCModelScalarArgument],
        successReply: String,
        queuedReply: String?
    ) {
        self.variant = variant
        self.selectors = selectors
        self.scalarArguments = scalarArguments
        self.successReply = successReply
        self.queuedReply = queuedReply
    }
}

package struct IPCMethodExample<
    Parameters: Codable & Sendable,
    Result: Codable & Sendable
>: Codable, Sendable {
    package let description: String
    package let parameters: Parameters
    package let result: Result

    package init(description: String, parameters: Parameters, result: Result) {
        self.description = description
        self.parameters = parameters
        self.result = result
    }
}

/// Generic metadata keeps examples typed until a heterogeneous registry erases
/// the descriptor. Encoding projects schemas as their finite JSON Schema
/// documents and never exposes an untyped parameter dictionary.
package struct IPCMethodDescriptorMetadata<
    Parameters: Codable & Sendable,
    Result: Codable & Sendable
>: Codable, Sendable {
    package let name: String
    package let description: String
    package let parameterSchema: IPCJSONSchema
    package let resultSchema: IPCJSONSchema
    package let examples: [IPCMethodExample<Parameters, Result>]
    package let exposure: IPCMethodExposure
    package let requiredPrivileges: [IPCPrivilegeClass]
    package let dataScope: IPCDataScope
    package let allowedTargetKinds: [IPCHandleKind]
    package let commandRelationship: IPCCommandRelationship
    package let executionOwner: IPCExecutionOwner
    package let principalAvailability: IPCPrincipalAvailability
    package let resultSemantics: IPCResultSemantics
    package let documentedErrors: [IPCMethodErrorCase]
    package let isMutating: Bool
    package let correlationPolicy: IPCCorrelationPolicy
    package let responseDelivery: IPCMethodResponseDelivery
    package let offlineEligibility: IPCMethodOfflineEligibility
    package let modelCalls: [IPCModelCallProjection]
    package let agentEligibility: IPCAgentEligibility?
}
