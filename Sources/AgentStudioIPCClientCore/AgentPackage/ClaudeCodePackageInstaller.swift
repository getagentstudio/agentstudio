import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

/// Installs Agent Studio's Claude Code integration inside one
/// Claude Code configuration directory.
///
/// Keeps Claude's home and skill provenance at its existing boundary; hook
/// decoding, per-handler ownership and writes belong to the shared installer.
package struct ClaudeCodePackageInstallation: Sendable {
    /// Any hook command containing this path fragment belongs to this package.
    package static let ownershipMarker = "/agentstudio/agentstudio-claude-hook.sh"

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

    package func install(notice: (String) -> Void) throws {
        let lines = try ProviderIntegrationInstaller.install(
            .init(
                layout: .init(provider: .claude, home: configurationDirectory),
                locator: .init(packageRoot: packageRoot),
                skillMarker: Data("\(ClaudeCodeProviderIdentity.identifier) \(providerVersion)\n".utf8)))
        lines.filter { $0.hasPrefix("notice:") }.forEach(notice)
    }
}
