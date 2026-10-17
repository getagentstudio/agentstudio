import AgentStudioCore
import Foundation

extension BridgePaneProductFileMetadataSource {
    private struct CanonicalFileViewDemand {
        let pathScope: [String]
        let lanesByPath: [String: BridgeProductDemandLane]
    }

    private struct FileViewDemandAdmission {
        let subscriptionId: String
        let demand: BridgePaneProductFileViewDemand
        let expectedSource: BridgeProductFileSourceIdentity
        let canonicalPathScope: [String]
        let productAdmission: BridgeProductAdmissionContext
        let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
        let forceRecapture: Bool
    }

    func applyViewDemand(
        subscriptionId: String,
        demand: BridgePaneProductFileViewDemand,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        forceRecapture: Bool,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        guard let initialContext = contextBySubscriptionId[subscriptionId],
            let sourceSpec = initialContext.subscription.subscription.fileMetadataSource
        else { return }
        let canonicalDemand = try resolveCanonicalViewDemand(
            initialContext: initialContext,
            sourceSpec: sourceSpec,
            subscriptionId: subscriptionId,
            demand: demand
        )
        guard
            let context = acceptViewDemandContext(
                .init(
                    subscriptionId: subscriptionId,
                    demand: demand,
                    expectedSource: initialContext.productSource,
                    canonicalPathScope: canonicalDemand.pathScope,
                    productAdmission: productAdmission,
                    foregroundWorkAdmission: foregroundWorkAdmission,
                    forceRecapture: forceRecapture
                )
            )
        else { return }
        let productSource = context.productSource
        // Record interest while the inventory is frozen; post-open reconciliation enriches it.
        guard !context.initialEnumerationInFlight else { return }

        let demandedPaths = canonicalDemand.lanesByPath.filter { path, _ in
            context.descriptorInterestRevisionByPath[path] != context.demandGeneration
                && context.inFlightDescriptorInterestRevisionByPath[path] != context.demandGeneration
        }
        guard !demandedPaths.isEmpty else { return }
        let manifestPaths = await context.manifestIndex.memberPaths(of: Set(demandedPaths.keys))
        try Task.checkCancellation()
        guard
            isCurrent(
                subscriptionId: subscriptionId, demand: demand,
                demandGeneration: context.demandGeneration, source: productSource,
                productAdmission: productAdmission),
            foregroundWorkAdmission.withValidAdmission({ true }) == true,
            (productAdmission.withValidAdmission { true }) == true
        else { return }
        let refreshed = await treeRowRefresher(authority.worktree.path, manifestPaths, false)
        let refreshedFilePaths = Set(
            refreshed.rows.lazy.filter { !$0.isDirectory }.map(\.path)
        )
        let descriptorUnavailablePaths = manifestPaths.subtracting(refreshedFilePaths)
        try Task.checkCancellation()
        guard
            isCurrent(
                subscriptionId: subscriptionId, demand: demand,
                demandGeneration: context.demandGeneration, source: productSource,
                productAdmission: productAdmission),
            foregroundWorkAdmission.withValidAdmission({ true }) == true,
            await context.manifestIndex.applyRefreshedRows(
                refreshed.rows,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else { return }
        guard
            case .applied = await context.manifestIndex.removePaths(
                refreshed.missingPaths,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else { return }
        try Task.checkCancellation()
        guard
            isCurrent(
                subscriptionId: subscriptionId, demand: demand,
                demandGeneration: context.demandGeneration, source: productSource,
                productAdmission: productAdmission),
            foregroundWorkAdmission.withValidAdmission({ true }) == true,
            (productAdmission.withValidAdmission { true }) == true
        else { return }

        let refreshRequest = RefreshedTreeDeltaRequest(
            demandedPaths: demandedPaths,
            emit: emit,
            foregroundWorkAdmission: foregroundWorkAdmission,
            productAdmission: productAdmission,
            productSource: productSource,
            rows: refreshed.rows,
            subscriptionId: subscriptionId,
            demand: demand,
            demandGeneration: context.demandGeneration
        )
        guard try await emitRefreshedTreeDeltas(refreshRequest) else { return }
        try await reconcileRefreshedDescriptors(
            refreshRequest,
            unavailablePaths: descriptorUnavailablePaths
        )
    }

    private func acceptViewDemandContext(_ admission: FileViewDemandAdmission) -> SubscriptionContext? {
        var acceptedContext: SubscriptionContext?
        let didAcceptContext =
            admission.foregroundWorkAdmission.withValidAdmission {
                admission.productAdmission.withValidAdmission { () -> Bool in
                    guard var context = contextBySubscriptionId[admission.subscriptionId],
                        context.productAdmission.matches(admission.productAdmission),
                        context.productSource == admission.expectedSource
                    else { return false }
                    if let currentDemand = context.viewDemand {
                        guard admission.demand.admissionSequence >= currentDemand.admissionSequence else {
                            return false
                        }
                        if admission.demand.admissionSequence == currentDemand.admissionSequence {
                            guard admission.demand == currentDemand else { return false }
                        } else if admission.demand.handle == currentDemand.handle {
                            guard admission.demand.scopeRevision > currentDemand.scopeRevision else {
                                return false
                            }
                        }
                    }
                    if context.viewDemand != admission.demand || admission.forceRecapture {
                        context.demandGeneration += 1
                    }
                    context.viewDemand = admission.demand
                    context.canonicalPathScope = admission.canonicalPathScope
                    contextBySubscriptionId[admission.subscriptionId] = context
                    acceptedContext = context
                    return true
                } ?? false
            } == true
        return didAcceptContext ? acceptedContext : nil
    }

    private func resolveCanonicalViewDemand(
        initialContext: SubscriptionContext,
        sourceSpec: BridgeProductFileSourceSpec,
        subscriptionId: String,
        demand: BridgePaneProductFileViewDemand
    ) throws -> CanonicalFileViewDemand {
        let scopedSourceSpec = try BridgePaneProductFileMetadataEncoding.legacySourceSpec(
            sourceSpec: sourceSpec,
            subscriptionId: subscriptionId,
            pathScope: demand.state.pathScope
        )
        let pathScope = try BridgeWorktreeFileSourceProvider.openSource(
            spec: scopedSourceSpec,
            worktree: authority.worktree,
            paneIdentity: authority.paneId,
            subscriptionGeneration: initialContext.openedSource.source.subscriptionGeneration
        ).canonicalPathScope
        let lanesByPath = BridgePaneProductFileMetadataEncoding.highestPriorityLaneByPath(
            demand.state.interests
        ).filter { path, _ in
            pathScope.isEmpty || Self.isWithinPathScope(path, scope: pathScope)
        }
        return .init(pathScope: pathScope, lanesByPath: lanesByPath)
    }

    private func reconcileRefreshedDescriptors(
        _ request: RefreshedTreeDeltaRequest,
        unavailablePaths: Set<String>
    ) async throws {
        let descriptorRows = BridgeProductDemandLane.fileMetadataPriorityOrder.flatMap { lane in
            request.rows.filter {
                !$0.isDirectory && request.demandedPaths[$0.path] == lane
            }
        }
        try await reconcileDescriptors(
            .init(
                emit: request.emit,
                foregroundWorkAdmission: request.foregroundWorkAdmission,
                productAdmission: request.productAdmission,
                productSource: request.productSource,
                rows: descriptorRows,
                subscriptionId: request.subscriptionId,
                demand: request.demand,
                demandGeneration: request.demandGeneration
            )
        )
        _ = try await emitDescriptorUnavailablePathInvalidations(
            .init(
                emit: request.emit,
                foregroundWorkAdmission: request.foregroundWorkAdmission,
                paths: unavailablePaths,
                productAdmission: request.productAdmission,
                productSource: request.productSource,
                subscriptionId: request.subscriptionId,
                demand: request.demand,
                demandGeneration: request.demandGeneration
            )
        )
    }

    private func emitRefreshedTreeDeltas(
        _ request: RefreshedTreeDeltaRequest
    ) async throws -> Bool {
        for lane in BridgeProductDemandLane.fileMetadataPriorityOrder {
            let laneRows = request.rows.filter { request.demandedPaths[$0.path] == lane }
            for rows in try BridgePaneProductFileMetadataEncoding.boundedProductRowChunks(
                laneRows
            ) {
                try Task.checkCancellation()
                guard
                    isCurrent(
                        subscriptionId: request.subscriptionId, demand: request.demand,
                        demandGeneration: request.demandGeneration, source: request.productSource,
                        productAdmission: request.productAdmission),
                    request.foregroundWorkAdmission.withValidAdmission({ true }) == true,
                    (request.productAdmission.withValidAdmission { true }) == true
                else { return false }
                try await request.emit(
                    .inventoryChanged(
                        .init(
                            updatedPaths: Set(rows.map(\.path)), removedPaths: [],
                            source: request.productSource
                        )
                    )
                )
            }
        }
        return true
    }

    private func emitDescriptorUnavailablePathInvalidations(
        _ request: DescriptorUnavailablePathInvalidationRequest
    ) async throws -> Bool {
        for path in request.paths.sorted() {
            try Task.checkCancellation()
            var acceptedContext: SubscriptionContext?
            let didAcceptContext =
                request.foregroundWorkAdmission.withValidAdmission {
                    request.productAdmission.withValidAdmission { () -> Bool in
                        guard
                            let currentContext = contextBySubscriptionId[request.subscriptionId],
                            currentContext.productSource == request.productSource,
                            currentContext.productAdmission.matches(request.productAdmission),
                            currentContext.viewDemand == request.demand,
                            currentContext.demandGeneration == request.demandGeneration
                        else { return false }
                        acceptedContext = currentContext
                        return true
                    } ?? false
                } == true
            guard didAcceptContext, let currentContext = acceptedContext else { return false }
            try await request.emit(
                .invalidated(
                    try .init(
                        fileId: currentContext.descriptorByPath[path]?.fileId,
                        path: path,
                        reason: .filesystemEvent,
                        replacementDescriptor: nil,
                        source: request.productSource
                    )
                )
            )
        }
        return true
    }

    private func reconcileDescriptors(
        _ request: DescriptorReconciliationRequest
    ) async throws {
        for row in request.rows {
            guard try await reconcileDescriptor(row, request: request) else { return }
        }
    }

}
