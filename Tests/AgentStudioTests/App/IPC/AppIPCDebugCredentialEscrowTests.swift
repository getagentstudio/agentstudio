import AgentStudioAppIPC
import AgentStudioCLIStore
import AgentStudioDeadlineTestSupport
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import GRDB
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

#if canImport(Darwin)
    import Darwin
#endif

/// The debug credential exists only while the runtime does. These cases run the
/// real handover: mint on readiness, verify from memory on every call, and drop
/// both the verifier and the file the launcher named when the server stops.
@MainActor
@Suite("App IPC debug credential escrow", .serialized)
struct AppIPCDebugCredentialEscrowTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test(
        "IPC startup prepares a fresh ordering store for its published channel",
        arguments: [AgentStudioIPCChannel.stable, .beta, .debug])
    func startupPreparesOrderingStore(channel: AgentStudioIPCChannel) async throws {
        let harness = try await SessionsVerticalHarness.make(channel: channel)
        do {
            let paths = try #require(harness.appDelegate.appIPCPaths)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(
                AgentStudioIPCRuntimeMetadata.self, from: Data(contentsOf: paths.metadataURL))
            #expect(metadata.channel == channel)
            #expect(metadata.socketPath == paths.socketURL.path)
            try #require(FileManager.default.fileExists(atPath: paths.cliStoreURL.path))
            let expectedChannel = try #require(CLIStoreChannel(rawValue: metadata.channel.rawValue))
            let openedChannel = try await valueFromDedicatedThread {
                let writer = try CLIStore.openWriter(url: paths.cliStoreURL, channel: expectedChannel).get()
                let openedChannel = writer.identity.channel
                try writer.close()
                return openedChannel
            }
            #expect(openedChannel == expectedChannel)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("an unavailable ordering store leaves IPC running and the CLI refusal specific")
    func unavailableOrderingStoreDoesNotStopStartup() async throws {
        let harness = try await SessionsVerticalHarness.make(prepareRuntimePaths: { paths in
            try FileManager.default.createDirectory(at: paths.cliStoreURL, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.ipcDirectory.path)
        })
        do {
            let paths = try #require(harness.appDelegate.appIPCPaths)
            #expect(harness.appDelegate.appIPCServer != nil)
            #expect(FileManager.default.fileExists(atPath: paths.metadataURL.path))
            let response = try await harness.response(method: "system.ping", params: .object([:]))
            #expect(response.error == nil)
            #expect(response.result != nil)
            let result = await oldShellWrite(harness: harness, verb: "line")
            #expect(result.exitCode == 1)
            #expect(result.standardError == "unavailable(orderingStoreUnavailable)")
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("old-shell title and line allocate ordering without a new-shell seed", arguments: ["title", "line"])
    func oldShellWritesAfterStartup(verb: String) async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            let result = await oldShellWrite(harness: harness, verb: verb)
            #expect(result.exitCode == 0, "old-shell stderr: \(result.standardError)")
            #expect(result.standardError.isEmpty)
            let composition = try #require(harness.appDelegate.appIPCSessionsPaneContextComposition)
            let read = await composition.paneContextService.readDetail(
                .init(paneId: PaneId(existingUUID: harness.boundPaneId), page: .first))
            guard case .detail(let detail) = read else {
                Issue.record("old-shell write must leave readable pane context")
                await harness.tearDown()
                return
            }
            if verb == "title" {
                #expect(detail.agentTitle == "old-shell status")
            } else {
                #expect(detail.agentLine?.summary == "old-shell status")
            }
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test(
        "valid-token status writes use the pane when the provider session is unbound and retain bound attribution",
        arguments: ["claude-code", "codex"], [false, true])
    func validTokenStatusDoesNotRequireSessionBinding(provider: String, bindSession: Bool) async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            let conversationID = "status-session"
            if bindSession {
                let binding = try await harness.sessionEvent(
                    paneId: harness.boundPaneId,
                    provider: .init(identifier: provider, version: "1.0.0", mode: "cli"),
                    name: "toolActivity", conversationId: conversationID)
                try #require(binding.disposition == .admitted)
            }
            let token = try #require(harness.boundPaneToken)
            let environment = [
                "AGENTSTUDIO_IPC_SOCKET": harness.socketPath,
                "AGENTSTUDIO_PANE_ID": harness.boundPaneId.uuidString,
                "AGENTSTUDIO_WORKSPACE_ID": harness.commandHarness.store.identityAtom.workspaceId.uuidString,
                "AGENTSTUDIO_PANE_TOKEN": token.rawValue,
                provider == "codex" ? "CODEX_THREAD_ID" : "CLAUDE_CODE_SESSION_ID": conversationID,
            ]
            let composition = try #require(harness.appDelegate.appIPCSessionsPaneContextComposition)
            let paneID = harness.boundPaneId
            for verb in ["line", "title"] {
                let result = await oldShellWrite(harness: harness, verb: verb, environment: environment)
                #expect(result.exitCode == 0, "\(verb) exit \(result.exitCode): \(result.standardError)")
                #expect(result.standardError.isEmpty)
            }
            let read = await composition.paneContextService.readDetail(
                .init(paneId: PaneId(existingUUID: paneID), page: .first))
            guard case .detail(let detail) = read else {
                Issue.record("status writes must leave readable pane context")
                await harness.tearDown()
                return
            }
            #expect(detail.agentTitle == "old-shell status")
            let line = try #require(detail.agentLine)
            #expect(line.summary == "old-shell status")
            if bindSession {
                guard case .session(let writerProvider, let sessionRef, _) = line.writer else {
                    Issue.record("bound status must retain the session writer")
                    await harness.tearDown()
                    return
                }
                #expect(writerProvider.value == provider)
                #expect(sessionRef.value == conversationID)
                #expect(detail.session?.sessionRef.value == conversationID)
            } else {
                #expect(line.writer == .pane(PaneId(existingUUID: paneID)))
                #expect(detail.session == nil)
            }
            let sqliteAccess = await composition.paneContextService.sqliteAccess
            let titleWriter = try await sqliteAccess.read { database in
                try String.fetchOne(
                    database, sql: "SELECT writer_kind FROM pane_state WHERE pane_id = ? AND kind = 'agentTitle'",
                    arguments: [paneID.uuidString])
            }
            #expect(titleWriter == (bindSession ? "session" : "pane"))
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    private func oldShellWrite(
        harness: SessionsVerticalHarness, verb: String, environment suppliedEnvironment: [String: String]? = nil
    ) async -> OldShellWriteOutcome {
        let environment =
            suppliedEnvironment ?? [
                "AGENTSTUDIO_IPC_SOCKET": harness.socketPath,
                "AGENTSTUDIO_PANE_ID": harness.boundPaneId.uuidString,
                "AGENTSTUDIO_WORKSPACE_ID": harness.commandHarness.store.identityAtom.workspaceId.uuidString,
                "AGENTSTUDIO_PANE_TOKEN": "old-shell-unrecognized-token",
                "CLAUDE_CODE_SESSION_ID": "old-shell-provider-session",
            ]
        #expect(environment["AGENTSTUDIO_CLI_STORE"] == nil)
        #expect(environment["AGENTSTUDIO_CLI_STORE_CHANNEL"] == nil)
        let driver = ControlledDeadlineDriver()
        defer { driver.close() }
        return await valueFromDedicatedThread {
            let errors = Mutex<[String]>([])
            let status = AgentStudioIPCClientCommandLineRunner.run(
                props: .init(
                    arguments: [verb, "old-shell status"], environment: environment,
                    executablePath: "/isolated-fixture/agentstudio", bundleExecutableURL: nil,
                    standardInput: { Data() }, identifierGenerator: { UUIDv7.generate() },
                    standardOutputSink: { _ in }, standardErrorSink: { line in errors.withLock { $0.append(line) } },
                    deadlineTiming: driver.timing))
            return OldShellWriteOutcome(exitCode: status, standardError: errors.withLock { $0.joined(separator: "\n") })
        }
    }

    @Test("a debug app hands its reusable credential to an unrelated shell through the escrow file")
    func debugServerPublishesEscrowFileAndAuthenticatesItsToken() async throws {
        let escrowDirectory = FileManager.default.temporaryDirectory
            .appending(path: "as-ipc-escrow-\(UUIDv7.generate().uuidString.suffix(12))")
        try FileManager.default.createDirectory(
            at: escrowDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: escrowDirectory) }
        let escrowURL = escrowDirectory.appending(path: "debug-credential.json")

        let harness = try await SessionsVerticalHarness.make(debugCredentialEscrowURL: escrowURL)

        let escrow = try JSONDecoder().decode(
            IPCDebugCredentialEscrowDocument.self,
            from: try Data(contentsOf: escrowURL)
        )
        #expect(escrow.runtimeId == harness.appDelegate.appIPCRuntimeID)
        #expect(escrow.socketPath == harness.socketPath)
        #expect(!escrow.token.isEmpty)
        #expect(try mode(for: escrowURL) & 0o777 == 0o600)

        #expect(try await loginSucceeds(socketPath: harness.socketPath, token: escrow.token))

        await harness.tearDown()

        #expect(!FileManager.default.fileExists(atPath: escrowURL.path))
        await #expect(throws: (any Error).self) {
            _ = try await loginSucceeds(socketPath: harness.socketPath, token: escrow.token)
        }
    }

    @Test("a debug app without an escrow path writes no credential file")
    func debugServerWithoutEscrowPathPublishesNothing() async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            #expect(harness.appDelegate.appIPCDebugCredentialEscrowURL == nil)
            let ipcDirectoryEntries = try FileManager.default.contentsOfDirectory(
                atPath: harness.appDelegate.appIPCPaths.ipcDirectory.path
            )
            #expect(
                ipcDirectoryEntries.allSatisfy {
                    ["agentstudio.sock", "runtime.json", "spool", "cli.sqlite", "cli.sqlite-wal", "cli.sqlite-shm"]
                        .contains($0)
                }
            )
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    private func loginSucceeds(socketPath: String, token: String) async throws -> Bool {
        let connection = try await withoutBlockingCooperativePool {
            try UnixSocketClient.connect(endpoint: UnixSocketEndpoint(path: socketPath))
        }
        defer { connection.close() }
        var reader = SessionsVerticalFrameReader()
        try await withoutBlockingCooperativePool {
            try connection.send(
                try NDJSONFrameEncoder.encode(
                    JSONRPCCodec.encodeRequest(
                        try JSONRPCClientRequest(
                            id: .number(1),
                            method: "auth.login",
                            params: .object(["token": .string(token)])
                        )
                    ),
                    maxFrameBytes: 65_536
                )
            )
        }
        let response = try await reader.receiveResponse(connection: connection)
        guard response.error == nil else {
            throw AppIPCDebugCredentialEscrowTestError.loginRejected
        }
        return true
    }

    private func mode(for url: URL) throws -> mode_t {
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else { throw POSIXError(.ENOENT) }
        return statBuffer.st_mode
    }
}

private enum AppIPCDebugCredentialEscrowTestError: Error {
    case loginRejected
}

private struct OldShellWriteOutcome: Sendable {
    let exitCode: Int32
    let standardError: String
}
