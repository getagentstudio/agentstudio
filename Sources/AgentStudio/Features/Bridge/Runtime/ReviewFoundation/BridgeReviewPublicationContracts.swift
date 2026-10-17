import AgentStudioInfrastructure
import Foundation

/// Raw Sendable Review publication input that can cross to off-main preparation.
struct BridgeReviewPublicationCandidate: Equatable, Sendable {
    let package: BridgeReviewPackage
    let delta: BridgeReviewDelta?
    let contentHandles: [BridgeContentHandle]
    let artifactPin: BridgeReviewPublicationArtifactPin?
    let classifiedRefreshImpact: BridgeReviewRefreshImpact?

    init(
        package: BridgeReviewPackage,
        delta: BridgeReviewDelta?,
        contentHandles: [BridgeContentHandle],
        artifactPin: BridgeReviewPublicationArtifactPin? = nil,
        classifiedRefreshImpact: BridgeReviewRefreshImpact? = nil
    ) {
        self.package = package
        self.delta = delta
        self.contentHandles = contentHandles
        self.artifactPin = artifactPin
        self.classifiedRefreshImpact = classifiedRefreshImpact
    }
}

struct BridgeReviewPublicationToken: Hashable, Sendable {
    let publicationId: UUID
    let operationCorrelationID: String?
}

struct BridgeReviewCommittedPublication: Equatable, Sendable {
    let publicationId: UUID
    let package: BridgeReviewPackage
    let delta: BridgeReviewDelta?
    let contentHandles: [BridgeContentHandle]
    let comparisonPresentationRevision: Int
    let reviewComparison: BridgePaneReviewComparisonPresentation?
    let operationCorrelationID: String?
    let classifiedRefreshImpact: BridgeReviewRefreshImpact?

    init(
        publicationId: UUID,
        package: BridgeReviewPackage,
        delta: BridgeReviewDelta?,
        contentHandles: [BridgeContentHandle],
        comparisonPresentationRevision: Int,
        reviewComparison: BridgePaneReviewComparisonPresentation?,
        operationCorrelationID: String? = nil,
        classifiedRefreshImpact: BridgeReviewRefreshImpact? = nil
    ) {
        self.publicationId = publicationId
        self.package = package
        self.delta = delta
        self.contentHandles = contentHandles
        self.comparisonPresentationRevision = comparisonPresentationRevision
        self.reviewComparison = reviewComparison
        self.operationCorrelationID = operationCorrelationID
        self.classifiedRefreshImpact = classifiedRefreshImpact
    }

    var retainedReplay: Self {
        Self(
            publicationId: publicationId,
            package: package,
            delta: delta,
            contentHandles: contentHandles,
            comparisonPresentationRevision: comparisonPresentationRevision,
            reviewComparison: reviewComparison,
            operationCorrelationID: nil,
            classifiedRefreshImpact: classifiedRefreshImpact
        )
    }
}

enum BridgeReviewPublicationDeliveryDisposition: Equatable, Sendable {
    case deferred
    case failed
    case viewBatchSealed
}

enum BridgeReviewPublicationOutcome: Equatable, Sendable {
    case rejectedBeforeCommit
    case superseded
    case closed
    case committed(delivery: BridgeReviewPublicationDeliveryDisposition)
}

enum BridgeReviewPublicationCommitResult: Equatable, Sendable {
    case committed(BridgeReviewCommittedPublication)
    case superseded
    case closed
}

struct BridgeReviewPublicationDiagnostic: Equatable, Sendable {
    let publicationId: UUID
    let packageId: String
    let reviewGeneration: BridgeReviewGeneration
    let revision: Int
}

struct BridgeReviewPublicationStateSnapshot: Equatable, Sendable {
    let active: BridgeReviewPublicationDiagnostic?
    let acknowledgedDisplayed: BridgeReviewPublicationDiagnostic?
    let admitted: BridgeReviewPublicationDiagnostic?
    let pending: BridgeReviewPublicationDiagnostic?
    let retiring: [BridgeReviewPublicationDiagnostic]
    let activeContentLeaseCount: Int
    let isClosed: Bool
}

enum BridgeReviewDisplayInstallAdmissionResult: Equatable, Sendable {
    case admitted
    case rejected
}

enum BridgeReviewDisplayedApplicationResult: Equatable, Sendable {
    case advanced
    case duplicate
    case rejected
}

struct BridgeReviewPublicationCloseDrain: Sendable {
    let artifactPins: [BridgeReviewPublicationArtifactPin]
    let priorReleaseTask: Task<Void, Never>?

    func releaseAndWait() async {
        await withTaskGroup(of: Void.self) { taskGroup in
            if let priorReleaseTask {
                taskGroup.addTask {
                    await priorReleaseTask.value
                }
            }
            for artifactPin in artifactPins {
                taskGroup.addTask {
                    await artifactPin.releaseAndWait()
                }
            }
        }
    }

    static let empty = Self(artifactPins: [], priorReleaseTask: nil)
}
