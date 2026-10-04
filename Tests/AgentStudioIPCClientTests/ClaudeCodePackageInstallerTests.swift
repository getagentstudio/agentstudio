import AgentStudioIPCTransport
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

/// A throwaway Claude Code configuration directory plus a copy of the shipped
/// agent package, so the installer runs against the real resource layout.
private struct ClaudeCodePackageFixture {
    let root: URL
    let configurationDirectory: URL
    let packageRoot: URL

    static func make(file: String = #filePath) throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-claude-package-\(UUID().uuidString)")
        let configurationDirectory = root.appending(path: "config")
        let packageRoot = root.appending(path: "AgentPackage")
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: shippedPackageRoot(file: file), to: packageRoot)
        return Self(root: root, configurationDirectory: configurationDirectory, packageRoot: packageRoot)
    }

    /// `Tests/AgentStudioIPCClientTests` -> repository root -> shipped resources.
    static func shippedPackageRoot(file: String) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/AgentStudio/Resources/AgentPackage")
    }

    var settingsURL: URL { configurationDirectory.appending(path: "settings.json") }

    var installation: ClaudeCodePackageInstallation {
        ClaudeCodePackageInstallation(
            configurationDirectory: configurationDirectory,
            packageRoot: packageRoot,
            providerVersion: "2.1.274"
        )
    }

    func writeSettings(_ value: JSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: settingsURL)
    }

    func readSettings() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: settingsURL))
    }

    func settingsFields() throws -> [String: JSONValue] {
        guard case .object(let fields) = try readSettings() else { return [:] }
        return fields
    }

    func hookGroups(for event: String) throws -> [JSONValue] {
        guard case .object(let hooks)? = try settingsFields()["hooks"],
            case .array(let groups)? = hooks[event]
        else { return [] }
        return groups
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Claude Code package installer")
struct ClaudeCodePackageInstallerTests {
    private func ownedCommands(_ groups: [JSONValue]) -> [String] {
        groups.compactMap { group in
            guard case .object(let fields) = group, case .array(let entries)? = fields["hooks"],
                case .object(let entry)? = entries.first,
                case .string(let command)? = entry["command"],
                command.contains(ClaudeCodePackageInstallation.ownershipMarker)
            else { return nil }
            return command
        }
    }

    @Test("A fresh install writes one owned group per projected hook event")
    func freshInstallWritesEveryEvent() throws {
        // Arrange
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        var notices: [String] = []

        // Act
        try fixture.installation.install(notice: { notices.append($0) })

        // Assert
        #expect(notices.isEmpty)
        for event in ClaudeCodeHookEvent.allCases {
            let commands = ownedCommands(try fixture.hookGroups(for: event.rawValue))
            #expect(commands.count == 1)
            let suffix =
                " \(event.rawValue) 2.1.274"
                + (event == .permissionRequest ? " --permission-policy wait" : "")
            #expect(commands.first?.hasSuffix(suffix) == true)
        }
        let skill = fixture.configurationDirectory.appending(path: "skills/agentstudio/SKILL.md")
        let marker = fixture.configurationDirectory.appending(path: "skills/agentstudio/.agentstudio-package")
        #expect(FileManager.default.isReadableFile(atPath: skill.path))
        #expect(FileManager.default.isReadableFile(atPath: marker.path))
    }

    @Test("Claude permission waits synchronously while every other owned hook is async")
    func ownedHooksAreAsync() throws {
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        try fixture.installation.install(notice: { _ in })
        for event in ClaudeCodeHookEvent.allCases {
            let groups = try fixture.hookGroups(for: event.rawValue)
            let fields = try #require(Self.ownedHandler(groups))
            if event == .permissionRequest {
                #expect(fields["async"] == nil)
                #expect(fields["timeout"] == .number(CLIPolicy.permissionHookTimeoutSeconds))
            } else {
                #expect(fields["async"] == .bool(true))
                #expect(fields["timeout"] == .number(ClaudeCodePackageInstallation.hookTimeoutSeconds))
            }
        }
    }

    @Test("reinstall upgrades old synchronous owned Claude hooks and leaves the user's own entries untouched")
    func reinstallUpgradesOwnedHooksToAsync() throws {
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        let userHook = JSONValue.object([
            "matcher": .string("Bash"),
            "hooks": .array([
                .object([
                    "type": .string("command"), "command": .string("/usr/local/bin/user-hook"),
                    "async": .bool(false), "timeout": .number(42), "userNote": .string("Keep my hook"),
                ])
            ]),
        ])
        var events: [String: JSONValue] = [:]
        for event in ClaudeCodeHookEvent.allCases {
            let oldOwned = JSONValue.object([
                "hooks": .array([
                    .object([
                        "type": .string("command"),
                        "command": .string("\(fixture.installation.hookScriptURL.path) \(event.rawValue) 2.1.274"),
                        "timeout": .number(ClaudeCodePackageInstallation.hookTimeoutSeconds),
                    ])
                ])
            ])
            events[event.rawValue] = .array([userHook, oldOwned])
        }
        try fixture.writeSettings(.object(["model": .string("user-model"), "hooks": .object(events)]))
        var notices: [String] = []
        try fixture.installation.install(notice: { notices.append($0) })
        let expectedNotices = Set(
            ClaudeCodeHookEvent.allCases.map {
                "notice: replacing modified agentstudio entry \($0.rawValue)"
            })
        let observedNotices = Set(notices)
        #expect(observedNotices == expectedNotices)
        #expect(notices.count == ClaudeCodeHookEvent.allCases.count)
        for event in ClaudeCodeHookEvent.allCases {
            let groups = try fixture.hookGroups(for: event.rawValue)
            #expect(groups.count == 2)
            #expect(groups.first == userHook)
            let commands = ownedCommands(groups)
            #expect(commands.count == 1)
            let handler = try #require(Self.ownedHandler(groups))
            if event == .permissionRequest {
                #expect(handler["async"] == nil)
                #expect(handler["timeout"] == .number(CLIPolicy.permissionHookTimeoutSeconds))
            } else {
                #expect(handler["async"] == .bool(true))
                #expect(handler["timeout"] == .number(ClaudeCodePackageInstallation.hookTimeoutSeconds))
            }
        }
        let fields = try fixture.settingsFields()
        #expect(fields["model"] == .string("user-model"))
    }

    private static func ownedHandler(_ groups: [JSONValue]) -> [String: JSONValue]? {
        for group in groups {
            guard case .object(let fields) = group, case .array(let hooks)? = fields["hooks"] else { continue }
            for hook in hooks {
                guard case .object(let handler) = hook, case .string(let command)? = handler["command"],
                    command.contains(ClaudeCodePackageInstallation.ownershipMarker)
                else { continue }
                return handler
            }
        }
        return nil
    }

    @Test("Unrelated settings and unrelated hooks survive install and uninstall")
    func unrelatedSettingsSurvive() throws {
        // Arrange
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        let userHook = JSONValue.object([
            "matcher": .string("Bash"),
            "hooks": .array([
                .object([
                    "type": .string("command"),
                    "command": .string("/usr/local/bin/my-audit.sh"),
                    "timeout": .number(30),
                ])
            ]),
        ])
        let original = JSONValue.object([
            "model": .string("opusplan"),
            "env": .object(["MY_FLAG": .string("1")]),
            "hooks": .object(["PreToolUse": .array([userHook]), "PostToolUse": .array([userHook])]),
        ])
        try fixture.writeSettings(original)

        // Act
        try fixture.installation.install(notice: { _ in })
        let afterInstall = try fixture.settingsFields()
        try fixture.installation.uninstall(notice: { _ in })

        // Assert
        #expect(afterInstall["model"] == .string("opusplan"))
        #expect(afterInstall["env"] == .object(["MY_FLAG": .string("1")]))
        #expect(try fixture.hookGroups(for: "PreToolUse").contains(userHook))
        #expect(try fixture.hookGroups(for: "PostToolUse") == [userHook])
        #expect(try fixture.readSettings() == original)
    }

    @Test("Reinstalling the same package changes nothing and reports nothing")
    func reinstallIsIdempotent() throws {
        // Arrange
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        try fixture.installation.install(notice: { _ in })
        let first = try Data(contentsOf: fixture.settingsURL)
        var notices: [String] = []

        // Act
        try fixture.installation.install(notice: { notices.append($0) })

        // Assert
        #expect(try Data(contentsOf: fixture.settingsURL) == first)
        #expect(notices.isEmpty)
    }

    @Test("A modified owned entry is reported once and then restored")
    func modifiedOwnedEntryIsReported() throws {
        // Arrange
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        try fixture.installation.install(notice: { _ in })
        let expected = try Data(contentsOf: fixture.settingsURL)
        var fields = try fixture.settingsFields()
        guard case .object(var hooks)? = fields["hooks"],
            case .array(var groups)? = hooks["Stop"],
            case .object(var group) = groups[0],
            case .array(var entries)? = group["hooks"],
            case .object(var entry) = entries[0],
            case .string(let command)? = entry["command"]
        else {
            Issue.record("installed Stop entry was not shaped as expected")
            return
        }
        entry["timeout"] = .number(999)
        entry["command"] = .string(command)
        entries[0] = .object(entry)
        group["hooks"] = .array(entries)
        groups[0] = .object(group)
        hooks["Stop"] = .array(groups)
        fields["hooks"] = .object(hooks)
        try fixture.writeSettings(.object(fields))
        var notices: [String] = []

        // Act
        try fixture.installation.install(notice: { notices.append($0) })

        // Assert
        #expect(notices == ["notice: replacing modified agentstudio entry Stop"])
        #expect(try Data(contentsOf: fixture.settingsURL) == expected)
    }

    @Test("Uninstall removes exactly the package's entries and its marked skill")
    func uninstallRemovesOnlyOwnedEntries() throws {
        // Arrange
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        try fixture.installation.install(notice: { _ in })

        // Act
        try fixture.installation.uninstall(notice: { _ in })

        // Assert
        #expect(try fixture.settingsFields()["hooks"] == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.configurationDirectory.appending(path: "skills/agentstudio").path
            )
        )
    }

    @Test("A missing configuration directory fails without writing anything")
    func missingConfigurationDirectoryWritesNothing() throws {
        // Arrange
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        let absent = fixture.root.appending(path: "absent")
        let installation = ClaudeCodePackageInstallation(
            configurationDirectory: absent,
            packageRoot: fixture.packageRoot,
            providerVersion: "2.1.274"
        )

        // Act / Assert
        #expect(throws: ClaudeCodePackageInstallerError.configurationDirectoryUnavailable(absent.path)) {
            try installation.install(notice: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }

    /// Uninstall already steps around a non-object `hooks`. Install replacing it
    /// would destroy a value the package never wrote.
    @Test("A non-object hooks value aborts the install and writes nothing")
    func nonObjectHooksValueAbortsInstall() throws {
        // Arrange
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        try fixture.writeSettings(
            .object(["hooks": .string("mine"), "model": .string("opus")])
        )
        let original = try Data(contentsOf: fixture.settingsURL)

        // Act / Assert
        #expect(throws: ClaudeCodePackageInstallerError.hooksValueNotAnObject(fixture.settingsURL.path)) {
            try fixture.installation.install(notice: { _ in })
        }
        #expect(try Data(contentsOf: fixture.settingsURL) == original)
        #expect(
            !FileManager.default.fileExists(atPath: fixture.installation.skillDirectoryURL.path))
    }

    @Test("A missing package root fails before settings.json is touched")
    func missingPackageRootWritesNothing() throws {
        // Arrange
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        let installation = ClaudeCodePackageInstallation(
            configurationDirectory: fixture.configurationDirectory,
            packageRoot: fixture.root.appending(path: "absent-package"),
            providerVersion: "2.1.274"
        )

        // Act / Assert
        #expect(throws: ClaudeCodePackageInstallerError.self) {
            try installation.install(notice: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path))
    }
}

@Suite("Claude Code package command")
struct ClaudeCodePackageCommandTests {
    @Test("Arguments for another provider or command are not claimed")
    func unrelatedArgumentsAreNotClaimed() {
        // Arrange
        let unrelated = [["session.query"], ["package", "install", "codex"], ["package"]]

        // Act
        let outcomes = unrelated.map { arguments in
            ClaudeCodePackageCommand.handle(
                ClaudeCodePackageCommandInputs(
                    arguments: arguments,
                    environment: [:],
                    executableURL: URL(fileURLWithPath: "/tmp/agentstudio"),
                    noticeSink: { _ in },
                    errorSink: { _ in },
                    installedVersionReader: { nil }
                )
            )
        }

        // Assert
        #expect(outcomes.allSatisfy { $0 == nil })
    }

    @Test("Install and uninstall run against an explicit configuration directory")
    func installAndUninstallThroughTheCommand() throws {
        // Arrange
        let fixture = try ClaudeCodePackageFixture.make()
        defer { fixture.tearDown() }
        var notices: [String] = []
        var errors: [String] = []
        func run(_ verb: String) -> Int32? {
            ClaudeCodePackageCommand.handle(
                ClaudeCodePackageCommandInputs(
                    arguments: [
                        "package", verb, "claude", "--config-dir", fixture.configurationDirectory.path,
                    ],
                    environment: ["AGENTSTUDIO_PACKAGE_ROOT": fixture.packageRoot.path],
                    executableURL: URL(fileURLWithPath: "/tmp/agentstudio"),
                    noticeSink: { notices.append($0) },
                    errorSink: { errors.append($0) },
                    installedVersionReader: { "2.1.274" }
                )
            )
        }

        // Act
        let installExit = run("install")
        let installedGroups = try fixture.hookGroups(for: "SessionStart")
        let uninstallExit = run("uninstall")

        // Assert
        #expect(installExit == 0)
        #expect(uninstallExit == 0)
        #expect(errors.isEmpty)
        #expect(installedGroups.count == 1)
        #expect(try fixture.settingsFields()["hooks"] == nil)
    }

    @Test("An unreadable configuration directory reports one line and exits one")
    func unreadableConfigurationDirectoryExitsOne() {
        // Arrange
        var errors: [String] = []

        // Act
        let exitCode = ClaudeCodePackageCommand.handle(
            ClaudeCodePackageCommandInputs(
                arguments: ["package", "install", "claude", "--config-dir", "/nonexistent/agentstudio"],
                environment: [:],
                executableURL: URL(fileURLWithPath: "/tmp/agentstudio"),
                noticeSink: { _ in },
                errorSink: { errors.append($0) },
                installedVersionReader: { "2.1.274" }
            )
        )

        // Assert
        #expect(exitCode == 1)
        #expect(errors.count == 1)
        #expect(errors.first?.contains("configuration directory is missing or not writable") == true)
    }

    @Test("The installed Claude Code release is parsed from its version line")
    func versionLineIsParsed() {
        // Arrange / Act / Assert
        #expect(ClaudeCodeInstalledVersion.parsedVersion("2.1.274 (Claude Code)\n") == "2.1.274")
        #expect(ClaudeCodeInstalledVersion.parsedVersion("") == nil)
        #expect(ClaudeCodeInstalledVersion.parsedVersion("command not found") == nil)
    }
}
