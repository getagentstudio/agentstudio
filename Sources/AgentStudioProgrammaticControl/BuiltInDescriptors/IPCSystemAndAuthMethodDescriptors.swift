import Foundation

package struct IPCSystemAndAuthMethodDescriptors: Sendable {
    package let systemPing: IPCMethodDescriptor<IPCEmptyParams, IPCSystemPingResult>
    package let systemIdentify: IPCMethodDescriptor<IPCEmptyParams, IPCSystemIdentifyResult>
    package let systemVersion: IPCMethodDescriptor<IPCEmptyParams, IPCSystemVersionResult>
    package let authLogin: IPCMethodDescriptor<IPCAuthLoginParams, IPCAuthStatusResult>
    package let authStatus: IPCMethodDescriptor<IPCEmptyParams, IPCAuthStatusResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        systemPing = try Self.systemPingEntry.makeDescriptor(inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        systemIdentify = try Self.systemIdentifyEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        systemVersion = try Self.systemVersionEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        authLogin = try Self.authLoginEntry.makeDescriptor(inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        authStatus = try Self.authStatusEntry.makeDescriptor(inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        systemPing = try Self.systemPingEntry.typedDescriptor(in: representations)
        systemIdentify = try Self.systemIdentifyEntry.typedDescriptor(in: representations)
        systemVersion = try Self.systemVersionEntry.typedDescriptor(in: representations)
        authLogin = try Self.authLoginEntry.typedDescriptor(in: representations)
        authStatus = try Self.authStatusEntry.typedDescriptor(in: representations)
    }

    static let systemPingEntry = IPCBuiltInMethodEntry<IPCEmptyParams, IPCSystemPingResult>(
        name: "system.ping", summary: "Confirm that the selected Agent Studio runtime is reachable.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .anyTarget,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
                parameters: IPCEmptyParams(),
                result: IPCSystemPingResult(runtimeId: examples.runtimeId),
                privilege: .systemRead,
                dataScope: .unspecified,
                exposure: .allChannels,
                availability: .preAuthentication,
                agentEligibility: entryEligibility
            )
        })

    static let systemIdentifyEntry = IPCBuiltInMethodEntry<IPCEmptyParams, IPCSystemIdentifyResult>(
        name: "system.identify", summary: "Identify the selected runtime, access mode, and application version.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .anyTarget,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
                parameters: IPCEmptyParams(),
                result: IPCSystemIdentifyResult(
                    runtimeId: examples.runtimeId,
                    accessMode: .agentStudioOnly,
                    appVersion: "1.0.0"
                ),
                privilege: .systemRead,
                dataScope: .unspecified,
                exposure: .allChannels,
                agentEligibility: entryEligibility
            )
        })

    static let systemVersionEntry = IPCBuiltInMethodEntry<IPCEmptyParams, IPCSystemVersionResult>(
        name: "system.version", summary: "Read the Agent Studio application version.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .anyTarget,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, _ in
            try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
                parameters: IPCEmptyParams(),
                result: IPCSystemVersionResult(appVersion: "1.0.0"),
                privilege: .systemRead,
                dataScope: .unspecified,
                exposure: .allChannels,
                agentEligibility: entryEligibility
            )
        })

    static let authLoginEntry = IPCBuiltInMethodEntry<IPCAuthLoginParams, IPCAuthStatusResult>(
        name: "auth.login", summary: "Authenticate this connection with the owning runtime credential.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: nil,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCMethodDescriptor(
                name: entryName,
                description: entrySummary,
                examples: [
                    .init(
                        description: "Authenticate a pane connection",
                        parameters: IPCAuthLoginParams(token: "example-runtime-credential"),
                        result: .authenticated(
                            principalId: examples.paneId,
                            runtimeId: examples.runtimeId,
                            accessMode: .agentStudioOnly
                        )
                    )
                ],
                exposure: .allChannels,
                requiredPrivileges: [.systemRead],
                dataScope: .unspecified,
                allowedTargetKinds: [],
                commandRelationship: .noInteractiveIdentity,
                executionOwner: .queryReader,
                principalAvailability: .preAuthentication,
                resultSemantics: .applied,
                documentedErrors: [
                    IPCBuiltInDescriptorSupport.invalidParams,
                    .init(
                        reason: "unauthenticated", description: "The supplied credential is not valid for this runtime."
                    ),
                ],
                isMutating: false,
                correlationPolicy: .notAccepted,
                agentEligibility: entryEligibility
            )
        })

    static let authStatusEntry = IPCBuiltInMethodEntry<IPCEmptyParams, IPCAuthStatusResult>(
        name: "auth.status", summary: "Read whether this connection has an authenticated principal.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: nil,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, _ in
            try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
                parameters: IPCEmptyParams(),
                result: IPCAuthStatusResult.unauthenticated,
                privilege: .systemRead,
                dataScope: .unspecified,
                exposure: .allChannels,
                availability: .preAuthentication,
                agentEligibility: entryEligibility
            )
        })

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            let representations: [any IPCMethodDescriptorRepresentation] = try [
                IPCMethodDescriptorRepresentations(typedDescriptor: systemPing),
                IPCMethodDescriptorRepresentations(typedDescriptor: systemIdentify),
                IPCMethodDescriptorRepresentations(typedDescriptor: systemVersion),
                IPCMethodDescriptorRepresentations(typedDescriptor: authLogin),
                IPCMethodDescriptorRepresentations(typedDescriptor: authStatus),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
