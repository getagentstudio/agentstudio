import AgentStudioGit
import AgentStudioTestHarness
import Foundation

@testable import AgentStudioCore

// The external stage/promotion dependency has one sticky hold, with failure
// propagated through the provider's existing throwing contract.
struct RemoteReferenceHeldStageProvider: RemoteReferenceRefreshProviding {
    let base: any RemoteReferenceRefreshProviding
    let stage: HeldStep<GitRemoteTrackingSnapshot>?
    let promotion: HeldStep<GitStagedFetchResult>?

    func captureRemoteTrackingSnapshot(repositoryPath: URL, remoteName: String) async throws
        -> GitRemoteTrackingSnapshot
    {
        try await base.captureRemoteTrackingSnapshot(repositoryPath: repositoryPath, remoteName: remoteName)
    }

    func stageFetch(snapshot: GitRemoteTrackingSnapshot, stagingId: UUID) async throws -> GitStagedFetchResult {
        if let stage { try await stage.arrive(snapshot) }
        return try await base.stageFetch(snapshot: snapshot, stagingId: stagingId)
    }

    func promoteStagedFetch(_ stagedFetch: GitStagedFetchResult) async throws {
        if let promotion { try await promotion.arrive(stagedFetch) }
        try await base.promoteStagedFetch(stagedFetch)
    }

    func cleanupStagedFetch(_ handle: GitStagedFetchHandle) async throws {
        try await base.cleanupStagedFetch(handle)
    }

    func cleanupAbandonedStagedFetches(repositoryCommonDirectory: URL, retainedStagingIds: Set<UUID>) async throws {
        try await base.cleanupAbandonedStagedFetches(
            repositoryCommonDirectory: repositoryCommonDirectory, retainedStagingIds: retainedStagingIds)
    }
}

enum RemoteReferenceHeldStageFailure: Error { case unavailable }
