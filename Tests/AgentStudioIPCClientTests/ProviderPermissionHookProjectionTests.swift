import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Provider permission hook projection")
struct ProviderPermissionHookProjectionTests {
    @Test("Recorded Claude permission becomes a bounded approval ask without granting persistent trust")
    func recordedClaudePermissionProjectsApproval() throws {
        let result = try ProviderPermissionHookProjection.project(
            provider: .claude, payload: RecordedClaudeStatusTrace.data("PermissionRequest"))
        guard case .approval(let request) = result else {
            Issue.record("Recorded permission did not project an approval")
            return
        }
        #expect(request.conversationId == "6f31f520-d7fa-4e37-90e4-16c5e296caa0")
        #expect(request.body.contains("Read"))
        #expect(request.body.contains("/recorded/file_path"))
        #expect(!request.body.contains("permission_suggestions"))
        let intent = try PaneCLIIntent.parse(request.askArguments, now: Date(timeIntervalSince1970: 1))
        guard case .ask(let draft) = intent else {
            Issue.record("Permission projection must use the real ask CLI")
            return
        }
        #expect(draft.reason == .approval)
        #expect(draft.timeout == CLIPolicy.permissionApprovalWindow / .seconds(1))
        #expect(
            draft.form
                == .choice(
                    options: [
                        .init(id: "Allow", label: "Allow"), .init(id: "Deny", label: "Deny"),
                        .init(id: "Ask", label: "Ask"),
                    ], allowsMultiple: false))
        #expect(intent.callLimit == CLIPolicy.permissionApprovalWindow + .seconds(2))
        #expect(CLIPolicy.permissionHookTimeoutSeconds == CLIPolicy.permissionApprovalWindow / .seconds(1) + 5)
    }

    @Test("Codex installation selects wait only for permission and derives its ceiling")
    func codexInstallationSelectsWaitingPolicy() throws {
        for event in CodexHookEventName.installedEvents {
            let group = CodexPackageInstaller.matcherGroup(
                event: event,
                scriptURL: URL(fileURLWithPath: "/AgentPackage/providers/codex/hooks/agentstudio-codex-hook.sh"))
            let handlers = try #require(group["hooks"] as? [[String: Any]])
            let handler = try #require(handlers.first)
            let command = try #require(handler["command"] as? String)
            let permission = event == .permissionRequest
            #expect(command.contains("--permission-policy wait") == permission)
            #expect(
                handler["timeout"] as? Double
                    == (permission
                        ? CLIPolicy.permissionHookTimeoutSeconds : Double(CodexPackageInstaller.hookTimeoutSeconds)))
            #expect(handler["async"] == nil)
        }
    }

    @Test("The recorded AskUserQuestion permission stays read-only")
    func questionPermissionIsReadOnly() throws {
        #expect(
            try ProviderPermissionHookProjection.project(
                provider: .claude, payload: RecordedClaudeStatusTrace.data("AskUserQuestion.PermissionRequest"))
                == .readOnlyQuestion)
    }

    @Test("Codex's source-derived fixture supplies its own writer and tool input")
    func sourceDerivedCodexPermissionProjectsApproval() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let payload = try Data(contentsOf: root.appending(path: "Fixtures/codex-0.154/permission-request.json"))
        guard
            case .approval(let request) = try ProviderPermissionHookProjection.project(
                provider: .codex, payload: payload)
        else {
            Issue.record("Source-derived Codex fixture did not project an approval")
            return
        }
        #expect(request.body.contains("git"))
        #expect(request.body.contains("push"))
        let environment = request.writerEnvironment(
            ["CLAUDE_CODE_SESSION_ID": "other-claude", "CODEX_THREAD_ID": "other-codex"])
        #expect(environment["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(environment["CODEX_THREAD_ID"] == request.conversationId)
    }

    @Test("Only exact single-choice human Allow or Deny produces provider decision JSON")
    func outcomesNeverInferPermission() throws {
        let allow = try #require(
            try ProviderPermissionHookDecision.json(for: .answered(value: .choices(ids: ["Allow"]))))
        let deny = try #require(try ProviderPermissionHookDecision.json(for: .answered(value: .choices(ids: ["Deny"]))))
        #expect(
            try JSONDecoder().decode(JSONValue.self, from: Data(allow.utf8))
                == .object([
                    "hookSpecificOutput": .object([
                        "hookEventName": .string("PermissionRequest"),
                        "decision": .object(["behavior": .string("allow")]),
                    ])
                ]))
        #expect(deny.contains("\"behavior\":\"deny\""))
        for outcome in [
            IPCPaneAskOutcome.handedBack, .expired, .withdrawn, .stale,
            .answered(value: .choices(ids: ["Ask"])), .answered(value: .choices(ids: [])),
            .answered(value: .choices(ids: ["Allow", "Deny"])), .answered(value: .choices(ids: ["allow"])),
            .answered(value: .text(value: "Allow")),
            .answered(value: .form(values: .init(properties: [:]))),
        ] {
            #expect(try ProviderPermissionHookDecision.json(for: outcome) == nil)
        }
        #expect(!allow.contains("updatedInput"))
        #expect(!allow.contains("updatedPermissions"))
        #expect(!deny.contains("interrupt"))
    }

    @Test("Mismatched, missing or malformed permission documents cannot project an approval")
    func invalidDocumentsAreRefused() {
        for payload in [
            "{}", "not json",
            "{\"session_id\":\"s\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"shell\",\"tool_input\":{}}",
            "{\"session_id\":\"\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"shell\",\"tool_input\":{}}",
        ] {
            #expect(throws: (any Error).self) {
                try ProviderPermissionHookProjection.project(provider: .codex, payload: Data(payload.utf8))
            }
        }
    }
}
