import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Pane context CLI skill")
struct CLIPaneContextSkillTests {
    @Test("the bundled skill teaches the seven pane-context verbs")
    func skillTeachesPaneContextVerbs() throws {
        let source = try skillSource()
        for verb in ["notify", "ask", "withdraw", "answers", "line", "title", "pane"] {
            #expect(source.contains("\"$AGENTSTUDIO_CLI\" \(verb)"), "Missing executable example for \(verb)")
        }
        #expect(source.contains("--wait"))
        #expect(source.contains("--timeout"))
    }

    @Test("pane identity guidance distinguishes active pane from the caller's own pane")
    func skillDistinguishesActivePaneFromSelf() throws {
        let source = try skillSource()
        #expect(source.contains("pane.current"))
        #expect(source.lowercased().contains("active pane"))
        #expect(source.contains("handle: \"self\""))
        #expect(source.lowercased().contains("execute in the pane"))
    }

    @Test("help remains the offline entry point and blocking asks never grant on timeout")
    func skillRetainsHelpAndAskFallback() throws {
        let source = try skillSource()
        #expect(source.contains("\"$AGENTSTUDIO_CLI\" help"))
        #expect(source.contains("\"$AGENTSTUDIO_CLI\" <method> --help"))
        #expect(source.contains("expired"))
        #expect(source.contains("withdrawn"))
        #expect(source.lowercased().contains("never grants permission"))
    }

    @Test("the skill retires direct status claims and teaches ask withdrawal plus hook-derived completion")
    func skillRetiresLegacyStatusAssertions() throws {
        let source = try skillSource()
        for verb in ["message", "needs-you", "done"] {
            #expect(!source.contains("\"$AGENTSTUDIO_CLI\" \(verb)"))
        }
        #expect(!source.contains("## The four calls"))
        #expect(source.contains("--reason"))
        #expect(source.lowercased().contains("non-blocking"))
        #expect(source.contains("Stop"))
        #expect(source.contains("line --done"))
        #expect(source.lowercased().contains("detail only"))
    }

    @Test("the skill teaches when pane-context updates and decisions belong in Agent Studio")
    func skillTeachesPaneContextDuties() throws {
        let source = try skillSource()
        #expect(source.contains("## When to use them"))
        #expect(source.contains("Keep the Agent Line and title current"))
        #expect(source.contains("Send messages in Agent Studio rather than only printing"))
        #expect(source.contains("Ask in Agent Studio for important decisions"))
        #expect(source.contains("Withdraw resolved messages"))
    }

    private func skillSource() throws -> String {
        let root = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        return try String(
            contentsOf: root.appending(path: "Sources/AgentStudio/Resources/AgentPackage/skills/agentstudio/SKILL.md"),
            encoding: .utf8)
    }
}
