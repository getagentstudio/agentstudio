import CryptoKit
import Foundation

#if DEBUG
    package actor BridgeObservabilitySmokeReviewSourceProvider: BridgeReviewSourceProvider {
        package static let diffId = UUID(uuidString: "33733733-7337-4337-9337-337337337337")!
        static let repoId = UUID(uuidString: "11111111-3370-4337-9337-337337337337")!
        package static let worktreeId = UUID(uuidString: "22222222-3370-4337-9337-337337337337")!

        package init() {}

        package func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
            BridgeReviewComparisonDefaultTargetIdentity(
                remoteName: "origin",
                branchName: "main"
            )
        }

        package func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
            -> BridgeContributionComparisonCapture
        {
            let baseEndpoint = BridgeSourceEndpoint(
                endpointId: request.baseEndpoint.endpointId,
                kind: .gitRef,
                repoId: request.baseEndpoint.repoId,
                worktreeId: request.baseEndpoint.worktreeId,
                label: request.baseEndpoint.label,
                createdAtUnixMilliseconds: request.baseEndpoint.createdAtUnixMilliseconds,
                contentSetHash: "bridge-observability-smoke-base",
                providerIdentity: "bridge-observability-smoke-base"
            )
            return BridgeContributionComparisonCapture(
                resolvedTargetOID: "bridge-observability-smoke-target",
                reviewedHeadOID: "bridge-observability-smoke-head",
                baseRole: .commonCommit,
                baseOID: "bridge-observability-smoke-base",
                comparison: BridgeEndpointComparison(
                    baseEndpoint: baseEndpoint,
                    headEndpoint: request.headEndpoint,
                    changedFiles: [Self.changedFile]
                )
            )
        }

        private static let baseContent = """
            struct BridgeObservabilitySmoke {
                let value = 1
            }
            """

        private static let headContent = """
            struct BridgeObservabilitySmoke {
                let value = 2
                let transport = "bridge"
            }
            """

        private static let changedFile = BridgeEndpointChangedFile(
            fileId: "bridge-observability-smoke",
            path: "Sources/Bridge/BridgeObservabilitySmoke.swift",
            oldPath: nil,
            changeKind: .modified,
            language: "swift",
            fileExtension: "swift",
            sizeBytes: headContent.utf8.count,
            oldContentHash: sha256ContentHash(baseContent),
            newContentHash: sha256ContentHash(headContent),
            contentHashAlgorithm: "sha256",
            additions: 2,
            deletions: 1,
            isBinary: false,
            mimeType: "text/x-swift"
        )

        package func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws -> BridgeSourceEndpoint {
            request.endpoint
        }

        package func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws
            -> BridgeEndpointComparison
        {
            BridgeEndpointComparison(
                baseEndpoint: request.baseEndpoint,
                headEndpoint: request.headEndpoint,
                changedFiles: [Self.changedFile]
            )
        }

        package func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
            let descriptor = try BridgeReviewPackageBuilder.build(
                request: BridgeReviewPackageBuildRequest(
                    packageId: "bridge-observability-smoke-tree",
                    query: BridgeReviewQuery(
                        queryId: "bridge-observability-smoke-tree-query",
                        queryKind: .compare,
                        repoId: Self.repoId,
                        worktreeId: Self.worktreeId,
                        baseEndpointId: request.endpoint.endpointId,
                        headEndpointId: request.endpoint.endpointId,
                        comparisonSemantics: .checkpointDelta,
                        pathScope: request.pathScope,
                        fileTarget: nil,
                        viewFilter: BridgeViewFilter(),
                        grouping: BridgeChangeGrouping(kind: .flat),
                        provenanceFilter: BridgeProvenanceFilter()
                    ),
                    comparison: BridgeEndpointComparison(
                        baseEndpoint: request.endpoint,
                        headEndpoint: request.endpoint,
                        changedFiles: [Self.changedFile]
                    ),
                    checkpointIds: [],
                    reviewGeneration: request.reviewGeneration,
                    generatedAtUnixMilliseconds: 0
                )
            ).itemsById.values.sorted { $0.itemId < $1.itemId }
            return BridgeTreeReadResult(endpoint: request.endpoint, descriptors: descriptor)
        }

        package func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
            -> BridgeReviewItemDescriptor
        {
            let package = try BridgeReviewPackageBuilder.build(
                request: BridgeReviewPackageBuildRequest(
                    packageId: "bridge-observability-smoke-file",
                    query: BridgeReviewQuery(
                        queryId: "bridge-observability-smoke-file-query",
                        queryKind: .compare,
                        repoId: Self.repoId,
                        worktreeId: Self.worktreeId,
                        baseEndpointId: request.endpoint.endpointId,
                        headEndpointId: request.endpoint.endpointId,
                        comparisonSemantics: .checkpointDelta,
                        pathScope: [],
                        fileTarget: request.path,
                        viewFilter: BridgeViewFilter(),
                        grouping: BridgeChangeGrouping(kind: .flat),
                        provenanceFilter: BridgeProvenanceFilter()
                    ),
                    comparison: BridgeEndpointComparison(
                        baseEndpoint: request.endpoint,
                        headEndpoint: request.endpoint,
                        changedFiles: [Self.changedFile]
                    ),
                    checkpointIds: [],
                    reviewGeneration: request.reviewGeneration,
                    generatedAtUnixMilliseconds: 0
                )
            )
            guard let descriptor = package.itemsById.values.first else {
                throw BridgeProviderFailure.providerFailed(message: "Bridge smoke descriptor missing")
            }
            return descriptor
        }

        package func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws
            -> BridgeSourceEndpoint
        {
            BridgeSourceEndpoint(
                endpointId: request.checkpointId,
                kind: .promptCheckpoint,
                repoId: Self.repoId,
                worktreeId: Self.worktreeId,
                label: "Bridge smoke checkpoint",
                createdAtUnixMilliseconds: 0,
                contentSetHash: nil,
                providerIdentity: "bridge-observability-smoke-checkpoint"
            )
        }

        package func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
            let content: String
            switch request.handle.role {
            case .base:
                content = Self.baseContent
            case .head, .file:
                content = Self.headContent
            case .diff:
                content = "\(Self.baseContent)\n---\n\(Self.headContent)"
            }
            let data = Data(content.utf8)
            return BridgeContentLoadResult(
                handle: request.handle,
                data: data,
                mimeType: request.handle.mimeType,
                contentHash: Self.sha256ContentHash(content),
                contentHashAlgorithm: request.handle.contentHashAlgorithm
            )
        }

        private static func sha256ContentHash(_ content: String) -> String {
            let digest = SHA256.hash(data: Data(content.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "sha256:\(hex)"
        }
    }
#endif
