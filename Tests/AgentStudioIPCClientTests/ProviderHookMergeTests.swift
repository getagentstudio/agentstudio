import AgentStudioIPCTransport
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Shared provider hook merge contract")
struct ProviderHookMergeTests {
    private let layout = ProviderIntegrationLayout(provider: .codex, home: URL(fileURLWithPath: "/scratch/.codex"))
    private let owned =
        #"{"type":"command","command":"\"/Applications/AgentStudio.app/Contents/Resources/AgentPackage/providers/codex/hooks/agentstudio-codex-hook.sh\" SessionStart"}"#
    private let foreign = #"{"type":"mcp_tool","server":"mine","tool":"keep","input":{"b":9007199254740993,"a":1e2}}"#
    private let after = #"{"type":"command","command":"foreign-after","timeout":4}"#

    @Test(
        "merge A-D and removal preserve foreign predicates and report exact moves",
        arguments: ["A", "B", "C", "D", "removal"])
    func mergeContract(caseName: String) throws {
        let groups: String
        let expectedMoves: [ProviderHookIndexMove]
        switch caseName {
        case "A":
            groups =
                "[{\"note\":\"keep\",\"hooks\":[\(owned),\(foreign)]},{\"matcher\":\"foreign\",\"hooks\":[\(after)]}]"
            expectedMoves = []
        case "B":
            groups =
                "[{\"matcher\":\"Bash\",\"hooks\":[\(owned),\(foreign)]},{\"matcher\":\"foreign\",\"hooks\":[\(after)]}]"
            expectedMoves = [.init(event: "SessionStart", oldGroup: 0, oldHandler: 1, newGroup: 0, newHandler: 0)]
        case "C", "removal":
            groups =
                "[{\"hooks\":[\(owned),\(foreign)]},{\"hooks\":[\(owned)]},{\"matcher\":\"foreign\",\"hooks\":[\(after)]}]"
            expectedMoves =
                caseName == "C"
                ? [.init(event: "SessionStart", oldGroup: 2, oldHandler: 0, newGroup: 1, newHandler: 0)]
                : [
                    .init(event: "SessionStart", oldGroup: 0, oldHandler: 1, newGroup: 0, newHandler: 0),
                    .init(event: "SessionStart", oldGroup: 2, oldHandler: 0, newGroup: 1, newHandler: 0),
                ]
        default:
            groups = "[{\"matcher\":\"foreign\",\"hooks\":[\(foreign),\(after)]}]"
            expectedMoves = []
        }
        let original = try ProviderHookFileDocument(
            provider: .codex, data: Data("{\"owner\":true,\"hooks\":{\"SessionStart\":\(groups)}}".utf8),
            path: layout.hookFileURL.path)
        let result = ProviderHookMerge.applying(to: original, layout: layout, removing: caseName == "removal")
        #expect(result.shiftedForeignKeys == expectedMoves)
        let merged = try #require(result.document.groupsByEvent["SessionStart"])
        let ownedCount = merged.flatMap(\.handlers).filter {
            ProviderHookOwnership.classify($0, layout: layout) != .foreign
        }.count
        #expect(ownedCount == (caseName == "removal" ? 0 : 1))
        let serialized = try #require(String(bytes: result.document.encoded(), encoding: .utf8))
        #expect(serialized.contains(foreign))
        #expect(serialized.contains(#""matcher":"foreign""#))
        #expect(serialized.contains(#""owner":true"#))
        if caseName == "A" { #expect(merged.first?.json["note"]?.stringValue == "keep") }
        if caseName == "B" { #expect(merged.first?.matcher == "Bash") }
        if caseName == "D" { #expect(merged.first?.matcher == "foreign") }
    }

    @Test("Cursor's literal untyped legacy command migrates in place and uninstalls completely")
    func cursorLiteralMigration() throws {
        let cursor = ProviderIntegrationLayout(provider: .cursor, home: URL(fileURLWithPath: "/scratch/.cursor"))
        let text =
            #"{"version":1,"hooks":{"stop":[{"command":"\"/Applications/AgentStudio.app/Contents/Resources/AgentPackage/providers/cursor/hooks/agentstudio-cursor-hook.sh\" stop"},{"command":"foreign"},{"type":"command","command":"typed-foreign","keep":true}]}}"#
        let original = try ProviderHookFileDocument(
            provider: .cursor, data: Data(text.utf8), path: cursor.hookFileURL.path)
        let installed = ProviderHookMerge.applying(to: original, layout: cursor).document
        let repeated = ProviderHookMerge.applying(to: installed, layout: cursor).document
        #expect(repeated.encoded() == installed.encoded())
        let entries = try #require(installed.json["hooks"]?["stop"]?.elements)
        #expect(entries.count == 3)
        #expect(entries.first?.members?.map(\.name) == ["command"])
        #expect(
            entries.first?["command"]?.stringValue == "\"/scratch/.cursor/agentstudio/agentstudio-cursor-hook.sh\" stop"
        )
        #expect(entries[1]["command"]?.stringValue == "foreign")
        #expect(entries[2]["type"]?.stringValue == "command")
        let removed = ProviderHookMerge.applying(to: repeated, layout: cursor, removing: true).document
        #expect(removed.json["hooks"]?["stop"]?.elements == Array(entries.dropFirst()))
    }

    @Test("an unchanged declaration keeps its positions and literal hash input")
    func unchangedDeclarationIsStable() throws {
        let initial = try ProviderHookFileDocument(provider: .codex, data: nil, path: layout.hookFileURL.path)
        let first = ProviderHookMerge.applying(to: initial, layout: layout)
        let decoded = try ProviderHookFileDocument(
            provider: .codex, data: first.document.encoded(), path: layout.hookFileURL.path)
        let second = ProviderHookMerge.applying(to: decoded, layout: layout)
        #expect(second.document.encoded() == first.document.encoded())
        #expect(second.shiftedForeignKeys.isEmpty)
        #expect(second.replacedEvents.isEmpty)
    }

    @Test("a foreign non-command handler never gains command ownership", arguments: AgentPackageProvider.allCases)
    func foreignHandlerRoundTrips(provider: AgentPackageProvider) throws {
        let handler = #"{"type":"mcp_tool","server":"mine","tool":"keep","input":{"b":9007199254740993,"a":1e2}}"#
        let entries = provider == .cursor ? "[\(handler)]" : "[{\"hooks\":[\(handler)]}]"
        let text = "{\"hooks\":{\"unknown-event\":\(entries)},\"keep\":{\"z\":2,\"a\":1}}"
        let document = try ProviderHookFileDocument(
            provider: provider, data: Data(text.utf8), path: "/scratch/hooks.json")
        #expect(try #require(String(bytes: document.encoded(), encoding: .utf8)).contains(handler))
        #expect(try #require(String(bytes: document.encoded(), encoding: .utf8)).contains(#""keep":{"z":2,"a":1}"#))
        let target = ProviderIntegrationLayout(provider: provider, home: URL(fileURLWithPath: "/scratch/home"))
        let removed = ProviderHookMerge.applying(to: document, layout: target, removing: true)
        #expect(removed.document.encoded() == document.encoded())
    }
    @Test("provider-default empty groups and obsolete legacy events survive the correct operation")
    func defaultGroupsAndObsoleteLegacyEvents() throws {
        let text = "{\"hooks\":{\"SessionStart\":[{}],\"OldEvent\":[{\"hooks\":[\(owned),\(foreign)]}]}}"
        let original = try ProviderHookFileDocument(
            provider: .codex, data: Data(text.utf8), path: layout.hookFileURL.path)
        #expect(original.json["hooks"]?["SessionStart"]?.elements?.first?.serialized == "{}")
        let installed = ProviderHookMerge.applying(to: original, layout: layout)
        let obsolete = try #require(installed.document.groupsByEvent["OldEvent"])
        #expect(obsolete.flatMap(\.handlers).count == 1)
        #expect(obsolete.first?.handlers.first?.json.serialized == foreign)
    }

    @Test("Cursor's unknown fields stay opaque and a missing hooks key stays absent")
    func cursorUnknownFieldsAreOpaque() throws {
        let text = #"{"version":1,"hooks":{"stop":[{"command":"foreign","timeout":"managed","async":{"raw":true}}]}}"#
        let document = try ProviderHookFileDocument(
            provider: .cursor, data: Data(text.utf8), path: "/scratch/hooks.json")
        #expect(document.encoded() == Data((text + "\n").utf8))
        let absent = try ProviderHookFileDocument(provider: .codex, data: Data("{}".utf8), path: "/scratch/hooks.json")
        #expect(absent.encoded() == Data("{}\n".utf8))
    }

}
