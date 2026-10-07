import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

/// One best-effort refusal call shares the hook's remaining deadline and never queues.
package enum ProviderHookRefusalInvocation {
    static func reason(for error: any Error) -> IPCSessionRefusalReason {
        switch error {
        case DecodingError.keyNotFound(let key, _) where key.stringValue == "session_id":
            return .noSessionId
        case DecodingError.valueNotFound(_, let context) where context.codingPath.last?.stringValue == "session_id":
            return .noSessionId
        default: return .undecodablePayload
        }
    }

    static func report(
        reason: IPCSessionRefusalReason, event: String?, environment: [String: String],
        identifierGenerator: () -> UUID, deadline: CallDeadline
    ) {
        guard deadline.remainingBudget > .zero,
            let token = environment["AGENTSTUDIO_PANE_TOKEN"], !token.isEmpty
        else { return }
        do {
            let configuration = AgentStudioIPCClientConfiguration(
                socketPath: try AgentStudioIPCClientDiscovery.socketPath(
                    explicitSocketPath: nil, environment: environment, metadataURL: nil), authToken: token)
            try send(
                params: .init(handle: "self", reason: reason, event: event, correlationId: identifierGenerator()),
                configuration: configuration, deadline: deadline)
        } catch {}
    }

    static func send(
        params: IPCSessionRefusalParams, configuration: AgentStudioIPCClientConfiguration, deadline: CallDeadline
    ) throws {
        guard deadline.remainingBudget > .zero else { return }
        let descriptors = try IPCCompiledInvocationResolver().resolve(
            arguments: ["session.refusal"], authenticated: configuration.authToken != nil,
            inputs: .init(examples: .init(illustrativeIdentifier: params.correlationId)))
        guard let descriptor = descriptors.first(where: { $0.metadata.name == "session.refusal" }) else { return }
        let client = AgentStudioIPCClient(configuration: configuration, descriptors: descriptors, deadline: deadline)
        _ = try client.call(
            .init(
                descriptor: descriptor,
                normalizedParameters: try descriptor.normalizeParameters(JSONEncoder().encode(params)),
                presentation: .tooling))
    }
}
