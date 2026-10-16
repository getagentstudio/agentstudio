import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product Review metadata contracts")
struct BridgeProductReviewMetadataContractTests {
    @Test("decodes the six Review events and six delta operations")
    func decodesClosedReviewMetadataUnion() throws {
        var window = reviewSnapshotObject()
        window["eventKind"] = "review.window"
        window.removeValue(forKey: "baseEndpoint")
        window.removeValue(forKey: "headEndpoint")
        window.removeValue(forKey: "query")

        var delta = reviewIdentityObject(eventKind: "review.delta")
        delta["contentSources"] = [reviewContentSourceObject()]
        delta["fromRevision"] = 10
        delta["operations"] = [
            ["item": reviewItemMetadataObject(), "operationKind": "upsertItem"],
            ["itemIds": ["review-item-1"], "operationKind": "removeItems"],
            ["itemIds": ["review-item-1"], "operationKind": "replaceItemOrder"],
            [
                "deleteCount": 1,
                "operationKind": "spliceTreeRows",
                "rows": [reviewTreeRowObject()],
                "startIndex": 0,
            ],
            [
                "facts": [reviewExtentFactObject()],
                "operationKind": "upsertExtentFacts",
            ],
            [
                "descriptorIds": ["review-descriptor-1"],
                "operationKind": "invalidateContentSources",
            ],
        ]
        delta["presentationRevision"] = 19
        addReviewRefreshImpact(to: &delta)
        delta["reviewComparison"] = reviewComparisonPresentationObject()
        delta["summary"] = reviewSummaryObject()
        delta["toRevision"] = 11

        var invalidated = reviewIdentityObject(eventKind: "review.invalidated")
        invalidated["itemIds"] = ["review-item-1"]
        invalidated["pathHints"] = ["src/file.ts"]
        invalidated["reason"] = "watchEvent"
        invalidated["scope"] = "items"

        var reset = reviewIdentityObject(eventKind: "review.reset")
        reset["reason"] = "providerRestart"
        addReviewRefreshImpact(to: &reset)

        let eventObjects = [
            reviewIdentityObject(eventKind: "review.sourceAccepted"),
            reviewSnapshotObject(),
            window,
            delta,
            invalidated,
            reset,
        ]

        let events = try eventObjects.map(decodeReviewMetadataEvent)

        #expect(events.count == 6)
        #expect(events.map(\.generation) == Array(repeating: 7, count: 6))
        #expect(events.map(\.packageId) == Array(repeating: "review-package-1", count: 6))
        guard case .delta(let deltaEvent) = events[3] else {
            Issue.record("Expected Review delta event")
            return
        }
        #expect(deltaEvent.operations.count == 6)
    }

    @Test("every Review metadata event requires one lowercase UUIDv7 publication identity")
    func reviewMetadataRequiresExactPublicationUUIDv7() throws {
        let validPublicationId = "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
        let decoded = try decodeReviewMetadataEvent(
            reviewIdentityObject(eventKind: "review.sourceAccepted")
        )
        #expect(decoded.publicationId.uuidString.lowercased() == validPublicationId)

        for invalidPublicationId in [
            validPublicationId.uppercased(),
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "00000000-0000-0000-0000-000000000000",
        ] {
            var invalidEvent = reviewIdentityObject(eventKind: "review.sourceAccepted")
            invalidEvent["publicationId"] = invalidPublicationId
            #expect(throws: (any Error).self) {
                try decodeReviewMetadataEvent(invalidEvent)
            }
        }
        var missingPublicationId = reviewIdentityObject(eventKind: "review.sourceAccepted")
        missingPublicationId.removeValue(forKey: "publicationId")
        #expect(throws: (any Error).self) {
            try decodeReviewMetadataEvent(missingPublicationId)
        }
    }

    @Test("rejects deep unknown keys, legacy fields, and retired tree operations")
    func rejectsUnknownAndLegacyReviewMetadata() throws {
        var snapshot = reviewSnapshotObject()
        var baseEndpoint = try #require(snapshot["baseEndpoint"] as? [String: Any])
        baseEndpoint["legacyEndpoint"] = true
        snapshot["baseEndpoint"] = baseEndpoint
        #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(snapshot) }

        snapshot = reviewSnapshotObject()
        var items = try #require(snapshot["itemMetadata"] as? [[String: Any]])
        items[0]["resourceUrl"] = "agentstudio://resource/review/content/legacy"
        snapshot["itemMetadata"] = items
        #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(snapshot) }

        snapshot = reviewSnapshotObject()
        var sources = try #require(snapshot["contentSources"] as? [[String: Any]])
        sources[0]["contents"] = "inline bytes are forbidden"
        snapshot["contentSources"] = sources
        #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(snapshot) }

        for legacyField in ["resourceUrl", "selectedItemId", "selectedFilePath"] {
            snapshot = reviewSnapshotObject()
            snapshot[legacyField] = "legacy"
            #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(snapshot) }
        }

        for retiredOperation in ["upsertTreeRows", "removeTreeRows"] {
            var delta = reviewDeltaObject(
                operations: [
                    [
                        "operationKind": retiredOperation,
                        "rows": [reviewTreeRowObject()],
                    ]
                ]
            )
            delta["revision"] = 11
            #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(delta) }
        }
    }

    @Test("enforces ordered window count, bounds, finality, and snapshot origin")
    func enforcesReviewWindowInvariants() throws {
        var snapshot = reviewSnapshotObject()
        var itemWindow = try #require(snapshot["itemWindow"] as? [String: Any])
        itemWindow["itemCount"] = 0
        snapshot["itemWindow"] = itemWindow
        #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(snapshot) }

        snapshot = reviewSnapshotObject()
        itemWindow = try #require(snapshot["itemWindow"] as? [String: Any])
        itemWindow["finalWindow"] = false
        snapshot["itemWindow"] = itemWindow
        #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(snapshot) }

        snapshot = reviewSnapshotObject()
        itemWindow = try #require(snapshot["itemWindow"] as? [String: Any])
        itemWindow["startIndex"] = 1
        itemWindow["totalItemCount"] = 2
        snapshot["itemWindow"] = itemWindow
        #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(snapshot) }

        var window = reviewSnapshotObject()
        window["eventKind"] = "review.window"
        window.removeValue(forKey: "baseEndpoint")
        window.removeValue(forKey: "headEndpoint")
        window.removeValue(forKey: "query")
        itemWindow = try #require(window["itemWindow"] as? [String: Any])
        itemWindow["startIndex"] = 3
        itemWindow["totalItemCount"] = 4
        window["itemWindow"] = itemWindow
        var treeWindow = try #require(window["treeWindow"] as? [String: Any])
        treeWindow["startIndex"] = 6
        treeWindow["totalRowCount"] = 7
        window["treeWindow"] = treeWindow
        _ = try decodeReviewMetadataEvent(window)

        itemWindow["totalItemCount"] = 3
        window["itemWindow"] = itemWindow
        #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(window) }
    }

    @Test("separates leading candidate impact from terminal comparison commit")
    func enforcesReviewCandidateStartAndComparisonCommitBarriers() throws {
        var terminalSnapshot = reviewSnapshotObject()
        terminalSnapshot["reviewComparison"] = NSNull()
        guard case .snapshot(let decodedTerminal) = try decodeReviewMetadataEvent(terminalSnapshot) else {
            Issue.record("Expected terminal Review snapshot")
            return
        }
        #expect(decodedTerminal.presentationRevision == 19)
        #expect(decodedTerminal.reviewComparison == nil)

        var unknownImpactReset = reviewIdentityObject(eventKind: "review.reset")
        unknownImpactReset["reason"] = "sourceChanged"
        unknownImpactReset["preDeliveryPresentationClass"] = ["kind": "promoted", "reason": "unknown"]
        unknownImpactReset["newlyImportedCommitCount"] = NSNull()
        unknownImpactReset["affectedFileCount"] = NSNull()
        unknownImpactReset["addedLineCount"] = NSNull()
        unknownImpactReset["deletedLineCount"] = NSNull()
        unknownImpactReset["affectedStableFileIdentities"] = []
        guard case .reset(let decodedUnknownImpact) = try decodeReviewMetadataEvent(unknownImpactReset) else {
            Issue.record("Expected leading Review reset with unknown impact")
            return
        }
        #expect(decodedUnknownImpact.refreshImpact?.preDeliveryPresentationClass == .promoted(reason: .unknown))
        #expect(decodedUnknownImpact.refreshImpact?.newlyImportedCommitCount == nil)

        for missingKey in ["presentationRevision", "reviewComparison"] {
            var invalidTerminal = reviewSnapshotObject()
            invalidTerminal.removeValue(forKey: missingKey)
            #expect(throws: (any Error).self) {
                try decodeReviewMetadataEvent(invalidTerminal)
            }
        }

        var nonterminalSnapshot = reviewSnapshotObject()
        var itemWindow = try #require(nonterminalSnapshot["itemWindow"] as? [String: Any])
        itemWindow["finalWindow"] = false
        itemWindow["totalItemCount"] = 2
        nonterminalSnapshot["itemWindow"] = itemWindow
        nonterminalSnapshot.removeValue(forKey: "presentationRevision")
        nonterminalSnapshot.removeValue(forKey: "reviewComparison")
        _ = try decodeReviewMetadataEvent(nonterminalSnapshot)

        for commitKey in ["presentationRevision", "reviewComparison"] {
            var invalidNonterminal = nonterminalSnapshot
            if commitKey == "presentationRevision" {
                invalidNonterminal[commitKey] = 19
            } else {
                invalidNonterminal[commitKey] = reviewComparisonPresentationObject()
            }
            #expect(throws: (any Error).self) {
                try decodeReviewMetadataEvent(invalidNonterminal)
            }
        }

        for missingKey in ["presentationRevision", "reviewComparison"] + reviewRefreshImpactWireKeys {
            var invalidDelta = reviewDeltaObject()
            invalidDelta.removeValue(forKey: missingKey)
            #expect(throws: (any Error).self) {
                try decodeReviewMetadataEvent(invalidDelta)
            }
        }

        var invalidTerminalImpact = reviewSnapshotObject()
        addReviewRefreshImpact(to: &invalidTerminalImpact)
        #expect(throws: (any Error).self) {
            try decodeReviewMetadataEvent(invalidTerminalImpact)
        }
    }

    @Test("enforces content-source identity, delta lineage, and unique item ordering")
    func enforcesReviewIdentityAndDeltaInvariants() throws {
        for mismatch in [
            ("packageId", "review-package-2"),
            ("reviewGeneration", 8),
            ("sourceIdentity", "review-query-2"),
        ] as [(String, Any)] {
            var snapshot = reviewSnapshotObject()
            var sources = try #require(snapshot["contentSources"] as? [[String: Any]])
            sources[0][mismatch.0] = mismatch.1
            snapshot["contentSources"] = sources
            #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(snapshot) }
        }

        var delta = reviewDeltaObject()
        delta["revision"] = 12
        #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(delta) }

        delta = reviewDeltaObject()
        delta["fromRevision"] = 12
        #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(delta) }

        for operationKind in ["removeItems", "replaceItemOrder"] {
            delta = reviewDeltaObject(
                operations: [
                    [
                        "itemIds": ["review-item-1", "review-item-1"],
                        "operationKind": operationKind,
                    ]
                ]
            )
            #expect(throws: (any Error).self) { try decodeReviewMetadataEvent(delta) }
        }
    }

}

private func decodeReviewMetadataEvent(_ object: [String: Any]) throws -> BridgeProductReviewMetadataEvent {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try BridgeProductStrictJSON.decode(BridgeProductReviewMetadataEvent.self, from: data)
}

private func reviewIdentityObject(eventKind: String) -> [String: Any] {
    [
        "eventKind": eventKind,
        "generation": 7,
        "operationCorrelationId": NSNull(),
        "packageId": "review-package-1",
        "publicationId": "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa",
        "revision": 11,
        "sourceIdentity": "review-query-1",
    ]
}

private func reviewSnapshotObject() -> [String: Any] {
    var snapshot = reviewIdentityObject(eventKind: "review.snapshot")
    snapshot["baseEndpoint"] = reviewEndpointObject(
        endpointId: "review-base-endpoint",
        kind: "gitRef",
        label: "main",
        providerIdentity: "git-ref:main"
    )
    snapshot["contentSources"] = [reviewContentSourceObject()]
    snapshot["extentFacts"] = [reviewExtentFactObject()]
    snapshot["headEndpoint"] = reviewEndpointObject(
        endpointId: "review-head-endpoint",
        kind: "workingTree",
        label: "Working Tree",
        providerIdentity: "working-tree"
    )
    snapshot["itemMetadata"] = [reviewItemMetadataObject()]
    snapshot["itemWindow"] = [
        "finalWindow": true,
        "itemCount": 1,
        "startIndex": 0,
        "totalItemCount": 1,
    ]
    snapshot["query"] = reviewQueryObject()
    snapshot["presentationRevision"] = 19
    snapshot["reviewComparison"] = reviewComparisonPresentationObject()
    snapshot["summary"] = reviewSummaryObject()
    snapshot["treeRows"] = [reviewTreeRowObject()]
    snapshot["treeWindow"] = [
        "finalWindow": true,
        "rowCount": 1,
        "startIndex": 0,
        "totalRowCount": 1,
    ]
    return snapshot
}

private func reviewDeltaObject(
    operations: [[String: Any]] = [
        [
            "deleteCount": 0,
            "operationKind": "spliceTreeRows",
            "rows": [reviewTreeRowObject()],
            "startIndex": 0,
        ]
    ]
) -> [String: Any] {
    var delta = reviewIdentityObject(eventKind: "review.delta")
    delta["contentSources"] = [reviewContentSourceObject()]
    delta["fromRevision"] = 10
    delta["operations"] = operations
    delta["presentationRevision"] = 19
    addReviewRefreshImpact(to: &delta)
    delta["reviewComparison"] = reviewComparisonPresentationObject()
    delta["summary"] = reviewSummaryObject()
    delta["toRevision"] = 11
    return delta
}

private let reviewRefreshImpactWireKeys = [
    "preDeliveryPresentationClass",
    "newlyImportedCommitCount",
    "affectedFileCount",
    "addedLineCount",
    "deletedLineCount",
    "affectedStableFileIdentities",
]

private func addReviewRefreshImpact(to event: inout [String: Any]) {
    event["preDeliveryPresentationClass"] = ["kind": "ordinary"]
    event["newlyImportedCommitCount"] = 0
    event["affectedFileCount"] = 0
    event["addedLineCount"] = 0
    event["deletedLineCount"] = 0
    event["affectedStableFileIdentities"] = []
}

private func reviewComparisonPresentationObject() -> [String: Any] {
    [
        "activeTarget": ["basis": "commonCommit", "kind": "branch", "name": "origin/main"],
        "attempt": ["reviewGeneration": 7, "status": "settled"],
        "displayedSnapshot": [
            "packageId": "review-package-1",
            "reviewGeneration": 7,
            "revision": 11,
            "status": "current",
        ],
        "repositoryDefaultTarget": NSNull(),
    ]
}

private func reviewEndpointObject(
    endpointId: String,
    kind: String,
    label: String,
    providerIdentity: String
) -> [String: Any] {
    [
        "createdAtUnixMilliseconds": 1,
        "endpointId": endpointId,
        "kind": kind,
        "label": label,
        "providerIdentity": providerIdentity,
        "repoId": "repo-1",
        "worktreeId": "worktree-1",
    ]
}

private func reviewContentSourceObject() -> [String: Any] {
    [
        "contentDigest": [
            "algorithm": "sha256",
            "authority": "authoritative",
            "value": String(repeating: "a", count: 64),
        ],
        "contentKind": "review.content",
        "descriptorId": "review-descriptor-1",
        "encoding": "utf-8",
        "endpointId": "review-endpoint-1",
        "handleId": "review-handle-1",
        "isBinary": false,
        "itemId": "review-item-1",
        "language": "typescript",
        "mimeType": "text/plain",
        "packageId": "review-package-1",
        "reviewGeneration": 7,
        "role": "head",
        "sourceIdentity": "review-query-1",
        "wholeByteLength": 12,
    ]
}

private func reviewItemMetadataObject() -> [String: Any] {
    [
        "additions": 2,
        "basePath": "src/file.ts",
        "changeKind": "modified",
        "contentDescriptorIdsByRole": ["head": "review-descriptor-1"],
        "contentHashesByRole": ["head": String(repeating: "a", count: 64)],
        "contentRoles": ["head"],
        "deletions": 1,
        "extension": "ts",
        "fileClass": "source",
        "headPath": "src/file.ts",
        "isHiddenByDefault": false,
        "itemId": "review-item-1",
        "language": "typescript",
        "mimeTypes": ["text/plain"],
        "provenance": [
            "agentSessionIds": [],
            "operationIds": [],
            "promptIds": [],
        ],
        "reviewPriority": "normal",
        "reviewState": "unreviewed",
    ]
}

private func reviewTreeRowObject() -> [String: Any] {
    [
        "depth": 0,
        "isDirectory": false,
        "itemId": "review-item-1",
        "path": "src/file.ts",
        "rowId": "review-row-1",
    ]
}

private func reviewExtentFactObject() -> [String: Any] {
    [
        "contentRole": "head",
        "itemId": "review-item-1",
        "lineCount": 3,
    ]
}

private func reviewSummaryObject() -> [String: Any] {
    [
        "additions": 2,
        "deletions": 1,
        "filesChanged": 1,
        "hiddenFileCount": 0,
        "visibleFileCount": 1,
    ]
}

private func reviewQueryObject() -> [String: Any] {
    [
        "baseEndpointId": "review-base-endpoint",
        "comparisonSemantics": "threeDot",
        "fileTarget": NSNull(),
        "grouping": ["kind": "folder"],
        "headEndpointId": "review-head-endpoint",
        "pathScope": [],
        "provenanceFilter": [
            "agentSessionIds": [],
            "operationIds": [],
            "paneIds": [],
            "promptIds": [],
            "sourceKinds": [],
        ],
        "queryId": "review-query-1",
        "queryKind": "compare",
        "repoId": "repo-1",
        "viewFilter": [
            "changeKinds": [],
            "excludedExtensions": [],
            "excludedFileClasses": [],
            "excludedPathGlobs": [],
            "includedExtensions": [],
            "includedFileClasses": [],
            "includedPathGlobs": [],
            "reviewStates": [],
            "showBinaryFiles": true,
            "showHiddenFiles": false,
            "showLargeFiles": true,
        ],
        "worktreeId": "worktree-1",
    ]
}
