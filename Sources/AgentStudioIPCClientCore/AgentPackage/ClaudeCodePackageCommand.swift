import AgentStudioProgrammaticControl
import Foundation

/// Everything `agentstudio package <verb> claude` needs from its process.
package struct ClaudeCodePackageCommandInputs {
    package let arguments: [String]
    package let environment: [String: String]
    package let executableURL: URL
    package let noticeSink: (String) -> Void
    package let errorSink: (String) -> Void
    package let installedVersionReader: () -> String?

    package init(
        arguments: [String],
        environment: [String: String],
        executableURL: URL,
        noticeSink: @escaping (String) -> Void,
        errorSink: @escaping (String) -> Void,
        installedVersionReader: @escaping () -> String? = ClaudeCodeInstalledVersion.read
    ) {
        self.arguments = arguments
        self.environment = environment
        self.executableURL = executableURL
        self.noticeSink = noticeSink
        self.errorSink = errorSink
        self.installedVersionReader = installedVersionReader
    }
}

/// Parses `agentstudio package install claude [--config-dir <path>]`
/// and runs it against the resolved Claude Code configuration directory.
package enum ClaudeCodePackageCommand {
    package static let commandPrefix = ["package"]
    package static let providerArgument = "claude"

    /// - Returns: the process exit code when `arguments` address this command,
    ///   and `nil` when they belong to another command or another provider.
    package static func handle(_ inputs: ClaudeCodePackageCommandInputs) -> Int32? {
        guard inputs.arguments.first == commandPrefix.first,
            let verb = inputs.arguments.dropFirst().first,
            inputs.arguments.dropFirst(2).first == providerArgument
        else {
            return nil
        }
        guard verb == "install" else { return nil }
        let options = Array(inputs.arguments.dropFirst(3))
        guard let configurationDirectory = resolvedConfigurationDirectory(options: options, inputs: inputs)
        else {
            inputs.errorSink("agentstudio package: could not resolve the Claude Code configuration directory")
            return 1
        }
        let installation = ClaudeCodePackageInstallation(
            configurationDirectory: configurationDirectory,
            packageRoot: resolvedPackageRoot(inputs: inputs),
            providerVersion: resolvedProviderVersion(options: options, inputs: inputs)
        )
        do {
            try installation.install(notice: inputs.noticeSink)
            inputs.noticeSink("installed agentstudio Claude Code hooks in \(configurationDirectory.path)")
            return 0
        } catch {
            inputs.errorSink("agentstudio package \(verb) claude failed: \(describe(error))")
            return 1
        }
    }

    private static func resolvedConfigurationDirectory(
        options: [String],
        inputs: ClaudeCodePackageCommandInputs
    ) -> URL? {
        if let explicit = value(of: "--config-dir", in: options) {
            return URL(fileURLWithPath: explicit)
        }
        if let configured = inputs.environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        guard let home = inputs.environment["HOME"], !home.isEmpty else { return nil }
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
    private static func resolvedProviderVersion(
        options: [String],
        inputs: ClaudeCodePackageCommandInputs
    ) -> String {
        if let explicit = value(of: "--provider-version", in: options), !explicit.isEmpty {
            return explicit
        }
        if let installed = inputs.installedVersionReader() { return installed }
        inputs.noticeSink(
            "notice: claude --version unavailable; recording \(ClaudeCodeProviderIdentity.supportedExactVersion)"
        )
        return ClaudeCodeProviderIdentity.supportedExactVersion
    }

    private static func value(of option: String, in options: [String]) -> String? {
        guard let flagIndex = options.firstIndex(of: option),
            case let valueIndex = options.index(after: flagIndex), valueIndex < options.count
        else {
            return nil
        }
        return options[valueIndex]
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case ClaudeCodePackageInstallerError.configurationDirectoryUnavailable(let path):
            "configuration directory is missing or not writable: \(path)"
        case ClaudeCodePackageInstallerError.packageResourcesUnavailable(let path):
            "agent package resources are missing: \(path)"
        case ClaudeCodePackageInstallerError.settingsUnreadable(let path):
            "settings.json is not readable JSON: \(path)"
        case ClaudeCodePackageInstallerError.settingsNotAnObject(let path):
            "settings.json is not a JSON object: \(path)"
        case ClaudeCodePackageInstallerError.hooksValueNotAnObject(let path):
            "\(path) has a non-object \"hooks\" value; not modified"
        default:
            "unexpected failure"
        }
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
