import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("App IPC CLI raw commands", .serialized)
struct AppIPCCLIRawCommandTests {
    @Test("execute sends an empty raw argument map with one login and no discovery")
    func emptyArgumentsExecuteDirectly() async throws {
        let correlationId = UUIDv7.generate()
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: ["command.execute", "--command-id", recordedCLILiveCommandID.rawValue],
                includesLiveCommand: true, correlationId: correlationId))

        #expect(observed.outcome.exitCode == 0, "stderr: \(observed.outcome.standardError)")
        #expect(observed.acceptedConnections == 1)
        #expect(observed.requests.map(\.method) == ["auth.login", "command.execute"])
        let request = try #require(observed.requests.first { $0.method == "command.execute" })
        #expect(
            request.params
                == .object([
                    "commandId": .string(recordedCLILiveCommandID.rawValue),
                    "correlationId": .string(correlationId.uuidString), "arguments": .object([:]),
                ]))
        #expect(observed.executedCommands.map(\.arguments) == [.noArguments])
    }

    @Test("a real CLI subprocess executes raw key=value arguments and preserves supplied correlation")
    func subprocessExecutesRawArguments() async throws {
        let repositoryId = UUIDv7.generate()
        let correlationId = UUIDv7.generate()
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: [
                    "command.execute", "--command-id", recordedCLILiveCommandID.rawValue,
                    "--arg", "repoId=\(repositoryId.uuidString)", "--correlation-id", correlationId.uuidString,
                ],
                includesLiveCommand: true, commandArgumentExample: .repository(.init(repoId: repositoryId)),
                correlationId: correlationId, execution: .subprocess(try cliExecutableURL())))

        #expect(observed.outcome.exitCode == 0, "stderr: \(observed.outcome.standardError)")
        #expect(observed.acceptedConnections == 1)
        #expect(observed.requests.map(\.method) == ["auth.login", "command.execute"])
        #expect(observed.executedCommands.map(\.arguments) == [.repository(.init(repoId: repositoryId))])
        #expect(observed.executedCommands.map(\.correlationId) == [correlationId])
        let result = try JSONDecoder().decode(
            IPCCommandExecutionResult.self, from: Data(observed.outcome.standardOutput.utf8))
        #expect(result.commandId == recordedCLILiveCommandID)
        #expect(result.correlationId == correlationId)
    }

    @Test("raw string arguments keep spaces and every equals sign after the first")
    func rawStringArgumentsArePreserved() async throws {
        let windowId = UUIDv7.generate()
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: [
                    "command.execute", "--command-id", recordedCLILiveCommandID.rawValue,
                    "--arg", "workspaceWindowId=\(windowId.uuidString)", "--arg", "title=hello = world", "--arg",
                    "launchDirectory=/tmp/a path",
                ],
                includesLiveCommand: true,
                commandArgumentExample: .floatingTerminal(
                    .init(workspaceWindowId: windowId, launchDirectory: "/tmp/a path", title: "hello = world"))))

        #expect(observed.outcome.exitCode == 0, "stderr: \(observed.outcome.standardError)")
        #expect(observed.requests.map(\.method) == ["auth.login", "command.execute"])
        #expect(
            observed.executedCommands.map(\.arguments) == [
                .floatingTerminal(
                    .init(workspaceWindowId: windowId, launchDirectory: "/tmp/a path", title: "hello = world"))
            ])
    }

    @Test("explicit command.list is a single live call without capabilities discovery")
    func commandListIsDirectDiscovery() async throws {
        let observed = try await runRecordedCLIInvocation(.init(arguments: ["command.list"], includesLiveCommand: true))

        #expect(observed.outcome.exitCode == 0, "stderr: \(observed.outcome.standardError)")
        #expect(observed.acceptedConnections == 1)
        #expect(observed.requests.map(\.method) == ["auth.login", "command.list"])
        let catalog = try JSONDecoder().decode(
            IPCCommandCatalogResult.self, from: Data(observed.outcome.standardOutput.utf8))
        #expect(catalog.commands.map(\.id) == [recordedCLILiveCommandID])
    }

    @Test("an invalid raw argument returns the app correction verbatim in a CLI subprocess")
    func badArgumentCorrectionSurvivesCLI() async throws {
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: [
                    "command.execute", "--command-id", recordedCLILiveCommandID.rawValue, "--arg", "repoId=not-a-uuid",
                ],
                includesLiveCommand: true, commandArgumentExample: .repository(.init(repoId: UUIDv7.generate())),
                execution: .subprocess(try cliExecutableURL())))
        let correction = try JSONDecoder().decode(JSONValue.self, from: Data(observed.outcome.standardError.utf8))
        guard case .object(let fields) = correction else {
            Issue.record("CLI correction must be an object")
            return
        }
        #expect(observed.outcome.exitCode != 0)
        #expect(observed.acceptedConnections == 1)
        #expect(observed.requests.map(\.method) == ["auth.login", "command.execute"])
        #expect(fields["reason"] == .string("invalidArguments"))
        #expect(fields["fieldPath"] == .string("$.arguments.repoId"))
        guard case .string(let expected) = fields["expected"] else {
            Issue.record("App correction expected text must survive CLI stderr")
            return
        }
        #expect(!expected.isEmpty)
        #expect(observed.executedCommands.isEmpty)
    }

    @Test("unknown commands return bounded visible closest matches in a CLI subprocess")
    func unknownCommandCorrectionSurvivesCLI() async throws {
        let sent = "fixture.fastCLIHelq"
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: ["command.execute", "--command-id", sent], includesLiveCommand: true,
                execution: .subprocess(try cliExecutableURL())))
        let correction = try JSONDecoder().decode(JSONValue.self, from: Data(observed.outcome.standardError.utf8))
        guard case .object(let fields) = correction else {
            Issue.record("CLI correction must be an object")
            return
        }
        #expect(observed.outcome.exitCode != 0)
        #expect(observed.requests.map(\.method) == ["auth.login", "command.execute"])
        #expect(fields["reason"] == .string("unknownCommand"))
        #expect(fields["commandId"] == .string(sent))
        guard case .array(let matches) = fields["closestMatches"] else {
            Issue.record("Closest matches must survive CLI stderr")
            return
        }
        #expect(matches == [.string(recordedCLILiveCommandID.rawValue)])
        #expect(matches.count <= 5)
        #expect(observed.executedCommands.isEmpty)
    }

    @Test(
        "malformed or repeated --arg keys fail locally with zero requests",
        arguments: [
            ["--arg", "missing-equals"], ["--arg", "=value"], ["--arg", "repoId=one", "--arg", "repoId=two"],
        ])
    func invalidRawFlagSyntaxNeverContactsServer(suffix: [String]) async throws {
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: ["command.execute", "--command-id", recordedCLILiveCommandID.rawValue] + suffix,
                includesLiveCommand: true))

        #expect(observed.outcome.exitCode != 0)
        #expect(observed.acceptedConnections == 0)
        #expect(observed.requests.isEmpty)
        #expect(observed.executedCommands.isEmpty)
    }
}
