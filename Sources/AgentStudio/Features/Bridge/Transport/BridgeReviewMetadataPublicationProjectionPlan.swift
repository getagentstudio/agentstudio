import Foundation

struct BridgeReviewMetadataProjectionWindow: Equatable, Sendable {
    let itemRange: Range<Int>
    let treeRowRange: Range<Int>
    let isSnapshot: Bool
}

struct BridgeReviewMetadataPublicationBinding: Equatable, Sendable {
    let identity: BridgeProductReviewMetadataIdentity
    let presentationRevision: Int
    let reviewComparison: BridgePaneReviewComparisonPresentation?
}

struct BridgeReviewMetadataPublicationProjectionPlan: Equatable, Sendable {
    static let maximumEncodedEventBytes =
        BridgeProductWireContract.maximumMetadataFrameBytes - 4096
    private static let preferredItemWindowCount = 64
    private static let preferredTreeWindowCount = 128

    let packageId: String
    let publicationId: UUID
    let reviewGeneration: BridgeReviewGeneration
    let revision: Int
    let itemCount: Int
    let treeRowCount: Int
    let windows: [BridgeReviewMetadataProjectionWindow]

    private let baseEndpoint: BridgeProductReviewSourceEndpointValue
    private let comparisonOrigin: BridgeReviewComparisonOrigin?
    private let headEndpoint: BridgeProductReviewSourceEndpointValue
    private let items: [BridgeReviewProjectedItem]
    private let query: BridgeProductReviewQueryValue
    private let reviewedSubjectLabel: String?
    private let summary: BridgeProductReviewPackageSummaryValue
    private let treeRows: [BridgeProductReviewTreeRowValue]

    static func prepare(
        package: BridgeReviewPackage,
        publicationId: UUID
    ) throws -> Self {
        let itemIds = BridgePaneProductReviewMetadataSource.orderedItemIds(in: package)
        let reviewItems = itemIds.compactMap { package.itemsById[$0] }
        let projectedItems = try reviewItems.map {
            try BridgeReviewProjectedItem(item: $0, package: package)
        }
        let projectedTreeRows = try productTreeRows(
            for: reviewItems,
            loadedBy: .startupWindow
        )
        let provisionalBinding = BridgeReviewMetadataPublicationBinding(
            identity: try BridgeProductReviewMetadataIdentity(
                generation: package.reviewGeneration.rawValue,
                packageId: package.packageId,
                publicationId: publicationId,
                revision: package.revision,
                sourceIdentity: package.query.queryId
            ),
            presentationRevision: 1,
            reviewComparison: nil
        )
        let plan = Self(
            packageId: package.packageId,
            publicationId: publicationId,
            reviewGeneration: package.reviewGeneration,
            revision: package.revision,
            itemCount: projectedItems.count,
            treeRowCount: projectedTreeRows.count,
            windows: [],
            baseEndpoint: try productEndpoint(package.baseEndpoint),
            comparisonOrigin: package.comparisonOrigin,
            headEndpoint: try productEndpoint(package.headEndpoint),
            items: projectedItems,
            query: try productQuery(package.query),
            reviewedSubjectLabel: package.reviewedSubjectLabel,
            summary: try productSummary(package.summary),
            treeRows: projectedTreeRows
        )
        return plan.replacingWindows(
            try plan.makeWindows(provisionalBinding: provisionalBinding)
        )
    }

    private func makeWindows(
        provisionalBinding: BridgeReviewMetadataPublicationBinding
    ) throws -> [BridgeReviewMetadataProjectionWindow] {
        var plannedWindows: [BridgeReviewMetadataProjectionWindow] = []
        var itemStartIndex = 0
        var treeStartIndex = 0
        var isSnapshot = true

        repeat {
            var itemCount = min(Self.preferredItemWindowCount, self.itemCount - itemStartIndex)
            var treeCount = min(
                Self.preferredTreeWindowCount,
                treeRowCount - treeStartIndex
            )
            var window: BridgeReviewMetadataProjectionWindow
            while true {
                window = BridgeReviewMetadataProjectionWindow(
                    itemRange: itemStartIndex..<(itemStartIndex + itemCount),
                    treeRowRange: treeStartIndex..<(treeStartIndex + treeCount),
                    isSnapshot: isSnapshot
                )
                let event = try event(window: window, binding: provisionalBinding)
                if try JSONEncoder().encode(event).count <= Self.maximumEncodedEventBytes {
                    break
                }
                if itemCount >= treeCount, itemCount > 0 {
                    itemCount /= 2
                } else if treeCount > 0 {
                    treeCount /= 2
                } else {
                    throw BridgePaneProductReviewMetadataSourceError.metadataEventExceedsByteLimit
                }
            }
            guard
                itemCount > 0 || treeCount > 0
                    || (self.itemCount == 0 && treeRowCount == 0)
            else {
                throw BridgePaneProductReviewMetadataSourceError.metadataEventExceedsByteLimit
            }
            plannedWindows.append(window)
            itemStartIndex += itemCount
            treeStartIndex += treeCount
            isSnapshot = false
        } while itemStartIndex < itemCount || treeStartIndex < treeRowCount
        return plannedWindows
    }

    private func replacingWindows(
        _ windows: [BridgeReviewMetadataProjectionWindow]
    ) -> Self {
        Self(
            packageId: packageId,
            publicationId: publicationId,
            reviewGeneration: reviewGeneration,
            revision: revision,
            itemCount: itemCount,
            treeRowCount: treeRowCount,
            windows: windows,
            baseEndpoint: baseEndpoint,
            comparisonOrigin: comparisonOrigin,
            headEndpoint: headEndpoint,
            items: items,
            query: query,
            reviewedSubjectLabel: reviewedSubjectLabel,
            summary: summary,
            treeRows: treeRows
        )
    }

    private func event(
        window: BridgeReviewMetadataProjectionWindow,
        binding: BridgeReviewMetadataPublicationBinding
    ) throws -> BridgeProductReviewMetadataEvent {
        let itemSlice = Array(items[window.itemRange])
        let treeSlice = Array(treeRows[window.treeRowRange])
        let itemWindow = try BridgeProductReviewItemWindow(
            finalWindow: window.itemRange.upperBound == items.count,
            itemCount: window.itemRange.count,
            startIndex: window.itemRange.lowerBound,
            totalItemCount: items.count
        )
        let treeWindow = try BridgeProductReviewTreeWindow(
            finalWindow: window.treeRowRange.upperBound == treeRows.count,
            rowCount: window.treeRowRange.count,
            startIndex: window.treeRowRange.lowerBound,
            totalRowCount: treeRows.count
        )
        let isFinalBarrier = itemWindow.finalWindow && treeWindow.finalWindow
        if window.isSnapshot {
            return .snapshot(
                try .init(
                    identity: binding.identity,
                    baseEndpoint: baseEndpoint,
                    comparisonOrigin: comparisonOrigin,
                    contentSources: itemSlice.flatMap(\.contentSources),
                    extentFacts: itemSlice.flatMap(\.extentFacts),
                    headEndpoint: headEndpoint,
                    itemMetadata: itemSlice.map(\.metadata),
                    itemWindow: itemWindow,
                    presentationRevision: isFinalBarrier ? binding.presentationRevision : nil,
                    query: query,
                    reviewComparison: isFinalBarrier ? binding.reviewComparison : nil,
                    reviewedSubjectLabel: reviewedSubjectLabel,
                    summary: summary,
                    treeRows: treeSlice,
                    treeWindow: treeWindow
                )
            )
        }
        return .window(
            try .init(
                identity: binding.identity,
                contentSources: itemSlice.flatMap(\.contentSources),
                extentFacts: itemSlice.flatMap(\.extentFacts),
                itemMetadata: itemSlice.map(\.metadata),
                itemWindow: itemWindow,
                presentationRevision: isFinalBarrier ? binding.presentationRevision : nil,
                reviewComparison: isFinalBarrier ? binding.reviewComparison : nil,
                summary: summary,
                treeRows: treeSlice,
                treeWindow: treeWindow
            )
        )
    }
}

private struct BridgeReviewProjectedItem: Equatable, Sendable {
    let contentSources: [BridgeProductReviewContentSourceDescriptor]
    let extentFacts: [BridgeProductReviewExtentFactValue]
    let metadata: BridgeProductReviewItemMetadataValue

    init(item: BridgeReviewItemDescriptor, package: BridgeReviewPackage) throws {
        self.contentSources = try productContentSources(for: item, package: package)
        self.extentFacts = authoritativeProductExtentFacts(item)
        self.metadata = try productItem(
            item,
            loadedBy: .startupWindow,
            lane: .foreground
        )
    }
}

func productItem(
    _ item: BridgeReviewItemDescriptor,
    loadedBy: BridgeProductReviewMetadataLoadedBy,
    lane: BridgeProductDemandLane
) throws -> BridgeProductReviewItemMetadataValue {
    let roles = item.contentRoles
    return try .init(
        additions: item.additions,
        basePath: item.basePath,
        changeKind: item.changeKind,
        contentDescriptorIdsByRole: .init(
            base: roles.base?.handleId,
            diff: roles.diff?.handleId,
            file: roles.file?.handleId,
            head: roles.head?.handleId
        ),
        contentHashesByRole: .init(
            base: roles.base?.contentHash,
            diff: roles.diff?.contentHash,
            file: roles.file?.contentHash,
            head: roles.head?.contentHash
        ),
        contentRoles: roles.allHandles.map(\.role),
        deletions: item.deletions,
        fileExtension: item.extension,
        fileClass: item.fileClass,
        headPath: item.headPath,
        isHiddenByDefault: item.isHiddenByDefault,
        itemId: item.itemId,
        lane: lane,
        language: item.language,
        loadedBy: loadedBy,
        mimeTypes: Array(Set(roles.allHandles.map(\.mimeType))).sorted(),
        provenance: .init(
            agentSessionIds: item.provenance.agentSessionIds,
            operationIds: item.provenance.operationIds,
            promptIds: item.provenance.promptIds
        ),
        reviewPriority: item.reviewPriority,
        reviewState: item.reviewState
    )
}

func productContentSources(
    for item: BridgeReviewItemDescriptor,
    package: BridgeReviewPackage
) throws -> [BridgeProductReviewContentSourceDescriptor] {
    try item.contentRoles.allHandles.map { handle in
        let digest: BridgeProductReviewContentDigest
        let unprefixedHash =
            handle.contentHash.hasPrefix("sha256:")
            ? String(handle.contentHash.dropFirst("sha256:".count))
            : handle.contentHash
        if handle.contentHashAlgorithm == "sha256",
            unprefixedHash.count == 64,
            unprefixedHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        {
            digest = .authoritativeSHA256(unprefixedHash)
        } else {
            digest = .provisional(algorithm: handle.contentHashAlgorithm, value: handle.contentHash)
        }
        return try .init(
            contentDigest: digest,
            descriptorId: handle.handleId,
            encoding: handle.isBinary ? nil : "utf-8",
            endpointId: handle.endpointId,
            handleId: handle.handleId,
            isBinary: handle.isBinary,
            itemId: handle.itemId,
            language: handle.language,
            mimeType: handle.mimeType,
            packageId: package.packageId,
            reviewGeneration: package.reviewGeneration.rawValue,
            role: handle.role,
            sourceIdentity: package.query.queryId,
            wholeByteLength: handle.sizeBytesIsExact ? handle.sizeBytes : nil
        )
    }
}

func authoritativeProductExtentFacts(
    _: BridgeReviewItemDescriptor
) -> [BridgeProductReviewExtentFactValue] {
    []
}

func productTreeRows(
    for items: [BridgeReviewItemDescriptor],
    loadedBy: BridgeProductReviewMetadataLoadedBy
) throws -> [BridgeProductReviewTreeRowValue] {
    var rows: [BridgeProductReviewTreeRowValue] = []
    var seenRowIds = Set<String>()
    for item in items {
        let path = item.headPath ?? item.basePath ?? item.itemId
        let components = path.split(separator: "/").map(String.init)
        if components.count > 1 {
            for componentCount in 1..<components.count {
                let ancestorPath = components.prefix(componentCount).joined(separator: "/")
                let rowId = BridgeProductReviewTreeRowIdentity.directoryRowId(path: ancestorPath)
                if seenRowIds.insert(rowId).inserted {
                    rows.append(
                        try .init(
                            depth: componentCount - 1,
                            isDirectory: true,
                            itemId: nil,
                            lane: .foreground,
                            loadedBy: loadedBy,
                            path: ancestorPath,
                            rowId: rowId
                        )
                    )
                }
            }
        }
        let rowId = BridgeProductReviewTreeRowIdentity.itemRowId(itemId: item.itemId)
        if seenRowIds.insert(rowId).inserted {
            rows.append(
                try .init(
                    depth: max(components.count - 1, 0),
                    isDirectory: false,
                    itemId: item.itemId,
                    lane: .foreground,
                    loadedBy: loadedBy,
                    path: path,
                    rowId: rowId
                )
            )
        }
    }
    return rows
}

func productEndpoint(
    _ endpoint: BridgeSourceEndpoint
) throws -> BridgeProductReviewSourceEndpointValue {
    guard let createdAt = Int(exactly: endpoint.createdAtUnixMilliseconds) else {
        throw BridgePaneProductReviewMetadataSourceError.integerOutOfRange
    }
    return try .init(
        contentSetHash: endpoint.contentSetHash,
        createdAtUnixMilliseconds: createdAt,
        endpointId: endpoint.endpointId,
        kind: endpoint.kind,
        label: endpoint.label,
        providerIdentity: endpoint.providerIdentity,
        repoId: endpoint.repoId.uuidString,
        worktreeId: endpoint.worktreeId.uuidString
    )
}

func productSummary(
    _ summary: BridgeReviewPackageSummary
) throws -> BridgeProductReviewPackageSummaryValue {
    try .init(
        additions: summary.additions,
        deletions: summary.deletions,
        filesChanged: summary.filesChanged,
        hiddenFileCount: summary.hiddenFileCount,
        visibleFileCount: summary.visibleFileCount
    )
}

func productQuery(_ query: BridgeReviewQuery) throws -> BridgeProductReviewQueryValue {
    guard
        let createdAfter = query.provenanceFilter.createdAfterUnixMilliseconds.map(Int.init(exactly:)) ?? .some(nil),
        let createdBefore = query.provenanceFilter.createdBeforeUnixMilliseconds.map(Int.init(exactly:)) ?? .some(nil)
    else {
        throw BridgePaneProductReviewMetadataSourceError.integerOutOfRange
    }
    let filter = query.viewFilter
    return try .init(
        baseEndpointId: query.baseEndpointId,
        comparisonSemantics: query.comparisonSemantics,
        fileTarget: query.fileTarget,
        grouping: .init(kind: query.grouping.kind, label: query.grouping.label),
        headEndpointId: query.headEndpointId,
        pathScope: query.pathScope,
        provenanceFilter: .init(
            agentSessionIds: query.provenanceFilter.agentSessionIds,
            createdAfterUnixMilliseconds: createdAfter,
            createdBeforeUnixMilliseconds: createdBefore,
            operationIds: query.provenanceFilter.operationIds,
            paneIds: query.provenanceFilter.paneIds.map(\.uuidString),
            promptIds: query.provenanceFilter.promptIds,
            sourceKinds: query.provenanceFilter.sourceKinds.map(\.rawValue)
        ),
        queryId: query.queryId,
        queryKind: query.queryKind,
        repoId: query.repoId.uuidString,
        viewFilter: .init(
            changeKinds: filter.changeKinds,
            excludedExtensions: filter.excludedExtensions,
            excludedFileClasses: filter.excludedFileClasses,
            excludedPathGlobs: filter.excludedPathGlobs,
            includedExtensions: filter.includedExtensions,
            includedFileClasses: filter.includedFileClasses,
            includedPathGlobs: filter.includedPathGlobs,
            reviewStates: filter.reviewStates,
            showBinaryFiles: filter.showBinaryFiles,
            showHiddenFiles: filter.showHiddenFiles,
            showLargeFiles: filter.showLargeFiles
        ),
        worktreeId: query.worktreeId.uuidString
    )
}
