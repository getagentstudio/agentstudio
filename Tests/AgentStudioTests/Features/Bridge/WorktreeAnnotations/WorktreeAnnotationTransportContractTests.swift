import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

struct WorktreeAnnotationTransportContractTests {
    @Test("annotation projection stale result carries current source authority")
    func annotationProjectionStaleResultCarriesCurrentSourceAuthority() throws {
        for method in [
            "file.annotations.projection.query",
            "review.annotations.projection.query",
        ] {
            let result = try decodeStrict(
                BridgeProductCallResult.self,
                object: [
                    "method": method,
                    "result": [
                        "currentSourceGeneration": 12,
                        "kind": "source_stale",
                    ],
                ]
            )
            switch result {
            case .fileAnnotationsProjectionQuery(.sourceStale(let currentSourceGeneration)),
                .reviewAnnotationsProjectionQuery(.sourceStale(let currentSourceGeneration)):
                #expect(currentSourceGeneration == 12)
            default:
                Issue.record("Expected a typed stale annotation projection result")
            }
        }

        #expect(throws: (any Error).self) {
            _ = try decodeStrict(
                BridgeProductCallResult.self,
                object: [
                    "method": "file.annotations.projection.query",
                    "result": [
                        "currentSourceGeneration": -1,
                        "kind": "source_stale",
                    ],
                ]
            )
        }
    }

    @Test("File and Review annotation commands use one strict logical operation contract")
    func fileAndReviewCommandsUseStrictSharedOperationContract() throws {
        for (method, expectedSurface) in [
            ("file.annotations.command", BridgeProductSurface.file),
            ("review.annotations.command", BridgeProductSurface.review),
        ] {
            var commandRequest: [String: Any] = [
                "operation": ["kind": "session.discover"]
            ]
            if expectedSurface == .review {
                commandRequest["reviewPublicationIdentity"] = reviewAnnotationPublicationIdentity()
            }
            let request = try decodeStrict(
                BridgeProductCallRequest.self,
                object: [
                    "method": method,
                    "request": commandRequest,
                ]
            )
            #expect(request.method == method)
            #expect(request.surface == expectedSurface)

            let result = try decodeStrict(
                BridgeProductCallResult.self,
                object: [
                    "method": method,
                    "result": [
                        "kind": "completed",
                        "outcome": [
                            "requestId": "annotation-product-call-1",
                            "sessionId": NSNull(),
                            "status": ["kind": "committed"],
                            "surface": expectedSurface == .file ? "file" : "review",
                        ],
                    ],
                ]
            )
            #expect(result.method == method)
            #expect(result.surface == expectedSurface)
        }

        #expect(throws: (any Error).self) {
            _ = try decodeStrict(
                BridgeProductCallResult.self,
                object: [
                    "method": "file.annotations.command",
                    "result": ["kind": "completed"],
                ]
            )
        }

        #expect(throws: (any Error).self) {
            _ = try decodeStrict(
                BridgeProductCallRequest.self,
                object: [
                    "method": "file.annotations.command",
                    "request": [
                        "operation": ["kind": "session.discover"],
                        "unexpected": true,
                    ],
                ]
            )
        }
        #expect(throws: (any Error).self) {
            _ = try decodeStrict(
                BridgeProductCallRequest.self,
                object: [
                    "method": "review.annotations.command",
                    "request": [
                        "operation": ["kind": "thread.delete"],
                        "reviewPublicationIdentity": reviewAnnotationPublicationIdentity(),
                    ],
                ]
            )
        }

        #expect(throws: (any Error).self) {
            _ = try decodeStrict(
                BridgeProductCallRequest.self,
                object: [
                    "method": "review.annotations.command",
                    "request": ["operation": ["kind": "session.discover"]],
                ]
            )
        }
        #expect(throws: (any Error).self) {
            _ = try decodeStrict(
                BridgeProductCallRequest.self,
                object: [
                    "method": "file.annotations.command",
                    "request": [
                        "operation": ["kind": "session.discover"],
                        "reviewPublicationIdentity": reviewAnnotationPublicationIdentity(),
                    ],
                ]
            )
        }
    }

    @Test("annotation command registry covers the complete PR1 operation vocabulary")
    func commandRegistryCoversCompletePR1Vocabulary() throws {
        let sessionID = "00000000-0000-7000-8000-000000000011"
        let threadID = "00000000-0000-7000-8000-000000000012"
        let messageID = "00000000-0000-7000-8000-000000000013"
        let attemptID = "00000000-0000-7000-8000-000000000015"
        let operations =
            annotationLifecycleOperations(
                sessionID: sessionID,
                threadID: threadID,
                messageID: messageID
            )
            + annotationOutputOperations(
                sessionID: sessionID,
                messageID: messageID,
                attemptID: attemptID
            )

        for operation in operations {
            do {
                _ = try decodeStrict(
                    BridgeProductCallRequest.self,
                    object: [
                        "method": "file.annotations.command",
                        "request": ["operation": operation],
                    ]
                )
            } catch {
                Issue.record("Failed to decode annotation operation \(operation): \(error)")
            }
        }
    }

    @Test("message viewed commands and results are bounded exact-revision contracts")
    func messageViewedCommandsAndResultsAreBoundedExactRevisionContracts() throws {
        let sessionID = "00000000-0000-7000-8000-000000000011"
        let messageID = "00000000-0000-7000-8000-000000000013"
        let item: [String: Any] = ["expectedSavedRevision": 2, "messageId": messageID]
        let uniqueItems = (0..<257).map { index in
            [
                "expectedSavedRevision": index + 1,
                "messageId": String(format: "00000000-0000-7000-8000-%012llx", index),
            ] as [String: Any]
        }
        _ = try decodeAnnotationCommand(
            method: "file.annotations.command",
            operation: ["items": [item], "kind": "message.viewed.mark", "sessionId": sessionID]
        )
        _ = try decodeAnnotationCommand(
            method: "file.annotations.command",
            operation: [
                "items": Array(uniqueItems.prefix(256)),
                "kind": "message.viewed.mark",
                "sessionId": sessionID,
            ]
        )
        for items in [[], [item, item], uniqueItems] {
            #expect(throws: (any Error).self) {
                _ = try decodeAnnotationCommand(
                    method: "file.annotations.command",
                    operation: ["items": items, "kind": "message.viewed.mark", "sessionId": sessionID]
                )
            }
        }

        _ = try decodeStrict(
            BridgeProductCallResult.self,
            object: [
                "method": "file.annotations.command",
                "result": [
                    "kind": "completed",
                    "outcome": [
                        "receipt": NSNull(),
                        "requestId": "annotation-viewed-1",
                        "sessionId": sessionID,
                        "status": [
                            "kind": "viewed",
                            "results": [
                                [
                                    "committedSessionRevision": 9,
                                    "disposition": "changed",
                                    "kind": "viewed",
                                    "messageId": messageID,
                                    "savedRevision": 2,
                                ],
                                [
                                    "disposition": "not_agent",
                                    "expectedSavedRevision": 3,
                                    "kind": "not_viewed",
                                    "messageId": "00000000-0000-7000-8000-000000000014",
                                ],
                            ],
                        ],
                        "surface": "file",
                    ],
                ],
            ]
        )
        #expect(throws: (any Error).self) {
            _ = try decodeStrict(
                BridgeProductCallResult.self,
                object: [
                    "method": "file.annotations.command",
                    "result": [
                        "kind": "completed",
                        "outcome": [
                            "receipt": NSNull(),
                            "requestId": "annotation-viewed-invalid",
                            "sessionId": sessionID,
                            "status": [
                                "kind": "viewed",
                                "results": [
                                    [
                                        "disposition": "not_agent",
                                        "expectedSavedRevision": 2,
                                        "kind": "not_viewed",
                                        "messageId": messageID,
                                        "unexpected": true,
                                    ]
                                ],
                            ],
                            "surface": "file",
                        ],
                    ],
                ]
            )
        }
    }

    private func annotationLifecycleOperations(
        sessionID: String,
        threadID: String,
        messageID: String
    ) -> [[String: Any]] {
        let commonIdentityFields: [String: Any] = ["sessionId": sessionID]
        return [
            ["kind": "session.discover"],
            ["kind": "demand.acquire", "sessionId": sessionID],
            ["kind": "demand.release", "sessionId": sessionID],
            [
                "admission": ["kind": "implicitOrSingle"],
                "body": "Durable draft",
                "editToken": "edit-token-1",
                "kind": "root.create",
                "origin": [
                    "diffSide": NSNull(),
                    "endLine": 14,
                    "kind": "located",
                    "path": "Sources/Feature.swift",
                    "sourceIdentity": "source-1",
                    "sourceRole": "file",
                    "startLine": 12,
                ],
            ],
            commonIdentityFields.merging([
                "body": "Reply draft",
                "editToken": "edit-token-2",
                "expectedThreadRevision": 4,
                "kind": "reply.create",
                "threadId": threadID,
            ]) { _, new in new },
            commonIdentityFields.merging([
                "body": "Updated draft",
                "editToken": "edit-token-1",
                "expectedDraftRevision": 2,
                "expectedMessageRevision": 4,
                "kind": "draft.flush",
                "messageId": messageID,
            ]) { _, new in new },
            commonIdentityFields.merging([
                "editToken": "edit-token-1",
                "expectedDraftRevision": 3,
                "expectedMessageRevision": 4,
                "kind": "draft.save",
                "messageId": messageID,
            ]) { _, new in new },
            commonIdentityFields.merging([
                "editToken": "edit-token-1",
                "expectedDraftRevision": 3,
                "expectedMessageRevision": 4,
                "kind": "draft.revert",
                "messageId": messageID,
            ]) { _, new in new },
            commonIdentityFields.merging([
                "expectedThreadRevision": 4,
                "kind": "thread.resolution.set",
                "resolution": "resolved",
                "threadId": threadID,
            ]) { _, new in new },
            commonIdentityFields.merging([
                "confirmsUnresolvedWork": true,
                "expectedOpenThreadCount": 2,
                "expectedSessionRevision": 4,
                "kind": "session.lifecycle.set",
                "lifecycle": "completed",
            ]) { _, new in new },
            commonIdentityFields.merging([
                "decision": "acceptCurrentSource",
                "expectedSessionRevision": 4,
                "kind": "continuity.choose",
            ]) { _, new in new },
            [
                "kind": "source.refresh",
                "sessionId": sessionID,
                "sourceEpoch": 5,
            ],
        ]
    }

    private func annotationOutputOperations(
        sessionID: String,
        messageID _: String,
        attemptID: String
    ) -> [[String: Any]] {
        [
            [
                "destination": "remembered",
                "displayedProjectionRevision": 9,
                "expectedSessionRevision": 4,
                "kind": "output.scope.commit",
                "outputKind": "jsonFile",
                "scope": "pending",
                "sessionId": sessionID,
                "sourceGeneration": 7,
            ],
            ["kind": "output.preference.changeFolder"],
            ["attemptId": attemptID, "kind": "output.reveal"],
            [
                "displayedProjectionRevision": 9,
                "expectedSessionRevision": 4,
                "kind": "output.scope.commit",
                "outputKind": "clipboardMarkdown",
                "scope": "pending",
                "sessionId": sessionID,
                "sourceGeneration": 7,
            ],
            [
                "attemptId": attemptID,
                "expectedSessionRevision": 4,
                "kind": "output.handled.clear",
            ],
            ["kind": "output.history", "sessionId": sessionID],
            ["attemptId": attemptID, "kind": "output.repeat"],
            ["kind": "recovery.acknowledge"],
        ]
    }

    @Test("annotation commands reject invalid identities, source coordinates, body size, and selection")
    func annotationCommandsRejectInvalidPayloads() {
        let sessionID = "00000000-0000-7000-8000-000000000011"
        let messageID = "00000000-0000-7000-8000-000000000013"
        let validLocatedOrigin: [String: Any] = [
            "diffSide": NSNull(),
            "endLine": 14,
            "kind": "located",
            "path": "Sources/Feature.swift",
            "sourceIdentity": "source-1",
            "sourceRole": "file",
            "startLine": 12,
        ]

        let invalidOperations: [[String: Any]] = [
            ["kind": "demand.acquire", "sessionId": "00000000-0000-4000-8000-000000000011"],
            [
                "admission": ["kind": "implicitOrSingle"],
                "body": "Forbidden whole-file annotation",
                "editToken": "edit-token-1",
                "kind": "root.create",
                "origin": [
                    "kind": "wholeFile",
                    "path": "Sources/Feature.swift",
                    "sourceIdentity": "source-1",
                    "sourceRole": "file",
                ],
            ],
            [
                "admission": ["kind": "implicitOrSingle"],
                "body": "Forbidden session annotation",
                "editToken": "edit-token-1",
                "kind": "root.create",
                "origin": ["kind": "session", "sourceIdentity": "source-1"],
            ],
            [
                "admission": ["kind": "implicitOrSingle"],
                "body": "Invalid range",
                "editToken": "edit-token-1",
                "kind": "root.create",
                "origin": validLocatedOrigin.merging(["endLine": 11]) { _, new in new },
            ],
            [
                "admission": ["kind": "implicitOrSingle"],
                "body": String(repeating: "é", count: 8193),
                "editToken": "edit-token-1",
                "kind": "root.create",
                "origin": validLocatedOrigin,
            ],
            [
                "kind": "output.selection.begin",
                "outputKind": "clipboardMarkdown",
                "selectionMode": "explicit",
                "sessionId": sessionID,
                "transferId": "transfer-1",
            ],
            [
                "kind": "output.selection.chunk",
                "messageIds": [],
                "ordinal": 0,
                "selectionMode": "explicit",
                "sessionId": sessionID,
                "transferId": "transfer-1",
            ],
            [
                "displayedProjectionRevision": 9,
                "expectedSessionRevision": 4,
                "kind": "output.scope.commit",
                "outputKind": "clipboardMarkdown",
                "scope": "pending",
                "sessionId": sessionID,
            ],
            [
                "kind": "output.selection.chunk",
                "messageIds": [messageID],
                "ordinal": 0,
                "selectionMode": "explicit",
                "sessionId": sessionID,
                "transferId": "transfer-1",
                "unexpected": true,
            ],
            [
                "kind": "source.refresh",
                "sessionId": sessionID,
                "sourceEpoch": -1,
            ],
            [
                "kind": "source.refresh",
                "sessionId": sessionID,
                "sourceEpoch": 5,
                "unexpected": true,
            ],
            ["kind": "thread.delete", "sessionId": sessionID],
            ["attemptId": "00000000-0000-7000-8000-000000000015", "kind": "output.inspect"],
        ]

        for operation in invalidOperations {
            #expect(throws: (any Error).self) {
                _ = try decodeAnnotationCommand(method: "file.annotations.command", operation: operation)
            }
        }
    }

    @Test("JSON output requires a destination while clipboard output forbids one")
    func outputDestinationIsStrictByKind() {
        let sessionID = "00000000-0000-7000-8000-000000000011"
        let outputOperation: [String: Any] = [
            "displayedProjectionRevision": 9,
            "expectedSessionRevision": 4,
            "kind": "output.scope.commit",
            "outputKind": "jsonFile",
            "scope": "pending",
            "sessionId": sessionID,
            "sourceGeneration": 7,
        ]
        for operation in [
            outputOperation,
            outputOperation.merging([
                "destination": "choose",
                "outputKind": "clipboardMarkdown",
            ]) { _, new in new },
        ] {
            #expect(throws: (any Error).self) {
                _ = try decodeAnnotationCommand(method: "file.annotations.command", operation: operation)
            }
        }
    }

    @Test("File and Review output inspection queries return strict annotation output descriptors")
    func outputInspectionQueriesReturnSurfaceBoundContentDescriptors() throws {
        let attemptID = "00000000-0000-7000-8000-000000000015"
        let descriptorID = "00000000-0000-7000-8000-000000000016"
        let digest = String(repeating: "a", count: 64)

        for (method, surface) in [
            ("file.annotations.output.inspect", BridgeProductSurface.file),
            ("review.annotations.output.inspect", BridgeProductSurface.review),
        ] {
            let request = try decodeStrict(
                BridgeProductCallRequest.self,
                object: [
                    "method": method,
                    "request": ["attemptId": attemptID],
                ]
            )
            #expect(request.method == method)
            #expect(request.surface == surface)

            let descriptor: [String: Any] = [
                "attemptId": attemptID,
                "contentKind": "annotation.output",
                "contentType": "text/markdown; charset=utf-8",
                "declaredByteLength": 5,
                "descriptorId": descriptorID,
                "encoding": "utf-8",
                "expectedSha256": digest,
                "formatVersion": 1,
                "maximumBytes": 5,
                "outputKind": "clipboard_markdown",
                "surface": surface.rawValue,
            ]
            let result = try decodeStrict(
                BridgeProductCallResult.self,
                object: [
                    "method": method,
                    "result": ["descriptor": descriptor],
                ]
            )
            #expect(result.method == method)
            #expect(result.surface == surface)

            let contentRequest = try decodeStrict(
                BridgeProductContentRequest.self,
                object: [
                    "contentKind": "annotation.output",
                    "contentRequestId": "annotation-output-content-1",
                    "descriptor": descriptor,
                    "kind": "content.open",
                    "leaseId": "annotation-output-lease-1",
                    "operationCorrelationId": NSNull(),
                    "paneSessionId": "00000000-0000-7000-8000-000000000001",
                    "wireVersion": 2,
                    "workerDerivationEpoch": 0,
                    "workerInstanceId": "00000000-0000-7000-8000-000000000002",
                ]
            )
            #expect(contentRequest.surface == surface)
            #expect(contentRequest.admission.identity.surface == surface)

            var wrongSurfaceDescriptor = descriptor
            wrongSurfaceDescriptor["surface"] = surface == .file ? "review" : "file"
            #expect(throws: (any Error).self) {
                _ = try decodeStrict(
                    BridgeProductCallResult.self,
                    object: [
                        "method": method,
                        "result": ["descriptor": wrongSurfaceDescriptor],
                    ]
                )
            }
        }
    }

    @Test("annotation source roles must match the File or Review surface")
    func annotationSourceRolesMatchSurface() throws {
        let commonRoot: [String: Any] = [
            "admission": ["kind": "implicitOrSingle"],
            "body": "Surface-bound origin",
            "editToken": "edit-token-1",
            "kind": "root.create",
        ]
        let fileOrigin: [String: Any] = [
            "diffSide": NSNull(),
            "endLine": 4,
            "kind": "located",
            "path": "Sources/Feature.swift",
            "sourceIdentity": "source-1",
            "sourceRole": "file",
            "startLine": 4,
        ]
        let reviewOrigin: [String: Any] = [
            "diffSide": "additions",
            "endLine": 4,
            "kind": "located",
            "path": "Sources/Feature.swift",
            "sourceIdentity": "source-1",
            "sourceRole": "reviewHead",
            "startLine": 4,
        ]

        let fileRequest = try decodeAnnotationCommand(
            method: "file.annotations.command",
            operation: commonRoot.merging(["origin": fileOrigin]) { _, new in new }
        )
        let reviewRequest = try decodeAnnotationCommand(
            method: "review.annotations.command",
            operation: commonRoot.merging(["origin": reviewOrigin]) { _, new in new }
        )
        let encodedFileRequest = try #require(
            String(data: JSONEncoder().encode(fileRequest), encoding: .utf8)
        )
        let encodedReviewRequest = try #require(
            String(data: JSONEncoder().encode(reviewRequest), encoding: .utf8)
        )
        #expect(encodedFileRequest.contains("\"kind\":\"located\""))
        #expect(encodedReviewRequest.contains("\"kind\":\"located\""))
        #expect(throws: (any Error).self) {
            _ = try decodeAnnotationCommand(
                method: "file.annotations.command",
                operation: commonRoot.merging(["origin": reviewOrigin]) { _, new in new }
            )
        }
        #expect(throws: (any Error).self) {
            _ = try decodeAnnotationCommand(
                method: "review.annotations.command",
                operation: commonRoot.merging(["origin": fileOrigin]) { _, new in new }
            )
        }
    }
}

private func reviewAnnotationPublicationIdentity() -> [String: Any] {
    [
        "packageId": "package-installed",
        "publicationId": "00000000-0000-7000-8000-000000000041",
        "reviewGeneration": 7,
        "revision": 3,
        "sourceIdentity": "source-installed",
    ]
}

private func decodeAnnotationCommand(
    method: String,
    operation: [String: Any]
) throws -> BridgeProductCallRequest {
    var request: [String: Any] = ["operation": operation]
    if method == "review.annotations.command" {
        request["reviewPublicationIdentity"] = reviewAnnotationPublicationIdentity()
    }
    return try decodeStrict(
        BridgeProductCallRequest.self,
        object: [
            "method": method,
            "request": request,
        ]
    )
}

private func decodeStrict<TValue: Decodable>(
    _ type: TValue.Type,
    object: [String: Any]
) throws -> TValue {
    try BridgeProductStrictJSON.decode(
        type,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}
