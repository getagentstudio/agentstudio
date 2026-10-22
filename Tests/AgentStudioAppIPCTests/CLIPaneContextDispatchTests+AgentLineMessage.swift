import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation
import Testing

extension CLIPaneContextDispatchTests {
    @Test(
        "removed Agent Line options explain the message contract without any IPC",
        arguments: [
            ["message", "--working"], ["message", "--done"], ["message", "--step", "3/7"],
            ["message", "--monitoring", "CI"], ["message", "--blocked-on-you", "approve"],
            ["message", "--failed", "compile"], ["message", "--detail", "details"],
            ["message", "--expires", "60"], ["--step"], ["--monitoring"], ["--blocked-on-you"],
            ["--failed"], ["--detail"], ["--expires"], ["--clear", "--working"], ["--clear", "--done"],
            ["--clear", "--step", "1/2"], ["--clear", "--monitoring", "CI"],
            ["--clear", "--blocked-on-you", "approve"], ["--clear", "--failed", "compile"],
            ["--clear", "--detail", "details"], ["--clear", "--expires", "60"],
        ])
    func agentLineMessageRejectsRetiredOptions(arguments: [String]) async throws {
        try await withS5PaneCLIContext { context in
            let output = try await context.run(["line"] + arguments)
            let error = try #require(String(bytes: output.standardError, encoding: .utf8))

            #expect(output.terminationStatus != 0)
            #expect(
                error.trimmingCharacters(in: .newlines)
                    == "Agent Line accepts a message only. Use: agentstudio line \"<message>\" or agentstudio line --clear. Status comes from harness hooks; use agentstudio ask \"<question>\" when you need the user."
            )
            #expect(context.port.wire.connections == 0)
            #expect(context.port.wire.methods.isEmpty)
        }
    }

    @Test("the compiled message and clear forms round-trip exact text through IPC")
    func agentLineMessageRoundTripsAndClears() async throws {
        try await withS5PaneCLIContext { context in
            let message = "Checking --done wording 🚀\nsecond line é中"
            let written = try await context.run(["line", message])
            try #require(written.terminationStatus == 0)
            let read = try await context.run(["pane"])
            try #require(read.terminationStatus == 0)
            let detail = try JSONDecoder().decode(IPCPaneContextGetResult.self, from: read.standardOutput)
            #expect(detail.agentLine?.summary == message)
            let request = try #require(context.port.wire.requests.first { $0.method == "pane.line.set" })
            guard case .object(let parameters)? = request.params, case .object(let line)? = parameters["line"] else {
                Issue.record("Missing actual line payload")
                return
            }
            #expect(Set(line.keys) == ["summary", "refs"])
            let cleared = try await context.run(["line", "--clear"])
            try #require(cleared.terminationStatus == 0)
            let empty = try await context.run(["pane"])
            try #require(empty.terminationStatus == 0)
            #expect(try JSONDecoder().decode(IPCPaneContextGetResult.self, from: empty.standardOutput).agentLine == nil)
        }
    }

    @Test("offline Agent Line help advertises only the message and clear forms")
    func agentLineMessageHelpHasNoWorkOptions() async throws {
        try await withS5PaneCLIContext { context in
            let output = try await context.run(["line", "--help"], useStore: false)
            #expect(output.terminationStatus == 0)
            let help = try #require(String(bytes: output.standardOutput, encoding: .utf8))
            #expect(help.contains("line \"<message>\""))
            #expect(help.contains("line --clear"))
            for option in [
                "--working", "--done", "--step", "--monitoring", "--blocked-on-you", "--failed", "--detail",
                "--expires",
            ] {
                #expect(!help.contains(option))
            }
            #expect(context.port.wire.connections == 0)
        }
    }
}
