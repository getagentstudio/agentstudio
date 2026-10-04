import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

package enum ProviderPermissionHookProvider: String, Sendable {
    case claude
    case codex
}

package struct ProviderPermissionHookRequest: Equatable, Sendable {
    package let provider: ProviderPermissionHookProvider
    package let conversationId: String
    package let body: String
    package let sessionEvent: IPCSessionEventParams

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
    private static let legacyProjectionIdentifier =
        UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    package static func project(provider: ProviderPermissionHookProvider, payload: Data) throws
        -> ProviderPermissionHookProjectionOutcome
    {
        try project(
            provider: provider,
            payload: payload,
            sourceOccurredAt: Date(),
            providerVersion: nil,
            correlationIdentifier: legacyProjectionIdentifier,
            freshOccurrenceIdentifier: { legacyProjectionIdentifier })
    }

    package static func project(
        provider: ProviderPermissionHookProvider,
        payload: Data,
        sourceOccurredAt: Date,
        providerVersion: String?,
        correlationIdentifier: UUID,
        freshOccurrenceIdentifier: @escaping () -> UUID
    ) throws -> ProviderPermissionHookProjectionOutcome {
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
        let event = try blockingSessionEvent(
            provider: provider,
            document: document,
            sourceOccurredAt: sourceOccurredAt,
            providerVersion: providerVersion,
            correlationIdentifier: correlationIdentifier,
            freshOccurrenceIdentifier: freshOccurrenceIdentifier)
        return .approval(
            .init(
                provider: provider, conversationId: document.sessionId,
                body: "\(document.toolName)\n\(inputText)", sessionEvent: event))
    }

    private static func blockingSessionEvent(
        provider: ProviderPermissionHookProvider,
        document: PermissionHookDocument,
        sourceOccurredAt: Date,
        providerVersion: String?,
        correlationIdentifier: UUID,
        freshOccurrenceIdentifier: @escaping () -> UUID
    ) throws -> IPCSessionEventParams {
        let providerIdentity: IPCSessionProviderIdentity
        let requestIdentifier: String?
        let occurrenceIdentifier: UUID
        switch provider {
        case .claude:
            providerIdentity = .init(
                identifier: ClaudeCodeProviderIdentity.identifier,
                version: providerVersion ?? ClaudeCodeProviderIdentity.supportedExactVersion,
                mode: ClaudeCodeProviderIdentity.operatingMode)
            requestIdentifier = document.toolUseId
            occurrenceIdentifier = ClaudeCodeHookOccurrenceIdentity.occurrenceIdentifier(
                sessionId: document.sessionId,
                hookEventName: document.hookEventName,
                toolUseId: document.toolUseId,
                freshIdentifier: freshOccurrenceIdentifier)
        case .codex:
            providerIdentity = .init(
                identifier: CodexHookProjection.providerIdentifier,
                version: document.codexVersion ?? CodexHookProjection.defaultProviderVersion,
                mode: CodexHookProjection.providerMode)
            let payload = CodexHookPayload(
                sessionId: document.sessionId,
                turnId: document.turnId,
                hookEventName: document.hookEventName,
                toolName: document.toolName,
                toolUseId: document.toolUseId,
                codexVersion: document.codexVersion)
            occurrenceIdentifier = CodexHookProjection.derivedIdentifier(
                eventName: .permissionRequest, payload: payload)
            requestIdentifier = occurrenceIdentifier.uuidString
        }
        var fields = IPCSessionProviderEventFields()
        fields.sourceOccurredAt = sourceOccurredAt
        fields.toolName = document.toolName
        let identity = IPCSessionEventIdentity(
            name: .permission,
            conversationId: document.sessionId,
            turnId: document.promptId ?? document.turnId,
            requestId: requestIdentifier,
            toolId: nil,
            subagentId: nil,
            occurrenceId: occurrenceIdentifier,
            providerFields: fields)
        return IPCSessionEventParams(
            handle: "self",
            provider: providerIdentity,
            event: identity,
            correlationId: correlationIdentifier,
            permissionHandling: .blockingAsk)
    }
}

private struct PermissionHookDocument: Decodable {
    let sessionId: String
    let hookEventName: String
    let toolName: String
    let toolInput: JSONValue
    let turnId: String?
    let promptId: String?
    let toolUseId: String?
    let codexVersion: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case turnId = "turn_id"
        case promptId = "prompt_id"
        case toolUseId = "tool_use_id"
        case codexVersion = "codex_version"
    }
}

private enum PermissionHookProjectionError: Error {
    case invalidDocument
}
