import Foundation

extension PaneContextService {
    package nonisolated func submitPullRequestContext(_ snapshot: PanePullRequestContextSnapshot) {
        pullRequestContextSnapshots.continuation.yield(snapshot)
    }

    package func startPullRequestInputs() {
        guard pullRequestContextDrain == nil, !isStopping else { return }
        let snapshots = pullRequestContextSnapshots.stream
        pullRequestContextDrain = Task { [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled, let self else { return }
                await self.setPullRequestContext(snapshot)
            }
        }
        if let pullRequestDetails {
            pullRequestDetailsDrain = Task { [weak self, updates = pullRequestDetails.updates] in
                for await update in updates {
                    guard !Task.isCancelled, let self else { return }
                    await self.acceptPullRequestDetails(update)
                }
            }
        }
    }

    package func setPullRequestContext(_ snapshot: PanePullRequestContextSnapshot) async {
        guard !isStopping, snapshot != pullRequestContext else { return }
        let previous = pullRequestContext
        pullRequestContext = snapshot
        do { try await ensureOpen() } catch { return }
        let panes = previous.mainPaneIds.union(snapshot.mainPaneIds)
        for rawPane in panes {
            let pane = PaneId(existingUUID: rawPane)
            if previous.worktreePullRequest(for: rawPane) != snapshot.worktreePullRequest(for: rawPane) {
                await refreshPullRequestList(paneId: pane)
            }
        }
        await refreshPullRequestDemand()
    }

    package func setPullRequestPopoverOpen(paneId: PaneId, isOpen: Bool) async {
        guard !isStopping else { return }
        if isOpen { pullRequestOpenPopovers.insert(paneId) } else { pullRequestOpenPopovers.remove(paneId) }
        await refreshPullRequestDemand()
    }

    func composePullRequestList(paneId: PaneId) async throws -> PanePullRequestList {
        let admission = scopeAdmission()
        let records = try await sqliteAccess.read { database in
            guard try admission(paneId, database) else { throw PanePullRequestServiceError.paneGone }
            return try PaneContextStorage.pullRequests(database, paneId: paneId)
        }
        return .compose(
            records: records, worktree: pullRequestContext.worktreePullRequest(for: paneId.uuid),
            entries: pullRequestEntries)
    }

    func refreshPullRequestList(paneId: PaneId) async {
        guard !isStopping else { return }
        do {
            try await ensureOpen()
            let list = try await composePullRequestList(paneId: paneId)
            guard publishedPullRequestLists[paneId] != list else { return }
            pullRequestLists[paneId] = list
            publishedPullRequestLists[paneId] = list
            recordInvalidations([paneId])
            await publishAffectedSources([paneId])
        } catch {
            // Membership and storage failures preserve the existing desired presentation.
        }
    }

    func refreshPullRequestDemand() async {
        guard !isStopping, let pullRequestDetails else { return }
        let visible = Set(pullRequestContext.visibleMainPaneIds.map { PaneId(existingUUID: $0) })
        var identities: Set<ForgePullRequestIdentity> = []
        for pane in visible.union(pullRequestOpenPopovers) where !isPendingRetirement(pane) {
            if let list = try? await composePullRequestList(paneId: pane) {
                pullRequestLists[pane] = list
                identities.formUnion(list.rows.map(\.identity))
            }
        }
        await pullRequestDetails.setDemand(identities: identities)
    }

    private func acceptPullRequestDetails(_ update: ForgePullRequestDetailsUpdate) async {
        guard !isStopping, pullRequestEntries[update.identity] != update.entry else { return }
        pullRequestEntries[update.identity] = update.entry
        let panes = Set(pullRequestLists.keys).union(pullRequestContext.mainPaneIds.map { PaneId(existingUUID: $0) })
        for pane in panes
        where pullRequestLists[pane]?.rows.contains(where: { $0.identity == update.identity }) == true
            || pullRequestContext.worktreePullRequest(for: pane.uuid) == update.identity
        {
            await refreshPullRequestList(paneId: pane)
        }
    }
}
