import AgentStudioCore
import Foundation

extension BridgePaneProductFileMetadataSource {
    /// Bootstraps an already-installed context, reporting whether the installed context
    /// survives. Every give-up exit returns `false` so `open` can release the context it
    /// installed; `open` owns that release for both the thrown and the given-up paths.
    func bootstrapInstalledContext(
        _ request: InstalledContextBootstrapRequest
    ) async throws -> Bool {
        let productSource = request.productSource
        let subscriptionId = request.subscription.subscriptionId
        guard request.foregroundWorkAdmission.withValidAdmission({ true }) == true,
            (request.productAdmission.withValidAdmission { true }) == true
        else { return false }
        try await request.emit(.sourceAccepted(productSource))
        await sourceAcceptedObserver(productSource)
        let constructionLease = try await sharedConstructionBinder.acquire(
            openedSource: request.context.openedSource
        )
        guard
            attachConstructionLease(
                constructionLease,
                subscriptionId: subscriptionId,
                productSource: productSource,
                productAdmission: request.productAdmission,
                foregroundWorkAdmission: request.foregroundWorkAdmission
            )
        else {
            // The lease never reached the context, so `releaseContext` cannot release it.
            await sharedConstructionBinder.release(constructionLease)
            return false
        }
        let preparation = try await sharedConstructionBinder.preparation(for: constructionLease)
        guard
            let preparedContext = applyPreparation(
                preparation,
                subscriptionId: subscriptionId,
                productSource: productSource,
                productAdmission: request.productAdmission,
                foregroundWorkAdmission: request.foregroundWorkAdmission
            )
        else { return false }
        if request.sourceSpec.includeStatuses {
            try await publishCurrentStatus(
                preparation.statusResult,
                emit: request.emit,
                productAdmission: request.productAdmission,
                productSource: productSource,
                foregroundWorkAdmission: request.foregroundWorkAdmission
            )
        }
        return try await enumerateInitialTree(
            .init(
                emit: request.emit,
                foregroundWorkAdmission: request.foregroundWorkAdmission,
                manifestIndex: preparedContext.manifestIndex,
                openedSource: preparedContext.openedSource,
                pathScope: request.pathScope,
                productAdmission: request.productAdmission,
                productSource: productSource,
                subscription: request.subscription
            ),
            constructionLease: constructionLease
        )
    }

    // WIP checkpoint: extract the window iteration before the 1.4c cutover commit.
    // swiftlint:disable:next function_body_length
    private func enumerateInitialTree(
        _ request: InitialTreeEnumerationRequest,
        constructionLease: BridgeSharedFileSnapshotConsumerLease
    ) async throws -> Bool {
        guard
            await request.manifestIndex.beginEnumeration(
                productAdmission: request.productAdmission,
                foregroundWorkAdmission: request.foregroundWorkAdmission
            )
        else { return false }
        var cursor = BridgeSharedFileSnapshotCursor(nextWindowOrdinal: 0)
        readLoop: while true {
            let read = try await sharedConstructionBinder.nextRead(
                for: constructionLease,
                cursor: cursor
            )
            let batch: BridgeWorktreeTreeRowWindowBatch
            switch read {
            case .window(let window):
                batch = BridgeWorktreeTreeRowWindowBatch(
                    discoveredRowCount: window.discoveredRowCount,
                    isFinalWindow: window.isFinalWindow,
                    rows: window.rows,
                    startIndex: window.startIndex
                )
                cursor = BridgeSharedFileSnapshotCursor(
                    nextWindowOrdinal: cursor.nextWindowOrdinal + 1
                )
            case .completed:
                break readLoop
            }
            try Task.checkCancellation()
            guard
                isCurrent(
                    subscriptionId: request.subscription.subscriptionId,
                    source: request.productSource,
                    productAdmission: request.productAdmission
                ),
                request.foregroundWorkAdmission.withValidAdmission({ true }) == true,
                (request.productAdmission.withValidAdmission { true }) == true
            else {
                return false
            }
            guard
                await request.manifestIndex.appendEnumeratedRows(
                    batch.rows,
                    productAdmission: request.productAdmission,
                    foregroundWorkAdmission: request.foregroundWorkAdmission
                )
            else { return false }
            guard try await emitInitialTreeWindowBatch(batch, request: request) else {
                return false
            }
        }
        guard
            isCurrent(
                subscriptionId: request.subscription.subscriptionId,
                source: request.productSource,
                productAdmission: request.productAdmission
            ),
            request.foregroundWorkAdmission.withValidAdmission({ true }) == true,
            (request.productAdmission.withValidAdmission { true }) == true
        else {
            return false
        }
        guard
            await request.manifestIndex.markEnumerationComplete(
                productAdmission: request.productAdmission,
                foregroundWorkAdmission: request.foregroundWorkAdmission
            )
        else { return false }
        let inventory = await request.manifestIndex.captureKeyedSnapshot()
        let status = inventory.memberStatus.record
        if status.status == .loading {
            guard
                try await request.manifestIndex.updateMemberStatus(
                    state: .ready,
                    branchName: status.branchName,
                    ahead: status.ahead,
                    behind: status.behind,
                    staged: status.staged,
                    unstaged: status.unstaged,
                    untracked: status.untracked,
                    productAdmission: request.productAdmission
                )
            else { return false }
        }
        guard
            isCurrent(
                subscriptionId: request.subscription.subscriptionId,
                source: request.productSource,
                productAdmission: request.productAdmission
            ),
            request.foregroundWorkAdmission.withValidAdmission({ true }) == true,
            request.productAdmission.withValidAdmission({ true }) == true
        else { return false }
        // The callback recaptures the complete inventory before post-open enrichment.
        try await request.emit(
            .inventoryProgress(
                .init(
                    finalWindow: true,
                    updatedPaths: [],
                    source: request.productSource
                )
            )
        )
        return try await drainDeferredFileChanges(request)
    }

    private func emitInitialTreeWindowBatch(
        _ batch: BridgeWorktreeTreeRowWindowBatch,
        request: InitialTreeEnumerationRequest
    ) async throws -> Bool {
        let rowChunks = try BridgePaneProductFileMetadataEncoding.boundedProductRowChunks(
            batch.rows
        )
        if rowChunks.isEmpty, batch.isFinalWindow {
            guard request.foregroundWorkAdmission.withValidAdmission({ true }) == true,
                (request.productAdmission.withValidAdmission { true }) == true
            else { return false }
            try await request.emit(
                .inventoryProgress(
                    .init(
                        finalWindow: true,
                        updatedPaths: [],
                        source: request.productSource
                    )
                )
            )
            return true
        }
        for (chunkIndex, rows) in rowChunks.enumerated() {
            let isLastChunk = chunkIndex + 1 == rowChunks.count
            guard request.foregroundWorkAdmission.withValidAdmission({ true }) == true,
                (request.productAdmission.withValidAdmission { true }) == true
            else {
                return false
            }
            try await request.emit(
                .inventoryProgress(
                    .init(
                        finalWindow: batch.isFinalWindow && isLastChunk,
                        updatedPaths: Set(rows.map(\.path)),
                        source: request.productSource
                    )
                )
            )
        }
        return true
    }

}
