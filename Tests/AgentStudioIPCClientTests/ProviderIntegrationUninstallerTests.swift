import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Provider integration removal")
struct ProviderIntegrationUninstallerTests {
    @Test(
        "uninstall removes owned artifacts and preserves owner content", arguments: AgentPackageProvider.allCases,
        [false, true])
    func uninstallPreservesOwnerContent(provider: AgentPackageProvider, hasOwnerFile: Bool) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let layout = ProviderIntegrationLayout(provider: provider, home: fixture.codexHome)
        _ = try ProviderIntegrationInstaller.install(.init(layout: layout, locator: locator))
        let skill = layout.home.appending(path: "skills/agentstudio/SKILL.md")
        let marker = layout.home.appending(path: "skills/agentstudio/.agentstudio-package")
        let skillBefore = try Data(contentsOf: skill)
        let markerBefore = try Data(contentsOf: marker)
        let configurationBefore = fixture.configuration()
        let owner = layout.directoryURL.appending(path: "owner.txt")
        if hasOwnerFile { try Data("owner\n".utf8).write(to: owner) }
        _ = try ProviderIntegrationUninstaller.uninstall(layout: layout)
        #expect(!FileManager.default.fileExists(atPath: layout.scriptURL.path))
        #expect(!FileManager.default.fileExists(atPath: layout.versionURL.path))
        #expect(FileManager.default.fileExists(atPath: layout.directoryURL.path) == hasOwnerFile)
        if hasOwnerFile { #expect(try Data(contentsOf: owner) == Data("owner\n".utf8)) }
        #expect(try Data(contentsOf: skill) == skillBefore)
        #expect(try Data(contentsOf: marker) == markerBefore)
        #expect(fixture.configuration() == configurationBefore)
        let document = try ProviderHookFileDocument(
            provider: provider, data: Data(contentsOf: layout.hookFileURL), path: layout.hookFileURL.path)
        #expect(document.groupsByEvent.values.flatMap { $0 }.flatMap(\.handlers).isEmpty)
        _ = try ProviderIntegrationUninstaller.uninstall(layout: layout)
        #expect(try Data(contentsOf: skill) == skillBefore)
    }

    @Test(
        "current and legacy commands are removed while foreign handler values survive",
        arguments: AgentPackageProvider.allCases)
    func uninstallKeepsForeignHandlers(provider: AgentPackageProvider) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let layout = ProviderIntegrationLayout(provider: provider, home: fixture.codexHome)
        _ = try ProviderIntegrationInstaller.install(.init(layout: layout, locator: locator))
        var document = try ProviderHookFileDocument(
            provider: provider, data: Data(contentsOf: layout.hookFileURL), path: layout.hookFileURL.path)
        let event = provider == .cursor ? "stop" : "Stop"
        let ownedGroup = try #require(document.groupsByEvent[event]?.first)
        guard case .command(let current)? = ownedGroup.handlers.first else {
            Issue.record("missing installed command")
            return
        }
        let legacy = ProviderHookHandler.command(
            .init(
                command:
                    "\"/Applications/AgentStudio.app/Contents/Resources/AgentPackage/providers/\(provider.rawValue)/hooks/agentstudio-\(provider.rawValue)-hook.sh\" \(event)",
                timeoutSeconds: nil, isAsync: nil, typeField: current.typeField, preserved: .object([])))
        let foreign = ProviderHookHandler.command(
            .init(
                command: "owner-command", timeoutSeconds: nil, isAsync: nil, typeField: current.typeField,
                preserved: .object([])))
        let opaque = try ProviderHookJSONValue.parse(Data(#"{"type":"mcp_tool","server":"owner","tool":"keep"}"#.utf8))
        if provider == .cursor {
            document.setGroups(
                [foreign, ownedGroup.handlers[0], legacy, .other(opaque)].map {
                    .init(matcher: nil, handlers: [$0], preserved: .object([]))
                }, event: event)
        } else {
            document.setGroups(
                [
                    .init(
                        matcher: "owner-matcher", handlers: [foreign, ownedGroup.handlers[0], legacy, .other(opaque)],
                        preserved: .object([]))
                ], event: event)
        }
        try document.encoded().write(to: layout.hookFileURL)
        _ = try ProviderIntegrationUninstaller.uninstall(layout: layout)
        let after = try ProviderHookFileDocument(
            provider: provider, data: Data(contentsOf: layout.hookFileURL), path: layout.hookFileURL.path)
        let remaining = (after.groupsByEvent[event] ?? []).flatMap(\.handlers)
        #expect(remaining.map(\.json) == [foreign.json, opaque])
        if provider != .cursor { #expect(after.groupsByEvent[event]?.first?.matcher == "owner-matcher") }
    }

    @Test("literal Cursor legacy entry migrates once and uninstalls completely")
    func cursorLiteralMigrationAndRemoval() throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let layout = ProviderIntegrationLayout(provider: .cursor, home: fixture.codexHome)
        let legacy =
            #"{"hooks":{"stop":[{"command":"\"/Applications/AgentStudio.app/Contents/Resources/AgentPackage/providers/cursor/hooks/agentstudio-cursor-hook.sh\" stop"},{"command":"owner-command"},{"type":"foreign","command":"typed-owner"}]}}"#
        try Data(legacy.utf8).write(to: layout.hookFileURL)
        let props = ProviderIntegrationInstaller.Props(layout: layout, locator: locator)
        _ = try ProviderIntegrationInstaller.install(props)
        let installed = try Data(contentsOf: layout.hookFileURL)
        _ = try ProviderIntegrationInstaller.install(props)
        #expect(try Data(contentsOf: layout.hookFileURL) == installed)
        _ = try ProviderIntegrationUninstaller.uninstall(layout: layout)
        let document = try ProviderHookFileDocument(
            provider: .cursor, data: Data(contentsOf: layout.hookFileURL), path: layout.hookFileURL.path)
        let entries = (document.groupsByEvent["stop"] ?? []).flatMap(\.handlers).map(\.json)
        #expect(
            entries.map(\.serialized) == [
                #"{"command":"owner-command"}"#, #"{"type":"foreign","command":"typed-owner"}"#,
            ])
    }

    @Test("malformed hooks abort removal before deleting any artifacts", arguments: AgentPackageProvider.allCases)
    func malformedUninstallPreservesArtifacts(provider: AgentPackageProvider) throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let layout = ProviderIntegrationLayout(provider: provider, home: fixture.codexHome)
        _ = try ProviderIntegrationInstaller.install(.init(layout: layout, locator: locator))
        try Data("[]".utf8).write(to: layout.hookFileURL)
        let script = try Data(contentsOf: layout.scriptURL)
        let version = try Data(contentsOf: layout.versionURL)
        #expect(throws: AgentPackageInstallationError.configurationUnreadable(layout.hookFileURL.path)) {
            try ProviderIntegrationUninstaller.uninstall(layout: layout)
        }
        #expect(try Data(contentsOf: layout.scriptURL) == script)
        #expect(try Data(contentsOf: layout.versionURL) == version)
        #expect(try Data(contentsOf: layout.hookFileURL) == Data("[]".utf8))
    }
    private var locator: AgentPackageResourceLocator {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/AgentStudio/Resources/AgentPackage")
        return .init(packageRoot: root)
    }

}
