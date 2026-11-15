import AgentStudioIPCClientCore
import AgentStudioPrimitives
import Foundation
import Testing

/// Confines even a CLI that mistakenly dispatches a rejected package verb.
struct PackageSubprocessFixture {
    let root: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "cli-package-safety-\(UUIDv7.generate())")
        let home = root.appending(path: "home")
        let claude = home.appending(path: ".claude")
        let codex = home.appending(path: ".codex")
        let cursor = home.appending(path: ".cursor")
        for directory in [home, claude, codex, cursor] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("{}\n".utf8).write(to: claude.appending(path: "settings.json"))
        try Data("# fixture\n".utf8).write(to: codex.appending(path: "config.toml"))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        environment = [
            "HOME": home.path, "CLAUDE_CONFIG_DIR": claude.path, "CODEX_HOME": codex.path,
            "AGENTSTUDIO_PACKAGE_ROOT": repository.appending(path: "Sources/AgentStudio/Resources/AgentPackage").path,
            "AGENTSTUDIO_IPC_SOCKET": root.appending(path: "ipc/app.sock").path,
            "AGENTSTUDIO_CLI_STORE": root.appending(path: "ipc/cli.sqlite").path,
            "AGENTSTUDIO_CLI_STORE_CHANNEL": "debug", "PATH": "/usr/bin:/bin",
        ]
    }

    func preflight(arguments: [String]) throws -> [String] {
        let claude = root.appending(path: "home/.claude")
        let codex = root.appending(path: "home/.codex")
        let cursor = root.appending(path: "home/.cursor")
        let resolvedClaude = try #require(
            ClaudeCodePackageCommand.resolvedConfigurationDirectory(
                options: .init(configurationDirectoryPath: claude.path), environment: environment))
        let resolvedCodex = CodexPackageInstaller.codexHome(explicitPath: codex.path, environment: environment)
        let resolvedCursor = CursorPackageInstaller.cursorHome(explicitPath: cursor.path)
        let prefix = root.resolvingSymlinksInPath().path + "/"
        for resolved in [resolvedClaude, resolvedCodex, resolvedCursor] {
            try #require(resolved.resolvingSymlinksInPath().path.hasPrefix(prefix))
        }
        let options: [String]
        switch arguments.dropFirst(2).first {
        case "claude": options = ["--config-dir", claude.path]
        case "codex": options = ["--codex-home", codex.path]
        default: options = ["--provider-home", cursor.path]
        }
        let insertion = min(3, arguments.count)
        return Array(arguments.prefix(insertion)) + options + Array(arguments.dropFirst(insertion))
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }
}
