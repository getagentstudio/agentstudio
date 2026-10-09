import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgeProductBootstrapFailureReplyTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("a failed bootstrap delivery answers the exact request id with a typed failure")
        func failedDeliveryAnswersRequestWithTypedFailure() async throws {
            // Arrange
            var failureReplies: [BootstrapFailureReply] = []
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .fileViewer, source: .commit(sha: "failed-delivery")),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground,
                productSessionBootstrapSink: { _, _, _, _, _ in
                    throw BridgeError.encoding("simulated bootstrap delivery failure")
                },
                productSessionBootstrapFailureSink: { _, requestId, reason, _ in
                    failureReplies.append(.init(requestId: requestId, reason: reason))
                }
            )

            // Act
            await controller.enqueueProductSessionBootstrapRequest(
                requestId: "failed-delivery-bootstrap",
                reason: .initial
            )

            // Assert: the undelivered capability is retired and the page gets an answer.
            #expect(
                failureReplies == [.init(requestId: "failed-delivery-bootstrap", reason: .deliveryFailed)]
            )
            #expect(await controller.productSessionOwner.activeBootstrap() == nil)
            #expect(await controller.beginTeardown().value)
        }

        @Test("a bootstrap request with no active product session answers with a typed failure")
        func missingActiveSessionAnswersRequestWithTypedFailure() async throws {
            // Arrange
            var deliveredWorkerInstanceIds: [String] = []
            var failureReplies: [BootstrapFailureReply] = []
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .fileViewer, source: .commit(sha: "no-active-session")),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground,
                productSessionBootstrapSink: { _, _, installation, _, _ in
                    deliveredWorkerInstanceIds.append(installation.bootstrap.workerInstanceId)
                },
                productSessionBootstrapFailureSink: { _, requestId, reason, _ in
                    failureReplies.append(.init(requestId: requestId, reason: reason))
                }
            )
            #expect(await controller.productSessionOwner.retire(reason: .workerReplacement) == .retired)

            // Act
            await controller.enqueueProductSessionBootstrapRequest(
                requestId: "initial-without-session",
                reason: .initial
            )

            // Assert
            #expect(deliveredWorkerInstanceIds.isEmpty)
            #expect(
                failureReplies == [.init(requestId: "initial-without-session", reason: .noActiveSession)]
            )
            #expect(await controller.beginTeardown().value)
        }
    }
}

private struct BootstrapFailureReply: Equatable {
    let requestId: String
    let reason: BridgeProductSessionBootstrapFailureReason
}
