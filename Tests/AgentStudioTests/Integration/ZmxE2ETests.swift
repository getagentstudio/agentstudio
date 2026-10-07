import AgentStudioInfrastructure
import Darwin
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

/// End-to-end tests that exercise the full zmx daemon lifecycle against a real zmx binary.
///
/// These tests spawn actual zmx daemons using `/bin/sh` to provide a process wrapper,
/// then exercise healthCheck, discoverOrphanSessions, and destroyPaneSession
/// against live processes.
///
/// Requires zmx to be installed on PATH. Tests are skipped when zmx is unavailable.
extension E2ESerializedTests {
    @Suite(.serialized)
    struct ZmxE2ETests {
        @Test(
            "pending cleanup recovers from a reopened database and preserves a replacement", arguments: [false, true])
        func pendingCleanupRecoversAfterProcessExit(withReplacement: Bool) async throws {
            try await withRealBackend { harness, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                let zmxPath = try #require(harness.zmxPath)
                let databaseURL = URL(fileURLWithPath: harness.zmxDir).appendingPathComponent("proof.sqlite")
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath, sessionId: sessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))
                let evidence = try await waitForObservedSessionIdentity(sessionID, backend: backend)
                do {
                    let database = try SQLiteDatabaseFactory.makeFileBackedPool(at: databaseURL)
                    try WorkspaceCoreMigrations.migrate(database)
                    try await database.write { connection in
                        try connection.execute(
                            sql: """
                                INSERT INTO workspace_terminal_session_ownership(
                                    session_id, cleanup_state, cleanup_requested_at, process_identity)
                                VALUES (?, 'pending', 100, ?)
                                """, arguments: [sessionID.rawValue, evidence])
                    }
                    // Deliberately omit completion persistence, as if shutdown interrupted
                    // the application after its external effect but before its final write.
                    _ = try await backend.retireVerifiedSession(sessionID, expectedIdentity: evidence)
                    try database.close()
                }
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: false))
                let datastore = try await reopenedCleanupDatastore(at: databaseURL)
                let pending = try await datastore.terminalSessionCleanupBatch(after: nil)
                try #require(pending.count == 1)
                guard case .retire(let recoveredSessionID, let recoveredEvidence) = pending[0] else {
                    Issue.record("Reopened journal must retain pending process evidence")
                    return
                }
                #expect(recoveredSessionID == sessionID)
                #expect(recoveredEvidence == evidence)
                var replacementEvidence: Data?
                if withReplacement {
                    _ = try await harness.spawnZmxSession(
                        zmxPath: zmxPath, sessionId: sessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
                    try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))
                    replacementEvidence = try await waitForObservedSessionIdentity(sessionID, backend: backend)
                    #expect(replacementEvidence != evidence)
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var completed = false
                while ContinuousClock.now < deadline {
                    do {
                        completed =
                            try await datastore.retirePendingTerminalSession(
                                sessionID: recoveredSessionID, identity: recoveredEvidence
                            ) {
                                try await backend.retireVerifiedSession(sessionID, expectedIdentity: recoveredEvidence)
                            } == .completed
                        if completed { break }
                    } catch is ZmxSessionControlFailure {
                        // A replaced endpoint is never signalled; old process reaping may still be in flight.
                    }
                    await Task.yield()
                }
                #expect(completed)
                #expect(try await datastore.terminalSessionCleanupBatch(after: nil).isEmpty)
                if let replacementEvidence {
                    #expect(try await backend.observeSessionIdentity(sessionID) == replacementEvidence)
                    #expect(await backend.sessionExists(.init(id: sessionID)))
                }
            }
        }

        @Test("verified extinct processes complete despite an untouched stale socket")
        func extinctProcessesCompleteWithStaleSocket() async throws {
            try await withRealBackend { harness, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                let zmxPath = try #require(harness.zmxPath)
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath, sessionId: sessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))
                let evidence = try await waitForObservedSessionIdentity(sessionID, backend: backend)
                _ = try await backend.retireVerifiedSession(sessionID, expectedIdentity: evidence)
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: false))
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var extinct = false
                while ContinuousClock.now < deadline {
                    do {
                        extinct =
                            try await backend.retireVerifiedSession(sessionID, expectedIdentity: evidence) == .completed
                        if extinct { break }
                    } catch is ZmxSessionControlFailure {
                        // Normal shutdown can still be reaping the recorded original processes.
                    }
                    await Task.yield()
                }
                try #require(extinct)
                let socketPath = "\(harness.zmxDir)/\(sessionID.rawValue)"
                let staleSocketIdentity = try makeStaleCleanupSocket(at: socketPath)
                defer {
                    removeOwnedStaleCleanupSocket(
                        at: socketPath,
                        expectedIdentity: staleSocketIdentity
                    )
                }
                let databaseURL = URL(fileURLWithPath: harness.zmxDir).appendingPathComponent("stale-socket.sqlite")
                do {
                    let database = try SQLiteDatabaseFactory.makeFileBackedPool(at: databaseURL)
                    try WorkspaceCoreMigrations.migrate(database)
                    try await database.write { connection in
                        try connection.execute(
                            sql: """
                                INSERT INTO workspace_terminal_session_ownership(
                                    session_id, cleanup_state, cleanup_requested_at, process_identity)
                                VALUES (?, 'pending', 100, ?)
                                """, arguments: [sessionID.rawValue, evidence])
                    }
                    try database.close()
                }
                let datastore = try await reopenedCleanupDatastore(at: databaseURL)
                let result = try await datastore.retirePendingTerminalSession(sessionID: sessionID, identity: evidence)
                {
                    try await backend.retireVerifiedSession(sessionID, expectedIdentity: evidence)
                }
                #expect(result == .completed)
                #expect(try await datastore.terminalSessionCleanupBatch(after: nil).isEmpty)
                var remainingSocket = stat()
                #expect(lstat(socketPath, &remainingSocket) == 0)
                #expect(remainingSocket.st_ino == staleSocketIdentity.inode)
                #expect(remainingSocket.st_dev == staleSocketIdentity.device)
                #expect(remainingSocket.st_mode & S_IFMT == staleSocketIdentity.fileType)
            }
        }

        private func waitForObservedSessionIdentity(_ sessionID: ZmxSessionID, backend: ZmxBackend) async throws -> Data
        {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                do {
                    if let identity = try await backend.observeSessionIdentity(sessionID) { return identity }
                } catch ZmxSessionControlFailure.unavailable {
                    // Socket creation precedes the daemon accepting control requests.
                } catch ZmxSessionControlFailure.connectionRefused {
                    // Amended 2026-09-30: zmx binds the socket's path
                    // before it calls listen, so a connect landing in that
                    // gap is refused the same way an unavailable endpoint
                    // is here.
                } catch ZmxSessionControlFailure.processUnverifiable {
                    // The daemon/terminal fork may still be settling.
                } catch ZmxSessionControlFailure.timeout {
                    // A busy startup may not answer within one bounded request.
                }
                await Task.yield()
            }
            throw ZmxSessionControlFailure.timeout
        }

        /// The fallback `TerminalColdRestorePlan` S4b ("option A") now
        /// carries on every `.warm`/`.unverified` restore kind
        /// (`TerminalRestoreKindResolver.buildColdPlan`'s shape), built
        /// directly here since these E2E tests spawn a real session outside
        /// the resolver's own classification flow.
        private func makeStaleCleanupSocket(at path: String) throws -> StaleCleanupSocketIdentity {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(descriptor) }
            var address = sockaddr_un()
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw POSIXError(.EIO) }
            var information = stat()
            guard lstat(path, &information) == 0 else { throw POSIXError(.EIO) }
            return StaleCleanupSocketIdentity(
                device: information.st_dev,
                inode: information.st_ino,
                fileType: information.st_mode & S_IFMT
            )
        }

        private func removeOwnedStaleCleanupSocket(
            at path: String,
            expectedIdentity: StaleCleanupSocketIdentity
        ) {
            var currentIdentity = stat()
            guard lstat(path, &currentIdentity) == 0 else {
                Issue.record("owned stale cleanup socket disappeared before fixture teardown: \(path)")
                return
            }
            guard currentIdentity.st_dev == expectedIdentity.device,
                currentIdentity.st_ino == expectedIdentity.inode,
                currentIdentity.st_mode & S_IFMT == expectedIdentity.fileType
            else {
                Issue.record("refusing to remove a replacement at the stale cleanup socket path: \(path)")
                return
            }
            guard unlink(path) == 0 else {
                Issue.record("failed to remove owned stale cleanup socket at \(path): errno \(errno)")
                return
            }
        }

        @MainActor
        private func reopenedCleanupDatastore(at databaseURL: URL) throws -> WorkspaceSQLiteDatastoreActor {
            let database = try SQLiteDatabaseFactory.makeFileBackedPool(at: databaseURL)
            let repository = WorkspaceCoreRepository(databaseWriter: database)
            let localDatabase = try SQLiteDatabaseFactory.makeInMemoryQueue()
            try WorkspaceLocalMigrations.migrate(localDatabase)
            return try preparedWorkspaceSQLiteDatastore(
                from: WorkspaceSQLiteStoreBackend(
                    coreRepository: repository,
                    makeLocalRepository: { WorkspaceLocalRepository(workspaceId: $0, databaseWriter: localDatabase) },
                    coreDatabaseStartupProvenance: .createdDuringCurrentStartup))
        }

        @Test("inspection failures are not reported as absence", arguments: [false, true])
        func inspectionFailureIsNotAbsence(permissionDenied: Bool) async throws {
            try await withRealBackend { harness, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                defer {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: harness.zmxDir)
                }
                if permissionDenied {
                    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: harness.zmxDir)
                } else {
                    try Data().write(to: URL(fileURLWithPath: "\(harness.zmxDir)/\(sessionID.rawValue)"))
                }
                await #expect(throws: ZmxSessionControlFailure.unavailable) {
                    try await backend.observeSessionIdentity(sessionID)
                }
            }
        }

        @Test("an already absent session needs no kill", arguments: [false, true])
        func absentSessionNeedsNoKill(wasRunning: Bool) async throws {
            try await withRealBackend { harness, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                if wasRunning {
                    _ = try await harness.spawnZmxSession(
                        zmxPath: try #require(harness.zmxPath), sessionId: sessionID.rawValue,
                        commandArgs: ["/bin/sleep", "300"])
                    try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))
                    try await backend.destroySessionByID(sessionID)
                    try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: false))
                }
                let evidence: Data? = try await backend.observeSessionIdentity(sessionID)
                #expect(evidence == nil)
            }
        }

        @Test("observed identity addresses one real daemon and rejects a mismatched cleanup")
        func observedIdentityProtectsTheRunningSession() async throws {
            try await withRealBackend { harness, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                _ = try await harness.spawnZmxSession(
                    zmxPath: try #require(harness.zmxPath), sessionId: sessionID.rawValue,
                    commandArgs: ["/bin/sleep", "300"])
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))

                let encoded = try await waitForObservedSessionIdentity(sessionID, backend: backend)
                let identity = try ZmxSessionIdentity.decode(encoded)
                #expect(identity.daemon.pid != identity.terminalLeader.pid)
                #expect(identity.processGroupID == identity.terminalLeader.pid)
                let mismatch = ZmxSessionIdentity(
                    version: identity.version, bootID: identity.bootID, daemon: identity.daemon,
                    terminalLeader: identity.terminalLeader, processGroupID: identity.processGroupID,
                    sessionCreatedAt: identity.sessionCreatedAt + 1)
                await #expect(throws: ZmxSessionControlFailure.identityMismatch) {
                    try await backend.retireVerifiedSession(sessionID, expectedIdentity: mismatch.encoded())
                }
                #expect(await backend.sessionExists(.init(id: sessionID)))
            }
        }

        @Test("verified cleanup ends the exact real session and reconciles a repeated attempt")
        func verifiedCleanupEndsTheOriginalSession() async throws {
            try await withRealBackend { harness, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                _ = try await harness.spawnZmxSession(
                    zmxPath: try #require(harness.zmxPath), sessionId: sessionID.rawValue,
                    commandArgs: ["/bin/sleep", "300"])
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))
                let identity = try await waitForObservedSessionIdentity(sessionID, backend: backend)

                _ = try await backend.retireVerifiedSession(sessionID, expectedIdentity: identity)
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: false))
                // Socket removal precedes final process reaping. Wait for the stronger
                // completion observation, rather than treating unlink as termination.
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var completed = false
                while ContinuousClock.now < deadline {
                    do {
                        completed =
                            try await backend.retireVerifiedSession(sessionID, expectedIdentity: identity) == .completed
                        if completed { break }
                    } catch ZmxSessionControlFailure.processUnverifiable {
                        // Kernel inspection can race final process reaping.
                    } catch ZmxSessionControlFailure.unavailable {
                        // The endpoint can disappear between inspection and connection.
                    } catch ZmxSessionControlFailure.connectionRefused {
                        // Amended 2026-09-30: a replacement daemon's socket
                        // can bind before it listens, refusing a connect
                        // landing in that gap the same way.
                    }
                    await Task.yield()
                }
                #expect(completed, "Original processes and process group must exit, not just remove their socket")
            }
        }

        @Test("full lifecycle create healthCheck kill verify")
        func test_fullLifecycle_create_healthCheck_kill_verify() async throws {
            try await withRealBackend { harness, backend in
                // Arrange — create a handle
                let handle = try await backend.createPaneSession(sessionID: .generateUUIDv7())
                let zmxPath = try #require(harness.zmxPath, "Expected zmx path to be available")

                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath,
                    sessionId: handle.id.rawValue,
                    commandArgs: ["/bin/sleep", "300"]
                )

                let appeared = try await harness.waitForSessionSocket(
                    sessionId: handle.id.rawValue,
                    exists: true
                )
                #expect(appeared, "zmx daemon should start within timeout")

                // Assert 1 — healthCheck sees the session
                #expect(
                    await backend.healthCheck(handle),
                    "healthCheck should return true for a live zmx session"
                )

                // Assert 2 — discoverOrphanSessions finds it (not in known set)
                let orphans = await backend.discoverOrphanSessions(excluding: [])
                #expect(
                    orphans.contains(handle.id),
                    "discoverOrphanSessions should find the session when not in the known set"
                )

                // Assert 3 — discoverOrphanSessions excludes it when known
                let orphansExcluded = await backend.discoverOrphanSessions(excluding: [handle.id])
                #expect(
                    !orphansExcluded.contains(handle.id),
                    "discoverOrphanSessions should exclude the session when in the known set"
                )

                // Act 2 — kill the session
                try await backend.destroyPaneSession(handle)

                let disappeared = try await harness.waitForSessionSocket(
                    sessionId: handle.id.rawValue,
                    exists: false
                )
                #expect(disappeared, "Session should disappear from zmx list after kill")

                // Assert 4 — healthCheck returns false after kill
                #expect(
                    await backend.healthCheck(handle) == false,
                    "healthCheck should return false after session is killed"
                )
            }
        }

        // MARK: - Orphan Discovery E2E

        @Test("orphan discovery finds untracked session")
        func test_orphanDiscovery_findsUntrackedSession() async throws {
            try await withRealBackend { harness, backend in
                // Arrange — spawn two sessions, only one is "known"
                let zmxPath = try #require(harness.zmxPath, "Expected zmx path to be available")

                let handle1 = try await backend.createPaneSession(sessionID: .generateUUIDv7())
                let handle2 = try await backend.createPaneSession(sessionID: .generateUUIDv7())
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath,
                    sessionId: handle1.id.rawValue,
                    commandArgs: ["/bin/sleep", "300"]
                )
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath,
                    sessionId: handle2.id.rawValue,
                    commandArgs: ["/bin/sleep", "300"]
                )

                // Wait for both daemons
                let appeared1 = try await harness.waitForSessionSocket(
                    sessionId: handle1.id.rawValue,
                    exists: true
                )
                let appeared2 = try await harness.waitForSessionSocket(
                    sessionId: handle2.id.rawValue,
                    exists: true
                )
                #expect(appeared1, "zmx daemon 1 should start within timeout")
                #expect(appeared2, "zmx daemon 2 should start within timeout")

                // Act — discover orphans, treating handle1 as "known"
                let orphans = await backend.discoverOrphanSessions(excluding: [handle1.id])

                // Assert
                #expect(orphans.contains(handle2.id), "handle2 should be discovered as orphan")
                #expect(!orphans.contains(handle1.id), "handle1 should be excluded (known)")
            }
        }

        // MARK: - Destroy By ID E2E

        @Test("destroy session by id kills live session")
        func test_destroySessionById_killsLiveSession() async throws {
            try await withRealBackend { harness, backend in
                // Arrange
                let handle = try await backend.createPaneSession(sessionID: .generateUUIDv7())
                let zmxPath = try #require(harness.zmxPath, "Expected zmx path to be available")

                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath,
                    sessionId: handle.id.rawValue,
                    commandArgs: ["/bin/sleep", "300"]
                )

                let appeared = try await harness.waitForSessionSocket(
                    sessionId: handle.id.rawValue,
                    exists: true
                )
                #expect(appeared, "zmx daemon should start before destroy")

                // Act
                try await backend.destroySessionByID(handle.id)

                // Assert
                let gone = try await harness.waitForSessionSocket(
                    sessionId: handle.id.rawValue,
                    exists: false
                )
                #expect(gone, "Session should be gone after destroySessionById")
            }
        }

        // MARK: - Restore Semantics E2E

        @Test("restore across backend recreation detects and kills existing session")
        func test_restoreAcrossBackendRecreation_detectsAndKillsExistingSession() async throws {
            try await withRealBackend { harness, backend in
                // Arrange — create a session and spawn a live daemon
                let handle = try await backend.createPaneSession(sessionID: .generateUUIDv7())
                let zmxPath = try #require(harness.zmxPath, "Expected zmx path to be available")

                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath,
                    sessionId: handle.id.rawValue,
                    commandArgs: ["/bin/sleep", "300"]
                )

                let appeared = try await harness.waitForSessionSocket(
                    sessionId: handle.id.rawValue,
                    exists: true
                )
                #expect(appeared, "zmx daemon should start before recreation checks")

                // Act — simulate app restart by creating a new backend instance.
                let recreatedBackend = try #require(
                    harness.createBackend(),
                    "Expected recreated backend for restore semantics test"
                )

                // Assert — recreated backend can still discover and control the existing session.
                #expect(
                    await recreatedBackend.healthCheck(handle),
                    "Recreated backend should detect live session (restore semantics)"
                )

                try await recreatedBackend.destroySessionByID(handle.id)
                let gone = try await harness.waitForSessionSocket(
                    sessionId: handle.id.rawValue,
                    exists: false
                )
                #expect(gone, "Session should be gone after kill from recreated backend")
            }
        }

        /// S3 (Program Design item 3, revision 11's argument-vector witness):
        /// a real cold-restore attach command -- built by the exact
        /// production path, `ZmxBackend.buildColdRestoreCommand` -- hands
        /// off once its script's only in-process exec replaces it. Driven
        /// end to end through the real `ColdStartObserver`, so this doesn't
        /// hand-roll a second, potentially racy argument-vector read
        /// alongside the observer's own register-then-check logic --
        /// `.handedOff` is only reachable when the observer itself saw the
        /// token gone from a live leader whose pid and start time still
        /// match what stage 1 discovered.
        ///
        /// Asserts `.handedOff` strictly (amended 2026-09-30, twice). Two
        /// real races were found and fixed against this exact test, both by
        /// diagnosing against real zmx first, never by loosening this
        /// assertion:
        /// - `.unobservable(.processArgsUnreadable)`: `DarwinColdStartObserverSyscalls`'
        ///   two-`sysctl`-call TOCTOU, fixed by a single sized read with an
        ///   immediate retry budget (`AppPolicies.Restore
        ///   .processArgumentsReadAttempts`) -- see `ColdStartObserverSyscalls.swift`.
        /// - `.unobservable(.identityUnverifiable)`: zmx binds the session
        ///   socket's filesystem path before it calls `listen`
        ///   (socket.zig:113-114), so a stage-1 connect landing in that gap
        ///   was refused and settled unobservable immediately. Fixed by
        ///   `ZmxSessionControlFailure.connectionRefused` retrying on
        ///   `AppPolicies.Restore.discoveryConnectRetryDelays`'s backoff,
        ///   staying discovering rather than settling on the timing alone
        ///   -- see `ColdStartObserver.attemptDiscoveryConnect`.
        ///
        /// Spawns before observing, deliberately: `async let` gives no
        /// guarantee stage 1's directory watch actually registers before
        /// the next line runs (an early draft raced there and flaked under
        /// load). A cold-restore session stays alive once its script execs
        /// into the final shell -- the daemon and socket persist -- so
        /// stage 1's register-then-check logic finds the already-existing
        /// socket regardless of exactly when it runs; production still
        /// registers before creating the surface for the *fast-exit* case,
        /// which is a separate proof (S3's zmx-e2e list), not this one.
        @Test("a real cold-restore attach hands off once its script execs into the final shell")
        func coldRestoreAttachHandsOffOnceItsScriptExecsIntoTheFinalShell() async throws {
            try await withRealBackend { harness, _ in
                let zmxPath = try #require(harness.zmxPath)
                let sessionID = ZmxSessionID.generateUUIDv7()
                let attemptID = ColdRestoreAttemptID.generate()
                let plan = TerminalColdRestorePlan(
                    zmxExecutable: URL(fileURLWithPath: zmxPath),
                    zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                    sessionID: sessionID,
                    // coldRestoreScript unconditionally appends "-i -l" to
                    // whatever loginShell is given -- those are interactive-
                    // login flags a real shell understands, not generic
                    // arguments (/bin/cat rejected them as illegal options
                    // and exited immediately, which was this test's first,
                    // flaky draft). /bin/bash -i -l blocks reading stdin at
                    // an interactive prompt, exactly like a real restore.
                    loginShell: URL(fileURLWithPath: "/bin/bash"),
                    folderCandidates: [URL(fileURLWithPath: "/tmp")],
                    notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
                    replayFile: nil,
                    resume: nil,
                    attemptID: attemptID
                )
                let bootID = try await WorkspaceUndoJournalClock.current().bootID
                let socketPath = "\(harness.zmxDir)/\(sessionID.rawValue)"
                let observer = ColdStartObserver()

                _ = try await harness.spawnColdRestoreSession(plan: plan)
                let settledOutcome = await observer.observeColdStart(
                    zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                    socketPath: socketPath,
                    bootID: bootID,
                    attemptID: attemptID
                )
                #expect(settledOutcome == .handedOff)
            }
        }

        /// S3 zmx-e2e list: a socket that's never created because the
        /// attach client itself never reaches zmx (`zmxExecutable` points
        /// nowhere real, so `/bin/sh` fails with "command not found" before
        /// ever invoking zmx) settles `.failed` on the client's own real
        /// exit -- discovery never even gets a socket to watch for.
        @Test("a socket never created and the attach client exiting settles failed")
        func aSocketNeverCreatedAndTheAttachClientExitingSettlesFailed() async throws {
            try await withRealBackend { harness, _ in
                let sessionID = ZmxSessionID.generateUUIDv7()
                let attemptID = ColdRestoreAttemptID.generate()
                let plan = TerminalColdRestorePlan(
                    zmxExecutable: URL(fileURLWithPath: "/does/not/exist/zmx"),
                    zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                    sessionID: sessionID,
                    loginShell: URL(fileURLWithPath: "/bin/bash"),
                    folderCandidates: [URL(fileURLWithPath: "/tmp")],
                    notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
                    replayFile: nil,
                    resume: nil,
                    attemptID: attemptID
                )
                let bootID = try await WorkspaceUndoJournalClock.current().bootID
                let socketPath = "\(harness.zmxDir)/\(sessionID.rawValue)"
                let observer = ColdStartObserver()

                // The bogus zmxExecutable means no socket, and no setsid,
                // ever exists to wait for -- the default, settlement-waiting
                // spawnColdRestoreSession would just time out on the socket
                // wait instead of exercising this test's own intent.
                let (process, _) = try harness.spawnColdRestoreSessionWithoutWaitingForSettlement(plan: plan)
                _ = try await awaitAlreadyRunningProcessExit(process)
                #expect(process.terminationStatus != 0, "the missing zmxExecutable must genuinely fail to run")
                await observer.reportAttachClientExited()

                let outcome = await observer.observeColdStart(
                    zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                    socketPath: socketPath,
                    bootID: bootID,
                    attemptID: attemptID
                )

                #expect(outcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
            }
        }

        /// S3 zmx-e2e list: the script's only in-process exec targets a
        /// non-executable `loginShell` -- coldRestoreScript's `exec
        /// '<loginShell>' -i -l` fails, and a POSIX shell whose last
        /// statement is a failed `exec` terminates rather than continuing,
        /// so the real leader genuinely exits. Proves NOTE_EXIT explains an
        /// otherwise-unreadable argv correctly (`handoffChecked`'s
        /// `.unreadable` branch), not `.unobservable`.
        ///
        /// Gate 5 fix (Lead 2026-10-02): the waiting `spawnColdRestoreSession`
        /// cannot be used here -- it settles through this same
        /// `ColdStartObserver` discovery/setsid/handoff chain internally
        /// (`waitUntilSessionSettled` -> `resolveSettledDiscovery`), and
        /// this test's own leader is designed to die before that chain ever
        /// reaches a stable identity to settle on; F7's removed retry used
        /// to paper over that precondition failure. Spawns without waiting
        /// instead (the same `spawnColdRestoreSessionWithoutWaitingForSettlement`
        /// the test above this one uses) and lets `observeColdStart` itself
        /// observe from before the socket exists -- the real production
        /// path. No created-line wait needed first: unlike the test above
        /// (no real zmx session at all, so nothing internal to the observer
        /// would ever learn of that attach client's exit without the
        /// explicit `reportAttachClientExited()` signal it uses), zmx here
        /// is real, so discovery's own direct `observeSession` call can
        /// read `.terminalLeaderGone` and settle `.failed` immediately
        /// (`attemptDiscoveryConnect`'s own case, ColdStartObserver.swift:324-331),
        /// or read `.pendingSetsid` and have the subsequent setsid watch's
        /// own `NOTE_EXIT` settle the same way (`checkForSetsidAndAdvance`'s
        /// `exitFired` branch) -- confirmed by reading both directly. Every
        /// timing of the real exec failure relative to this call converges
        /// on the same outcome through the observer's own watches, with
        /// nothing external to wait for first.
        @Test("a non-executable final shell settles failed, not unobservable")
        func aNonExecutableFinalShellSettlesFailed() async throws {
            try await withRealBackend { harness, _ in
                let zmxPath = try #require(harness.zmxPath)
                let sessionID = ZmxSessionID.generateUUIDv7()
                let attemptID = ColdRestoreAttemptID.generate()
                // A real, non-executable file: exec must fail with ENOEXEC/EACCES,
                // not "no such file" -- proving the script actually attempted
                // the final exec rather than failing earlier at resolution.
                let nonExecutablePath = FileManager.default.temporaryDirectory
                    .appending(path: "non-executable-login-shell-\(UUIDv7.generate().uuidString)")
                try "not a script".write(to: nonExecutablePath, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: nonExecutablePath) }
                let plan = TerminalColdRestorePlan(
                    zmxExecutable: URL(fileURLWithPath: zmxPath),
                    zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                    sessionID: sessionID,
                    loginShell: nonExecutablePath,
                    folderCandidates: [URL(fileURLWithPath: "/tmp")],
                    notice: ColdRestoreNotice(linesByCandidateIndex: ["Restored after restart"]),
                    replayFile: nil,
                    resume: nil,
                    attemptID: attemptID
                )
                let bootID = try await WorkspaceUndoJournalClock.current().bootID
                let socketPath = "\(harness.zmxDir)/\(sessionID.rawValue)"
                let observer = ColdStartObserver()

                _ = try harness.spawnColdRestoreSessionWithoutWaitingForSettlement(plan: plan)
                let outcome = await observer.observeColdStart(
                    zmxDirectory: URL(fileURLWithPath: harness.zmxDir),
                    socketPath: socketPath,
                    bootID: bootID,
                    attemptID: attemptID
                )

                #expect(outcome == .failed(.exitedBeforeHandoff(exitStatus: nil)))
            }
        }

        /// S4 (Program Design item 5): the post-attach recreation check's
        /// three outcomes against a real daemon -- `PaneRecreationChecker`
        /// itself is pure and already unit-tested; this proves the real
        /// `observeSessionIdentity` calls it's compared against actually
        /// behave the way S4's proof list assumes.
        @Test("a warm daemon replaced under the same name between check and attach compares as recreated")
        func warmDaemonReplacedUnderTheSameNameComparesAsRecreated() async throws {
            try await withRealBackend { harness, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                let zmxPath = try #require(harness.zmxPath)
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath, sessionId: sessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))
                let baselineIdentity = try await awaitSessionIdentityOnRealEvent(
                    sessionID, harness: harness, backend: backend, zmxDirectory: harness.zmxDir)

                // Simulate app restart replacing the daemon under the exact
                // same session id, including within the same second.
                try await backend.destroySessionByID(sessionID)
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: false))
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath, sessionId: sessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))
                let replacementIdentity = try await awaitSessionIdentityOnRealEvent(
                    sessionID, harness: harness, backend: backend, zmxDirectory: harness.zmxDir)

                #expect(replacementIdentity != baselineIdentity)
                let result = PaneRecreationChecker.checkForRecreation(
                    baselineIdentity: baselineIdentity, observedIdentity: replacementIdentity)
                #expect(result == .recreated)
            }
        }

        @Test("observing a session with no socket reports couldNotCheck, never recreated on a mere absence of proof")
        func observingASessionWithNoSocketReportsCouldNotCheck() async throws {
            try await withRealBackend { _, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                let baselineIdentity = Data([1, 2, 3])
                let observedIdentity = try await backend.observeSessionIdentity(sessionID)

                #expect(observedIdentity == nil)
                let result = PaneRecreationChecker.checkForRecreation(
                    baselineIdentity: baselineIdentity, observedIdentity: observedIdentity)
                #expect(result == .couldNotCheck)
            }
        }

        @Test("a live, unchanged session compares as unchanged")
        func aLiveUnchangedSessionComparesAsUnchanged() async throws {
            try await withRealBackend { harness, backend in
                let sessionID = ZmxSessionID.generateUUIDv7()
                let zmxPath = try #require(harness.zmxPath)
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath, sessionId: sessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
                try #require(await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true))
                let baselineIdentity = try await awaitSessionIdentityOnRealEvent(
                    sessionID, harness: harness, backend: backend, zmxDirectory: harness.zmxDir)

                // The same still-live daemon, observed again after the
                // attach settles -- no replacement in between.
                let postAttachIdentity = try await backend.observeSessionIdentity(sessionID)

                let result = PaneRecreationChecker.checkForRecreation(
                    baselineIdentity: baselineIdentity, observedIdentity: postAttachIdentity)
                #expect(result == .unchanged)
            }
        }

        // MARK: - Helpers

        /// Run backend setup and guaranteed cleanup for each zmx E2E case.
        /// Not `private`: shared with `ZmxE2ETests+ForcedTiming.swift`, an
        /// extension of this same struct in a separate file.
        func withRealBackend(
            _ test: @escaping @Sendable (ZmxTestHarness, ZmxBackend) async throws -> Void
        ) async throws {
            let harness = await ZmxTestHarness()
            let backend = try #require(
                harness.createBackend(),
                "ZmxTestHarness failed to resolve zmx path; integration test requires zmx"
            )
            try #require(await backend.isAvailable, "zmx is unavailable in this environment")

            try FileManager.default.createDirectory(
                atPath: harness.zmxDir,
                withIntermediateDirectories: true,
                attributes: nil
            )

            var bodyError: (any Error)?
            do {
                try await test(harness, backend)
            } catch {
                bodyError = error
            }
            let cleanupOutcome = await harness.cleanup()
            if let bodyError {
                if !cleanupOutcome.succeeded {
                    Issue.record("zmx cleanup also failed: \(cleanupOutcome.diagnostics)")
                }
                throw bodyError
            }
            if !cleanupOutcome.succeeded {
                throw ZmxTestHarness.CleanupError(outcome: cleanupOutcome)
            }
        }
    }
}

private struct StaleCleanupSocketIdentity {
    let device: dev_t
    let inode: ino_t
    let fileType: mode_t
}
