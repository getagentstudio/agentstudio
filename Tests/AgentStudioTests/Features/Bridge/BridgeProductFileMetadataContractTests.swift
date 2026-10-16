import Foundation
import Testing

@testable import AgentStudioBridge

struct BridgeProductFileMetadataContractTests {
    @Test("canonical File values round-trip their closed row, status, source and descriptor contracts")
    func acceptsCanonicalValuesAndRoundTripsExactly() throws {
        try assertCanonicalRoundTrip(source, as: BridgeProductFileSourceIdentity.self)
        try assertCanonicalRoundTrip(row, as: BridgeProductFileTreeRow.self)
        try assertCanonicalRoundTrip(memberStatus, as: BridgeProductFileMemberStatusRecord.self)
        for value in [descriptorReady, lineLimitedDescriptorReady, binaryDescriptorReady, unavailableDescriptorReady] {
            try assertCanonicalRoundTrip(value, as: BridgeProductFileDescriptorReadyPayload.self)
        }
    }

    @Test("canonical File values reject missing nullable facts, legacy envelopes and cross-wired descriptors")
    func rejectsLegacyCrossWiredAndMissingNullableFacts() throws {
        var missingLanguage = descriptorReady
        missingLanguage.removeValue(forKey: "language")
        var legacyHandle = descriptorReady
        legacyHandle["contentHandle"] = "legacy-handle"
        var mismatched = descriptorReady
        var availability = try #require(mismatched["availability"] as? [String: Any])
        var content = try #require(availability["contentDescriptor"] as? [String: Any])
        var contentSource = try #require(content["source"] as? [String: Any])
        contentSource["sourceCursor"] = "different-source-cursor"
        content["source"] = contentSource
        availability["contentDescriptor"] = content
        mismatched["availability"] = availability
        var legacyEnvelope = descriptorReady
        legacyEnvelope["eventKind"] = "file.descriptorReady"
        for value in [missingLanguage, legacyHandle, mismatched, legacyEnvelope] {
            #expect(throws: (any Error).self) { _ = try decode(value) }
        }
        var ignoredRow = row
        ignoredRow["changeStatus"] = "ignored"
        var missingClass = row
        missingClass.removeValue(forKey: "fileClass")
        var invalidClass = row
        invalidClass["fileClass"] = "text"
        for value in [ignoredRow, missingClass, invalidClass] {
            #expect(throws: (any Error).self) { _ = try decodeCanonical(value, as: BridgeProductFileTreeRow.self) }
        }
        var missingCount = memberStatus
        missingCount.removeValue(forKey: "staged")
        var crossWiredStatus = memberStatus
        crossWiredStatus["patchKind"] = "invalidated"
        for value in [missingCount, crossWiredStatus] {
            #expect(throws: (any Error).self) {
                _ = try decodeCanonical(value, as: BridgeProductFileMemberStatusRecord.self)
            }
        }
        var legacySource = source
        legacySource["streamId"] = "legacy-stream"
        legacySource["generation"] = 11
        legacySource["sequence"] = 1
        #expect(throws: (any Error).self) {
            _ = try decodeCanonical(legacySource, as: BridgeProductFileSourceIdentity.self)
        }
    }

    @Test("File descriptors enforce canonical UTF-8 prefix and truncation facts")
    func enforcesCanonicalPrefixAndTruncationFacts() throws {
        var mismatchedPayloadLength = descriptorReady
        mismatchedPayloadLength["payloadByteCount"] = 119
        var invalidEncoding = descriptorReady
        invalidEncoding["encoding"] = "utf-16"
        var fabricatedBinaryFacts = binaryDescriptorReady
        fabricatedBinaryFacts["payloadLineCount"] = 1
        var invalidLineLimit = descriptorReady
        invalidLineLimit["payloadByteCount"] = 119
        invalidLineLimit["payloadLineCount"] = 10_000
        invalidLineLimit["totalLineCount"] = NSNull()
        invalidLineLimit["truncationKind"] = "lineLimit"
        invalidLineLimit["endsWithNewline"] = false
        invalidLineLimit["virtualizedExtentKind"] = "previewBounded"
        var invalidMidLine = descriptorReady
        invalidMidLine["endsMidLine"] = true
        invalidMidLine["endsWithNewline"] = true
        var nullableDigestDescriptor = contentDescriptor
        nullableDigestDescriptor["expectedSha256"] = NSNull()
        var nullableDigest = descriptorReady
        nullableDigest["availability"] = [
            "availabilityKind": "available",
            "contentDescriptor": nullableDigestDescriptor,
        ]
        var nullableLengthDescriptor = contentDescriptor
        nullableLengthDescriptor["declaredByteLength"] = NSNull()
        var nullableLength = descriptorReady
        nullableLength["availability"] = [
            "availabilityKind": "available",
            "contentDescriptor": nullableLengthDescriptor,
        ]
        var narrowLineWindowDescriptor = contentDescriptor
        var narrowLineWindow = try #require(narrowLineWindowDescriptor["window"] as? [String: Any])
        narrowLineWindow["maximumLines"] = 11
        narrowLineWindowDescriptor["window"] = narrowLineWindow
        var narrowLineWindowEvent = descriptorReady
        narrowLineWindowEvent["availability"] = [
            "availabilityKind": "available",
            "contentDescriptor": narrowLineWindowDescriptor,
        ]
        var emptyWithNewline = descriptorReady
        emptyWithNewline["availability"] = [
            "availabilityKind": "available",
            "contentDescriptor": emptyContentDescriptor,
        ]
        emptyWithNewline["endsWithNewline"] = true
        emptyWithNewline["payloadByteCount"] = 0
        emptyWithNewline["payloadLineCount"] = 0
        emptyWithNewline["sizeBytes"] = 0
        emptyWithNewline["totalLineCount"] = 0
        var completePreview = descriptorReady
        completePreview["virtualizedExtentKind"] = "previewBounded"
        var availableUnavailable = descriptorReady
        availableUnavailable["virtualizedExtentKind"] = "unavailable"
        var truncatedExact = lineLimitedDescriptorReady
        truncatedExact["totalLineCount"] = 10_000
        truncatedExact["virtualizedExtentKind"] = "exactLineCount"
        var removedTooLarge = unavailableDescriptorReady
        removedTooLarge["availability"] = [
            "availabilityKind": "unavailable",
            "reason": "too_large",
        ]

        for event in [
            mismatchedPayloadLength,
            invalidEncoding,
            fabricatedBinaryFacts,
            invalidLineLimit,
            invalidMidLine,
            nullableDigest,
            nullableLength,
            narrowLineWindowEvent,
            emptyWithNewline,
            completePreview,
            availableUnavailable,
            truncatedExact,
            estimatedDescriptorReady,
            removedTooLarge,
        ] {
            #expect(throws: (any Error).self) { _ = try decode(event) }
        }
    }

    // The retired positional envelope ceilings had no wire consumer. The real
    // batch limit is exercised in BridgeProductSealedViewBatchTests.sealedFileFrameRejectsOversizedPart.
    @Test("canonical File producer values reject invalid row depth and status counts")
    func rejectsInvalidProducerValues() throws {
        var negativeDepth = row
        negativeDepth["depth"] = -1
        #expect(throws: (any Error).self) {
            _ = try decodeCanonical(negativeDepth, as: BridgeProductFileTreeRow.self)
        }
        let identity = try decodeCanonical(source, as: BridgeProductFileSourceIdentity.self)
        #expect(throws: (any Error).self) {
            _ = try BridgeProductFileMemberStatusRecord(
                source: identity, status: .ready, branchName: nil,
                ahead: -1, behind: nil, staged: nil, unstaged: nil, untracked: nil)
        }
    }

    private var memberStatus: [String: Any] {
        [
            "kind": "memberStatus", "status": "ready", "source": source,
            "ahead": 1, "behind": 0, "branchName": "main", "staged": 1, "unstaged": 2, "untracked": 3,
        ]
    }

    private var source: [String: Any] {
        [
            "repoId": "00000000-0000-4000-8000-000000000001",
            "rootRevisionToken": NSNull(),
            "sourceCursor": "source-cursor-1",
            "sourceId": "source-1",
            "subscriptionGeneration": 11,
            "worktreeId": "00000000-0000-4000-8000-000000000002",
        ]
    }

    private var row: [String: Any] { treeRow(index: 1) }

    private func treeRow(index: Int) -> [String: Any] {
        [
            "changeStatus": "modified",
            "depth": 1,
            "fileId": "file-\(index)",
            "fileClass": "source",
            "isDirectory": false,
            "lineCount": 12,
            "name": "file-\(index).ts",
            "parentPath": "src",
            "path": "src/file-\(index).ts",
            "rowId": "row-\(index)",
            "sizeBytes": 120,
        ]
    }

    private var descriptorReadyPayload: [String: Any] {
        [
            "availability": ["availabilityKind": "available", "contentDescriptor": contentDescriptor],
            "encoding": "utf-8",
            "endsMidLine": false,
            "endsWithNewline": true,
            "estimatedContentHeightPixels": NSNull(),
            "fileExtension": "ts",
            "fileId": "file-1",
            "language": "typescript",
            "modifiedAtUnixMilliseconds": 1_720_000_000_000,
            "path": "src/file.ts",
            "payloadByteCount": 120,
            "payloadLineCount": 12,
            "rowId": "row-1",
            "sizeBytes": 120,
            "source": source,
            "totalLineCount": 12,
            "truncationKind": "none",
            "virtualizedExtentKind": "exactLineCount",
        ]
    }

    private var descriptorReady: [String: Any] {
        descriptorReadyPayload
    }

    private var binaryDescriptorReady: [String: Any] {
        var value = descriptorReady
        value["availability"] = ["availabilityKind": "binary"]
        value["encoding"] = NSNull()
        value["endsMidLine"] = false
        value["endsWithNewline"] = false
        value["estimatedContentHeightPixels"] = NSNull()
        value["fileExtension"] = NSNull()
        value["language"] = NSNull()
        value["modifiedAtUnixMilliseconds"] = NSNull()
        value["payloadByteCount"] = 0
        value["payloadLineCount"] = 0
        value["totalLineCount"] = NSNull()
        value["truncationKind"] = "none"
        value["virtualizedExtentKind"] = "unavailable"
        return value
    }

    private var lineLimitedDescriptorReady: [String: Any] {
        var value = descriptorReady
        value["payloadLineCount"] = 10_000
        value["sizeBytes"] = 121
        value["totalLineCount"] = NSNull()
        value["truncationKind"] = "lineLimit"
        value["virtualizedExtentKind"] = "previewBounded"
        return value
    }

    private var unavailableDescriptorReady: [String: Any] {
        var value = binaryDescriptorReady
        value["availability"] = [
            "availabilityKind": "unavailable",
            "reason": "unsupported_encoding",
        ]
        value["virtualizedExtentKind"] = "unavailable"
        return value
    }

    private var estimatedDescriptorReady: [String: Any] {
        var value = binaryDescriptorReady
        value["estimatedContentHeightPixels"] = 123.5
        value["virtualizedExtentKind"] = "estimatedHeight"
        return value
    }

    private var contentDescriptor: [String: Any] {
        [
            "contentKind": "file.content",
            "declaredByteLength": 120,
            "descriptorId": "descriptor-1",
            "encoding": "utf-8",
            "expectedSha256": String(repeating: "a", count: 64),
            "fileId": "file-1",
            "maximumBytes": 120,
            "source": source,
            "window": [
                "kind": "prefix",
                "maximumBytes": 120,
                "maximumLines": 10_000,
                "startByte": 0,
            ],
        ]
    }

    private var emptyContentDescriptor: [String: Any] {
        var descriptor = contentDescriptor
        descriptor["declaredByteLength"] = 0
        descriptor["expectedSha256"] =
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        descriptor["maximumBytes"] = 0
        descriptor["window"] = [
            "kind": "prefix",
            "maximumBytes": 0,
            "maximumLines": 10_000,
            "startByte": 0,
        ]
        return descriptor
    }

    private func decode(_ object: [String: Any]) throws -> BridgeProductFileDescriptorReadyPayload {
        try decodeCanonical(object, as: BridgeProductFileDescriptorReadyPayload.self)
    }

    private func decodeCanonical<CanonicalValue: Decodable>(
        _ object: [String: Any], as type: CanonicalValue.Type
    ) throws -> CanonicalValue {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try BridgeProductStrictJSON.decode(type, from: data)
    }

    private func assertCanonicalRoundTrip<CanonicalValue: Codable>(
        _ object: [String: Any], as type: CanonicalValue.Type
    ) throws {
        let value = try decodeCanonical(object, as: type)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
        #expect(encoded?.isEqual(to: object) == true)
    }
}
