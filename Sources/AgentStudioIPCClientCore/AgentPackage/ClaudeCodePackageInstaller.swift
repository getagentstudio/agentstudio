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

/// Installs Agent Studio's Claude Code integration inside one
/// Claude Code configuration directory.
///
/// Ownership is carried by the hook command itself: a matcher group is ours
/// exactly when one of its commands names this package's hook script. Nothing
/// else in `settings.json` is read as ownership, so a user's own hooks — even
/// on the same events — survive install and reinstall untouched.
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

    /// Merges this package's hook groups into `settings.json` and installs the
    /// model skill. Nothing is written until every input is readable, so a
    /// rejected install leaves the directory exactly as it was.
    package func install(notice: (String) -> Void) throws {
        try requireWritableConfigurationDirectory()
        guard FileManager.default.isReadableFile(atPath: hookScriptURL.path) else {
            throw ClaudeCodePackageInstallerError.packageResourcesUnavailable(packageRoot.path)
        }
        var settings = try readSettingsObject()
        // Replacing a non-object hooks value would throw away configuration
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
        let skill = try PreparedAgentSkillDirectory(
            source: packageRoot.appending(path: "skills/agentstudio"), providerHome: configurationDirectory,
            marker: Data(packageMarkerContents.utf8))
        defer { skill.discardStaging() }
        try writeAtomically(.object(settings), to: settingsURL)
        try skill.publish(to: skillDirectoryURL)
    }

}

extension ClaudeCodePackageInstallation {
    fileprivate var packageMarkerContents: String {
        "\(ClaudeCodeProviderIdentity.identifier) \(providerVersion)\n"
    }

    fileprivate func ownedGroup(for event: ClaudeCodeHookEvent) -> JSONValue {
        .object([
            "hooks": .array([
                .object([
                    "type": .string("command"),
                    "command": .string("\"\(hookScriptURL.path)\" \(event.rawValue) \(providerVersion)"),
                    "timeout": .number(Self.hookTimeoutSeconds),
                    "async": .bool(true),
                ])
            ])
        ])
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
