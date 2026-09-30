import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("App IPC typed method registration")
struct AppIPCTypedMethodRegistrationTests {
    @Test("typed invocation canonicalizes parameters before authorization and the handler")
    func typedInvocationCanonicalizesBeforeAuthorizationAndHandler() async throws {
        let fixture = TypedRegistrationFixture()
        let correlationId = UUIDv7.generate()
        let canonicalPaneId = UUIDv7.generate()
        let canonicalPaneHandle = IPCHandle(
            kind: .pane,
            reference: .canonicalUUID(canonicalPaneId)
        )
        let recorder = TypedRegistrationRecorder()
        let registration = try makeRegistration(recorder: recorder)
        let erasedRegistration = try registration.erase()

        let result = try await erasedRegistration.invoke(
            parameters: fixture.parameters(handle: "pane:1", correlationId: correlationId),
            connectionContext: fixture.connectionContext,
            targetResolutionTools: .init(canonicalizePaneHandle: { rawHandle in
                #expect(rawHandle == "pane:1")
                await recorder.record(.canonicalizeTarget)
                return canonicalPaneHandle
            }),
            authorize: { principal, authorization in
                await recorder.record(.authorize)
                #expect(principal == fixture.principal)
                #expect(authorization.methodName == "fixture.typedMutation")
                #expect(authorization.requiredPrivileges == [.layoutMutate])
                #expect(authorization.dataScope == .paneContext)
                #expect(authorization.target == .pane(canonicalPaneId.uuidString))
            }
        )

        #expect(
            result
                == .object([
                    "disposition": .string("applied"),
                    "canonicalHandle": .string("pane:\(canonicalPaneId.uuidString)"),
                ])
        )
        #expect(
            await recorder.snapshot()
                == [
                    .resolveTarget,
                    .canonicalizeTarget,
                    .authorize,
                    .handler(
                        parameters: .init(
                            handle: "pane:\(canonicalPaneId.uuidString)",
                            correlationId: correlationId
                        ),
                        principal: fixture.principal,
                        target: .pane(canonicalPaneId.uuidString)
                    ),
                ]
        )
    }

    @Test("schema failures have no target, authorization, or handler effects")
    func schemaFailuresHaveNoEffects() async throws {
        let fixture = TypedRegistrationFixture()
        let correlationId = UUIDv7.generate()
        let invalidParameters: [JSONValue] = [
            .object(["handle": .string("pane:1")]),
            .object([
                "handle": .string("pane:1"),
                "correlationId": .string("not-a-uuid"),
            ]),
            .object([
                "handle": .string("pane:1"),
                "correlationId": .string(correlationId.uuidString),
                "privateCallerField": .string("must-not-cross-the-boundary"),
            ]),
        ]

        for parameters in invalidParameters {
            let recorder = TypedRegistrationRecorder()
            let erasedRegistration = try makeRegistration(recorder: recorder).erase()

            await #expect(throws: IPCSchemaValidationError.self) {
                try await erasedRegistration.invoke(
                    parameters: parameters,
                    connectionContext: fixture.connectionContext,
                    targetResolutionTools: fixture.unusedTargetResolutionTools,
                    authorize: { _, _ in await recorder.record(.authorize) }
                )
            }
            #expect(await recorder.snapshot().isEmpty)
        }
    }

    @Test("a typed correlation extractor must agree with normalized parameters")
    func correlationExtractorMustAgreeWithNormalizedParameters() async throws {
        let fixture = TypedRegistrationFixture()
        let correlationId = UUIDv7.generate()
        let recorder = TypedRegistrationRecorder()
        let registration = try makeRegistration(
            recorder: recorder,
            correlation: .required { _ in UUIDv7.generate() }
        )
        let erasedRegistration = try registration.erase()

        await #expect(throws: AppIPCTypedMethodRegistrationError.self) {
            try await erasedRegistration.invoke(
                parameters: fixture.parameters(handle: "pane:1", correlationId: correlationId),
                connectionContext: fixture.connectionContext,
                targetResolutionTools: fixture.targetResolutionTools,
                authorize: { _, _ in await recorder.record(.authorize) }
            )
        }
        #expect(await recorder.snapshot().isEmpty)
    }

    @Test("checked correlation extraction can reject without downstream effects")
    func checkedCorrelationExtractionCanRejectWithoutEffects() async throws {
        let fixture = TypedRegistrationFixture()
        let recorder = TypedRegistrationRecorder()
        let registration = try makeRegistration(
            recorder: recorder,
            correlation: .required { _ in
                throw AppIPCTypedMethodRegistrationError.correlationMismatch
            }
        )
        let erasedRegistration = try registration.erase()

        await #expect(throws: AppIPCTypedMethodRegistrationError.correlationMismatch) {
            try await erasedRegistration.invoke(
                parameters: fixture.parameters(handle: "pane:1", correlationId: UUIDv7.generate()),
                connectionContext: fixture.connectionContext,
                targetResolutionTools: fixture.targetResolutionTools,
                authorize: { _, _ in await recorder.record(.authorize) }
            )
        }
        #expect(await recorder.snapshot().isEmpty)
    }

    @Test("target canonicalization cannot replace the normalized wire correlation")
    func targetCanonicalizationCannotReplaceCorrelation() async throws {
        let fixture = TypedRegistrationFixture()
        let recorder = TypedRegistrationRecorder()
        let registration = try makeRegistration(
            recorder: recorder,
            resolveTarget: { parameters, _, _ in
                await recorder.record(.resolveTarget)
                let canonicalPaneId = UUIDv7.generate()
                return AppIPCTargetResolution(
                    parameters: TypedRegistrationParameters(
                        handle: parameters.handle,
                        correlationId: UUIDv7.generate()
                    ),
                    canonicalHandle: IPCHandle(
                        kind: .pane,
                        reference: .canonicalUUID(canonicalPaneId)
                    ),
                    target: .pane(canonicalPaneId.uuidString)
                )
            }
        )
        let erasedRegistration = try registration.erase()

        await #expect(throws: AppIPCTypedMethodRegistrationError.self) {
            try await erasedRegistration.invoke(
                parameters: fixture.parameters(
                    handle: "pane:1", correlationId: UUIDv7.generate()),
                connectionContext: fixture.connectionContext,
                targetResolutionTools: fixture.targetResolutionTools,
                authorize: { _, _ in await recorder.record(.authorize) }
            )
        }
        #expect(await recorder.snapshot() == [.resolveTarget])
    }

    @Test("a resolved target outside descriptor kinds is rejected before authorization")
    func disallowedResolvedTargetKindIsRejectedBeforeAuthorization() async throws {
        let fixture = TypedRegistrationFixture()
        let recorder = TypedRegistrationRecorder()
        let workspaceId = UUIDv7.generate()
        let canonicalWorkspaceHandle = IPCHandle(
            kind: .workspace,
            reference: .canonicalUUID(workspaceId)
        )
        let registration = try makeRegistration(
            recorder: recorder,
            resolveTarget: { parameters, _, _ in
                await recorder.record(.resolveTarget)
                return AppIPCTargetResolution(
                    parameters: parameters,
                    canonicalHandle: canonicalWorkspaceHandle,
                    target: .workspace(workspaceId)
                )
            }
        )
        let erasedRegistration = try registration.erase()

        await #expect(throws: AppIPCTypedMethodRegistrationError.self) {
            try await erasedRegistration.invoke(
                parameters: fixture.parameters(
                    handle: "pane:1", correlationId: UUIDv7.generate()),
                connectionContext: fixture.connectionContext,
                targetResolutionTools: fixture.targetResolutionTools,
                authorize: { _, _ in await recorder.record(.authorize) }
            )
        }
        #expect(await recorder.snapshot() == [.resolveTarget])
    }

    @Test("a canonical repo target can authorize against its owning workspace scope")
    func canonicalRepoTargetUsesWorkspaceAuthorizationScope() async throws {
        let fixture = TypedRegistrationFixture()
        let correlationId = UUIDv7.generate()
        let repositoryId = UUIDv7.generate()
        let workspaceId = UUIDv7.generate()
        let canonicalRepositoryHandle = IPCHandle(
            kind: .repo,
            reference: .canonicalUUID(repositoryId)
        )
        let recorder = TypedRegistrationRecorder()
        let registration = try makeRegistration(
            recorder: recorder,
            descriptor: TypedRegistrationFixture.descriptor(allowedTargetKinds: [.repo]),
            resolveTarget: { parameters, _, _ in
                await recorder.record(.resolveTarget)
                return AppIPCTargetResolution(
                    parameters: TypedRegistrationParameters(
                        handle: "repo:\(repositoryId.uuidString)",
                        correlationId: parameters.correlationId
                    ),
                    canonicalHandle: canonicalRepositoryHandle,
                    target: .workspace(workspaceId)
                )
            }
        )
        let erasedRegistration = try registration.erase()

        let result = try await erasedRegistration.invoke(
            parameters: fixture.parameters(handle: "repo:1", correlationId: correlationId),
            connectionContext: fixture.connectionContext,
            targetResolutionTools: fixture.unusedTargetResolutionTools,
            authorize: { _, authorization in
                await recorder.record(.authorize)
                #expect(authorization.target == .workspace(workspaceId))
            }
        )

        #expect(
            result
                == .object([
                    "disposition": .string("applied"),
                    "canonicalHandle": .string("repo:\(repositoryId.uuidString)"),
                ])
        )
        #expect(
            await recorder.snapshot()
                == [
                    .resolveTarget,
                    .authorize,
                    .handler(
                        parameters: .init(
                            handle: "repo:\(repositoryId.uuidString)",
                            correlationId: correlationId
                        ),
                        principal: fixture.principal,
                        target: .workspace(workspaceId)
                    ),
                ]
        )
    }

    @Test("unresolved self and ordinal selectors cannot satisfy a canonical target kind")
    func unresolvedSelectorsAreRejectedBeforeAuthorization() async throws {
        let fixture = TypedRegistrationFixture()
        let correlationId = UUIDv7.generate()
        let unresolvedTargets: [(canonicalHandle: IPCHandle?, scope: IPCTargetScope)] = [
            (nil, .selfPane),
            (
                IPCHandle(kind: .pane, reference: .friendlyOrdinal(1)),
                .pane(UUIDv7.generate().uuidString)
            ),
        ]

        for unresolvedTarget in unresolvedTargets {
            let recorder = TypedRegistrationRecorder()
            let registration = try makeRegistration(
                recorder: recorder,
                resolveTarget: { parameters, _, _ in
                    await recorder.record(.resolveTarget)
                    return AppIPCTargetResolution(
                        parameters: parameters,
                        canonicalHandle: unresolvedTarget.canonicalHandle,
                        target: unresolvedTarget.scope
                    )
                }
            )
            let erasedRegistration = try registration.erase()

            await #expect(throws: AppIPCTypedMethodRegistrationError.self) {
                try await erasedRegistration.invoke(
                    parameters: fixture.parameters(handle: "pane:1", correlationId: correlationId),
                    connectionContext: fixture.connectionContext,
                    targetResolutionTools: fixture.unusedTargetResolutionTools,
                    authorize: { _, _ in await recorder.record(.authorize) }
                )
            }
            #expect(await recorder.snapshot() == [.resolveTarget])
        }
    }

    @Test("erased registration retains metadata from its generic descriptor")
    func erasedRegistrationRetainsGenericDescriptorMetadata() throws {
        let recorder = TypedRegistrationRecorder()
        let descriptor = try TypedRegistrationFixture.descriptor()
        let erasedRegistration = try makeRegistration(
            recorder: recorder,
            descriptor: descriptor
        ).erase()

        #expect(erasedRegistration.descriptor.metadata.name == descriptor.name)
        #expect(
            erasedRegistration.descriptor.metadata.parameterSchema
                == descriptor.contract.parameterSchema
        )
        #expect(
            erasedRegistration.descriptor.metadata.resultSchema
                == descriptor.contract.resultSchema
        )
    }

    @Test("authorization denial prevents the typed handler")
    func authorizationDenialPreventsHandler() async throws {
        let fixture = TypedRegistrationFixture()
        let recorder = TypedRegistrationRecorder()
        let erasedRegistration = try makeRegistration(recorder: recorder).erase()

        await #expect(throws: TypedRegistrationAuthorizationDenied.self) {
            try await erasedRegistration.invoke(
                parameters: fixture.parameters(
                    handle: "pane:1", correlationId: UUIDv7.generate()),
                connectionContext: fixture.connectionContext,
                targetResolutionTools: fixture.targetResolutionTools,
                authorize: { _, _ in
                    await recorder.record(.authorize)
                    throw TypedRegistrationAuthorizationDenied()
                }
            )
        }
        #expect(await recorder.snapshot() == [.resolveTarget, .authorize])
    }

    @Test("resolved additional authority is checked before any command effect")
    func additionalAuthorityPrecedesHandler() async throws {
        let fixture = TypedRegistrationFixture()
        let recorder = TypedRegistrationRecorder()
        let paneId = UUIDv7.generate()
        let additionalScope = IPCPermissionScope(
            privilege: .sidebarStateMutate, target: .workspace(UUIDv7.generate()), dataScope: .sidebarState)
        let registration = try makeRegistration(
            recorder: recorder,
            resolveTarget: { parameters, _, _ in
                await recorder.record(.resolveTarget)
                return AppIPCTargetResolution(
                    parameters: parameters,
                    canonicalHandle: IPCHandle(kind: .pane, reference: .canonicalUUID(paneId)),
                    target: .pane(paneId.uuidString), requiredScopes: [additionalScope])
            }
        ).erase()

        await #expect(throws: TypedRegistrationAuthorizationDenied.self) {
            try await registration.invoke(
                parameters: fixture.parameters(handle: "pane:1", correlationId: UUIDv7.generate()),
                connectionContext: fixture.connectionContext,
                targetResolutionTools: fixture.unusedTargetResolutionTools,
                authorize: { _, request in
                    await recorder.record(.authorize)
                    #expect(request.requiredPrivileges == [.layoutMutate])
                    #expect(request.additionalScopes == [additionalScope])
                    throw TypedRegistrationAuthorizationDenied()
                })
        }
        #expect(await recorder.snapshot() == [.resolveTarget, .authorize])
    }

    @Test("a typed result that violates the descriptor schema is never returned")
    func invalidTypedResultIsRejected() async throws {
        let fixture = TypedRegistrationFixture()
        let recorder = TypedRegistrationRecorder()
        let registration = try makeRegistration(
            recorder: recorder,
            disposition: "caller-private-result"
        )
        let erasedRegistration = try registration.erase()

        await #expect(throws: IPCSchemaValidationError.self) {
            try await erasedRegistration.invoke(
                parameters: fixture.parameters(
                    handle: "pane:1", correlationId: UUIDv7.generate()),
                connectionContext: fixture.connectionContext,
                targetResolutionTools: fixture.targetResolutionTools,
                authorize: { _, _ in await recorder.record(.authorize) }
            )
        }
        let stages = await recorder.snapshot()
        #expect(stages.count == 3)
        #expect(stages[0] == .resolveTarget)
        #expect(stages[1] == .authorize)
        guard case .handler = stages[2] else {
            Issue.record("Expected descriptor result validation after the typed handler")
            return
        }
    }

    private func makeRegistration(
        recorder: TypedRegistrationRecorder,
        correlation: AppIPCCorrelation<TypedRegistrationParameters> = .required(\.correlationId),
        descriptor: IPCMethodDescriptor<TypedRegistrationParameters, TypedRegistrationResult>? = nil,
        resolveTarget: (
            @Sendable (
                TypedRegistrationParameters,
                AppIPCConnectionContext,
                AppIPCTargetResolutionTools
            ) async throws -> AppIPCTargetResolution<TypedRegistrationParameters>
        )? = nil,
        disposition: String = "applied"
    ) throws -> AppIPCTypedMethodRegistration<TypedRegistrationParameters, TypedRegistrationResult> {
        let resolvedTarget =
            resolveTarget ?? { parameters, _, tools in
                await recorder.record(.resolveTarget)
                let canonicalHandle = try await tools.canonicalizePaneHandle(parameters.handle)
                guard case .canonicalUUID(let paneId) = canonicalHandle.reference else {
                    throw IPCHandleError.targetNotFound
                }
                let canonicalParameters = TypedRegistrationParameters(
                    handle: "pane:\(paneId.uuidString)",
                    correlationId: parameters.correlationId
                )
                return AppIPCTargetResolution(
                    parameters: canonicalParameters,
                    canonicalHandle: canonicalHandle,
                    target: .pane(paneId.uuidString)
                )
            }

        return AppIPCTypedMethodRegistration(
            descriptorRepresentations: try IPCMethodDescriptorRepresentations(
                typedDescriptor: try descriptor ?? TypedRegistrationFixture.descriptor()
            ),
            correlation: correlation,
            resolveTarget: resolvedTarget,
            connectionHandler: { parameters, context, target in
                guard let principal = context.principal else {
                    throw AppIPCTypedMethodRegistrationError.authenticationRequired
                }
                await recorder.record(
                    .handler(parameters: parameters, principal: principal, target: target)
                )
                return TypedRegistrationResult(
                    disposition: disposition,
                    canonicalHandle: parameters.handle
                )
            }
        )
    }
}

private struct TypedRegistrationFixture {
    let principal = IPCPrincipal(
        principalId: UUIDv7.generate(),
        runtimeId: UUIDv7.generate(),
        accessMode: .agentStudioOnly,
        kind: .spawnedPaneAgent(boundPaneId: "fixture-pane", boundWorkspaceId: nil),
        approvalAuthority: .noApprovalAuthority
    )

    var connectionContext: AppIPCConnectionContext {
        AppIPCConnectionContext(
            contextId: UUIDv7.generate(),
            channel: .stable,
            authenticatedContext: AgentStudioIPCAuthenticatedContext(
                principal: principal,
                credentialIdentity: .pane(recordID: UUIDv7.generate())
            ),
            authenticate: { _ in .unauthenticated },
            authenticationStatus: { .unauthenticated },
            eventSubscriber: TypedConnectionRecordingEventSubscriber()
        )
    }

    static func descriptor(
        allowedTargetKinds: Set<IPCHandleKind> = [.pane]
    ) throws
        -> IPCMethodDescriptor<TypedRegistrationParameters, TypedRegistrationResult>
    {
        try IPCMethodDescriptor(
            name: "fixture.typedMutation",
            description: "Exercise the typed request registration boundary.",
            examples: [],
            exposure: .allChannels,
            requiredPrivileges: [.layoutMutate],
            dataScope: .paneContext,
            allowedTargetKinds: allowedTargetKinds,
            commandRelationship: .noInteractiveIdentity,
            executionOwner: .workspaceAction,
            principalAvailability: .authenticated,
            resultSemantics: .applied,
            documentedErrors: [
                .init(
                    reason: "invalidParams",
                    description: "A declared parameter is missing or invalid."
                )
            ],
            isMutating: true,
            correlationPolicy: .required
        )
    }

    func parameters(handle: String, correlationId: UUID) -> JSONValue {
        .object([
            "handle": .string(handle),
            "correlationId": .string(correlationId.uuidString),
        ])
    }

    var targetResolutionTools: AppIPCTargetResolutionTools {
        .init(canonicalizePaneHandle: { rawHandle in
            let parsed = try IPCHandle.parse(rawHandle)
            guard parsed.kind == .pane else { throw IPCHandleError.invalidHandle }
            switch parsed.reference {
            case .canonicalUUID:
                return parsed
            case .friendlyOrdinal:
                return IPCHandle(
                    kind: .pane,
                    reference: .canonicalUUID(UUIDv7.generate())
                )
            }
        })
    }

    var unusedTargetResolutionTools: AppIPCTargetResolutionTools {
        .init(canonicalizePaneHandle: { _ in
            Issue.record("Schema rejection must happen before target tools are called")
            throw IPCHandleError.targetNotFound
        })
    }
}

private struct TypedRegistrationParameters: Codable, Equatable, Sendable, IPCSchemaProviding {
    let handle: String
    let correlationId: UUID

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "handle",
                description: "Pane handle to canonicalize before authorization",
                schema: .string(minimumLength: 1)
            ),
            .init(
                name: "correlationId",
                description: "Logical mutation identity",
                schema: IPCSchemaScalars.uuid
            ),
        ])
    }
}

private struct TypedRegistrationResult: Codable, Equatable, Sendable, IPCSchemaProviding {
    let disposition: String
    let canonicalHandle: String

    static func ipcSchema() throws -> IPCJSONSchema {
        .object(fields: [
            .init(
                name: "disposition",
                description: "Applied result discriminator",
                schema: .string(allowedValues: ["applied"])
            ),
            .init(
                name: "canonicalHandle",
                description: "Canonical pane handle received by the typed handler",
                schema: .string(minimumLength: 1)
            ),
        ])
    }
}

private struct TypedRegistrationAuthorizationDenied: Error {}

private actor TypedRegistrationRecorder {
    private var stages: [TypedRegistrationStage] = []

    func record(_ stage: TypedRegistrationStage) {
        stages.append(stage)
    }

    func snapshot() -> [TypedRegistrationStage] {
        stages
    }
}

private enum TypedRegistrationStage: Equatable, Sendable {
    case resolveTarget
    case canonicalizeTarget
    case authorize
    case handler(
        parameters: TypedRegistrationParameters,
        principal: IPCPrincipal,
        target: IPCTargetScope
    )
}
