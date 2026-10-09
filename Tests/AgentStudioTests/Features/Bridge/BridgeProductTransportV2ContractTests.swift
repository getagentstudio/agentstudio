import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product v2 wire contracts")
struct BridgeProductTransportV2ContractTests {
    @Test("snapshot cause is required only on snapshot begins", arguments: ["missing", "change", "unknown"])
    func snapshotCauseRejectsInvalidEnvelope(variant: String) throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
        )
        let transport = try #require(corpus["transportV2"] as? [String: Any])
        var frame = try #require(try fixtureArray(named: "batchFrames", in: transport).first)
        frame["snapshotCause"] = "requested"
        switch variant {
        case "missing": frame.removeValue(forKey: "snapshotCause")
        case "change": frame["mode"] = "change"
        default: frame["snapshotCause"] = "not-a-cause"
        }
        #expect(decodingFails(BridgeProductBatchFrame.self, object: frame))
    }

    @Test("snapshot begins round-trip each native cause", arguments: ["open", "requested", "recovery", "newerInput"])
    func snapshotCausesRoundTrip(cause: String) throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
        )
        let transport = try #require(corpus["transportV2"] as? [String: Any])
        var frame = try #require(try fixtureArray(named: "batchFrames", in: transport).first)
        frame["snapshotCause"] = cause
        _ = try decodeAndVerifyRoundTrips(BridgeProductBatchFrame.self, from: [frame])
    }

    @Test("content acknowledgement carries a cumulative per-read sequence")
    func contentAcknowledgementCarriesCumulativeSequence() throws {
        let acknowledgement: [String: Any] = [
            "contentRequestId": "content-request-1",
            "kind": "content.acknowledge",
            "leaseId": "lease-1",
            "paneSessionId": "pane-session-1",
            "receivedThroughContentSequence": 3,
            "wireVersion": 2,
            "workerInstanceId": "worker-instance-1",
        ]
        let decoded = try decodeAndVerifyRoundTrips(
            BridgeProductContentFrameAcknowledgement.self,
            from: [acknowledgement]
        )
        #expect(decoded.count == 1)
    }

    @Test("unknown content read acknowledgement has a definitive typed refusal")
    func unknownContentReadAcknowledgementRefusalRoundTrips() throws {
        let refusal: [String: Any] = [
            "contentRequestId": "content-request-1",
            "kind": "content.acknowledgementRefused",
            "leaseId": "lease-1",
            "paneSessionId": "pane-session-1",
            "reason": "unknownRead",
            "receivedThroughContentSequence": 3,
            "wireVersion": 2,
            "workerInstanceId": "worker-instance-1",
        ]
        let decoded = try decodeAndVerifyRoundTrips(
            BridgeProductContentAcknowledgementRefusedResponse.self,
            from: [refusal]
        )
        #expect(decoded.first?.reason == .unknownRead)
    }

    @Test("shared startup envelope transcript round-trips without running effects")
    func sharedStartupEnvelopeTranscriptRoundTrips() throws {
        let fixture = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-startup-transcript.json"
        )
        let entries = try fixtureArray(named: "envelopeTranscript", in: fixture)
        #expect(entries.count == 4)
        for entry in entries {
            let codec = try #require(entry["codec"] as? String)
            let value = try #require(entry["value"] as? [String: Any])
            switch codec {
            case "operationAdmittedResponse":
                _ = try decodeAndVerifyRoundTrips(BridgeProductOperationAdmittedResponse.self, from: [value])
            case "operationResultRequest":
                _ = try decodeAndVerifyRoundTrips(BridgeProductOperationResultRequest.self, from: [value])
            case "operationResultResponse":
                _ = try decodeAndVerifyRoundTrips(BridgeProductOperationResultResponse.self, from: [value])
            case "operationResultAcknowledgement":
                _ = try decodeAndVerifyRoundTrips(BridgeProductOperationResultAcknowledgement.self, from: [value])
            default:
                Issue.record("Unsupported v2 startup envelope codec: \(codec)")
            }
        }
    }

    @Test("shared v2 operation and sealed-batch envelopes round-trip in Swift")
    func sharedV2TransportEnvelopesRoundTrip() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
        )
        let transport = try #require(corpus["transportV2"] as? [String: Any])

        _ = try decodeAndVerifyRoundTrips(
            BridgeProductOperationAdmittedResponse.self,
            from: try fixtureArray(named: "admittedResponses", in: transport)
        )
        _ = try decodeAndVerifyRoundTrips(
            BridgeProductOperationResultRequest.self,
            from: try fixtureArray(named: "resultRequests", in: transport)
        )
        _ = try decodeAndVerifyRoundTrips(
            BridgeProductOperationResultResponse.self,
            from: try fixtureArray(named: "resultResponses", in: transport)
        )
        _ = try decodeAndVerifyRoundTrips(
            BridgeProductOperationResultAcknowledgement.self,
            from: try fixtureArray(named: "resultAcknowledgements", in: transport)
        )
        _ = try decodeAndVerifyRoundTrips(
            BridgeProductOperationResultAcknowledgedResponse.self,
            from: try fixtureArray(named: "resultAcknowledgedResponses", in: transport)
        )
        _ = try decodeAndVerifyRoundTrips(
            BridgeProductOperationResultAckRefusedResponse.self,
            from: try fixtureArray(named: "resultAckRefusedResponses", in: transport)
        )
        let scopeRequests = try decodeAndVerifyRoundTrips(
            BridgeProductViewScopeRequest.self,
            from: try fixtureArray(named: "viewScopeRequests", in: transport)
        )
        let resnapshotRequests = try decodeAndVerifyRoundTrips(
            BridgeProductViewResnapshotRequest.self,
            from: try fixtureArray(named: "viewResnapshotRequests", in: transport)
        )
        let viewAcknowledgements = try decodeAndVerifyRoundTrips(
            BridgeProductViewAcknowledgementRequest.self,
            from: try fixtureArray(named: "viewAcknowledgements", in: transport)
        )
        let scopeAccepted = try decodeAndVerifyRoundTrips(
            BridgeProductViewAcceptedResponse.self,
            from: try fixtureArray(named: "viewScopeAcceptedResponses", in: transport)
        )
        let resnapshotAccepted = try decodeAndVerifyRoundTrips(
            BridgeProductViewAcceptedResponse.self,
            from: try fixtureArray(named: "viewResnapshotAcceptedResponses", in: transport)
        )
        let acknowledged = try decodeAndVerifyRoundTrips(
            BridgeProductViewAcknowledgedResponse.self,
            from: try fixtureArray(named: "viewAcknowledgedResponses", in: transport)
        )
        #expect(scopeAccepted.first == scopeRequests.first.map(BridgeProductViewAcceptedResponse.init(correlating:)))
        #expect(
            resnapshotAccepted.first
                == resnapshotRequests.first.map(BridgeProductViewAcceptedResponse.init(correlating:)))
        #expect(
            acknowledged.first
                == viewAcknowledgements.first.map(BridgeProductViewAcknowledgedResponse.init(correlating:)))
        let batches = try decodeAndVerifyRoundTrips(
            BridgeProductBatchFrame.self,
            from: try fixtureArray(named: "batchFrames", in: transport)
        )
        #expect(batches.count == 12)
    }

    @Test("shared v2 invalid envelopes fail at the same structural boundary")
    func sharedV2InvalidTransportEnvelopesFail() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/invalid/bridge-product-transport-v2-corpus.json"
        )
        for result in try fixtureArray(named: "resultResponses", in: corpus) {
            #expect(decodingFails(BridgeProductOperationResultResponse.self, object: result))
        }
        for frame in try fixtureArray(named: "batchFrames", in: corpus) {
            #expect(decodingFails(BridgeProductBatchFrame.self, object: frame))
        }
        for acknowledgement in try fixtureArray(named: "viewAcknowledgements", in: corpus) {
            #expect(decodingFails(BridgeProductViewAcknowledgementRequest.self, object: acknowledgement))
        }

        let validCorpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
        )
        let transport = try #require(validCorpus["transportV2"] as? [String: Any])
        var batch = try #require(fixtureArray(named: "batchFrames", in: transport).first)
        batch["scope"] = NSNull()
        #expect(decodingFails(BridgeProductBatchFrame.self, object: batch))

        var reviewBegin = try #require(fixtureArray(named: "batchFrames", in: transport).first)
        reviewBegin.removeValue(forKey: "publicationId")
        #expect(decodingFails(BridgeProductBatchFrame.self, object: reviewBegin))

        var fileBegin = try #require(
            fixtureArray(named: "batchFrames", in: transport).last(where: {
                ($0["kind"] as? String) == "subscription.batchBegin"
            }))
        fileBegin["publicationId"] = "00000000-0000-7000-8000-000000000011"
        #expect(decodingFails(BridgeProductBatchFrame.self, object: fileBegin))
    }

    @Test("File batch rows retain canonical identity and deleted ghosts have no read capability")
    func fileBatchRowsRoundTrip() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-file-batch-row-corpus.json"
        )
        let entries = try fixtureArray(named: "rows", in: corpus)
        #expect(entries.count == 3)
        for entry in entries {
            let recordKey = try #require(entry["recordKey"] as? String)
            #expect(recordKey.hasPrefix("/workspace/"))
            let rowObject = try #require(entry["row"] as? [String: Any])
            let rows = try decodeAndVerifyRoundTrips(BridgeProductFileBatchRow.self, from: [rowObject])
            let row = try #require(rows.first)
            if row.kind != .deleted {
                let sourceRow = BridgeWorktreeTreeRowMetadata(
                    rowId: row.rowId,
                    path: row.displayKey,
                    name: row.name,
                    parentPath: row.parentDisplayKey,
                    depth: row.depth,
                    isDirectory: row.kind == .directory,
                    fileId: row.fileId,
                    fileClass: row.fileClass,
                    sizeBytes: row.sizeBytes,
                    lineCount: row.lineCount,
                    changeStatus: row.changeStatus?.rawValue
                )
                #expect(
                    try BridgeProductFileBatchRow(
                        sourceRow: sourceRow,
                        descriptorOutcome: row.descriptorOutcome
                    ) == row)
            }
            #expect(!row.rowId.isEmpty)
            #expect(!row.name.isEmpty)
            if row.kind == .file {
                #expect(row.fileClass == .source)
                #expect(row.fileId == "file-1")
                #expect(row.sizeBytes == 3)
                #expect(row.lineCount == 1)
                #expect(row.depth == 1)
                #expect(row.descriptorOutcome?.rowId == row.rowId)
                #expect(row.descriptorOutcome?.path == row.displayKey)
            } else {
                #expect(row.fileClass == nil)
                #expect(row.fileId == nil)
                #expect(row.sizeBytes == nil)
                #expect(row.lineCount == nil)
                #expect(row.descriptorOutcome == nil)
            }
            if row.kind == .deleted {
                #expect(row.readDescriptor == nil)
                #expect(row.oldPath != nil)
            }
        }
    }

    @Test("File member-status records preserve source identity and last-good facts")
    func fileMemberStatusRecordsRoundTrip() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-file-batch-row-corpus.json"
        )
        let entries = try fixtureArray(named: "memberStatuses", in: corpus)
        #expect(entries.count == 3)
        for entry in entries {
            #expect(entry["recordKey"] as? String == BridgeProductFileMemberStatusRecord.recordKey)
            let record = try #require(entry["record"] as? [String: Any])
            let decoded = try #require(
                decodeAndVerifyRoundTrips(BridgeProductFileBatchRecord.self, from: [record]).first
            )
            guard case .memberStatus(let status) = decoded else {
                Issue.record("Expected a typed File member-status record")
                continue
            }
            #expect(status.source.sourceId == "source-1")
            #expect(status.branchName == "main")
            #expect(status.ahead == 2)
            #expect(status.behind == 1)
            #expect(status.staged == 3)
            #expect(status.unstaged == 4)
            #expect(status.untracked == 5)
        }
    }

    @Test("File scopes reject future baselines and repeated change kinds")
    func invalidFileChangeFiltersFail() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
        )
        let transport = try #require(corpus["transportV2"] as? [String: Any])
        let requests = try fixtureArray(named: "viewScopeRequests", in: transport)
        var request = try #require(requests.first(where: { $0["requestId"] as? String == "file-scope-all-changes" }))
        var scope = try #require(request["scope"] as? [String: Any])
        var filter = try #require(scope["changeFilter"] as? [String: Any])
        filter["baseline"] = ["kind": "commit", "oid": "abc"]
        scope["changeFilter"] = filter
        request["scope"] = scope
        #expect(decodingFails(BridgeProductViewScopeRequest.self, object: request))

        filter["baseline"] = ["kind": "uncommitted"]
        filter["kinds"] = ["added", "added"]
        scope["changeFilter"] = filter
        request["scope"] = scope
        #expect(decodingFails(BridgeProductViewScopeRequest.self, object: request))
    }

    @Test("comment view scope requires the admitted worktree id")
    func commentViewScopeRequiresWorktreeID() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
        )
        let transport = try #require(corpus["transportV2"] as? [String: Any])
        let requests = try fixtureArray(named: "viewScopeRequests", in: transport)
        var request = try #require(requests.first)
        request["subscriptionKind"] = "file.annotations"
        request["scope"] = ["kind": "comment", "sessionIds": [], "worktreeId": "worktree-1"]
        #expect(!decodingFails(BridgeProductViewScopeRequest.self, object: request))
        request["scope"] = ["kind": "comment"]
        #expect(decodingFails(BridgeProductViewScopeRequest.self, object: request))
        request["scope"] = ["kind": "comment", "worktreeId": "worktree-1"]
        #expect(decodingFails(BridgeProductViewScopeRequest.self, object: request))
    }

    @Test("metadata view scopes require their complete admitted demand")
    func metadataViewScopesRequireDemand() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
        )
        let transport = try #require(corpus["transportV2"] as? [String: Any])
        let requests = try fixtureArray(named: "viewScopeRequests", in: transport)
        let fileRequest = try #require(requests.first { $0["subscriptionKind"] as? String == "file.metadata" })
        let reviewRequest = try #require(requests.first { $0["subscriptionKind"] as? String == "review.metadata" })
        #expect(!decodingFails(BridgeProductViewScopeRequest.self, object: fileRequest))
        #expect(!decodingFails(BridgeProductViewScopeRequest.self, object: reviewRequest))
        for missingDemand in [
            ["kind": "file", "changeFilter": ["kind": "none"], "pathScope": []] as [String: Any],
            ["kind": "file", "changeFilter": ["kind": "none"], "interests": []] as [String: Any],
        ] {
            var request = fileRequest
            request["scope"] = missingDemand
            #expect(decodingFails(BridgeProductViewScopeRequest.self, object: request))
        }
        var wrongReview = reviewRequest
        wrongReview["scope"] = ["kind": "review"]
        #expect(decodingFails(BridgeProductViewScopeRequest.self, object: wrongReview))
        wrongReview = fileRequest
        wrongReview["scope"] = ["kind": "review", "interests": []]
        #expect(decodingFails(BridgeProductViewScopeRequest.self, object: wrongReview))
    }

    @Test("typed view scopes expose exactly the admitted File and Review demand")
    func typedViewScopesExposeAdmittedDemand() throws {
        let fileScope = BridgeProductJSONValue.object([
            "kind": .string("file"),
            "changeFilter": .object(["kind": .string("none")]),
            "interests": .array([
                .object([
                    "lane": .string("foreground"),
                    "paths": .array([.string("src/current.ts")]),
                ])
            ]),
            "pathScope": .array([.string("src")]),
        ])
        try BridgeProductViewScopeContract.validate(fileScope, codingPath: [])
        let fileDemand = try BridgeProductViewScopeContract.fileDemand(from: fileScope)
        #expect(fileDemand.interests.first?.lane == .foreground)
        #expect(fileDemand.interests.first?.paths == ["src/current.ts"])
        #expect(fileDemand.pathScope == ["src"])
        let changedFileDemand = BridgeProductJSONValue.object([
            "kind": .string("file"),
            "changeFilter": .object(["kind": .string("none")]),
            "interests": .array([]),
            "pathScope": .array([.string("src")]),
        ])
        let changedFileFilter = BridgeProductJSONValue.object([
            "kind": .string("file"),
            "changeFilter": .object([
                "kind": .string("changes"),
                "baseline": .object(["kind": .string("uncommitted")]),
                "kinds": .array([.string("modified")]),
            ]),
            "interests": .array([]),
            "pathScope": .array([.string("src")]),
        ])
        #expect(BridgeProductViewScopeContract.hasSameMembershipFilter(fileScope, changedFileDemand))
        #expect(!BridgeProductViewScopeContract.hasSameMembershipFilter(fileScope, changedFileFilter))
        let changedFilePathScope = BridgeProductJSONValue.object([
            "kind": .string("file"),
            "changeFilter": .object(["kind": .string("none")]),
            "interests": .array([]),
            "pathScope": .array([.string("Sources")]),
        ])
        #expect(!BridgeProductViewScopeContract.hasSameMembershipFilter(fileScope, changedFilePathScope))

        let reviewScope = BridgeProductJSONValue.object([
            "kind": .string("review"),
            "interests": .array([
                .object([
                    "lane": .string("active"),
                    "itemIds": .array([.string("review-item-1")]),
                ])
            ]),
        ])
        try BridgeProductViewScopeContract.validate(reviewScope, codingPath: [])
        let reviewDemand = try BridgeProductViewScopeContract.reviewDemand(from: reviewScope)
        #expect(reviewDemand.interests.first?.lane == .active)
        #expect(reviewDemand.interests.first?.itemIds == ["review-item-1"])
        #expect(
            BridgeProductViewScopeContract.hasSameMembershipFilter(
                reviewScope, .object(["kind": .string("review"), "interests": .array([])])
            )
        )
        let commentScope = BridgeProductJSONValue.object([
            "kind": .string("comment"), "worktreeId": .string("worktree-1"), "sessionIds": .array([]),
        ])
        #expect(
            BridgeProductViewScopeContract.hasSameMembershipFilter(
                commentScope,
                .object([
                    "kind": .string("comment"), "worktreeId": .string("worktree-1"),
                    "sessionIds": .array([.string("session-1")]),
                ])
            ))
        #expect(
            !BridgeProductViewScopeContract.hasSameMembershipFilter(
                commentScope,
                .object([
                    "kind": .string("comment"), "worktreeId": .string("worktree-2"),
                    "sessionIds": .array([]),
                ])
            ))
    }

    @Test("a deleted File row cannot carry a read descriptor")
    func deletedFileRowCannotBeOpened() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-file-batch-row-corpus.json"
        )
        let entries = try fixtureArray(named: "rows", in: corpus)
        let descriptorRow = try #require(entries.first?["row"] as? [String: Any])
        let descriptor = try #require(descriptorRow["readDescriptor"] as? [String: Any])
        var ghost = try #require(entries.last?["row"] as? [String: Any])
        ghost["readDescriptor"] = descriptor
        #expect(decodingFails(BridgeProductFileBatchRow.self, object: ghost))
    }

    @Test("comment catalog records keep wire and semantic revisions independent")
    func commentCatalogRecordsRoundTrip() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-comment-catalog-record-corpus.json"
        )
        let entries = try fixtureArray(named: "records", in: corpus)
        #expect(entries.count == 4)
        for entry in entries {
            let expectedKey = try #require(entry["recordKey"] as? String)
            let recordObject = try #require(entry["record"] as? [String: Any])
            let records = try decodeAndVerifyRoundTrips(BridgeProductCommentCatalogRecord.self, from: [recordObject])
            #expect(records.first?.recordKey == expectedKey)
        }
    }

    @Test("contribution publications round-trip a required null reviewed branch")
    func contributionPublicationWithNullBranchRoundTrips() throws {
        let recordObject = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-review-contribution-null-branch.json"
        )
        let records = try decodeAndVerifyRoundTrips(BridgeProductReviewBatchRecord.self, from: [recordObject])
        guard case .publication(let publication) = try #require(records.first),
            let displayed = publication.displayed,
            case .contribution(let origin) = displayed.comparisonOrigin
        else {
            Issue.record("Expected a displayed contribution publication")
            return
        }
        #expect(origin.reviewedSubjectBranchName == nil)
    }

    @Test("Review batch records retain item order and explicit role capability")
    func reviewBatchRecordsRoundTrip() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-review-batch-record-corpus.json"
        )
        let entries = try fixtureArray(named: "records", in: corpus)
        #expect(entries.count == 3)
        for entry in entries {
            let recordKey = try #require(entry["recordKey"] as? String)
            let recordObject = try #require(entry["record"] as? [String: Any])
            let records = try decodeAndVerifyRoundTrips(BridgeProductReviewBatchRecord.self, from: [recordObject])
            switch try #require(records.first) {
            case .item(let item):
                #expect(item.itemId == recordKey)
                #expect(item.sortKey == 0)
            case .publication(let publication):
                #expect(recordKey == "publication")
                #expect(publication.revision > 0)
                if let displayed = publication.displayed {
                    #expect(displayed.revision == 0)
                    #expect(publication.publicationId != displayed.publicationId)
                    #expect(publication.desired.status == .failedRetryable)
                }
            }
        }

        var item = try #require(entries.first?["record"] as? [String: Any])
        var contentByRole = try #require(item["contentByRole"] as? [String: Any])
        var head = try #require(contentByRole["head"] as? [String: Any])
        var source = try #require(head["source"] as? [String: Any])
        source["itemId"] = "another-item"
        head["source"] = source
        contentByRole["head"] = head
        item["contentByRole"] = contentByRole
        #expect(decodingFails(BridgeProductReviewBatchRecord.self, object: item))

        var publication = try #require(entries[1]["record"] as? [String: Any])
        publication.removeValue(forKey: "publicationId")
        #expect(decodingFails(BridgeProductReviewBatchRecord.self, object: publication))
    }

    @Test("revision-aware mutation observation has distinct unknown and late evidence")
    func mutationObservationRoundTrips() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-operation-observation-corpus.json"
        )
        _ = try decodeAndVerifyRoundTrips(
            BridgeProductOperationObservationRequest.self,
            from: try fixtureArray(named: "observeRequests", in: corpus)
        )
        let responses = try decodeAndVerifyRoundTrips(
            BridgeProductOperationObservationResponse.self,
            from: try fixtureArray(named: "observeResponses", in: corpus)
        )
        #expect(responses.count == 2)
        _ = try decodeAndVerifyRoundTrips(
            BridgeProductOperationLateOutcomeAcknowledgement.self,
            from: try fixtureArray(named: "lateOutcomeAcknowledgements", in: corpus)
        )
    }

    @Test("sealed batch frames use the production metadata stream codec")
    func sealedBatchesUseMetadataStreamCodec() throws {
        let corpus = try fixtureJSONObject(
            relativePath: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
        )
        let transport = try #require(corpus["transportV2"] as? [String: Any])
        let frames = try decodeAndVerifyRoundTrips(
            BridgeProductMetadataFrame.self,
            from: try fixtureArray(named: "batchFrames", in: transport)
        )
        let decoder = try BridgeProductMetadataFrameDecoder()
        for frame in frames {
            let decoded = try decoder.append(BridgeProductMetadataFrameCodec.encode(frame))
            #expect(decoded == [frame])
        }
        try decoder.finish()
    }

    private func decodeAndVerifyRoundTrips<CodableValue: Codable>(
        _ type: CodableValue.Type,
        from objects: [[String: Any]]
    ) throws -> [CodableValue] {
        try objects.map { object in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let value: CodableValue
            do {
                value = try BridgeProductStrictJSON.decode(type, from: data)
            } catch {
                let kind = String(describing: object["kind"] ?? "missing")
                let batchId = String(describing: object["batchId"] ?? "none")
                Issue.record("Failed to decode \(String(describing: type)) kind=\(kind) batchId=\(batchId): \(error)")
                throw error
            }
            let encodedData = try JSONEncoder().encode(value)
            let encodedObject = try #require(JSONSerialization.jsonObject(with: encodedData) as? NSDictionary)
            #expect(encodedObject.isEqual(to: object))
            return value
        }
    }

    private func decodingFails<CodableValue: Codable>(
        _ type: CodableValue.Type,
        object: [String: Any]
    ) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return true
        }
        do {
            _ = try BridgeProductStrictJSON.decode(type, from: data)
            return false
        } catch {
            return true
        }
    }

    private func fixtureArray(named name: String, in object: [String: Any]) throws -> [[String: Any]] {
        try #require(object[name] as? [[String: Any]])
    }

    private func fixtureJSONObject(relativePath: String) throws -> [String: Any] {
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let data = try Data(contentsOf: projectRoot.appending(path: relativePath))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
