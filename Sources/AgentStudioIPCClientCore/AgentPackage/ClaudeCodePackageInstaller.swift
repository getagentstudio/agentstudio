import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

package enum ClaudeCodePackageInstallerError: Error, Equatable, Sendable {
    case configurationDirectoryUnavailable(String)
    case packageResourcesUnavailable(String)
    case settingsUnreadable(String)
    case settingsNotAnObject(String)
    case hooksValueNotAnObject(String)
}

/// Installs and removes Agent Studio's Claude Code integration inside one
/// Claude Code configuration directory.
///
/// Ownership is carried by the hook command itself: a matcher group is ours
/// exactly when one of its commands names this package's hook script. Nothing
/// else in `settings.json` is read as ownership, so a user's own hooks — even
/// on the same events — survive install, reinstall and uninstall untouched.
package struct ClaudeCodePackageInstallation: Sendable {
    /// Any hook command containing this path fragment belongs to this package.
    package static let ownershipMarker = "/AgentPackage/providers/claude/hooks/agentstudio-claude-hook.sh"

    /// Claude Code's own default; the hook returns as soon as the pane's socket
    /// answers, so a long ceiling would only delay a wedged turn.
    package static let hookTimeoutSeconds = 10.0

    package let configurationDirectory: URL
    package let packageRoot: URL
    package let providerVersion: String

    package init(configurationDirectory: URL, packageRoot: URL, providerVersion: String) {
        self.configurationDirectory = configurationDirectory
        self.packageRoot = packageRoot
        self.providerVersion = providerVersion
    }

    package var hookScriptURL: URL {
        packageRoot.appending(path: "providers/claude/hooks/agentstudio-claude-hook.sh")
    }

    package var skillDirectoryURL: URL {
        configurationDirectory.appending(path: "skills/agentstudio")
    }

    private var settingsURL: URL { configurationDirectory.appending(path: "settings.json") }
    private var skillMarkerURL: URL { skillDirectoryURL.appending(path: ".agentstudio-package") }
    private var sourceSkillURL: URL { packageRoot.appending(path: "skills/agentstudio/SKILL.md") }

    /// Merges this package's hook groups into `settings.json` and installs the
    /// model skill. Nothing is written until every input is readable, so a
    /// rejected install leaves the directory exactly as it was.
    package func install(notice: (String) -> Void) throws {
        try requireWritableConfigurationDirectory()
        guard FileManager.default.isReadableFile(atPath: hookScriptURL.path),
            FileManager.default.isReadableFile(atPath: sourceSkillURL.path)
        else {
            throw ClaudeCodePackageInstallerError.packageResourcesUnavailable(packageRoot.path)
        }
        let skillContents = try Data(contentsOf: sourceSkillURL)
        var settings = try readSettingsObject()
        // Uninstall already leaves a non-object `hooks` alone. Install must
        // refuse it for the same reason: replacing it would throw away a value
        // this package never wrote and cannot read.
        if let present = settings["hooks"], objectValue(present) == nil {
            throw ClaudeCodePackageInstallerError.hooksValueNotAnObject(settingsURL.path)
        }
        var hooksByEvent = objectValue(settings["hooks"]) ?? [:]
        for event in ClaudeCodeHookEvent.allCases {
            let desired = ownedGroup(for: event)
            var groups = arrayValue(hooksByEvent[event.rawValue]) ?? []
            let ownedIndexes = groups.indices.filter { isOwned(groups[$0]) }
            if ownedIndexes.isEmpty {
                groups.append(desired)
            } else {
                for index in ownedIndexes where groups[index] != desired {
                    notice("notice: replacing modified agentstudio entry \(event.rawValue)")
                }
                for index in ownedIndexes.dropFirst().reversed() { groups.remove(at: index) }
                groups[ownedIndexes[0]] = desired
            }
            hooksByEvent[event.rawValue] = .array(groups)
        }
        settings["hooks"] = .object(hooksByEvent)
        try writeAtomically(.object(settings), to: settingsURL)
        try FileManager.default.createDirectory(
            at: skillDirectoryURL, withIntermediateDirectories: true
        )
        try skillContents.write(to: skillDirectoryURL.appending(path: "SKILL.md"), options: .atomic)
        try Data(packageMarkerContents.utf8).write(to: skillMarkerURL, options: .atomic)
    }

    /// Removes exactly this package's hook groups and its marked skill. Event
    /// keys and the `hooks` container are dropped when nothing else occupies
    /// them, so uninstalling a fresh install restores the original document.
    package func uninstall(notice: (String) -> Void) throws {
        try requireWritableConfigurationDirectory()
        var settings = try readSettingsObject()
        if var hooksByEvent = objectValue(settings["hooks"]) {
            for (event, groupsValue) in hooksByEvent {
                guard let groups = arrayValue(groupsValue) else { continue }
                let retained = groups.filter { !isOwned($0) }
                guard retained.count != groups.count else { continue }
                if retained.isEmpty {
                    hooksByEvent.removeValue(forKey: event)
                } else {
                    hooksByEvent[event] = .array(retained)
                }
            }
            if hooksByEvent.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = .object(hooksByEvent)
            }
        }
        try writeAtomically(.object(settings), to: settingsURL)
        guard FileManager.default.isReadableFile(atPath: skillMarkerURL.path) else {
            notice("notice: no agentstudio skill installed at \(skillDirectoryURL.path)")
            return
        }
        try FileManager.default.removeItem(at: skillDirectoryURL)
    }
}

extension ClaudeCodePackageInstallation {
    fileprivate var packageMarkerContents: String {
        "\(ClaudeCodeProviderIdentity.identifier) \(providerVersion)\n"
    }

    /// Every hook entry runs async so a hook never makes the agent wait (PR B PD rev 32).
    /// The one exception is PermissionRequest under the "wait" policy: the agent asked to
    /// wait for the person's answer, so that entry stays synchronous.
    fileprivate func ownedGroup(for event: ClaudeCodeHookEvent) -> JSONValue {
        var entry: [String: JSONValue] = [
            "type": .string("command"),
            "command": .string(
                "\(hookScriptURL.path) \(event.rawValue) \(providerVersion)"
                    + (event == .permissionRequest ? " --permission-policy wait" : "")),
            "timeout": .number(
                event == .permissionRequest
                    ? CLIPolicy.permissionHookTimeoutSeconds : Self.hookTimeoutSeconds),
        ]
        if event != .permissionRequest { entry["async"] = .bool(true) }
        return .object(["hooks": .array([.object(entry)])])
    }

    fileprivate func isOwned(_ group: JSONValue) -> Bool {
        guard case .object(let fields) = group, let entries = arrayValue(fields["hooks"]) else {
            return false
        }
        return entries.contains { entry in
            guard case .object(let entryFields) = entry,
                case .string(let command)? = entryFields["command"]
            else { return false }
            return command.contains(Self.ownershipMarker)
        }
    }

    fileprivate func requireWritableConfigurationDirectory() throws {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: configurationDirectory.path, isDirectory: &isDirectory
            ), isDirectory.boolValue,
            FileManager.default.isWritableFile(atPath: configurationDirectory.path)
        else {
            throw ClaudeCodePackageInstallerError.configurationDirectoryUnavailable(
                configurationDirectory.path
            )
        }
    }

    fileprivate func readSettingsObject() throws -> [String: JSONValue] {
        guard FileManager.default.isReadableFile(atPath: settingsURL.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            throw ClaudeCodePackageInstallerError.settingsUnreadable(settingsURL.path)
        }
        guard !data.isEmpty else { return [:] }
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ClaudeCodePackageInstallerError.settingsUnreadable(settingsURL.path)
        }
        guard case .object(let fields) = decoded else {
            throw ClaudeCodePackageInstallerError.settingsNotAnObject(settingsURL.path)
        }
        return fields
    }

    fileprivate func writeAtomically(_ value: JSONValue, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    fileprivate func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let fields)? = value else { return nil }
        return fields
    }

    fileprivate func arrayValue(_ value: JSONValue?) -> [JSONValue]? {
        guard case .array(let elements)? = value else { return nil }
        return elements
    }
}
