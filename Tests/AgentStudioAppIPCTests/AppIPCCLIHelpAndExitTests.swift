import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("App IPC CLI help and exit codes", .serialized)
struct AppIPCCLIHelpAndExitTests {
    @Test("local help works in a real CLI process with no app", arguments: [["--help"], ["help"], ["help", "--help"]])
    func localHelpNeedsNoApp(arguments: [String]) async throws {
        let output = try await runCLI(
            executableURL: cliExecutableURL(), arguments: arguments, environment: offlineEnvironment())
        let text = try #require(String(bytes: output.standardOutput, encoding: .utf8))

        #expect(
            output.exitCode == 0,
            "stderr: \(String(bytes: output.standardError, encoding: .utf8) ?? "Invalid UTF-8 stderr")")
        #expect(output.standardError.isEmpty)
        if arguments == ["help", "--help"] {
            let root = try await runCLI(
                executableURL: cliExecutableURL(), arguments: ["--help"], environment: offlineEnvironment())
            #expect(root.exitCode == 0)
            #expect(output.standardOutput == root.standardOutput)
        }
        for name in ["system.identify", "terminal.send", "pane.close", "drawer.toggle", "session.query"] {
            #expect(text.contains(name), "missing compiled method: \(name)")
        }
        #expect(!text.contains(recordedCLILiveCommandID.rawValue))
        #expect(
            text.components(separatedBy: "\n").contains(
                "  agentstudio package install claude|codex|cursor [OPTIONS]  (provider hooks and skill; see agentstudio package --help)"
            ))
    }

    @Test("method help comes from the compiled descriptor without an app")
    func methodHelpComesFromDescriptor() async throws {
        let output = try await runCLI(
            executableURL: cliExecutableURL(), arguments: ["terminal.send", "--help"],
            environment: offlineEnvironment())
        let text = try #require(String(bytes: output.standardOutput, encoding: .utf8))
        let description = try terminalSendDescription()

        #expect(
            output.exitCode == 0,
            "stderr: \(String(bytes: output.standardError, encoding: .utf8) ?? "Invalid UTF-8 stderr")")
        #expect(output.standardError.isEmpty)
        #expect(text.contains("terminal.send"))
        #expect(text.contains(description))
        #expect(text.contains("handle"))
        #expect(text.contains("input"))
        #expect(text.contains("correlationId"))
    }

    @Test("auth.login help describes its credential and JSON stdin forms without argv credentials")
    func authLoginHelpMatchesAcceptedSyntax() async throws {
        let output = try await runCLI(
            executableURL: cliExecutableURL(), arguments: ["auth.login", "--help"], environment: offlineEnvironment())
        let text = try #require(String(bytes: output.standardOutput, encoding: .utf8))
        let expected = """
            auth.login — Authenticate this connection with the owning runtime credential.
            Usage: agentstudio auth.login
                   agentstudio auth.login --stdin
            agentstudio auth.login uses the resolved credential: the pane's inherited token, or a raw token from agentstudio --token-stdin auth.login.
            agentstudio auth.login --stdin reads the JSON parameter object from standard input.
            --token-stdin and --stdin can't be combined.
            JSON fields:
              token (required) — Bearer credential supplied by the owning runtime
            """
        #expect(output.exitCode == 0)
        #expect(output.standardError.isEmpty)
        #expect(text == expected + "\n")
        #expect(!text.contains("--token <value>"))
        #expect(!text.contains("--json"))
        #expect(!text.contains("example-runtime-credential"))
    }

    @Test("live help explicitly fetches commands and prints a real advertised command")
    func liveHelpDiscoversCommands() async throws {
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: ["help", "--live"], includesLiveCommand: true,
                execution: .subprocess(try cliExecutableURL())))

        #expect(observed.outcome.exitCode == 0, "stderr: \(observed.outcome.standardError)")
        #expect(observed.outcome.standardOutput.contains(recordedCLILiveCommandID.rawValue))
        // A2 / R31: live help reads only command.list presentation metadata.
        #expect(!observed.requests.contains { $0.method == "system.capabilities" })
        #expect(observed.requests.filter { $0.method == "command.list" }.count == 1)
        #expect(!observed.requests.contains { $0.method == "command.execute" })
    }

    @Test("capabilities stdin reaches a real server through the CLI process")
    func capabilitiesStdinWorksInSubprocess() async throws {
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: ["system.capabilities", "--stdin"], standardInput: Data("{}".utf8),
                execution: .subprocess(try cliExecutableURL())))

        #expect(observed.outcome.exitCode == 0, "stderr: \(observed.outcome.standardError)")
        #expect(observed.acceptedConnections == 1)
        #expect(observed.requests.map(\.method) == ["auth.login", "system.capabilities"])
        let catalog = try JSONDecoder().decode(
            IPCMethodCatalogResult.self, from: Data(observed.outcome.standardOutput.utf8))
        #expect(catalog.methods.contains { $0.name == "system.capabilities" })
    }

    @Test(
        "local CLI errors exit nonzero with a diagnostic",
        arguments: [
            [], ["--unknown-option"], ["terminal.sned"], ["help", "future.method"],
            ["terminal.send", "--handle", "self"],
        ])
    func localErrorsExitNonzero(arguments: [String]) async throws {
        let output = try await runCLI(
            executableURL: cliExecutableURL(), arguments: arguments, environment: offlineEnvironment())

        #expect(output.exitCode != 0)
        #expect(!output.standardError.isEmpty)
        #expect(output.standardOutput.isEmpty)
    }

    @Test("removed package commands reject locally", arguments: ["claude", "codex", "cursor"])
    func removedPackageCommandsRejectLocally(provider: String) async throws {
        let output = try await runCLI(
            executableURL: cliExecutableURL(), arguments: ["package", "uninstall", provider],
            environment: offlineEnvironment())

        #expect(output.exitCode == 64)
        #expect(output.standardOutput.isEmpty)
        #expect(
            String(bytes: output.standardError, encoding: .utf8)
                == "agentstudio package: unknown subcommand uninstall\n\(expectedPackageUsage)\n")
    }

    @Test("a real server refusal exits nonzero in the CLI process")
    func remoteErrorsExitNonzero() async throws {
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: ["terminal.status", "--handle", "self"],
                execution: .subprocess(try cliExecutableURL())))

        #expect(observed.requests.contains { $0.method == "terminal.status" })
        #expect(observed.outcome.exitCode != 0)
        #expect(!observed.outcome.standardError.isEmpty)
        #expect(observed.outcome.standardOutput.isEmpty)
    }

    private func offlineEnvironment() -> [String: String] {
        ["AGENTSTUDIO_IPC_SOCKET": "/tmp/asipc-absent-\(UUIDv7.generate().uuidString).sock"]
    }

    private func terminalSendDescription() throws -> String {
        let context = IPCBuiltInMethodExampleContext(illustrativeIdentifier: UUIDv7.generate())
        let inputs = IPCBuiltInMethodCatalogInputs(
            relationships: .init(
                paneFocus: .noInteractiveIdentity, paneClose: .noInteractiveIdentity,
                drawerToggle: .noInteractiveIdentity, drawerAddPane: .noInteractiveIdentity,
                bridgeDiffLoad: .noInteractiveIdentity, bridgeFileViewOpen: .noInteractiveIdentity),
            examples: context)
        return try IPCBuiltInMethodCatalog(inputs: inputs).terminal.terminalSend.description
    }
}
