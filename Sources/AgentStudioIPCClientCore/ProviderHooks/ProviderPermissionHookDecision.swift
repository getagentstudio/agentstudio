import AgentStudioProgrammaticControl
import Foundation

/// Only an exact, single human answer is authority for this tool invocation.
package enum ProviderPermissionHookDecision {
    package static func json(for outcome: IPCPaneAskOutcome) throws -> String? {
        guard case .answered(.choices(let identifiers)) = outcome, identifiers.count == 1 else { return nil }
        let decision: PermissionDecision
        switch identifiers.first {
        case "Allow": decision = .init(behavior: .allow, message: nil)
        case "Deny": decision = .init(behavior: .deny, message: "The person denied this permission request.")
        default: return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(
            PermissionHookOutput(
                hookSpecificOutput: .init(hookEventName: "PermissionRequest", decision: decision)))
        return String(data: bytes, encoding: .utf8)
    }
}

private struct PermissionHookOutput: Encodable {
    let hookSpecificOutput: PermissionSpecificOutput
}

private struct PermissionSpecificOutput: Encodable {
    let hookEventName: String
    let decision: PermissionDecision
}

private struct PermissionDecision: Encodable {
    let behavior: PermissionDecisionBehavior
    let message: String?
}

private enum PermissionDecisionBehavior: String, Encodable {
    case allow
    case deny
}
