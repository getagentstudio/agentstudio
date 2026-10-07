import Darwin
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

/// SR1, SR2; Program Design item 1: proves `ZmxBackend.discoverSessionInventory()`
/// and `observeSessionIdentity(_:)` against a real zmx daemon — the boundary
/// obligations the plan forbids mocking away. The kind-mapping *decision*
/// from an already-observed `ZmxSessionInventory` is proven separately, fast
/// and without a daemon, in `TerminalRestoreKindResolverTests`.
extension E2ESerializedTests {
    @Suite(.serialized)
    @MainActor
    struct TerminalRestoreZmxIntegrationTests {
        private func withBackend(
            _ test: @escaping (ZmxTestHarness, ZmxBackend) async throws -> Void
        ) async throws {
            let harness = await ZmxTestHarness()
            let backend = try #require(
                harness.createBackend(),
                "ZmxTestHarness failed to resolve zmx path for integration test"
            )
            try #require(await backend.isAvailable, "zmx should be available for integration test")
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

        /// Mirrors `ZmxSessionControl.processSnapshot`'s own `proc_pidinfo`
        /// read — this test's only way to find a daemon pid from the
        /// terminal-leader pid `zmx list` reports, without exposing a new
        /// production API for it.
        private func parentProcessID(of pid: Int32) -> Int32? {
            var information = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size)
            guard count == size else { return nil }
            return Int32(information.pbi_ppid)
        }

        @Test("a live session is alive, with an observable identity for the warm baseline")
        func liveSessionIsAliveWithObservableIdentity() async throws {
            try await withBackend { harness, backend in
                // Arrange — a real zmx session running a long-lived shell.
                let sessionID = ZmxSessionID.generateUUIDv7()
                let zmxPath = try #require(harness.zmxPath)
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath,
                    sessionId: sessionID.rawValue,
                    commandArgs: ["/bin/sh", "-c", "sleep 60"]
                )
                let socketAppeared = try await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true)
                try #require(socketAppeared, "zmx session socket never appeared")

                // Act
                let inventory = await backend.discoverSessionInventory()
                let identity = try await backend.observeSessionIdentity(sessionID)

                // Assert — proven alive, and its identity is observable (the
                // warm baseline choice 1 requires before ever calling a
                // session `.warm`).
                guard case .complete(let entries) = inventory else {
                    Issue.record("expected a complete inventory, got \(inventory)")
                    return
                }
                guard case .alive = entries[sessionID] else {
                    Issue.record("expected the live session to be alive, got \(String(describing: entries[sessionID]))")
                    return
                }
                #expect(identity != nil)

                _ = try await backend.destroyPaneSession(PaneSessionHandle(id: sessionID))
            }
        }

        @Test("killing the daemon (the reboot equivalent) proves the session dead, never merely unseen")
        func killedDaemonProvesSessionDead() async throws {
            try await withBackend { harness, backend in
                // Arrange
                let sessionID = ZmxSessionID.generateUUIDv7()
                let zmxPath = try #require(harness.zmxPath)
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath,
                    sessionId: sessionID.rawValue,
                    commandArgs: ["/bin/sh", "-c", "sleep 60"]
                )
                let socketAppeared = try await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: true)
                try #require(socketAppeared, "zmx session socket never appeared")
                let baselineInventory = await backend.discoverSessionInventory()
                guard case .complete(let baselineEntries) = baselineInventory,
                    case .alive(let wrapperPid) = baselineEntries[sessionID]
                else {
                    Issue.record("expected the session to start alive")
                    return
                }

                // Act — SIGKILL the daemon: the same fact a reboot leaves
                // behind (the socket file remains; nothing is listening).
                #expect(Darwin.kill(wrapperPid, SIGKILL) == 0)

                let inventoryAfterKill = await backend.discoverSessionInventory()

                // Assert — proof of death (SR2): `.refused` (the connection
                // was actively refused) or absent from a complete inventory,
                // never `.alive` and never `.unresponsive` (which would only
                // mean "couldn't tell").
                guard case .complete(let entriesAfterKill) = inventoryAfterKill else {
                    Issue.record("expected a complete inventory after kill, got \(inventoryAfterKill)")
                    return
                }
                switch entriesAfterKill[sessionID] {
                case .refused, nil:
                    break
                case .alive, .unresponsive:
                    let observed = String(describing: entriesAfterKill[sessionID])
                    Issue.record("killed daemon must never read as alive or merely unresponsive, got \(observed)")
                }
            }
        }

        @Test(
            "a stopped daemon's accepted-but-silent socket reads unresponsive, while another live session in the same list stays alive"
        )
        func stoppedDaemonReadsUnresponsiveWhileAnotherStaysAlive() async throws {
            try await withBackend { harness, backend in
                // Arrange — two real sessions: one this test will SIGSTOP, one
                // that stays live throughout, in the same `zmx list` call.
                let stoppedSessionID = ZmxSessionID.generateUUIDv7()
                let liveSessionID = ZmxSessionID.generateUUIDv7()
                let zmxPath = try #require(harness.zmxPath)
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath,
                    sessionId: stoppedSessionID.rawValue,
                    commandArgs: ["/bin/sh", "-c", "sleep 60"]
                )
                _ = try await harness.spawnZmxSession(
                    zmxPath: zmxPath,
                    sessionId: liveSessionID.rawValue,
                    commandArgs: ["/bin/sh", "-c", "sleep 60"]
                )
                let stoppedSocketAppeared = try await harness.waitForSessionSocket(
                    sessionId: stoppedSessionID.rawValue, exists: true
                )
                try #require(stoppedSocketAppeared, "zmx session socket never appeared")
                let liveSocketAppeared = try await harness.waitForSessionSocket(
                    sessionId: liveSessionID.rawValue, exists: true
                )
                try #require(liveSocketAppeared, "zmx session socket never appeared")

                let baselineInventory = await backend.discoverSessionInventory()
                guard case .complete(let baselineEntries) = baselineInventory,
                    case .alive(let stoppedTerminalLeaderPid) = baselineEntries[stoppedSessionID]
                else {
                    Issue.record("expected the session to start alive")
                    return
                }

                // `zmx list`'s `pid=` (and `.alive(wrapperPid:)`) names the
                // terminal leader — the forkpty child `daemonize.zig` execs
                // directly into the shell command — NOT the daemon that
                // answers the IPC control socket. `ZmxSessionControl.observe`
                // proves this itself: it asserts `terminal.parentPID ==
                // peerPID`, i.e. the daemon (`peerPID`, the process that
                // answers the socket) is the terminal leader's *parent*.
                // Stopping the terminal leader would stop the shell, not the
                // daemon's probe responder — so this test must find and stop
                // the parent.
                guard let stoppedDaemonPid = parentProcessID(of: stoppedTerminalLeaderPid) else {
                    Issue.record("could not resolve the daemon pid (parent of \(stoppedTerminalLeaderPid))")
                    return
                }

                // Act — SIGSTOP only this test's own daemon (verified by its
                // socket living under `harness.zmxDir`, the isolated lab
                // ZMX_DIR; never a bare pkill). A Unix domain socket's kernel
                // accept queue still completes a new connection for a stopped
                // listener, and a client's writes still land in its receive
                // buffer — but the stopped process never calls `poll`/`read`
                // to answer. zmx's own per-session probe
                // (`ipc.zig probeSession`, a 1s poll) times out and prints
                // `status=unreachable` for this session only, leaving the
                // other, still-live session unaffected in the same list.
                #expect(Darwin.kill(stoppedDaemonPid, SIGSTOP) == 0)
                defer { _ = Darwin.kill(stoppedDaemonPid, SIGCONT) }

                let inventoryWhileStopped = await backend.discoverSessionInventory()

                // Resume immediately: the assertions below don't need the
                // daemon stopped, and this keeps the defer-safe path (above)
                // a pure belt-and-suspenders cleanup rather than the only
                // resume path.
                #expect(Darwin.kill(stoppedDaemonPid, SIGCONT) == 0)

                // Assert — the stopped session reads unresponsive (proof of
                // neither life nor death, SR2), and the untouched live
                // session in the *same* inventory reads alive. The
                // `.unresponsive -> .unverified` restore-kind mapping itself
                // is proven, fast and without a daemon, in
                // `TerminalRestoreKindResolverTests`.
                guard case .complete(let entriesWhileStopped) = inventoryWhileStopped else {
                    Issue.record("expected a complete inventory while stopped, got \(inventoryWhileStopped)")
                    return
                }
                guard case .unresponsive = entriesWhileStopped[stoppedSessionID] else {
                    Issue.record(
                        "expected the stopped daemon to read unresponsive, got \(String(describing: entriesWhileStopped[stoppedSessionID]))"
                    )
                    return
                }
                guard case .alive = entriesWhileStopped[liveSessionID] else {
                    Issue.record(
                        "expected the other live session to stay alive in the same list, got \(String(describing: entriesWhileStopped[liveSessionID]))"
                    )
                    return
                }
            }
        }

        @Test("an unresponsive probe entry is never treated as proof of anything")
        func timeoutEntryIsNeitherAliveNorRefused() async throws {
            try await withBackend { harness, backend in
                // Arrange — a session zmx will classify as `Timeout` or
                // `Unexpected` (both print `status=unreachable`): request an
                // id that was never created, but craft a socket file present
                // with no daemon backing it, so the connection attempt is not
                // a simple "no such file" absence. zmx's own `get_session_entries`
                // iterates real directory entries in `cfg.socket_dir`; a
                // dangling regular file at that path is neither a valid nor
                // a cleanly-refused endpoint.
                let sessionID = ZmxSessionID.generateUUIDv7()
                let socketPath = harness.sessionSocketPath(for: sessionID.rawValue)
                FileManager.default.createFile(atPath: socketPath, contents: Data())

                // Act
                let inventory = await backend.discoverSessionInventory()

                // Assert — never proof of life or death.
                guard case .complete(let entries) = inventory else {
                    Issue.record("expected a complete inventory, got \(inventory)")
                    return
                }
                switch entries[sessionID] {
                case .alive:
                    Issue.record("a dangling non-socket file must never read as alive")
                case .refused, .unresponsive, nil:
                    break
                }
            }
        }
    }
}
