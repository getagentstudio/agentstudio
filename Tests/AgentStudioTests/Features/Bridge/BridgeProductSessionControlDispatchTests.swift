import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session control dispatch")
struct BridgeProductSessionControlDispatchTests {
    @Test("revocation may abandon an admission before provider dispatch is claimed")
    func revocationWinsBeforeProviderDispatchClaim() async throws {
        // Arrange
        let fixture = try makePendingControlFixture()
        let admission = await fixture.productAdmission.beginControl(
            in: fixture.session,
            exactRequestBytes: fixture.requestBytes,
            presentedCapability: fixture.capabilityHeader
        )
        let token = try #require(controlDispatchToken(admission))

        // Act
        let revocation = await fixture.session.revoke(acknowledgeLifecycle: { _ in true })
        let claimedAfterRevocation = await fixture.session.admitControlProviderExecution(token: token)

        // Assert
        #expect(!claimedAfterRevocation)
        #expect(await revocation.wait())
        let snapshot = await fixture.session.snapshot
        #expect(snapshot.pendingRequestKind == nil)
        #expect(snapshot.controlReplay.inFlightRequestSequence == nil)
    }

    @Test("revocation settles an admitted operation and preserves its exact admission replay")
    func admittedOperationIsFencedByRevocation() async throws {
        // Arrange
        let fixture = try makePendingControlFixture()
        let admission = await fixture.productAdmission.beginControl(
            in: fixture.session,
            exactRequestBytes: fixture.requestBytes,
            presentedCapability: fixture.capabilityHeader
        )
        let token = try #require(controlDispatchToken(admission))
        let request = try #require(controlDispatchRequest(admission))
        let admitted = try await fixture.session.admitControlOperation(token: token, execute: { _ in })
        let exactResponseBytes = try JSONEncoder().encode(
            BridgeProductControlResponse.workerSessionAccepted(correlating: request)
        )

        // Act
        let revocation = await fixture.session.revoke(acknowledgeLifecycle: { _ in true })
        let revoked = await revocation.wait()
        var replayCache = await fixture.session.controlReplay
        let replay = replayCache.begin(
            requestSequence: 1,
            exactRequestBytes: fixture.requestBytes
        )

        // Assert
        #expect(revoked)
        await #expect(throws: BridgeProductSessionError.invalidAdmissionToken) {
            _ = try await fixture.session.completeControl(
                token: token,
                exactResponseBytes: exactResponseBytes
            )
        }
        #expect(replay == .replay(exactResponseBytes: admitted.responseBytes))
        #expect((await fixture.session.diagnosticSnapshot).retainedOperationResultCount == 0)
        let finalSnapshot = await fixture.session.snapshot
        #expect(finalSnapshot.lifecycle == .revoked)
        #expect(finalSnapshot.pendingRequestKind == nil)
        #expect(finalSnapshot.controlReplay.replayableRequestSequence == 1)
    }
}

private struct PendingControlFixture {
    let capabilityHeader: String
    let productAdmission: BridgeProductAdmissionTestContext
    let requestBytes: Data
    let session: BridgeProductSession
}

private func makePendingControlFixture() throws -> PendingControlFixture {
    let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
    return try .init(
        capabilityHeader: BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes),
        productAdmission: .make(),
        requestBytes: bridgeProductSchemeWorkerOpenBody(),
        session: BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes
        )
    )
}

private func controlDispatchToken(
    _ admission: BridgeProductSessionControlAdmission
) -> BridgeProductControlAdmissionToken? {
    guard case .execute(let token, _) = admission else { return nil }
    return token
}

private func controlDispatchRequest(
    _ admission: BridgeProductSessionControlAdmission
) -> BridgeProductControlRequest? {
    guard case .execute(_, let request) = admission else { return nil }
    return request
}
