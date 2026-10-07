import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension RepoExplorerProjectionWorker {
    static func repositoryActivityClassification(
        for request: RepoExplorerProjectionRequest
    ) -> RepositoryActivityClassification {
        RepositoryActivityClassifier.classify(
            RepositoryActivityClassificationInput(
                repositories: request.snapshot.repos.map { repository in
                    RepositoryActivityTopology(
                        repositoryID: repository.id,
                        repositoryStableKey: repository.stableKey,
                        worktreeStableKeysByID: repository.worktreeStableKeysByID
                    )
                },
                openWorktreeIDs: Set(request.snapshot.paneLocationsByWorktreeId.keys),
                localActivityHydrationDisposition: request.localActivityHydrationDisposition,
                repositoryLocalActivityByStableKey: request.repositoryLocalActivityByStableKey,
                referenceDate: request.activityReferenceDate,
                inactivityHorizon: AppPolicies.EntityRecency.applicationActivityHorizon
            )
        )
    }

    static func applyScopedRepositoryActivityChanges(
        _ repositoryIDs: [UUID],
        request: RepoExplorerProjectionRequest,
        previous: RepoExplorerProjectionResult
    ) throws -> RepoExplorerProjectionResult? {
        var result = previous
        for repositoryID in repositoryIDs {
            try Task.checkCancellation()
            guard
                let updated = applyScopedRepositoryActivityChange(
                    repositoryID: repositoryID,
                    request: request,
                    previous: result
                )
            else { return nil }
            result = updated
        }
        return result
    }

    static func applyScopedRepositoryActivityChange(
        repositoryID: UUID,
        request: RepoExplorerProjectionRequest,
        previous: RepoExplorerProjectionResult
    ) -> RepoExplorerProjectionResult? {
        guard let repository = request.snapshot.repos.first(where: { $0.id == repositoryID }) else {
            return nil
        }
        let activityByRepositoryStableKey =
            request.repositoryLocalActivityByStableKey[
                repository.stableKey
            ].map { [repository.stableKey: $0] } ?? [:]
        let classification = RepositoryActivityClassifier.classify(
            RepositoryActivityClassificationInput(
                repositories: [
                    RepositoryActivityTopology(
                        repositoryID: repository.id,
                        repositoryStableKey: repository.stableKey,
                        worktreeStableKeysByID: repository.worktreeStableKeysByID
                    )
                ],
                openWorktreeIDs: Set(request.snapshot.paneLocationsByWorktreeId.keys),
                localActivityHydrationDisposition: request.localActivityHydrationDisposition,
                repositoryLocalActivityByStableKey: activityByRepositoryStableKey,
                referenceDate: request.activityReferenceDate,
                inactivityHorizon: AppPolicies.EntityRecency.applicationActivityHorizon
            )
        )
        guard let disposition = classification.dispositionByRepositoryID[repositoryID] else {
            return nil
        }

        var dispositionsByRepositoryID = previous.repositoryActivityDispositionByRepoId
        dispositionsByRepositoryID[repositoryID] = disposition
        var transitionsByRepositoryID = previous.repositoryActivityTransitionAtByRepoId
        transitionsByRepositoryID[repositoryID] = classification.transitionAtByRepositoryID[repositoryID]
        let preparedPresentationDeadline = RepoExplorerPreparedPresentationDeadline.prepare(
            sidebarTransitionsByPaneID: previous.sidebarPresentationTransitionAtByPaneId,
            repositoryTransitionsByRepositoryID: transitionsByRepositoryID
        )
        let materializationSnapshot = previous.materializationSnapshot
            .replacingRepositoryActivityDisposition(
                repositoryID: repositoryID,
                disposition: disposition
            )
        return RepoExplorerProjectionResult(
            generation: request.generation,
            snapshot: request.snapshot,
            collapsedGroupIds: request.collapsedGroupIds,
            isFiltering: request.isFiltering,
            trigger: request.trigger,
            projection: previous.projection,
            rowIndex: previous.rowIndex,
            materializationSnapshot: materializationSnapshot,
            workerDuration: .zero,
            projectionDuration: .zero,
            rowIndexDuration: .zero,
            branchStatusByWorktreeId: previous.branchStatusByWorktreeId,
            branchNameByWorktreeId: previous.branchNameByWorktreeId,
            bridgeCommandResolutionByWorktreeId: previous.bridgeCommandResolutionByWorktreeId,
            paneRowFactsByPaneId: request.paneRowFactsByPaneId,
            tabGroupFactsByTabId: request.tabGroupFactsByTabId,
            repositoryActivityDispositionByRepoId: dispositionsByRepositoryID,
            repositoryActivityTransitionAtByRepoId: transitionsByRepositoryID,
            sidebarPresentationTransitionAtByPaneId: previous.sidebarPresentationTransitionAtByPaneId,
            preparedPresentationDeadline: preparedPresentationDeadline,
            semanticBaselineSequence: nil
        )
    }

    static func preparedPaneRowFacts(
        _ capturedFacts: [UUID: RepoExplorerPaneRowFacts],
        snapshot: RepoExplorerSnapshot
    ) -> [UUID: RepoExplorerPaneRowFacts] {
        guard snapshot.surface == .panes else { return capturedFacts }
        return capturedFacts.mapValues { facts in
            let referenceInstant =
                snapshot.referenceInstant
                ?? facts.paneActivityTime?.orderingInstant
                ?? ContinuousClock.now
            let activity = RepoExplorerPaneActivityProjection.make(
                time: snapshot.referenceInstant == nil ? nil : facts.paneActivityTime,
                referenceInstant: referenceInstant,
                wallNow: snapshot.referenceDate,
                calendar: snapshot.calendar
            )
            return RepoExplorerPaneRowFacts(
                terminalTitle: facts.terminalTitle,
                sessionStatus: facts.sessionStatus,
                contextDisplay: facts.contextDisplay,
                activityAt: activity.activityDate,
                paneActivityTime: facts.paneActivityTime,
                isPinned: facts.isPinned,
                noteText: facts.noteText,
                latestMessageText: facts.latestMessageText,
                recencyReferenceDate: activity.activityDate ?? .distantPast,
                recencyText: activity.clockText,
                recencyTier: activity.recencyTier,
                nextPresentationChangeDate: activity.nextPresentationChangeDate,
                isActive: activity.isActive,
                isDrawerPane: facts.isDrawerPane,
                drawerOwnerPaneID: facts.drawerOwnerPaneID
            )
        }
    }

    static func sidebarPresentationTransitions(
        _ paneFacts: [UUID: RepoExplorerPaneRowFacts],
        snapshot: RepoExplorerSnapshot
    ) -> [UUID: Date] {
        let usesActivityTime =
            snapshot.groupingMode == .activity
            || snapshot.subgroupMode == .activity
            || snapshot.sortField == .activity
        var transitions: [UUID: Date] = [:]
        transitions.reserveCapacity(paneFacts.count)
        for (paneID, facts) in paneFacts {
            let recencyTransition = snapshot.surface == .panes ? facts.nextPresentationChangeDate : nil
            let activityTransition =
                snapshot.surface == .repos && usesActivityTime
                ? RepoExplorerActivityBucket.nextChangeDate(
                    activityAt: facts.activityAt,
                    now: snapshot.referenceDate,
                    calendar: snapshot.calendar
                )
                : nil
            if let transition = [recencyTransition, activityTransition].compactMap(\.self).min() {
                transitions[paneID] = transition
            }
        }
        return transitions
    }
}
