import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Bridge Review recovery admission fence")
struct BridgeReviewPublicationRecoveryAdmissionTests {
    @Test(
        "same worker replaces unapplied B with recovery C under the unchanged displayed fence",
        arguments: [false, true])
    func sameWorkerAbandonsUnappliedAdmission(withDisplayedPredecessor: Bool) async throws {
        try await withRecoveryAdmissionFixture(withDisplayedPredecessor: withDisplayedPredecessor) { fixture in
            let admission = fixture.coordinator.admitDisplayInstallation(
                expectedDisplayedPublicationId: fixture.displayedPublication?.publicationId,
                candidatePublicationId: fixture.recoveryPublication.publicationId,
                workerInstanceId: "worker-1",
                productAdmission: fixture.productAdmission
            )
            try #require(admission == .admitted)
            let snapshot = fixture.coordinator.diagnosticSnapshot
            #expect(snapshot.admitted?.publicationId == fixture.recoveryPublication.publicationId)
            #expect(snapshot.acknowledgedDisplayed?.publicationId == fixture.displayedPublication?.publicationId)
            #expect(!snapshot.retiring.contains { $0.publicationId == fixture.admittedPublication.publicationId })
            #expect(
                fixture.coordinator.recordDisplayedApplication(
                    publicationId: fixture.admittedPublication.publicationId,
                    workerInstanceId: "worker-1",
                    productAdmission: fixture.productAdmission
                ) == .rejected
            )
            #expect(
                fixture.coordinator.recordDisplayedApplication(
                    publicationId: fixture.recoveryPublication.publicationId,
                    workerInstanceId: "worker-1",
                    productAdmission: fixture.productAdmission
                ) == .advanced
            )
        }
    }

    @Test("honest page showing B cannot admit C until the lost B receipt settles", arguments: [false, true])
    func appliedPublicationWithLostReceiptKeepsItsFence(withDisplayedPredecessor: Bool) async throws {
        try await withRecoveryAdmissionFixture(withDisplayedPredecessor: withDisplayedPredecessor) { fixture in
            // Page installed B; native still knows the prior display because B's receipt was lost.
            #expect(
                fixture.coordinator.admitDisplayInstallation(
                    expectedDisplayedPublicationId: fixture.admittedPublication.publicationId,
                    candidatePublicationId: fixture.recoveryPublication.publicationId,
                    workerInstanceId: "worker-1",
                    productAdmission: fixture.productAdmission
                ) == .rejected
            )
            #expect(
                fixture.coordinator.diagnosticSnapshot.admitted?.publicationId
                    == fixture.admittedPublication.publicationId)
            #expect(
                fixture.coordinator.recordDisplayedApplication(
                    publicationId: fixture.admittedPublication.publicationId,
                    workerInstanceId: "worker-1",
                    productAdmission: fixture.productAdmission
                ) == .advanced
            )
            #expect(
                fixture.coordinator.admitDisplayInstallation(
                    expectedDisplayedPublicationId: fixture.admittedPublication.publicationId,
                    candidatePublicationId: fixture.recoveryPublication.publicationId,
                    workerInstanceId: "worker-1",
                    productAdmission: fixture.productAdmission
                ) == .admitted
            )
        }
    }

    @Test(
        "different worker cannot replace a foreign pin and keeps the existing retirement path",
        arguments: [false, true])
    func differentWorkerRequiresExistingRetirement(withDisplayedPredecessor: Bool) async throws {
        try await withRecoveryAdmissionFixture(withDisplayedPredecessor: withDisplayedPredecessor) { fixture in
            #expect(
                fixture.coordinator.admitDisplayInstallation(
                    expectedDisplayedPublicationId: fixture.displayedPublication?.publicationId,
                    candidatePublicationId: fixture.recoveryPublication.publicationId,
                    workerInstanceId: "worker-2",
                    productAdmission: fixture.productAdmission
                ) == .rejected
            )
            #expect(
                fixture.coordinator.diagnosticSnapshot.admitted?.publicationId
                    == fixture.admittedPublication.publicationId)
            fixture.coordinator.retireDisplayWorker(workerInstanceId: "worker-1")
            #expect(
                fixture.coordinator.admitDisplayInstallation(
                    expectedDisplayedPublicationId: nil,
                    candidatePublicationId: fixture.recoveryPublication.publicationId,
                    workerInstanceId: "worker-2",
                    productAdmission: fixture.productAdmission
                ) == .admitted
            )
            #expect(
                fixture.coordinator.recordDisplayedApplication(
                    publicationId: fixture.recoveryPublication.publicationId,
                    workerInstanceId: "worker-2",
                    productAdmission: fixture.productAdmission
                ) == .advanced
            )
        }
    }
}

private struct ReviewRecoveryAdmissionFixture {
    let coordinator: BridgeReviewPublicationCoordinator
    let productAdmission: BridgeProductAdmissionContext
    let displayedPublication: BridgeReviewCommittedPublication?
    let admittedPublication: BridgeReviewCommittedPublication
    let recoveryPublication: BridgeReviewCommittedPublication
}

@MainActor
private func withRecoveryAdmissionFixture(
    withDisplayedPredecessor: Bool,
    operation: @MainActor (ReviewRecoveryAdmissionFixture) async throws -> Void
) async throws {
    let productAdmission = try BridgeProductAdmissionTestContext.make()
    let coordinator = BridgeReviewPublicationCoordinator()
    do {
        var displayedPublication: BridgeReviewCommittedPublication?
        if withDisplayedPredecessor {
            let prepared = try await makeReviewPreparedPublication(suffix: "recovery-displayed-a", reviewGeneration: 1)
            let committed = try commitObserved(prepared, in: coordinator, productAdmission: productAdmission.context)
            try #require(
                coordinator.admitDisplayInstallation(
                    expectedDisplayedPublicationId: nil,
                    candidatePublicationId: committed.publicationId,
                    workerInstanceId: "worker-1",
                    productAdmission: productAdmission.context
                ) == .admitted
            )
            try #require(
                coordinator.recordDisplayedApplication(
                    publicationId: committed.publicationId,
                    workerInstanceId: "worker-1",
                    productAdmission: productAdmission.context
                ) == .advanced
            )
            displayedPublication = committed
        }
        let prepared = try await makeReviewPreparedPublication(suffix: "recovery-admitted-b", reviewGeneration: 2)
        let admittedPublication = try commitObserved(
            prepared, in: coordinator, productAdmission: productAdmission.context)
        try #require(
            coordinator.admitDisplayInstallation(
                expectedDisplayedPublicationId: displayedPublication?.publicationId,
                candidatePublicationId: admittedPublication.publicationId,
                workerInstanceId: "worker-1",
                productAdmission: productAdmission.context
            ) == .admitted
        )
        let recovery = try await makeReviewPreparedPublication(suffix: "recovery-current-c", reviewGeneration: 3)
        let recoveryPublication = try commitObserved(
            recovery, in: coordinator, productAdmission: productAdmission.context)
        try await operation(
            ReviewRecoveryAdmissionFixture(
                coordinator: coordinator,
                productAdmission: productAdmission.context,
                displayedPublication: displayedPublication,
                admittedPublication: admittedPublication,
                recoveryPublication: recoveryPublication
            )
        )
    } catch {
        productAdmission.close()
        await coordinator.close().releaseAndWait()
        throw error
    }
    productAdmission.close()
    await coordinator.close().releaseAndWait()
}
