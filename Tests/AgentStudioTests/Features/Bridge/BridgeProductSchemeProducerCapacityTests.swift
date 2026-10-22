import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

@Suite("Bridge product scheme producer capacity")
struct BridgeProductSchemeProducerCapacityTests {
    @Test("only producer capacity is a retryable HTTP refusal", arguments: ProducerRejectionScenario.allCases)
    func producerRegistrationRefusalPreservesItsMeaning(_ scenario: ProducerRejectionScenario) async throws {
        // Arrange: exercise the real session registry and adapter, not a status mapper.
        let harness = try BridgeProductSchemeAdapterHarness.make()
        do {
            try #require(try await harness.openSession().response?.statusCode == 200)
            try #require(await harness.session.waitUntilActive())
            let admission = try #require(harness.adapter.acquireAdmission())
            let request = try bridgeProductFileContentRequest(
                identitySuffix: "producer-capacity-subject", workerDerivationEpoch: 1
            )
            switch scenario {
            case .capacity:
                for index in 0..<16 {
                    let occupied = try bridgeProductFileContentRequest(
                        identitySuffix: "producer-capacity-occupied-\(index)", workerDerivationEpoch: 1
                    )
                    let registration = await harness.session.registerContentProducer(
                        request: occupied, productAdmission: admission, operation: { _ in }
                    )
                    _ = try bridgeProductAcceptedLease(registration)
                }
                #expect((await harness.session.producerSnapshot()).contentProducerLifecycleResidueCount == 16)
            case .duplicate:
                let registration = await harness.session.registerContentProducer(
                    request: request, productAdmission: admission, operation: { _ in }
                )
                _ = try bridgeProductAcceptedLease(registration)
            case .closing, .revoked:
                await harness.session.closeProducerRegistryForCapacityTest(revoking: scenario == .revoked)
            }

            // Act: keep the routing task so every outcome is joined before cleanup.
            let routed = bridgeProductSchemeReplyWithRoutingTask(
                adapter: harness.adapter,
                request: bridgeProductSchemeRequest(
                    route: BridgeProductWireContract.contentRoute,
                    capability: harness.capabilityHeader,
                    body: try JSONEncoder().encode(request)
                )
            )
            var response: HTTPURLResponse?
            do {
                responseEvents: for try await event in routed.stream {
                    switch event {
                    case .response(let value):
                        response = value as? HTTPURLResponse
                        break responseEvents
                    case .data: Issue.record("Content bytes preceded the HTTP response")
                    @unknown default: Issue.record("Unexpected scheme reply event")
                    }
                }
            } catch {
                routed.routingTask.cancel()
                await routed.routingTask.value
                throw error
            }
            // A mistaken acceptance emits 200 then holds a provider; stop at the response.
            routed.routingTask.cancel()
            await routed.routingTask.value

            // Assert: literals come from the wire contract in the Lead's commission.
            if scenario == .capacity {
                #expect(response?.statusCode == 503)
                #expect(
                    response?.value(forHTTPHeaderField: "X-AgentStudio-Bridge-Content-Rejection") == "producer_capacity"
                )
                #expect(
                    response?.value(forHTTPHeaderField: "Access-Control-Expose-Headers")
                        == "X-AgentStudio-Bridge-Content-Rejection")
            } else {
                #expect(response?.statusCode == 409)
                #expect(response?.value(forHTTPHeaderField: "X-AgentStudio-Bridge-Content-Rejection") == nil)
            }
            #expect((await harness.provider.snapshot).contentRequestCount == 0)
        } catch {
            await retireCapacityTestSession(harness.session)
            throw error
        }
        await retireCapacityTestSession(harness.session)
    }
}

enum ProducerRejectionScenario: CaseIterable, Sendable {
    case capacity
    case closing
    case duplicate
    case revoked
}

private func retireCapacityTestSession(_ session: BridgeProductSession) async {
    let revocation = await session.revoke(acknowledgeLifecycle: { _ in true })
    #expect(await revocation.wait())
    #expect((await session.producerSnapshot()).hasZeroResidue)
}

extension BridgeProductSession {
    // The session is still active: reach the registry's actual closing/revoked branches.
    fileprivate func closeProducerRegistryForCapacityTest(revoking: Bool) {
        _ = producerRegistry.requestStopEveryProducer(revoking: revoking)
    }
}
