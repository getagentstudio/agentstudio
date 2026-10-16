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
    struct BridgePaneControllerNoSourceTests {
        @Test(
            "a pane without a workspace source publishes no-source Review",
            arguments: [
                nil, BridgePaneSource.commit(sha: "no-workspace-source"),
            ])
        func noWorkspaceSourcePublishesNoSource(source: BridgePaneSource?) async throws {
            installTestCoreAtomsIfNeeded()
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: source),
                appRootURL: testBridgeAppRootURL(),
                initialPaneActivity: .foreground
            )
            do {
                let installation = try #require(await controller.productSessionOwner.activeInstallation)
                try await openBridgePaneProductSession(installation)
                let provider = try #require(controller.productSchemeProvider)
                let admission = try #require(installation.productAdapter.acquireAdmission())
                let request = try bootstrapReviewMetadataRequest(installation: installation)
                let registration = await installation.session.registerMetadataProducer(
                    request: request,
                    productAdmission: admission
                ) { lease in
                    await provider.runMetadataProducer(
                        request: request, lease: lease, productAdmission: admission, session: installation.session)
                }
                let lease = try bridgeProductAcceptedLease(registration)
                let decoder = try BridgeProductMetadataFrameDecoder()
                let opening = try #require(
                    await consumeNextBridgeProductProducerFrame(
                        for: lease, from: installation.session, productAdmission: admission)
                )
                guard case .metadataStreamAccepted = try #require(decoder.append(opening.data).first) else {
                    Issue.record("Expected metadata acceptance before the initial pane presentation")
                    #expect(await controller.beginTeardown().value)
                    return
                }
                let queued = try #require(
                    await consumeNextBridgeProductProducerFrame(
                        for: lease, from: installation.session, productAdmission: admission)
                )
                guard case .panePresentation(let presentation) = try #require(decoder.append(queued.data).first) else {
                    Issue.record("Expected the controller's initial pane presentation")
                    #expect(await controller.beginTeardown().value)
                    return
                }
                let comparison = try #require(presentation.reviewComparison)
                #expect(comparison.attempt == .noSource)
                let attemptObject = try #require(
                    JSONSerialization.jsonObject(with: JSONEncoder().encode(comparison.attempt)) as? [String: String]
                )
                #expect(attemptObject == ["status": "noSource"])
                #expect(comparison.activeTarget == nil)
                #expect(comparison.displayedSnapshot == .absent)
                #expect(comparison.repositoryDefaultTarget == nil)
                #expect(
                    controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison == comparison)
                try await closeBridgeProductSessionProducer(lease, in: installation.session)
            } catch {
                #expect(await controller.beginTeardown().value)
                throw error
            }
            #expect(await controller.beginTeardown().value)
        }
    }
}
