import Foundation

/// Everything `agentstudio package install claude` needs from its process.
package struct ClaudeCodePackageCommandInputs {
    package let options: ClaudeCodePackageOptions
    package let environment: [String: String]
    package let executableURL: URL
    package let noticeSink: (String) -> Void
    package let errorSink: (String) -> Void

    package init(
        options: ClaudeCodePackageOptions,
        environment: [String: String],
        executableURL: URL,
        noticeSink: @escaping (String) -> Void,
        errorSink: @escaping (String) -> Void
    ) {
        self.options = options
        self.environment = environment
        self.executableURL = executableURL
        self.noticeSink = noticeSink
        self.errorSink = errorSink
    }
}

/// Installs validated Claude Code package options against the resolved home.
package enum ClaudeCodePackageCommand {
    package static func handle(_ inputs: ClaudeCodePackageCommandInputs) -> Int32 {
        guard
            let configurationDirectory = resolvedConfigurationDirectory(
                options: inputs.options, environment: inputs.environment)
        else {
            inputs.errorSink("agentstudio package: could not resolve the Claude Code configuration directory")
            return 1
        }
        let installation = ClaudeCodePackageInstallation(
            configurationDirectory: configurationDirectory,
            packageRoot: resolvedPackageRoot(inputs: inputs),
            providerVersion: "unknown"
        )
        do {
            try installation.install(notice: inputs.noticeSink)
            inputs.noticeSink("installed agentstudio Claude Code hooks in \(configurationDirectory.path)")
            return 0
        } catch {
            inputs.errorSink("agentstudio package install claude failed: \(describe(error))")
            return 1
        }
    }

    package static func resolvedConfigurationDirectory(
        options: ClaudeCodePackageOptions,
        environment: [String: String]
    ) -> URL? {
        if let explicit = options.configurationDirectoryPath {
            return URL(fileURLWithPath: explicit)
        }
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home).appending(path: ".claude")
    }

    /// The bundled CLI lives at `<app>/Contents/Helpers/agentstudio` and its
    /// package resources at `<app>/Contents/Resources/AgentPackage`, so the
    /// root is derived from the running executable rather than a search path.
    private static func resolvedPackageRoot(inputs: ClaudeCodePackageCommandInputs) -> URL {
        if let override = inputs.environment["AGENTSTUDIO_PACKAGE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return inputs.executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/AgentPackage")
    }

    private static func describe(_ error: any Error) -> String {
        if let installationError = error as? AgentPackageInstallationError {
            return installationError.description
        }
        return "unexpected failure"
    }
}
