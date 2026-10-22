import Darwin
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Provider skill tree installation")
struct AgentPackageSkillTreeTests {
    @Test("every provider installs and replaces the complete skill tree", arguments: SkillTreeProvider.allCases)
    func completeTreeReplacesStaleFiles(provider: SkillTreeProvider) throws {
        // Arrange: independent nested files, including an empty directory.
        let fixture = try SkillTreeInstallationFixture()
        defer { fixture.home.tearDown() }
        try fixture.writeSource(revision: "first")

        // Act / Assert
        try provider.install(fixture.home)
        let firstInstalled = try fixture.installedTree()
        let firstSource = try fixture.sourceTree()
        #expect(firstInstalled == firstSource)
        #expect(try fixture.marker() == provider.marker)
        try FileManager.default.createDirectory(
            at: fixture.installed.appending(path: "obsolete/empty"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: fixture.installed.appending(path: "obsolete/old.md"))
        try fixture.writeSource(revision: "replacement")
        try provider.install(fixture.home)
        let replacementInstalled = try fixture.installedTree()
        let replacementSource = try fixture.sourceTree()
        #expect(replacementInstalled == replacementSource)
        #expect(try fixture.marker() == provider.marker)
    }

    @Test("an unreadable nested source leaves skill and configuration untouched", arguments: SkillTreeProvider.allCases)
    func preparationFailureWritesNothing(provider: SkillTreeProvider) throws {
        // Arrange
        let fixture = try SkillTreeInstallationFixture()
        defer { fixture.home.tearDown() }
        try fixture.writeSource(revision: "first")
        try provider.install(fixture.home)
        let before = try fixture.installedTree(includeMarker: true)
        let configuration = try fixture.configurationSnapshot()
        try fixture.writeSource(revision: "replacement")
        let unreadable = fixture.source.appending(path: "references/message.md")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        // Act / Assert: nested preparation must precede even idempotent config rewrites.
        #expect(throws: (any Error).self) { try provider.install(fixture.home) }
        #expect(try fixture.installedTree(includeMarker: true) == before)
        #expect(try fixture.configurationSnapshot() == configuration)
    }

    @Test(
        "a refused directory publication preserves the prior complete generation", arguments: SkillTreeProvider.allCases
    )
    func publicationFailureKeepsPreviousTree(provider: SkillTreeProvider) throws {
        // Arrange: an immutable parent prevents replacing its entry, but permits
        // per-file writes inside the old child. Such a fallback must fail this test.
        let fixture = try SkillTreeInstallationFixture()
        defer { fixture.home.tearDown() }
        try fixture.writeSource(revision: "first")
        try provider.install(fixture.home)
        let before = try fixture.installedTree(includeMarker: true)
        let inode = try fixture.fileIdentity(fixture.installed)
        try fixture.writeSource(revision: "replacement")
        let parent = fixture.installed.deletingLastPathComponent()
        try #require(chflags(parent.path, UInt32(UF_IMMUTABLE)) == 0, "Cannot arrange immutable skill parent: \(errno)")
        defer { #expect(chflags(parent.path, 0) == 0, "Cannot restore scratch skill parent flags") }

        // Act / Assert
        #expect(throws: (any Error).self) { try provider.install(fixture.home) }
        #expect(try fixture.installedTree(includeMarker: true) == before)
        #expect(try fixture.fileIdentity(fixture.installed) == inode)
    }
}

enum SkillTreeProvider: String, CaseIterable, Sendable {
    case claude, codex, cursor

    var marker: String { self == .claude ? "claude-code 2.1.274\n" : "1\n" }

    func install(_ home: CodexHomeFixture) throws {
        switch self {
        case .claude:
            try ClaudeCodePackageInstallation(
                configurationDirectory: home.codexHome, packageRoot: home.packageRoot, providerVersion: "2.1.274"
            ).install(notice: { _ in })
        case .codex: _ = try CodexPackageInstaller.install(home.props)
        case .cursor:
            _ = try CursorPackageInstaller.install(.init(cursorHome: home.codexHome, locator: home.props.locator))
        }
    }
}

struct SkillTreeInstallationFixture {
    enum Entry: Equatable {
        case directory
        case file(Data)
    }

    struct ConfigurationFile: Equatable {
        let bytes: Data
        let inode: UInt64
    }

    let home: CodexHomeFixture
    var source: URL { home.packageRoot.appending(path: "skills/agentstudio") }
    var installed: URL { home.codexHome.appending(path: "skills/agentstudio") }

    init() throws {
        home = try CodexHomeFixture()
        let hook = home.packageRoot.appending(path: "providers/claude/hooks/agentstudio-claude-hook.sh")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: hook)
    }

    func writeSource(revision: String) throws {
        for path in ["references/empty", "agents"] {
            try FileManager.default.createDirectory(at: source.appending(path: path), withIntermediateDirectories: true)
        }
        for path in ["SKILL.md", "references/message.md", "agents/openai.yaml"] {
            try Data("\(path): \(revision)\n".utf8).write(to: source.appending(path: path))
        }
    }

    func sourceTree() throws -> [String: Entry] { try tree(at: source, includeMarker: false) }
    func installedTree(includeMarker: Bool = false) throws -> [String: Entry] {
        try tree(at: installed, includeMarker: includeMarker)
    }

    func marker() throws -> String {
        try String(contentsOf: installed.appending(path: ".agentstudio-package"), encoding: .utf8)
    }

    func fileIdentity(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    func configurationSnapshot() throws -> [String: ConfigurationFile] {
        var result: [String: ConfigurationFile] = [:]
        for name in ["settings.json", "config.toml", "hooks.json"] {
            let url = home.codexHome.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) {
                result[name] = try ConfigurationFile(bytes: Data(contentsOf: url), inode: fileIdentity(url))
            }
        }
        return result
    }

    private func tree(at root: URL, includeMarker: Bool) throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        for relative in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            if !includeMarker && relative == ".agentstudio-package" { continue }
            let url = root.appending(path: relative)
            let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            result[relative] = directory ? .directory : .file(try Data(contentsOf: url))
        }
        return result
    }
}
