import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

/// Delivers one projected provider event to the running app.
///
/// The live value is the ordinary authenticated client path: discover the
/// selected compiled contract, then call `session.event` with the pane credential the pane
/// environment already carries. It is a value rather than a direct call so the
/// hook runner can be proven without a socket.
package struct ProviderHookDelivery: Sendable {
    package let deliver:
        @Sendable (IPCSessionEventParams, AgentStudioIPCClientConfiguration, CallDeadline) throws -> Void
    package let recordRefusal:
        @Sendable (IPCSessionRefusalParams, AgentStudioIPCClientConfiguration, CallDeadline) throws -> Void

    package init(
        deliver:
            @escaping @Sendable (IPCSessionEventParams, AgentStudioIPCClientConfiguration, CallDeadline) throws
            -> Void,
        recordRefusal:
            @escaping @Sendable (IPCSessionRefusalParams, AgentStudioIPCClientConfiguration, CallDeadline) throws ->
            Void
    ) {
        self.deliver = deliver
        self.recordRefusal = recordRefusal
    }

    package static func liveIPC(
        exampleIdentifierProvider: @escaping @Sendable () -> UUID
    ) -> Self {
        Self(
            deliver: { params, configuration, deadline in
                let examples = IPCBuiltInMethodExampleContext(
                    illustrativeIdentifier: exampleIdentifierProvider()
                )
                let descriptors = try IPCCompiledInvocationResolver().resolve(
                    arguments: ["session.event"], authenticated: configuration.authToken != nil,
                    inputs: .init(examples: examples))
                guard let descriptor = descriptors.first(where: { $0.metadata.name == "session.event" })
                else {
                    throw ProviderHookFailure.methodUnavailable
                }
                let invocation = try IPCDescriptorInvocation(
                    descriptor: descriptor,
                    normalizedParameters: descriptor.normalizeParameters(JSONEncoder().encode(params)),
                    presentation: .tooling
                )
                let client = AgentStudioIPCClient(
                    configuration: configuration, descriptors: descriptors, deadline: deadline)
                switch try client.call(invocation) {
                case .success:
                    return
                case .remoteFailure(let failure):
                    throw ProviderHookFailure.rejected(failure.documentedReason ?? "requestRejected")
                }
            },
            recordRefusal: { params, configuration, deadline in
                try ProviderHookRefusalInvocation.send(params: params, configuration: configuration, deadline: deadline)
            })
    }

    /// Only Codex SessionEnd is provider-forced synchronous. Interrupt stays
    /// async despite sharing the provider's lifecycle timeout cap.
    package static func codexCallLimit(for event: CodexHookEventName) -> Duration {
        event == .sessionEnd ? CLIPolicy.synchronousLifecycleHookLimit : CLIPolicy.hookCallLimit
    }
}

package enum ProviderHookFailure: Error, Equatable, Sendable {
    case methodUnavailable
    case rejected(String)

    package var reasonLabel: String {
        switch self {
        case .methodUnavailable: "session.event unavailable"
        case .rejected(let reason): reason
        }
    }
}

/// Runs one provider hook end to end: guard, read, project, deliver.
///
/// Every path returns `0`. A hook that fails must never block the provider, so
/// diagnostics go only to the CLI's private log, never the provider's streams.
package enum ProviderHookInvocation {
    package static let paneTokenVariable = "AGENTSTUDIO_PANE_TOKEN"
    package static let socketVariable = "AGENTSTUDIO_IPC_SOCKET"

    package struct Props: Sendable {
        package let eventName: String
        package let environment: [String: String]
        package let standardInput: @Sendable () throws -> Data
        package let correlationIdProvider: @Sendable () -> UUID
        package let delivery: ProviderHookDelivery
        package let standardErrorSink: @Sendable (String) -> Void
        package let deadline: CallDeadline?

        package init(
            eventName: String,
            environment: [String: String],
            standardInput: @escaping @Sendable () throws -> Data,
            correlationIdProvider: @escaping @Sendable () -> UUID,
            delivery: ProviderHookDelivery,
            standardErrorSink: @escaping @Sendable (String) -> Void,
            deadline: CallDeadline? = nil
        ) {
            self.eventName = eventName
            self.environment = environment
            self.standardInput = standardInput
            self.correlationIdProvider = correlationIdProvider
            self.delivery = delivery
            self.standardErrorSink = standardErrorSink
            self.deadline = deadline
        }
    }

    @discardableResult
    package static func runCodexHook(_ props: Props) -> Int32 {
        guard let eventName = CodexHookEventName(rawValue: props.eventName) else {
            props.standardErrorSink("agentstudio hook codex: unknown event \(props.eventName)")
            return 0
        }
        let eventLimit = ProviderHookDelivery.codexCallLimit(for: eventName)
        let ingressDeadline = props.deadline ?? CallDeadline(limit: eventLimit)
        let deadline = ingressDeadline.capped(to: eventLimit)
        // No pane credential means this Codex process was not started by an
        // Agent Studio pane. That is ordinary, not a failure, so it stays silent.
        guard let configuration = paneConfiguration(environment: props.environment) else { return 0 }
        // The event may carry no Sessions meaning; then read nothing, say nothing.
        guard CodexHookProjection.isProjected(eventName) else { return 0 }
        let payload: CodexHookPayload
        do {
            payload = try JSONDecoder().decode(CodexHookPayload.self, from: try props.standardInput())
        } catch {
            recordPayloadRefusal(
                ProviderHookRefusalInvocation.reason(for: error), props: props, configuration: configuration,
                deadline: deadline)
            props.standardErrorSink(
                "agentstudio hook codex \(eventName.rawValue): unreadable hook payload")
            return 0
        }
        guard !payload.sessionId.isEmpty else {
            recordPayloadRefusal(.noSessionId, props: props, configuration: configuration, deadline: deadline)
            return 0
        }
        guard
            let projected = CodexHookProjection.project(
                eventName: eventName, payload: payload, freshOccurrenceIdentifier: props.correlationIdProvider)
        else {
            return 0
        }
        guard deadline.remainingBudget > .zero else { return 0 }
        do {
            try props.delivery.deliver(
                IPCSessionEventParams(
                    handle: "self",
                    provider: projected.provider,
                    event: projected.event,
                    correlationId: props.correlationIdProvider()
                ),
                configuration,
                deadline
            )
        } catch let failure as ProviderHookFailure {
            props.standardErrorSink(
                "agentstudio hook codex \(eventName.rawValue): \(failure.reasonLabel)")
        } catch {
            props.standardErrorSink("agentstudio hook codex \(eventName.rawValue): not delivered")
        }
        return 0
    }

    private static func recordPayloadRefusal(
        _ reason: IPCSessionRefusalReason, props: Props,
        configuration: AgentStudioIPCClientConfiguration, deadline: CallDeadline
    ) {
        guard deadline.remainingBudget > .zero else { return }
        try? props.delivery.recordRefusal(
            .init(handle: "self", reason: reason, event: props.eventName, correlationId: props.correlationIdProvider()),
            configuration, deadline)
    }

    private static func paneConfiguration(
        environment: [String: String]
    ) -> AgentStudioIPCClientConfiguration? {
        guard let token = environment[paneTokenVariable], !token.isEmpty,
            let socketPath = environment[socketVariable], !socketPath.isEmpty
        else {
            return nil
        }
        return AgentStudioIPCClientConfiguration(socketPath: socketPath, authToken: token)
    }
}
