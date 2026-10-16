import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge File metadata scope admission")
struct BridgeFileInterestAdmissionTests {
    @Test(
        "accepted File scope reaches the source while source opening is suspended",
        .timeLimit(.minutes(1))
    )
    func acceptedFileScopeCanStartDuringSourceOpening() async throws {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let source = CoordinatorGatedFileMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: source,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        )
        let openToken = try #require(controlExecutionToken(try await harness.begin(openRequest)))
        #expect(await harness.session.admitControlProviderExecution(token: openToken))
        let openResponse = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest,
            worktreeId: nil
        )
        let openEffect = try await harness.session.completeAdmittedControl(
            token: openToken,
            exactResponseBytes: try JSONEncoder().encode(openResponse)
        )
        _ = try await pullMetadataFrame(from: pump)
        await coordinator.apply(openEffect, productAdmission: harness.productAdmission.context)
        #expect(await source.waitUntilOpenStarted() == 1)
        await harness.session.settleControlProviderDispatch(token: openToken)

        let scopeRequest = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(
                """
                {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","requestId":"file-scope-before-source",\
                "requestSequence":3,"subscriptionId":"file-subscription-1",\
                "subscriptionKind":"file.metadata","domain":"default",\
                "handle":"file-scope-handle-1","incarnation":"file-scope-incarnation-1",\
                "scopeRevision":1,"scope":{"kind":"file","changeFilter":{"kind":"none"},\
                "interests":[{"lane":"foreground","paths":["Sources/App.swift"]}],"pathScope":[]}}
                """.utf8
            )
        )
        #expect(
            await coordinator.acceptViewScope(
                scopeRequest,
                productAdmission: harness.productAdmission.context
            ) == nil
        )

        let updateStart = await source.waitUntilUpdateStarted()
        #expect(!updateStart.sourceAccepted)
        #expect(!updateStart.openFinished)
        await source.releaseSourceAcceptance()
        #expect((await source.waitUntilSourceAccepted()).sourceId == "file-source-1")
        await source.releaseOpen()
        #expect(!(await source.waitUntilOpenFinished()))
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }
}
