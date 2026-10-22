import AgentStudioInfrastructure
import CryptoKit
import Foundation

extension FilesystemActor {
    func ensureWatchedFolderResultDrainStarted() {
        guard !watchedFolderScanState.isShuttingDown,
            case .idle = watchedFolderScanState.resultDrainState
        else { return }
        let bindingID = UUIDv7.generate()
        let drainTask = Task { [weak self] in
            guard let self else { return }
            await self.bindAndDrainWatchedFolderScanResults(bindingID: bindingID)
        }
        watchedFolderScanState.resultDrainState = .bindingConsumer(
            id: bindingID,
            task: drainTask
        )
    }

    private func bindAndDrainWatchedFolderScanResults(bindingID: UUID) async {
        switch await watchedFolderScanScheduler.bindResultConsumer(
            watchedFolderScanState.resultConsumer
        ) {
        case .bound, .alreadyBound:
            break
        case .rejected(.schedulerShutDown):
            finishWatchedFolderResultDrain(bindingID: bindingID)
            return
        case .rejected(.anotherConsumerBound):
            preconditionFailure("FilesystemActor must own the sole watched-folder result consumer")
        }
        guard
            case .bindingConsumer(let retainedBindingID, let drainTask) =
                watchedFolderScanState.resultDrainState,
            retainedBindingID == bindingID
        else { return }
        watchedFolderScanState.resultDrainState = .running(
            id: bindingID,
            task: drainTask
        )
        await drainWatchedFolderScanResults(bindingID: bindingID)
    }

    private func drainWatchedFolderScanResults(bindingID: UUID) async {
        let consumer = watchedFolderScanState.resultConsumer
        while !Task.isCancelled {
            switch await watchedFolderScanScheduler.nextResultLease(for: consumer) {
            case .leased(let lease):
                let submittedDiagnostics = lease.submittedDiagnostics
                await applyWatchedFolderScanResult(lease.result)
                let resolution = await watchedFolderScanScheduler.resolveResultLease(
                    for: consumer,
                    leaseID: lease.leaseID,
                    submittedDiagnostics: submittedDiagnostics,
                    resolution: .transferred
                )
                recordResultLeaseObservation(resolution, submitted: submittedDiagnostics, at: .afterResolve)
                await recordLogicalDebtSnapshotIfChanged()
                recordResultLeaseObservation(resolution, submitted: submittedDiagnostics, at: .beforeSwitch)
                switch resolution {
                case .transferred, .staleResultDiscarded:
                    break
                case .queuedForRetry:
                    await reportResultLeaseCustodyFailure(consumer: consumer, lease: lease)
                    preconditionFailure("transferred result cannot be queued for retry")
                case .rejected:
                    await reportResultLeaseCustodyFailure(consumer: consumer, lease: lease)
                    preconditionFailure("FilesystemActor lost exact result-lease custody")
                }
            case .cancelled, .consumerUnbound, .schedulerShutDown:
                finishWatchedFolderResultDrain(bindingID: bindingID)
                return
            case .rejected(.consumerMismatch):
                preconditionFailure("FilesystemActor result consumer identity changed")
            case .rejected(.waiterAlreadyRegistered):
                preconditionFailure("FilesystemActor created multiple result waiters")
            case .rejected(.leaseAlreadyOutstanding):
                preconditionFailure("FilesystemActor requested a second result lease")
            case .rejected(.leaseIdentityExhausted):
                preconditionFailure("watched-folder result lease UUIDv7 generation exhausted")
            }
        }
        finishWatchedFolderResultDrain(bindingID: bindingID)
    }

    private func finishWatchedFolderResultDrain(bindingID: UUID) {
        switch watchedFolderScanState.resultDrainState {
        case .idle:
            return
        case .bindingConsumer(let retainedBindingID, _),
            .running(let retainedBindingID, _):
            guard retainedBindingID == bindingID else { return }
            watchedFolderScanState.resultDrainState = .idle
        }
    }

    private func applyWatchedFolderScanResult(_ result: ScheduledWatchedFolderScanResult) async {
        let sourceID = result.request.sourceID
        guard
            let registration = watchedFolderScanState.registrationsBySourceID[sourceID],
            registration.registeredRoot == result.request.canonicalRoot,
            result.demandCoverage.registration == registration.registeredRoot.registration
        else { return }
        guard watchedFolderScanState.lastAppliedResultIDBySourceID[sourceID] != result.resultID else {
            return
        }

        let previousGroups = watchedFolderScanState.inventoryBySourceID[sourceID]?.repoGroups ?? []
        let latestCoverage = watchedFolderScanState.latestDemandCoverageBySourceID[sourceID]
        let scannerResult = WatchedFolderPublicationHolds.excludingHeldCheckouts(
            from: result.scannerResult,
            heldPaths: publicationHeldPaths(forResultOf: result.request)
        )
        retireReleasedPublicationHolds(satisfiedBy: result.request)
        let reduction = WatchedFolderInventoryReducer.reduce(
            previousGroups: previousGroups,
            scannerResult: scannerResult,
            mayReplaceNegativeSpace: latestCoverage == result.demandCoverage
        )

        let observedAt: RepositoryRetentionTime?
        if case .authoritativeReplacement = reduction {
            observedAt = try? await RepositoryRetentionTime.current()
        } else {
            observedAt = nil
        }
        guard watchedFolderScanState.registrationsBySourceID[sourceID]?.registeredRoot == registration.registeredRoot
        else {
            return
        }
        let coverage: WatchedFolderTopologyCoverage
        switch reduction {
        case .authoritativeReplacement(let replacement):
            if let observedAt,
                watchedFolderScanState.latestDemandCoverageBySourceID[sourceID] == result.demandCoverage
            {
                coverage = .authoritative(observedAt)
                watchedFolderScanState.inventoryBySourceID[sourceID] = .init(repoGroups: replacement.repoGroups)
            } else {
                coverage = .additive
                guard
                    case .additiveMerge(let fallback) = WatchedFolderInventoryReducer.reduce(
                        previousGroups: previousGroups, scannerResult: scannerResult,
                        mayReplaceNegativeSpace: false
                    )
                else { preconditionFailure("complete evidence must support additive fallback") }
                watchedFolderScanState.inventoryBySourceID[sourceID] = .init(repoGroups: fallback.repoGroups)
            }
        case .additiveMerge(let replacement):
            coverage = .additive
            watchedFolderScanState.inventoryBySourceID[sourceID] = .init(repoGroups: replacement.repoGroups)
        case .preserved:
            coverage = .additive
        }
        let entries = Self.validatedEntries(in: scannerResult)
        watchedFolderScanState.validatedPathsBySourceID[sourceID] = Set(entries.map { $0.path.standardizedFileURL })
        if case .authoritative = coverage {
            watchedFolderScanState.authoritativeSourceIDs.insert(sourceID)
        } else {
            watchedFolderScanState.authoritativeSourceIDs.remove(sourceID)
        }
        watchedFolderScanState.appliedDemandCoverageBySourceID[sourceID] = result.demandCoverage
        watchedFolderScanState.lastAppliedResultIDBySourceID[sourceID] = result.resultID
        var otherPaths = Set<URL>()
        var otherEntries: [RepoScanner.ResolvedGitEntry] = []
        var incompleteScopes: [URL] = []
        for (otherID, otherRegistration) in watchedFolderScanState.registrationsBySourceID where otherID != sourceID {
            if watchedFolderScanState.authoritativeSourceIDs.contains(otherID),
                let applied = watchedFolderScanState.appliedDemandCoverageBySourceID[otherID],
                applied == watchedFolderScanState.latestDemandCoverageBySourceID[otherID]
            {
                otherPaths.formUnion(watchedFolderScanState.validatedPathsBySourceID[otherID] ?? [])
                otherEntries.append(
                    contentsOf: watchedFolderScanState.latestObservationReceipts[otherID]?.observation.entries ?? [])
            } else {
                incompleteScopes.append(otherRegistration.watchedPath.path.standardizedFileURL)
                incompleteScopes.append(
                    URL(fileURLWithPath: otherRegistration.registeredRoot.aliases.onceResolvedCanonical.path))
            }
        }
        nextEnvelopeSequence += 1
        let observation = WatchedFolderTopologyObservation(
            root: registration.watchedPath.path, registration: registration.registeredRoot.registration,
            entries: entries, otherObservedPaths: otherPaths, coverage: coverage,
            baselineMembershipRevision: result.request.baselineMembershipRevision,
            incompleteOtherScopes: incompleteScopes, demandCoverage: result.demandCoverage,
            canonicalRoot: URL(fileURLWithPath: registration.registeredRoot.aliases.onceResolvedCanonical.path),
            overlappingSourceVersions: overlappingSourceVersions(for: registration.registeredRoot),
            otherObservedEntries: otherEntries
        )
        watchedFolderScanState.latestObservationReceipts[sourceID] = .init(
            sequence: nextEnvelopeSequence, observation: observation)
        _ = await runtimeBus.post(
            .system(
                SystemEnvelope(
                    source: .builtin(.filesystemWatcher), seq: nextEnvelopeSequence, timestamp: envelopeClock.now,
                    event: .topology(.watchedFolderReconciled(observation))
                )))
        completeManualRefreshIfSatisfied()
    }

    package func currentWatchedFolderObservationReceipts() -> [WatchedFolderTopologyReceipt] {
        watchedFolderScanState.latestObservationReceipts.values.filter {
            isCurrentWatchedFolderObservation($0.observation)
        }
    }

    package func areCurrentWatchedFolderObservations(_ observations: [WatchedFolderTopologyObservation]) -> Bool {
        observations.allSatisfy(isCurrentWatchedFolderObservation)
    }

    private func isCurrentWatchedFolderObservation(_ observation: WatchedFolderTopologyObservation) -> Bool {
        let sourceID = observation.registration.sourceID
        guard let registration = watchedFolderScanState.registrationsBySourceID[sourceID],
            registration.registeredRoot.registration == observation.registration,
            registration.watchedPath.path.standardizedFileURL == observation.root.standardizedFileURL,
            registration.registeredRoot.aliases.onceResolvedCanonical.path == observation.canonicalRoot.path,
            let coverage = observation.demandCoverage,
            watchedFolderScanState.latestDemandCoverageBySourceID[sourceID] == coverage,
            watchedFolderScanState.appliedDemandCoverageBySourceID[sourceID] == coverage
        else { return false }
        let currentOverlaps = overlappingSourceVersions(for: registration.registeredRoot)
        guard Set(currentOverlaps.keys) == Set(observation.overlappingSourceVersions.keys) else { return false }
        return observation.overlappingSourceVersions.allSatisfy { sourceID, expected in
            guard let current = currentOverlaps[sourceID], current.registration == expected.registration else {
                return false
            }
            // A region captured as incomplete remains protected even if its scan subsequently finishes.
            guard let authoritativeCoverage = expected.authoritativeCoverage else { return true }
            return current.authoritativeCoverage == authoritativeCoverage
        }
    }

    private func overlappingSourceVersions(
        for root: RegisteredRootDescriptor
    ) -> [FilesystemSourceID: WatchedFolderTopologySourceVersion] {
        var versions: [FilesystemSourceID: WatchedFolderTopologySourceVersion] = [:]
        for (sourceID, other) in watchedFolderScanState.registrationsBySourceID
        where sourceID != root.sourceID && Self.watchedRootsOverlap(root, other.registeredRoot) {
            let applied = watchedFolderScanState.appliedDemandCoverageBySourceID[sourceID]
            let isComplete =
                watchedFolderScanState.authoritativeSourceIDs.contains(sourceID)
                && applied == watchedFolderScanState.latestDemandCoverageBySourceID[sourceID]
            versions[sourceID] = .init(
                registration: other.registeredRoot.registration, authoritativeCoverage: isComplete ? applied : nil)
        }
        return versions
    }

    private static func watchedRootsOverlap(_ first: RegisteredRootDescriptor, _ second: RegisteredRootDescriptor)
        -> Bool
    {
        let isCaseInsensitive =
            first.volumeSemantics.casePolicy == .caseInsensitive
            || second.volumeSemantics.casePolicy == .caseInsensitive
        func normalizedPath(_ root: RegisteredRootDescriptor) -> String {
            let path = FilesystemRootOwnership.canonicalizeKernelPath(root.aliases.onceResolvedCanonical.path)
                .precomposedStringWithCanonicalMapping
            return isCaseInsensitive ? path.lowercased() : path
        }
        let firstPath = normalizedPath(first)
        let secondPath = normalizedPath(second)
        return firstPath == "/" || secondPath == "/" || firstPath == secondPath
            || firstPath.hasPrefix(secondPath + "/") || secondPath.hasPrefix(firstPath + "/")
    }

    private static func validatedEntries(in result: RepoScannerResult) -> [RepoScanner.ResolvedGitEntry] {
        switch result {
        case .completeAuthoritative(let scan): return scan.verifiedEntries
        case .partial(let scan): return scan.verifiedEntries
        case .cancelled(let scan): return scan.verifiedEntries
        case .failed, .unavailable: return []
        }
    }

    func completeManualRefreshIfSatisfied() {
        guard
            case .waitingForResults(let refreshID, let refreshTask, let manualRefresh) =
                watchedFolderScanState.manualRefreshState
        else { return }
        let allSatisfied = manualRefresh.receiptsBySourceID.allSatisfy { sourceID, receipt in
            watchedFolderScanState.appliedDemandCoverageBySourceID[sourceID]?.covers(receipt) == true
        }
        guard allSatisfied else { return }
        watchedFolderScanState.manualRefreshState = .running(id: refreshID, task: refreshTask)
        manualRefresh.continuation.resume(returning: watchedFolderRefreshSummary())
    }

    func cancelManualWatchedFolderRefreshForShutdown() {
        guard
            case .waitingForResults(let refreshID, let refreshTask, let manualRefresh) =
                watchedFolderScanState.manualRefreshState
        else { return }
        watchedFolderScanState.manualRefreshState = .running(id: refreshID, task: refreshTask)
        manualRefresh.continuation.resume(returning: watchedFolderRefreshSummary())
    }

    func watchedFolderRefreshSummary() -> WatchedFolderRefreshSummary {
        var repoPathsByWatchedFolder: [URL: [URL]] = [:]
        var linkedWorktreePathsByWatchedFolder: [URL: [URL]] = [:]
        var fingerprintComponents: [String] = []
        for (sourceID, registration) in watchedFolderScanState.registrationsBySourceID {
            let watchedRoot = registration.watchedPath.path.standardizedFileURL
            let groups = watchedFolderScanState.inventoryBySourceID[sourceID]?.repoGroups ?? []
            let repoPaths = groups.map(\.clonePath).sorted(by: Self.sortByPath)
            let linkedWorktreePaths = groups.flatMap(\.linkedWorktreePaths).sorted(by: Self.sortByPath)
            repoPathsByWatchedFolder[watchedRoot] = repoPaths
            linkedWorktreePathsByWatchedFolder[watchedRoot] = linkedWorktreePaths
            fingerprintComponents.append("root:\(StableKey.fromPath(watchedRoot))")
            fingerprintComponents.append(contentsOf: repoPaths.map { "repo:\(StableKey.fromPath($0))" })
            fingerprintComponents.append(
                contentsOf: linkedWorktreePaths.map { "worktree:\(StableKey.fromPath($0))" }
            )
        }
        let topologyFingerprint: String?
        if repoPathsByWatchedFolder.values.allSatisfy({ !$0.isEmpty }) {
            let digest = SHA256.hash(
                data: Data(fingerprintComponents.sorted().joined(separator: "\n").utf8)
            )
            topologyFingerprint = digest.map { String(format: "%02x", $0) }.joined()
        } else {
            topologyFingerprint = nil
        }
        return WatchedFolderRefreshSummary(
            repoPathsByWatchedFolder: repoPathsByWatchedFolder,
            linkedWorktreePathsByWatchedFolder: linkedWorktreePathsByWatchedFolder,
            topologyFingerprint: topologyFingerprint
        )
    }
}
