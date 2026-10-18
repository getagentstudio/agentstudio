import Foundation

/// Edits Cursor's flat command entries while retaining every foreign value.
package struct CursorHooksDocument {
    private var root: [String: Any]
    private var hooks: [String: Any]

    package init(data: Data?, path: String) throws {
        if let data {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentPackageInstallationError.configurationUnreadable(path)
            }
            root = parsed
            if let value = parsed["hooks"] {
                guard let object = value as? [String: Any] else {
                    throw AgentPackageInstallationError.configurationUnreadable(path)
                }
                hooks = object
            } else {
                hooks = [:]
            }
        } else {
            root = ["version": 1]
            hooks = [:]
        }
        for event in CursorHookEventName.installedEvents {
            if let value = hooks[event.rawValue], !(value is [Any]) {
                throw AgentPackageInstallationError.configurationUnreadable(path)
            }
        }
    }

    package mutating func replaceOwnedEntries(scriptURL: URL?) -> Int {
        var removed = 0
        for event in CursorHookEventName.installedEvents {
            let entries = hooks[event.rawValue] as? [Any] ?? []
            var remaining = entries.filter { entry in
                guard let fields = entry as? [String: Any], let command = fields["command"] as? String else {
                    return true
                }
                return !command.contains(CursorPackageInstaller.ownedCommandFragment)
            }
            removed += entries.count - remaining.count
            if let scriptURL {
                remaining.append(["command": "\"\(scriptURL.path)\" \(event.rawValue)"])
            }
            if remaining.isEmpty {
                hooks.removeValue(forKey: event.rawValue)
            } else {
                hooks[event.rawValue] = remaining
            }
        }
        return removed
    }

    package func encoded() throws -> Data {
        var document = root
        document["hooks"] = hooks
        return try JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
