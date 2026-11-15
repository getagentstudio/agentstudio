import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Provider hook call limits")
struct ProviderHookPolicyTests {
    @Test("every installed Codex call limit is strictly below its declared timeout")
    func codexLimitsFitInstalledEntries() throws {
        let layout = ProviderIntegrationLayout(provider: .codex, home: URL(fileURLWithPath: "/scratch/codex"))
        let entries = ProviderExpectedEntries.entries(layout: layout)
        #expect(entries.count == 9)
        for entry in entries {
            let event = try #require(CodexHookEventName(rawValue: entry.event))
            guard case .command(let handler)? = entry.group.handlers.first else {
                Issue.record("missing declared command")
                continue
            }
            let seconds = try #require(handler.timeoutSeconds)
            #expect(
                ProviderHookDelivery.codexCallLimit(for: event) < .milliseconds(Int64(seconds * 1000)),
                "event: \(entry.event)")
        }
        #expect(CLIPolicy.hookCallLimit < .seconds(10))
    }
}
