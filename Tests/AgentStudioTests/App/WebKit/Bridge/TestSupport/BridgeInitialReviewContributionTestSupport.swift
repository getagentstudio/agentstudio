import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

struct ReviewContributionEndpointCase {
    let baseline: WorkspaceBaseline
    let expectedEndpointId: String
    let expectedLabel: String
    let expectedProviderIdentity: String
}

let reviewContributionEndpointCases = [
    ReviewContributionEndpointCase(
        baseline: .localDefaultBranch(branchName: "main"),
        expectedEndpointId: "baseline-local-default",
        expectedLabel: "main",
        expectedProviderIdentity: "main"
    ),
    ReviewContributionEndpointCase(
        baseline: .originDefaultBranch(remoteName: "origin", branchName: "main"),
        expectedEndpointId: "baseline-origin-default",
        expectedLabel: "origin/main",
        expectedProviderIdentity: "origin/main"
    ),
    ReviewContributionEndpointCase(
        baseline: .branch(name: "release/next"),
        expectedEndpointId: "baseline-branch-release-next",
        expectedLabel: "release/next",
        expectedProviderIdentity: "release/next"
    ),
    ReviewContributionEndpointCase(
        baseline: .ref(name: "v1.2.3"),
        expectedEndpointId: "baseline-ref-v1-2-3",
        expectedLabel: "v1.2.3",
        expectedProviderIdentity: "v1.2.3"
    ),
    ReviewContributionEndpointCase(
        baseline: .ref(name: "HEAD"),
        expectedEndpointId: "baseline-ref-HEAD",
        expectedLabel: "HEAD",
        expectedProviderIdentity: "HEAD"
    ),
]

actor CanonicalContributionReviewSourceProvider: BridgeReviewSourceProvider {
    static let repositoryDefaultTarget = BridgeReviewComparisonDefaultTargetIdentity(
        remoteName: "upstream",
        branchName: "trunk"
    )

    private var reviewComparisonTargetReadCount = 0
    private var comparisonReadCount = 0
    private var contributionRequests: [BridgeContributionComparisonRequest] = []

    func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        reviewComparisonTargetReadCount += 1
        return Self.repositoryDefaultTarget
    }

    func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
        -> BridgeContributionComparisonCapture
    {
        contributionRequests.append(request)
        let baseEndpoint = BridgeSourceEndpoint(
            endpointId: request.baseEndpoint.endpointId,
            kind: .gitRef,
            repoId: request.baseEndpoint.repoId,
            worktreeId: request.baseEndpoint.worktreeId,
            label: request.baseEndpoint.label,
            createdAtUnixMilliseconds: request.baseEndpoint.createdAtUnixMilliseconds,
            contentSetHash: "base-oid",
            providerIdentity: "base-oid"
        )
        return BridgeContributionComparisonCapture(
            resolvedTargetOID: "target-oid",
            reviewedHeadOID: "head-oid",
            baseRole: .commonCommit,
            baseOID: "base-oid",
            comparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: request.headEndpoint,
                changedFiles: [
                    makeBridgeEndpointChangedFile(
                        fileId: "source",
                        path: "Sources/App/View.swift",
                        sizeBytes: 100
                    )
                ]
            )
        )
    }

    func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws -> BridgeSourceEndpoint {
        request.endpoint
    }

    func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws -> BridgeEndpointComparison {
        comparisonReadCount += 1
        return BridgeEndpointComparison(
            baseEndpoint: request.baseEndpoint,
            headEndpoint: request.headEndpoint,
            changedFiles: []
        )
    }

    func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
        BridgeTreeReadResult(endpoint: request.endpoint, descriptors: [])
    }

    func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
        -> BridgeReviewItemDescriptor
    {
        makeBridgeReviewItemDescriptor(itemId: "item-\(request.path)", path: request.path, fileClass: .source)
    }

    func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws
        -> BridgeSourceEndpoint
    {
        makeBridgeEndpoint(endpointId: request.checkpointId, kind: .promptCheckpoint)
    }

    func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
        throw BridgeProviderFailure.missingContent(handleId: request.handle.handleId)
    }

    func recordedReviewComparisonTargetReadCount() -> Int { reviewComparisonTargetReadCount }
    func recordedComparisonReadCount() -> Int { comparisonReadCount }
    func recordedContributionRequests() -> [BridgeContributionComparisonRequest] { contributionRequests }
}

@MainActor
final class AutomaticContributionTargetRecorder {
    private(set) var target: WorkspaceReviewContributionTarget?

    func record(_ target: WorkspaceReviewContributionTarget) {
        self.target = target
    }
}
