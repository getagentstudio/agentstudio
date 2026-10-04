import Foundation

/// Installs and removes the Agent Studio package inside a Codex home.
///
/// Three things land: `features.hooks = true` in `config.toml`, the package's
/// matcher groups in `hooks.json`, and the model skill under `skills/`.
/// `$CODEX_HOME/hooks.json` is a real discovery location — the user config
/// layer's hooks folder is the parent of its `config.toml`
/// (`codex-rs/config/src/state.rs:225`, `:239`), which `discover_handlers`
/// reads through `load_hooks_json`
/// (`codex-rs/hooks/src/engine/discovery.rs:146`, `:343`) — so the hooks go
/// there rather than into `config.toml`, whose `[hooks]` table in the same
/// layer would make Codex warn about two representations
/// (`discovery.rs:155`).
///
/// Nothing here grants trust. Codex trusts a hook only when its
/// `hooks.state.<key>.trusted_hash` matches the hook's current hash
/// (`discovery.rs:794`), which the user sets from Codex's own review prompt.
package enum CodexPackageInstaller {
    package static let providerIdentifier = "codex"
    package static let hookScriptName = "agentstudio-codex-hook.sh"
    package static let hookTimeoutSeconds = 5
    package static let skillDirectoryName = "agentstudio"
    package static let installationMarkerName = ".agentstudio-package"

    /// The path fragment that marks a hook entry as this package's. It is
    /// deliberately relative to the package tree rather than absolute, so an
    /// app that moved on disk still recognises its own previous entries.
    package static let ownedCommandFragment =
        "/AgentPackage/providers/codex/hooks/\(hookScriptName)"

    /// Not `Sendable`: it carries a `FileManager` and the installer runs to
    /// completion on the one thread the CLI invocation owns.
    package struct Props {
        package let codexHome: URL
        package let locator: AgentPackageResourceLocator
        package let fileManager: FileManager

        package init(
            codexHome: URL,
            locator: AgentPackageResourceLocator,
            fileManager: FileManager = .default
        ) {
            self.codexHome = codexHome
            self.locator = locator
            self.fileManager = fileManager
        }

        package var configurationURL: URL { codexHome.appending(path: "config.toml") }
        package var hooksURL: URL { codexHome.appending(path: "hooks.json") }
        package var skillDirectory: URL {
            codexHome
                .appending(path: "skills", directoryHint: .isDirectory)
                .appending(path: skillDirectoryName, directoryHint: .isDirectory)
        }
    }

    /// Resolves the Codex home the way Codex itself does: `$CODEX_HOME`, else
    /// `~/.codex`.
    package static func codexHome(
        explicitPath: String?,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL {
        if let explicitPath, !explicitPath.isEmpty {
            return URL(fileURLWithPath: explicitPath, isDirectory: true)
        }
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appending(
            path: ".codex", directoryHint: .isDirectory)
    }

    // MARK: - Install

    package static func install(_ props: Props) throws -> [String] {
        try requireWritableHome(props)
        let version = try props.locator.version(fileManager: props.fileManager)
        let scriptURL = props.locator.hookScriptURL(
            provider: providerIdentifier, scriptName: hookScriptName)
        guard props.fileManager.isReadableFile(atPath: scriptURL.path) else {
            throw AgentPackageInstallationError.packageResourcesUnavailable
        }
        let skillSource = props.locator.skillSourceDirectory.appending(path: "SKILL.md")
        guard let skillContents = props.fileManager.contents(atPath: skillSource.path) else {
            throw AgentPackageInstallationError.packageResourcesUnavailable
        }

        // Everything is decided and validated before any byte is written, so a
        // rejected input leaves the Codex home exactly as it was.
        let configuration = try plannedConfiguration(props)
        var notices: [String] = []
        let hooks = try plannedHooks(props, scriptURL: scriptURL, notices: &notices)

        var output = notices
        try AtomicFileWriter.write(
            Data(configuration.contents.utf8), to: props.configurationURL,
            fileManager: props.fileManager)
        output.append(configurationLine(configuration.outcome))
        try AtomicFileWriter.write(hooks, to: props.hooksURL, fileManager: props.fileManager)
        output.append(
            "wrote \(CodexHookEventName.installedEvents.count) hook entries to \(props.hooksURL.path)")
        try props.fileManager.createDirectory(
            at: props.skillDirectory, withIntermediateDirectories: true)
        try AtomicFileWriter.write(
            skillContents, to: props.skillDirectory.appending(path: "SKILL.md"),
            fileManager: props.fileManager)
        try AtomicFileWriter.write(
            Data("\(version)\n".utf8),
            to: props.skillDirectory.appending(path: installationMarkerName),
            fileManager: props.fileManager)
        output.append("installed the agentstudio skill in \(props.skillDirectory.path)")
        output.append(
            "start Codex and trust the agentstudio hooks in its hook review prompt; "
                + "untrusted hooks never run")
        return output
    }

    // MARK: - Uninstall

    package static func uninstall(_ props: Props) throws -> [String] {
        try requireWritableHome(props)
        var output: [String] = []
        var removedEntries = 0
        if let data = props.fileManager.contents(atPath: props.hooksURL.path) {
            var document = try CodexHooksDocument(data: data, path: props.hooksURL.path)
            for event in CodexHookEventName.installedEvents {
                removedEntries += document.removeOwnedGroups(
                    event: event.rawValue, ownedCommandFragment: ownedCommandFragment)
            }
            // A file this package never wrote is left byte-identical: no
            // re-encode, no deletion. Only an install of ours can have put
            // entries there, and only then can removing them empty the file.
            if removedEntries == 0 {
                output.append("no agentstudio hook entries to remove from \(props.hooksURL.path)")
            } else if document.carriesNothingButAnEmptyHooksTable {
                try props.fileManager.removeItem(at: props.hooksURL)
                output.append("removed \(removedEntries) hook entries and \(props.hooksURL.path)")
            } else {
                try AtomicFileWriter.write(
                    try document.encoded(), to: props.hooksURL, fileManager: props.fileManager)
                output.append(
                    "removed \(removedEntries) hook entries from \(props.hooksURL.path)")
            }
        } else {
            output.append("no hook entries to remove at \(props.hooksURL.path)")
        }

        let markerPath = props.skillDirectory.appending(path: installationMarkerName).path
        if props.fileManager.fileExists(atPath: markerPath) {
            try props.fileManager.removeItem(at: props.skillDirectory)
            output.append("removed the agentstudio skill from \(props.skillDirectory.path)")
        } else {
            output.append("left \(props.skillDirectory.path) alone; it carries no package marker")
        }
        output.append(
            "left features.hooks in \(props.configurationURL.path) enabled; other hooks may need it")
        return output
    }

    // MARK: - Planning

    private static func plannedConfiguration(
        _ props: Props
    ) throws -> (contents: String, outcome: CodexFeatureTableEditor.Outcome) {
        let existing: String
        if let data = props.fileManager.contents(atPath: props.configurationURL.path) {
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw AgentPackageInstallationError.configurationUnreadable(
                    props.configurationURL.path)
            }
            existing = decoded
        } else {
            existing = ""
        }
        return try CodexFeatureTableEditor.enablingHooks(
            in: existing, configurationPath: props.configurationURL.path)
    }

    private static func plannedHooks(
        _ props: Props,
        scriptURL: URL,
        notices: inout [String]
    ) throws -> Data {
        var document: CodexHooksDocument
        if let data = props.fileManager.contents(atPath: props.hooksURL.path) {
            document = try CodexHooksDocument(data: data, path: props.hooksURL.path)
        } else {
            document = CodexHooksDocument()
        }
        for event in CodexHookEventName.installedEvents {
            let replacedModified = document.replaceOwnedGroup(
                event: event.rawValue,
                with: matcherGroup(event: event, scriptURL: scriptURL),
                ownedCommandFragment: ownedCommandFragment
            )
            if replacedModified {
                notices.append("notice: replacing modified agentstudio entry \(event.rawValue)")
            }
        }
        return try document.encoded()
    }

    /// Codex runs a command hook through the user's shell, so the script path is
    /// double-quoted: an app bundle name such as `AgentStudio Beta.app` contains
    /// a space and would otherwise split into two words.
    package static func matcherGroup(
        event: CodexHookEventName,
        scriptURL: URL
    ) -> [String: Any] {
        // SessionEnd is forced synchronous by Codex. Interrupt can run async,
        // but both lifecycle events use the provider's one-second default.
        // PermissionRequest under the "wait" policy is the one wait the agent asks for,
        // so it stays synchronous with the derived permission timeout.
        var handler: [String: Any] = [
            "type": "command",
            CodexHooksDocument.commandKey: "\"\(scriptURL.path)\" \(event.rawValue)"
                + (event == .permissionRequest ? " --permission-policy wait" : ""),
            "timeout": event == .permissionRequest
                ? CLIPolicy.permissionHookTimeoutSeconds as Any
                : (event == .sessionEnd || event == .interrupt ? 1 : hookTimeoutSeconds) as Any,
        ]
        if event != .sessionEnd && event != .permissionRequest { handler["async"] = true }
        return [CodexHooksDocument.hooksKey: [handler]]
    }

    private static func requireWritableHome(_ props: Props) throws {
        var isDirectory: ObjCBool = false
        guard props.fileManager.fileExists(atPath: props.codexHome.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw AgentPackageInstallationError.providerHomeUnavailable(props.codexHome.path)
        }
        guard props.fileManager.isWritableFile(atPath: props.codexHome.path) else {
            throw AgentPackageInstallationError.providerHomeNotWritable(props.codexHome.path)
        }
    }

    private static func configurationLine(_ outcome: CodexFeatureTableEditor.Outcome) -> String {
        switch outcome {
        case .alreadyEnabled: "features.hooks was already true"
        case .enabledInExistingTable: "set features.hooks = true in the existing [features] table"
        case .appendedFeaturesTable: "appended [features] with hooks = true"
        }
    }
}

/// Writes through an auxiliary file and renames, so a reader never sees a
/// half-written configuration and a failed write leaves the original intact.
package enum AtomicFileWriter {
    package static func write(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try data.write(to: url, options: [.atomic])
    }
}
