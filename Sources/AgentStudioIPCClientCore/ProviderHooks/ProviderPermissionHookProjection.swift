import AgentStudioIPCTransport
import Foundation

package enum ProviderPermissionHookProvider: String, Sendable {
    case claude
    case codex
}

package struct ProviderPermissionHookRequest: Equatable, Sendable {
    package let provider: ProviderPermissionHookProvider
    package let conversationId: String
    package let body: String

    package var askArguments: [String] {
        [
            "ask", body, "--reason", "approval", "--kind", "attention", "--choice", "Allow,Deny,Ask",
            "--wait", "--timeout", String(CLIPolicy.permissionApprovalWindow / .seconds(1)),
        ]
    }

    /// The hook document, rather than its parent's inherited variables, names the writer.
    package func writerEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        result.removeValue(forKey: "CLAUDE_CODE_SESSION_ID")
        result.removeValue(forKey: "CODEX_THREAD_ID")
        switch provider {
        case .claude: result["CLAUDE_CODE_SESSION_ID"] = conversationId
        case .codex: result["CODEX_THREAD_ID"] = conversationId
        }
        return result
    }
}

package enum ProviderPermissionHookProjectionOutcome: Equatable, Sendable {
    case approval(ProviderPermissionHookRequest)
    case readOnlyQuestion
}

/// Permission input is message content, never added to Sessions evidence or diagnostics.
package enum ProviderPermissionHookProjection {
    package static func project(provider: ProviderPermissionHookProvider, payload: Data) throws
        -> ProviderPermissionHookProjectionOutcome
    {
        let document = try JSONDecoder().decode(PermissionHookDocument.self, from: payload)
        guard document.hookEventName == "PermissionRequest", !document.sessionId.isEmpty,
            !document.toolName.isEmpty
        else { throw PermissionHookProjectionError.invalidDocument }
        if provider == .claude, document.toolName == "AskUserQuestion" { return .readOnlyQuestion }
        guard case .object = document.toolInput else { throw PermissionHookProjectionError.invalidDocument }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let input = try encoder.encode(document.toolInput)
        guard let inputText = String(data: input, encoding: .utf8) else {
            throw PermissionHookProjectionError.invalidDocument
        }
        return .approval(
            .init(
                provider: provider, conversationId: document.sessionId,
                body: "\(document.toolName)\n\(inputText)"))
    }
}

private struct PermissionHookDocument: Decodable {
    let sessionId: String
    let hookEventName: String
    let toolName: String
    let toolInput: JSONValue

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }
}

private enum PermissionHookProjectionError: Error {
    case invalidDocument
}
