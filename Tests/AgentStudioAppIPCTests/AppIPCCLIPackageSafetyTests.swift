import AgentStudioIPCClientCore
import AgentStudioPrimitives
import CryptoKit
import Foundation
import Testing

/// Literal contract from brief revision 3, independent of the grammar renderer.
let expectedPackageUsage = """
    Usage: agentstudio package install claude [--config-dir PATH] [--provider-version VERSION]
           agentstudio package install codex [--codex-home PATH | --provider-home PATH]
           agentstudio package install cursor [--provider-home PATH | --codex-home PATH]
    Installs Agent Studio's hooks and skill for one provider. Without a path it uses the provider's default home.
    """

@Suite("CLI package refusal leaves scratch provider homes unchanged", .serialized)
struct AppIPCCLIPackageSafetyTests {
    @Test(
        "Help and malformed Claude/Codex installs never enter installation",
        arguments: [
            ["package", "--help"],
            ["package", "install", "claude", "--help"],
            ["package", "install", "codex", "--codex-hom", "/x"],
            ["package", "install", "claude", "--config-dir", "--provider-version", "X"],
        ])
    func packageRefusalLeavesHomesUnchanged(arguments: [String]) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cli-package-safety-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try scratchEnvironment(root: root)
        let executable = try cliExecutableURL()
        let claudeHome = try #require(
            ClaudeCodePackageCommand.resolvedConfigurationDirectory(
                options: .init(), environment: environment))
        let codexHome = CodexPackageInstaller.codexHome(explicitPath: nil, environment: environment)
        // Fail closed before spawning even a baseline build that installs on typos.
        try #require(claudeHome.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"))
        try #require(codexHome.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"))
        let before = try contentsSnapshot(root)
        let output = try await runCLI(
            executableURL: executable, arguments: arguments, environment: environment, currentDirectoryURL: root)
        let isHelp = arguments.contains("--help")
        let reason =
            arguments.contains("codex") ? "unknown option --codex-hom for codex" : "missing value for --config-dir"
        #expect(output.exitCode == (isHelp ? 0 : 64))
        #expect(String(bytes: output.standardOutput, encoding: .utf8) == (isHelp ? expectedPackageUsage + "\n" : ""))
        #expect(
            String(bytes: output.standardError, encoding: .utf8)
                == (isHelp ? "" : "agentstudio package: \(reason)\n\(expectedPackageUsage)\n"))
        #expect(try contentsSnapshot(root) == before)
    }

    private func scratchEnvironment(root: URL) throws -> [String: String] {
        let home = root.appending(path: "home")
        let claude = home.appending(path: ".claude")
        let codex = home.appending(path: ".codex")
        for directory in [home, claude, codex] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("{}\n".utf8).write(to: claude.appending(path: "settings.json"))
        try Data("# fixture\n".utf8).write(to: codex.appending(path: "config.toml"))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return [
            "HOME": home.path, "CLAUDE_CONFIG_DIR": claude.path, "CODEX_HOME": codex.path,
            "AGENTSTUDIO_PACKAGE_ROOT": repository.appending(path: "Sources/AgentStudio/Resources/AgentPackage").path,
            "AGENTSTUDIO_IPC_SOCKET": root.appending(path: "ipc/app.sock").path,
            "AGENTSTUDIO_CLI_STORE": root.appending(path: "ipc/cli.sqlite").path,
            "AGENTSTUDIO_CLI_STORE_CHANNEL": "debug",
            // Prevent the baseline's version lookup from invoking an installed provider.
            "PATH": "/usr/bin:/bin",
        ]
    }

    private func contentsSnapshot(_ root: URL) throws -> [String: String] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        return try Dictionary(
            uniqueKeysWithValues: paths.map { path in
                let url = root.appending(path: path)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                let digest =
                    try values.isDirectory == true
                    ? "directory" : SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                return (path, digest)
            })
    }
}
