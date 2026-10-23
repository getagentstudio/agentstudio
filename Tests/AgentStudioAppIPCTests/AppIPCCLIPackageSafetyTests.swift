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
           agentstudio package snippet claude|codex|cursor [OPTIONS]
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
        let fixture = try PackageSubprocessFixture()
        defer { fixture.dispose() }
        let root = fixture.root
        let containedArguments = try fixture.preflight(arguments: arguments)
        let executable = try cliExecutableURL()
        let before = try contentsSnapshot(root)
        let output = try await runCLI(
            executableURL: executable, arguments: containedArguments, environment: fixture.environment,
            currentDirectoryURL: root)
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
