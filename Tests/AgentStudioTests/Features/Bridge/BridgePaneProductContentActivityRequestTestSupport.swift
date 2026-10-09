import CryptoKit
import Foundation

@testable import AgentStudioBridge

func activityFileContentRequest(
    content: Data,
    identifier: String
) throws -> BridgeProductContentRequest {
    let sha256 = activitySHA256(content)
    let object: [String: Any] = [
        "contentKind": "file.content",
        "contentRequestId": "content-request-\(identifier)",
        "descriptor": [
            "contentKind": "file.content",
            "declaredByteLength": content.count,
            "descriptorId": "file-descriptor-\(identifier)",
            "encoding": "utf-8",
            "expectedSha256": sha256,
            "fileId": "file-\(identifier)",
            "maximumBytes": content.count,
            "source": [
                "repoId": "00000000-0000-4000-8000-000000000001",
                "rootRevisionToken": NSNull(),
                "sourceCursor": "source-cursor-\(identifier)",
                "sourceId": "source-\(identifier)",
                "subscriptionGeneration": 1,
                "worktreeId": "00000000-0000-4000-8000-000000000002",
            ],
            "window": [
                "kind": "prefix",
                "maximumBytes": content.count,
                "maximumLines": BridgeProductWireContract.maximumContentLines,
                "startByte": 0,
            ],
        ],
        "kind": "content.open",
        "leaseId": "lease-\(identifier)",
        "operationCorrelationId": NSNull(),
        "paneSessionId": "pane-session-1",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": "worker-instance-1",
    ]
    return try BridgeProductStrictJSON.decode(
        BridgeProductContentRequest.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

func activityReviewContentRequest(
    content: Data,
    identifier: String
) throws -> BridgeProductReviewContentRequest {
    let sha256 = activitySHA256(content)
    let object: [String: Any] = [
        "contentKind": "review.content",
        "contentRequestId": "content-request-\(identifier)",
        "descriptor": [
            "contentDigest": [
                "algorithm": "sha256",
                "authority": "authoritative",
                "value": sha256,
            ],
            "contentKind": "review.content",
            "declaredByteLength": content.count,
            "descriptorId": "review-descriptor-\(identifier)",
            "encoding": "utf-8",
            "endpointId": "review-endpoint-\(identifier)",
            "expectedSha256": sha256,
            "handleId": "review-handle-\(identifier)",
            "isBinary": false,
            "itemId": "review-item-\(identifier)",
            "language": "swift",
            "maximumBytes": content.count,
            "mimeType": "text/plain",
            "packageId": "review-package-\(identifier)",
            "reviewGeneration": 1,
            "role": "head",
            "sourceIdentity": "review-query-\(identifier)",
            "wholeByteLength": content.count,
            "window": [
                "kind": "byteRange",
                "maximumBytes": content.count,
                "startByte": 0,
            ],
        ],
        "kind": "content.open",
        "leaseId": "lease-\(identifier)",
        "operationCorrelationId": NSNull(),
        "paneSessionId": "pane-session-1",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": "worker-instance-1",
    ]
    let request = try BridgeProductStrictJSON.decode(
        BridgeProductContentRequest.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
    guard case .reviewContent(let reviewRequest) = request else {
        throw ActivityContentAdmissionTestError.expectedReviewRequest
    }
    return reviewRequest
}

func activitySHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

enum ActivityContentAdmissionTestError: Error {
    case expectedProducerFrame
    case expectedReviewRequest
}
