import Foundation

/// A Codex `hooks.json` file, edited in place.
///
/// The document is held as untyped JSON rather than decoded into Swift models
/// because everything the package does not own must survive the round trip
/// byte-for-byte in meaning: other people's matcher groups, their `description`,
/// and any key a newer Codex adds.
///
/// Ownership is carried by the hook command itself — a group is the package's
/// when one of its command entries runs the package's hook script. No extra key
/// is added to the file: several Codex config types deny unknown fields, and a
/// marker the provider might reject is a marker that can break the provider.
package struct CodexHooksDocument {
    package static let hooksKey = "hooks"
    package static let commandKey = "command"

    private var root: [String: Any]

    package init() {
        root = [:]
    }

    package init(data: Data, path: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            throw AgentPackageInstallationError.configurationUnreadable(path)
        }
        self.root = root
    }

    /// Every matcher group for `event`, in file order.
    package func groups(event: String) -> [[String: Any]] {
        guard let hooks = root[Self.hooksKey] as? [String: Any],
            let groups = hooks[event] as? [[String: Any]]
        else {
            return []
        }
        return groups
    }

    package func ownedGroups(event: String, ownedCommandFragment: String) -> [[String: Any]] {
        groups(event: event).filter { Self.isOwned($0, commandFragment: ownedCommandFragment) }
    }

    /// Replaces the package's groups for `event` with `group`, leaving every
    /// other group in its original position and appending ours at the end.
    /// Appending rather than inserting keeps the `<source>:<event>:<group
    /// index>:<handler index>` trust keys of pre-existing groups stable, so a
    /// reinstall never silently revokes the user's other hook trust.
    /// Returns `true` when an existing owned group differed from `group`.
    @discardableResult
    package mutating func replaceOwnedGroup(
        event: String,
        with group: [String: Any],
        ownedCommandFragment: String
    ) -> Bool {
        let existing = groups(event: event)
        let owned = existing.filter { Self.isOwned($0, commandFragment: ownedCommandFragment) }
        let differs = owned.count == 1 ? !Self.equal(owned[0], group) : !owned.isEmpty
        let others = existing.filter { !Self.isOwned($0, commandFragment: ownedCommandFragment) }
        setGroups(event: event, to: others + [group])
        return differs
    }

    package func encoded() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private mutating func setGroups(event: String, to groups: [[String: Any]]) {
        var hooks = root[Self.hooksKey] as? [String: Any] ?? [:]
        hooks[event] = groups
        root[Self.hooksKey] = hooks
    }

    private static func isOwned(_ group: [String: Any], commandFragment: String) -> Bool {
        guard let handlers = group[hooksKey] as? [[String: Any]] else { return false }
        return handlers.contains { handler in
            guard let command = handler[commandKey] as? String else { return false }
            return command.contains(commandFragment)
        }
    }

    private static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        let options: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let left = try? JSONSerialization.data(withJSONObject: lhs, options: options),
            let right = try? JSONSerialization.data(withJSONObject: rhs, options: options)
        else {
            return false
        }
        return left == right
    }
}
