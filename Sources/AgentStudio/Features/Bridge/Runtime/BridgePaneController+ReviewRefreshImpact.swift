import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@MainActor
extension BridgePaneController {
    func commitClassifiedReviewPackageRefresh(
        _ load: BridgeReviewPackageLoadData,
        refreshGeneration: BridgeReviewGeneration,
        reservation: BridgePaneRefreshCatchUpReservation,
        productAdmission: BridgeProductAdmissionContext,
        packageTraceContext: BridgeTraceContext?,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> BridgePaneRefreshCatchUpOutcome {
        let contentRegisterStart = ContinuousClock.now
        await recordReviewContentRegisterTelemetry(
            traceContext: packageTraceContext,
            contentRegisterStart: contentRegisterStart
        )
        guard productAdmission.withValidAdmission({ isReviewShownByPage }) == true else { return .stale }
        let disposition = await commitReviewPackageLoad(
            load,
            expectedReviewGeneration: refreshGeneration,
            expectedReviewAuthorityGeneration: reservation.authorityGeneration,
            operationCorrelationID: reservation.operationCorrelationID,
            productAdmission: productAdmission,
            traceContext: packageTraceContext,
            foregroundWorkAdmission: foregroundWorkAdmission
        )
        guard case .committed = disposition else {
            return failCurrentReviewComparisonRefresh(
                refreshGeneration,
                failureKind: "publicationRejected",
                reservation: reservation,
                foregroundWorkAdmission: foregroundWorkAdmission,
                productAdmission: productAdmission
            )
        }
        return .succeeded
    }

    func classifyReviewPackageRefresh(
        _ load: BridgeReviewPackageLoadData,
        currentPublication: BridgeReviewCommittedPublication,
        refreshGeneration: BridgeReviewGeneration,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        productAdmission: BridgeProductAdmissionContext,
        reservation: BridgePaneRefreshCatchUpReservation
    ) async throws -> BridgeReviewPackageLoadData? {
        let classificationStartedAt = ContinuousClock.now
        let displayedPublication = reviewPublicationCoordinator.acknowledgedDisplayedPublication(
            productAdmission: productAdmission
        )
        let expectedDisplayedPublicationId = displayedPublication?.publicationId
        let impact: BridgeReviewRefreshImpact
        if let displayedPublication,
            let impactProvider = reviewSourceProvider as? any BridgeReviewRefreshImpactSourceProvider
        {
            impact = try await impactProvider.measureRefreshImpact(
                displayedPackage: displayedPublication.package,
                candidatePackage: load.package,
                candidateGeneration: refreshGeneration
            )
        } else {
            impact = .unknown(
                displayedPackage: displayedPublication?.package,
                candidatePackage: load.package
            )
        }
        guard productAdmission.withValidAdmission({ isReviewShownByPage }) == true,
            !Task.isCancelled,
            foregroundWorkAdmission.withValidAdmission({ true }) == true,
            refreshAdmissionCoordinator.isRefreshPassCurrent(reservation),
            refreshGeneration == nextReviewGeneration,
            reviewPublicationCoordinator.isCurrentPublication(
                publicationId: currentPublication.publicationId,
                productAdmission: productAdmission
            ),
            reviewPublicationCoordinator.acknowledgedDisplayedPublication(
                productAdmission: productAdmission
            )?.publicationId == expectedDisplayedPublicationId
        else { return nil }
        await recordReviewRefreshClassification(
            impact,
            generation: refreshGeneration,
            duration: ContinuousClock.now - classificationStartedAt
        )
        return load.classified(with: impact)
    }

    private func recordReviewRefreshClassification(
        _ impact: BridgeReviewRefreshImpact,
        generation: BridgeReviewGeneration,
        duration: Duration
    ) async {
        guard let telemetryRecorder else { return }
        let presentationClass: String
        let resultReason: BridgeReviewRefreshLifecycleTraceEvent.ResultReason
        switch impact.preDeliveryPresentationClass {
        case .ordinary:
            presentationClass = "ordinary"
            resultReason = .noReason
        case .promoted(let reason):
            presentationClass = "promoted"
            resultReason =
                switch reason {
                case .commits: .commits
                case .files: .files
                case .lines: .lines
                case .unknown: .unknown
                }
        }
        let changedLineCount = impact.addedLineCount.flatMap { addedLineCount in
            impact.deletedLineCount.flatMap { deletedLineCount in
                let sum = addedLineCount.addingReportingOverflow(deletedLineCount)
                return sum.overflow ? nil : sum.partialValue
            }
        }
        await BridgeReviewRefreshLifecycleTraceRecorder(recorder: telemetryRecorder).record(
            BridgeReviewRefreshLifecycleTraceEvent(
                phase: .classified,
                resultReason: resultReason,
                presentationClass: presentationClass,
                reviewGeneration: generation.rawValue,
                importedCommitCount: impact.newlyImportedCommitCount,
                affectedFileCount: impact.affectedFileCount,
                changedLineCount: changedLineCount,
                affectedStableFileCount: impact.affectedStableFileIdentities.count,
                retainedPublicationCount: nil,
                sourceLeaseCount: nil,
                durationMilliseconds: milliseconds(from: duration),
                traceContext: lastReviewPackageTraceContext
            )
        )
    }

    private func milliseconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
