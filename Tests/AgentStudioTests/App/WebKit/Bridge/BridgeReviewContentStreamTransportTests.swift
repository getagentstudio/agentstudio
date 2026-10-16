import CryptoKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgeReviewContentStreamTransportTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("modified review file streams base and head content through direct product authority")
        func modifiedReviewFileStreamsBaseAndHeadContentThroughDirectProductAuthority() async throws {
            // Arrange
            let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-ref-HEAD-1", kind: .gitRef)
            let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
            let baseText = "old source with extra bytes\nlet oldOnly = true\n"
            let headText = "new source\n"
            let changedFile = makeBridgeEndpointChangedFile(
                fileId: "source",
                path: "Sources/App/View.swift",
                sizeBytes: Data(headText.utf8).count,
                oldContentHash: bridgeSHA256ContentHash(baseText),
                newContentHash: bridgeSHA256ContentHash(headText)
            )
            let expectedBaseHandle = BridgeReviewPackageBuilder.contentHandle(
                for: changedFile,
                endpoint: baseEndpoint,
                role: .base,
                reviewGeneration: 1
            )
            let expectedHeadHandle = BridgeReviewPackageBuilder.contentHandle(
                for: changedFile,
                endpoint: headEndpoint,
                role: .head,
                reviewGeneration: 1
            )
            let comparison = BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                changedFiles: [changedFile]
            )
            let provider = BridgeReviewSourceProviderFake(
                comparison: comparison,
                contentByHandleId: [
                    expectedBaseHandle.handleId: makeContentResult(handle: expectedBaseHandle, data: baseText),
                    expectedHeadHandle.handleId: makeContentResult(handle: expectedHeadHandle, data: headText),
                ],
                contributionCapture: BridgeContributionComparisonCapture(
                    resolvedTargetOID: baseEndpoint.providerIdentity,
                    reviewedHeadOID: headEndpoint.providerIdentity,
                    baseRole: .commonCommit,
                    baseOID: baseEndpoint.providerIdentity,
                    comparison: comparison
                )
            )
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: .ref(name: "HEAD~1"))
                ),
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            try await showReviewInNativeFixture(controller)

            let result = await controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: headEndpoint.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: UUID(),
                correlationId: nil
            )
            guard case .success = result else {
                Issue.record("Expected Review diff load to succeed")
                return
            }
            let package = try #require(controller.paneState.diff.packageMetadata)
            let contentSource = Self.contentSource(controller: controller)
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let baseRequest = try Self.contentRequest(
                handle: expectedBaseHandle,
                package: package,
                content: Data(baseText.utf8)
            )
            let headRequest = try Self.contentRequest(
                handle: expectedHeadHandle,
                package: package,
                content: Data(headText.utf8)
            )

            // Act
            let baseBody = try await contentSource.contentBody(
                for: baseRequest,
                productAdmission: productAdmission
            )
            let headBody = try await contentSource.contentBody(
                for: headRequest,
                productAdmission: productAdmission
            )

            // Assert
            #expect(expectedBaseHandle.sizeBytesIsExact == false)
            #expect(expectedHeadHandle.sizeBytesIsExact)
            #expect(baseBody.data == Data(baseText.utf8))
            #expect(headBody.data == Data(headText.utf8))
            #expect(baseBody.isFinalRange)
            #expect(headBody.isFinalRange)
            #expect(await provider.recordedContentRequestsCount(handleId: expectedBaseHandle.handleId) == 1)
            #expect(await provider.recordedContentRequestsCount(handleId: expectedHeadHandle.handleId) == 1)
        }

        private static func contentSource(
            controller: BridgePaneController
        ) -> BridgePaneProductReviewContentSource {
            BridgePaneProductReviewContentSource(
                loaderCache: controller.reviewContentLoaderCache,
                acquireContentLease: { descriptor, admission in
                    controller.reviewPublicationCoordinator.acquireContentLease(
                        handleId: descriptor.descriptorId,
                        packageId: descriptor.packageId,
                        requestedGeneration: BridgeReviewGeneration(descriptor.reviewGeneration),
                        sourceIdentity: descriptor.sourceIdentity,
                        productAdmission: admission
                    )
                },
                settleContentLease: { lease in
                    controller.reviewPublicationCoordinator.settleContentLease(lease)
                }
            )
        }

        private static func contentRequest(
            handle: BridgeContentHandle,
            package: BridgeReviewPackage,
            content: Data
        ) throws -> BridgeProductReviewContentRequest {
            let rawSHA256 = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            let wholeByteLength: Any =
                handle.sizeBytesIsExact ? content.count : NSNull()
            let object: [String: Any] = [
                "contentKind": "review.content",
                "contentRequestId": "request-\(handle.role.rawValue)",
                "descriptor": [
                    "contentDigest": [
                        "algorithm": "sha256",
                        "authority": "authoritative",
                        "value": rawSHA256,
                    ],
                    "contentKind": "review.content",
                    "declaredByteLength": content.count,
                    "descriptorId": handle.handleId,
                    "encoding": "utf-8",
                    "endpointId": handle.endpointId,
                    "expectedSha256": rawSHA256,
                    "handleId": handle.handleId,
                    "isBinary": handle.isBinary,
                    "itemId": handle.itemId,
                    "language": handle.language.map { $0 as Any } ?? NSNull(),
                    "maximumBytes": content.count,
                    "mimeType": handle.mimeType,
                    "packageId": package.packageId,
                    "reviewGeneration": handle.reviewGeneration.rawValue,
                    "role": handle.role.rawValue,
                    "sourceIdentity": package.query.queryId,
                    "wholeByteLength": wholeByteLength,
                    "window": [
                        "kind": "byteRange",
                        "maximumBytes": content.count,
                        "startByte": 0,
                    ],
                ],
                "kind": "content.open",
                "leaseId": "lease-\(handle.role.rawValue)",
                "operationCorrelationId": NSNull(),
                "paneSessionId": "pane-session-1",
                "wireVersion": BridgeProductWireContract.version,
                "workerDerivationEpoch": 1,
                "workerInstanceId": "worker-instance-1",
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let decoded = try BridgeProductStrictJSON.decode(BridgeProductContentRequest.self, from: data)
            guard case .reviewContent(let request) = decoded else {
                throw BridgeReviewContentStreamTransportTestError.unexpectedContentKind
            }
            return request
        }
    }
}

private enum BridgeReviewContentStreamTransportTestError: Error {
    case unexpectedContentKind
}
