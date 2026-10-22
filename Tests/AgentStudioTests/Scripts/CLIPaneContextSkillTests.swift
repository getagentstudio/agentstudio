import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Pane context CLI skill")
struct CLIPaneContextSkillTests {
    @Test("the bundled skill teaches the seven pane-context verbs")
    func skillTeachesPaneContextVerbs() throws {
        let source = try skillSource()
        for verb in ["notify", "ask", "withdraw", "answers", "line", "title", "pane"] {
            #expect(source.contains("\"$AS_CLI\" \(verb)"), "Missing executable example for \(verb)")
        }
        #expect(source.contains("--wait"))
        #expect(source.contains("--timeout"))
    }

    @Test("pane identity guidance distinguishes active pane from the caller's own pane")
    func skillDistinguishesActivePaneFromSelf() throws {
        let source = try skillSource()
        #expect(source.contains("pane.current"))
        #expect(source.contains("focused pane"))
        #expect(source.contains("\"handle\":\"self\""))
        #expect(source.contains("self` identifies the caller's pane"))
    }

    @Test("help remains the offline entry point and blocking asks never grant on timeout")
    func skillRetainsHelpAndAskFallback() throws {
        let source = try skillSource()
        #expect(source.contains("\"$AS_CLI\" --help"))
        #expect(source.contains("Local help works without the app"))
        #expect(source.contains("expired"))
        #expect(source.contains("withdrawn"))
        #expect(source.contains("Exit 0 is not approval"))
    }

    @Test("the skill retires direct status claims and teaches ask withdrawal plus hook-derived completion")
    func skillRetiresLegacyStatusAssertions() throws {
        let source = try skillSource()
        for verb in ["message", "needs-you", "done"] {
            #expect(!source.contains("\"$AS_CLI\" \(verb)"))
        }
        #expect(!source.contains("## The four calls"))
        #expect(source.contains("--reason"))
        #expect(source.contains("nonblocking"))
        #expect(source.contains("lifecycle hooks own status"))
        #expect(!source.contains("\"$AS_CLI\" line --done"))
        #expect(source.contains("notify --kind done` is a notice, not a status transition"))
    }

    @Test("the skill teaches when pane-context updates and decisions belong in Agent Studio")
    func skillTeachesPaneContextDuties() throws {
        let source = try skillSource()
        #expect(source.contains("Update it when the work changes and clear obsolete text"))
        #expect(source.contains("Use an ask for a decision"))
        #expect(source.contains("withdraw obsolete owned messages"))
        #expect(source.contains("Retain the returned ID and read the answer before dependent work"))
    }

    @Test("the shipped skill teaches message-only line, age, and exact legacy recovery")
    func skillTeachesMessageOnlyLine() throws {
        let source = try skillSource()
        #expect(source.contains("\"$AS_CLI\" line \"Migrating staging; checking deployment logs\""))
        #expect(source.contains("\"$AS_CLI\" line --clear"))
        #expect(source.contains("fixed message icon and relative age"))
        #expect(source.contains("no timed expiry or age dimming"))
        #expect(
            source.contains(
                "Agent Line accepts a message only. Use: agentstudio line \"<message>\" or agentstudio line --clear. Status comes from harness hooks; use agentstudio ask \"<question>\" when you need the user."
            ))
        #expect(source.contains("report a version mismatch instead of reviving those forms"))
    }

    private func skillSource() throws -> String {
        let root = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let skill = root.appending(path: "Sources/AgentStudio/Resources/AgentPackage/skills/agentstudio")
        let files = try FileManager.default.subpathsOfDirectory(atPath: skill.path).filter { $0.hasSuffix(".md") }
            .sorted()
        return try files.map { try String(contentsOf: skill.appending(path: $0), encoding: .utf8) }.joined(
            separator: "\n")
    }
}
