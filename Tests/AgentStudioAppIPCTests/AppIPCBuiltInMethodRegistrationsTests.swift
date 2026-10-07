import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("App IPC built-in typed registrations")
struct AppIPCBuiltInMethodRegistrationsTests {
    @Test("factory binds every compiled built-in descriptor exactly once")
    func factoryBindsExactCompiledCatalog() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let catalog = try fixture.catalog
        let registrations = try fixture.registrations()
        let registrationMetadata = registrations.map(\.descriptor.metadata)
        let expectedMetadata = catalog.erasedDescriptors.map(\.metadata)

        #expect(registrations.count == 47)
        #expect(Set(registrationMetadata.map(\.name)).count == 47)
        #expect(registrationMetadata.map(\.name) == registrationMetadata.map(\.name).sorted())
        #expect(registrationMetadata == expectedMetadata)
        #expect(!registrationMetadata.map(\.name).contains("system.capabilities"))
        #expect(!registrationMetadata.map(\.name).contains("command.list"))
        #expect(!registrationMetadata.map(\.name).contains("command.execute"))
    }

    @Test("pane and drawer bindings forward canonical handles and required correlation")
    func paneAndDrawerBindingsCanonicalizeBeforeForwarding() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let principal = fixture.diagnosticPrincipal
        let targetRecorder = BuiltInTargetResolutionRecorder()
        let authorizationRecorder = BuiltInAuthorizationRecorder()
        let registrations = try fixture.registrations()
        let context = fixture.connectionContext(principal: principal)
        let tools = fixture.targetResolutionTools(recorder: targetRecorder)

        let splitResultValue = try await fixture.registration(named: "pane.split", in: registrations).invoke(
            parameters: fixture.jsonValue(
                IPCPaneSplitParams(
                    handle: "pane:1",
                    direction: .right,
                    correlationId: fixture.correlationId
                )
            ),
            connectionContext: context,
            targetResolutionTools: tools,
            authorize: { _, request in
                #expect(request.dataScope == .paneContext)
                await authorizationRecorder.record(request.target)
            }
        )
        let splitResult = try decodeJSONValue(IPCPaneSplitResult.self, from: splitResultValue)

        let drawerResultValue = try await fixture.registration(named: "drawer.toggle", in: registrations).invoke(
            parameters: fixture.jsonValue(
                IPCDrawerToggleParams(
                    parentPaneHandle: "pane:1",
                    correlationId: fixture.correlationId
                )
            ),
            connectionContext: context,
            targetResolutionTools: tools,
            authorize: { _, request in await authorizationRecorder.record(request.target) }
        )
        let drawerResult = try decodeJSONValue(IPCDrawerToggleResult.self, from: drawerResultValue)

        #expect(splitResult.targetPaneId == fixture.paneId)
        #expect(splitResult.correlationId == fixture.correlationId)
        #expect(drawerResult.parentPaneId == fixture.paneId)
        #expect(drawerResult.correlationId == fixture.correlationId)
        #expect(
            await authorizationRecorder.snapshot()
                == [.pane(fixture.paneId.uuidString), .pane(fixture.paneId.uuidString)]
        )
        #expect(await targetRecorder.snapshot() == ["pane:1", "pane:1"])
    }

    @Test("optional DTO correlation is checked before target resolution")
    func optionalDTOCorrelationRequiresWireValue() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let principal = fixture.diagnosticPrincipal
        let targetRecorder = BuiltInTargetResolutionRecorder()
        let registration = try fixture.registration(named: "pane.split", in: fixture.registrations())

        await #expect(throws: IPCSchemaValidationError.self) {
            try await registration.invoke(
                parameters: .object([
                    "handle": .string("pane:1"),
                    "direction": .string("right"),
                ]),
                connectionContext: fixture.connectionContext(principal: principal),
                targetResolutionTools: fixture.targetResolutionTools(recorder: targetRecorder),
                authorize: { _, _ in
                    Issue.record("Missing correlation must fail before authorization")
                }
            )
        }
        #expect(await targetRecorder.snapshot().isEmpty)
    }

    @Test("arrangements canonicalizes optional pane context while retaining window as primary target")
    func arrangementsCanonicalizesWindowAndOptionalPaneContext() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let principal = fixture.diagnosticPrincipal
        let targetRecorder = BuiltInTargetResolutionRecorder()
        let presentationPort = await MainActor.run {
            BuiltInRecordingUIPresentationPort(tabId: fixture.tabId, paneId: fixture.paneId)
        }
        let registrations = try fixture.registrations(uiPresentationPort: presentationPort)
        let registration = try fixture.registration(named: "ui.arrangements.open", in: registrations)

        let resultValue = try await registration.invoke(
            parameters: fixture.jsonValue(
                IPCArrangementsOpenParams(
                    workspaceWindowId: fixture.windowId,
                    targetPaneHandle: "self",
                    correlationId: fixture.correlationId
                )
            ),
            connectionContext: fixture.connectionContext(principal: principal),
            targetResolutionTools: fixture.targetResolutionTools(recorder: targetRecorder),
            authorize: { _, request in
                #expect(request.target == .app)
                #expect(request.dataScope == .uiSurface)
            }
        )
        let result = try decodeJSONValue(IPCArrangementsOpenResult.self, from: resultValue)
        let receivedParameters = await MainActor.run { presentationPort.arrangementsParameters }

        #expect(result.workspaceWindowId == fixture.windowId)
        #expect(result.correlationId == fixture.correlationId)
        #expect(receivedParameters.count == 1)
        #expect(receivedParameters.first?.workspaceWindowId == fixture.windowId)
        #expect(receivedParameters.first?.targetPaneHandle == "pane:\(fixture.paneId.uuidString)")
        #expect(receivedParameters.first?.correlationId == fixture.correlationId)
        #expect(await targetRecorder.snapshot() == ["self"])
    }

    @Test("pre-auth login and event subscription use typed connection callbacks")
    func connectionOwnedBindingsUseTypedContext() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let principal = fixture.diagnosticPrincipal
        let eventBroker = IPCEventBroker()
        let eventSubscriber = BuiltInRecordingEventSubscriber()
        let registrations = try fixture.registrations(eventBroker: eventBroker)
        let expectedStatus = IPCAuthStatusResult.authenticated(
            principalId: principal.principalId,
            runtimeId: principal.runtimeId,
            accessMode: principal.accessMode
        )
        let loginRegistration = try fixture.registration(named: "auth.login", in: registrations)

        let loginValue = try await loginRegistration.invoke(
            parameters: .object(["token": .string("fixture-token")]),
            connectionContext: fixture.connectionContext(
                principal: nil,
                channel: .stable,
                authenticate: { parameters in
                    #expect(parameters.token == "fixture-token")
                    return expectedStatus
                }
            ),
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { _, _ in
                Issue.record("Pre-authentication login must skip grant authorization")
            }
        )
        #expect(try decodeJSONValue(IPCAuthStatusResult.self, from: loginValue) == expectedStatus)

        let subscribeRegistration = try fixture.registration(named: "events.subscribe", in: registrations)
        let subscriptionValue = try await subscribeRegistration.invoke(
            parameters: fixture.jsonValue(
                IPCEventsSubscribeParams(
                    eventNames: [.terminalCommandFinished],
                    correlationId: fixture.correlationId
                )
            ),
            connectionContext: fixture.connectionContext(
                principal: principal,
                channel: .stable,
                subscriber: eventSubscriber
            ),
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { authorizedPrincipal, request in
                #expect(authorizedPrincipal == principal)
                #expect(request.dataScope == .permissionState)
            }
        )
        let subscription = try decodeJSONValue(IPCEventSubscriptionResult.self, from: subscriptionValue)

        #expect(subscription.eventNames == [.terminalCommandFinished])
        #expect(await eventBroker.subscriptionCount() == 1)
    }

    @Test("Bridge target kind is checked before port effect and accepted refresh publishes an event")
    func bridgeBindingValidatesKindAndPublishesAcceptedEvent() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let principal = fixture.diagnosticPrincipal
        let bridgePane = fixture.paneSummary(contentKind: .bridgePanel)
        let eventBroker = IPCEventBroker()
        let eventSubscriber = BuiltInRecordingEventSubscriber()
        _ = try await eventBroker.subscribe(
            eventNames: [.bridgeReviewUpdated],
            principal: principal,
            connectionId: fixture.connectionId,
            subscriber: eventSubscriber
        )
        let registrations = try fixture.registrations(
            queryPort: FakeQueryPort(panes: [bridgePane]),
            bridgePort: FakeBridgePort(paneId: fixture.paneId),
            eventBroker: eventBroker
        )
        let refreshRegistration = try fixture.registration(named: "bridge.diff.refresh", in: registrations)

        _ = try await refreshRegistration.invoke(
            parameters: fixture.jsonValue(
                IPCBridgeReviewRefreshParams(
                    handle: "pane:1",
                    correlationId: fixture.correlationId
                )
            ),
            connectionContext: fixture.connectionContext(principal: principal),
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { _, request in
                #expect(request.target == .pane(fixture.paneId.uuidString))
                #expect(request.dataScope == .bridgeReviewPackage)
            }
        )
        #expect((await eventSubscriber.snapshot()).count == 1)

        let nonBridgeRegistrations = try fixture.registrations(
            queryPort: FakeQueryPort(panes: [fixture.paneSummary(contentKind: .terminal)]),
            bridgePort: FakeBridgePort(paneId: fixture.paneId)
        )
        let nonBridgeRefresh = try fixture.registration(
            named: "bridge.diff.refresh",
            in: nonBridgeRegistrations
        )
        await #expect(throws: AppIPCBridgeError.self) {
            try await nonBridgeRefresh.invoke(
                parameters: fixture.jsonValue(
                    IPCBridgeReviewRefreshParams(
                        handle: "pane:1",
                        correlationId: fixture.correlationId
                    )
                ),
                connectionContext: fixture.connectionContext(principal: principal),
                targetResolutionTools: fixture.targetResolutionTools(),
                authorize: { _, _ in
                    Issue.record("Wrong Bridge kind must fail before authorization")
                }
            )
        }
    }

    @Test("terminal wait converts bounded seconds and preserves sequence semantics")
    func terminalWaitConvertsDurationAndPreservesSequence() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let principal = fixture.diagnosticPrincipal
        let runtimePort = await MainActor.run { BuiltInRecordingTerminalWaitPort(paneId: fixture.paneId) }
        let registrations = try fixture.registrations(runtimePort: runtimePort)
        let registration = try fixture.registration(named: "terminal.wait", in: registrations)

        let resultValue = try await registration.invoke(
            parameters: fixture.jsonValue(
                IPCTerminalWaitParams(
                    handle: "pane:1",
                    condition: .titleChanged,
                    timeoutSeconds: 1.25,
                    afterSequence: 42
                )
            ),
            connectionContext: fixture.connectionContext(principal: principal),
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { _, request in
                #expect(request.target == .pane(fixture.paneId.uuidString))
                #expect(request.dataScope == .terminalWait)
            }
        )
        let receipt = try decodeJSONValue(IPCTerminalWaitResponse.self, from: resultValue)
        let result = receipt.observation
        #expect(receipt.timeoutSeconds == 1.25)
        #expect(receipt.wasClamped == false)
        let invocation = await MainActor.run { runtimePort.invocation }

        #expect(result.paneId == fixture.paneId)
        #expect(invocation.handle == IPCHandle(kind: .pane, reference: .canonicalUUID(fixture.paneId)))
        #expect(invocation.timeout == .milliseconds(1250))
        #expect(invocation.afterSequence == 42)
    }
}
