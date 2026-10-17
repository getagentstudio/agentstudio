import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Bridge Review pending publication supersession")
struct BridgeReviewPublicationSupersessionTests {
    @Test("same-pane retirement supersedes a live installation-bound pending publication")
    func samePaneRetirementSupersedesLiveInstallationBoundPendingPublication() async throws {
        let paneAdmission = try BridgeProductAdmissionTestContext.make()
        let installationGate = BridgeProductAdmissionGate()
        let installationAdmission = try #require(
            paneAdmission.context.withInstallation(installationGate)
        )
        let coordinator = BridgeReviewPublicationCoordinator()
        let prepared = try await makeReviewPreparedPublication(
            suffix: "retire-current-e1-pending",
            reviewGeneration: 1
        )
        _ = try #require(
            coordinator.stage(
                prepared,
                productAdmission: installationAdmission
            )
        )

        let didSupersede = coordinator.supersedePendingPublication(
            productAdmission: paneAdmission.context
        )

        #expect(didSupersede)
        #expect(coordinator.diagnosticSnapshot.pending == nil)
        #expect(coordinator.diagnosticSnapshot.active == nil)

        _ = coordinator.close()
        installationGate.close()
        paneAdmission.close()
    }

    @Test("foreign pane and retired E1 cannot supersede an installation-bound pending publication")
    func foreignPaneAndRetiredInstallationCannotSupersedePendingPublication() async throws {
        let paneAdmission = try BridgeProductAdmissionTestContext.make()
        let installationGate = BridgeProductAdmissionGate()
        let installationAdmission = try #require(
            paneAdmission.context.withInstallation(installationGate)
        )
        let foreignPaneAdmission = try BridgeProductAdmissionTestContext.make()
        let coordinator = BridgeReviewPublicationCoordinator()
        let prepared = try await makeReviewPreparedPublication(
            suffix: "reject-foreign-retired-supersede",
            reviewGeneration: 1
        )
        let token = try #require(
            coordinator.stage(
                prepared,
                productAdmission: installationAdmission
            )
        )

        #expect(
            !coordinator.supersedePendingPublication(
                productAdmission: foreignPaneAdmission.context
            )
        )
        #expect(coordinator.diagnosticSnapshot.pending?.publicationId == token.publicationId)

        installationGate.close()
        #expect(
            !coordinator.supersedePendingPublication(
                productAdmission: paneAdmission.context
            )
        )
        #expect(coordinator.diagnosticSnapshot.pending?.publicationId == token.publicationId)

        _ = coordinator.close()
        foreignPaneAdmission.close()
        paneAdmission.close()
    }
}
