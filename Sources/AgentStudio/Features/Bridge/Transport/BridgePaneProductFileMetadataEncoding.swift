import AgentStudioCore
import Foundation

enum BridgePaneProductFileMetadataEncoding {
    static func legacySourceSpec(
        sourceSpec: BridgeProductFileSourceSpec,
        subscriptionId: String,
        pathScope: [String]
    ) throws -> BridgeWorktreeFileSurfaceSourceSpec {
        guard let repoId = UUID(uuidString: sourceSpec.repoId),
            let worktreeId = UUID(uuidString: sourceSpec.worktreeId)
        else {
            throw BridgeWorktreeFileSourceProviderError.worktreeMismatch
        }
        return .init(
            clientRequestId: subscriptionId,
            repoId: repoId,
            worktreeId: worktreeId,
            rootPathToken: sourceSpec.rootPathToken,
            cwdScope: sourceSpec.cwdScope,
            pathScope: pathScope,
            includeStatuses: sourceSpec.includeStatuses,
            includeComments: false,
            includeAgentComms: false,
            freshness: .live
        )
    }

    static func productTreeRow(
        _ row: BridgeWorktreeTreeRowMetadata
    ) throws -> BridgeProductFileTreeRow {
        try .init(
            changeStatus: row.changeStatus.flatMap(BridgeProductFileChangeStatus.init(rawValue:)),
            depth: row.depth,
            fileId: row.fileId,
            fileClass: row.fileClass,
            isDirectory: row.isDirectory,
            lineCount: row.lineCount,
            name: row.name,
            parentPath: row.parentPath,
            path: row.path,
            rowId: row.rowId,
            sizeBytes: row.sizeBytes
        )
    }

    static func boundedProductRowChunks(
        _ rows: [BridgeWorktreeTreeRowMetadata]
    ) throws -> [[BridgeProductFileTreeRow]] {
        var chunks: [[BridgeProductFileTreeRow]] = []
        var currentChunk: [BridgeProductFileTreeRow] = []
        var currentEncodedByteCount = 0
        let maximumPayloadByteCount = BridgeProductWireContract.maximumMetadataFrameBytes - 4096
        let encoder = JSONEncoder()
        for row in try rows.map(productTreeRow) {
            let encodedByteCount = try encoder.encode(row).count + 1
            if !currentChunk.isEmpty,
                currentChunk.count == BridgeProductWireContract.maximumFileMetadataDeltaMemberCount
                    || currentEncodedByteCount + encodedByteCount > maximumPayloadByteCount
            {
                chunks.append(currentChunk)
                currentChunk = []
                currentEncodedByteCount = 0
            }
            currentChunk.append(row)
            currentEncodedByteCount += encodedByteCount
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk) }
        return chunks
    }

    static func boundedRemovalChunks(
        _ rows: [BridgeWorktreeTreeRowMetadata]
    ) -> [[BridgeWorktreeTreeRowMetadata]] {
        var chunks: [[BridgeWorktreeTreeRowMetadata]] = []
        var currentChunk: [BridgeWorktreeTreeRowMetadata] = []
        var currentEncodedByteCount = 0
        let maximumPayloadByteCount = BridgeProductWireContract.maximumMetadataFrameBytes - 4096
        for row in rows {
            let encodedByteCount = row.path.utf8.count + row.rowId.utf8.count + 32
            if !currentChunk.isEmpty,
                currentChunk.count == BridgeProductWireContract.maximumFileMetadataDeltaMemberCount
                    || currentEncodedByteCount + encodedByteCount > maximumPayloadByteCount
            {
                chunks.append(currentChunk)
                currentChunk = []
                currentEncodedByteCount = 0
            }
            currentChunk.append(row)
            currentEncodedByteCount += encodedByteCount
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk) }
        return chunks
    }

    static func inventoryChangeEmissions(
        refreshed: BridgeWorktreeRefreshedTreeRows,
        removedRows: [BridgeWorktreeTreeRowMetadata],
        source: BridgeProductFileSourceIdentity,
        subscriptionId: String
    ) throws -> [BridgePaneProductFileMetadataEmission] {
        var emissions: [BridgePaneProductFileMetadataEmission] = []
        for rows in try boundedProductRowChunks(refreshed.rows) {
            emissions.append(
                .init(
                    fact: .inventoryChanged(
                        .init(
                            updatedPaths: Set(rows.map(\.path)), removedPaths: [], source: source)),
                    subscriptionId: subscriptionId))
        }
        for chunk in boundedRemovalChunks(removedRows) {
            emissions.append(
                .init(
                    fact: .inventoryChanged(
                        .init(
                            updatedPaths: [], removedPaths: Set(chunk.map(\.path)), source: source)),
                    subscriptionId: subscriptionId))
        }
        return emissions
    }

    static func highestPriorityLaneByPath(
        _ interestGroups: [BridgeProductFileMetadataInterestStateGroup]
    ) -> [String: BridgeProductDemandLane] {
        var laneByPath: [String: BridgeProductDemandLane] = [:]
        for group in interestGroups {
            for path in group.paths
            where group.lane.priority < (laneByPath[path]?.priority ?? Int.max) {
                laneByPath[path] = group.lane
            }
        }
        return laneByPath
    }

    static func isGitInternalPath(_ path: String) -> Bool {
        path == ".git" || path.hasPrefix(".git/")
    }
}
