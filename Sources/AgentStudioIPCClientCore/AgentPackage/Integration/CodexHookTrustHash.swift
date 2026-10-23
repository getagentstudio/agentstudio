import CryptoKit
import Foundation

/// Codex 0.154–0.163 ordinary command-hook identity, pinned to 83086188a.
package enum CodexHookTrustHash {
    enum HashFailure: Error { case unsupportedDeclaration }

    package static func supports(version: String) -> Bool {
        let components = version.split(separator: ".")
        guard components.count == 3, components[0] == "0", let minor = Int(components[1]),
            Int(components[2]) != nil
        else { return false }
        return (154...163).contains(minor)
    }

    package static func eventKey(_ event: String) -> String {
        var result = ""
        for character in event {
            if character.isUppercase, !result.isEmpty { result += "_" }
            result += character.lowercased()
        }
        return result
    }

    package static func hash(event: String, group: ProviderHookGroup, handler: ProviderCommandHook) throws -> String {
        guard handler.typeField == .command, !handler.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw HashFailure.unsupportedDeclaration }
        let lifecycle = event == "SessionEnd" || event == "Interrupt"
        let declaredTimeout = try unsignedInteger(handler.json["timeout"]) ?? (lifecycle ? 1 : 600)
        let timeout = lifecycle ? min(3, max(1, declaredTimeout)) : max(1, declaredTimeout)
        var command: [ProviderHookJSONValue.Member] = [
            .init(name: "type", value: .string("command")), .init(name: "command", value: .string(handler.command)),
            .init(name: "timeout", value: .scalar(String(timeout))),
            .init(name: "async", value: .boolean(handler.isAsync ?? false)),
        ]
        _ = try optionalString(handler.preserved["commandWindows"] ?? handler.preserved["command_windows"])
        if let status = try optionalString(handler.preserved["statusMessage"]) {
            command.append(.init(name: "statusMessage", value: .string(status)))
        }
        let contextEvents: Set<String> = [
            "PreToolUse", "PostToolUse", "SessionStart", "UserPromptSubmit", "SubagentStart",
        ]
        let limit = try unsignedInteger(handler.preserved["additionalContextLimit"])
        if contextEvents.contains(event), let limit, limit != 2500 {
            command.append(.init(name: "additionalContextLimit", value: .scalar(String(limit))))
        }
        var identity: [ProviderHookJSONValue.Member] = [
            .init(name: "event_name", value: .string(eventKey(event))),
            .init(name: "hooks", value: .array([.object(command)])),
        ]
        if !["UserPromptSubmit", "Stop", "Interrupt"].contains(event), let matcher = group.matcher {
            identity.append(.init(name: "matcher", value: .string(matcher)))
        }
        let bytes = Data(canonicalJSON(.object(identity)).utf8)
        return "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func unsignedInteger(_ value: ProviderHookJSONValue?) throws -> UInt64? {
        guard let value, value != .scalar("null") else { return nil }
        guard case .scalar(let raw) = value, !raw.isEmpty, raw.allSatisfy(\.isNumber), let integer = UInt64(raw)
        else { throw HashFailure.unsupportedDeclaration }
        return integer
    }

    private static func optionalString(_ value: ProviderHookJSONValue?) throws -> String? {
        guard let value, value != .scalar("null") else { return nil }
        guard let string = value.stringValue else { throw HashFailure.unsupportedDeclaration }
        return string
    }

    private static func canonicalJSON(_ value: ProviderHookJSONValue) -> String {
        switch value {
        case .scalar(let raw): raw
        case .array(let elements): "[" + elements.map(canonicalJSON).joined(separator: ",") + "]"
        case .object(let members):
            "{"
                + members.sorted { $0.name < $1.name }.map {
                    ProviderHookJSONValue.string($0.name).serialized + ":" + canonicalJSON($0.value)
                }.joined(separator: ",") + "}"
        }
    }
}
