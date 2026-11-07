import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

extension E2ESerializedTests.ZmxE2ETests {
    @Test(
        "an archived unversioned daemon is preserved until explicit stop and cold replay",
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_ZMX_LEGACY_FIXTURE"] != nil)
    )
    func archivedDaemonRestartsWithSavedScrollback() async throws {
        try await withRealBackend { harness, backend in
            let archivedPath = try #require(ProcessInfo.processInfo.environment["AGENTSTUDIO_ZMX_LEGACY_FIXTURE"])
            let currentPath = try #require(harness.zmxPath)
            let sessionID = ZmxSessionID.generateUUIDv7()
            let marker = "legacy-ready-\(UUIDv7.generate().uuidString)"
            // The archived native CLI owns fixture creation. Completed shell output is the readiness fact;
            // an initial attach viewport can omit output written before that first client connects.
            let creation = try await RunToExitProcessExecutor().execute(
                command: archivedPath, args: ["run", sessionID.rawValue, "/bin/echo", marker], cwd: nil,
                environment: ZmxTestHarness.hermeticChildEnvironment(
                    zmxDir: harness.zmxDir, scratchHomeDirectory: harness.scratchHomeDirectory))
            try #require(creation.succeeded, Comment(rawValue: creation.stderr))
            #expect(creation.stdout.contains(marker))
            let socketPath = harness.sessionSocketPath(for: sessionID.rawValue)
            let legacyDaemon = try ZmxIncompatibleSessionStop.verifiedDaemon(path: socketPath)
            let database = try SQLiteDatabaseFactory.makeInMemoryQueue(label: "legacy-protocol-restart")
            try WorkspaceCoreMigrations.migrator.migrate(database, upTo: "018_repository_location_absence")
            try await database.write {
                try $0.execute(
                    sql: "INSERT INTO workspace_terminal_session_ownership(session_id) VALUES (?)",
                    arguments: [sessionID.rawValue])
            }
            try WorkspaceCoreMigrations.migrate(database)
            let repository = WorkspaceCoreRepository(databaseWriter: database)
            let pane = Pane(
                content: .terminal(.init(provider: .zmx, lifetime: .persistent, zmxSessionID: sessionID)),
                metadata: PaneMetadata(launchDirectory: URL(filePath: "/tmp"), title: "Archived session"))
            let scrollback = ScrollbackStore(
                directoryURL: URL(fileURLWithPath: harness.scratchHomeDirectory).appending(path: "saved"))
            let savedText = "saved-before-upgrade-\(UUIDv7.generate().uuidString)"
            #expect(
                try await scrollback.store(
                    paneId: PaneId(existingUUID: pane.id), capture: Data("\(savedText)\r\n".utf8)) == .written)
            let configuration = SessionConfiguration(
                isEnabled: true, zmxPath: currentPath, zmxDir: harness.zmxDir,
                healthCheckInterval: 30, maxCheckpointAge: 3600)
            let resolver = TerminalRestoreKindResolver(
                sessionConfiguration: configuration, probe: backend, scrollbackStore: scrollback,
                repositoryMainFolder: { _ in nil },
                recordedProtocol: { try repository.terminalSessionProtocolVersion($0) },
                recordProtocol: { try repository.recordTerminalSessionProtocolVersion($0, version: $1) })
            let kinds = await resolver.resolveRestoreKinds(for: [
                .init(pane: pane, visibilityPriority: .activeVisible, hostPlacement: .tab(tabID: UUIDv7.generate()))
            ])
            let kind = try #require(kinds[PaneId(existingUUID: pane.id)])
            guard case .incompatible(let version, let fallback) = kind else {
                Issue.record("archived daemon must be incompatible, not attached")
                return
            }
            #expect(version == 0)
            #expect(
                await TerminalRestoreRuntime(sessionConfiguration: configuration).startupCommand(for: pane, kind: kind)
                    == nil)
            #expect(ZmxSessionControl.currentIncarnation(forPID: legacyDaemon.pid) == legacyDaemon)
            #expect(try repository.terminalSessionProtocolVersion(sessionID) == nil)

            // Explicit restart operation: real stop, real cold command/replay, real ownership update.
            try await ZmxIncompatibleSessionStop.stop(sessionID: sessionID, directory: harness.zmxDir)
            #expect(ZmxSessionControl.currentIncarnation(forPID: legacyDaemon.pid) == nil)
            try repository.recordTerminalSessionProtocolVersion(sessionID, version: ZmxProtocol.version)
            _ = try await harness.spawnColdRestoreSession(plan: fallback)
            let observer = ColdStartObserver()
            let outcome = await observer.observeColdStart(
                zmxDirectory: URL(fileURLWithPath: harness.zmxDir), socketPath: socketPath,
                bootID: try await WorkspaceUndoJournalClock.current().bootID, attemptID: fallback.attemptID)
            #expect(outcome == .handedOff)
            let history = try await harness.sessionHistory(sessionId: sessionID.rawValue)
            #expect(history.contains(savedText))
            #expect(history.contains("restored after restart"))
            #expect(try repository.terminalSessionProtocolVersion(sessionID) == 1)
            let currentIdentity = try #require(try await backend.observeSessionIdentity(sessionID))
            #expect(try ZmxSessionIdentity.decode(currentIdentity).daemon != legacyDaemon)
        }
    }
}
