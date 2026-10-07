import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

/// The provider hooks and the model verbs run several times a turn under short
/// timeouts, so what matters is not only that they answer but that they do not
/// pull the whole self-describing catalog first. A proxy in front of the real
/// server records exactly which methods the client asks for.
///
/// The client runs in process rather than as a spawned binary. The dispatch
/// under test is `AgentStudioIPCClientCommandLineRunner`, which is the whole of
/// what the shipped CLI does; `main.swift` only binds it to argv and stdio.
/// `AppIPCDynamicCommandClientTests` keeps the subprocess cases that prove the
/// built binary itself runs.
@Suite("App IPC CLI catalog discovery skip", .serialized)
struct AppIPCCLICatalogDiscoverySkipTests {
    @Test("a session verb reaches the server without fetching the catalog")
    func sessionVerbSkipsCatalogDiscovery() async throws {
        let observed = try await runClientThroughRecordingProxy(arguments: ["message", "hi"])

        #expect(!observed.contains("system.capabilities"))
        #expect(observed.contains("session.message"))
    }

    @Test("a session method named outright also skips the catalog")
    func namedSessionMethodSkipsCatalogDiscovery() async throws {
        let observed = try await runClientThroughRecordingProxy(
            arguments: ["session.query", "--handle", "self"])

        #expect(!observed.contains("system.capabilities"))
        #expect(observed.contains("session.query"))
    }

    @Test("a bare --json on a parameterless method means no parameters")
    func bareJSONFlagMeansNoParameters() async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(accessMode: .unsafeDebug, channel: .debug) },
            body: { fixture in
                try fixture.server.start()
                var environment = ProcessInfo.processInfo.environment
                environment["AGENTSTUDIO_IPC_SOCKET"] = fixture.paths.socketURL.path
                environment.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN")

                let bare = await runClientCommandLineOffCooperativePool(
                    arguments: ["system.ping", "--json"], environment: environment)
                let plain = await runClientCommandLineOffCooperativePool(
                    arguments: ["system.ping"], environment: environment)

                #expect(bare.exitCode == 0, "stderr: \(bare.standardError)")
                #expect(bare.standardOutput == plain.standardOutput)
            })
    }

    @Test("command.execute sends its compiled raw envelope without discovery")
    func commandExecuteSkipsDiscovery() async throws {
        let observed = try await runRecordedCLIInvocation(
            .init(
                arguments: ["command.execute", "--command-id", recordedCLILiveCommandID.rawValue],
                includesLiveCommand: true))
        #expect(!observed.requests.contains { $0.method == "system.capabilities" || $0.method == "command.list" })
        #expect(observed.requests.map(\.method) == ["auth.login", "command.execute"])
        #expect(observed.outcome.exitCode == 0, "stderr: \(observed.outcome.standardError)")
    }

}

private func runClientThroughRecordingProxy(arguments: [String]) async throws -> [String] {
    try await runRecordedCLIInvocation(.init(arguments: arguments, authenticated: false)).requests.map(\.method)
}
