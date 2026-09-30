import Foundation

package struct IPCSystemAndAuthMethodDescriptors: Sendable {
    package let systemPing: IPCMethodDescriptor<IPCEmptyParams, IPCSystemPingResult>
    package let systemIdentify: IPCMethodDescriptor<IPCEmptyParams, IPCSystemIdentifyResult>
    package let systemVersion: IPCMethodDescriptor<IPCEmptyParams, IPCSystemVersionResult>
    package let authLogin: IPCMethodDescriptor<IPCAuthLoginParams, IPCAuthStatusResult>
    package let authStatus: IPCMethodDescriptor<IPCEmptyParams, IPCAuthStatusResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        systemPing = try IPCBuiltInDescriptorSupport.read(
            name: "system.ping",
            description: "Confirm that the selected Agent Studio runtime is reachable.",
            parameters: IPCEmptyParams(),
            result: IPCSystemPingResult(runtimeId: examples.runtimeId),
            privilege: .systemRead,
            dataScope: .unspecified,
            exposure: .allChannels,
            availability: .preAuthentication,
            agentEligibility: .anyTarget
        )
        systemIdentify = try IPCBuiltInDescriptorSupport.read(
            name: "system.identify",
            description: "Identify the selected runtime, access mode, and application version.",
            parameters: IPCEmptyParams(),
            result: IPCSystemIdentifyResult(
                runtimeId: examples.runtimeId,
                accessMode: .agentStudioOnly,
                appVersion: "1.0.0"
            ),
            privilege: .systemRead,
            dataScope: .unspecified,
            exposure: .allChannels,
            agentEligibility: .anyTarget
        )
        systemVersion = try IPCBuiltInDescriptorSupport.read(
            name: "system.version",
            description: "Read the Agent Studio application version.",
            parameters: IPCEmptyParams(),
            result: IPCSystemVersionResult(appVersion: "1.0.0"),
            privilege: .systemRead,
            dataScope: .unspecified,
            exposure: .allChannels,
            agentEligibility: .anyTarget
        )
        authLogin = try IPCMethodDescriptor(
            name: "auth.login",
            description: "Authenticate this connection with the owning runtime credential.",
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
                .init(reason: "unauthenticated", description: "The supplied credential is not valid for this runtime."),
            ],
            isMutating: false,
            correlationPolicy: .notAccepted
        )
        authStatus = try IPCBuiltInDescriptorSupport.read(
            name: "auth.status",
            description: "Read whether this connection has an authenticated principal.",
            parameters: IPCEmptyParams(),
            result: IPCAuthStatusResult.unauthenticated,
            privilege: .systemRead,
            dataScope: .unspecified,
            exposure: .allChannels,
            availability: .preAuthentication,
            agentEligibility: nil
        )
    }

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
