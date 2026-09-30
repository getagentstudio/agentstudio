import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

/// A1 admission for a pane-bound agent calling a method that declares an
/// eligibility: the eligibility, then own-pane membership of every resolved
/// target, then the argument rules. It stands in for the privilege baseline
/// and grant ledger for those methods.
struct AppIPCPaneAgentAuthorization: Sendable {
    let methodRegistry: AppIPCMethodRegistry
    let ownPaneScopePort: any AppIPCOwnPaneScopePort
    let telemetry: any AppIPCAgentAuthorizationTelemetry

    /// Decides one request and records the decision's duration as one
    /// authorization-time sample, whether it admits or refuses.
    func authorize(
        boundPaneId: String,
        methodEligibility: IPCAgentEligibility,
        request: AppIPCMethodAuthorizationRequest
    ) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await decide(boundPaneId: boundPaneId, methodEligibility: methodEligibility, request: request)
            telemetry.recordAgentAuthorization(elapsed: started.duration(to: clock.now), outcome: .authorized)
        } catch let refusal as AuthorizationError {
            telemetry.recordAgentAuthorization(
                elapsed: started.duration(to: clock.now), outcome: Self.outcome(of: refusal))
            throw refusal
        }
    }

    /// Routing admission before schema validation. A refusal here is the
    /// request's decision, so it is recorded as one authorization-time sample;
    /// a request routing lets through is recorded when `authorize` decides it.
    func routingRefusal(methodName: String, parameters: JSONValue?) -> AuthorizationError? {
        let clock = ContinuousClock()
        let started = clock.now
        guard let refusal = methodRegistry.paneAgentRoutingRefusal(methodName: methodName, parameters: parameters)
        else { return nil }
        telemetry.recordAgentAuthorization(
            elapsed: started.duration(to: clock.now), outcome: Self.outcome(of: refusal))
        return refusal
    }

    private static func outcome(of refusal: AuthorizationError) -> AppIPCAgentAuthorizationOutcome {
        refusal.reason == .refusedForAgent ? .refusedForAgent : .notYetAllowed
    }

    private func decide(
        boundPaneId: String,
        methodEligibility: IPCAgentEligibility,
        request: AppIPCMethodAuthorizationRequest
    ) async throws {
        let refusedName = request.commandId ?? request.methodName
        switch effectiveEligibility(methodEligibility, request: request) {
        case .notYetAllowed:
            throw AuthorizationError.notYetAllowed(refusedName)
        case .anyTarget:
            return
        case .ownPane:
            guard let boundId = UUID(uuidString: boundPaneId),
                let scope = await ownPaneScopePort.ownPaneScope(boundPaneId: boundId),
                !request.resolvedPaneIds.isEmpty,
                request.resolvedPaneIds.allSatisfy({ scope.membership(of: $0) != .outside })
            else {
                throw AuthorizationError.notYetAllowed(refusedName)
            }
            try Self.checkArgumentRule(request.agentArgumentRule, scope: scope, refusedName: refusedName)
        }
    }

    /// `command.execute` carries the pane-scoped class; each command's own
    /// eligibility decides.
    private func effectiveEligibility(
        _ methodEligibility: IPCAgentEligibility,
        request: AppIPCMethodAuthorizationRequest
    ) -> IPCAgentEligibility {
        guard request.methodName == AppIPCMethodNames.commandExecute else { return methodEligibility }
        guard let commandId = request.commandId else { return .notYetAllowed }
        return methodRegistry.commandAgentEligibility(commandId)
    }

    private static func drawerMayHold(_ content: IPCDrawerChildContent) -> Bool {
        switch content {
        case .terminal: true
        case .browser: content.admissibleBrowserURL != nil
        case .bridge, .codeViewer: false
        }
    }

    static func checkArgumentRule(
        _ rule: AppIPCAgentArgumentRule,
        scope: AppIPCOwnPaneScope,
        refusedName: String
    ) throws {
        switch rule {
        case .targetOnly:
            return
        case .closesPane(let paneId):
            guard paneId != scope.boundPaneId else {
                throw AuthorizationError.refusedForAgent(refusedName)
            }
        case .addsDrawerChild(let parentPaneId, let content):
            guard !scope.isDrawerTerminal, parentPaneId == scope.boundPaneId, Self.drawerMayHold(content) else {
                throw AuthorizationError.refusedForAgent(refusedName)
            }
        }
    }
}
