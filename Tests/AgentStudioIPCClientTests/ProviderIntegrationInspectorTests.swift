import AgentStudioIPCTransport
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

struct IntegrationStatusFixture {
    let fixture: CodexHomeFixture
    let layout: ProviderIntegrationLayout

    init(provider: AgentPackageProvider = .claude) throws {
        fixture = try CodexHomeFixture()
        layout = .init(provider: provider, home: fixture.codexHome)
        try FileManager.default.createDirectory(at: layout.directoryURL, withIntermediateDirectories: true)
        try Data(
            ProviderHookScript.body(provider: provider, version: ProviderIntegrationVersion.current(for: provider)).utf8
        ).write(to: layout.scriptURL)
        try Data("\(ProviderIntegrationVersion.current(for: provider))\n".utf8).write(to: layout.versionURL)
        try Data(ProviderExpectedEntries.snippet(layout: layout).utf8).write(to: layout.hookFileURL)
        if provider == .codex { try fixture.writeConfiguration("[features]\nhooks = true\n") }
    }

    func inspect(version: String? = "0.163.0") -> ProviderIntegrationStatus {
        ProviderIntegrationInspector.inspect(.init(layout: layout, environment: [:], codexVersion: { version }))
    }
    func dispose() { fixture.tearDown() }

    func changeEntry(aspect: ProviderHookEntryAspect) throws {
        var document = try ProviderHookFileDocument(
            provider: layout.provider, data: Data(contentsOf: layout.hookFileURL), path: layout.hookFileURL.path)
        let event = layout.provider == .cursor ? "stop" : "Stop"
        let original = try #require(document.groupsByEvent[event]?.first)
        guard case .command(let handler)? = original.handlers.first else {
            Issue.record("missing fixture command")
            return
        }
        let changed = ProviderCommandHook(
            command: handler.command + (aspect == .command ? " extra" : ""),
            timeoutSeconds: aspect == .timeout ? 999 : handler.timeoutSeconds,
            isAsync: aspect == .asynchronous ? false : handler.isAsync,
            typeField: handler.typeField, preserved: handler.preserved)
        document.setGroups(
            [
                .init(
                    matcher: aspect == .matcher ? "Bash" : original.matcher, handlers: [.command(changed)],
                    preserved: original.preserved)
            ], event: event)
        try document.encoded().write(to: layout.hookFileURL)
    }
}

@Suite("Read-only integration inspection")
struct ProviderIntegrationInspectorTests {
    @Test("installed Claude and Cursor are current without writes", arguments: [AgentPackageProvider.claude, .cursor])
    func installedIntegrationIsCurrent(provider: AgentPackageProvider) throws {
        let fixture = try IntegrationStatusFixture(provider: provider)
        defer { fixture.dispose() }
        let before = try snapshot(fixture.fixture.root)
        let status = fixture.inspect()
        #expect(status.verdict == .current)
        #expect(status.problems.isEmpty)
        #expect(try snapshot(fixture.fixture.root) == before)
    }

    @Test(
        "required artifacts and unreadable paths never report current",
        arguments: [
            "homeMissing", "homeUnreadable", "hookFileUnreadable", "hookFileUnparseable", "scriptUnreadable",
            "versionUnreadable", "versionMissing", "scriptMissing", "scriptOutdated", "notInstalled", "entryMissing",
            "legacyEntry",
        ])
    func inspectionProblems(scenario: String) throws {
        let fixture = try IntegrationStatusFixture()
        defer { fixture.dispose() }
        let layout = fixture.layout
        let permissions: URL?
        switch scenario {
        case "homeUnreadable": permissions = layout.home
        case "hookFileUnreadable": permissions = layout.hookFileURL
        case "scriptUnreadable": permissions = layout.scriptURL
        default: permissions = nil
        }
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: permissions.path)
        }
        defer {
            if let permissions {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: permissions.path)
            }
        }
        var target = layout
        switch scenario {
        case "homeMissing": target = .init(provider: .claude, home: fixture.fixture.root.appending(path: "missing"))
        case "hookFileUnparseable": try Data("[]".utf8).write(to: layout.hookFileURL)
        case "versionUnreadable": try Data("abc".utf8).write(to: layout.versionURL)
        case "versionMissing": try FileManager.default.removeItem(at: layout.versionURL)
        case "scriptMissing": try FileManager.default.removeItem(at: layout.scriptURL)
        case "scriptOutdated": try Data("0\n".utf8).write(to: layout.versionURL)
        case "notInstalled":
            try FileManager.default.removeItem(at: layout.scriptURL)
            try Data("{}".utf8).write(to: layout.hookFileURL)
        case "entryMissing": try Data("{}".utf8).write(to: layout.hookFileURL)
        case "legacyEntry":
            let text = try String(contentsOf: layout.hookFileURL, encoding: .utf8)
            try Data(
                text.replacingOccurrences(
                    of: layout.scriptURL.path,
                    with:
                        "/Applications/AgentStudio.app/Contents/Resources/AgentPackage/providers/claude/hooks/agentstudio-claude-hook.sh"
                ).utf8
            ).write(to: layout.hookFileURL)
        default: break
        }
        let status = ProviderIntegrationInspector.inspect(
            .init(layout: target, environment: [:], codexVersion: { "0.163.0" }))
        let expectedKind = scenario == "versionMissing" ? "versionUnreadable" : scenario
        let expectedVerdict: ProviderIntegrationVerdict
        switch scenario {
        case "homeMissing", "homeUnreadable", "hookFileUnreadable", "hookFileUnparseable", "scriptUnreadable":
            expectedVerdict = .unavailable
        case "notInstalled": expectedVerdict = .notInstalled
        case "entryMissing": expectedVerdict = .entriesMissing
        default: expectedVerdict = .outdated
        }
        #expect(status.verdict == expectedVerdict)
        #expect(status.problems.contains { $0.presentation(provider: .claude).kind == expectedKind })
        for problem in status.problems { #expect(!problem.presentation(provider: .claude).recovery.isEmpty) }
        let json = try ProviderIntegrationStatusRenderer.json([status])
        #expect(json.contains("\"kind\":\"\(expectedKind)\""))
        #expect(ProviderIntegrationStatusRenderer.human([status]).contains("claude:"))
    }

    @Test(
        "each modified entry aspect is diagnosed",
        arguments: [ProviderHookEntryAspect.command, .matcher, .timeout, .asynchronous])
    func modifiedEntryAspects(aspect: ProviderHookEntryAspect) throws {
        let fixture = try IntegrationStatusFixture()
        defer { fixture.dispose() }
        try fixture.changeEntry(aspect: aspect)
        let status = fixture.inspect()
        #expect(status.verdict == .entriesMissing)
        #expect(
            status.problems.contains(
                .entryModified(event: "Stop", path: fixture.layout.hookFileURL.path, aspect: aspect)))
    }

    @Test("newer script versions keep current plus an informational note")
    func newerIntegrationNote() throws {
        let fixture = try IntegrationStatusFixture()
        defer { fixture.dispose() }
        try Data("99\n".utf8).write(to: fixture.layout.versionURL)
        let status = fixture.inspect()
        #expect(status.verdict == .current)
        #expect(status.notes == [.installedByNewerAgentStudio(installed: 99, expected: 1)])
        #expect(try ProviderIntegrationStatusRenderer.json([status]).contains("installedByNewerAgentStudio"))
        #expect(ProviderIntegrationStatusRenderer.human([status]).contains("installed by a newer Agent Studio"))
    }

    @Test(
        "Codex trust failures remain distinct and simultaneous problems are retained",
        arguments: [
            "needsReview", "modified", "disabled", "featureOff", "stateUnreadable", "unsupported", "versionUnavailable",
            "simultaneous",
        ])
    func codexInspectionStates(scenario: String) throws {
        let fixture = try IntegrationStatusFixture(provider: .codex)
        defer { fixture.dispose() }
        let config = fixture.layout.home.appending(path: "config.toml")
        if scenario == "modified" || scenario == "disabled" {
            let key = CodexHookReviewStateReader.key(
                path: fixture.layout.hookFileURL.path, event: "SessionStart", group: 0, handler: 0)
            let quoted = "\"\(key)\""
            try fixture.fixture.writeConfiguration(
                "[features]\nhooks = true\n[hooks.state.\(quoted)]\ntrusted_hash = 'sha256:stale'\nenabled = \(scenario == "disabled" ? "false" : "true")\n"
            )
        }
        if scenario == "featureOff" { try fixture.fixture.writeConfiguration("[features]\nhooks = false\n") }
        if scenario == "stateUnreadable" {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: config.path)
        }
        defer {
            if scenario == "stateUnreadable" {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
            }
        }
        if scenario == "simultaneous" { try Data("0\n".utf8).write(to: fixture.layout.versionURL) }
        let version: String? =
            scenario == "unsupported" ? "0.164.0" : scenario == "versionUnavailable" ? nil : "0.163.0"
        let status = fixture.inspect(version: version)
        let expectedKind: String
        switch scenario {
        case "modified": expectedKind = "codexModified"
        case "disabled": expectedKind = "codexDisabled"
        case "featureOff": expectedKind = "codexHooksFeatureOff"
        case "stateUnreadable", "unsupported", "versionUnavailable": expectedKind = "codexTrustUnknown"
        default: expectedKind = "codexNeedsReview"
        }
        #expect(status.problems.contains { $0.presentation(provider: .codex).kind == expectedKind })
        #expect(status.verdict != .current)
        if scenario == "disabled" {
            #expect(status.problems.filter { $0.presentation(provider: .codex).kind == "codexDisabled" }.count == 1)
        }
        if scenario == "unsupported" || scenario == "versionUnavailable" || scenario == "stateUnreadable" {
            #expect(status.verdict == .trustUnknown)
        }
        if scenario == "simultaneous" {
            #expect(status.verdict == .outdated)
            #expect(status.problems.contains { $0.verdict == .notTrusted })
        }
    }

    @Test("status command renders current, noncurrent and all-provider results with matching exits")
    func statusCommandOutputAndExit() throws {
        let fixture = try IntegrationStatusFixture()
        defer { fixture.dispose() }
        let target = AgentPackageTarget(provider: .claude, homePath: fixture.layout.home.path)
        var output = ""
        var errors = ""
        let current = AgentPackageStatusCommand.run(
            request: .init(selection: .provider(target), json: false), environment: [:],
            output: { output = $0 }, error: { errors = $0 })
        #expect(current == 0)
        #expect(output == "claude: current")
        #expect(errors.isEmpty)
        try Data("0\n".utf8).write(to: fixture.layout.versionURL)
        let outdated = AgentPackageStatusCommand.run(
            request: .init(selection: .provider(target), json: true), environment: [:],
            output: { output = $0 }, error: { errors = $0 })
        #expect(outdated == 1)
        #expect(output.contains("\"verdict\":\"outdated\""))
        #expect(errors.isEmpty)
        let statuses = AgentPackageProvider.allCases.map {
            ProviderIntegrationStatus(provider: $0, problems: [.homeMissing(path: "/scratch/missing")], notes: [])
        }
        let json = try ProviderIntegrationStatusRenderer.json(statuses)
        let results = try JSONDecoder().decode([JSONValue].self, from: Data(json.utf8))
        #expect(results.count == 3)
    }

    @Test("version parser and failed private-directory creation never fall back to a provider home")
    func versionProbeFailure() throws {
        let fixture = try CodexHomeFixture()
        defer { fixture.tearDown() }
        let missing = fixture.root.appending(path: "missing/parent")
        #expect(
            CodexVersionProbe.read(environment: ["CODEX_HOME": fixture.codexHome.path], temporaryRoot: missing) == nil)
        #expect(CodexVersionProbe.parsedVersion("codex-cli 0.163.0\n") == "0.163.0")
        for text in ["", "0.163.0", "codex-cli 0.163.0-beta", "codex-cli 0.163.0 extra"] {
            #expect(CodexVersionProbe.parsedVersion(text) == nil)
        }
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let url = root.appending(path: path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[path] = try Data(contentsOf: url)
            }
        }
        return result
    }
}
