import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("App IPC typed connection registration")
struct AppIPCTypedConnectionRegistrationTests {
    @Test("pre-authentication invocation accepts no principal and skips authority")
    func preAuthenticationInvocationSkipsAuthority() async throws {
        let fixture = TypedConnectionRegistrationFixture()
        let descriptor = try TypedConnectionRegistrationFixture.preAuthenticationDescriptor(
            name: "system.ping",
            parameters: IPCEmptyParams(),
            result: IPCSystemPingResult(runtimeId: fixture.runtimeId)
        )
        let registration = AppIPCTypedMethodRegistration(
            descriptorRepresentations: try IPCMethodDescriptorRepresentations(typedDescriptor: descriptor),
            correlation: AppIPCCorrelation<IPCEmptyParams>.notRequired,
            resolveTarget: { parameters, context, _ in
                #expect(context.principal == nil)
                return AppIPCTargetResolution(parameters: parameters, canonicalHandle: nil, target: .app)
            },
            connectionHandler: { _, context, target in
                #expect(context.contextId == fixture.contextId)
                #expect(context.channel == .stable)
                #expect(context.principal == nil)
                #expect(target == .app)
                return IPCSystemPingResult(runtimeId: fixture.runtimeId)
            }
        )

        let result = try await registration.erase().invoke(
            parameters: .object([:]),
            connectionContext: fixture.context(channel: .stable, principal: nil),
            targetResolutionTools: fixture.unusedTargetResolutionTools,
            authorize: { _, _ in
                Issue.record("Pre-authentication methods must not invoke authority")
                throw TypedConnectionRegistrationFailure()
            }
        )

        #expect(
            result
                == .object([
                    "ok": .bool(true),
                    "runtimeId": .string(fixture.runtimeId.uuidString),
                ])
        )
    }

    @Test("auth login receives typed parameters through the connection callback")
    func authLoginUsesTypedConnectionCallback() async throws {
        let fixture = TypedConnectionRegistrationFixture()
        let expectedPrincipal = fixture.panePrincipal
        let expectedStatus = IPCAuthStatusResult.authenticated(
            principalId: expectedPrincipal.principalId,
            runtimeId: expectedPrincipal.runtimeId,
            accessMode: expectedPrincipal.accessMode
        )
        let descriptor = try TypedConnectionRegistrationFixture.preAuthenticationDescriptor(
            name: "auth.login",
            parameters: IPCAuthLoginParams(token: "fixture-token"),
            result: expectedStatus
        )
        let registration = AppIPCTypedMethodRegistration(
            descriptorRepresentations: try IPCMethodDescriptorRepresentations(typedDescriptor: descriptor),
            correlation: AppIPCCorrelation<IPCAuthLoginParams>.notRequired,
            resolveTarget: { parameters, _, _ in
                AppIPCTargetResolution(parameters: parameters, canonicalHandle: nil, target: .app)
            },
            connectionHandler: { parameters, context, _ in
                try await context.authenticate(parameters)
            }
        )

        let result = try await registration.erase().invoke(
            parameters: .object(["token": .string("fixture-token")]),
            connectionContext: fixture.context(
                channel: .beta,
                principal: nil,
                authenticate: { parameters in
                    #expect(parameters.token == "fixture-token")
                    return expectedStatus
                }
            ),
            targetResolutionTools: fixture.unusedTargetResolutionTools,
            authorize: { _, _ in
                Issue.record("Authentication must not invoke grant authority")
                throw TypedConnectionRegistrationFailure()
            }
        )

        #expect(try decodeJSONValue(IPCAuthStatusResult.self, from: result) == expectedStatus)
    }

    @Test("auth status reads the connection-local principal snapshot callback")
    func authStatusUsesTypedConnectionCallback() async throws {
        let fixture = TypedConnectionRegistrationFixture()
        let expectedPrincipal = fixture.diagnosticPrincipal
        let expectedStatus = IPCAuthStatusResult.authenticated(
            principalId: expectedPrincipal.principalId,
            runtimeId: expectedPrincipal.runtimeId,
            accessMode: expectedPrincipal.accessMode
        )
        let descriptor = try TypedConnectionRegistrationFixture.preAuthenticationDescriptor(
            name: "auth.status",
            parameters: IPCEmptyParams(),
            result: expectedStatus
        )
        let registration = AppIPCTypedMethodRegistration(
            descriptorRepresentations: try IPCMethodDescriptorRepresentations(typedDescriptor: descriptor),
            correlation: AppIPCCorrelation<IPCEmptyParams>.notRequired,
            resolveTarget: { parameters, _, _ in
                AppIPCTargetResolution(parameters: parameters, canonicalHandle: nil, target: .app)
            },
            connectionHandler: { _, context, _ in
                context.authenticationStatus()
            }
        )

        let result = try await registration.erase().invoke(
            parameters: .object([:]),
            connectionContext: fixture.context(
                channel: .debug,
                principal: expectedPrincipal,
                authenticationStatus: { expectedStatus }
            ),
            targetResolutionTools: fixture.unusedTargetResolutionTools,
            authorize: { _, _ in
                Issue.record("Authentication status must not invoke grant authority")
                throw TypedConnectionRegistrationFailure()
            }
        )

        #expect(try decodeJSONValue(IPCAuthStatusResult.self, from: result) == expectedStatus)
    }

    @Test("authenticated registration rejects a missing principal before target resolution")
    func authenticatedRegistrationRejectsMissingPrincipal() async throws {
        let fixture = TypedConnectionRegistrationFixture()
        let recorder = TypedConnectionRegistrationRecorder()
        let registration = try authenticatedRegistration(fixture: fixture, recorder: recorder)

        await #expect(throws: AppIPCTypedMethodRegistrationError.authenticationRequired) {
            try await registration.erase().invoke(
                parameters: parameters(correlationId: UUIDv7.generate()),
                connectionContext: fixture.context(channel: .stable, principal: nil),
                targetResolutionTools: fixture.unusedTargetResolutionTools,
                authorize: { _, _ in
                    await recorder.record(.authorize(fixture.panePrincipal))
                }
            )
        }
        #expect(await recorder.snapshot().isEmpty)
    }

    @Test(
        "debug registration rejects stable and beta channels",
        arguments: [AgentStudioIPCChannel.stable, .beta]
    )
    func debugRegistrationRejectsNonDebugChannel(channel: AgentStudioIPCChannel) async throws {
        let fixture = TypedConnectionRegistrationFixture()
        let recorder = TypedConnectionRegistrationRecorder()
        let principal = fixture.diagnosticPrincipal
        let registration = try authenticatedRegistration(
            fixture: fixture,
            recorder: recorder,
            exposure: .debugTesting
        )

        await #expect(throws: AppIPCTypedMethodRegistrationError.methodNotExposed) {
            try await registration.erase().invoke(
                parameters: parameters(correlationId: UUIDv7.generate()),
                connectionContext: fixture.context(channel: channel, principal: principal),
                targetResolutionTools: fixture.unusedTargetResolutionTools,
                authorize: { _, _ in await recorder.record(.authorize(principal)) }
            )
        }
        #expect(await recorder.snapshot().isEmpty)
    }

    @Test("debug channel does not upgrade a pane principal to diagnostic authority")
    func debugRegistrationRejectsPanePrincipal() async throws {
        let fixture = TypedConnectionRegistrationFixture()
        let recorder = TypedConnectionRegistrationRecorder()
        let panePrincipal = fixture.panePrincipal
        let registration = try authenticatedRegistration(
            fixture: fixture,
            recorder: recorder,
            exposure: .debugTesting
        )

        await #expect(throws: AppIPCTypedMethodRegistrationError.methodNotExposed) {
            try await registration.erase().invoke(
                parameters: parameters(correlationId: UUIDv7.generate()),
                connectionContext: fixture.context(channel: .debug, principal: panePrincipal),
                targetResolutionTools: fixture.unusedTargetResolutionTools,
                authorize: { _, _ in await recorder.record(.authorize(panePrincipal)) }
            )
        }
        #expect(await recorder.snapshot().isEmpty)
    }

    @Test("debug registration admits the exact unsafe diagnostic pair")
    func debugRegistrationAcceptsUnsafeDiagnosticPair() async throws {
        let fixture = TypedConnectionRegistrationFixture()
        let recorder = TypedConnectionRegistrationRecorder()
        let principal = fixture.unsafeDebugPrincipal
        let correlationId = UUIDv7.generate()
        let registration = try authenticatedRegistration(
            fixture: fixture,
            recorder: recorder,
            exposure: .debugTesting
        )

        let result = try await registration.erase().invoke(
            parameters: parameters(correlationId: correlationId),
            connectionContext: fixture.context(channel: .debug, principal: principal),
            targetResolutionTools: fixture.canonicalPaneTargetResolutionTools(recorder: recorder),
            authorize: { authorizedPrincipal, _ in
                await recorder.record(.authorize(authorizedPrincipal))
            }
        )

        #expect(result == .object(["canonicalHandle": .string("pane:\(fixture.paneId.uuidString)")]))
        #expect(
            await recorder.snapshot().last
                == .handler(
                    contextId: fixture.contextId,
                    principal: principal,
                    target: .pane(fixture.paneId.uuidString)
                ))
    }

    @Test("debug registration rejects mixed and non-diagnostic principals before downstream effects")
    func debugRegistrationRejectsInvalidDiagnosticPairsBeforeEffects() async throws {
        let fixture = TypedConnectionRegistrationFixture()
        let rejectedPrincipals = [
            fixture.automationUnsafeHybridPrincipal,
            fixture.unsafeAutomationHybridPrincipal,
            fixture.panePrincipal,
            fixture.futureMCPPrincipal,
        ]

        for principal in rejectedPrincipals {
            let recorder = TypedConnectionRegistrationRecorder()
            let registration = try authenticatedRegistration(
                fixture: fixture,
                recorder: recorder,
                exposure: .debugTesting
            )

            await #expect(throws: AppIPCTypedMethodRegistrationError.methodNotExposed) {
                try await registration.erase().invoke(
                    parameters: parameters(correlationId: UUIDv7.generate()),
                    connectionContext: fixture.context(channel: .debug, principal: principal),
                    targetResolutionTools: fixture.unusedTargetResolutionTools,
                    authorize: { authorizedPrincipal, _ in
                        await recorder.record(.authorize(authorizedPrincipal))
                    }
                )
            }
            #expect(await recorder.snapshot().isEmpty)
        }
    }

    @Test("diagnostic invocation retains schema correlation target authorization handler order")
    func diagnosticInvocationRetainsTypedBoundaryOrder() async throws {
        let fixture = TypedConnectionRegistrationFixture()
        let recorder = TypedConnectionRegistrationRecorder()
        let principal = fixture.diagnosticPrincipal
        let correlationId = UUIDv7.generate()
        let registration = try authenticatedRegistration(
            fixture: fixture,
            recorder: recorder,
            exposure: .debugTesting
        )

        let result = try await registration.erase().invoke(
            parameters: parameters(correlationId: correlationId),
            connectionContext: fixture.context(channel: .debug, principal: principal),
            targetResolutionTools: fixture.canonicalPaneTargetResolutionTools(recorder: recorder),
            authorize: { authorizedPrincipal, request in
                await recorder.record(.authorize(authorizedPrincipal))
                #expect(authorizedPrincipal == principal)
                #expect(request.requiredPrivileges == [.layoutMutate])
                #expect(request.dataScope == .paneContext)
                #expect(request.target == .pane(fixture.paneId.uuidString))
            }
        )

        #expect(result == .object(["canonicalHandle": .string("pane:\(fixture.paneId.uuidString)")]))
        #expect(
            await recorder.snapshot()
                == [
                    .resolveTarget,
                    .canonicalizeTarget,
                    .authorize(principal),
                    .handler(
                        contextId: fixture.contextId,
                        principal: principal,
                        target: .pane(fixture.paneId.uuidString)
                    ),
                ]
        )
    }

    @Test("connection handler receives its exact event subscriber")
    func connectionHandlerReceivesEventSubscriber() async throws {
        let fixture = TypedConnectionRegistrationFixture()
        let principal = fixture.panePrincipal
        let subscriber = TypedConnectionRecordingEventSubscriber()
        let registration = AppIPCTypedMethodRegistration(
            descriptorRepresentations: try IPCMethodDescriptorRepresentations(
                typedDescriptor: TypedConnectionRegistrationFixture.eventDescriptor()
            ),
            correlation: AppIPCCorrelation<TypedConnectionEventParameters>.notRequired,
            resolveTarget: { parameters, context, _ in
                #expect(context.contextId == fixture.contextId)
                return AppIPCTargetResolution(
                    parameters: parameters,
                    canonicalHandle: nil,
                    target: .pane(fixture.paneId.uuidString)
                )
            },
            connectionHandler: { _, context, _ in
                let disposition = try await context.eventSubscriber.deliver("fixture-event")
                #expect(disposition == .delivered)
                return TypedConnectionEventResult(delivered: true)
            }
        )

        let result = try await registration.erase().invoke(
            parameters: .object([:]),
            connectionContext: fixture.context(
                channel: .stable,
                principal: principal,
                eventSubscriber: subscriber
            ),
            targetResolutionTools: fixture.unusedTargetResolutionTools,
            authorize: { authorizedPrincipal, request in
                #expect(authorizedPrincipal == principal)
                #expect(request.dataScope == .permissionState)
            }
        )

        #expect(result == .object(["delivered": .bool(true)]))
        #expect(await subscriber.snapshot() == ["fixture-event"])
    }

    private func authenticatedRegistration(
        fixture: TypedConnectionRegistrationFixture,
        recorder: TypedConnectionRegistrationRecorder,
        exposure: IPCMethodExposure = .allChannels
    ) throws -> AppIPCTypedMethodRegistration<TypedConnectionParameters, TypedConnectionResult> {
        AppIPCTypedMethodRegistration(
            descriptorRepresentations: try IPCMethodDescriptorRepresentations(
                typedDescriptor: TypedConnectionRegistrationFixture.authenticatedDescriptor(exposure: exposure)
            ),
            correlation: .required(\.correlationId),
            resolveTarget: { parameters, context, tools in
                await recorder.record(.resolveTarget)
                let principal = try #require(context.principal)
                let canonicalHandle = try await tools.canonicalizePaneHandle(parameters.handle)
                guard case .canonicalUUID(let paneId) = canonicalHandle.reference else {
                    throw TypedConnectionRegistrationFailure()
                }
                #expect(paneId == fixture.paneId)
                #expect(principal.runtimeId == fixture.runtimeId)
                return AppIPCTargetResolution(
                    parameters: TypedConnectionParameters(
                        handle: "pane:\(paneId.uuidString)",
                        correlationId: parameters.correlationId
                    ),
                    canonicalHandle: canonicalHandle,
                    target: .pane(paneId.uuidString)
                )
            },
            connectionHandler: { parameters, context, target in
                let principal = try #require(context.principal)
                await recorder.record(
                    .handler(contextId: context.contextId, principal: principal, target: target)
                )
                return TypedConnectionResult(canonicalHandle: parameters.handle)
            }
        )
    }

    private func parameters(correlationId: UUID) -> JSONValue {
        .object([
            "handle": .string("pane:1"),
            "correlationId": .string(correlationId.uuidString),
        ])
    }
}
