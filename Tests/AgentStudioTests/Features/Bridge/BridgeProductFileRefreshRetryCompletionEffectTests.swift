import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product File refresh retry completion effect")
struct BridgeProductFileRefreshRetryCompletionEffectTests {
    @Test("retry runs only after committed completion and only once")
    func retryRequiresCommittedCompletion() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let deadlineClock = TestPushClock()
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes,
            deadlineClock: deadlineClock
        )
        let recorder = await MainActor.run { FileRefreshRetryRecorder() }
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            applyFileRefreshRetry: { _ in recorder.record() },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        let callBody = fileRefreshRetryBody()
        let decodedCall = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: callBody
        )

        // Act
        _ = await provider.response(for: decodedCall)
        let countBeforeCommit = await recorder.count
        let openAdmission = try await dispatcher.dispatch(
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )
        let openResult = try await awaitBridgeProductAdmittedControlResult(
            openAdmission,
            session: session,
            productAdmission: productAdmission
        )
        #expect(openResult.outcome == .succeeded)
        let admitted = try await dispatcher.dispatch(
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )
        let replay = try await dispatcher.dispatch(
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )
        let result = try await awaitBridgeProductAdmittedControlResult(
            admitted,
            session: session,
            productAdmission: productAdmission
        )

        // Assert
        #expect(countBeforeCommit == 0)
        #expect(replay == admitted)
        #expect(result.outcome == .succeeded)
        #expect(await recorder.count == 1)
    }
}

@MainActor
private final class FileRefreshRetryRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private func fileRefreshRetryBody() -> Data {
    Data(
        """
        {
          "call": { "method": "file.refresh.retry", "request": {} },
          "kind": "product.call",
          "paneSessionId": "\(bridgeProductTestPaneSessionId)",
          "requestId": "file-refresh-retry-1",
          "requestSequence": 2,
          "wireVersion": 2,
          "workerDerivationEpoch": 0,
          "workerInstanceId": "\(bridgeProductTestWorkerInstanceId)"
        }
        """.utf8
    )
}
