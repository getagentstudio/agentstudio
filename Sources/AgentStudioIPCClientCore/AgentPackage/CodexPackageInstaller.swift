import Foundation

/// Installs and removes the Agent Studio package inside a Codex home.
///
/// The shared installer copies the versioned script, enables `features.hooks`
/// in `config.toml`, merges owned handlers in `hooks.json`, and installs the skill.
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
        "/agentstudio/\(hookScriptName)"

    /// Not `Sendable`: it carries a `FileManager` and the installer runs to
    /// completion on the one thread the CLI invocation owns.
    package struct Props {
        package let codexHome: URL
        package let locator: AgentPackageResourceLocator
        package let ipcDirectory: URL
        package let fileManager: FileManager

        package init(
            codexHome: URL,
            locator: AgentPackageResourceLocator,
            ipcDirectory: URL,
            fileManager: FileManager = .default
        ) {
            self.codexHome = codexHome
            self.locator = locator
            self.ipcDirectory = ipcDirectory
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

    package static func install(_ props: Props) throws -> [String] {
        try ProviderIntegrationInstaller.install(
            .init(
                layout: .init(provider: .codex, home: props.codexHome), locator: props.locator,
                ipcDirectory: props.ipcDirectory))
    }
}
