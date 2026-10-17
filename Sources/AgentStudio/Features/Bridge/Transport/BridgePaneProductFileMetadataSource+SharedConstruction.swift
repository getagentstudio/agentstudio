import AgentStudioCore
import Foundation

extension BridgePaneProductFileMetadataSource {
    func currentSource() async throws(BridgeWorktreeFileRootAccessError) -> BridgeProductFileSourceCurrentResult {
        try await BridgeWorktreeFileRootAccess.validateRoot(authority.worktree.path)
        return .available(
            BridgeProductFileSourceSpec(
                currentAuthorityRepoId: authority.worktree.repoId,
                currentAuthorityRootPathToken: authority.worktree.stableKey,
                currentAuthorityWorktreeId: authority.worktree.id
            )
        )
    }

    func cancel(subscriptionId: String) async {
        guard let context = contextBySubscriptionId[subscriptionId] ?? retiringContextBySubscriptionId[subscriptionId]
        else { return }
        await releaseContext(subscriptionId: subscriptionId, expectedSource: context.productSource)
    }

    func diagnosticSnapshot() async -> BridgeFileMetadataSourceDiagnostics {
        let contexts = Array(contextBySubscriptionId.values)
        var manifestRowCount = 0
        for context in contexts {
            manifestRowCount += await context.manifestIndex.count
        }
        return BridgeFileMetadataSourceDiagnostics(
            descriptorCount: contexts.reduce(0) { $0 + $1.descriptorByPath.count },
            inFlightDescriptorCount: contexts.reduce(0) {
                $0 + $1.inFlightDescriptorInterestRevisionByPath.count
            },
            manifestRowCount: manifestRowCount,
            subscriptionCount: contexts.count
        )
    }

    func attachConstructionLease(
        _ constructionLease: BridgeSharedFileSnapshotConsumerLease,
        subscriptionId: String,
        productSource: BridgeProductFileSourceIdentity,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) -> Bool {
        foregroundWorkAdmission.withValidAdmission {
            productAdmission.withValidAdmission {
                guard var context = contextBySubscriptionId[subscriptionId],
                    context.productSource == productSource,
                    context.productAdmission.matches(productAdmission)
                else { return false }
                context.constructionLease = constructionLease
                contextBySubscriptionId[subscriptionId] = context
                return true
            } ?? false
        } ?? false
    }

    func applyPreparation(
        _ preparation: BridgeSharedFileSnapshotPreparation,
        subscriptionId: String,
        productSource: BridgeProductFileSourceIdentity,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) -> SubscriptionContext? {
        var preparedContext: SubscriptionContext?
        let didPrepare =
            foregroundWorkAdmission.withValidAdmission {
                productAdmission.withValidAdmission { () -> Bool in
                    guard var context = contextBySubscriptionId[subscriptionId],
                        context.productSource == productSource,
                        context.productAdmission.matches(productAdmission)
                    else { return false }
                    context.openedSource = context.openedSource.withIgnorePolicy(
                        preparation.ignorePolicy
                    )
                    contextBySubscriptionId[subscriptionId] = context
                    preparedContext = context
                    return true
                } ?? false
            }
        return didPrepare == true ? preparedContext : nil
    }

    func releaseContext(
        subscriptionId: String,
        expectedSource: BridgeProductFileSourceIdentity
    ) async {
        if let context = contextBySubscriptionId[subscriptionId], context.productSource == expectedSource {
            // Fence live publication immediately, while retaining the index's
            // counter for another cancel/open to finish the same handoff.
            contextBySubscriptionId.removeValue(forKey: subscriptionId)
            retiringContextBySubscriptionId[subscriptionId] = context
        }
        guard let context = retiringContextBySubscriptionId[subscriptionId],
            context.productSource == expectedSource
        else { return }
        let retiredRevision = await revisionFloorCapture(context.manifestIndex)
        guard retiringContextBySubscriptionId[subscriptionId]?.productSource == expectedSource else { return }
        // Publishing the floor and releasing its slot is one source-actor turn.
        // A successor cannot observe a removed context with the old seed.
        lastIssuedFileViewRevision = max(lastIssuedFileViewRevision, retiredRevision)
        retiringContextBySubscriptionId.removeValue(forKey: subscriptionId)
        await context.manifestIndex.revokeRetainedDescriptors()
        if let constructionLease = context.constructionLease {
            await sharedConstructionBinder.release(constructionLease)
        }
    }

    func isCurrent(
        subscriptionId: String,
        source: BridgeProductFileSourceIdentity,
        productAdmission: BridgeProductAdmissionContext
    ) -> Bool {
        guard let context = contextBySubscriptionId[subscriptionId] else { return false }
        return context.productSource == source
            && context.productAdmission.matches(productAdmission)
    }

    func publishCurrentStatus(
        _ statusResult: GitWorkingTreeStatusResult,
        emit: BridgePaneProductFileSourceFactSink,
        productAdmission: BridgeProductAdmissionContext,
        productSource: BridgeProductFileSourceIdentity,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws {
        guard
            let index = contextBySubscriptionId.values.first(where: {
                $0.productSource == productSource && $0.productAdmission.matches(productAdmission)
            })?.manifestIndex
        else { return }
        switch statusResult {
        case .available(let status):
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true,
                (productAdmission.withValidAdmission { true }) == true
            else { return }
            guard
                try await index.updateMemberStatus(
                    state: .ready,
                    branchName: status.branch,
                    ahead: status.summary.aheadCount,
                    behind: status.summary.behindCount,
                    staged: status.summary.staged,
                    unstaged: status.summary.changed,
                    untracked: status.summary.untracked,
                    productAdmission: productAdmission
                )
            else { return }
            try await emit(
                .statusChanged(productSource)
            )
        case .unavailable:
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true,
                (productAdmission.withValidAdmission { true }) == true
            else { return }
            guard
                try await index.updateMemberStatus(
                    state: .stale,
                    branchName: nil,
                    ahead: nil,
                    behind: nil,
                    staged: nil,
                    unstaged: nil,
                    untracked: nil,
                    productAdmission: productAdmission
                )
            else { return }
            try await emit(
                .statusChanged(productSource)
            )
        }
    }
}
