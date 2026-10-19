import AgentStudioPrimitives
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Claude background hook suppression")
struct ClaudeBackgroundHookTests {
    @Test(
        "background hooks ignore payload and pane authority",
        arguments: ["CLAUDE_JOB_DIR", "CLAUDE_CODE_SESSION_KIND"], [false, true])
    func backgroundHookDoesNotReadOrReport(marker: String, hasToken: Bool) {
        var environment = [
            marker: marker == "CLAUDE_JOB_DIR" ? "/fixture/background-job" : "bg",
            "AGENTSTUDIO_IPC_SOCKET": "/fixture/not-a-live-socket",
            "AGENTSTUDIO_PANE_ID": UUIDv7.generate().uuidString,
            "AGENTSTUDIO_WORKSPACE_ID": UUIDv7.generate().uuidString,
        ]
        if hasToken { environment["AGENTSTUDIO_PANE_TOKEN"] = "fixture-token" }
        var reads = 0
        var diagnostics: [String] = []
        let exit = ClaudeCodeHookInvocation.handle(
            .init(
                arguments: ["hook", "claude", "UserPromptSubmit"], environment: environment,
                standardInput: {
                    reads += 1
                    return Data("malformed".utf8)
                },
                identifierGenerator: { UUIDv7.generate() }, diagnosticSink: { diagnostics.append($0) }))
        #expect(exit == 0)
        #expect(reads == 0)
        #expect(diagnostics.isEmpty)
    }

    @Test(
        "background commands refuse before token stdin or stale debug escrow",
        arguments: ["line", "title", "notify", "ask"])
    func backgroundCommandDoesNotReadToken(verb: String) {
        var reads = 0
        do {
            _ = try AgentStudioIPCClientArguments.parseGlobal(
                ["--token-stdin", verb, "intent"],
                environment: [
                    "CLAUDE_JOB_DIR": "/fixture/job", "AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW": "/fixture/stale",
                ],
                standardInputProvider: {
                    reads += 1
                    return Data("fixture-token".utf8)
                })
            Issue.record("Background command must be refused locally")
        } catch let failure as PaneCLICommandFailure {
            #expect(failure.description == "background session: not attached to a pane")
        } catch {
            Issue.record("Expected the background refusal, got \(error)")
        }
        #expect(reads == 0)
    }
}
