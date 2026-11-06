import AgentStudioInfrastructure
import Foundation

package struct WatchedFolderPublicationHoldID: Hashable, Sendable {
    let rawValue: UUID
}

/// A released hold still covers every scan requested before release: such a scan may
/// have observed the destination half-built or before a rollback removed it, so its
/// result must not publish the destination even when applied after release. Requests
/// are ordered by the submission sequence reserved before they are submitted, so a
/// submission still in flight at release is covered too.
struct ReleasedWatchedFolderPublicationHold: Sendable {
    let path: String
    /// The highest submission sequence reserved when the hold was released.
    let releasedThroughSubmissionSequence: UInt64
    /// Sources that have not yet applied a result requested after release.
    var pendingSourceIDs: Set<FilesystemSourceID>
}

/// A creation owner builds a checkout in place; linked-worktree metadata appears
/// before the checkout is complete, so discovery could publish it half-built. A hold
/// withholds that destination from every scan result until the owner releases it,
/// then the owner requests a refresh that publishes the finished checkout. While held,
/// directory churn inside the destination is treated like work inside a known checkout
/// and does not admit scans.
extension FilesystemActor {
    package func holdWatchedFolderPublication(of destination: URL) -> WatchedFolderPublicationHoldID {
        let holdID = WatchedFolderPublicationHoldID(rawValue: UUIDv7.generate())
        watchedFolderScanState.publicationHoldPathsByID[holdID] =
            WatchedFolderPublicationHolds.canonicalPath(destination)
        publishAllWatchedFolderAdmissions()
        return holdID
    }

    package func releaseWatchedFolderPublicationHold(_ holdID: WatchedFolderPublicationHoldID) {
        guard let path = watchedFolderScanState.publicationHoldPathsByID.removeValue(forKey: holdID) else {
            return
        }
        publishAllWatchedFolderAdmissions()
        let pendingSourceIDs = Set(watchedFolderScanState.registrationsBySourceID.keys)
        guard !pendingSourceIDs.isEmpty else { return }
        watchedFolderScanState.releasedPublicationHoldsByID[holdID] = ReleasedWatchedFolderPublicationHold(
            path: path,
            releasedThroughSubmissionSequence: watchedFolderScanState.lastReservedScanSubmissionSequence,
            pendingSourceIDs: pendingSourceIDs
        )
    }

    /// Paths a result for `request` must not publish: every active hold, plus released
    /// holds whose release came after `request` was reserved.
    func publicationHeldPaths(forResultOf request: WatchedFolderScanRequest) -> Set<String> {
        var heldPaths = Set(watchedFolderScanState.publicationHoldPathsByID.values)
        for released in watchedFolderScanState.releasedPublicationHoldsByID.values
        where released.pendingSourceIDs.contains(request.sourceID)
            && request.submissionSequence <= released.releasedThroughSubmissionSequence
        {
            heldPaths.insert(released.path)
        }
        return heldPaths
    }

    /// Once a source applies a result requested after release, its released holds no longer
    /// apply to it; a hold with no pending sources is forgotten.
    func retireReleasedPublicationHolds(satisfiedBy request: WatchedFolderScanRequest) {
        for (holdID, released) in watchedFolderScanState.releasedPublicationHoldsByID
        where released.pendingSourceIDs.contains(request.sourceID)
            && request.submissionSequence > released.releasedThroughSubmissionSequence
        {
            var remaining = released
            remaining.pendingSourceIDs.remove(request.sourceID)
            watchedFolderScanState.releasedPublicationHoldsByID[holdID] =
                remaining.pendingSourceIDs.isEmpty ? nil : remaining
        }
    }
}

enum WatchedFolderPublicationHolds {
    static func canonicalPath(_ url: URL) -> String {
        FilesystemRootOwnership.canonicalizeKernelPath(url.standardizedFileURL.path)
    }

    /// Drops verified checkouts at or under a held path, as if the scan had not seen them.
    static func excludingHeldCheckouts(from result: RepoScannerResult, heldPaths: Set<String>) -> RepoScannerResult {
        guard !heldPaths.isEmpty else { return result }
        func isPublishable(_ entry: RepoScanner.ResolvedGitEntry) -> Bool {
            let entryPath = canonicalPath(entry.path)
            return !heldPaths.contains { entryPath == $0 || entryPath.hasPrefix($0 + "/") }
        }
        switch result {
        case .completeAuthoritative(let scan):
            return .completeAuthoritative(
                CompleteRepoScan(
                    verifiedEntries: scan.verifiedEntries.filter(isPublishable),
                    counts: scan.counts,
                    serviceMetrics: scan.serviceMetrics
                ))
        case .partial(let scan):
            return .partial(
                PartialRepoScan(
                    verifiedEntries: scan.verifiedEntries.filter(isPublishable),
                    failures: scan.failures,
                    counts: scan.counts,
                    serviceMetrics: scan.serviceMetrics
                ))
        case .cancelled(let scan):
            return .cancelled(
                CancelledRepoScan(
                    verifiedEntries: scan.verifiedEntries.filter(isPublishable),
                    counts: scan.counts,
                    serviceMetrics: scan.serviceMetrics
                ))
        case .unavailable, .failed:
            return result
        }
    }
}
