import Foundation

enum BridgeProductReviewBatchItemProjectionError: Error {
    case duplicateContentRole
    case missingItem
    case missingRevision
}

/// Converts an immutable Review package into N10's initial item values. N10
/// supplies wire revisions and owns later content and extent replacements.
enum BridgeProductReviewBatchItemProjection {
    static func initialItems(
        in package: BridgeReviewPackage,
        revisionByItemId: [String: Int]
    ) throws -> [BridgeProductReviewKeyedItem] {
        let orderedIds = BridgePaneProductReviewMetadataSource.orderedItemIds(in: package)
        return try orderedIds.enumerated().map { sortKey, itemId in
            guard let item = package.itemsById[itemId] else {
                throw BridgeProductReviewBatchItemProjectionError.missingItem
            }
            guard let revision = revisionByItemId[itemId] else {
                throw BridgeProductReviewBatchItemProjectionError.missingRevision
            }
            return try .init(
                record: BridgeProductReviewBatchItemRecord(
                    item: item,
                    package: package,
                    sortKey: sortKey
                ),
                revision: revision
            )
        }
    }
}

extension BridgeProductReviewBatchContentByRole {
    init(sources: [BridgeProductReviewContentSourceDescriptor]) throws {
        var sourceByRole: [BridgeContentHandle.Role: BridgeProductReviewContentSourceDescriptor] = [:]
        for source in sources {
            guard sourceByRole.updateValue(source, forKey: source.role) == nil else {
                throw BridgeProductReviewBatchItemProjectionError.duplicateContentRole
            }
        }
        base = sourceByRole[.base].map(BridgeProductReviewBatchContentRole.available) ?? .absent
        diff = sourceByRole[.diff].map(BridgeProductReviewBatchContentRole.available) ?? .absent
        file = sourceByRole[.file].map(BridgeProductReviewBatchContentRole.available) ?? .absent
        head = sourceByRole[.head].map(BridgeProductReviewBatchContentRole.available) ?? .absent
    }
}

extension BridgeProductReviewBatchExtentByRole {
    init() {
        base = nil
        diff = nil
        file = nil
        head = nil
    }
}

extension BridgeProductReviewBatchItemRecord {
    init(item: BridgeReviewItemDescriptor, package: BridgeReviewPackage, sortKey: Int) throws {
        let sources = try productContentSources(for: item, package: package)
        let displayPath = item.headPath ?? item.basePath ?? item.itemId
        let pathSegments = displayPath.split(separator: "/")
        let parentPath =
            pathSegments.count > 1
            ? pathSegments.dropLast().joined(separator: "/") : nil
        additions = item.additions
        basePath = item.basePath
        changeKind = item.changeKind
        contentByRole = try .init(sources: sources)
        contentHashesByRole = try .init(
            base: item.contentRoles.base?.contentHash,
            diff: item.contentRoles.diff?.contentHash,
            file: item.contentRoles.file?.contentHash,
            head: item.contentRoles.head?.contentHash
        )
        deletions = item.deletions
        extentByRole = .init()
        fileExtension = item.extension
        fileClass = item.fileClass
        headPath = item.headPath
        isHiddenByDefault = item.isHiddenByDefault
        itemId = item.itemId
        lane = .foreground
        language = item.language
        loadedBy = .startupWindow
        mimeTypes = Array(Set(item.contentRoles.allHandles.map(\.mimeType))).sorted()
        self.parentPath = parentPath
        provenance = try .init(
            agentSessionIds: item.provenance.agentSessionIds,
            operationIds: item.provenance.operationIds,
            promptIds: item.provenance.promptIds
        )
        recordKind = "item"
        reviewPriority = item.reviewPriority
        reviewState = item.reviewState
        self.sortKey = sortKey
    }
}
