import Foundation

extension PaneContextService {
    package func readDisplay(paneId: PaneId) async -> PaneContextDisplay? {
        do {
            try await ensureOpen()
            return try await computeDisplay(paneId: paneId)
        } catch { return nil }
    }

    func startPresentation() async {
        guard let presentationLane, !isStopping else { return }
        if let directory = membership as? PaneContextMembershipDirectory, membershipDrain == nil {
            // Subscribe before capturing compact current facts; buffered invalidations
            // retain every change while the initial reconciliation is suspended.
            let wakes = directory.wakes
            membershipDrain = Task { [weak self] in
                for await _ in wakes {
                    guard !Task.isCancelled, let self else { return }
                    await self.reconcileMembership()
                }
            }
            await joinMembershipReconcile(directory, forceAll: true)
        }
        await presentationLane.start()
    }

    package func reconcileMembership() async {
        guard !isStopping, let directory = membership as? PaneContextMembershipDirectory else { return }
        do { try await ensureOpen() } catch { return }
        await joinMembershipReconcile(directory, forceAll: false)
    }

    private func joinMembershipReconcile(_ directory: PaneContextMembershipDirectory, forceAll: Bool) async {
        if let membershipReconcile {
            await membershipReconcile.value
            return
        }
        let task = Task { await drainMembership(directory, forceAll: forceAll) }
        membershipReconcile = task
        await task.value
    }

    private func drainMembership(_ directory: PaneContextMembershipDirectory, forceAll: Bool) async {
        defer { membershipReconcile = nil }
        var fullSnapshotRequired = forceAll
        while !isStopping, !Task.isCancelled {
            let affected = directory.takeAffectedOwners()
            if fullSnapshotRequired {
                fullSnapshotRequired = false
                await reconcileAllPresentation(directory)
            } else {
                switch affected {
                case .all: await reconcileAllPresentation(directory)
                case .owners(let paneIds):
                    guard !paneIds.isEmpty else { return }
                    for paneId in paneIds {
                        do {
                            if try await computeDisplay(paneId: paneId) == nil {
                                presentationLane?.mailbox.removeAbsent(paneId)
                            }
                        } catch {
                            // Preserve the desired value on read failure; no removal was decided.
                        }
                    }
                }
            }
        }
    }

    private func reconcileAllPresentation(_ directory: PaneContextMembershipDirectory) async {
        guard !isStopping, let presentationLane else { return }
        let owners = directory.currentOwners()
        var displays: [PaneId: PaneContextDisplay] = [:]
        do {
            for owner in owners {
                if let display = try await computeDisplay(paneId: owner.paneId) { displays[owner.paneId] = display }
            }
        } catch { return }
        guard !isStopping else { return }
        let current = Dictionary(
            uniqueKeysWithValues: directory.currentOwners().map { ($0.paneId, $0.membershipRevision) })
        let captured = Dictionary(uniqueKeysWithValues: owners.map { ($0.paneId, $0.membershipRevision) })
        guard current == captured else {
            await reconcileAllPresentation(directory)
            return
        }
        presentationLane.mailbox.reconcile(displays)
    }

    func publishAffectedSources(_ sources: Set<PaneId>) async {
        guard presentationLane != nil, !isStopping else { return }
        var panes = sources
        if let directory = membership as? PaneContextMembershipDirectory {
            for source in sources {
                if let owner = directory.ownerPaneId(for: source) { panes.insert(owner) }
            }
        }
        for paneId in panes {
            do { _ = try await computeDisplay(paneId: paneId) } catch {
                // Publication is retried by later demand; a failed read changes no desired value.
            }
        }
    }

    private func computeDisplay(paneId: PaneId) async throws -> PaneContextDisplay? {
        guard !isStopping, !isPendingRetirement(paneId), let view = captureMembershipView(paneId: paneId) else {
            return nil
        }
        let sources = view.sources
        let session = try await sessionSummary(paneId)
        let now = wallNow
        let snapshot = try await sqliteAccess.write { database in
            try capturePaneContextDetail(database, paneId: paneId, sources: sources, now: now)
        }
        guard let snapshot, !isStopping, !isPendingRetirement(paneId) else { return nil }
        guard let current = captureMembershipView(paneId: paneId) else { return nil }
        guard current.sources == sources, current.revision == view.revision else {
            return try await computeDisplay(paneId: paneId)
        }
        if let previous = detailVersions[paneId], previous.version.sources == sources,
            zip(previous.version.sourceRevisions, snapshot.sourceRevisions).contains(where: { $0.0.value > $0.1.value }
            ),
            let desired = presentationLane?.mailbox.desiredDisplay(for: paneId)
        {
            // An earlier read may resume after a newer commit's projection.
            return desired
        }
        let version = PaneContextDetailVersion(
            sources: sources, membershipRevision: view.revision, sourceRevisions: snapshot.sourceRevisions,
            session: session)
        let display = PaneContextDisplay(
            revision: detailRevision(for: paneId, version: version), agentTitle: snapshot.title,
            agentLine: snapshot.line,
            own: PaneMessageCountFold.summarize(messages: snapshot.messages.first ?? [], sourceOrder: [paneId]),
            includingDrawers: PaneMessageCountFold.summarize(
                messages: snapshot.messages.flatMap { $0 }, sourceOrder: sources),
            pullRequests: .notApplicable)
        presentationLane?.mailbox.offer(display, for: paneId)
        return display
    }

    func captureMembershipView(paneId: PaneId) -> (sources: [PaneId], revision: UInt64?)? {
        if let directory = membership as? PaneContextMembershipDirectory {
            guard let view = directory.view(for: paneId) else { return nil }
            return (view.sources, view.membershipRevision)
        }
        guard let sources = membership.sources(for: paneId) else { return nil }
        return (sources, nil)
    }
}
