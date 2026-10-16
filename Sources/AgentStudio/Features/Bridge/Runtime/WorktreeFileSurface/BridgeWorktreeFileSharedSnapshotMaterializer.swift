import AgentStudioCore
import Foundation

extension BridgeWorktreeFileMaterializer {
    static func buildSharedSnapshot(
        request: BridgeWorktreeFileMaterializationRequest,
        preparation: BridgeSharedFileSnapshotPreparation,
        publisher: BridgeSharedFileSnapshotPublisher
    ) async throws -> BridgeSharedFileSnapshotCompletion {
        try await publisher.publishPreparation(preparation)
        let preparedRequest = BridgeWorktreeFileMaterializationRequest(
            rootURL: request.rootURL,
            openedSource: request.openedSource.withIgnorePolicy(preparation.ignorePolicy),
            directoryReader: request.directoryReader
        )
        var nextOrdinal = 0
        var discoveredRowCount = 0
        var didPublishFinalWindow = false
        for try await batch in materializeTreeRowWindows(
            request: preparedRequest,
            afterCount: 0,
            windowSize: BridgeProductWireContract.maximumFileMetadataTreeWindowRowCount
        ) {
            try Task.checkCancellation()
            try await publisher.append(
                BridgeSharedFileSnapshotWindow(
                    ordinal: nextOrdinal,
                    startIndex: batch.startIndex,
                    discoveredRowCount: batch.discoveredRowCount,
                    isFinalWindow: batch.isFinalWindow,
                    rows: batch.rows,
                    retainedByteCount: estimatedTreeRowRetainedByteCount(batch.rows)
                )
            )
            nextOrdinal += 1
            discoveredRowCount = batch.discoveredRowCount
            didPublishFinalWindow = batch.isFinalWindow
        }
        if !didPublishFinalWindow {
            try await publisher.append(
                BridgeSharedFileSnapshotWindow(
                    ordinal: nextOrdinal,
                    startIndex: discoveredRowCount,
                    discoveredRowCount: discoveredRowCount,
                    isFinalWindow: true,
                    rows: [],
                    retainedByteCount: 0
                )
            )
        }
        return BridgeSharedFileSnapshotCompletion()
    }

    static func prepareSharedSnapshot(
        rootURL: URL,
        gitReadContext: BridgeGitReadContext,
        statusProvider: any GitWorkingTreeStatusProvider
    ) async -> BridgeSharedFileSnapshotPreparation {
        let statusResult = await statusProvider.statusResult(for: rootURL)
        let ignorePolicy = await BridgeWorktreeFileIgnorePolicy.load(
            rootURL: rootURL,
            gitReadContext: gitReadContext,
            statusResult: statusResult
        )
        return BridgeSharedFileSnapshotPreparation(
            ignorePolicy: ignorePolicy,
            statusResult: statusResult,
            retainedByteCount: estimatedPreparationRetainedByteCount(
                ignorePolicy: ignorePolicy,
                statusResult: statusResult
            )
        )
    }

    static func estimatedPreparationRetainedByteCount(
        ignorePolicy: BridgeWorktreeFileIgnorePolicy,
        statusResult: GitWorkingTreeStatusResult
    ) -> Int {
        ignorePolicy.estimatedRetainedByteCount
            + estimatedStatusRetainedByteCount(statusResult)
    }

    private static func estimatedStatusRetainedByteCount(
        _ result: GitWorkingTreeStatusResult
    ) -> Int {
        switch result {
        case .available(let status):
            let branchByteCount = status.branch?.utf8.count ?? 0
            let originByteCount: Int
            switch status.originResolution {
            case .resolved(let origin): originByteCount = origin.utf8.count
            case .awaitingResolution, .confirmedAbsent: originByteCount = 0
            }
            let entryByteCount = status.entries.reduce(0) { partialResult, entry in
                partialResult + entry.path.utf8.count + (entry.previousPath?.utf8.count ?? 0) + 32
            }
            return 64 + branchByteCount + originByteCount + entryByteCount
        case .unavailable(let unavailable):
            return 32 + unavailable.reason.rawValue.utf8.count
        }
    }

    private static func estimatedTreeRowRetainedByteCount(
        _ rows: [BridgeWorktreeTreeRowMetadata]
    ) -> Int {
        rows.reduce(0) { partialResult, row in
            let requiredStringBytes =
                row.rowId.utf8.count + row.path.utf8.count
                + row.name.utf8.count
            let optionalStringBytes =
                (row.parentPath?.utf8.count ?? 0)
                + (row.fileId?.utf8.count ?? 0)
                + (row.changeStatus?.utf8.count ?? 0)
            return partialResult + requiredStringBytes + optionalStringBytes + 64
        }
    }
}
