import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@Suite("Live server fixture teardown", .serialized)
struct LiveServerFixtureTeardownTests {
    @Test("a failed drain is reported while preserving the body outcome", arguments: [false, true])
    func failedDrainIsReportedWithoutReplacingBodyError(bodyThrows: Bool) async throws {
        let port = FailingFixtureCredentialPort()
        let fixture = try LiveServerFixture(credentialContinuityPort: port)
        var observedBodyError = false

        try await withKnownIssue(
            "The fixture must report this intentionally failed persistence drain",
            {
                do {
                    try await withLiveServer(
                        makeFixture: { fixture },
                        body: { fixture in
                            try fixture.server.start()
                            try registerFixtureCredential(in: fixture)
                            if bodyThrows { throw FixtureTeardownProofError.bodyFailed }
                        })
                } catch FixtureTeardownProofError.bodyFailed {
                    observedBodyError = true
                }
            },
            matching: { issue in
                issue.comments.contains {
                    $0.rawValue.contains("credential persistence drain failed")
                        && $0.rawValue.contains("failedOperationCount: 1")
                }
            }
        )

        #expect(observedBodyError == bodyThrows)
        #expect(port.registrationCallCount == 1)
        #expect(fixture.server.trackedConnectionHandlerCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.path))
    }

    @Test("explicit stop and scope teardown do not retry a held failed write")
    func repeatedStopsDoNotSnapshotFailedCredentialTwice() async throws {
        let registration = HeldStep<AgentStudioIPCIssuedPaneCredential>("fixture held credential write")
        let port = FailingFixtureCredentialPort(registration: registration)
        let fixture = try LiveServerFixture(credentialContinuityPort: port)

        try await withLiveServer(
            makeFixture: { fixture },
            releaseHeldWork: { registration.release() },
            body: { fixture in
                try fixture.server.start()
                try registerFixtureCredential(in: fixture)
                fixture.stopAcceptingConnections()
                let credential = try await registration.firstArrival()
                #expect(credential.paneID == fixture.boundPaneId)
                registration.fail(FixtureTeardownProofError.writeFailed)
                await fixture.server.joinConnectionHandlers()
                #expect(await fixture.server.drainCredentialPersistence().failedOperationCount == 1)

                // The facade is deliberately used here: it cannot bypass the
                // fixture checkpoint and enqueue that unsaved credential again.
                fixture.server.stopAcceptingConnections()
                fixture.stopAcceptingConnections()
                fixture.stop()
            }
        )

        #expect(port.registrationCallCount == 1)
        #expect(fixture.server.trackedConnectionHandlerCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.path))
    }

    private func registerFixtureCredential(in fixture: LiveServerFixture) throws {
        try fixture.server.principalRegistry.registerIssuedPaneCredential(
            paneID: fixture.boundPaneId,
            workspaceID: fixture.workspaceId,
            credentialRecordID: UUIDv7.generate(),
            verifierSHA256: Data(repeating: 0xA5, count: 32)
        )
    }
}

private enum FixtureTeardownProofError: Error {
    case bodyFailed
    case writeFailed
}

private final class FailingFixtureCredentialPort: AgentStudioIPCCredentialContinuityPort, Sendable {
    private let callCount = Mutex(0)
    private let registration: HeldStep<AgentStudioIPCIssuedPaneCredential>?

    init(registration: HeldStep<AgentStudioIPCIssuedPaneCredential>? = nil) {
        self.registration = registration
    }

    var registrationCallCount: Int { callCount.withLock { $0 } }

    func registerIssuedPaneCredential(
        _ credential: AgentStudioIPCIssuedPaneCredential,
        if _: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        callCount.withLock { $0 += 1 }
        if let registration { try await registration.arrive(credential) }
        throw FixtureTeardownProofError.writeFailed
    }

    func revokeAllPaneCredentials(paneID _: UUID) async throws {}
}
