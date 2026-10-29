import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

extension E2ESerializedTests.ZmxE2ETests {
    @Test("the new daemon supports restore identity and verified quit control")
    func newDaemonSupportsRestoreIdentityAndVerifiedQuitControl() async throws {
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
            let cleanup = try await backend.retireVerifiedSession(sessionID, expectedIdentity: evidence)

            // Assert: the daemon consumed Kill; harness cleanup joins all owned processes.
            #expect(cleanup == .pending)
            #expect(try await harness.waitForSessionSocket(sessionId: sessionID.rawValue, exists: false))
        }
    }
}
