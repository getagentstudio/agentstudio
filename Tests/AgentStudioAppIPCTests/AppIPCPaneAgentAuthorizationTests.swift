import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

/// A1 admission for pane-bound agents: declared eligibility, then own-pane
/// membership of every resolved identity, then argument rules. The own-pane
/// port is a fixed table here; the App-backed port is proven end to end in the
/// App target.
@Suite("App IPC pane-agent authorization")
struct AppIPCPaneAgentAuthorizationTests {
    private let boundPaneId = UUIDv7.generate()
    private let childPaneId = UUIDv7.generate()
    private let otherPaneId = UUIDv7.generate()
    private let drawerTerminalId = UUIDv7.generate()

    @Test("an own-pane method admits the bound pane and its drawer children and names itself for anything else")
    func ownPaneMethodAdmitsOnlyTheOwnPane() async throws {
        let scenario = try makeScenario()

        try await scenario.authorize(boundPaneId, "terminal.send", paneIds: [boundPaneId])
        try await scenario.authorize(boundPaneId, "terminal.send", paneIds: [childPaneId])
        for paneIds in [[otherPaneId], [boundPaneId, otherPaneId], []] {
            let refusal = try await scenario.refusal(boundPaneId, "terminal.send", paneIds: paneIds)
            #expect(refusal == .notYetAllowed("terminal.send"))
        }
    }

    @Test("a drawer terminal's own pane is only itself")
    func drawerTerminalOwnsOnlyItself() async throws {
        let scenario = try makeScenario()

        try await scenario.authorize(drawerTerminalId, "terminal.status", paneIds: [drawerTerminalId])
        for foreign in [boundPaneId, childPaneId] {
            let refusal = try await scenario.refusal(drawerTerminalId, "terminal.status", paneIds: [foreign])
            #expect(refusal == .notYetAllowed("terminal.status"))
        }
    }

    @Test("a principal that outlived its pane owns nothing")
    func vanishedBoundPaneOwnsNothing() async throws {
        let scenario = try makeScenario(unlistedPanesExist: false)
        let vanishedPaneId = UUIDv7.generate()

        let refusal = try await scenario.refusal(vanishedPaneId, "terminal.status", paneIds: [vanishedPaneId])

        #expect(refusal == .notYetAllowed("terminal.status"))
    }

    @Test("any-target listing needs no own-pane scope")
    func anyTargetListingNeedsNoScope() async throws {
        let scenario = try makeScenario(unlistedPanesExist: false)
        let vanishedPaneId = UUIDv7.generate()

        try await scenario.authorize(vanishedPaneId, "pane.list", target: .pane(vanishedPaneId.uuidString))
        try await scenario.authorize(vanishedPaneId, "window.list", target: .pane(vanishedPaneId.uuidString))
    }

    @Test("not-yet-allowed methods are refused by name and a grant is no fallback")
    func notYetAllowedMethodsIgnoreGrants() async throws {
        let scenario = try makeScenario()
        scenario.grantLedger.grant(
            IPCPermissionScope(
                privilege: .layoutMutate, target: .pane(boundPaneId.uuidString), dataScope: .paneContext),
            to: scenario.principal(boundTo: boundPaneId).principalId
        )

        for method in ["pane.focus", "pane.split", "drawer.toggle", "bridge.diff.getPackage", "sidebar.grouping.get"] {
            let refusal = try await scenario.refusal(boundPaneId, method, paneIds: [boundPaneId])
            #expect(refusal == .notYetAllowed(method))
        }
    }

    @Test("argument rules refuse closing the own pane and adding outside a main-layout agent's own drawer")
    func argumentRulesRefuseNeverAllowedEffects() async throws {
        let scenario = try makeScenario()

        let closeSelf = try await scenario.refusal(
            boundPaneId, "pane.close", paneIds: [boundPaneId], rule: .closesPane(boundPaneId))
        try await scenario.authorize(
            boundPaneId, "pane.close", paneIds: [childPaneId], rule: .closesPane(childPaneId))
        try await scenario.authorize(
            boundPaneId, "drawer.addPane", paneIds: [boundPaneId],
            rule: .addsDrawerChild(parentPaneId: boundPaneId, content: .terminal))
        let nestedAdd = try await scenario.refusal(
            drawerTerminalId, "drawer.addPane", paneIds: [drawerTerminalId],
            rule: .addsDrawerChild(parentPaneId: drawerTerminalId, content: .terminal))
        let addUnderChild = try await scenario.refusal(
            boundPaneId, "drawer.addPane", paneIds: [childPaneId],
            rule: .addsDrawerChild(parentPaneId: childPaneId, content: .terminal))

        for (content, admitted) in [
            (IPCDrawerChildContent.browser(url: "https://example.com/docs"), true),
            (.browser(url: "http://localhost:8080"), true),
            (.browser(url: "file:///etc/passwd"), false),
            (.browser(url: "javascript:alert(1)"), false),
            (.browser(url: "not a url"), false),
            (.bridge, false),
            (.codeViewer, false),
        ] {
            let refusal = try await scenario.refusal(
                boundPaneId, "drawer.addPane", paneIds: [boundPaneId],
                rule: .addsDrawerChild(parentPaneId: boundPaneId, content: content))
            #expect(refusal == (admitted ? nil : .refusedForAgent("drawer.addPane")), "\(content)")
        }
        #expect(closeSelf == .refusedForAgent("pane.close"))
        #expect(nestedAdd == .refusedForAgent("drawer.addPane"))
        #expect(addUnderChild == .refusedForAgent("drawer.addPane"))
    }

    @Test("command execution is admitted by each command's own eligibility")
    func commandExecutionUsesCommandEligibility() async throws {
        let scenario = try makeScenario()

        try await scenario.authorize(
            boundPaneId, "command.execute", paneIds: [childPaneId], commandId: FixtureCommands.ownPane)
        for commandId in [FixtureCommands.refused, "fixture.unknown"] {
            let refusal = try await scenario.refusal(
                boundPaneId, "command.execute", paneIds: [boundPaneId], commandId: commandId)
            #expect(refusal == .notYetAllowed(commandId))
        }
        let outside = try await scenario.refusal(
            boundPaneId, "command.execute", paneIds: [otherPaneId], commandId: FixtureCommands.ownPane)
        #expect(outside == .notYetAllowed(FixtureCommands.ownPane))
    }

    @Test("established v2 methods keep the bound-pane baseline and are not widened to drawer children")
    func establishedMethodsKeepTheBaseline() async throws {
        let scenario = try makeScenario()

        try await scenario.authorize(boundPaneId, "session.query", target: .pane(boundPaneId.uuidString))
        try await scenario.authorize(boundPaneId, "events.subscribe", target: .pane(boundPaneId.uuidString))
        let childQuery = try await scenario.refusal(
            boundPaneId, "session.query", target: .pane(childPaneId.uuidString))

        #expect(childQuery?.reason == .missingGrant)
    }

    @Test(
        "routing refuses recognized hidden or not-yet-allowed names before schema validation",
        arguments: [AgentStudioIPCChannel.stable, .debug]
    )
    func routingRefusesRecognizedNames(channel: AgentStudioIPCChannel) throws {
        let registry = try makeScenario(channel: channel).registry

        #expect(
            registry.paneAgentRoutingRefusal(methodName: "pane.focus", parameters: nil) == .notYetAllowed("pane.focus"))
        #expect(
            registry.paneAgentRoutingRefusal(methodName: "ui.commandBar.open", parameters: .object([:]))
                == .notYetAllowed("ui.commandBar.open"))
        #expect(registry.paneAgentRoutingRefusal(methodName: "terminal.send", parameters: nil) == nil)
        #expect(registry.paneAgentRoutingRefusal(methodName: "session.report", parameters: nil) == nil)
        #expect(registry.paneAgentRoutingRefusal(methodName: "unknown.method", parameters: nil) == nil)
        #expect(!registry.recognizesMethod(named: "unknown.method"))
        #expect(
            registry.paneAgentRoutingRefusal(
                methodName: "command.execute",
                parameters: .object(["commandId": .string(FixtureCommands.refused)])
            ) == .notYetAllowed(FixtureCommands.refused))
        #expect(
            registry.paneAgentRoutingRefusal(
                methodName: "command.execute",
                parameters: .object(["commandId": .string(FixtureCommands.ownPane)])
            ) == nil)
        #expect(
            registry.paneAgentRoutingRefusal(
                methodName: "command.execute",
                parameters: .object(["commandId": .string("fixture.unknown")])
            ) == nil)
    }

    @Test("every decided pane-agent request records one authorization-time sample with its outcome")
    func everyDecisionRecordsOneAuthorizationSample() async throws {
        let telemetry = RecordingAgentAuthorizationTelemetry()
        let scenario = try makeScenario(telemetry: telemetry)

        try await scenario.authorize(boundPaneId, "terminal.send", paneIds: [boundPaneId])
        _ = try await scenario.refusal(boundPaneId, "pane.focus", paneIds: [boundPaneId])
        _ = try await scenario.refusal(boundPaneId, "terminal.send", paneIds: [otherPaneId])
        _ = try await scenario.refusal(
            boundPaneId, "pane.close", paneIds: [boundPaneId], rule: .closesPane(boundPaneId))
        let routed = scenario.service.paneAgentRoutingRefusal(methodName: "terminal.send", parameters: nil)
        let hidden = scenario.service.paneAgentRoutingRefusal(methodName: "pane.focus", parameters: nil)
        try await scenario.authorize(boundPaneId, "session.query", target: .pane(boundPaneId.uuidString))

        // Routing that lets a request through, and an established v2 method
        // with no eligibility, decide nothing here and record nothing.
        #expect(routed == nil)
        #expect(hidden == .notYetAllowed("pane.focus"))
        #expect(telemetry.outcomes == [.authorized, .notYetAllowed, .notYetAllowed, .refusedForAgent, .notYetAllowed])
    }

    // MARK: - Scenario

    private func makeScenario(
        channel: AgentStudioIPCChannel = .debug,
        unlistedPanesExist: Bool = true,
        telemetry: RecordingAgentAuthorizationTelemetry = RecordingAgentAuthorizationTelemetry()
    ) throws -> PaneAgentAuthorizationScenario {
        let fixture = BuiltInMethodRegistrationsFixture()
        let composition = try FixtureCommands.composition()
        let registrations =
            try fixture.registrations()
            + AppIPCCommandMethodRegistrations.make(composition: composition, port: FakeCommandPort())
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: registrations,
            recognizedCommands: composition.commands.map {
                AppIPCRecognizedEntry(
                    name: $0.id.rawValue, exposure: $0.exposure, agentEligibility: $0.agentEligibility)
            },
            channel: channel
        )
        let grantLedger = GrantLedger()
        let scopePort = StaticOwnPaneScopePort(
            scopes: [
                AppIPCOwnPaneScope(
                    boundPaneId: boundPaneId, isDrawerTerminal: false, drawerChildPaneIds: [childPaneId]),
                AppIPCOwnPaneScope(boundPaneId: drawerTerminalId, isDrawerTerminal: true, drawerChildPaneIds: []),
            ],
            unlistedPanesExist: unlistedPanesExist
        )
        return PaneAgentAuthorizationScenario(
            registry: registry,
            grantLedger: grantLedger,
            service: AuthorizationService(
                methodRegistry: registry,
                grantLedger: grantLedger,
                canonicalizer: PermissionScopeCanonicalizer(),
                ownPaneScopePort: scopePort,
                agentAuthorizationTelemetry: telemetry
            ),
            runtimeId: fixture.runtimeId
        )
    }
}

private struct PaneAgentAuthorizationScenario {
    let registry: AppIPCMethodRegistry
    let grantLedger: GrantLedger
    let service: AuthorizationService
    let runtimeId: UUID

    func principal(boundTo paneId: UUID) -> IPCPrincipal {
        IPCPrincipal(
            principalId: Self.principalId(for: paneId),
            runtimeId: runtimeId,
            accessMode: .agentStudioOnly,
            kind: .spawnedPaneAgent(boundPaneId: paneId.uuidString, boundWorkspaceId: nil),
            approvalAuthority: .noApprovalAuthority
        )
    }

    /// One stable principal identity per bound pane, so a grant recorded for
    /// it is the one a later request presents.
    private static func principalId(for paneId: UUID) -> UUID { paneId }

    func authorize(
        _ boundPaneId: UUID,
        _ method: String,
        paneIds: [UUID]? = nil,
        target: IPCTargetScope? = nil,
        commandId: String? = nil,
        rule: AppIPCAgentArgumentRule = .targetOnly
    ) async throws {
        let registration = try #require(registry.registration(named: method))
        let metadata = registration.descriptor.metadata
        let resolvedPaneIds = paneIds ?? []
        try await service.authorize(
            principal: principal(boundTo: boundPaneId),
            request: AppIPCMethodAuthorizationRequest(
                methodName: method,
                requiredPrivileges: Set(metadata.requiredPrivileges),
                dataScope: metadata.dataScope,
                target: target ?? resolvedPaneIds.first.map { .pane($0.uuidString) } ?? .app,
                resolvedPaneIds: resolvedPaneIds,
                commandId: commandId,
                agentArgumentRule: rule
            )
        )
    }

    func refusal(
        _ boundPaneId: UUID,
        _ method: String,
        paneIds: [UUID]? = nil,
        target: IPCTargetScope? = nil,
        commandId: String? = nil,
        rule: AppIPCAgentArgumentRule = .targetOnly
    ) async throws -> AuthorizationError? {
        do {
            try await authorize(
                boundPaneId, method, paneIds: paneIds, target: target, commandId: commandId, rule: rule)
            return nil
        } catch let error as AuthorizationError {
            return error
        }
    }
}

/// Two commands spanning the eligibility classes `command.execute` admits by.
private enum FixtureCommands {
    static let ownPane = "fixture.ownPane"
    static let refused = "fixture.refused"

    static func composition() throws -> IPCCommandMethodComposition {
        try IPCCommandMethodComposition(
            compatibility: .current,
            commands: [
                descriptor(id: ownPane, exposure: .allChannels, eligibility: .ownPane),
                descriptor(id: refused, exposure: .debugTesting, eligibility: .notYetAllowed),
            ]
        )
    }

    private static func descriptor(
        id rawId: String,
        exposure: IPCMethodExposure,
        eligibility: IPCAgentEligibility
    ) throws -> IPCCommandDescriptor {
        let id = IPCCommandIdentifier(rawValue: rawId)
        let correlationId = UUIDv7.generate()
        return try IPCCommandDescriptorFactory.make(
            IPCCommandDescriptorInput(
                id: id,
                title: "Fixture \(rawId)",
                description: "Exercise one pane-agent command class.",
                exposure: exposure,
                executionMode: .headless,
                argumentVariants: [.pane],
                requiredPrivileges: [.appCommandExecute, .terminalInputWrite],
                dataScope: .terminalInput,
                allowedTargetKinds: [.pane],
                resultVariants: [.applied],
                examples: [
                    IPCCommandExample(
                        description: "Apply the fixture command to one pane.",
                        request: IPCCommandExecutionRequest(
                            commandId: id,
                            correlationId: correlationId,
                            arguments: .pane(
                                IPCPaneCommandArguments(
                                    workspaceWindowId: UUIDv7.generate(),
                                    paneSelector: try IPCPaneSelector(rawValue: "self")
                                ))
                        ),
                        result: .applied(IPCCommandAppliedResult(commandId: id, correlationId: correlationId))
                    )
                ],
                agentEligibility: eligibility
            )
        )
    }
}
