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

    static func send(
        params: IPCSessionRefusalParams, configuration: AgentStudioIPCClientConfiguration, deadline: CallDeadline
    ) throws {
        guard deadline.remainingBudget > .zero else { return }
        let descriptors = try IPCCompiledInvocationResolver().resolve(
            arguments: ["session.refusal"], authenticated: configuration.authToken != nil,
            inputs: .init(examples: .init(illustrativeIdentifier: params.correlationId)))
        guard let descriptor = descriptors.first(where: { $0.metadata.name == "session.refusal" }) else { return }
        let client = AgentStudioIPCClient(configuration: configuration, descriptors: descriptors, deadline: deadline)
        let result = try client.call(
            .init(
                descriptor: descriptor,
                normalizedParameters: try descriptor.normalizeParameters(JSONEncoder().encode(params)),
                presentation: .tooling))
        if case .remoteFailure(let failure) = result { throw failure }
    }
}
