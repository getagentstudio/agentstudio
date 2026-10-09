import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgeProductInstallationIngressTests {
        @Test("native message closes E1 before its task and held bootstrap tail; first initial stays live")
        func nativeIngressFencesBeforeTaskAndTail() async throws {
            installTestCoreAtomsIfNeeded()
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .fileViewer, source: .commit(sha: "rr2-native-ingress")),
                appRootURL: testBridgeAppRootURL(), initialPaneActivity: .foreground,
                productSessionBootstrapSink: { _, _, _, _, _ in })
            let first = try #require(await controller.productSessionOwner.activeInstallation)
            let firstAdmission = try #require(first.productAdapter.acquireAdmission())
            await controller.enqueueProductSessionBootstrapRequest(requestId: "rr2-first", reason: .initial)
            #expect(firstAdmission.withValidAdmission { true } == true)
            let heldTail = HeldStep<Void>("native bootstrap transition tail")
            let tail = Task { try? await heldTail.arrive(()) }
            controller.productSessionBootstrapTransitionTail = Task { _ = await tail.value }
            try await heldTail.firstArrival()
            let handler = BridgeReadyMessageHandler()
            controller.configureReadyMessageHandler(handler)
            let request = try #require(
                handler.receiveValidatedBootstrapMessage(
                    .productSessionBootstrap(requestId: "rr2-replacement", reason: .workerReplacement)))
            // The synchronous handler call has returned. Its MainActor task has not run yet.
            #expect(firstAdmission.withValidAdmission { true } == nil)
            #expect(controller.productAdmissionGate.acquire() != nil)
            heldTail.release()
            await tail.value
            await request.value
            #expect(await controller.productSessionOwner.activeInstallation?.productAdapter.acquireAdmission() != nil)
            #expect(controller.reloadWebView())
            let reloaded = controller.productSessionOwner.installationFenceProjection.snapshot
            #expect(reloaded.installation?.gate.diagnosticSnapshot.isOpen == false)
            #expect(await controller.beginTeardown().value)
        }
    }
}
