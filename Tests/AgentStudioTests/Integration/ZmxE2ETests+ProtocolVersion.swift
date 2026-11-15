import AgentStudioInfrastructure
import Darwin
import Foundation
import Testing

@testable import AgentStudioCore

extension E2ESerializedTests.ZmxE2ETests {
    @Test("conditional incompatible cleanup preserves a different incarnation", arguments: [false, true])
    func conditionalIncompatibleCleanupProtectsReplacement(originalExtinct: Bool) async throws {
        try await withRealBackend { harness, backend in
            let originalSessionID = ZmxSessionID.generateUUIDv7()
            let path = try #require(harness.zmxPath)
            _ = try await harness.spawnZmxSession(
                zmxPath: path, sessionId: originalSessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
            let originalEvidence = try #require(try await backend.observeSessionIdentity(originalSessionID))
            let originalIdentity = try ZmxSessionIdentity.decode(originalEvidence)
            let targetSessionID: ZmxSessionID
            if originalExtinct {
                // Same durable ID and socket path, new daemon after the original family exits.
                try await harness.observeSessionRetirement(
                    sessionID: originalSessionID.rawValue, daemon: originalIdentity.daemon
                ) {
                    _ = try await backend.retireVerifiedSession(originalSessionID, expectedIdentity: originalEvidence)
                }
                targetSessionID = originalSessionID
            } else {
                // A still-live recorded family also cannot authorize a distinct endpoint's daemon.
                targetSessionID = .generateUUIDv7()
            }
            _ = try await harness.spawnZmxSession(
                zmxPath: path, sessionId: targetSessionID.rawValue, commandArgs: ["/bin/sleep", "300"])
            let replacementEvidence = try #require(try await backend.observeSessionIdentity(targetSessionID))
            let replacement = try ZmxSessionIdentity.decode(replacementEvidence)
            #expect(replacement.daemon != originalIdentity.daemon)

            if originalExtinct {
                try await ZmxIncompatibleSessionStop.stop(
                    sessionID: targetSessionID, directory: harness.zmxDir, expectedIdentity: originalEvidence)
            } else {
                await #expect(throws: ZmxSessionControlFailure.identityMismatch) {
                    try await ZmxIncompatibleSessionStop.stop(
                        sessionID: targetSessionID, directory: harness.zmxDir, expectedIdentity: originalEvidence)
                }
            }

            #expect(ZmxSessionControl.currentIncarnation(forPID: replacement.daemon.pid) == replacement.daemon)
            #expect(try await backend.observeSessionIdentity(targetSessionID) == replacementEvidence)
        }
    }

    @Test("protocol-independent stop verifies the real daemon and observes its exit", arguments: [false, true])
    func protocolIndependentStopUsesRealDaemonIdentity(useRecordedIdentity: Bool) async throws {
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

            try await ZmxIncompatibleSessionStop.stop(
                sessionID: sessionID, directory: harness.zmxDir, expectedIdentity: useRecordedIdentity ? data : nil)

            #expect(ZmxSessionControl.currentIncarnation(forPID: identity.daemon.pid) == nil)
            #expect(try ZmxSessionControl.endpointIsAbsent(path: socketPath))
        }
    }

    @Test("a prior-boot cleanup record cannot signal the present daemon")
    func priorBootIncompatibleCleanupDoesNotSignal() async throws {
        try await withRealBackend { harness, backend in
            let sessionID = ZmxSessionID.generateUUIDv7()
            _ = try await harness.spawnZmxSession(
                zmxPath: try #require(harness.zmxPath), sessionId: sessionID.rawValue,
                commandArgs: ["/bin/sleep", "300"])
            let data = try #require(try await backend.observeSessionIdentity(sessionID))
            let identity = try ZmxSessionIdentity.decode(data)
            let priorBoot = ZmxSessionIdentity(
                version: identity.version, bootID: "a different kernel boot", daemon: identity.daemon,
                terminalLeader: identity.terminalLeader, processGroupID: identity.processGroupID,
                sessionCreatedAt: identity.sessionCreatedAt)

            try await ZmxIncompatibleSessionStop.stop(
                sessionID: sessionID, directory: harness.zmxDir, expectedIdentity: priorBoot.encoded())

            #expect(try await backend.observeSessionIdentity(sessionID) == data)
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
