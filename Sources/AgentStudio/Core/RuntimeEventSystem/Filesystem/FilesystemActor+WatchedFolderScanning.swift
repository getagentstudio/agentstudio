import AgentStudioInfrastructure
import Foundation

extension FilesystemActor {
    @discardableResult
    package func updateRepositoryScanBaseline(_ repositories: [Repo], membershipRevision: UInt64) -> Bool {
        guard membershipRevision >= watchedFolderScanState.repositoryScanBaseline.membershipRevision else {
            return false
        }
        watchedFolderScanState.repositoryScanBaseline = WatchedFolderScanBaseline(
            membershipRevision: membershipRevision,
            checkoutPaths: repositories.flatMap(\.worktrees).map(\.path)
        )
        return true
    }

    /// Restored topology is previous knowledge, never positive evidence from this scan.
    package func refreshWatchedFolders(
        _ watchedPaths: [WatchedPath],
        restoring repositories: [Repo],
        membershipRevision: UInt64 = 0,
        scanning selectedPathIDs: Set<UUID>? = nil
    ) async -> WatchedFolderRefreshSummary {
        guard updateRepositoryScanBaseline(repositories, membershipRevision: membershipRevision) else {
            return watchedFolderRefreshSummary()
        }
        _ = await reconcileWatchedFolderRegistrations(watchedPaths)
        for (sourceID, registration) in watchedFolderScanState.registrationsBySourceID
        where watchedFolderScanState.inventoryBySourceID[sourceID] == nil {
            let root = registration.watchedPath.path.standardizedFileURL.path
            func covered(_ path: URL) -> Bool {
                let candidate = path.standardizedFileURL.path
                return candidate == root || candidate.hasPrefix(root + "/")
            }
            let groups = repositories.compactMap { repository -> RepoScanner.RepoScanGroup? in
                let linkedPaths = repository.worktrees
                    .filter { $0.path.standardizedFileURL != repository.repoPath.standardizedFileURL }
                    .map(\.path)
                    .filter(covered)
                guard covered(repository.repoPath) || !linkedPaths.isEmpty else { return nil }
                return RepoScanner.RepoScanGroup(
                    clonePath: repository.repoPath.standardizedFileURL,
                    linkedWorktreePaths: linkedPaths
                )
            }
            watchedFolderScanState.inventoryBySourceID[sourceID] = FilesystemWatchedFolderInventory(
                repoGroups: groups
            )
            publishWatchedFolderAdmission(for: sourceID)
        }
        return await refreshWatchedFolders(watchedPaths, scanning: selectedPathIDs)
    }

    func updateWatchedFolders(_ watchedPaths: [WatchedPath]) async {
        _ = await refreshWatchedFolders(watchedPaths)
    }

    package func refreshWatchedFolders(
        _ watchedPaths: [WatchedPath], scanning selectedPathIDs: Set<UUID>? = nil
    ) async -> WatchedFolderRefreshSummary {
        if let activeRefresh = watchedFolderScanState.manualRefreshState.task {
            _ = await activeRefresh.value
            return await refreshWatchedFolders(watchedPaths, scanning: selectedPathIDs)
        }
        let refreshID = UUIDv7.generate()
        let refreshTask = Task { [weak self] in
            guard let self else {
                return WatchedFolderRefreshSummary(repoPathsByWatchedFolder: [:])
            }
            let summary = await self.performManualWatchedFolderRefresh(
                watchedPaths,
                refreshID: refreshID,
                scanning: selectedPathIDs
            )
            await self.finishManualWatchedFolderRefreshTask(refreshID: refreshID)
            return summary
        }
        watchedFolderScanState.manualRefreshState = .running(id: refreshID, task: refreshTask)
        return await refreshTask.value
    }

    private func performManualWatchedFolderRefresh(
        _ watchedPaths: [WatchedPath],
        refreshID: UUID,
        scanning selectedPathIDs: Set<UUID>?
    ) async -> WatchedFolderRefreshSummary {
        guard !watchedFolderScanState.isShuttingDown else {
            return watchedFolderRefreshSummary()
        }
        startIngressTaskIfNeeded()
        let newlyRegisteredSourceIDs = await reconcileWatchedFolderRegistrations(watchedPaths)
        ensureWatchedFolderResultDrainStarted()

        var receiptsBySourceID: [FilesystemSourceID: WatchedFolderScanDemandReceipt] = [:]
        for registration in watchedFolderScanState.registrationsBySourceID.values
        where selectedPathIDs?.contains(registration.watchedPath.id) ?? true {
            let request = watchedFolderScanRequest(
                for: registration,
                cause: newlyRegisteredSourceIDs.contains(registration.registeredRoot.sourceID)
                    ? .initialAdd : .manual
            )
            switch await submitWatchedFolderScanRequest(request, intent: .tracked) {
            case .accepted(.tracked(let receipt, _)):
                receiptsBySourceID[request.sourceID] = receipt
            case .accepted(.untracked):
                preconditionFailure("tracked scan admission must return a receipt")
            case .rejected:
                continue
            }
        }
        await recordLogicalDebtSnapshotIfChanged()

        guard !watchedFolderScanState.isShuttingDown, !receiptsBySourceID.isEmpty else {
            startFallbackRescan()
            return watchedFolderRefreshSummary()
        }

        let summary = await withCheckedContinuation { continuation in
            guard
                case .running(let currentRefreshID, let refreshTask) =
                    watchedFolderScanState.manualRefreshState,
                currentRefreshID == refreshID,
                !watchedFolderScanState.isShuttingDown
            else {
                continuation.resume(returning: watchedFolderRefreshSummary())
                return
            }
            watchedFolderScanState.manualRefreshState = .waitingForResults(
                id: refreshID,
                task: refreshTask,
                wait: FilesystemManualWatchedFolderRefreshWait(
                    receiptsBySourceID: receiptsBySourceID,
                    continuation: continuation
                )
            )
            completeManualRefreshIfSatisfied()
        }
        startFallbackRescan()
        return summary
    }

    private func finishManualWatchedFolderRefreshTask(refreshID: UUID) {
        switch watchedFolderScanState.manualRefreshState {
        case .running(let currentRefreshID, _):
            if currentRefreshID == refreshID {
                watchedFolderScanState.manualRefreshState = .idle
            }
        case .waitingForResults(let currentRefreshID, _, _):
            if currentRefreshID == refreshID {
                watchedFolderScanState.manualRefreshState = .idle
            }
        case .idle:
            break
        }
    }

    func isWatchedFolderBatch(_ worktreeID: UUID) -> Bool {
        watchedFolderScanState.sourceIDByLegacyCallbackRoutingID[worktreeID] != nil
    }

    func handleWatchedFolderFSEvent(
        _ batch: FSEventBatch,
        shouldRecordLogicalDebt: Bool = true
    ) async {
        guard
            let sourceID = watchedFolderScanState.sourceIDByLegacyCallbackRoutingID[
                batch.worktreeId
            ],
            let registration = watchedFolderScanState.registrationsBySourceID[sourceID]
        else { return }
        let knownGroups = watchedFolderScanState.inventoryBySourceID[sourceID]?.repoGroups ?? []
        guard
            WatchedFolderTopologyAdmission.shouldScan(
                batch, root: registration.registeredRoot, knownGroups: knownGroups,
                heldCheckoutPaths: Array(watchedFolderScanState.publicationHoldPathsByID.values))
        else { return }
        recordWatchedFolderScanTrigger(
            sourceID,
            reason: batch.requiresFullGitRefresh || batch.observations.contains(where: \.hasCoverageLoss)
                ? .nativeCoverageLoss : .relevantChange)
        if shouldRecordLogicalDebt { await recordLogicalDebtSnapshotIfChanged() }
    }

    func handleCoarseWatchedFolderFSEvent(
        worktreeId: UUID,
        shouldRecordLogicalDebt: Bool = true
    ) async {
        guard
            let sourceID = watchedFolderScanState.sourceIDByLegacyCallbackRoutingID[worktreeId]
        else { return }
        recordWatchedFolderScanTrigger(sourceID, reason: .intakeCoverageLoss)
        if shouldRecordLogicalDebt { await recordLogicalDebtSnapshotIfChanged() }
    }

    private func reconcileWatchedFolderRegistrations(
        _ watchedPaths: [WatchedPath]
    ) async -> Set<FilesystemSourceID> {
        var desiredBySourceID: [FilesystemSourceID: WatchedPath] = [:]
        for watchedPath in watchedPaths.sorted(by: { $0.path.path < $1.path.path }) {
            let sourceID = FilesystemSourceID(
                kind: .watchedParentMembership,
                rootID: watchedPath.id
            )
            if desiredBySourceID[sourceID] == nil {
                desiredBySourceID[sourceID] = watchedPath
            }
        }
        var newlyRegisteredSourceIDs = Set<FilesystemSourceID>()
        let removedSourceIDs = Set(watchedFolderScanState.registrationsBySourceID.keys)
            .subtracting(desiredBySourceID.keys)
        var removedClonePaths = Set<URL>()

        for sourceID in removedSourceIDs {
            guard
                let registration = watchedFolderScanState.registrationsBySourceID.removeValue(
                    forKey: sourceID
                )
            else { continue }
            watchedFolderScanState.pacing.removeFolder(sourceID)
            _ = await watchedFolderScanScheduler.retireRegistration(registration.registeredRoot)
            await recordLogicalDebtSnapshotIfChanged()
            fseventStreamClient.updateWatchedFolderAdmission(
                worktreeId: registration.legacyCallbackRoutingID, snapshot: nil)
            fseventStreamClient.unregister(worktreeId: registration.legacyCallbackRoutingID)
            watchedFolderScanState.sourceIDByLegacyCallbackRoutingID.removeValue(
                forKey: registration.legacyCallbackRoutingID
            )
            if let inventory = watchedFolderScanState.inventoryBySourceID.removeValue(
                forKey: sourceID
            ) {
                removedClonePaths.formUnion(inventory.repoGroups.map(\.clonePath))
            }
            watchedFolderScanState.latestDemandCoverageBySourceID.removeValue(forKey: sourceID)
            watchedFolderScanState.appliedDemandCoverageBySourceID.removeValue(forKey: sourceID)
            watchedFolderScanState.lastAppliedResultIDBySourceID.removeValue(forKey: sourceID)
            watchedFolderScanState.authoritativeSourceIDs.remove(sourceID)
            watchedFolderScanState.validatedPathsBySourceID.removeValue(forKey: sourceID)
            watchedFolderScanState.latestObservationReceipts.removeValue(forKey: sourceID)
        }

        for (sourceID, watchedPath) in desiredBySourceID {
            if let existing = watchedFolderScanState.registrationsBySourceID[sourceID],
                existing.watchedPath == watchedPath
            {
                continue
            }
            if let existing = watchedFolderScanState.registrationsBySourceID[sourceID] {
                _ = await watchedFolderScanScheduler.retireRegistration(existing.registeredRoot)
                await recordLogicalDebtSnapshotIfChanged()
                fseventStreamClient.updateWatchedFolderAdmission(
                    worktreeId: existing.legacyCallbackRoutingID, snapshot: nil)
                fseventStreamClient.unregister(worktreeId: existing.legacyCallbackRoutingID)
                watchedFolderScanState.sourceIDByLegacyCallbackRoutingID.removeValue(
                    forKey: existing.legacyCallbackRoutingID
                )
                watchedFolderScanState.pacing.removeFolder(sourceID)
                watchedFolderScanState.latestDemandCoverageBySourceID.removeValue(forKey: sourceID)
            }
            guard
                let registeredRoot = makeWatchedFolderRegisteredRoot(
                    sourceID: sourceID,
                    watchedPath: watchedPath
                )
            else {
                continue
            }
            let legacyCallbackRoutingID = UUIDv7.generate()
            watchedFolderScanState.registrationsBySourceID[sourceID] =
                FilesystemWatchedFolderRegistration(
                    watchedPath: watchedPath,
                    registeredRoot: registeredRoot,
                    legacyCallbackRoutingID: legacyCallbackRoutingID
                )
            watchedFolderScanState.sourceIDByLegacyCallbackRoutingID[
                legacyCallbackRoutingID
            ] = sourceID
            newlyRegisteredSourceIDs.insert(sourceID)
            fseventStreamClient.register(
                worktreeId: legacyCallbackRoutingID,
                repoId: watchedPath.id,
                rootPath: watchedPath.path
            )
            publishWatchedFolderAdmission(for: sourceID)
        }

        await emitRemovedClones(noLongerReferencedByAnyWatchedFolder: removedClonePaths)
        return newlyRegisteredSourceIDs
    }

    func publishWatchedFolderAdmission(for sourceID: FilesystemSourceID) {
        guard let registration = watchedFolderScanState.registrationsBySourceID[sourceID] else { return }
        fseventStreamClient.updateWatchedFolderAdmission(
            worktreeId: registration.legacyCallbackRoutingID,
            snapshot: .init(
                root: registration.registeredRoot,
                knownGroups: watchedFolderScanState.inventoryBySourceID[sourceID]?.repoGroups ?? [],
                heldCheckoutPaths: Array(watchedFolderScanState.publicationHoldPathsByID.values)))
    }

    func publishAllWatchedFolderAdmissions() {
        for sourceID in watchedFolderScanState.registrationsBySourceID.keys {
            publishWatchedFolderAdmission(for: sourceID)
        }
    }

    private func makeWatchedFolderRegisteredRoot(
        sourceID: FilesystemSourceID,
        watchedPath: WatchedPath
    ) -> RegisteredRootDescriptor? {
        let previousGeneration =
            watchedFolderScanState.nextRegistrationGenerationBySourceID[sourceID] ?? 0
        let (generation, overflow) = previousGeneration.addingReportingOverflow(1)
        guard !overflow else { return nil }
        let registration = FSEventRegistrationToken(
            sourceID: sourceID,
            registrationGeneration: generation,
            rootGeneration: generation
        )
        do {
            let registeredRoot = try FilesystemSourceConfiguration.registerRoot(
                from: .hostAuthorized(
                    FilesystemHostAuthorizedRootInput(
                        registration: registration,
                        authorizedBoundary: watchedPath.path,
                        registeredRoot: watchedPath.path
                    )
                )
            )
            watchedFolderScanState.nextRegistrationGenerationBySourceID[sourceID] = generation
            return registeredRoot
        } catch {
            return nil
        }
    }

    func submitWatchedFolderScan(
        sourceID: FilesystemSourceID,
        cause: WatchedFolderScanCause,
        shouldRecordLogicalDebt: Bool = true
    ) async {
        guard !watchedFolderScanState.isShuttingDown else { return }
        guard let registration = watchedFolderScanState.registrationsBySourceID[sourceID] else {
            return
        }
        let request = watchedFolderScanRequest(for: registration, cause: cause)
        switch await submitWatchedFolderScanRequest(request, intent: .untracked) {
        case .accepted:
            if shouldRecordLogicalDebt {
                await recordLogicalDebtSnapshotIfChanged()
            }
        case .rejected:
            return
        }
    }

    func watchedFolderScanRequest(
        for registration: FilesystemWatchedFolderRegistration,
        cause: WatchedFolderScanCause
    ) -> WatchedFolderScanRequest {
        let baseline = watchedFolderScanState.repositoryScanBaseline
        let rootAliases = [
            registration.watchedPath.path.standardizedFileURL,
            URL(fileURLWithPath: registration.registeredRoot.aliases.onceResolvedCanonical.path).standardizedFileURL,
        ]
        let retainedPaths = baseline.checkoutPaths.filter { path in
            let components = path.standardizedFileURL.pathComponents
            return rootAliases.contains { components.starts(with: $0.pathComponents) }
        }
        // Reserved synchronously, before the caller awaits submission, so a hold released
        // while that submission is in flight still covers the scan it starts.
        watchedFolderScanState.lastReservedScanSubmissionSequence += 1
        watchedFolderScanState.pacing.reserveSubmission(
            registration.registeredRoot.sourceID, sequence: watchedFolderScanState.lastReservedScanSubmissionSequence,
            cause: cause, at: schedulingClock.now())
        return WatchedFolderScanRequest(
            canonicalRoot: registration.registeredRoot,
            cause: cause,
            baselineMembershipRevision: baseline.membershipRevision,
            retainedCheckoutPaths: retainedPaths,
            submissionSequence: watchedFolderScanState.lastReservedScanSubmissionSequence
        )
    }

    /// All causes share reservation, acceptance and registration/revision currency.
    func submitWatchedFolderScanRequest(
        _ request: WatchedFolderScanRequest, intent: WatchedFolderScanSubmissionIntent
    ) async -> WatchedFolderScanSubmissionResult {
        let result = await watchedFolderScanSubmission.submit(watchedFolderScanScheduler, request, intent)
        guard watchedFolderScanState.registrationsBySourceID[request.sourceID]?.registeredRoot == request.canonicalRoot,
            let reservation = watchedFolderScanState.pacing.submissionsBySourceID[request.sourceID]?[
                request.submissionSequence]
        else { return result }  // A result may already have settled this reservation.
        switch result {
        case .accepted(let acceptance):
            let coverage = acceptance.coverage
            watchedFolderScanState.pacing.recordAccepted(
                request.sourceID, coveredRevision: reservation.inFlight.coveredRevision,
                coverage: coverage, at: schedulingClock.now())
            if watchedFolderScanState.pacing.triggerRevisionBySourceID[request.sourceID, default: 0]
                == reservation.inFlight.coveredRevision,
                watchedFolderScanState.latestDemandCoverageBySourceID[request.sourceID]?.covers(coverage) != true
            {
                watchedFolderScanState.latestDemandCoverageBySourceID[request.sourceID] = coverage
            }
            ensureWatchedFolderResultDrainStarted()
        case .rejected:
            watchedFolderScanState.pacing.rejectSubmission(request.sourceID, sequence: request.submissionSequence)
        }
        return result
    }

    private func startFallbackRescan() {
        watchedFolderScanState.fallbackTask?.cancel()
        guard !watchedFolderScanState.isShuttingDown,
            !watchedFolderScanState.registrationsBySourceID.isEmpty
        else { return }
        watchedFolderScanState.fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await AsyncDelay.taskSleep.wait(
                        AppPolicies.WatchedFolderScanning.fallbackCadence
                    )
                } catch {
                    return
                }
                guard let self else { return }
                await self.submitAllWatchedFolderScans(cause: .fallback)
            }
        }
    }

    private func submitAllWatchedFolderScans(cause: WatchedFolderScanCause) async {
        for sourceID in watchedFolderScanState.registrationsBySourceID.keys {
            await submitWatchedFolderScan(sourceID: sourceID, cause: cause)
        }
    }

}
