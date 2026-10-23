import AgentStudioIPCTransport
import AgentStudioTestHarness
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Provider integration copy and preservation")
struct ProviderIntegrationInstallerTests {
    @Test("install copies a versioned script into the provider home", arguments: ["claude", "codex", "cursor"])
    func installsCopiedVersionedScript(provider: String) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        try install(provider: provider, fixture: fixture)
        let script = fixture.codexHome.appending(path: "agentstudio/agentstudio-\(provider)-hook.sh")
        let attributes = try FileManager.default.attributesOfItem(atPath: script.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        let body = try String(contentsOf: script, encoding: .utf8)
        #expect(body.contains("exec >/dev/null 2>&1"))
        #expect(body.contains("hook \(provider) \"$1\""))
        #expect(!body.contains("--provider-version"))
        #expect(
            try String(
                contentsOf: script.deletingLastPathComponent().appending(path: "integration-version"), encoding: .utf8)
                == (provider == "cursor" ? "2\n" : "1\n"))
        let hookFile = fixture.codexHome.appending(path: provider == "claude" ? "settings.json" : "hooks.json")
        let text = try String(contentsOf: hookFile, encoding: .utf8)
        #expect(text.contains(script.path))
        #expect(!text.contains("/AgentPackage/providers/"))
    }

    @Test("reinstall retains foreign positions and handlers sharing our group")
    func reinstallRetainsForeignPositions() throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let command =
            "\"\(shippedPackageRoot.appending(path: "providers/codex/hooks/agentstudio-codex-hook.sh").path)\" SessionStart"
        let original: JSONValue = .object([
            "hooks": .object([
                "SessionStart": .array([
                    .object([
                        "description": .string("keep"),
                        "hooks": .array([
                            .object(["type": .string("command"), "command": .string(command)]),
                            .object(["type": .string("mcp_tool"), "server": .string("mine"), "tool": .string("keep")]),
                        ]),
                    ]),
                    .object([
                        "matcher": .string("foreign"),
                        "hooks": .array([
                            .object(["type": .string("command"), "command": .string("foreign-command")])
                        ]),
                    ]),
                ])
            ])
        ])
        try JSONEncoder().encode(original).write(to: fixture.codexHome.appending(path: "hooks.json"))
        try install(provider: "codex", fixture: fixture)
        let result = try JSONDecoder().decode(JSONValue.self, from: #require(fixture.hooksData()))
        guard case .object(let root) = result, case .object(let hooks)? = root["hooks"],
            case .array(let groups)? = hooks["SessionStart"], case .object(let first)? = groups.first,
            case .array(let handlers)? = first["hooks"]
        else {
            Issue.record("installed document lost its groups")
            return
        }
        #expect(first["description"] == .string("keep"))
        #expect(handlers.count == 2)
        #expect(
            handlers.last == .object(["type": .string("mcp_tool"), "server": .string("mine"), "tool": .string("keep")]))
        #expect(groups.count == 2)
        guard case .object(let last)? = groups.last else {
            Issue.record("missing foreign group")
            return
        }
        #expect(last["matcher"] == .string("foreign"))
    }

    @Test(
        "the copied shell wrapper is silent for every failure route",
        arguments: ["missing", "non-executable", "exit-one", "noisy", "abort", "malformed-input"])
    func hookWrapperIsSilent(scenario: String) async throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        try install(provider: "codex", fixture: fixture)
        let cli = fixture.root.appending(path: "failing-cli")
        let body: String
        switch scenario {
        case "exit-one": body = "exit 1"
        case "noisy": body = "printf noisy; printf noisy >&2"
        case "abort": body = "kill -ABRT $$"
        case "malformed-input": body = "cat >/dev/null; exit 1"
        default: body = "exit 0"
        }
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: cli)
        try FileManager.default.setAttributes(
            [.posixPermissions: scenario == "non-executable" ? 0o644 : 0o755], ofItemAtPath: cli.path)
        let output = fixture.root.appending(path: "stdout")
        let errors = fixture.root.appending(path: "stderr")
        let input = fixture.root.appending(path: "stdin")
        try Data().write(to: output)
        try Data().write(to: errors)
        try Data("{malformed".utf8).write(to: input)
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        let stdin = try FileHandle(forReadingFrom: input)
        defer {
            try? stdout.close()
            try? stderr.close()
            try? stdin.close()
        }
        let environment = [
            "AGENTSTUDIO_CLI": scenario == "missing" ? "" : cli.path, "HOME": fixture.root.path,
            "CODEX_HOME": fixture.codexHome.path, "CLAUDE_CONFIG_DIR": fixture.root.appending(path: "claude").path,
            "PATH": "/usr/bin:/bin",
        ]
        let resolved = CodexPackageInstaller.codexHome(explicitPath: fixture.codexHome.path, environment: environment)
        try #require(
            resolved.resolvingSymlinksInPath().path.hasPrefix(fixture.root.resolvingSymlinksInPath().path + "/"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            fixture.codexHome.appending(path: "agentstudio/agentstudio-codex-hook.sh").path, "SessionStart",
        ]
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        let status = try await awaitProcessExit(process)
        #expect(status == 0)
        #expect(try Data(contentsOf: output).isEmpty)
        #expect(try Data(contentsOf: errors).isEmpty)
    }

    @Test("snippet is byte-identical to fresh installed entries", arguments: AgentPackageProvider.allCases)
    func snippetMatchesInstalledEntries(provider: AgentPackageProvider) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        try install(provider: provider.rawValue, fixture: fixture)
        let layout = ProviderIntegrationLayout(provider: provider, home: fixture.codexHome)
        #expect(
            Data(try ProviderExpectedEntries.snippet(layout: layout).utf8) == (try Data(contentsOf: layout.hookFileURL))
        )
        #expect(
            try Data(contentsOf: layout.scriptURL)
                == Data(
                    ProviderHookScript.body(
                        provider: provider, version: ProviderIntegrationVersion.current(for: provider)
                    ).utf8)
        )
    }

    @Test("malformed provider hooks preserve every existing artifact", arguments: AgentPackageProvider.allCases)
    func malformedHooksPreserveEveryArtifact(provider: AgentPackageProvider) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        try install(provider: provider.rawValue, fixture: fixture)
        let layout = ProviderIntegrationLayout(provider: provider, home: fixture.codexHome)
        try Data(#"{"hooks":{"stop":"broken"}}"#.utf8).write(to: layout.hookFileURL)
        let before = try manifest(fixture.root)
        #expect(throws: AgentPackageInstallationError.configurationUnreadable(layout.hookFileURL.path)) {
            try install(provider: provider.rawValue, fixture: fixture)
        }
        #expect(try manifest(fixture.root) == before)
    }

    @Test("replacing only the script leaves Codex declarations and trust text unchanged")
    func scriptOnlyReinstallKeepsTrust() throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let layout = ProviderIntegrationLayout(provider: .codex, home: fixture.codexHome)
        let configuration =
            "[features]\nhooks = true\n[hooks.state.\"/fixture/hooks.json:session_start:0:0\"]\ntrusted_hash = \"owner-trust\"\nenabled = false\n"
        try fixture.writeConfiguration(configuration)
        let props = ProviderIntegrationInstaller.Props(layout: layout, locator: .init(packageRoot: shippedPackageRoot))
        _ = try ProviderIntegrationInstaller.install(props)
        let entries = try Data(contentsOf: layout.hookFileURL)
        try Data("#!/bin/sh\n# older body\nexit 0\n".utf8).write(to: layout.scriptURL)
        _ = try ProviderIntegrationInstaller.install(props)
        #expect(try Data(contentsOf: layout.hookFileURL) == entries)
        #expect(fixture.configuration() == configuration)
    }

    private func manifest(_ root: URL) throws -> [String: String] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        return try Dictionary(
            uniqueKeysWithValues: paths.map { path in
                let url = root.appending(path: path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let value =
                    attributes[.type] as? FileAttributeType == .typeDirectory
                    ? "directory"
                    : SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                return (path, value)
            })
    }

    private var shippedPackageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/AgentStudio/Resources/AgentPackage")
    }

    private func install(provider: String, fixture: CodexHomeFixture) throws {
        let locator = AgentPackageResourceLocator(packageRoot: shippedPackageRoot)
        switch provider {
        case "claude":
            try ClaudeCodePackageInstallation(
                configurationDirectory: fixture.codexHome, packageRoot: shippedPackageRoot, providerVersion: "2.1.274"
            ).install(notice: { _ in })
        case "codex":
            _ = try CodexPackageInstaller.install(
                .init(codexHome: fixture.codexHome, locator: locator, ipcDirectory: fixture.root.appending(path: "ipc"))
            )
        default:
            _ = try CursorPackageInstaller.install(.init(cursorHome: fixture.codexHome, locator: locator))
        }
    }
}
