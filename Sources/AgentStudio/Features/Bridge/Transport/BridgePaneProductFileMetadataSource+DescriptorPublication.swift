import Foundation
import Synchronization

extension BridgePaneProductFileMetadataSource {
    func changesetEmissionsWithRenewedDescriptors(
        _ changesetEmissions: [BridgePaneProductFileMetadataEmission],
        renewalEmissions: [BridgePaneProductFileMetadataEmission]
    ) throws -> [BridgePaneProductFileMetadataEmission] {
        let renewedByPath = renewalEmissions.reduce(
            into: [String: BridgeProductFileDescriptorReadyPayload]()
        ) { payloads, emission in
            if case .descriptorReady(let ready) = emission.fact {
                payloads[ready.path] = ready
            }
        }
        var attachedPaths = Set<String>()
        let changesets = try changesetEmissions.map { emission in
            guard case .invalidated(let invalidation) = emission.fact,
                let replacement = renewedByPath[invalidation.path],
                replacement.source == invalidation.source
            else { return emission }
            attachedPaths.insert(invalidation.path)
            return BridgePaneProductFileMetadataEmission(
                fact: .invalidated(
                    try .init(
                        fileId: invalidation.fileId,
                        path: invalidation.path,
                        reason: invalidation.reason,
                        replacementDescriptor: replacement,
                        source: invalidation.source
                    )
                ),
                subscriptionId: emission.subscriptionId
            )
        }
        // One invalidation carries the replacement, rather than deleting then re-adding it.
        // Other renewal events still carry their normal tree and unavailable-path facts.
        return changesets
            + renewalEmissions.filter { emission in
                guard case .descriptorReady(let ready) = emission.fact else { return true }
                return !attachedPaths.contains(ready.path)
            }
    }

    func renewInvalidatedDescriptorInterests(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] {
        // This call-local buffer adapts the existing streaming renewal to changeset publication.
        // The source's descriptor-revision index admits only missing or invalidated interests.
        let emissions = Mutex<[BridgePaneProductFileMetadataEmission]>([])
        guard let demand = contextBySubscriptionId[subscription.subscriptionId]?.viewDemand else {
            return []
        }
        try await applyViewDemand(
            subscriptionId: subscription.subscriptionId,
            demand: demand,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            forceRecapture: false
        ) { event in
            emissions.withLock {
                $0.append(.init(fact: event, subscriptionId: subscription.subscriptionId))
            }
        }
        return emissions.withLock { $0 }
    }

    struct DescriptorInterestCommit: Sendable {
        let committedPayload: BridgeProductFileDescriptorReadyPayload
        let committedRevision: Int
        let committedDemand: BridgePaneProductFileViewDemand
        let previousPayload: BridgeProductFileDescriptorReadyPayload?
        let previousRevision: Int?
    }

    func commitDescriptorInterest(
        _ materialized: BridgePaneProductFileDescriptorMaterialization,
        for row: BridgeWorktreeTreeRowMetadata,
        request: DescriptorReconciliationRequest
    ) -> DescriptorInterestCommit? {
        request.foregroundWorkAdmission.withValidAdmission({
            request.productAdmission.withValidAdmission {
                guard var currentContext = contextBySubscriptionId[request.subscriptionId],
                    currentContext.productSource == request.productSource,
                    currentContext.productAdmission.matches(request.productAdmission),
                    currentContext.viewDemand == request.demand,
                    currentContext.demandGeneration == request.demandGeneration,
                    currentContext.inFlightDescriptorInterestRevisionByPath[row.path]
                        == request.demandGeneration
                else { return nil }
                let commit = DescriptorInterestCommit(
                    committedPayload: materialized.payload,
                    committedRevision: request.demandGeneration,
                    committedDemand: request.demand,
                    previousPayload: currentContext.descriptorByPath[row.path],
                    previousRevision: currentContext.descriptorInterestRevisionByPath[row.path]
                )
                currentContext.inFlightDescriptorInterestRevisionByPath.removeValue(forKey: row.path)
                currentContext.descriptorInterestRevisionByPath[row.path] =
                    request.demandGeneration
                currentContext.descriptorByPath[row.path] = materialized.payload
                contextBySubscriptionId[request.subscriptionId] = currentContext
                return commit
            }.flatMap { $0 }
        }).flatMap { $0 }
    }

    func descriptorInterestCommitIsCurrent(
        _ commit: DescriptorInterestCommit,
        for row: BridgeWorktreeTreeRowMetadata,
        request: DescriptorReconciliationRequest
    ) -> Bool {
        request.foregroundWorkAdmission.withValidAdmission({
            request.productAdmission.withValidAdmission {
                guard let currentContext = contextBySubscriptionId[request.subscriptionId]
                else { return false }
                return currentContext.productSource == request.productSource
                    && currentContext.productAdmission.matches(request.productAdmission)
                    && currentContext.viewDemand == commit.committedDemand
                    && currentContext.demandGeneration == commit.committedRevision
                    && currentContext.descriptorInterestRevisionByPath[row.path]
                        == commit.committedRevision
                    && currentContext.descriptorByPath[row.path] == commit.committedPayload
            } ?? false
        }) == true
    }

    func rollbackDescriptorInterest(
        _ commit: DescriptorInterestCommit,
        for row: BridgeWorktreeTreeRowMetadata,
        request: DescriptorReconciliationRequest
    ) {
        let subscriptionId = request.subscriptionId
        guard var currentContext = contextBySubscriptionId[subscriptionId],
            currentContext.productSource == request.productSource,
            currentContext.productAdmission.matches(request.productAdmission),
            currentContext.descriptorInterestRevisionByPath[row.path]
                == commit.committedRevision,
            currentContext.descriptorByPath[row.path] == commit.committedPayload
        else { return }

        if currentContext.viewDemand == commit.committedDemand,
            currentContext.demandGeneration == commit.committedRevision
        {
            currentContext.descriptorInterestRevisionByPath[row.path] = commit.previousRevision
            currentContext.descriptorByPath[row.path] = commit.previousPayload
        } else {
            currentContext.descriptorInterestRevisionByPath.removeValue(forKey: row.path)
            currentContext.descriptorByPath.removeValue(forKey: row.path)
        }
        contextBySubscriptionId[subscriptionId] = currentContext
    }
}
