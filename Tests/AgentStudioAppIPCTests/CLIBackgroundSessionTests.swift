import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Background session CLI isolation", .serialized)
struct CLIBackgroundSessionTests {
    @Test(
        "background writes refuse before IPC or local storage",
        arguments: ["CLAUDE_JOB_DIR", "CLAUDE_CODE_SESSION_KIND"])
    func backgroundWritesLeavePaneUntouched(marker: String) async throws {
        try await withS5PaneCLIContext { context in
            var environment = context.callEnvironment(store: nil, useStore: true)
            environment[marker] = marker == "CLAUDE_JOB_DIR" ? "/fixture/background-job" : "bg"
            let commands = [
                ["line", "background line"], ["title", "background title"],
                ["notify", "background notice"], ["ask", "background question", "--reason", "blocked"],
            ]
            for arguments in commands {
                let output = try await runCLI(
                    executableURL: context.executableURL, arguments: arguments, environment: environment)
                #expect(output.exitCode == 1)
                #expect(output.standardOutput.isEmpty)
                #expect(
                    String(data: output.standardError, encoding: .utf8)
                        == "background session: not attached to a pane\n")
            }
            #expect(context.port.wire.connections == 0)
            #expect(context.port.wire.methods.isEmpty)
            #expect(context.port.titles.isEmpty)
            #expect(context.port.lineWriteCount == 0)
            #expect(context.port.messages.isEmpty)
            #expect(context.port.asks.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: context.storeURL.path))
        }
    }

    @Test("background refusal precedes endpoint discovery", arguments: ["line", "title", "notify", "ask"])
    func backgroundRefusalNeedsNoEndpoint(verb: String) async throws {
        let output = try await runCLI(
            executableURL: cliExecutableURL(), arguments: [verb, "background intent"],
            environment: ["CLAUDE_JOB_DIR": "/fixture/background-job"])
        #expect(output.exitCode == 1)
        #expect(output.standardOutput.isEmpty)
        #expect(String(data: output.standardError, encoding: .utf8) == "background session: not attached to a pane\n")
    }

    @Test("foreground controls with empty or non-background markers still write", arguments: ["", "foreground"])
    func foregroundWritesRemainAvailable(kind: String) async throws {
        try await withS5PaneCLIContext { context in
            var environment = context.callEnvironment(store: nil, useStore: true)
            environment["CLAUDE_JOB_DIR"] = ""
            environment["CLAUDE_CODE_SESSION_KIND"] = kind
            let output = try await runCLI(
                executableURL: context.executableURL, arguments: ["notify", "foreground notice"],
                environment: environment)
            #expect(output.exitCode == 0)
            #expect(context.port.messages.map(\.body) == ["foreground notice"])
        }
    }
}
