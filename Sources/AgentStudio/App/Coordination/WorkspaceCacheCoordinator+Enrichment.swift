import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import os

extension WorkspaceCacheCoordinator {
    func handleEnrichment(_ envelope: WorktreeEnvelope) {
        let scope = Self.applicationScope(for: .worktree(envelope))
        guard
            workspaceStore.repositoryTopologyAtom.acceptsObservation(
                envelope.observationLifetime, repositoryID: envelope.repoId, worktreeID: envelope.worktreeId
            )
        else {
            if let scope { factSink?(scope, .ignored) }
            return
        }
        switch envelope.event {
        case .gitWorkingDirectory(let gitEvent):
            switch gitEvent {
            case .statusOutcome(let statusOutcome):
                handleGitStatusOutcome(statusOutcome)
            case .snapshotChanged(let snapshot):
                let enrichment = WorktreeEnrichment(
                    worktreeId: snapshot.worktreeId,
                    repoId: snapshot.repoId,
                    branch: snapshot.branch ?? "",
                    snapshot: snapshot
                )
                repoCache.setWorktreeEnrichment(enrichment)
                refreshTraceIdentity()
            case .branchChanged(let worktreeId, let repoId, _, let to):
                var enrichment =
                    repoCache.worktreeEnrichment(for: worktreeId)
                    ?? WorktreeEnrichment(
                        worktreeId: worktreeId,
                        repoId: repoId,
                        branch: to
                    )
                enrichment.updateBranch(to)
                repoCache.setWorktreeEnrichment(enrichment)
                refreshTraceIdentity()
            case .originChanged(let repoId, _, let to):
                let trimmedOrigin = to.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedOrigin.isEmpty else {
                    Self.logger.error(
                        "Ignoring empty originChanged for repoId=\(repoId.uuidString, privacy: .public); local-only resolution must arrive via originUnavailable"
                    )
                    if let scope { factSink?(scope, .ignored) }
                    return
                }
                let upstream: String?
                if case .some(.resolvedRemote(_, let raw, _, _)) = repoCache.repoEnrichment(for: repoId) {
                    upstream = raw.upstream
                } else {
                    upstream = nil
                }
                let enrichment: RepoEnrichment
                if let identity = RemoteIdentityNormalizer.normalize(trimmedOrigin) {
                    enrichment = .resolvedRemote(
                        repoId: repoId,
                        raw: RawRepoOrigin(origin: trimmedOrigin, upstream: upstream),
                        identity: identity,
                        updatedAt: Date()
                    )
                } else {
                    enrichment = .resolvedRemote(
                        repoId: repoId,
                        raw: RawRepoOrigin(origin: trimmedOrigin, upstream: upstream),
                        identity: RepoIdentity(
                            groupKey: "remote:\(trimmedOrigin)",
                            remoteSlug: nil,
                            organizationName: nil,
                            displayName: Self.fallbackDisplayName(for: trimmedOrigin)
                        ),
                        updatedAt: Date()
                    )
                }
                repoCache.setRepoEnrichment(enrichment)
            case .originUnavailable(let repoId):
                let repoName =
                    workspaceStore.repositoryTopologyAtom.repos.first(where: { $0.id == repoId })?.name
                    ?? repoId.uuidString
                repoCache.setRepoEnrichment(
                    .resolvedLocal(
                        repoId: repoId,
                        identity: RemoteIdentityNormalizer.localIdentity(repoName: repoName),
                        updatedAt: Date()
                    )
                )
            case .worktreeDiscovered, .worktreeRemoved, .diffAvailable:
                break
            }
        case .forge(let forgeEvent):
            handleForgeEnrichment(
                forgeEvent, envelopeSequence: envelope.seq, observationLifetime: envelope.observationLifetime,
                scope: scope)
            return
        case .filesystem, .security:
            break
        }
        if let scope { factSink?(scope, .applied) }
    }

    private func handleGitStatusOutcome(_ statusOutcome: GitStatusOutcomeFact) {
        switch statusOutcome.outcome {
        case .completed:
            if case .statusUnavailable = repoCache.repoEnrichment(for: statusOutcome.repoId) {
                repoCache.setRepoEnrichment(.awaitingOrigin(repoId: statusOutcome.repoId))
            }
        case .timeout, .unavailable:
            guard let reason = statusOutcome.reason,
                statusOutcome.consecutiveFailureCount
                    >= AppPolicies.GitRefresh.statusUnavailableConsecutiveFailureThreshold
            else { break }
            switch repoCache.repoEnrichment(for: statusOutcome.repoId) {
            case .none, .some(.awaitingOrigin):
                repoCache.setRepoEnrichment(
                    .statusUnavailable(repoId: statusOutcome.repoId, reason: reason.rawValue)
                )
            case .some(.statusUnavailable), .some(.resolvedLocal), .some(.resolvedRemote):
                break
            }
        }
    }

    /// Internal for @testable proof that cache application does not depend on receipt bookkeeping.
    func handleForgeEnrichment(
        _ forgeEvent: ForgeEvent,
        envelopeSequence: UInt64,
        observationLifetime: RepositoryFactObservationLifetime,
        scope: WorkspaceCacheApplicationScope?
    ) {
        switch forgeEvent {
        case .pullRequestRepositoryProjectionChanged(let repoId, let projection, _):
            applyCoalescedRepositoryProjection(
                for: repoId,
                pending: PendingRepositoryProjection(
                    scope: scope,
                    envelopeSequence: envelopeSequence,
                    observationLifetime: observationLifetime,
                    projection: projection
                )
            )
        case .refreshFailed(let repoId, let error):
            Self.logger.error(
                "Forge refresh failed for repoId=\(repoId.uuidString, privacy: .public): \(error, privacy: .public)"
            )
        case .checksUpdated(let repoId, let status):
            Self.logger.debug(
                "Forge checks updated for repoId=\(repoId.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public)"
            )
        case .rateLimited(let repoId, let retryAfterSeconds):
            Self.logger.warning(
                "Forge provider rate limited for repoId=\(repoId.uuidString, privacy: .public); retryAfterSeconds=\(String(describing: retryAfterSeconds), privacy: .public)"
            )
        }
    }

}

extension WorkspaceCacheCoordinator {
    private static func fallbackDisplayName(for remote: String) -> String {
        if let parsedURL = URL(string: remote), !parsedURL.lastPathComponent.isEmpty {
            let name = parsedURL.lastPathComponent
            return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
        }

        let cleanedRemote = remote.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = cleanedRemote.split(separator: "/")
        guard let last = components.last else {
            return cleanedRemote.isEmpty ? remote : cleanedRemote
        }
        let name = String(last)
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }
}
