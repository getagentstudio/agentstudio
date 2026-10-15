import AgentStudioCore
import AgentStudioDeadlineTestSupport
import AgentStudioIPCClientCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@Suite("Pane CLI status fallback ordering", .serialized)
struct CLIPaneContextStatusFallbackTests {
    @Test(
        "refused-token title and line allocate a pane epoch then reuse it", arguments: ["title", "line"],
        ["claude", "codex"])
    func firstAndCachedEpochUsePaneWriter(verb: String, provider: String) async throws {
        try await withRefusedTokenPaneCLIContext(provider: provider) { context in
            let first = await runFallbackCLI(context, arguments: [verb, "first"])
            #expect(first.exitCode == 0)
            #expect(context.port.wire.methods == ["auth.login", "pane.writer.claimEpoch", "pane.\(verb).set"])
            let claim = try #require(context.port.claims.first)
            #expect(claim.writer == nil)
            #expect(claim.paneClaim?.paneId == context.domain.paneId)
            #expect(claim.paneClaim?.workspaceId.uuidString == context.environment["AGENTSTUDIO_WORKSPACE_ID"])
            let second = await runFallbackCLI(context, arguments: [verb, "second"])
            #expect(second.exitCode == 0)
            #expect(Array(context.port.wire.methods.suffix(2)) == ["auth.login", "pane.\(verb).set"])
            #expect(context.port.claims.count == 1)
            let detail = await context.domain.service.readDetail(
                .init(paneId: PaneId(existingUUID: context.domain.paneId), page: .first))
            guard case .detail(let value) = detail else {
                Issue.record("Missing post-write pane context")
                return
            }
            if verb == "title" {
                #expect(value.agentTitle == "second")
                #expect(context.port.titles.map(\.number.counter) == [1, 2])
                #expect(context.port.titles.allSatisfy { $0.writer == nil && $0.paneClaim == claim.paneClaim })
            } else {
                #expect(value.agentLine?.summary == "second")
                #expect(context.port.lineWriteCount == 2)
            }
            #expect(value.session?.sessionRef.value == context.writer.conversationId)
            #expect(context.port.messages.isEmpty)
        }
    }

    @Test(
        "protected verbs keep the refused token and never send a pane claim",
        arguments: ["notify", "ask", "answers", "pane"])
    func protectedVerbsNeverFallBack(verb: String) async throws {
        try await withRefusedTokenPaneCLIContext { context in
            let arguments = ["notify", "ask"].contains(verb) ? [verb, "protected"] : [verb]
            let output = await runFallbackCLI(context, arguments: arguments)
            #expect(output.exitCode != 0)
            #expect(context.port.wire.methods == ["auth.login"])
            #expect(context.port.claims.isEmpty)
            #expect(context.port.messages.isEmpty)
        }
    }

    @Test("a refused-token shell discovers the same cli.sqlite beside matching runtime metadata")
    func metadataDiscoversExistingStore() async throws {
        try await withRefusedTokenPaneCLIContext { context in
            let storeURL = context.fixture.paths.socketURL.deletingLastPathComponent().appending(path: "cli.sqlite")
            var explicit = context.environment
            explicit["AGENTSTUDIO_CLI_STORE"] = storeURL.path
            explicit["AGENTSTUDIO_CLI_STORE_CHANNEL"] = "debug"
            let seed = await runFallbackCLI(context, arguments: ["title", "seed"], environment: explicit)
            #expect(seed.exitCode == 0)
            let discovered = await runFallbackCLI(
                context, arguments: ["title", "discovered"], environment: context.environment)
            #expect(discovered.exitCode == 0)
            #expect(context.port.claims.count == 1)
            #expect(context.port.titles.map(\.number.counter) == [1, 2])
            #expect(try await context.title() == "discovered")
        }
    }

    @Test(
        "missing, mismatched or unreadable runtime metadata refuses without an ordering mutation",
        arguments: ["missing", "mismatched", "unreadable", "channelMismatch", "missingStore"])
    func missingStoreIsLocalRefusal(metadataCase: String) async throws {
        try await withRefusedTokenPaneCLIContext { context in
            let directory = context.fixture.paths.socketURL.deletingLastPathComponent()
            let hasStore = metadataCase != "missingStore"
            if hasStore {
                var seedEnvironment = context.environment
                seedEnvironment["AGENTSTUDIO_CLI_STORE"] = directory.appending(path: "cli.sqlite").path
                seedEnvironment["AGENTSTUDIO_CLI_STORE_CHANNEL"] = "debug"
                let seed = await runFallbackCLI(context, arguments: ["title", "seed"], environment: seedEnvironment)
                try #require(seed.exitCode == 0)
            }
            let methodsBefore = context.port.wire.methods
            let claimsBefore = context.port.claims.count
            let titlesBefore = context.port.titles.count
            try await valueFromDedicatedThread {
                let metadataURL = directory.appending(path: "runtime.json")
                switch metadataCase {
                case "missing": try FileManager.default.removeItem(at: metadataURL)
                case "mismatched":
                    try Data(#"{"socketPath":"/another/socket","channel":"debug"}"#.utf8).write(to: metadataURL)
                case "unreadable": try Data("invalid metadata".utf8).write(to: metadataURL)
                case "channelMismatch":
                    try JSONSerialization.data(withJSONObject: [
                        "socketPath": context.fixture.paths.socketURL.path, "channel": "beta",
                    ]).write(to: metadataURL)
                default: break
                }
            }
            let result = await runFallbackCLI(
                context, arguments: ["title", "refused"], environment: context.environment)
            #expect(result.exitCode != 0)
            #expect(result.standardError.contains("orderingStoreUnavailable"))
            #expect(context.port.wire.methods == methodsBefore)
            #expect(context.port.claims.count == claimsBefore)
            #expect(context.port.titles.count == titlesBefore)
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "cli.sqlite").path) == hasStore)
        }
    }

    @Test("a refused-token lower counter is final and only a new intent receives the next counter")
    func staleCounterNeverResubmits() async throws {
        try await withRefusedTokenPaneCLIContext { context in
            #expect(await runFallbackCLI(context, arguments: ["title", "seed"]).exitCode == 0)
            let seed = try #require(context.port.titles.first)
            let claim = try #require(context.port.claims.first?.paneClaim)
            let higher = IPCPaneTitleSetParams(
                handle: "self", paneClaim: claim, text: "higher",
                writeNumber: .init(epoch: seed.number.epoch, counter: 17),
                correlationId: UUIDv7.generate())
            var tokenless = context.environment
            tokenless.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN")
            let json = try #require(String(data: JSONEncoder().encode(higher), encoding: .utf8))
            let competing = await runFallbackCLI(
                context, arguments: ["pane.title.set", "--json", json], environment: tokenless)
            #expect(competing.exitCode == 0)
            let refused = await runFallbackCLI(context, arguments: ["title", "lower"])
            #expect(refused.exitCode != 0)
            #expect(refused.standardError.contains("lastAccepted"))
            #expect(context.port.titles.filter { $0.text == "lower" }.count == 1)
            #expect(try await context.title() == "higher")
            #expect(await runFallbackCLI(context, arguments: ["title", "next"]).exitCode == 0)
            #expect(context.port.titles.last?.number == .init(epoch: seed.number.epoch, counter: 18))
        }
    }

    @Test(
        "an older refused-token call cannot overwrite a newer title through an explicit or discovered store",
        arguments: [false, true], ["claude", "codex"])
    func heldOlderCallIsRejected(discoverStore: Bool, provider: String) async throws {
        try await withRefusedTokenPaneCLIContext(provider: provider) { context in
            var seedEnvironment = context.callEnvironment(store: nil, useStore: true)
            if discoverStore {
                seedEnvironment["AGENTSTUDIO_CLI_STORE"] =
                    context.fixture.paths.socketURL.deletingLastPathComponent()
                    .appending(path: "cli.sqlite").path
            }
            let seed = await runFallbackCLI(context, arguments: ["title", "seed"], environment: seedEnvironment)
            try #require(seed.exitCode == 0)
            let writeEnvironment = discoverStore ? context.environment : seedEnvironment
            let scope = UUIDv7.generate()
            let hold = context.port.holdNextTitle(in: scope)
            let older = Task {
                let result = await runFallbackCLI(
                    context, arguments: ["title", "older"], environment: writeEnvironment)
                hold.retire()
                return result
            }
            do {
                let request = try await hold.firstArrival()
                #expect(request.writer == nil)
                #expect(request.paneClaim?.paneId == context.domain.paneId)
                let newer = await runFallbackCLI(context, arguments: ["title", "newer"], environment: writeEnvironment)
                #expect(newer.exitCode == 0)
                hold.release()
                let stale = await older.value
                #expect(stale.exitCode != 0)
                #expect(stale.standardError.contains("lastAccepted"))
                #expect(try await context.title() == "newer")
                #expect(context.port.titles.filter { $0.text == "older" }.count == 1)
                #expect(context.port.titles.map(\.number.counter) == [1, 2, 3])
            } catch {
                hold.release()
                _ = await older.value
                throw error
            }
        }
    }
}

private func withRefusedTokenPaneCLIContext<Output: Sendable>(
    provider: String = "claude", _ body: (S5PaneCLIContext) async throws -> Output
) async throws -> Output {
    try await withS5PaneCLIContext { context in
        var environment = context.environment
        environment["AGENTSTUDIO_PANE_TOKEN"] = "unrecognized-pane-cli-fixture-token"
        if provider == "codex" {
            environment.removeValue(forKey: "CLAUDE_CODE_SESSION_ID")
            environment["CODEX_THREAD_ID"] = context.writer.conversationId
        }
        return try await body(
            S5PaneCLIContext(
                domain: context.domain, fixture: context.fixture, port: context.port, clients: context.clients,
                executableURL: context.executableURL, environment: environment, storeURL: context.storeURL,
                writer: context.writer))
    }
}

private func runFallbackCLI(
    _ context: S5PaneCLIContext, arguments: [String], environment: [String: String]? = nil
) async -> ClientCommandLineOutcome {
    let environment = environment ?? context.callEnvironment(store: nil, useStore: true)
    let driver = ControlledDeadlineDriver()
    defer { driver.close() }
    return await valueFromDedicatedThread {
        let output = Mutex<[String]>([])
        let error = Mutex<[String]>([])
        let status = AgentStudioIPCClientCommandLineRunner.run(
            props: .init(
                arguments: arguments, environment: environment, executablePath: context.executableURL.path,
                bundleExecutableURL: nil, standardInput: { Data() }, identifierGenerator: { UUIDv7.generate() },
                standardOutputSink: { line in output.withLock { $0.append(line) } },
                standardErrorSink: { line in error.withLock { $0.append(line) } }, deadlineTiming: driver.timing))
        return ClientCommandLineOutcome(
            exitCode: status, standardOutput: output.withLock { $0.joined(separator: "\n") },
            standardError: error.withLock { $0.joined(separator: "\n") })
    }
}
