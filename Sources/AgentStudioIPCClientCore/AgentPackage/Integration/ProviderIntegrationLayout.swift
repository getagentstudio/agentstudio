import Foundation

package enum AgentPackageProvider: String, CaseIterable, Sendable {
    case claude, codex, cursor
}

package struct ProviderIntegrationLayout: Equatable, Sendable {
    package let provider: AgentPackageProvider
    package let home: URL
    package var directoryURL: URL { home.appending(path: "agentstudio") }
    package var scriptURL: URL { directoryURL.appending(path: "agentstudio-\(provider.rawValue)-hook.sh") }
    package var versionURL: URL { directoryURL.appending(path: "integration-version") }
    package var hookFileURL: URL { home.appending(path: provider == .claude ? "settings.json" : "hooks.json") }
}

package enum ProviderIntegrationVersion {
    package static func current(for provider: AgentPackageProvider) -> Int { provider == .cursor ? 2 : 1 }
}

package enum ProviderHookScript {
    package static func body(provider: AgentPackageProvider, version: Int) -> String {
        """
        #!/bin/sh
        # Agent Studio hook for \(provider.rawValue), integration version \(version). Installed by `agentstudio package install`.
        exec >/dev/null 2>&1
        [ -x "${AGENTSTUDIO_CLI:-}" ] || exit 0
        "$AGENTSTUDIO_CLI" hook \(provider.rawValue) "$1"
        exit 0

        """
    }
}

extension ProviderIntegrationLayout {
    package static func resolve(target: AgentPackageTarget, environment: [String: String]) throws -> Self {
        let home: URL
        switch target.provider {
        case .claude:
            guard
                let resolved = ClaudeCodePackageCommand.resolvedConfigurationDirectory(
                    options: .init(configurationDirectoryPath: target.homePath), environment: environment)
            else { throw AgentPackageInstallationError.providerHomeUnavailable("Claude configuration directory") }
            home = resolved
        case .codex: home = CodexPackageInstaller.codexHome(explicitPath: target.homePath, environment: environment)
        case .cursor: home = CursorPackageInstaller.cursorHome(explicitPath: target.homePath)
        }
        return .init(provider: target.provider, home: home)
    }
}
