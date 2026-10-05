import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestSupport
import Foundation
import Testing

@MainActor
@Suite("App IPC raw command adapter", .serialized)
struct AppIPCRawCommandAdapterTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("raw arguments use the real command spec and existing typed owner")
    func rawArgumentsReachTypedOwner() async throws {
        let harness = CommandAdapterHarness()
        let probe = RawCommandAuthorizationProbe()
        let registration = try await makeRegistration(harness: harness)
        let correlationId = UUIDv7.generate()
        let result = try await invoke(
            registration, harness: harness, options: .init(correlationId: correlationId, probe: probe))

        #expect(result.commandId.rawValue == "showReposSidebar")
        #expect(result.correlationId == correlationId)
        #expect(
            rawCommandOwnerArguments(from: harness) == [.workspaceWindow(.init(workspaceWindowId: harness.windowId))])
        let authorizations = await probe.requests
        #expect(authorizations.count == 1)
        #expect(authorizations.first?.target == .workspace(harness.workspaceStore.identityAtom.workspaceId))
        #expect(authorizations.first?.additionalScopes.contains { $0.privilege == .sidebarStateMutate } == true)
    }

    @Test(
        "app argument corrections occur before authorization and owner effects",
        arguments: ["invalid", "missing", "unknownField", "unknownCommand"])
    func correctionsPrecedeAuthorization(scenario: String) async throws {
        let harness = CommandAdapterHarness()
        let probe = RawCommandAuthorizationProbe()
        let registration = try await makeRegistration(harness: harness)
        // A successful raw call in this fixture makes the negative non-vacuous.
        _ = try await invoke(
            registration, harness: harness, options: .init(correlationId: UUIDv7.generate(), probe: probe))
        let knownIDs = try await makeIPCCommandCompositionOffMain(from: harness.adapter).commands.map { $0.id.rawValue }
        let sent = scenario == "unknownCommand" ? "showReposSidebaq" : "showReposSidebar"
        var raw = ["workspaceWindowId": harness.windowId.uuidString]
        let expectedField: String
        switch scenario {
        case "invalid":
            raw["workspaceWindowId"] = "not-a-uuid"
            expectedField = "workspaceWindowId"
        case "missing":
            raw = [:]
            expectedField = "workspaceWindowId"
        case "unknownField":
            raw["surprise"] = "value"
            expectedField = "surprise"
        default:
            raw = [:]
            expectedField = "commandId"
        }
        let failure: AgentStudioAppIPCRequestError?
        do {
            _ = try await invoke(
                registration, harness: harness,
                options: .init(correlationId: UUIDv7.generate(), probe: probe, commandId: sent, arguments: raw))
            failure = nil
        } catch let requestError as AgentStudioAppIPCRequestError {
            failure = requestError
        } catch {
            Issue.record(error, "App prepare must produce its typed request-error correction")
            failure = nil
        }
        let requestError = try #require(failure)
        guard case .object(let fields) = requestError.data else {
            Issue.record("App prepare error must preserve correction data")
            return
        }
        if scenario == "unknownCommand" {
            // Existing table: AgentStudioAppIPCRequestError.swift:235-240 uses -32003.
            #expect(requestError.code == -32_003)
            #expect(fields["reason"] == .string("unknownCommand"))
            #expect(fields["commandId"] == .string(sent))
            guard case .array(let matches) = fields["closestMatches"] else {
                Issue.record("unknownCommand must include bounded visible matches")
                return
            }
            #expect(matches.contains(.string("showReposSidebar")))
            #expect(matches.count <= 5)
            #expect(
                matches.allSatisfy {
                    if case .string(let name) = $0 { return knownIDs.contains(name) }
                    return false
                })
        } else {
            #expect(requestError.code == -32_602)
            #expect(fields["reason"] == .string("invalidArguments"))
            #expect(fields["fieldPath"] == .string("$.arguments.\(expectedField)"))
            guard case .string(let expected) = fields["expected"] else {
                Issue.record("invalidArguments must carry expected text")
                return
            }
            #expect(!expected.isEmpty)
        }
        #expect(await probe.requests.count == 1)
        #expect(rawCommandOwnerArguments(from: harness).count == 1)
    }

    @Test("authorization refusal leaves the typed owner unchanged after raw preparation")
    func authorizationRefusalPreventsEffect() async throws {
        let harness = CommandAdapterHarness()
        let probe = RawCommandAuthorizationProbe()
        let registration = try await makeRegistration(harness: harness)
        _ = try await invoke(
            registration, harness: harness, options: .init(correlationId: UUIDv7.generate(), probe: probe))

        await #expect(throws: RawCommandAuthorizationDenied.self) {
            try await invoke(
                registration, harness: harness,
                options: .init(correlationId: UUIDv7.generate(), probe: probe, refusesAuthorization: true))
        }
        #expect(await probe.requests.count == 2)
        #expect(rawCommandOwnerArguments(from: harness).count == 1)
    }

    @Test("preparation cannot change wire correlation before authorization")
    func preparedCorrelationMustMatchWire() async throws {
        let harness = CommandAdapterHarness()
        let probe = RawCommandAuthorizationProbe()
        let normal = try await makeRegistration(harness: harness)
        _ = try await invoke(normal, harness: harness, options: .init(correlationId: UUIDv7.generate(), probe: probe))
        let corrupt = try await makeRegistration(harness: harness, corruptsCorrelation: true)

        let failure: AppIPCTypedMethodRegistrationError?
        do {
            _ = try await invoke(
                corrupt, harness: harness, options: .init(correlationId: UUIDv7.generate(), probe: probe))
            failure = nil
        } catch let registrationError as AppIPCTypedMethodRegistrationError {
            failure = registrationError
        } catch {
            Issue.record(error, "Changed prepared correlation must fail its exact validation")
            failure = nil
        }
        #expect(failure == .correlationMismatch)
        #expect(await probe.requests.count == 1)
        #expect(rawCommandOwnerArguments(from: harness).count == 1)
    }

    @Test("unauthenticated calls fail before raw preparation or authorization")
    func unauthenticatedCallCannotPrepare() async throws {
        let harness = CommandAdapterHarness()
        let probe = RawCommandAuthorizationProbe()
        let registration = try await makeRegistration(harness: harness)
        _ = try await invoke(
            registration, harness: harness, options: .init(correlationId: UUIDv7.generate(), probe: probe))
        let failure: AppIPCTypedMethodRegistrationError?
        do {
            _ = try await invoke(
                registration, harness: harness,
                options: .init(
                    correlationId: UUIDv7.generate(), probe: probe, arguments: ["workspaceWindowId": "invalid"],
                    authenticated: false))
            failure = nil
        } catch let registrationError as AppIPCTypedMethodRegistrationError {
            failure = registrationError
        } catch {
            Issue.record(error, "Unauthenticated intake must precede raw argument parsing")
            failure = nil
        }
        #expect(failure == .authenticationRequired)
        #expect(await probe.requests.count == 1)
        #expect(rawCommandOwnerArguments(from: harness).count == 1)
    }

    private func makeRegistration(harness: CommandAdapterHarness, corruptsCorrelation: Bool = false) async throws
        -> AnyAppIPCMethodRegistration
    {
        let composition = try await makeIPCCommandCompositionOffMain(from: harness.adapter)
        let base: any AppIPCCommandPort = harness.adapter
        let port: any AppIPCCommandPort = corruptsCorrelation ? CorruptingRawPreparedCommandPort(base: base) : base
        return try #require(
            AppIPCCommandMethodRegistrations.make(composition: composition, port: port).first {
                $0.descriptor.metadata.name == "command.execute"
            })
    }

    private struct InvocationOptions {
        let correlationId: UUID
        let probe: RawCommandAuthorizationProbe
        var commandId = "showReposSidebar"
        var arguments: [String: String]?
        var refusesAuthorization = false
        var authenticated = true
    }

    private func invoke(
        _ registration: AnyAppIPCMethodRegistration, harness: CommandAdapterHarness,
        options: InvocationOptions
    ) async throws -> IPCCommandExecutionResult {
        let correlationId = options.correlationId
        let probe = options.probe
        let commandId = options.commandId
        let arguments = options.arguments
        let refusesAuthorization = options.refusesAuthorization
        let authenticated = options.authenticated
        let raw = arguments ?? ["workspaceWindowId": harness.windowId.uuidString]
        let value = JSONValue.object([
            "commandId": .string(commandId), "correlationId": .string(correlationId.uuidString),
            "arguments": .object(raw.mapValues(JSONValue.string)),
        ])
        let principal = commandAdapterTestPrincipal()
        let context = AppIPCConnectionContext(
            contextId: UUIDv7.generate(), channel: .stable,
            authenticatedContext: authenticated
                ? .init(principal: principal, credentialIdentity: .diagnostic(generationID: UUIDv7.generate())) : nil,
            authenticate: { _ in .unauthenticated }, authenticationStatus: { .unauthenticated },
            eventSubscriber: RawCommandUnusedEventSubscriber())
        let result = try await withRawCommandAdapterDispatcher(harness: harness) {
            try await registration.invoke(
                parameters: value, connectionContext: context,
                targetResolutionTools: .init(canonicalizePaneHandle: { _ in throw IPCHandleError.targetNotFound }),
                authorize: { _, request in
                    await probe.record(request)
                    if refusesAuthorization { throw RawCommandAuthorizationDenied() }
                })
        }
        let resultData: Data
        switch result {
        case .value(let value): resultData = try JSONEncoder().encode(value)
        case .encoded(let bytes): resultData = bytes
        }
        return try JSONDecoder().decode(IPCCommandExecutionResult.self, from: resultData)
    }
}

private actor RawCommandAuthorizationProbe {
    private(set) var requests: [AppIPCMethodAuthorizationRequest] = []
    func record(_ request: AppIPCMethodAuthorizationRequest) { requests.append(request) }
}

private struct RawCommandAuthorizationDenied: Error {}
private struct RawCommandUnusedEventSubscriber: IPCEventSubscriber {
    func deliver(_: String) async throws -> IPCEventDeliveryResult { .delivered }
}

@MainActor
private struct CorruptingRawPreparedCommandPort: AppIPCCommandPort {
    let base: any AppIPCCommandPort
    func prepareCommand(
        _ request: IPCRawCommandExecutionRequest, principal: IPCPrincipal, tools: AppIPCTargetResolutionTools
    ) async throws(AgentStudioAppIPCRequestError) -> AppIPCPreparedCommand {
        let prepared = try await base.prepareCommand(request, principal: principal, tools: tools)
        return AppIPCPreparedCommand(
            request: .init(
                commandId: prepared.request.commandId, correlationId: UUIDv7.generate(),
                arguments: prepared.request.arguments),
            canonicalHandle: prepared.canonicalHandle, target: prepared.target, requiredScopes: prepared.requiredScopes,
            resolvedPaneIds: prepared.resolvedPaneIds, agentArgumentRule: prepared.agentArgumentRule)
    }
    func executeCommand(_ request: IPCCommandExecutionRequest, ownPaneAssertion: AppIPCOwnPaneAssertion?) async throws
        -> IPCCommandExecutionResult
    {
        try await base.executeCommand(request, ownPaneAssertion: ownPaneAssertion)
    }
}
