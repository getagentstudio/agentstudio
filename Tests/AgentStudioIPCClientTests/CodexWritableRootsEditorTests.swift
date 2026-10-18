import AgentStudioPrimitives
import Foundation
import Synchronization
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Codex writable roots")
struct CodexWritableRootsEditorTests {
    @Test("an unreadable Codex configuration is refused before other files are written")
    func unreadableConfigurationRefuses() throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        try FileManager.default.createDirectory(at: fixture.props.configurationURL, withIntermediateDirectories: false)
        #expect(throws: AgentPackageInstallationError.configurationUnreadable(fixture.props.configurationURL.path)) {
            _ = try CodexPackageInstaller.install(fixture.props)
        }
        #expect(!fixture.fileExists(relativePath: "hooks.json"))
        #expect(!fixture.fileExists(relativePath: "skills/agentstudio"))
    }

    @Test(
        "root additions match literal valid TOML",
        arguments: [
            ("", "[sandbox_workspace_write]\nwritable_roots = [\"/runtime/ipc\"]\n"),
            (
                "[sandbox_workspace_write]\nwritable_roots = [\n  '/keep']\n",
                "[sandbox_workspace_write]\nwritable_roots = [\n  '/keep',\n  \"/runtime/ipc\",\n]\n"
            ),
            (
                "[sandbox_workspace_write]\nwritable_roots = ['/keep']\n",
                "[sandbox_workspace_write]\nwritable_roots = ['/keep', \"/runtime/ipc\"]\n"
            ),
            (
                "[sandbox_workspace_write]\nwritable_roots = [\n  '/keep',\n]\n",
                "[sandbox_workspace_write]\nwritable_roots = [\n  '/keep',\n  \"/runtime/ipc\",\n]\n"
            ),
        ])
    func literalRootEdits(scenario: (String, String)) throws {
        let edited = try CodexWritableRootsEditor.updating(
            scenario.0, directory: "/runtime/ipc", configurationPath: "fixture")
        #expect(edited.contents == scenario.1)
    }

    @Test("installer notices once and uninstall removes only its directory")
    func installerRootLifecycle() throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        try fixture.writeConfiguration("[sandbox_workspace_write]\nwritable_roots = ['/keep']\n")
        let first = try CodexPackageInstaller.install(fixture.props)
        #expect(first.filter { $0.hasPrefix("notice: added ") }.count == 1)
        #expect(first.contains { $0.contains("dotfiles-managed") })
        let repeated = try CodexPackageInstaller.install(fixture.props)
        #expect(!repeated.contains { $0.hasPrefix("notice: added ") })
        _ = try CodexPackageInstaller.uninstall(fixture.props)
        #expect(!fixture.configuration().contains(fixture.props.ipcDirectory.path))
        #expect(fixture.configuration().contains("'/keep'"))
        #expect(fixture.configuration().contains("writable_roots"))
        #expect(fixture.configuration().contains("hooks = true"))
    }

    @Test(
        "install discovers the store directory or refuses without writing", arguments: ["stable", "beta", "debug"],
        ["explicit", "metadata", "missing", "mismatch"])
    func installUsesExistingStoreContext(channel: String, source: String) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let directory = fixture.root.appending(path: "runtime/\(channel)/ipc")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appending(path: "cli.sqlite")
        let socket =
            source == "explicit"
            ? fixture.root.appending(path: "separate-socket/agent.sock") : directory.appending(path: "agent.sock")
        var environment = ["AGENTSTUDIO_PACKAGE_ROOT": fixture.packageRoot.path]
        if source == "explicit" {
            environment["AGENTSTUDIO_CLI_STORE"] = store.path
            environment["AGENTSTUDIO_CLI_STORE_CHANNEL"] = channel
            environment["AGENTSTUDIO_IPC_SOCKET"] = socket.path
        } else if source != "missing" {
            environment["AGENTSTUDIO_IPC_SOCKET"] = socket.path
            try Data().write(to: store)
            try JSONSerialization.data(withJSONObject: [
                "socketPath": source == "mismatch" ? "/other/socket" : socket.path, "channel": channel,
            ]).write(to: directory.appending(path: "runtime.json"))
        }
        let errors = Mutex<[String]>([])
        let result = AgentPackageCommandRunner.run(
            .install(provider: "codex", providerHomePath: fixture.codexHome.path),
            props: .init(
                environment: environment, executableURL: nil, standardInput: { Data() },
                correlationIdProvider: { UUIDv7.generate() }, exampleIdentifierProvider: { UUIDv7.generate() },
                standardOutputSink: { _ in }, standardErrorSink: { text in errors.withLock { $0.append(text) } }))
        if source == "missing" || source == "mismatch" {
            #expect(result == 1)
            #expect(errors.withLock { $0 } == ["run this from an Agent Studio pane"])
            #expect(!fixture.fileExists(relativePath: "config.toml"))
            #expect(!fixture.fileExists(relativePath: "hooks.json"))
            #expect(!fixture.fileExists(relativePath: "skills/agentstudio"))
        } else {
            #expect(result == 0, "\(errors.withLock { $0 })")
            #expect(fixture.configuration().contains(directory.path))
            if source == "explicit" {
                #expect(!FileManager.default.fileExists(atPath: store.path))
                #expect(!fixture.configuration().contains(socket.deletingLastPathComponent().path))
            }
        }
    }

    @Test(
        "adds exactly one store directory and removes only that element",
        arguments: [
            "", "model = 'keep'\n",
            "[sandbox_workspace_write]\nnetwork_access = true\n",
            "[sandbox_workspace_write]\nwritable_roots = []\n",
            "[sandbox_workspace_write]\nwritable_roots = ['/keep']\n",
            "[sandbox_workspace_write]\nwritable_roots = [\n  '/keep', # keep comment\n]\n",
            "[sandbox_workspace_write]\nwritable_roots = [\n  '/keep'\n]\n",
            "[sandbox_workspace_write]\nwritable_roots = ['/#keep]雪',]\r\n",
            "policy = \"\"\"\n[sandbox_workspace_write]\nwritable_roots = ['fake']\n\"\"\"\n",
            "policy = '''\n[sandbox_workspace_write]\nwritable_roots = ['fake']\n'''\n",
        ])
    func addReinstallAndRemove(original: String) throws {
        let directory = "/runtime/ipc"
        let added = try CodexWritableRootsEditor.updating(
            original, directory: directory, configurationPath: "fixture")
        #expect(added.changed)
        #expect(added.contents.contains(directory))
        let repeated = try CodexWritableRootsEditor.updating(
            added.contents, directory: directory, configurationPath: "fixture")
        #expect(!repeated.changed)
        #expect(repeated.contents == added.contents)
        let removed = try CodexWritableRootsEditor.updating(
            added.contents, directory: directory, removing: true, configurationPath: "fixture")
        #expect(removed.changed)
        #expect(!removed.contents.contains(directory))
        #expect(removed.contents.contains("[sandbox_workspace_write]"))
        #expect(removed.contents.contains("writable_roots"))
        if original.contains("/keep") { #expect(removed.contents.contains("/keep")) }
        if original.contains("keep comment") { #expect(removed.contents.contains("keep comment")) }
        if original.contains("/#keep]雪") { #expect(removed.contents.contains("/#keep]雪")) }
        if original.hasPrefix("policy") { #expect(removed.contents.hasPrefix(original)) }
    }

    @Test(
        "ambiguous roots leave all installer outputs untouched",
        arguments: [
            "sandbox_workspace_write.writable_roots = []\n",
            "sandbox_workspace_write = { writable_roots = [] }\n",
            "[sandbox_workspace_write]\nwritable_roots = []\n[sandbox_workspace_write]\nwritable_roots = []\n",
            "[sandbox_workspace_write]\nwritable_roots = []\nwritable_roots = []\n",
            "[sandbox_workspace_write]\nwritable_roots.extra = []\n",
            "[sandbox_workspace_write]\nwritable_roots = ['a' 'b']\n",
            "[sandbox_workspace_write]\nwritable_roots = [,'a']\n",
            "[sandbox_workspace_write]\nwritable_roots = ['a',,]\n",
            "[sandbox_workspace_write]\nwritable_roots = ['a'] bad\n",
        ])
    func ambiguousInstallWritesNothing(original: String) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        try fixture.writeConfiguration(original)
        #expect(throws: AgentPackageInstallationError.self) {
            _ = try CodexPackageInstaller.install(fixture.props)
        }
        #expect(fixture.configuration() == original)
        #expect(!fixture.fileExists(relativePath: "hooks.json"))
        #expect(!fixture.fileExists(relativePath: "skills/agentstudio"))
    }

    @Test(
        "features scanning ignores escaped, literal and multiline policy strings",
        arguments: [
            "policy = '\"\"\" # [features]'\n",
            "policy = \"[features] # string\"\n",
            "policy = \"\"\"\n[features]\nhooks = false\n\"\"\"\n",
            "policy = '''\n[features]\nhooks = false\n'''\n",
        ])
    func unrelatedStringsKeepRealFeatureTable(policy: String) throws {
        let original = policy + "[features]\nhooks = false # keep\n"
        let edited = try CodexFeatureTableEditor.enablingHooks(in: original, configurationPath: "fixture")
        #expect(edited.contents == policy + "[features]\nhooks = true # keep\n")
    }

    @Test("quoted paths and Unicode escapes remain valid and idempotent")
    func escapedPaths() throws {
        let original = "[\"sandbox_workspace_write\"]\n'writable_roots' = ['/#keep]雪', \"\\U0001F600\"]\n"
        let directory = "/runtime/quote\"#]雪"
        let added = try CodexWritableRootsEditor.updating(original, directory: directory, configurationPath: "fixture")
        #expect(added.changed)
        #expect(added.contents.contains("quote\\\"#"))
        let repeated = try CodexWritableRootsEditor.updating(
            added.contents, directory: directory, configurationPath: "fixture")
        #expect(!repeated.changed)
        let removed = try CodexWritableRootsEditor.updating(
            added.contents, directory: directory, removing: true, configurationPath: "fixture")
        #expect(removed.contents.contains("'/#keep]雪'"))
        #expect(removed.contents.contains(#"\U0001F600"#))
    }
}
