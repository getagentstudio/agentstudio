import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

@Suite("Bridge product admission integration")
struct BridgeProductAdmissionIntegrationTests {
    @Test("OPTIONS remains bodyless and claim-free across pane routing states")
    func optionsIsUniformAcrossPaneRoutingStates() async throws {
        // Arrange
        let activeHarness = try await BridgeProductAdmissionIntegrationHarness.make()
        let clearedHarness = try await BridgeProductAdmissionIntegrationHarness.make()
        let closedHarness = try await BridgeProductAdmissionIntegrationHarness.make()
        let optionsRequest = bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: nil,
            method: "OPTIONS"
        )
        #expect(await clearedHarness.owner.retire(reason: .pageReload) == .retired)
        closedHarness.owner.productAdmissionGate.close()
        #expect(await closedHarness.owner.retire(reason: .paneDisposal) == .retired)

        // Act
        let activeReply = await bridgeProductAdmissionReply(
            handler: activeHarness.handler,
            request: optionsRequest
        )
        let activeRouterSnapshot = await bridgeProductAdmissionDrainedRouterSnapshot(
            activeHarness.router
        )
        let clearedReply = await bridgeProductAdmissionReply(
            handler: clearedHarness.handler,
            request: optionsRequest
        )
        let clearedRouterSnapshot = await bridgeProductAdmissionDrainedRouterSnapshot(
            clearedHarness.router
        )
        let closedReply = await bridgeProductAdmissionReply(
            handler: closedHarness.handler,
            request: optionsRequest
        )
        let closedRouterSnapshot = await bridgeProductAdmissionDrainedRouterSnapshot(
            closedHarness.router
        )

        activeHarness.owner.productAdmissionGate.close()
        _ = await activeHarness.owner.retire(reason: .paneDisposal)

        // Assert
        for reply in [activeReply, clearedReply, closedReply] {
            #expect(reply?.response?.statusCode == 204)
            #expect(reply?.body.isEmpty == true)
            #expect(reply?.events == [.response])
        }
        for snapshot in [
            activeRouterSnapshot,
            clearedRouterSnapshot,
            closedRouterSnapshot,
        ] {
            #expect(snapshot.hasZeroResidue)
            #expect(snapshot.activeTransportClaimCount == 0)
            #expect(snapshot.transportClaimMintCount == 0)
        }
    }

    @Test("capability rejection precedes body access and closed admission is conflict")
    func capabilityAndClosedAdmissionPrecedeBodyAccess() async throws {
        // Arrange
        let harness = try await BridgeProductAdmissionIntegrationHarness.make()
        let body = harness.workerOpenBody
        let missingCapabilityBodyBeforeClose = BridgeProductObservedBodyInputStream(data: body)
        let wrongCapabilityBodyBeforeClose = BridgeProductObservedBodyInputStream(data: body)
        let missingCapabilityBodyAfterClose = BridgeProductObservedBodyInputStream(data: body)
        let wrongCapabilityBodyAfterClose = BridgeProductObservedBodyInputStream(data: body)
        let validCapabilityBodyAfterClose = BridgeProductObservedBodyInputStream(data: body)

        // Act
        let missingBeforeClose = await bridgeProductAdmissionReply(
            handler: harness.handler,
            request: harness.commandRequest(
                capability: nil,
                bodyStream: missingCapabilityBodyBeforeClose
            )
        )
        let missingBeforeCloseRouterSnapshot = await bridgeProductAdmissionDrainedRouterSnapshot(
            harness.router
        )
        let wrongBeforeClose = await bridgeProductAdmissionReply(
            handler: harness.handler,
            request: harness.commandRequest(
                capability: "wrong-capability",
                bodyStream: wrongCapabilityBodyBeforeClose
            )
        )
        let wrongBeforeCloseRouterSnapshot = await bridgeProductAdmissionDrainedRouterSnapshot(
            harness.router
        )
        harness.owner.productAdmissionGate.close()
        let missingAfterClose = await bridgeProductAdmissionReply(
            handler: harness.handler,
            request: harness.commandRequest(
                capability: nil,
                bodyStream: missingCapabilityBodyAfterClose
            )
        )
        let missingAfterCloseRouterSnapshot = await bridgeProductAdmissionDrainedRouterSnapshot(
            harness.router
        )
        let wrongAfterClose = await bridgeProductAdmissionReply(
            handler: harness.handler,
            request: harness.commandRequest(
                capability: "wrong-capability",
                bodyStream: wrongCapabilityBodyAfterClose
            )
        )
        let wrongAfterCloseRouterSnapshot = await bridgeProductAdmissionDrainedRouterSnapshot(
            harness.router
        )
        let validAfterClose = await bridgeProductAdmissionReply(
            handler: harness.handler,
            request: harness.commandRequest(
                capability: harness.capabilityHeader,
                bodyStream: validCapabilityBodyAfterClose
            )
        )
        let validAfterCloseRouterSnapshot = await bridgeProductAdmissionDrainedRouterSnapshot(
            harness.router
        )
        _ = await harness.owner.retire(reason: .paneDisposal)

        // Assert
        #expect(missingBeforeClose?.response?.statusCode == 401)
        #expect(wrongBeforeClose?.response?.statusCode == 403)
        #expect(missingAfterClose?.response?.statusCode == 401)
        #expect(wrongAfterClose?.response?.statusCode == 403)
        #expect(validAfterClose?.response?.statusCode == 409)
        #expect(validAfterClose?.body.isEmpty == true)
        for reply in [
            missingBeforeClose,
            wrongBeforeClose,
            missingAfterClose,
            wrongAfterClose,
            validAfterClose,
        ] {
            #expect(reply?.body.isEmpty == true)
            #expect(reply?.events == [.response])
        }
        #expect(
            [
                missingCapabilityBodyBeforeClose,
                wrongCapabilityBodyBeforeClose,
                missingCapabilityBodyAfterClose,
                wrongCapabilityBodyAfterClose,
                validCapabilityBodyAfterClose,
            ].allSatisfy { $0.readInvocationCount == 0 }
        )
        for snapshot in [
            missingBeforeCloseRouterSnapshot,
            wrongBeforeCloseRouterSnapshot,
            missingAfterCloseRouterSnapshot,
            wrongAfterCloseRouterSnapshot,
            validAfterCloseRouterSnapshot,
        ] {
            #expect(snapshot.hasZeroResidue)
            #expect(snapshot.activeTransportClaimCount == 0)
            #expect(snapshot.transportClaimMintCount == 0)
        }
    }

    @Test("close after admission fences provider completion and settles residue")
    func closeAfterAdmissionFencesProviderCompletion() async throws {
        // Arrange
        let harness = try await BridgeProductAdmissionIntegrationHarness.make(
            holdFirstControlResponse: true
        )
        let request = harness.commandRequest(
            capability: harness.capabilityHeader,
            body: harness.workerOpenBody
        )
        let replyTask = Task {
            try await bridgeProductAdmissionCollectReply(
                handler: harness.handler,
                request: request
            )
        }
        await harness.provider.waitUntilControlStarted(1)
        let admissionReply = try await replyTask.value
        let admitted = try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: admissionReply.body
        )

        // Act
        harness.owner.productAdmissionGate.close()
        await harness.provider.releaseHeldControlResponse()
        await harness.provider.waitUntilControlCompleted(1)
        await harness.installation.session.waitForOutstandingOperationExecutions()
        let sessionSnapshot = await harness.installation.session.snapshot
        let operationSettlement = await harness.installation.session.operationTable
            .entriesById[admitted.operationId]?.settlement?.outcome
        let providerSnapshot = await harness.provider.snapshot
        let routerSnapshot = await bridgeProductAdmissionDrainedRouterSnapshot(harness.router)
        let ownerSnapshot = await harness.owner.snapshot()
        _ = await harness.owner.retire(reason: .paneDisposal)

        // Assert
        #expect(admissionReply.response?.statusCode == 200)
        #expect(admissionReply.events.first == .response)
        #expect(operationSettlement == .failed)
        #expect(providerSnapshot.controlRequests.count == 1)
        #expect(providerSnapshot.controlCompletionCount == 1)
        #expect(sessionSnapshot.pendingRequestKind == nil)
        #expect((await harness.installation.session.diagnosticSnapshot).activeOperationExecutionCount == 0)
        #expect(sessionSnapshot.controlReplay.inFlightRequestSequence == nil)
        #expect(sessionSnapshot.controlReplay.replayableRequestSequence == 1)
        #expect(sessionSnapshot.lifecycle == .awaitingOpen)
        #expect(routerSnapshot.hasZeroResidue)
        #expect(routerSnapshot.transportClaimMintCount == 1)
        #expect(ownerSnapshot.activeSchemeTaskCount == 0)
        #expect(ownerSnapshot.activeTransportLeaseCount == 0)
    }

    @Test("session completion cannot commit after pane admission closes")
    func sessionCompletionIsFencedByPaneAdmission() async throws {
        // Arrange
        let harness = try await BridgeProductAdmissionIntegrationHarness.make()
        let session = harness.installation.session
        let productAdmission = try #require(
            harness.installation.productAdmissionGate.acquire()
        )
        let admission = await session.beginControl(
            exactRequestBytes: harness.workerOpenBody,
            presentedCapability: harness.capabilityHeader,
            productAdmission: productAdmission
        )
        guard case .execute(let token, let request) = admission else {
            Issue.record("Expected worker-open control execution admission")
            return
        }
        guard await session.admitControlProviderExecution(token: token) else {
            Issue.record("Expected worker-open provider dispatch claim")
            return
        }
        let exactResponseBytes = try JSONEncoder().encode(
            BridgeProductControlResponse.workerSessionAccepted(correlating: request)
        )

        // Act
        harness.owner.productAdmissionGate.close()
        let completionEffect = try await session.completeControl(
            token: token,
            exactResponseBytes: exactResponseBytes
        )
        await session.settleControlProviderDispatch(token: token)
        let sessionSnapshot = await session.snapshot
        _ = await harness.owner.retire(reason: .paneDisposal)

        // Assert
        #expect(completionEffect == .noEffect)
        #expect(sessionSnapshot.pendingRequestKind == nil)
        #expect((await session.diagnosticSnapshot).activeOperationExecutionCount == 0)
        #expect(sessionSnapshot.controlReplay.inFlightRequestSequence == nil)
        #expect(sessionSnapshot.controlReplay.replayableRequestSequence == 1)
        #expect(sessionSnapshot.lifecycle == .awaitingOpen)
    }
}

private struct BridgeProductAdmissionIntegrationHarness {
    let capabilityHeader: String
    let handler: BridgeSchemeHandler
    let installation: BridgeProductSessionInstallation
    let owner: BridgePaneProductSessionOwner
    let provider: BridgeProductSchemeProviderSpy
    let router: BridgeProductSchemeSessionRouter

    var workerOpenBody: Data {
        try! JSONSerialization.data(
            withJSONObject: [
                "kind": "workerSession.open",
                "paneSessionId": installation.bootstrap.paneSessionId,
                "request": NSNull(),
                "requestId": "request-open-admission-integration",
                "requestSequence": 1,
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ],
            options: [.sortedKeys]
        )
    }

    static func make(
        holdFirstControlResponse: Bool = false
    ) async throws -> Self {
        let provider = BridgeProductSchemeProviderSpy(
            holdFirstControlResponse: holdFirstControlResponse,
            contentReturnsWithoutTerminal: false
        )
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate(),
            retirementClock: TestPushClock()
        )
        let productAdmission = try #require(owner.productAdmissionGate.acquire())
        let installation = try await owner.prepareCandidate(productAdmission: productAdmission)
        guard
            await owner.activatePreparedCandidate(
                installation,
                productAdmission: productAdmission
            ) == .activated
        else {
            throw BridgeProductAdmissionIntegrationHarnessError.activationFailed
        }
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        )
        let router = await owner.schemeRouter
        return Self(
            capabilityHeader: capabilityHeader,
            handler: BridgeSchemeHandler(
                paneId: UUID(),
                appRootURL: testBridgeAppRootURL(),
                productSessionRouter: router
            ),
            installation: installation,
            owner: owner,
            provider: provider,
            router: router
        )
    }

    func commandRequest(
        capability: String?,
        body: Data? = nil,
        bodyStream: InputStream? = nil
    ) -> URLRequest {
        bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: capability,
            body: body,
            bodyStream: bodyStream
        )
    }
}

private enum BridgeProductAdmissionIntegrationHarnessError: Error {
    case activationFailed
}

private func bridgeProductAdmissionReply(
    handler: BridgeSchemeHandler,
    request: URLRequest
) async -> BridgeProductSchemeReplyObservation? {
    try? await bridgeProductAdmissionCollectReply(handler: handler, request: request)
}

private func bridgeProductAdmissionCollectReply(
    handler: BridgeSchemeHandler,
    request: URLRequest
) async throws -> BridgeProductSchemeReplyObservation {
    var body = Data()
    var events: [BridgeProductSchemeReplyObservation.Event] = []
    var response: HTTPURLResponse?
    for try await result in handler.reply(for: request) {
        switch result {
        case .response(let emittedResponse):
            events.append(.response)
            response = emittedResponse as? HTTPURLResponse
        case .data(let chunk):
            events.append(.data)
            body.append(chunk)
        @unknown default:
            Issue.record("Unexpected product admission URL scheme task result")
        }
    }
    return .init(body: body, events: events, response: response)
}

private func bridgeProductAdmissionDrainedRouterSnapshot(
    _ router: BridgeProductSchemeSessionRouter
) async -> BridgeProductSchemeSessionRouterSnapshot {
    await router.waitForDrain()
    return await router.snapshot
}
