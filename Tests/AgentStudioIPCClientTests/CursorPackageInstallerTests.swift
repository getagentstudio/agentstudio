import AgentStudioPrimitives
import Foundation
import Synchronization
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Cursor package installer")
struct CursorPackageInstallerTests {
    @Test("an unreadable hooks document is refused before other files are written")
    func unreadableHooksRefuse() throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let props = CursorPackageInstaller.Props(cursorHome: fixture.codexHome, locator: fixture.props.locator)
        try FileManager.default.createDirectory(at: props.hooksURL, withIntermediateDirectories: false)
        #expect(throws: AgentPackageInstallationError.configurationUnreadable(props.hooksURL.path)) {
            _ = try CursorPackageInstaller.install(props)
        }
        #expect(!fixture.fileExists(relativePath: "skills/agentstudio"))
    }

    @Test("reinstall and uninstall preserve foreign hooks and root keys", arguments: [false, true])
    func mergeAndUninstall(versionOnly: Bool) throws {
        let fixture = try CodexHomeFixture(packageDirectoryName: "Agent Studio Beta.app")
        defer { fixture.tearDown() }
        let foreign: [String: Any] = ["command": "/usr/local/bin/mine", "extra": ["keep": true]]
        let original: [String: Any] =
            versionOnly
            ? ["version": 1]
            : [
                "version": 1, "description": "keep",
                "hooks": [
                    "beforeSubmitPrompt": [foreign],
                    "preToolUse": [["command": "unrelated"]],
                ],
            ]
        let text = try #require(String(data: JSONSerialization.data(withJSONObject: original), encoding: .utf8))
        try fixture.writeHooks(text)
        let props = CursorPackageInstaller.Props(cursorHome: fixture.codexHome, locator: fixture.props.locator)
        _ = try CursorPackageInstaller.install(props)
        let installed = try #require(fixture.hooksData())
        _ = try CursorPackageInstaller.install(props)
        #expect(fixture.hooksData() == installed)
        let document = try #require(JSONSerialization.jsonObject(with: installed) as? [String: Any])
        #expect(document["version"] as? Int == 1)
        let hooks = try #require(document["hooks"] as? [String: Any])
        let ownedEvents: Set<String> = ["beforeSubmitPrompt", "stop", "sessionEnd"]
        for event in ownedEvents {
            let entries = try #require(hooks[event] as? [[String: Any]])
            let ours = entries.filter {
                ($0["command"] as? String)?.contains(CursorPackageInstaller.ownedCommandFragment) == true
            }
            #expect(ours.count == 1)
            #expect(ours.first?.keys.count == 1)
            #expect((ours.first?["command"] as? String)?.hasPrefix("\"") == true)
            #expect((ours.first?["command"] as? String)?.hasSuffix("\" \(event)") == true)
        }
        #expect(hooks["sessionStart"] == nil)
        #expect(hooks["subagentStart"] == nil)
        #expect(hooks["subagentStop"] == nil)
        _ = try CursorPackageInstaller.uninstall(props)
        #expect(!fixture.fileExists(relativePath: "skills/agentstudio"))
        let uninstalled = try #require(fixture.hooksData())
        let restored = try #require(JSONSerialization.jsonObject(with: uninstalled) as? [String: Any])
        let remaining = try #require(restored["hooks"] as? [String: Any])
        if versionOnly {
            #expect(remaining.isEmpty)
        } else {
            #expect(restored["description"] as? String == "keep")
            let prompt = try #require(remaining["beforeSubmitPrompt"] as? [[String: Any]])
            #expect(
                try JSONSerialization.data(withJSONObject: prompt, options: [.sortedKeys])
                    == JSONSerialization.data(withJSONObject: [foreign], options: [.sortedKeys]))
            #expect(remaining["preToolUse"] != nil)
        }
    }

    @Test(
        "invalid configuration refuses before hooks or skill changes",
        arguments: [
            "not JSON", "[]", #"{"version":1,"hooks":[]}"#,
            #"{"version":1,"hooks":{"stop":"not-an-array"}}"#,
        ])
    func invalidConfigurationWritesNothing(original: String) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        try fixture.writeHooks(original)
        #expect(throws: AgentPackageInstallationError.self) {
            _ = try CursorPackageInstaller.install(
                .init(cursorHome: fixture.codexHome, locator: fixture.props.locator))
        }
        #expect(fixture.hooksText() == original)
        #expect(!fixture.fileExists(relativePath: "skills/agentstudio"))
    }

    @Test("uninstall keeps an unmarked skill and a foreign hooks file byte-identical")
    func foreignFilesSurviveUninstall() throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let original = #"{"version":1, "hooks": {"stop":[{"command":"mine"}]}}"#
        try fixture.writeHooks(original)
        try fixture.writeSkillWithoutMarker()
        _ = try CursorPackageInstaller.uninstall(
            .init(cursorHome: fixture.codexHome, locator: fixture.props.locator))
        #expect(fixture.hooksText() == original)
        #expect(fixture.fileExists(relativePath: "skills/agentstudio/SKILL.md"))
    }

    @Test("missing Cursor home refuses before creating it")
    func missingHomeRefuses() throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let missing = fixture.root.appending(path: "missing-cursor")
        #expect(throws: AgentPackageInstallationError.self) {
            _ = try CursorPackageInstaller.install(.init(cursorHome: missing, locator: fixture.props.locator))
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("the package command installs Cursor into a disposable provider home")
    func commandInstallsCursor() throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let errors = Mutex<[String]>([])
        let code = AgentPackageCommandRunner.run(
            .install(provider: "cursor", providerHomePath: fixture.codexHome.path),
            props: .init(
                environment: ["AGENTSTUDIO_PACKAGE_ROOT": fixture.packageRoot.path], executableURL: nil,
                standardInput: { Data() }, correlationIdProvider: { UUIDv7.generate() },
                exampleIdentifierProvider: { UUIDv7.generate() }, standardOutputSink: { _ in },
                standardErrorSink: { line in errors.withLock { $0.append(line) } }))
        try #require(code == 0, "Cursor install exit \(code): \(errors.withLock { $0 })")
        #expect(fixture.fileExists(relativePath: "hooks.json"))
        #expect(fixture.fileExists(relativePath: "skills/agentstudio/SKILL.md"))
    }
}
