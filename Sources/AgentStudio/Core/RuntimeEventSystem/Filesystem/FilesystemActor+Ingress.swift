import Foundation

extension FilesystemActor {
    func ingestRawPaths(
        worktreeId: UUID,
        paths: [String],
        requiresFullGitRefresh: Bool,
        activityParticipant: FSEventParticipant? = nil,
        activityObservations: [FSEventObservation] = [],
        shouldScheduleAndRecord: Bool = true
    ) async {
        guard !hasBegunShutdown else { return }
        guard roots[worktreeId] != nil else {
            Self.logger.debug(
                "Dropped filesystem path batch for unregistered worktree \(worktreeId.uuidString, privacy: .public)"
            )
            return
        }
        guard !paths.isEmpty || requiresFullGitRefresh || !activityObservations.isEmpty else {
            return
        }

        recordRequiredFullGitRefresh(for: worktreeId, when: requiresFullGitRefresh)

        let externallyObservedActivityPaths = Set(
            activityObservations.lazy.filter { !$0.isOwnEvent }.map(\.path)
        )
        let processOwnedActivityPaths = Set(
            activityObservations.lazy.filter(\.isOwnEvent).map(\.path)
        )
        let ordinaryPathSet = Set(paths)
        let activityContext = RawPathActivityContext(
            externallyObservedPaths: externallyObservedActivityPaths,
            processOwnedPaths: processOwnedActivityPaths
        )
        var qualifyingRepositoryStableKeys: Set<String> = []
        var coverageLostRepositoryStableKeys: Set<String> = []
        var ancestorCachesByWorktreeID: [UUID: FilesystemPathFilter.DirectoryIgnoreCache] = [:]
        for rawPath in paths {
            guard
                let classification = await ingestRawPath(
                    rawPath,
                    sourceWorktreeID: worktreeId,
                    activityContext: activityContext,
                    ancestorCachesByWorktreeID: &ancestorCachesByWorktreeID
                )
            else { return }
            if let qualifyingRepositoryStableKey = classification.qualifyingRepositoryStableKey {
                qualifyingRepositoryStableKeys.insert(qualifyingRepositoryStableKey)
            }
            if let coverageLostRepositoryStableKey = classification.coverageLostRepositoryStableKey {
                coverageLostRepositoryStableKeys.insert(coverageLostRepositoryStableKey)
            }
        }

        if let activityParticipant {
            await ingestRepositoryLocalActivity(
                RepositoryLocalActivityIngress(
                    sourceWorktreeID: worktreeId,
                    participant: activityParticipant,
                    observations: activityObservations,
                    ordinaryPaths: ordinaryPathSet,
                    qualifyingRepositoryStableKeys: qualifyingRepositoryStableKeys,
                    coverageLostRepositoryStableKeys: coverageLostRepositoryStableKeys
                )
            )
        }

        if shouldScheduleAndRecord {
            scheduleDrainIfNeeded()
            await recordLogicalDebtSnapshotIfChanged()
        }
    }

    private struct RawPathActivityContext {
        let externallyObservedPaths: Set<String>
        let processOwnedPaths: Set<String>
    }

    private struct RawPathActivityClassification {
        var qualifyingRepositoryStableKey: String?
        var coverageLostRepositoryStableKey: String?
    }

    private func ingestRawPath(
        _ rawPath: String,
        sourceWorktreeID: UUID,
        activityContext: RawPathActivityContext,
        ancestorCachesByWorktreeID: inout [UUID: FilesystemPathFilter.DirectoryIgnoreCache]
    ) async -> RawPathActivityClassification? {
        guard let ownedPath = rootOwnership.route(sourceWorktreeId: sourceWorktreeID, rawPath: rawPath)
        else {
            Self.logger.debug(
                "Dropped unroutable filesystem path for source worktree \(sourceWorktreeID.uuidString, privacy: .public): \(rawPath, privacy: .public)"
            )
            return RawPathActivityClassification()
        }
        guard let root = roots[ownedPath.worktreeId] else {
            return RawPathActivityClassification()
        }

        let isExternallyObservedActivity = activityContext.externallyObservedPaths.contains(rawPath)
        let isProcessOwnedActivity = activityContext.processOwnedPaths.contains(rawPath)
        if Self.isGitIgnoreReloadPath(rawPath: rawPath, relativePath: ownedPath.relativePath) {
            var classification = RawPathActivityClassification()
            if isExternallyObservedActivity || isProcessOwnedActivity,
                let repositoryStableKey = repositoryStableKeysByWorktreeId[ownedPath.worktreeId]
            {
                classification.qualifyingRepositoryStableKey = repositoryStableKey
            }
            let pathFilter = await FilesystemPathFilter.loadOffExecutor(forRootPath: root.rootPath)
            guard !hasBegunShutdown else { return nil }
            guard var latestRoot = roots[ownedPath.worktreeId] else {
                return classification
            }
            latestRoot.pathFilter = pathFilter
            roots[ownedPath.worktreeId] = latestRoot

            var pendingChanges = pendingChangesByWorktreeId[ownedPath.worktreeId] ?? PendingWorktreeChanges()
            pendingChanges.containsGitInternalChanges = true
            pendingChanges.recordPendingChange(at: schedulingClock.now())
            pendingChangesByWorktreeId[ownedPath.worktreeId] = pendingChanges
            return classification
        }

        var pendingChanges = pendingChangesByWorktreeId[ownedPath.worktreeId] ?? PendingWorktreeChanges()
        let pathDisposition = root.pathFilter.classify(
            relativePath: ownedPath.relativePath,
            ancestorCache: &ancestorCachesByWorktreeID[ownedPath.worktreeId, default: .init()]
        )
        switch pathDisposition {
        case .projected:
            pendingChanges.projectedPaths.insert(ownedPath.relativePath)
        case .gitInternal:
            pendingChanges.containsGitInternalChanges = true
            pendingChanges.suppressedGitInternalPathCount += 1
        case .ignoredByPolicy:
            pendingChanges.suppressedIgnoredPathCount += 1
        case .gitObjectDatabase:
            return RawPathActivityClassification()
        }

        var classification = RawPathActivityClassification()
        let isQualifyingOwnedGitMetadata =
            isProcessOwnedActivity
            && pathDisposition == .gitInternal
            && RepositoryLocalActivityPathClassifier.qualifiesGitMetadataPath(
                ownedPath.relativePath
            )
        if isExternallyObservedActivity || (isProcessOwnedActivity && !isQualifyingOwnedGitMetadata),
            let repositoryStableKey = repositoryStableKeysByWorktreeId[ownedPath.worktreeId],
            RepositoryLocalActivityPathClassifier.qualifiesWorktreePath(
                relativePath: ownedPath.relativePath,
                disposition: pathDisposition
            )
        {
            classification.qualifyingRepositoryStableKey = repositoryStableKey
        }
        if isQualifyingOwnedGitMetadata,
            let repositoryStableKey = repositoryStableKeysByWorktreeId[ownedPath.worktreeId]
        {
            classification.coverageLostRepositoryStableKey = repositoryStableKey
        }
        pendingChanges.recordPendingChange(at: schedulingClock.now())
        pendingChangesByWorktreeId[ownedPath.worktreeId] = pendingChanges
        return classification
    }

    private struct RepositoryLocalActivityIngress {
        let sourceWorktreeID: UUID
        let participant: FSEventParticipant
        let observations: [FSEventObservation]
        let ordinaryPaths: Set<String>
        var qualifyingRepositoryStableKeys: Set<String>
        var coverageLostRepositoryStableKeys: Set<String>
    }

    private func ingestRepositoryLocalActivity(
        _ ingress: RepositoryLocalActivityIngress
    ) async {
        guard let processedThroughEventID = ingress.observations.map(\.eventID).max() else {
            return
        }
        var qualifyingRepositoryStableKeys = ingress.qualifyingRepositoryStableKeys
        var coverageLostRepositoryStableKeys = ingress.coverageLostRepositoryStableKeys
        if let repositoryStableKey = repositoryStableKeysByWorktreeId[ingress.sourceWorktreeID] {
            if ingress.observations.contains(where: {
                !ingress.ordinaryPaths.contains($0.path)
                    && !$0.isOwnEvent
                    && RepositoryLocalActivityPathClassifier.qualifiesGitMetadataPath($0.path)
            }) {
                qualifyingRepositoryStableKeys.insert(repositoryStableKey)
            }
            if ingress.observations.contains(where: {
                $0.hasCoverageLoss
                    || ($0.isOwnEvent
                        && RepositoryLocalActivityPathClassifier.qualifiesGitMetadataPath($0.path))
            }) {
                coverageLostRepositoryStableKeys.insert(repositoryStableKey)
            }
        }
        await repositoryLocalActivityProjector?.ingest(
            RepositoryLocalActivityObservedEvent(
                scopeKey: ingress.participant.scopeKey,
                generation: ingress.participant.generation,
                eventID: processedThroughEventID,
                qualifyingRepositoryStableKeys: qualifyingRepositoryStableKeys,
                coverageLostRepositoryStableKeys: coverageLostRepositoryStableKeys,
                observedAt: Date()
            )
        )
        recordPendingActivityCheckpoint()
    }

    private func recordRequiredFullGitRefresh(for worktreeId: UUID, when required: Bool) {
        guard required else { return }
        var pendingChanges = pendingChangesByWorktreeId[worktreeId] ?? PendingWorktreeChanges()
        pendingChanges.containsGitInternalChanges = true
        pendingChanges.recordPendingChange(at: schedulingClock.now())
        pendingChangesByWorktreeId[worktreeId] = pendingChanges
    }

    nonisolated private static func isGitIgnoreReloadPath(
        rawPath: String,
        relativePath: String
    ) -> Bool {
        if relativePath == ".gitignore" {
            return true
        }
        guard relativePath == "." else {
            return false
        }
        let normalizedRawPath =
            rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        return normalizedRawPath == ".gitignore" || normalizedRawPath.hasSuffix("/.gitignore")
    }
}
