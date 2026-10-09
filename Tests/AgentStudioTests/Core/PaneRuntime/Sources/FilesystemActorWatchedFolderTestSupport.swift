import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation

@testable import AgentStudioCore

struct RepoDiscoveryEvent: Equatable {
    let repoPath: URL
    let linkedWorktrees: LinkedWorktreeInfo
    let stableIdentity: DiscoveredRepoStableIdentity

    init(
        repoPath: URL,
        linkedWorktrees: LinkedWorktreeInfo,
        stableIdentity: DiscoveredRepoStableIdentity? = nil
    ) {
        self.repoPath = repoPath
        self.linkedWorktrees = linkedWorktrees
        self.stableIdentity =
            stableIdentity
            ?? .prepare(repoPath: repoPath, linkedWorktrees: linkedWorktrees)
    }
}

struct TopologyEventSet: Equatable {
    var discovered: [RepoDiscoveryEvent] = []
    var removed: Set<URL> = []
}

actor TopologyEventRecorder {
    private var events = TopologyEventSet()
    private var groupsByRoot: [URL: [RepoScanner.RepoScanGroup]] = [:]

    func record(_ envelope: RuntimeEnvelope) {
        guard case .system(let systemEnvelope) = envelope,
            case .topology(let topologyEvent) = systemEnvelope.event
        else { return }
        switch topologyEvent {
        case .watchedFolderReconciled(let observation):
            let previous = groupsByRoot[observation.root] ?? []
            var groups = RepoScanner.groupResolvedEntries(observation.entries)
            if case .additive = observation.coverage {
                var merged = Dictionary(uniqueKeysWithValues: previous.map { ($0.clonePath, $0) })
                for group in groups {
                    let retained = merged[group.clonePath]?.linkedWorktreePaths ?? []
                    merged[group.clonePath] = .init(
                        clonePath: group.clonePath,
                        linkedWorktreePaths: Array(Set(retained + group.linkedWorktreePaths)).sorted {
                            $0.path < $1.path
                        }
                    )
                }
                groups = merged.values.sorted { $0.clonePath.path < $1.clonePath.path }
            }
            groupsByRoot[observation.root] = groups
            for group in groups where !previous.contains(group) {
                events.discovered.append(
                    RepoDiscoveryEvent(
                        repoPath: group.clonePath,
                        linkedWorktrees: .scanned(group.linkedWorktreePaths)
                    ))
            }
            for group in previous where !groups.contains(where: { $0.clonePath == group.clonePath }) {
                if !groupsByRoot.values.joined().contains(where: { $0.clonePath == group.clonePath }) {
                    events.removed.insert(group.clonePath)
                }
            }
        case .repoDiscovered(let repoPath, _, let linkedWorktrees, let stableIdentity):
            events.discovered.append(
                RepoDiscoveryEvent(
                    repoPath: repoPath.standardizedFileURL,
                    linkedWorktrees: linkedWorktrees,
                    stableIdentity: stableIdentity
                )
            )
        case .reposDiscovered(_, let repositories):
            events.discovered.append(
                contentsOf: repositories.map {
                    RepoDiscoveryEvent(
                        repoPath: $0.repoPath.standardizedFileURL,
                        linkedWorktrees: $0.linkedWorktrees,
                        stableIdentity: $0.stableIdentity
                    )
                }
            )
        case .repoRemoved(let repoPath):
            events.removed.insert(repoPath.standardizedFileURL)
        case .worktreeRegistered, .worktreeUnregistered:
            break
        }
    }

    func reset() { events = TopologyEventSet() }
    func snapshot() -> TopologyEventSet { events }
}

/// Holds one armed submission's accepted result back from the FilesystemActor until opened,
/// so actor work can be ordered between a scan starting and its acceptance returning.
actor WatchedFolderScanAcceptanceGate {
    private var isArmed = false
    private var heldSubmission: HeldStep<Void>?

    nonisolated var port: WatchedFolderScanSubmissionPort {
        WatchedFolderScanSubmissionPort { scheduler, request, intent in
            let result = await scheduler.submit(request, intent: intent)
            await self.holdIfArmed()
            return result
        }
    }

    func arm() {
        isArmed = true
        heldSubmission = HeldStep<Void>("watchedFolderScanAcceptance", cancellation: .holdThroughCancellation)
    }

    func open() {
        heldSubmission?.release()
    }

    private func holdIfArmed() async {
        guard isArmed, let heldSubmission else { return }
        isArmed = false
        try? await heldSubmission.arrive(())
    }
}

func cloneEntry(_ path: URL) -> RepoScanner.ResolvedGitEntry {
    RepoScanner.ResolvedGitEntry(
        path: path,
        kind: .cloneRoot,
        repositoryKey: path.standardizedFileURL.path
    )
}

func canonicalURL(_ path: URL) -> URL {
    RepoScanner.canonicalURL(path)
}

func linkedEntry(
    _ path: URL,
    parentClone: URL
) -> RepoScanner.ResolvedGitEntry {
    RepoScanner.ResolvedGitEntry(
        path: path,
        kind: .linkedWorktree(parentClonePath: parentClone),
        repositoryKey: parentClone.standardizedFileURL.path
    )
}

func completeResult(entries: [RepoScanner.ResolvedGitEntry]) -> RepoScannerResult {
    .completeAuthoritative(
        CompleteRepoScan(
            verifiedEntries: entries,
            counts: scannerCounts(successCount: entries.count),
            serviceMetrics: .zero
        )
    )
}

func partialResult(entries: [RepoScanner.ResolvedGitEntry]) -> RepoScannerResult {
    .partial(
        PartialRepoScan(
            verifiedEntries: entries,
            failures: NonEmptyScanFailures(
                first: .scannerServiceFailed(detail: "controlled partial result"),
                remaining: []
            ),
            counts: scannerCounts(successCount: entries.count, failureCount: 1),
            serviceMetrics: .zero
        )
    )
}

func cancelledResult(entries: [RepoScanner.ResolvedGitEntry]) -> RepoScannerResult {
    .cancelled(
        CancelledRepoScan(
            verifiedEntries: entries,
            counts: scannerCounts(successCount: entries.count),
            serviceMetrics: .zero
        )
    )
}

func unavailableResult() -> RepoScannerResult {
    .unavailable(
        UnavailableRepoScan(
            reason: .rootTraversalUnavailable(detail: "controlled unavailable result"),
            counts: scannerCounts(),
            serviceMetrics: .zero
        )
    )
}

func failedResult() -> RepoScannerResult {
    .failed(
        FailedRepoScan(
            reason: .scannerServiceFailed(detail: "controlled failed result"),
            counts: scannerCounts(failureCount: 1),
            serviceMetrics: .zero
        )
    )
}

func scannerCounts(
    successCount: Int = 0,
    failureCount: Int = 0
) -> RepoScannerEvidenceCounts {
    RepoScannerEvidenceCounts(
        directoryVisitCount: 0,
        directoryTraversalFailureCount: 0,
        entryMetadataFailureCount: 0,
        gitCandidateCount: successCount,
        validationSuccessCount: successCount,
        validationAuthoritativeNegativeCount: 0,
        validationTimeoutCount: 0,
        validationCancellationCount: 0,
        validationFailureCount: failureCount,
        scannerServiceInvocationCount: 1
    )
}
