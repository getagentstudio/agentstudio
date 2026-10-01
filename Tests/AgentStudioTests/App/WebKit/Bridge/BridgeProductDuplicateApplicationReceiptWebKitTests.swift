import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.BridgeProductRealGitFileAndReviewWebKitTests {
    @Test("same-worker duplicate A receipt does not advance the displayed publication")
    func sameWorkerDuplicateApplicationDoesNotAdvanceDisplayedPublication() async throws {
        let repoURL = try await FilesystemTestGitRepo.create(named: "bridge-duplicate-application-webkit")
        defer { FilesystemTestGitRepo.destroy(repoURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repoURL)
        try seedMultiWindowReviewChanges(at: repoURL)
        let harness = makeTransactionalPublicationHarness(repoURL: repoURL)
        let run = try await BridgeProductWebKitCarrierTestSupport.withHostedController(
            harness.controller
        ) { controller in
            controller.loadApp()
            try await waitForMetadataSubscriptions(harness)
            let checkpoint = try await prepareFirstPublicationCheckpoint(controller: controller, harness: harness)
            let before = controller.reviewPublicationCoordinator.diagnosticSnapshot
            let receiptCountBefore = harness.controllerTarget.applicationReceipts.count
            let result = harness.controllerTarget.recordApplication(
                checkpoint.publication.publicationId,
                workerInstanceId: harness.installation.bootstrap.workerInstanceId,
                productAdmission: harness.productAdmission
            )
            let after = controller.reviewPublicationCoordinator.diagnosticSnapshot
            #expect(result == .duplicate)
            #expect(after.acknowledgedDisplayed?.publicationId == before.acknowledgedDisplayed?.publicationId)
            #expect(after.admitted == nil)
            #expect(harness.controllerTarget.applicationReceipts.count == receiptCountBefore + 1)
            #expect(
                harness.controllerTarget.applicationReceipts.last
                    == BridgeProductWebKitCarrierApplicationReceipt(
                        applicationResult: .duplicate, publicationId: checkpoint.publication.publicationId
                    )
            )
            assertReviewApplicationReceiptAdvances(
                harness.controllerTarget.applicationReceipts,
                expectedPublicationIds: [checkpoint.publication.publicationId]
            )
            #expect(controller.reviewPublicationCoordinator.settleContentLease(checkpoint.retiringLease))
        }
        #expect(run.teardownSnapshot.hasZeroResidue)
    }
}
