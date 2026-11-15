import Foundation
import Testing

@testable import AgentStudioIPCClientCore

/// The installer edits a file the user owns and shares with other tools, so
/// these cases are mostly about what it must not touch: their comments, their
/// other hooks, their `[features]` table, and their trust grants.
@Suite("Codex package installer")
struct CodexPackageInstallerTests {
    @Test("the owner's multiline policy and writable roots install without losing unrelated text")
    func ownerConfigurationInstallsStoreRoot() throws {
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        let original =
            "model = \"test\"\n[features]\nhooks = true\n[sandbox_workspace_write]\nwritable_roots = [\n  \"/keep\",\n]\n[policy]\nextra_policy = \"\"\"\n[features]\nhooks = false\n\"\"\"\n"
        try home.writeConfiguration(original)
        _ = try CodexPackageInstaller.install(home.props)
        let configuration = home.configuration()
        #expect(configuration.contains("\"/keep\""))
        #expect(configuration.contains(home.root.appending(path: "runtime/ipc").path))
        #expect(configuration.contains("extra_policy = \"\"\"\n[features]\nhooks = false\n\"\"\""))
    }

    @Test("a fresh install enables the feature, writes every hook entry and lands the skill")
    func freshInstall() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }

        // Act
        let output = try CodexPackageInstaller.install(home.props)

        // Assert
        #expect(home.configuration().contains("[features]"))
        #expect(home.configuration().contains("hooks = true"))
        let hooks = try home.hooksDocument()
        for event in CodexHookEventName.installedEvents {
            let owned = hooks.ownedGroups(
                event: event.rawValue,
                ownedCommandFragment: CodexPackageInstaller.ownedCommandFragment
            )
            #expect(owned.count == 1, "expected one owned group for \(event.rawValue)")
        }
        #expect(home.fileExists(relativePath: "skills/agentstudio/SKILL.md"))
        #expect(home.fileExists(relativePath: "skills/agentstudio/.agentstudio-package"))
        #expect(output.contains { $0.contains("trust") })
    }

    @Test("owned Codex hooks are async except SessionEnd and lifecycle timeouts don't trigger provider clamping")
    func ownedHookExecutionPolicyMatchesProvider() throws {
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        _ = try CodexPackageInstaller.install(home.props)
        for event in CodexHookEventName.installedEvents {
            let group = try #require(home.ownedGroup(event: event))
            let handler = try #require((group["hooks"] as? [[String: Any]])?.first)
            if event == .sessionEnd {
                #expect(handler["async"] == nil)
            } else {
                #expect(handler["async"] as? Bool == true)
            }
            let expectedTimeout =
                event == .sessionEnd || event == .interrupt ? 1 : CodexPackageInstaller.hookTimeoutSeconds
            #expect(handler["timeout"] as? Int == expectedTimeout)
        }
    }

    @Test("reinstall upgrades old Codex hooks and preserves every user hook in its original position")
    func reinstallUpgradesOldHookExecutionPolicy() throws {
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        let userHook: [String: Any] = [
            "matcher": "user-matcher", "userNote": "Keep my hook",
            "hooks": [["type": "command", "command": "/usr/local/bin/user-hook", "async": false, "timeout": 42]],
        ]
        let script = home.props.locator.hookScriptURL(
            provider: CodexPackageInstaller.providerIdentifier, scriptName: CodexPackageInstaller.hookScriptName)
        var hooks: [String: Any] = [:]
        for event in CodexHookEventName.installedEvents {
            let legacy: [String: Any] = [
                "hooks": [
                    [
                        "type": "command", "command": "\"\(script.path)\" \(event.rawValue)",
                        "timeout": CodexPackageInstaller.hookTimeoutSeconds,
                    ]
                ]
            ]
            hooks[event.rawValue] = [userHook, legacy]
        }
        let legacyDocument = try JSONSerialization.data(withJSONObject: ["hooks": hooks, "description": "Mine"])
        let legacyText = try #require(String(data: legacyDocument, encoding: .utf8))
        try home.writeHooks(legacyText)
        let output = try CodexPackageInstaller.install(home.props)
        let notices = output.filter { $0.hasPrefix("notice: replacing") }
        let expectedNotices = Set(
            CodexHookEventName.installedEvents.map {
                "notice: replacing modified agentstudio entry \($0.rawValue)"
            })
        let observedNotices = Set(notices)
        #expect(observedNotices == expectedNotices)
        #expect(notices.count == CodexHookEventName.installedEvents.count)
        let document = try home.hooksDocument()
        let expectedUser = try JSONSerialization.data(withJSONObject: userHook, options: [.sortedKeys])
        for event in CodexHookEventName.installedEvents {
            let groups = document.groups(event: event.rawValue)
            #expect(groups.count == 2)
            let first = try #require(groups.first)
            let observedUser = try JSONSerialization.data(withJSONObject: first, options: [.sortedKeys])
            #expect(observedUser == expectedUser)
            let owned = document.ownedGroups(
                event: event.rawValue, ownedCommandFragment: CodexPackageInstaller.ownedCommandFragment)
            #expect(owned.count == 1)
            let group = try #require(owned.first)
            let handler = try #require((group["hooks"] as? [[String: Any]])?.first)
            if event == .sessionEnd {
                #expect(handler["async"] == nil)
            } else {
                #expect(handler["async"] as? Bool == true)
            }
            let expectedTimeout =
                event == .sessionEnd || event == .interrupt ? 1 : CodexPackageInstaller.hookTimeoutSeconds
            #expect(handler["timeout"] as? Int == expectedTimeout)
        }
    }

    /// Codex runs the command through a shell, so a bundle path with a space
    /// must survive as one word.
    @Test("the hook command quotes the script path and names the event")
    func hookCommandIsShellSafe() throws {
        // Arrange
        let home = try CodexHomeFixture(packageDirectoryName: "Agent Studio Beta Package")
        defer { home.tearDown() }

        // Act
        _ = try CodexPackageInstaller.install(home.props)

        // Assert
        let command = try #require(home.ownedCommand(event: .sessionStart))
        #expect(command.hasPrefix("\""))
        #expect(command.hasSuffix("\" SessionStart"))
        #expect(command.contains(home.codexHome.appending(path: "agentstudio/agentstudio-codex-hook.sh").path))
        #expect(command.contains(CodexPackageInstaller.ownedCommandFragment))
    }

    @Test("an existing [features] table gains the key instead of a second table")
    func existingFeaturesTableIsExtended() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        try home.writeConfiguration(
            """
            # my notes
            model = "gpt-5.5-codex"

            [features]
            web_search = true

            [profiles.work]
            model = "gpt-5.5"
            """
        )

        // Act
        _ = try CodexPackageInstaller.install(home.props)

        // Assert
        let configuration = home.configuration()
        #expect(configuration.components(separatedBy: "[features]").count == 2)
        #expect(configuration.contains("# my notes"))
        #expect(configuration.contains("web_search = true"))
        #expect(configuration.contains("[profiles.work]"))
        // The key lands inside [features], not after the next table header.
        let featuresBody = try #require(
            configuration.components(separatedBy: "[features]").last?
                .components(separatedBy: "[profiles.work]").first)
        #expect(featuresBody.contains("hooks = true"))
    }

    @Test("features.hooks set to false is corrected in place")
    func disabledFeatureIsCorrected() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        try home.writeConfiguration("[features]\nhooks = false\nweb_search = true\n")

        // Act
        _ = try CodexPackageInstaller.install(home.props)

        // Assert
        #expect(home.configuration().contains("hooks = true"))
        #expect(home.configuration().contains("hooks = false") == false)
        #expect(home.configuration().contains("web_search = true"))
    }

    @Test("features.hooks already true is left exactly as written")
    func alreadyEnabledFeatureIsUntouched() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        let original =
            "[features]\n  hooks   =   true\n[sandbox_workspace_write]\nwritable_roots = [\"\(home.props.ipcDirectory.path)\"]\n"
        try home.writeConfiguration(original)

        // Act
        let output = try CodexPackageInstaller.install(home.props)

        // Assert
        #expect(home.configuration() == original)
        #expect(output.contains { $0.contains("already true") })
    }

    @Test("a [features] header carrying an inline comment is extended, not duplicated")
    func commentedFeaturesHeaderIsExtended() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        try home.writeConfiguration("[features]  # experimental toggles\nweb_search = true\n")

        // Act
        _ = try CodexPackageInstaller.install(home.props)

        // Assert
        let configuration = home.configuration()
        #expect(configuration.components(separatedBy: "[features]").count == 2)
        #expect(configuration.contains("# experimental toggles"))
        #expect(configuration.contains("hooks = true"))
        #expect(configuration.contains("web_search = true"))
    }

    @Test("a CRLF config gains the key inside its table and keeps its line endings")
    func carriageReturnConfigIsExtended() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        try home.writeConfiguration(
            "model = \"gpt-5.5-codex\"\r\n[features]\r\nweb_search = true\r\n")

        // Act
        _ = try CodexPackageInstaller.install(home.props)

        // Assert
        let configuration = home.configuration()
        #expect(configuration.components(separatedBy: "[features]").count == 2)
        #expect(configuration.contains("hooks = true\r\n"))
        #expect(configuration.replacingOccurrences(of: "\r\n", with: "").contains("\n") == false)
    }

    @Test("hooks = true followed by the user's comment counts as enabled and keeps the comment")
    func enabledHooksWithCommentIsUntouched() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        let original =
            "[features]\nhooks = true  # keep hooks on\n[sandbox_workspace_write]\nwritable_roots = [\"\(home.props.ipcDirectory.path)\"]\n"
        try home.writeConfiguration(original)

        // Act
        let output = try CodexPackageInstaller.install(home.props)

        // Assert
        #expect(home.configuration() == original)
        #expect(output.contains { $0.contains("already true") })
    }

    @Test("a features lookalike inside a multiline string is preserved and a real table is appended")
    func multilineFeaturesLookalikeIsPreserved() throws {
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        let original = "instructions = \"\"\"\n[features]\nhooks = false\n\"\"\"\n"
        try home.writeConfiguration(original)
        _ = try CodexPackageInstaller.install(home.props)
        #expect(home.configuration().hasPrefix(original))
        #expect(home.configuration().contains("\n[features]\nhooks = true\n"))
    }

    @Test("hooks belonging to someone else survive install untouched")
    func unrelatedHooksArePreserved() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        try home.writeHooks(
            """
            {
              "description": "my own hooks",
              "hooks": {
                "SessionStart": [
                  { "hooks": [{ "type": "command", "command": "/usr/local/bin/mine.sh", "timeout": 9 }] }
                ],
                "PostToolUse": [
                  { "matcher": "shell", "hooks": [{ "type": "command", "command": "/usr/local/bin/audit.sh" }] }
                ],
                "ForeignEvent": []
              }
            }
            """
        )

        // Act
        _ = try CodexPackageInstaller.install(home.props)

        // Assert — ours appended after theirs, so their trust key index holds.
        let installed = try home.hooksDocument()
        let sessionStart = installed.groups(event: "SessionStart")
        #expect(sessionStart.count == 2)
        #expect(Self.command(sessionStart[0]) == "/usr/local/bin/mine.sh")
        #expect(Self.command(sessionStart[1])?.contains(CodexPackageInstaller.ownedCommandFragment) == true)

        #expect(installed.groups(event: "PostToolUse").count == 1)
        let data = try #require(home.hooksData())
        let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(document["hooks"] as? [String: Any])
        #expect((hooks["ForeignEvent"] as? [Any])?.isEmpty == true)
    }

    @Test("reinstalling changes nothing and prints no notice")
    func reinstallIsIdempotent() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        _ = try CodexPackageInstaller.install(home.props)
        let firstConfiguration = home.configuration()
        let firstHooks = home.hooksData()

        // Act
        let output = try CodexPackageInstaller.install(home.props)

        // Assert
        #expect(home.configuration() == firstConfiguration)
        #expect(home.hooksData() == firstHooks)
        #expect(output.contains { $0.hasPrefix("notice:") } == false)
    }

    @Test("a hand-edited package entry is reported once and then restored")
    func modifiedEntryIsNoticedAndOverwritten() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        _ = try CodexPackageInstaller.install(home.props)
        try home.rewriteOwnedTimeout(event: .sessionStart, to: 99)

        // Act
        let output = try CodexPackageInstaller.install(home.props)

        // Assert
        let notices = output.filter { $0.hasPrefix("notice: replacing") }
        #expect(notices == ["notice: replacing modified agentstudio entry SessionStart"])
        let restored = try #require(home.ownedGroup(event: .sessionStart))
        let handler = try #require((restored["hooks"] as? [[String: Any]])?.first)
        #expect(handler["timeout"] as? Int == CodexPackageInstaller.hookTimeoutSeconds)
    }

    @Test("a Codex home that does not exist fails before anything is written")
    func missingCodexHomeFails() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        let absentHome = home.root.appending(path: "not-here", directoryHint: .isDirectory)
        let absent = CodexPackageInstaller.Props(
            codexHome: absentHome, locator: home.props.locator, ipcDirectory: home.props.ipcDirectory)

        // Act / Assert
        #expect(throws: AgentPackageInstallationError.self) {
            _ = try CodexPackageInstaller.install(absent)
        }
        #expect(FileManager.default.fileExists(atPath: absentHome.path) == false)
    }

    @Test("a malformed hooks.json fails and leaves both files untouched")
    func malformedHooksFileFailsWithoutWriting() throws {
        // Arrange
        let home = try CodexHomeFixture()
        defer { home.tearDown() }
        try home.writeConfiguration("model = \"gpt-5.5-codex\"\n")
        try home.writeHooks("{ this is not json")

        // Act / Assert
        #expect(throws: AgentPackageInstallationError.self) {
            _ = try CodexPackageInstaller.install(home.props)
        }
        #expect(home.configuration() == "model = \"gpt-5.5-codex\"\n")
        #expect(home.hooksText() == "{ this is not json")
    }

    @Test("the Codex home follows CODEX_HOME and then the home directory")
    func codexHomeResolution() {
        // Arrange / Act
        let explicit = CodexPackageInstaller.codexHome(
            explicitPath: "/tmp/explicit", environment: ["CODEX_HOME": "/tmp/env"])
        let fromEnvironment = CodexPackageInstaller.codexHome(
            explicitPath: nil, environment: ["CODEX_HOME": "/tmp/env"])
        let fallback = CodexPackageInstaller.codexHome(explicitPath: nil, environment: [:])

        // Assert
        #expect(explicit.path == "/tmp/explicit")
        #expect(fromEnvironment.path == "/tmp/env")
        #expect(fallback.lastPathComponent == ".codex")
    }

    private static func command(_ group: [String: Any]) -> String? {
        (group["hooks"] as? [[String: Any]])?.first?["command"] as? String
    }
}
