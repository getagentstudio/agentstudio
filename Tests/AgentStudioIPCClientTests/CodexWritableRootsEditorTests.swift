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

    @Test("install adds a missing root once and preserves an existing root", arguments: [false, true])
    func installPreservesWritableRoots(alreadyPresent: Bool) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let roots = alreadyPresent ? "['/keep', \"\(fixture.props.ipcDirectory.path)\"]" : "['/keep']"
        let original =
            "[features]\nhooks = true\n[sandbox_workspace_write]\nwritable_roots = \(roots) # dotfiles\n"
        try fixture.writeConfiguration(original)

        let output = try CodexPackageInstaller.install(fixture.props)

        if alreadyPresent {
            #expect(fixture.configuration() == original)
            #expect(!output.contains { $0.hasPrefix("notice: added ") })
        } else {
            #expect(output.filter { $0.hasPrefix("notice: added ") }.count == 1)
            #expect(output.contains { $0.contains("dotfiles-managed") })
        }
        let installed = fixture.configuration()
        let repeated = try CodexPackageInstaller.install(fixture.props)
        #expect(fixture.configuration() == installed)
        #expect(!repeated.contains { $0.hasPrefix("notice: added ") })
        #expect(installed.contains(fixture.props.ipcDirectory.path))
        #expect(installed.contains("'/keep'"))
        #expect(installed.contains("# dotfiles"))
    }

    @Test(
        "install discovers the store directory or refuses without writing", arguments: ["stable", "beta", "debug"],
        ["explicit", "metadata", "split", "missing", "mismatch"])
    func installUsesExistingStoreContext(channel: String, source: String) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let directory = fixture.root.appending(path: "runtime/\(channel)/ipc")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appending(path: "cli.sqlite")
        let socket =
            ["explicit", "split"].contains(source)
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
            if source == "split" {
                try FileManager.default.createDirectory(
                    at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    at: socket.deletingLastPathComponent().appending(path: "runtime.json"),
                    withDestinationURL: directory.appending(path: "runtime.json"))
            }
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
            let expectedDirectory = source == "split" ? directory.resolvingSymlinksInPath() : directory
            #expect(fixture.configuration().contains(expectedDirectory.path))
            if source == "split" {
                #expect(!fixture.configuration().contains(socket.deletingLastPathComponent().path))
            }
            if source == "explicit" {
                #expect(!FileManager.default.fileExists(atPath: store.path))
                #expect(!fixture.configuration().contains(socket.deletingLastPathComponent().path))
            }
        }
    }

    @Test(
        "adds exactly one store directory and preserves foreign text on reinstall",
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
    func addAndReinstallPreserveForeignText(original: String) throws {
        let directory = "/runtime/ipc"
        let added = try CodexWritableRootsEditor.updating(
            original, directory: directory, configurationPath: "fixture")
        #expect(added.changed)
        #expect(added.contents.contains(directory))
        let repeated = try CodexWritableRootsEditor.updating(
            added.contents, directory: directory, configurationPath: "fixture")
        #expect(!repeated.changed)
        #expect(repeated.contents == added.contents)
        if original.contains("/keep") { #expect(added.contents.contains("/keep")) }
        if original.contains("keep comment") { #expect(added.contents.contains("keep comment")) }
        if original.contains("/#keep]雪") { #expect(added.contents.contains("/#keep]雪")) }
        if original.hasPrefix("policy") { #expect(added.contents.hasPrefix(original)) }
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
        #expect(added.contents.contains("'/#keep]雪'"))
        #expect(added.contents.contains(#"\U0001F600"#))
    }
}
