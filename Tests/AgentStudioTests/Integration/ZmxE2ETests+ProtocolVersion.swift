import AgentStudioInfrastructure
import Darwin
import Foundation
import Testing

@testable import AgentStudioCore

extension E2ESerializedTests.ZmxE2ETests {
    @Test("protocol-independent stop verifies the real daemon and observes its exit")
    func protocolIndependentStopUsesRealDaemonIdentity() async throws {
        try await withRealBackend { harness, backend in
            let sessionID = ZmxSessionID.generateUUIDv7()
            _ = try await harness.spawnZmxSession(
                zmxPath: try #require(harness.zmxPath), sessionId: sessionID.rawValue,
                commandArgs: ["/bin/sleep", "300"])
            let data = try #require(try await backend.observeSessionIdentity(sessionID))
            let identity = try ZmxSessionIdentity.decode(data)
            let socketPath = harness.sessionSocketPath(for: sessionID.rawValue)
            #expect(try ZmxIncompatibleSessionStop.verifiedDaemon(path: socketPath) == identity.daemon)
            #expect(ZmxSessionControl.currentIncarnation(forPID: identity.daemon.pid) == identity.daemon)

            try await ZmxIncompatibleSessionStop.stop(sessionID: sessionID, directory: harness.zmxDir)

            #expect(ZmxSessionControl.currentIncarnation(forPID: identity.daemon.pid) == nil)
            #expect(try ZmxSessionControl.endpointIsAbsent(path: socketPath))
        }
    }

    @Test("the new daemon supports restore identity and verified quit control", arguments: [false, true])
    func newDaemonSupportsRestoreIdentityAndVerifiedQuitControl(forceDaemonExit: Bool) async throws {
        try await withRealBackend { harness, backend in
            // Arrange: the established harness owns this daemon and its isolated root.
            let sessionID = ZmxSessionID.generateUUIDv7()
            _ = try await harness.spawnZmxSession(
                zmxPath: try #require(harness.zmxPath), sessionId: sessionID.rawValue,
                commandArgs: ["/bin/sleep", "300"])

            // Act: use the same identity and control entry points as restore and quit.
            let evidence = try #require(try await backend.observeSessionIdentity(sessionID))
            let identity = try ZmxSessionIdentity.decode(evidence)
            #expect(identity.daemon.pid != identity.terminalLeader.pid)
            #expect(identity.processGroupID == identity.terminalLeader.pid)
            #expect(identity.sessionCreatedAt > 0)
            let socketPath = harness.sessionSocketPath(for: sessionID.rawValue)
            defer {
                // Only this fixture's unique socket; a crash intentionally leaves it behind.
                if forceDaemonExit { try? FileManager.default.removeItem(atPath: socketPath) }
            }
            // Assert: normal Kill removes the socket; an abrupt daemon exit
            // reports the stale socket through the same observation path.
            let retirement = { @Sendable in
                try await harness.observeSessionRetirement(sessionID: sessionID.rawValue, daemon: identity.daemon) {
                    if forceDaemonExit {
                        try #require(Darwin.kill(identity.daemon.pid, SIGKILL) == 0)
                    } else {
                        let cleanup = try await backend.retireVerifiedSession(sessionID, expectedIdentity: evidence)
                        #expect(cleanup == .pending)
                    }
                }
            }
            if forceDaemonExit {
                await #expect(
                    throws: ZmxSessionRetirementFailure.daemonExitedWithSocket(
                        sessionID: sessionID.rawValue, daemonPID: identity.daemon.pid)
                ) { try await retirement() }
                #expect(FileManager.default.fileExists(atPath: socketPath))
            } else {
                try await retirement()
                #expect(!FileManager.default.fileExists(atPath: socketPath))
            }
        }
    }
}
