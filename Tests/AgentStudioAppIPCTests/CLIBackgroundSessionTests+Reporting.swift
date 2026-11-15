import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioSessions

extension CLIBackgroundSessionTests {
    @Test("successful background answers retain and reuse their bookmark")
    func backgroundAnswersKeepTheirPosition() async throws {
        try await withS5PaneCLIContext { context in
            let messageId = try await context.seedAnswer("background answer")
            var environment = context.callEnvironment(store: nil, useStore: true)
            environment["CLAUDE_JOB_DIR"] = "/fixture/job"
            let first = try await runCLI(
                executableURL: context.executableURL, arguments: ["answers"], environment: environment)
            #expect(first.exitCode == 0)
            let reply = try JSONDecoder().decode(IPCPaneMessageChangesResult.self, from: first.standardOutput)
            #expect(reply.entries.map(\.messageId) == [messageId])
            let saved = try await context.storedAnswerPosition()
            #expect(saved == Int64(reply.nextPosition))
            let second = try await runCLI(
                executableURL: context.executableURL, arguments: ["answers"], environment: environment)
            #expect(second.exitCode == 0)
            #expect(context.port.changes.last?.after == reply.nextPosition)
        }
    }

    @Test("raw pane reports obey background containment", arguments: [false, true])
    func rawReportsCannotBypassFriendlyVerbs(background: Bool) async throws {
        try await withS5PaneCLIContext { context in
            var environment = context.callEnvironment(store: nil, useStore: true)
            if background { environment["CLAUDE_JOB_DIR"] = "/fixture/job" }
            let parameters = IPCPaneMessageSendParams(
                handle: "self", messageId: UUIDv7.generate(), importance: .info,
                body: "raw notice", actions: [], shape: .notice, correlationId: UUIDv7.generate())
            let payload = try #require(String(data: JSONEncoder().encode(parameters), encoding: .utf8))
            let output = try await runCLI(
                executableURL: context.executableURL,
                arguments: ["pane.message.send", "--json", payload], environment: environment)
            if background {
                #expect(output.exitCode == 1)
                #expect(
                    String(data: output.standardError, encoding: .utf8)
                        == "background session: not attached to a pane\n")
                #expect(context.port.wire.connections == 0)
                #expect(context.port.messages.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: context.storeURL.path))
            } else {
                #expect(output.exitCode == 0)
                #expect(context.port.messages.map(\.body) == ["raw notice"])
                #expect(context.port.wire.methods == ["auth.login", "pane.message.send"])
            }
        }
    }

    @Test(
        "failed background reads preserve their failure without publishing a credential refusal",
        arguments: ["pane", "answers", "withdraw"], [false, true])
    func readFailureCannotReportStatus(verb: String, absentToken: Bool) async throws {
        func observe(background: Bool) async throws -> (Int32, Data) {
            try await withS5PaneCLIContext(bindSession: false) { context in
                var environment = context.callEnvironment(store: nil, useStore: true)
                if background { environment["CLAUDE_JOB_DIR"] = "/fixture/job" }
                if absentToken {
                    environment.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN")
                } else {
                    environment["AGENTSTUDIO_PANE_TOKEN"] = "rejected-fixture-token"
                }
                let mailbox = await context.domain.ingestion.statusPublicationMailbox
                _ = mailbox.takeBatch()
                let arguments = verb == "withdraw" ? [verb, UUIDv7.generate().uuidString] : [verb]
                let output = try await runCLI(
                    executableURL: context.executableURL, arguments: arguments, environment: environment)
                #expect(output.exitCode != 0)
                #expect(!output.standardError.isEmpty)
                let refusal = await context.domain.ingestion.lastRefusal(paneId: context.domain.paneId)
                if background {
                    #expect(!context.port.wire.methods.contains("session.status"))
                    #expect(refusal == nil)
                    #expect(mailbox.takeBatch().isEmpty)
                } else {
                    #expect(context.port.wire.methods.last == "session.status")
                    #expect(refusal?.reason == .credentialNotRecognized)
                    #expect(!mailbox.takeBatch().isEmpty)
                }
                #expect(context.port.messages.isEmpty)
                #expect(context.port.asks.isEmpty)
                return (output.exitCode, output.standardError)
            }
        }
        let foreground = try await observe(background: false)
        let background = try await observe(background: true)
        #expect(background.0 == foreground.0)
        #expect(background.1 == foreground.1)
    }
}
