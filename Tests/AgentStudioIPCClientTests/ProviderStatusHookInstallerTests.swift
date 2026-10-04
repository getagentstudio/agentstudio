import AgentStudioIPCTransport
import AgentStudioPrimitives
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Provider status hook installer")
struct ProviderStatusHookInstallerTests {
    @Test("installation wires captured status events and selects waiting permission policy")
    func installedEventsDecodeTheirRecordedPayloads() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agentstudio-status-install-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appending(path: "config")
        let packageRoot = root.appending(path: "AgentPackage")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: repoRoot.appending(path: "Sources/AgentStudio/Resources/AgentPackage"), to: packageRoot)
        try ClaudeCodePackageInstallation(
            configurationDirectory: config, packageRoot: packageRoot, providerVersion: "2.1.286"
        ).install(notice: { _ in })
        let settings = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: config.appending(path: "settings.json")))
        guard case .object(let fields) = settings, case .object(let hooks)? = fields["hooks"] else {
            Issue.record("Installed settings have no hooks")
            return
        }
        let fixtures = [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "PermissionRequest", "PreToolUse", "PostToolUse",
            "PostToolUseFailure", "StopFailure", "Elicitation", "ElicitationResult",
        ]
        for fixture in fixtures {
            let payload = try RecordedClaudeStatusTrace.payload(fixture)
            let projected = try RecordedClaudeStatusTrace.project(fixture)
            #expect(projected.event.conversationId == payload.sessionId)
            let event = payload.hookEventName
            guard case .array(let groups)? = hooks[event], case .object(let group)? = groups.first,
                case .array(let entries)? = group["hooks"], case .object(let entry)? = entries.first,
                case .string(let command)? = entry["command"]
            else {
                Issue.record("Captured status event \(event) is not installed")
                continue
            }
            let permission = event == "PermissionRequest"
            let suffix = " \(event) 2.1.286" + (permission ? " --permission-policy wait" : "")
            #expect(command.hasSuffix(suffix))
            #expect(
                entry["timeout"]
                    == .number(
                        permission
                            ? CLIPolicy.permissionHookTimeoutSeconds : ClaudeCodePackageInstallation.hookTimeoutSeconds)
            )
            #expect(!command.contains("ask --wait"))
            #expect(entry["async"] == nil)
        }
        #expect(hooks["Notification"] == nil)
        // The shell preserves the installer-selected permission policy for the CLI.
        let script = try String(
            contentsOf: packageRoot.appending(path: "providers/claude/hooks/agentstudio-claude-hook.sh"),
            encoding: .utf8)
        #expect(script.contains("hook claude"))
        #expect(!script.contains("pane.message.ask"))
        #expect(script.contains("\"$@\""))
    }

    @Test("Codex retains its installed vocabulary; no unreported failure or question capability is invented")
    func codexKeepsQualifiedVocabulary() throws {
        let expected: Set<String> = [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "SubagentStart",
            "SubagentStop", "Stop", "Interrupt",
        ]
        #expect(Set(CodexHookEventName.installedEvents.map(\.rawValue)) == expected)
        for event in CodexHookEventName.installedEvents {
            let projected = try #require(
                CodexHookProjection.project(
                    sourceOccurredAt: Date(timeIntervalSince1970: 1_700_000_000), eventName: event,
                    payload: CodexFixtures.payload(for: event)))
            #expect(projected.event.name.rawValue != "turnFailed")
            #expect(projected.event.name.rawValue != "question")
            #expect(projected.event.name.rawValue != "elicitation")
        }
    }
}
