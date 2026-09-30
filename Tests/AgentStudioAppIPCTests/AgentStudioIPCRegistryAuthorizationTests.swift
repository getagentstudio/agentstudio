import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("AgentStudio IPC typed registry and authorization")
struct AgentStudioIPCRegistryAuthorizationTests {
    @Test("scope canonicalization preserves descriptor-owned data category")
    func canonicalizationPreservesExplicitDataScope() throws {
        let principal = panePrincipal(boundPaneId: "pane-1")
        let scope = IPCPermissionScope(privilege: .workspaceRead, target: .selfPane, dataScope: .sidebarState)
        let canonical = try PermissionScopeCanonicalizer().canonicalize(scope, for: principal)

        #expect(canonical.target == .pane("pane-1"))
        #expect(canonical.privilege == .workspaceRead)
        #expect(canonical.dataScope == .sidebarState)
    }

    @Test("debug registry exposes the 47 typed bindings and computed capabilities only")
    func debugRegistryHasTypedCatalogAndComputedCapabilities() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: .debug)
        let names = registry.capabilities.methods.map(\.name)

        #expect(names.count == 48)
        #expect(Set(names).count == 48)
        #expect(registry.registration(named: "system.capabilities") != nil)
        #expect(registry.registration(named: "pane.snapshot") != nil)
        #expect(registry.registration(named: "permission.request") == nil)
        #expect(registry.registration(named: "command.list") == nil)
        #expect(registry.registration(named: "command.execute") == nil)
    }

    @Test("stable registry omits debug-testing methods and keeps agent-eligible methods")
    func stableRegistryOmitsDebugTestingMethods() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: .stable)
        let names = Set(registry.capabilities.methods.map(\.name))

        #expect(
            names
                == Set([
                    "auth.login", "auth.status", "events.subscribe", "events.unsubscribe",
                    "session.event", "session.message", "session.query", "session.report",
                    "system.capabilities", "system.identify", "system.ping", "system.version",
                    "drawer.addPane", "pane.close", "pane.current", "pane.list", "pane.snapshot",
                    "terminal.send", "terminal.snapshot", "terminal.status", "terminal.wait",
                    "window.current", "window.list", "workspace.current", "workspace.list",
                ])
        )
        #expect(registry.registration(named: "system.capabilities") != nil)
        #expect(registry.registration(named: "pane.snapshot") != nil)
        #expect(registry.registration(named: "pane.focus") == nil)
        #expect(registry.registration(named: "bridge.diff.load") == nil)
    }

    @Test("registry rejects duplicate names")
    func registryRejectsDuplicateNames() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registrations = try fixture.registrations()
        let duplicate = try #require(registrations.first)
        let capabilitiesComposition = try makeTestIPCSystemCapabilitiesComposition(
            registrations: registrations,
            channel: .debug
        )

        #expect(throws: AppIPCMethodRegistryError.duplicateMethodName(duplicate.descriptor.metadata.name)) {
            _ = try AppIPCMethodRegistry(
                registrations: registrations + [duplicate],
                recognizedCommands: [],
                channel: .debug,
                capabilitiesComposition: capabilitiesComposition
            )
        }
    }

    @Test("Bridge grants keep review content control and telemetry scopes distinct")
    func bridgeGrantsKeepDataScopesDistinct() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let grantLedger = GrantLedger()
        let service = AuthorizationService(
            methodRegistry: try makeTestAppIPCMethodRegistry(
                registrations: fixture.registrations(), recognizedCommands: [], channel: .debug),
            grantLedger: grantLedger,
            canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
        )
        let principal = automationPrincipal(runtimeId: fixture.runtimeId)
        let target = IPCTargetScope.pane("pane-1")

        grantLedger.grant(
            IPCPermissionScope(privilege: .bridgeRead, target: target, dataScope: .bridgeReviewPackage),
            to: principal.principalId
        )
        try service.authorize(
            principal: principal,
            scope: IPCPermissionScope(
                privilege: .bridgeRead, target: target, dataScope: .bridgeReviewPackage))
        #expect(throws: AuthorizationError.self) {
            try service.authorize(
                principal: principal,
                scope: IPCPermissionScope(
                    privilege: .bridgeContentRead, target: target, dataScope: .bridgeContent)
            )
        }

        for (_, privilege, dataScope) in [
            ("bridge.fileView.getContent", IPCPrivilegeClass.bridgeContentRead, IPCDataScope.bridgeContent),
            ("bridge.diff.selectFile", .bridgeControl, .bridgeReviewPackage),
            ("bridge.telemetry.snapshot", .bridgeTelemetryRead, .bridgeTelemetry),
            ("bridge.telemetry.flush", .bridgeTelemetryFlush, .bridgeTelemetry),
        ] {
            grantLedger.grant(
                IPCPermissionScope(privilege: privilege, target: target, dataScope: dataScope),
                to: principal.principalId
            )
            try service.authorize(
                principal: principal,
                scope: IPCPermissionScope(privilege: privilege, target: target, dataScope: dataScope)
            )
        }
    }

    @Test("pane baseline authorizes self terminal input and denies cross-pane input")
    func paneBaselineIsBoundToItsExactPane() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: .debug)
        let service = AuthorizationService(
            methodRegistry: registry,
            grantLedger: GrantLedger(),
            canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
        )
        let principal = panePrincipal(boundPaneId: "pane-1", runtimeId: fixture.runtimeId)

        try service.authorize(
            principal: principal,
            scope: IPCPermissionScope(
                privilege: .terminalInputWrite, target: .pane("pane-1"), dataScope: .terminalInput))
        #expect(throws: AuthorizationError.self) {
            try service.authorize(
                principal: principal,
                scope: IPCPermissionScope(
                    privilege: .terminalInputWrite, target: .pane("pane-2"), dataScope: .terminalInput)
            )
        }
    }

    @Test("cross-pane terminal input requires the exact canonical grant")
    func crossPaneTerminalInputRequiresExactGrant() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: .debug)
        let ledger = GrantLedger()
        let service = AuthorizationService(
            methodRegistry: registry, grantLedger: ledger, canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry())
        let principal = panePrincipal(boundPaneId: "pane-1", runtimeId: fixture.runtimeId)
        let scope = IPCPermissionScope(
            privilege: .terminalInputWrite, target: .pane("pane-2"), dataScope: .terminalInput)

        ledger.grant(
            IPCPermissionScope(
                privilege: .terminalInputWrite, target: .pane("pane-2"), dataScope: .terminalInput),
            to: principal.principalId
        )
        try service.authorize(principal: principal, scope: scope)
    }

    @Test("authorization rejects privilege or data scope that differs from descriptor metadata")
    func authorizationRejectsMetadataMismatch() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: .debug)
        let service = AuthorizationService(
            methodRegistry: registry,
            grantLedger: GrantLedger(),
            canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
        )
        let principal = panePrincipal(boundPaneId: "pane-1", runtimeId: fixture.runtimeId)

        await #expect(throws: AuthorizationError.self) {
            try await service.authorize(
                principal: principal,
                request: authorizationRequest(
                    method: "terminal.send",
                    privilege: .terminalInputWrite,
                    dataScope: .terminalSnapshot,
                    target: .pane("pane-1")
                )
            )
        }
    }

    @Test("additional command scopes require their exact canonical grants")
    func additionalScopesRequireExactCanonicalGrants() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let ledger = GrantLedger()
        let service = AuthorizationService(
            methodRegistry: try makeTestAppIPCMethodRegistry(
                registrations: fixture.registrations(), recognizedCommands: [], channel: .debug),
            grantLedger: ledger,
            canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
        )
        let principal = panePrincipal(boundPaneId: "pane-1", runtimeId: fixture.runtimeId)
        let additionalScope = IPCPermissionScope(
            privilege: .layoutMutate,
            target: .pane("pane-2"),
            dataScope: .paneContext
        )
        let request = AppIPCMethodAuthorizationRequest(
            methodName: "events.subscribe",
            requiredPrivileges: [.eventsRead],
            dataScope: .permissionState,
            target: .pane("pane-1"),
            additionalScopes: [additionalScope]
        )

        await #expect(throws: AuthorizationError.self) {
            try await service.authorize(principal: principal, request: request)
        }
        ledger.grant(
            IPCPermissionScope(
                privilege: .layoutMutate,
                target: .pane("pane-2"),
                dataScope: .uiSurface
            ),
            to: principal.principalId
        )
        await #expect(throws: AuthorizationError.self) {
            try await service.authorize(principal: principal, request: request)
        }
        ledger.grant(additionalScope, to: principal.principalId)
        try await service.authorize(principal: principal, request: request)
    }

    @Test("debug authorization bypasses grants only for exact diagnostic provenance pairs")
    func diagnosticAuthorizationRequiresExactProvenancePair() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let service = AuthorizationService(
            methodRegistry: try makeTestAppIPCMethodRegistry(
                registrations: fixture.registrations(), recognizedCommands: [], channel: .debug),
            grantLedger: GrantLedger(),
            canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
        )
        let request = authorizationRequest(
            method: "ui.commandBar.open",
            privilege: .uiPresent,
            dataScope: .uiSurface,
            target: .app
        )
        let admittedPrincipals = [
            diagnosticPrincipal(
                runtimeId: fixture.runtimeId,
                accessMode: .automationSameUser,
                kind: .automationClient
            ),
            diagnosticPrincipal(
                runtimeId: fixture.runtimeId,
                accessMode: .unsafeDebug,
                kind: .unsafeDebugClient
            ),
        ]
        let rejectedPrincipals = [
            diagnosticPrincipal(
                runtimeId: fixture.runtimeId,
                accessMode: .unsafeDebug,
                kind: .automationClient
            ),
            diagnosticPrincipal(
                runtimeId: fixture.runtimeId,
                accessMode: .automationSameUser,
                kind: .unsafeDebugClient
            ),
            panePrincipal(boundPaneId: "pane-1", runtimeId: fixture.runtimeId),
            diagnosticPrincipal(
                runtimeId: fixture.runtimeId,
                accessMode: .automationSameUser,
                kind: .futureMCPClient
            ),
        ]

        for principal in admittedPrincipals {
            try await service.authorize(principal: principal, request: request)
        }
        for principal in rejectedPrincipals {
            await #expect(throws: AuthorizationError.self) {
                try await service.authorize(principal: principal, request: request)
            }
        }
    }

    @Test("descriptor metadata mismatch rejects before diagnostic authority bypass")
    func diagnosticAuthorizationRejectsMetadataMismatch() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let service = AuthorizationService(
            methodRegistry: try makeTestAppIPCMethodRegistry(
                registrations: fixture.registrations(), recognizedCommands: [], channel: .debug),
            grantLedger: GrantLedger(),
            canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
        )
        let principal = diagnosticPrincipal(
            runtimeId: fixture.runtimeId,
            accessMode: .automationSameUser,
            kind: .automationClient
        )

        await #expect(throws: AuthorizationError.self) {
            try await service.authorize(
                principal: principal,
                request: authorizationRequest(
                    method: "ui.commandBar.open",
                    privilege: .uiPresent,
                    dataScope: .paneContext,
                    target: .app
                )
            )
        }
    }

    @Test(
        "stable and beta registries refuse diagnostic-only authorization",
        arguments: [AgentStudioIPCChannel.stable, .beta]
    )
    func productionRegistryRefusesDiagnosticAuthorization(channel: AgentStudioIPCChannel) async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let service = AuthorizationService(
            methodRegistry: try makeTestAppIPCMethodRegistry(
                registrations: fixture.registrations(), recognizedCommands: [], channel: channel),
            grantLedger: GrantLedger(),
            canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
        )
        let principal = diagnosticPrincipal(
            runtimeId: fixture.runtimeId,
            accessMode: .automationSameUser,
            kind: .automationClient
        )

        await #expect(throws: AuthorizationError.self) {
            try await service.authorize(
                principal: principal,
                request: authorizationRequest(
                    method: "ui.commandBar.open",
                    privilege: .uiPresent,
                    dataScope: .uiSurface,
                    target: .app
                )
            )
        }
    }

    @Test("debug channel does not upgrade a pane principal to diagnostic methods")
    func debugChannelDoesNotUpgradePanePrincipal() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: .debug)
        let service = AuthorizationService(
            methodRegistry: registry,
            grantLedger: GrantLedger(),
            canonicalizer: PermissionScopeCanonicalizer(),
            ownPaneScopePort: StaticOwnPaneScopePort(),
            agentAuthorizationTelemetry: RecordingAgentAuthorizationTelemetry()
        )
        let principal = panePrincipal(boundPaneId: "pane-1", runtimeId: fixture.runtimeId)

        await #expect(throws: AuthorizationError.self) {
            try await service.authorize(
                principal: principal,
                request: authorizationRequest(
                    method: "ui.commandBar.open",
                    privilege: .uiPresent,
                    dataScope: .uiSurface,
                    target: .app
                )
            )
        }
    }
}

private func authorizationRequest(
    method: String,
    privilege: IPCPrivilegeClass,
    dataScope: IPCDataScope,
    target: IPCTargetScope
) -> AppIPCMethodAuthorizationRequest {
    AppIPCMethodAuthorizationRequest(
        methodName: method,
        requiredPrivileges: [privilege],
        dataScope: dataScope,
        target: target
    )
}

private func panePrincipal(
    boundPaneId: String,
    runtimeId: UUID = UUIDv7.generate()
) -> IPCPrincipal {
    IPCPrincipal(
        principalId: UUIDv7.generate(),
        runtimeId: runtimeId,
        accessMode: .agentStudioOnly,
        kind: .spawnedPaneAgent(boundPaneId: boundPaneId, boundWorkspaceId: nil),
        approvalAuthority: .noApprovalAuthority
    )
}

private func automationPrincipal(runtimeId: UUID) -> IPCPrincipal {
    IPCPrincipal(
        principalId: UUIDv7.generate(),
        runtimeId: runtimeId,
        accessMode: .agentStudioOnly,
        kind: .automationClient,
        approvalAuthority: .noApprovalAuthority
    )
}

private func diagnosticPrincipal(
    runtimeId: UUID,
    accessMode: IPCAccessMode,
    kind: IPCPrincipalKind
) -> IPCPrincipal {
    IPCPrincipal(
        principalId: UUIDv7.generate(),
        runtimeId: runtimeId,
        accessMode: accessMode,
        kind: kind,
        approvalAuthority: .noApprovalAuthority
    )
}
