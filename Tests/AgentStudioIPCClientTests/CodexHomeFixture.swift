import AgentStudioPrimitives
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

/// A throwaway Codex home plus a throwaway copy of the shipped package tree.
///
/// The package tree is built rather than read from the repository so the tests
/// exercise the same locator the bundled CLI uses, including its manifest check
/// and its hook-script path, without depending on an assembled app bundle.
struct CodexHomeFixture {
    let root: URL
    let codexHome: URL
    let packageRoot: URL
    private let fileManager = FileManager.default

    init(packageDirectoryName: String = "AgentPackage") throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "as-codex-package-\(UUIDv7.generate().uuidString)", directoryHint: .isDirectory)
        codexHome = root.appending(path: ".codex", directoryHint: .isDirectory)
        packageRoot =
            root
            .appending(path: packageDirectoryName, directoryHint: .isDirectory)
            .appending(path: "AgentPackage", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Self.writePackageTree(at: packageRoot)
    }

    var props: CodexPackageInstaller.Props {
        CodexPackageInstaller.Props(
            codexHome: codexHome,
            locator: AgentPackageResourceLocator(packageRoot: packageRoot),
            ipcDirectory: root.appending(path: "runtime/ipc")
        )
    }

    func tearDown() {
        try? fileManager.removeItem(at: root)
    }

    // MARK: - Reading

    func configuration() -> String {
        (try? String(contentsOf: codexHome.appending(path: "config.toml"), encoding: .utf8)) ?? ""
    }

    func hooksData() -> Data? {
        fileManager.contents(atPath: codexHome.appending(path: "hooks.json").path)
    }

    func hooksText() -> String {
        (try? String(contentsOf: codexHome.appending(path: "hooks.json"), encoding: .utf8)) ?? ""
    }

    func hooksDocument() throws -> CodexHooksDocument {
        let path = codexHome.appending(path: "hooks.json").path
        guard let data = fileManager.contents(atPath: path) else {
            throw AgentPackageInstallationError.configurationUnreadable(path)
        }
        return try CodexHooksDocument(data: data, path: path)
    }

    func ownedGroup(event: CodexHookEventName) -> [String: Any]? {
        try? hooksDocument().ownedGroups(
            event: event.rawValue,
            ownedCommandFragment: CodexPackageInstaller.ownedCommandFragment
        ).first
    }

    func ownedCommand(event: CodexHookEventName) -> String? {
        (ownedGroup(event: event)?["hooks"] as? [[String: Any]])?.first?["command"] as? String
    }

    func fileExists(relativePath: String) -> Bool {
        fileManager.fileExists(atPath: codexHome.appending(path: relativePath).path)
    }

    // MARK: - Arranging

    func writeConfiguration(_ contents: String) throws {
        try Data(contents.utf8).write(to: codexHome.appending(path: "config.toml"))
    }

    func writeHooks(_ contents: String) throws {
        try Data(contents.utf8).write(to: codexHome.appending(path: "hooks.json"))
    }

    func writeSkillWithoutMarker() throws {
        let directory =
            codexHome
            .appending(path: "skills", directoryHint: .isDirectory)
            .appending(path: "agentstudio", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("someone else's skill".utf8).write(to: directory.appending(path: "SKILL.md"))
    }

    /// Edits the installed entry the way a curious user would, so the next
    /// install has to notice the difference.
    func rewriteOwnedTimeout(event: CodexHookEventName, to timeout: Int) throws {
        let path = codexHome.appending(path: "hooks.json").path
        guard let data = fileManager.contents(atPath: path),
            var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var hooks = root["hooks"] as? [String: Any],
            var groups = hooks[event.rawValue] as? [[String: Any]],
            var handlers = groups[0]["hooks"] as? [[String: Any]]
        else {
            throw AgentPackageInstallationError.configurationUnreadable(path)
        }
        handlers[0]["timeout"] = timeout
        groups[0]["hooks"] = handlers
        hooks[event.rawValue] = groups
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: URL(fileURLWithPath: path))
    }

    private static func writePackageTree(at packageRoot: URL) throws {
        let fileManager = FileManager.default
        let hooksDirectory =
            packageRoot
            .appending(path: "providers", directoryHint: .isDirectory)
            .appending(path: "codex", directoryHint: .isDirectory)
            .appending(path: "hooks", directoryHint: .isDirectory)
        let skillDirectory =
            packageRoot
            .appending(path: "skills", directoryHint: .isDirectory)
            .appending(path: "agentstudio", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try Data(#"{"version":"1","providers":["codex"]}"#.utf8)
            .write(to: packageRoot.appending(path: "manifest.json"))
        let script = hooksDirectory.appending(path: CodexPackageInstaller.hookScriptName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data("# agentstudio\n".utf8).write(to: skillDirectory.appending(path: "SKILL.md"))
        let cursorHooks = packageRoot.appending(path: "providers/cursor/hooks")
        try fileManager.createDirectory(at: cursorHooks, withIntermediateDirectories: true)
        let cursorScript = cursorHooks.appending(path: "agentstudio-cursor-hook.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cursorScript)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cursorScript.path)
    }
}
