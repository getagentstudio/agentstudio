import AgentStudioProgrammaticControl
import Foundation

/// Everything `agentstudio package install claude` needs from its process.
package struct ClaudeCodePackageCommandInputs {
    package let options: ClaudeCodePackageOptions
    package let environment: [String: String]
    package let executableURL: URL
    package let noticeSink: (String) -> Void
    package let errorSink: (String) -> Void
    package let installedVersionReader: () -> String?

    package init(
        options: ClaudeCodePackageOptions,
        environment: [String: String],
        executableURL: URL,
        noticeSink: @escaping (String) -> Void,
        errorSink: @escaping (String) -> Void,
        installedVersionReader: @escaping () -> String? = ClaudeCodeInstalledVersion.read
    ) {
        self.options = options
        self.environment = environment
        self.executableURL = executableURL
        self.noticeSink = noticeSink
        self.errorSink = errorSink
        self.installedVersionReader = installedVersionReader
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
            providerVersion: resolvedProviderVersion(inputs: inputs)
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

    /// The installed release is written into every hook command, so a Claude
    /// Code upgrade reports the new version and the app refuses it as
    /// unqualified instead of admitting capabilities nobody verified.
    private static func resolvedProviderVersion(inputs: ClaudeCodePackageCommandInputs) -> String {
        if let explicit = inputs.options.providerVersion, !explicit.isEmpty {
            return explicit
        }
        if let installed = inputs.installedVersionReader() { return installed }
        inputs.noticeSink(
            "notice: claude --version unavailable; recording \(ClaudeCodeProviderIdentity.supportedExactVersion)"
        )
        return ClaudeCodeProviderIdentity.supportedExactVersion
    }

    private static func describe(_ error: any Error) -> String {
        if let installationError = error as? AgentPackageInstallationError {
            return installationError.description
        }
        return "unexpected failure"
    }
}

/// Reads the release of the `claude` executable on PATH. Absence is an ordinary
/// outcome: the user may install the hooks before Claude Code.
package enum ClaudeCodeInstalledVersion {
    package static func read() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return parsedVersion(text)
    }

    /// `claude --version` prints `2.1.274 (Claude Code)`.
    package static func parsedVersion(_ text: String) -> String? {
        let candidate = text.split(separator: " ").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty,
            candidate.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" })
        else {
            return nil
        }
        return candidate
    }
}
