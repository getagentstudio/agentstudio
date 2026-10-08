import Foundation

enum BridgeProductStrictJSONError: Error, Equatable {
    case duplicateObjectMember
    case inputExceedsCeiling
    case invalidJSON
    case invalidUTF8
    case nestingExceedsCeiling
    case objectMemberCountExceedsCeiling
}

struct BridgeProductStrictJSONMemberVocabulary {
    fileprivate let exactUTF8MemberNames: Set<Data>

    init(_ memberNames: Set<String>) {
        exactUTF8MemberNames = Set(memberNames.map { Data($0.utf8) })
    }
}

enum BridgeProductStrictJSON {
    private static let maximumInputBytes = 256 * 1024
    private static let maximumNestingDepth = 64
    private static let maximumObjectMembers = 64
    private static let productMemberVocabulary = BridgeProductStrictJSONMemberVocabulary(
        Set([
            "activeSubscriptions",
            "snapshotCause",
            "activeSource",
            "activeTarget",
            "addedLineCount",
            "add",
            "addPathScope",
            "additions",
            "admission",
            "ahead",
            "affectedFileCount",
            "affectedStableFileIdentities",
            "after",
            "agentSessionIds",
            "algorithm",
            "applicationSourceGeneration",
            "aggregateSha256",
            "attempt",
            "attemptId",
            "attentionState",
            "authority",
            "authorKind",
            "authoredAt",
            "availability",
            "availabilityKind",
            "baseline",
            "base",
            "baseEndpoint",
            "baseEndpointId",
            "baseInterestRevision",
            "baseInterestSha256",
            "basePath",
            "baseRevision",
            "baseRole",
            "basis",
            "batchCount",
            "batchId",
            "batchIndex",
            "behind",
            "bindingRevision",
            "body",
            "branchName",
            "branches",
            "catalogRevision",
            "call",
            "canMarkNotHandled",
            "candidatePublicationId",
            "capturedAtUnixMilliseconds",
            "candidates",
            "changeKind",
            "changeFilter",
            "changeKinds",
            "changeStatus",
            "classifiedRefreshImpact",
            "code",
            "commandId",
            "commandKind",
            "commandOutcomes",
            "committedSessionRevision",
            "comparedRole",
            "comparisonOrigin",
            "comparisonSemantics",
            "completedAt",
            "completedAtUnixMilliseconds",
            "confirmsUnresolvedWork",
            "contentDescriptor",
            "contentDescriptorIdsByRole",
            "contentByRole",
            "contentDigest",
            "contentHashesByRole",
            "contentKind",
            "contentRequestId",
            "receivedThroughContentSequence",
            "contentRole",
            "contentRoles",
            "contentSequence",
            "contentSetHash",
            "domain",
            "displayKey",
            "contentSources",
            "contentType",
            "context",
            "coveredScope",
            "cleanupError",
            "baseOID",
            "cutoffUnixMilliseconds",
            "createdAfterUnixMilliseconds",
            "createdAt",
            "createdAtUnixMilliseconds",
            "createdBeforeUnixMilliseconds",
            "createdOrdinal",
            "currentSourceGeneration",
            "cursor",
            "cwdScope",
            "data",
            "declaredByteLength",
            "deleteCount",
            "deletions",
            "desired",
            "deletedLineCount",
            "deliverySequence",
            "defaultTarget",
            "delta",
            "depth",
            "descriptorOutcome",
            "decision",
            "descriptor",
            "descriptorId",
            "descriptorIds",
            "destination",
            "destinationFilename",
            "displayedSnapshot",
            "displayed",
            "displayedProjectionRevision",
            "disposition",
            "diff",
            "diffSide",
            "draft",
            "draftRevision",
            "editToken",
            "eligibleMessageCount",
            "eligibleWithoutInlinePlacementCount",
            "encoding",
            "entry",
            "endLine",
            "endOfSource",
            "endsMidLine",
            "endsWithNewline",
            "endpointId",
            "entries",
            "entryCount",
            "estimatedContentHeightPixels",
            "effectCode",
            "effectError",
            "event",
            "eventKind",
            "excerpt",
            "excludedExtensions",
            "excludedFileClasses",
            "excludedPathGlobs",
            "expectedSha256",
            "expectedDraftRevision",
            "expectedEntryCount",
            "expectedDisplayedPublicationId",
            "expectedMessageCount",
            "expectedPageCount",
            "expectedOpenThreadCount",
            "expectedSavedRevision",
            "expectedSessionRevision",
            "expectedMessageRevision",
            "expectedThreadRevision",
            "expectedSessionCount",
            "expectedThreadCount",
            "extension",
            "extentFacts",
            "facts",
            "file",
            "fileClass",
            "fileExtension",
            "fileId",
            "fileTarget",
            "failureKind",
            "failureCode",
            "filesChanged",
            "finalWindow",
            "finalizationError",
            "freshness",
            "fromRevision",
            "formatVersion",
            "flatOrdinal",
            "generation",
            "grouping",
            "handleId",
            "head",
            "headEndpoint",
            "headEndpointId",
            "headPath",
            "header",
            "handled",
            "handle",
            "hiddenFileCount",
            "identity",
            "includeStatuses",
            "includedExtensions",
            "includedFileClasses",
            "includedPathGlobs",
            "incarnation",
            "interests",
            "isBinary",
            "isDirectory",
            "isHiddenByDefault",
            "isLastBatchForThread",
            "isLastPage",
            "item",
            "itemCount",
            "itemId",
            "itemIds",
            "itemMetadata",
            "itemWindow",
            "items",
            "key",
            "kind",
            "kinds",
            "label",
            "lane",
            "language",
            "lastAcceptedRequestSequence",
            "lastAcceptedStreamSequence",
            "savedBody",
            "savedRevision",
            "leaseId",
            "lineCount",
            "lineage",
            "limit",
            "lifecycle",
            "loadedBy",
            "location",
            "activeEditToken",
            "admissionRetryCount",
            "telemetryPreReadyBufferMaxBytes",
            "telemetryPreReadyBufferMaxSamples",
            "maximumBytes",
            "maximumContentBytes",
            "maximumLines",
            "maximumMetadataFrameBytes",
            "maximumQueuedStreamBytes",
            "maximumQueuedStreamFrames",
            "maximumRequestBodyBytes",
            "message",
            "messageCount",
            "messageId",
            "messageRevision",
            "messages",
            "metadataSourceId",
            "metadataStreamSequenceBarrier",
            "metadataStreamId",
            "method",
            "mimeType",
            "mimeTypes",
            "mode",
            "modifiedAtUnixMilliseconds",
            "name",
            "nativeActivity",
            "nativeSelectionRequestId",
            "newlyImportedCommitCount",
            "nextCursor",
            "navigationCommand",
            "nextExpectedRequestSequence",
            "observedByteLength",
            "observedSha256",
            "oid",
            "offsetBytes",
            "oldPath",
            "op",
            "operationCorrelationId",
            "operationId",
            "operationIds",
            "operationKind",
            "operation",
            "operations",
            "ordinal",
            "origin",
            "outputHistory",
            "outputKind",
            "outcome",
            "packageId",
            "paneSessionId",
            "paneIds",
            "parentPath",
            "part",
            "partCount",
            "partIndex",
            "parentDisplayKey",
            "patch",
            "patchKind",
            "page",
            "pageOrdinal",
            "path",
            "pathScope",
            "pathHints",
            "paths",
            "payload",
            "payloadByteCount",
            "payloadLineCount",
            "policy",
            "placement",
            "presentationRevision",
            "preDeliveryPresentationClass",
            "projectionRevision",
            "priorWorkerDerivationEpoch",
            "promptIds",
            "provenance",
            "provenanceFilter",
            "providerIdentity",
            "publicationId",
            "recordKind",
            "extentByRole",
            "query",
            "queryId",
            "queryKind",
            "reason",
            "receivedThroughDeliverySequence",
            "readDescriptor",
            "reconciliation",
            "recoveryStatus",
            "receipt",
            "readiness",
            "refreshingLanes",
            "fileRefreshFailure",
            "removeItemIds",
            "removedMessageRevision",
            "removePathScope",
            "removePaths",
            "replacementDescriptor",
            "repeatedFromAttemptId",
            "remoteName",
            "repoId",
            "request",
            "requestId",
            "repositoryDefaultTarget",
            "requestSequence",
            "refusalKind",
            "replayRejectionKind",
            "result",
            "results",
            "resolution",
            "requiredWorkerDerivationEpoch",
            "requiresCollection",
            "resumeDisposition",
            "resumeFromStreamSequence",
            "retryAfterMilliseconds",
            "retryable",
            "revision",
            "reviewGeneration",
            "reviewComparison",
            "reviewItemId",
            "reviewedSubjectBranchName",
            "reviewPriority",
            "reviewState",
            "reviewStates",
            "reviewedHeadOID",
            "reviewPublicationIdentity",
            "reviewedSubjectLabel",
            "role",
            "rootPathToken",
            "rootRevisionToken",
            "resolvedTargetOID",
            "rowId",
            "rowIds",
            "rowCount",
            "rows",
            "safeMessage",
            "scope",
            "scopeRevision",
            "semanticRevision",
            "sequence",
            "sessionId",
            "sessionIds",
            "sessionRevision",
            "sessions",
            "selection",
            "selectionError",
            "selectionMode",
            "messageIds",
            "excludedMessageIds",
            "sizeBytes",
            "source",
            "sourceCursor",
            "sourceEpoch",
            "sourceGeneration",
            "sourceId",
            "sourceIdentity",
            "sourceKind",
            "sourceKinds",
            "sourceRelationship",
            "sourceRole",
            "sortKey",
            "startByte",
            "startIndex",
            "startLine",
            "staged",
            "status",
            "state",
            "streamSequence",
            "streamKind",
            "streamId",
            "showBinaryFiles",
            "showHiddenFiles",
            "showLargeFiles",
            "summary",
            "summaries",
            "surface",
            "subscription",
            "subscriptionGeneration",
            "subscriptionId",
            "subscriptionKind",
            "subscriptionSequence",
            "symbolicTarget",
            "snapshotId",
            "target",
            "targetKind",
            "targetInterestRevision",
            "targetInterestSha256",
            "targetRevision",
            "terminalFrameReserve",
            "streamKeepaliveIntervalMilliseconds",
            "contentProgressDeadlineMilliseconds",
            "contentAcknowledgementDeadlineMilliseconds",
            "workerSettlementDeadlineMilliseconds",
            "viewAcknowledgementDeadlineMilliseconds",
            "viewBatchProgressDeadlineMilliseconds",
            "viewCreditBytes",
            "viewCreditParts",
            "viewMaximumConsecutiveResnapshots",
            "viewMaximumDirtyKeys",
            "threadId",
            "threadRevision",
            "transfer",
            "transferId",
            "toRevision",
            "totalDeltaItemCount",
            "totalItemCount",
            "totalLineCount",
            "totalRowCount",
            "treeRows",
            "treeWindow",
            "truncationKind",
            "unstaged",
            "untracked",
            "updateId",
            "updatedAt",
            "updatedAtUnixMilliseconds",
            "value",
            "version",
            "versionId",
            "viewFilter",
            "visibleFileCount",
            "virtualizedExtentKind",
            "wholeByteLength",
            "window",
            "wireVersion",
            "workerDerivationEpoch",
            "workerInstanceId",
            "waitKind",
            "windowCount",
            "windowOrdinal",
            "worktreeId",
        ])
    )

    static func validate(_ data: Data) throws {
        try validate(data, memberVocabulary: nil)
    }

    private static func validate(
        _ data: Data,
        memberVocabulary: BridgeProductStrictJSONMemberVocabulary?
    ) throws {
        guard data.count <= maximumInputBytes else {
            throw BridgeProductStrictJSONError.inputExceedsCeiling
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw BridgeProductStrictJSONError.invalidUTF8
        }
        try data.withUnsafeBytes { bytes in
            var scanner = DuplicateMemberScanner(
                bytes: bytes,
                allowedObjectMemberNames: memberVocabulary?.exactUTF8MemberNames
            )
            try scanner.validate()
        }
    }

    static func decode<DecodedValue: Decodable>(
        _ type: DecodedValue.Type,
        from data: Data
    ) throws -> DecodedValue {
        try decode(type, from: data, memberVocabulary: productMemberVocabulary)
    }

    static func decode<DecodedValue: Decodable>(
        _ type: DecodedValue.Type,
        from data: Data,
        memberVocabulary: BridgeProductStrictJSONMemberVocabulary
    ) throws -> DecodedValue {
        try decode(
            type,
            from: data,
            memberVocabulary: memberVocabulary,
            maximumInputBytes: maximumInputBytes
        )
    }

    static func decode<DecodedValue: Decodable>(
        _ type: DecodedValue.Type,
        from data: Data,
        memberVocabulary: BridgeProductStrictJSONMemberVocabulary,
        maximumInputBytes: Int?
    ) throws -> DecodedValue {
        if let maximumInputBytes, data.count > maximumInputBytes {
            throw BridgeProductStrictJSONError.inputExceedsCeiling
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw BridgeProductStrictJSONError.invalidUTF8
        }
        try data.withUnsafeBytes { bytes in
            var scanner = DuplicateMemberScanner(
                bytes: bytes,
                allowedObjectMemberNames: memberVocabulary.exactUTF8MemberNames
            )
            try scanner.validate()
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BridgeProductStrictJSONError.invalidJSON
        }
    }

    private struct DuplicateMemberScanner {
        private enum ContainerKind {
            case array
            case object
        }

        private struct ContainerScope {
            let kind: ContainerKind
            var decodedMemberNames = Set<Data>()
            var memberCount = 0
        }

        let bytes: UnsafeRawBufferPointer
        let allowedObjectMemberNames: Set<Data>?
        private var scopes: [ContainerScope] = []

        init(
            bytes: UnsafeRawBufferPointer,
            allowedObjectMemberNames: Set<Data>?
        ) {
            self.bytes = bytes
            self.allowedObjectMemberNames = allowedObjectMemberNames
        }

        mutating func validate() throws {
            var cursor = 0
            while cursor < bytes.count {
                switch bytes[cursor] {
                case 0x22:
                    let stringEnd = findStringEnd(openingQuote: cursor)
                    let nextToken = skipWhitespace(startingAt: min(stringEnd + 1, bytes.count))
                    if stringEnd < bytes.count,
                        scopes.last?.kind == .object,
                        nextToken < bytes.count,
                        bytes[nextToken] == 0x3a
                    {
                        try recordObjectMember(openingQuote: cursor, closingQuote: stringEnd)
                    }
                    cursor = min(stringEnd + 1, bytes.count)
                case 0x7b:
                    try pushScope(kind: .object)
                    cursor += 1
                case 0x5b:
                    try pushScope(kind: .array)
                    cursor += 1
                case 0x7d:
                    if scopes.last?.kind == .object {
                        scopes.removeLast()
                    }
                    cursor += 1
                case 0x5d:
                    if scopes.last?.kind == .array {
                        scopes.removeLast()
                    }
                    cursor += 1
                default:
                    cursor += 1
                }
            }
        }

        private mutating func pushScope(kind: ContainerKind) throws {
            guard scopes.count < BridgeProductStrictJSON.maximumNestingDepth else {
                throw BridgeProductStrictJSONError.nestingExceedsCeiling
            }
            scopes.append(ContainerScope(kind: kind))
        }

        private mutating func recordObjectMember(
            openingQuote: Int,
            closingQuote: Int
        ) throws {
            let rawMemberName = Data(
                bytes[(openingQuote)...closingQuote]
            )
            guard
                let decodedMemberName = try? JSONDecoder().decode(
                    String.self,
                    from: rawMemberName
                )
            else { return }

            let objectScopeIndex = scopes.count - 1
            scopes[objectScopeIndex].memberCount += 1
            guard
                scopes[objectScopeIndex].memberCount
                    <= BridgeProductStrictJSON.maximumObjectMembers
            else {
                throw BridgeProductStrictJSONError.objectMemberCountExceedsCeiling
            }

            let exactDecodedName = Data(decodedMemberName.utf8)
            guard
                allowedObjectMemberNames == nil
                    || allowedObjectMemberNames?.contains(exactDecodedName) == true
            else {
                throw BridgeProductStrictJSONError.invalidJSON
            }
            guard scopes[objectScopeIndex].decodedMemberNames.insert(exactDecodedName).inserted else {
                throw BridgeProductStrictJSONError.duplicateObjectMember
            }
        }

        private func findStringEnd(openingQuote: Int) -> Int {
            var cursor = openingQuote + 1
            while cursor < bytes.count {
                switch bytes[cursor] {
                case 0x22:
                    return cursor
                case 0x5c:
                    cursor = min(cursor + 2, bytes.count)
                default:
                    cursor += 1
                }
            }
            return bytes.count
        }

        private func skipWhitespace(startingAt start: Int) -> Int {
            var cursor = start
            while cursor < bytes.count {
                switch bytes[cursor] {
                case 0x20, 0x09, 0x0a, 0x0d:
                    cursor += 1
                default:
                    return cursor
                }
            }
            return cursor
        }
    }
}
