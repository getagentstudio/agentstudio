import Foundation

actor BridgePaneProductContentDemandAuthority {
    private let fileMetadataSource: any BridgePaneProductFileMetadataProducing
    private let reviewContentSource: any BridgePaneProductReviewContentProducing
    private var fileDemandBySubscriptionId:
        [String: (admissionSequence: Int, state: BridgeProductFileMetadataInterestState)] = [:]
    private var reviewDemandBySubscriptionId:
        [String: (admissionSequence: Int, state: BridgeProductReviewMetadataInterestState)] = [:]

    init(
        fileMetadataSource: any BridgePaneProductFileMetadataProducing,
        reviewContentSource: any BridgePaneProductReviewContentProducing
    ) {
        self.fileMetadataSource = fileMetadataSource
        self.reviewContentSource = reviewContentSource
    }

    func apply(
        _ effect: BridgeProductSessionCompletionEffect,
        productAdmission: BridgeProductAdmissionContext
    ) {
        switch effect {
        case .subscriptionOpened:
            break
        case .subscriptionCancelled(let subscription):
            removeDemand(subscriptionId: subscription.subscriptionId)
        case .resynced(let result):
            for outcome in result.reconciliation {
                switch outcome {
                case .retained:
                    break
                case .cancelled, .reopenRequired:
                    removeDemand(subscriptionId: outcome.subscriptionId)
                }
            }
            for subscriptionId in result.revokedNativeOnlySubscriptionIds {
                removeDemand(subscriptionId: subscriptionId)
            }
        case .viewScopeAccepted(let request):
            guard productAdmission.withValidAdmission({ true }) == true else { return }
            switch request.subscriptionKind {
            case .fileMetadata:
                if let state = try? BridgeProductViewScopeContract.fileDemand(from: request.scope),
                    request.correlation.requestSequence
                        > (fileDemandBySubscriptionId[request.subscriptionId]?.admissionSequence ?? 0)
                {
                    fileDemandBySubscriptionId[request.subscriptionId] = (request.correlation.requestSequence, state)
                }
            case .reviewMetadata:
                if let state = try? BridgeProductViewScopeContract.reviewDemand(from: request.scope),
                    request.correlation.requestSequence
                        > (reviewDemandBySubscriptionId[request.subscriptionId]?.admissionSequence ?? 0)
                {
                    reviewDemandBySubscriptionId[request.subscriptionId] = (request.correlation.requestSequence, state)
                }
            case .fileAnnotations, .reviewAnnotations:
                break
            default:
                break
            }
        case .noEffect, .productCall, .viewResnapshotAccepted:
            break
        }
    }

    private func removeDemand(subscriptionId: String) {
        fileDemandBySubscriptionId.removeValue(forKey: subscriptionId)
        reviewDemandBySubscriptionId.removeValue(forKey: subscriptionId)
    }

    func removeAll() {
        fileDemandBySubscriptionId.removeAll(keepingCapacity: false)
        reviewDemandBySubscriptionId.removeAll(keepingCapacity: false)
    }

    func interest(
        for request: BridgeProductContentRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeContentDemandInterest {
        let highestLane: BridgeProductDemandLane?
        switch request {
        case .annotationOutput, .annotationProjection:
            return .selected
        case .fileContent(let fileRequest):
            guard
                let path = await fileMetadataSource.authoritativePath(
                    for: fileRequest,
                    productAdmission: productAdmission
                )
            else {
                return .unspecified
            }
            guard
                let admittedHighestLane = productAdmission.withValidAdmission({
                    highestFileDemandLane(for: path)
                })
            else { return .unspecified }
            highestLane = admittedHighestLane
        case .reviewContent(let reviewRequest):
            guard
                let itemId = await reviewContentSource.authoritativeItemId(
                    for: reviewRequest,
                    productAdmission: productAdmission
                )
            else {
                return .unspecified
            }
            guard
                let admittedHighestLane = productAdmission.withValidAdmission({
                    highestReviewDemandLane(for: itemId)
                })
            else { return .unspecified }
            highestLane = admittedHighestLane
        case .reviewComparisonTargets:
            return .selected
        }
        return highestLane.map(Self.contentDemandInterest(for:)) ?? .unspecified
    }

    private func highestFileDemandLane(for path: String) -> BridgeProductDemandLane? {
        var highestLane: BridgeProductDemandLane?
        for demand in fileDemandBySubscriptionId.values {
            let interests = demand.state.interests
            for interest in interests where interest.paths.contains(path) {
                highestLane = Self.higherPriorityLane(highestLane, interest.lane)
            }
        }
        return highestLane
    }

    private func highestReviewDemandLane(for itemId: String) -> BridgeProductDemandLane? {
        var highestLane: BridgeProductDemandLane?
        for demand in reviewDemandBySubscriptionId.values {
            let interests = demand.state.interests
            for interest in interests where interest.itemIds.contains(itemId) {
                highestLane = Self.higherPriorityLane(highestLane, interest.lane)
            }
        }
        return highestLane
    }

    private static func higherPriorityLane(
        _ current: BridgeProductDemandLane?,
        _ candidate: BridgeProductDemandLane
    ) -> BridgeProductDemandLane {
        guard let current else { return candidate }
        return contentDemandPriority(candidate) < contentDemandPriority(current)
            ? candidate
            : current
    }

    private static func contentDemandInterest(
        for lane: BridgeProductDemandLane
    ) -> BridgeContentDemandInterest {
        switch lane {
        case .foreground, .active: .selected
        case .visible: .visible
        case .nearby: .nearby
        case .speculative: .speculative
        case .idle: .background
        }
    }

    private static func contentDemandPriority(_ lane: BridgeProductDemandLane) -> Int {
        switch lane {
        case .foreground, .active: 0
        case .visible: 1
        case .nearby: 2
        case .speculative: 3
        case .idle: 4
        }
    }
}
