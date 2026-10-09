import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane disposal quiescence deadline")
struct BridgePaneProductDisposalDeadlineTests {
    @Test("pane disposal returns a typed leak count at its quiescence deadline")
    func paneDisposalBoundsUncooperativeExecution() async throws {
        let clock = TestPushClock()
        let provider = BridgePaneProductSessionProviderGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate(),
            retirementClock: clock
        )
        let installation = try await installFirstCandidate(in: owner)
        try await openBridgePaneProductSession(installation)
        await provider.holdProductCallResponses()
        let handler = BridgeSchemeHandler(
            paneId: UUIDv7.generate(),
            appRootURL: testBridgeAppRootURL(),
            productSessionRouter: await owner.schemeRouter
        )
        let request = try paneOwnerProductCallSchemeRequest(
            installation: installation,
            identitySuffix: "bounded-disposal"
        )
        let replyTask = Task {
            try await collectBridgeSchemeHandlerProductReply(handler: handler, request: request)
        }
        await provider.waitUntilProductCallStarted()

        let disposalTask = Task { await owner.retire(reason: .paneDisposal) }
        await clock.waitForPendingSleepCount(atLeast: 1)
        await owner.schemeRouter.waitUntilCleared()
        clock.advance(by: AppPolicies.Bridge.productRetirementQuiescenceDeadline)
        #expect(await disposalTask.value == .quiescenceDeadlineExceeded(unfinishedExecutionCount: 1))
        #expect((await owner.snapshot()).activeOperationExecutionCount == 1)

        await provider.releaseProductCallResponses()
        _ = try? await replyTask.value
        #expect(await owner.waitForRetirement(of: installation.bootstrap.workerInstanceId))
        #expect((await owner.snapshot()).activeOperationExecutionCount == 0)
    }

}
