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

    @Test("committed pane Review is readable without E1 but not by a foreign pane")
    func committedPaneReviewIsReadableWithoutE1ButNotByForeignPane() async throws {
        let paneAdmission = try BridgeProductAdmissionTestContext.make()
        let installationGate = BridgeProductAdmissionGate()
        let installationAdmission = try #require(
            paneAdmission.context.withInstallation(installationGate)
        )
        let foreignPaneAdmission = try BridgeProductAdmissionTestContext.make()
        let coordinator = BridgeReviewPublicationCoordinator()
        let prepared = try await makeReviewPreparedPublication(
            suffix: "pane-canonical-isolation",
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
            coordinator.committedPublicationForReplay(productAdmission: paneAdmission.context) == committed
        )
        #expect(
            coordinator.committedPublicationForReplay(productAdmission: foreignPaneAdmission.context) == nil
        )
        #expect(
            !coordinator.isCurrentCanonicalPublication(
                publicationId: committed.publicationId, productAdmission: foreignPaneAdmission.context
            )
        )
        #expect(
            coordinator.retainedPublication(
                matching: publicationIdentity,
                productAdmission: foreignPaneAdmission.context
            ) == nil
        )
        #expect(
            coordinator.activeContentHandle(
                handleId: prepared.contentHandles[0].handleId,
                requestedGeneration: prepared.package.reviewGeneration,
                productAdmission: foreignPaneAdmission.context
            ) == nil
        )

        let closeDrain = coordinator.close()
        #expect(closeDrain.artifactPins.isEmpty)
        #expect(closeDrain.priorReleaseTask == nil)
        installationGate.close()
        foreignPaneAdmission.close()
        paneAdmission.close()
    }

    @Test("committed E1 Review publication replays to its successor installation")
    func committedInstallationPublicationReplaysToSuccessor() async throws {
        let paneGate = BridgeProductAdmissionGate()
        let pane = try #require(paneGate.acquire())
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: BridgePaneProductSessionProviderGate(), productAdmissionGate: paneGate)
        let first = try await installFirstCandidate(in: owner)
        let firstAdmission = try #require(first.productAdapter.acquireAdmission())
        let coordinator = BridgeReviewPublicationCoordinator()
        let prepared = try await makeReviewPreparedPublication(suffix: "e1-canonical", reviewGeneration: 1)
        let committed = try commitObserved(prepared, in: coordinator, productAdmission: firstAdmission)
        #expect(
            coordinator.committedPublicationForReplay(productAdmission: pane)?.publicationId == committed.publicationId)
        #expect(coordinator.committedPublicationForReplay(productAdmission: firstAdmission) == committed)

        #expect(
            coordinator.isCurrentCanonicalPublication(
                publicationId: committed.publicationId, productAdmission: firstAdmission))
        let successor = try await installFirstCandidate(in: owner)
        let nextAdmission = try #require(successor.productAdapter.acquireAdmission())
        let foreign = try #require(BridgeProductAdmissionGate().acquire())
        #expect(!firstAdmission.matches(nextAdmission))
        #expect(firstAdmission.hasSamePaneAuthority(as: nextAdmission))
        #expect(coordinator.committedPublicationForReplay(productAdmission: firstAdmission) == nil)
        #expect(
            coordinator.committedPublicationForReplay(productAdmission: nextAdmission)?.publicationId
                == committed.publicationId)
        #expect(coordinator.committedPublicationForReplay(productAdmission: foreign) == nil)
        #expect(
            coordinator.isCurrentCanonicalPublication(
                publicationId: committed.publicationId, productAdmission: nextAdmission))
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

    @Test("foreign or retired E1 cannot commit a staged Review publication")
    func foreignOrRetiredInstallationCannotCommitStagedPublication() async throws {
        let pane = try BridgeProductAdmissionTestContext.make()
        let installationGate = BridgeProductAdmissionGate()
        let installationAdmission = try #require(pane.context.withInstallation(installationGate))
        let foreignInstallationGate = BridgeProductAdmissionGate()
        let foreignInstallationAdmission = try #require(pane.context.withInstallation(foreignInstallationGate))
        let coordinator = BridgeReviewPublicationCoordinator()
        let prepared = try await makeReviewPreparedPublication(suffix: "late-e1-commit", reviewGeneration: 1)
        let token = try #require(coordinator.stage(prepared, productAdmission: installationAdmission))

        #expect(
            coordinator.commit(
                token,
                productAdmission: foreignInstallationAdmission,
                captureCommittedPresentation: reviewCommittedPresentationSnapshot,
                presentCommitted: { _ in Issue.record("A foreign E1 must not commit a staged publication") }
            ) == .superseded
        )
        installationGate.close()
        #expect(
            coordinator.commit(
                token,
                productAdmission: installationAdmission,
                captureCommittedPresentation: reviewCommittedPresentationSnapshot,
                presentCommitted: { _ in Issue.record("A retired E1 must not commit a staged publication") }
            ) == .closed
        )
        #expect(coordinator.diagnosticSnapshot.active == nil)
        #expect(coordinator.committedPublicationForReplay(productAdmission: pane.context) == nil)

        _ = coordinator.close()
        foreignInstallationGate.close()
        pane.close()
    }
}
