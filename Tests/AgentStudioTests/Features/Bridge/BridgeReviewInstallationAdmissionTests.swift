import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Canonical Review across installation replacement", .serialized)
struct BridgeReviewInstallationAdmissionTests {
    @Test("the committing E1 admission can replay and display its publication")
    func committingInstallationAdmissionCanReplayAndDisplayPublication() async throws {
        let paneAdmission = try BridgeProductAdmissionTestContext.make()
        let installationGate = BridgeProductAdmissionGate()
        let installationAdmission = try #require(
            paneAdmission.context.withInstallation(installationGate)
        )
        let coordinator = BridgeReviewPublicationCoordinator()
        let prepared = try await makeReviewPreparedPublication(
            suffix: "installation-bound-replay",
            reviewGeneration: 1
        )
        let committed = try commitObserved(
            prepared,
            in: coordinator,
            productAdmission: installationAdmission
        )

        #expect(
            coordinator.committedPublicationForReplay(productAdmission: installationAdmission)
                == committed
        )
        #expect(
            coordinator.isCurrentCanonicalPublication(
                publicationId: committed.publicationId,
                productAdmission: installationAdmission
            )
        )
        #expect(
            coordinator.activeContentHandle(
                handleId: prepared.contentHandles[0].handleId,
                requestedGeneration: prepared.package.reviewGeneration,
                productAdmission: installationAdmission
            ) == prepared.contentHandles[0]
        )
        #expect(
            coordinator.admitDisplayInstallation(
                expectedDisplayedPublicationId: nil,
                candidatePublicationId: committed.publicationId,
                workerInstanceId: "installation-bound-worker",
                productAdmission: installationAdmission
            ) == .admitted
        )
        #expect(
            coordinator.recordDisplayedApplication(
                publicationId: committed.publicationId,
                workerInstanceId: "installation-bound-worker",
                productAdmission: installationAdmission
            ) == .advanced
        )
        #expect(
            coordinator.acknowledgedDisplayedPublication(productAdmission: installationAdmission)
                == committed
        )
        let publicationIdentity = try BridgeProductReviewAnnotationPublicationIdentity(
            packageId: committed.package.packageId,
            publicationId: committed.publicationId,
            reviewGeneration: committed.package.reviewGeneration.rawValue,
            revision: committed.package.revision,
            sourceIdentity: committed.package.query.queryId
        )
        #expect(
            coordinator.retainedPublication(
                matching: publicationIdentity,
                productAdmission: installationAdmission
            ) == committed
        )
        let closeDrain = coordinator.close()
        #expect(closeDrain.artifactPins.isEmpty)
        #expect(closeDrain.priorReleaseTask == nil)
        installationGate.close()
        paneAdmission.close()
    }

    @Test("pane-only and foreign E1 authority cannot read an E1-bound publication")
    func foreignOrPaneAuthorityCannotReadInstallationBoundPublication() async throws {
        let paneAdmission = try BridgeProductAdmissionTestContext.make()
        let installationGate = BridgeProductAdmissionGate()
        let installationAdmission = try #require(
            paneAdmission.context.withInstallation(installationGate)
        )
        let foreignInstallationGate = BridgeProductAdmissionGate()
        let foreignInstallationAdmission = try #require(
            paneAdmission.context.withInstallation(foreignInstallationGate)
        )
        let coordinator = BridgeReviewPublicationCoordinator()
        let prepared = try await makeReviewPreparedPublication(
            suffix: "installation-bound-isolation",
            reviewGeneration: 1
        )
        let committed = try commitObserved(
            prepared,
            in: coordinator,
            productAdmission: installationAdmission
        )
        let publicationIdentity = try BridgeProductReviewAnnotationPublicationIdentity(
            packageId: committed.package.packageId,
            publicationId: committed.publicationId,
            reviewGeneration: committed.package.reviewGeneration.rawValue,
            revision: committed.package.revision,
            sourceIdentity: committed.package.query.queryId
        )

        #expect(
            coordinator.committedPublicationForReplay(productAdmission: foreignInstallationAdmission) == nil
        )
        #expect(
            coordinator.committedPublicationForReplay(productAdmission: paneAdmission.context) == nil
        )
        #expect(
            !coordinator.isCurrentCanonicalPublication(
                publicationId: committed.publicationId,
                productAdmission: foreignInstallationAdmission
            )
        )
        #expect(
            !coordinator.isCurrentCanonicalPublication(
                publicationId: committed.publicationId,
                productAdmission: paneAdmission.context
            )
        )
        #expect(
            coordinator.retainedPublication(
                matching: publicationIdentity,
                productAdmission: foreignInstallationAdmission
            ) == nil
        )
        #expect(
            coordinator.retainedPublication(
                matching: publicationIdentity,
                productAdmission: paneAdmission.context
            ) == nil
        )
        #expect(
            coordinator.activeContentHandle(
                handleId: prepared.contentHandles[0].handleId,
                requestedGeneration: prepared.package.reviewGeneration,
                productAdmission: foreignInstallationAdmission
            ) == nil
        )
        #expect(
            coordinator.admitDisplayInstallation(
                expectedDisplayedPublicationId: nil,
                candidatePublicationId: committed.publicationId,
                workerInstanceId: "foreign-installation-worker",
                productAdmission: foreignInstallationAdmission
            ) == .rejected
        )

        let closeDrain = coordinator.close()
        #expect(closeDrain.artifactPins.isEmpty)
        #expect(closeDrain.priorReleaseTask == nil)
        installationGate.close()
        foreignInstallationGate.close()
        paneAdmission.close()
    }

    @Test("B reads and installs pane publication while closed A and foreign pane are refused")
    func canonicalPublicationSurvivesInstallationReplacement() async throws {
        let paneGate = BridgeProductAdmissionGate()
        let pane = try #require(paneGate.acquire())
        let coordinator = BridgeReviewPublicationCoordinator()
        let prepared = try await makeReviewPreparedPublication(suffix: "e1-canonical", reviewGeneration: 1)
        let committed = try commitObserved(prepared, in: coordinator, productAdmission: pane)
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: BridgePaneProductSessionProviderGate(), productAdmissionGate: paneGate)
        let first = try await installFirstCandidate(in: owner)
        let firstAdmission = try #require(first.productAdapter.acquireAdmission())
        #expect(
            coordinator.committedPublicationForReplay(productAdmission: firstAdmission)?.publicationId
                == committed.publicationId)
        let successor = try await installFirstCandidate(in: owner)
        let nextAdmission = try #require(successor.productAdapter.acquireAdmission())
        let foreign = try #require(BridgeProductAdmissionGate().acquire())
        #expect(!firstAdmission.matches(nextAdmission))
        #expect(firstAdmission.hasSamePaneAuthority(as: nextAdmission))
        #expect(
            coordinator.isCurrentCanonicalPublication(
                publicationId: committed.publicationId, productAdmission: nextAdmission))
        #expect(
            !coordinator.isCurrentCanonicalPublication(
                publicationId: committed.publicationId, productAdmission: firstAdmission))
        #expect(coordinator.committedPublicationForReplay(productAdmission: firstAdmission) == nil)
        #expect(coordinator.committedPublicationForReplay(productAdmission: foreign) == nil)
        #expect(
            coordinator.committedPublicationForReplay(productAdmission: nextAdmission)?.publicationId
                == committed.publicationId)
        #expect(
            coordinator.activeContentHandle(
                handleId: prepared.contentHandles[0].handleId,
                requestedGeneration: prepared.package.reviewGeneration, productAdmission: nextAdmission)
                == prepared.contentHandles[0])
        #expect(
            coordinator.activeContentHandle(
                handleId: prepared.contentHandles[0].handleId,
                requestedGeneration: prepared.package.reviewGeneration, productAdmission: firstAdmission) == nil)
        #expect(
            coordinator.activeContentHandle(
                handleId: "wrong-handle",
                requestedGeneration: prepared.package.reviewGeneration, productAdmission: nextAdmission) == nil)
        #expect(
            coordinator.admitDisplayInstallation(
                expectedDisplayedPublicationId: nil,
                candidatePublicationId: committed.publicationId, workerInstanceId: successor.bootstrap.workerInstanceId,
                productAdmission: nextAdmission) == .admitted)
        #expect(
            coordinator.recordDisplayedApplication(
                publicationId: committed.publicationId,
                workerInstanceId: first.bootstrap.workerInstanceId, productAdmission: firstAdmission) == .rejected)
        #expect(
            coordinator.recordDisplayedApplication(
                publicationId: committed.publicationId,
                workerInstanceId: successor.bootstrap.workerInstanceId, productAdmission: nextAdmission) == .advanced)
        #expect(
            coordinator.acknowledgedDisplayedPublication(productAdmission: nextAdmission)?.publicationId
                == committed.publicationId)
        #expect(await owner.retire(reason: .paneDisposal) == .retired)
        _ = coordinator.close()
        await coordinator.takeArtifactPinReleaseTask()?.value
    }
}
