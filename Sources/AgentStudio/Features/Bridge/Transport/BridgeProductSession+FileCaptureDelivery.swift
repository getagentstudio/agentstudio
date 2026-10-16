import Foundation

extension BridgeProductSession {
    func sealFileCapture(
        subscriptionId: String,
        snapshot: BridgeWorktreeFileKeyedSnapshot,
        scope: BridgeProductAcceptedViewScopeSnapshot,
        productAdmission: BridgeProductAdmissionContext
    ) throws -> Bool {
        guard
            let viewDomain = viewScopeByDomain.keys.first(where: {
                $0.viewId == subscriptionId && $0.domain == .singleDomain
            }), let current = viewScopeByDomain[viewDomain],
            viewDomain == scope.viewDomain, current.handle == scope.handle,
            current.revision == scope.revision, current.scope == scope.scope,
            lifecycle == .active, productAdmission.withValidAdmission({ true }) == true
        else { return false }
        if viewSenderState.hasActiveEmission(for: viewDomain) {
            return productAdmission.withValidAdmission {
                if snapshot.targetRevision >= (pendingFileSnapshotByViewDomain[viewDomain]?.targetRevision ?? 0) {
                    pendingFileSnapshotByViewDomain[viewDomain] = snapshot
                }
                return true
            } ?? false
        }
        guard
            let batch = try makeFileCaptureBatch(
                .init(
                    viewDomain: viewDomain,
                    handle: current.handle,
                    scopeRevision: current.revision,
                    scope: current.scope,
                    firstDeliverySequence: nextViewDeliverySequenceByDomain[viewDomain] ?? 1,
                    snapshot: snapshot
                )
            )
        else { return false }
        guard try sealViewBatch(batch, productAdmission: productAdmission) else { return false }
        recordSealedFileBatch(batch)
        return true
    }

    private func makeFileCaptureBatch(
        _ input: BridgeProductFileViewSnapshotInput
    ) throws -> BridgeProductSealedViewBatch? {
        guard input.snapshot.isEnumerationComplete,
            case .keys = viewSenderState.pending(for: input.viewDomain),
            let base = lastSealedFileTargetByViewDomain[input.viewDomain]
        else { return try fileCaptureBatchSealer(input, nil) }
        guard input.snapshot.targetRevision > base else { return nil }
        return try fileCaptureBatchSealer(input, base)
    }

    private func recordSealedFileBatch(_ batch: BridgeProductSealedViewBatch) {
        lastSealedFileTargetByViewDomain[batch.viewDomain] = batch.targetRevision
    }

    func sealPendingFileSnapshotIfReady() throws {
        for (viewDomain, snapshot) in pendingFileSnapshotByViewDomain {
            guard !viewSenderState.hasActiveEmission(for: viewDomain),
                let current = viewScopeByDomain[viewDomain]
            else { continue }
            guard
                let batch = try makeFileCaptureBatch(
                    .init(
                        viewDomain: viewDomain,
                        handle: current.handle,
                        scopeRevision: current.revision,
                        scope: current.scope,
                        firstDeliverySequence: nextViewDeliverySequenceByDomain[viewDomain] ?? 1,
                        snapshot: snapshot
                    )
                )
            else {
                pendingFileSnapshotByViewDomain.removeValue(forKey: viewDomain)
                continue
            }
            try viewSenderState.seal(batch)
            recordSealedFileBatch(batch)
            nextViewDeliverySequenceByDomain[viewDomain] = batch.firstDeliverySequence + batch.parts.count
            pendingFileSnapshotByViewDomain.removeValue(forKey: viewDomain)
        }
    }

}
