import AgentStudioCore
import Foundation

enum BridgePaneProductFileMetadataSourceError: Error, Equatable {
    case unavailableAuthority
}

struct BridgePaneProductFileSourceAuthority: Sendable {
    let paneId: UUID
    let worktree: Worktree
}

struct BridgePaneProductFileMetadataEmission: Sendable {
    let fact: BridgePaneProductFileSourceFact
    let subscriptionId: String
}

struct BridgePaneProductFileViewDemand: Equatable, Sendable {
    let admissionSequence: Int
    let handle: String
    let scopeRevision: Int
    let state: BridgeProductFileMetadataInterestState
}

typealias BridgePaneProductFileSourceFactSink =
    @Sendable (BridgePaneProductFileSourceFact) async throws -> Void

typealias BridgePaneProductFileSourceAcceptedObserver =
    @Sendable (BridgeProductFileSourceIdentity) async -> Void

typealias BridgePaneProductFileIgnorePolicyLoader =
    @Sendable (URL) async -> BridgeWorktreeFileIgnorePolicy

typealias BridgePaneProductFileSnapshotPreparationLoader =
    @Sendable (URL, BridgeGitReadContext) async -> BridgeSharedFileSnapshotPreparation

typealias BridgePaneProductFileSharedSnapshotBuilder =
    @Sendable (
        BridgeWorktreeFileMaterializationRequest,
        BridgeSharedFileSnapshotPreparation,
        BridgeSharedFileSnapshotPublisher
    ) async throws -> BridgeSharedFileSnapshotCompletion

typealias BridgePaneProductFileTreeRowRefresher =
    @Sendable (URL, Set<String>, Bool) async -> BridgeWorktreeRefreshedTreeRows

struct BridgeFileMetadataSourceDiagnostics: Equatable, Sendable {
    let descriptorCount: Int
    let inFlightDescriptorCount: Int
    let manifestRowCount: Int
    let subscriptionCount: Int
}

protocol BridgePaneProductFileMetadataProducing: Sendable {
    func currentSource() async throws(BridgeWorktreeFileRootAccessError) -> BridgeProductFileSourceCurrentResult
    func captureKeyedSnapshot(
        subscriptionId: String,
        demand: BridgePaneProductFileViewDemand,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot?
    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws
    func applyViewDemand(
        subscriptionId: String,
        demand: BridgePaneProductFileViewDemand,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        forceRecapture: Bool,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws
    func cancel(subscriptionId: String) async
    func publish(
        status: GitWorkingTreeStatus,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> [BridgePaneProductFileMetadataEmission]
    func publish(
        changeset: FileChangeset,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission]
    func authoritativePath(
        for request: BridgeProductFileContentRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async -> String?
    func contentReadPlan(
        for request: BridgeProductFileContentRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgePaneProductFileContentReadPlan?
    func captureWorktreeAnnotationSource(
        origin: BridgeProductWorktreeAnnotationOrigin,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationCapturedSource
    func currentWorktreeAnnotationFingerprint(
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSourceFingerprint
    func currentWorktreeAnnotationSourceGeneration(
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> Int
    func currentWorktreeAnnotationRefresh(
        requirements: [WorktreeAnnotationSourceRefreshRequirement],
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSourceRefreshCapture
    func worktreeAnnotationRepositoryPath() async throws -> URL
}

extension BridgePaneProductFileMetadataProducing {
    func authoritativePath(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> String? { nil }

    func captureWorktreeAnnotationSource(
        origin _: BridgeProductWorktreeAnnotationOrigin,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationCapturedSource {
        throw WorktreeAnnotationSourceResolutionError.unavailable
    }

    func currentWorktreeAnnotationFingerprint(
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSourceFingerprint {
        throw WorktreeAnnotationSourceResolutionError.unavailable
    }

    func currentWorktreeAnnotationSourceGeneration(
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> Int {
        throw WorktreeAnnotationSourceResolutionError.unavailable
    }

    func currentWorktreeAnnotationRefresh(
        requirements _: [WorktreeAnnotationSourceRefreshRequirement],
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSourceRefreshCapture {
        throw WorktreeAnnotationSourceResolutionError.unavailable
    }

    func worktreeAnnotationRepositoryPath() async throws -> URL {
        throw WorktreeAnnotationSourceResolutionError.unavailable
    }
}

actor BridgeUnavailablePaneProductFileMetadataSource: BridgePaneProductFileMetadataProducing {
    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func captureKeyedSnapshot(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? { nil }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        throw BridgePaneProductFileMetadataSourceError.unavailableAuthority
    }

    func applyViewDemand(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        throw BridgePaneProductFileMetadataSourceError.unavailableAuthority
    }

    func cancel(subscriptionId _: String) {}

    func publish(
        status _: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] { [] }

    func publish(
        changeset _: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] { [] }

    func authoritativePath(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> String? { nil }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? { nil }
}

extension BridgeProductDemandLane {
    static let fileMetadataPriorityOrder: [Self] = [
        .foreground, .active, .visible, .nearby, .speculative, .idle,
    ]

    var priority: Int {
        Self.fileMetadataPriorityOrder.firstIndex(of: self) ?? Int.max
    }
}
