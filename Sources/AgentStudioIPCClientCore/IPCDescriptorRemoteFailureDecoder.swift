import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

/// Projects untrusted remote errors into the finite correction types understood
/// by the client. Raw messages, unknown keys, and malformed values are dropped.
enum IPCDescriptorRemoteFailureDecoder {
    static func decode(
        _ error: JSONRPCErrorPayload,
        descriptor: IPCAnyMethodDescriptor?
    ) -> IPCDescriptorRemoteFailure {
        IPCDescriptorRemoteFailure(
            code: error.code,
            documentedReason: documentedReason(
                from: error.data,
                descriptor: descriptor
            ),
            correction: schemaCorrection(from: error.data),
            requiredScope: missingGrantScope(from: error),
            agentRefusal: agentRefusal(from: error),
            commandCorrection: commandCorrection(from: error)
        )
    }

    private static func commandCorrection(from error: JSONRPCErrorPayload) -> IPCCommandErrorCorrection? {
        guard case .object(let fields) = error.data else { return nil }
        if error.code == -32_602, fields["reason"] == .string("invalidArguments"),
            Set(fields.keys) == ["reason", "fieldPath", "expected"],
            case .string(let fieldPath) = fields["fieldPath"], fieldPath.hasPrefix("$.arguments"),
            case .string(let expected) = fields["expected"]
        {
            return .invalidArguments(fieldPath: fieldPath, expected: expected)
        }
        if error.code == -32_003, fields["reason"] == .string("unknownCommand"),
            Set(fields.keys) == ["reason", "commandId", "closestMatches"],
            case .string(let commandId) = fields["commandId"],
            case .array(let values) = fields["closestMatches"], values.count <= 5
        {
            let matches = values.compactMap { value -> String? in
                guard case .string(let name) = value else { return nil }
                return name
            }
            guard matches.count == values.count else { return nil }
            return .unknownCommand(commandId: commandId, closestMatches: matches)
        }
        return nil
    }

    /// Accepts exactly the app's agent refusal shape: its own code, the
    /// matching reason, and an identifier-shaped name.
    private static func agentRefusal(from error: JSONRPCErrorPayload) -> IPCAgentRefusal? {
        let reason: IPCAgentRefusal.Reason
        switch error.code {
        case -32_011: reason = .notYetAllowed
        case -32_012: reason = .refusedForAgent
        default: return nil
        }
        guard case .object(let fields) = error.data,
            Set(fields.keys) == ["name", "reason"],
            fields["reason"] == .string(reason.rawValue),
            case .string(let name)? = fields["name"],
            name.wholeMatch(of: refusedIdentifierPattern) != nil
        else {
            return nil
        }
        return IPCAgentRefusal(reason: reason, name: name)
    }

    private nonisolated(unsafe) static let refusedIdentifierPattern = /[A-Za-z][A-Za-z0-9.]{0,127}/

    private static func documentedReason(
        from data: JSONValue?,
        descriptor: IPCAnyMethodDescriptor?
    ) -> String? {
        guard case .object(let fields) = data,
            case .string(let reason) = fields["reason"],
            descriptor?.metadata.documentedErrors.contains(where: { $0.reason == reason }) == true
        else {
            return nil
        }
        return reason
    }

    private static func schemaCorrection(
        from data: JSONValue?
    ) -> IPCSchemaValidationError? {
        guard case .object(let fields) = data,
            Set(fields.keys) == ["expected", "fieldPath", "reason"]
        else {
            return nil
        }
        return decode(IPCSchemaValidationError.self, from: fields)
    }

    private static func missingGrantScope(
        from error: JSONRPCErrorPayload
    ) -> IPCPermissionScope? {
        guard error.code == -32_002,
            case .object(let fields) = error.data,
            Set(fields.keys) == ["fieldPath", "reason", "requiredScope"],
            fields["reason"] == .string("missingGrant"),
            fields["fieldPath"] == .string("$.authorization"),
            let requiredScope = fields["requiredScope"]
        else {
            return nil
        }
        guard let scope = decode(IPCPermissionScope.self, from: requiredScope) else { return nil }
        switch scope.target {
        case .selfPane:
            return nil
        case .pane(let identifier):
            guard UUID(uuidString: identifier) != nil else { return nil }
        case .workspace, .app:
            break
        }
        return scope
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from fields: [String: JSONValue]
    ) -> Value? {
        decode(type, from: .object(fields))
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from value: JSONValue
    ) -> Value? {
        guard let encoded = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: encoded)
    }
}
