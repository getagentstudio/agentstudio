import AgentStudioInfrastructure
import Foundation

enum GitDemandTier: String, CaseIterable, Sendable {
    case activePane = "active_pane"
    case visibleSidebar = "visible_sidebar"
    case openPane = "open_pane"
    case background

    func cadence(in policy: AppPolicies.GitRefresh.Policy) -> Duration {
        switch self {
        case .activePane: policy.activePaneCadence
        case .visibleSidebar: policy.visibleSidebarCadence
        case .openPane: policy.openPaneCadence
        case .background: policy.backgroundCadence
        }
    }

    func maximumConcurrent(in policy: AppPolicies.GitRefresh.Policy) -> Int {
        switch self {
        case .activePane: policy.activePaneMaxConcurrent
        case .visibleSidebar: policy.visibleSidebarMaxConcurrent
        case .openPane: policy.openPaneMaxConcurrent
        case .background: policy.backgroundMaxConcurrent
        }
    }
}

/// Attention-tiered admission for pending git status computes. Pending debt is
/// never removed here until a slot is granted: demotion changes eligibility and
/// cadence, not whether the refresh survives.
extension GitWorkingDirectoryProjector {
    /// One immutable key per candidate. The comparator never reads projector state.
    struct PendingAdmissionCandidate: Comparable, Sendable {
        let worktreeId: UUID
        let tier: GitDemandTier
        let isExplicit: Bool
        let priority: Int
        let timestamp: ContinuousClock.Instant
        let batchSeq: UInt64
        let uuidString: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.batchSeq != rhs.batchSeq { return lhs.batchSeq < rhs.batchSeq }
            return lhs.uuidString < rhs.uuidString
        }
    }

    func grantDemandEligibility(worktreeId: UUID) {
        tierEligibleWorktreeIds.insert(worktreeId)
    }

    func admitPendingWorktrees() {
        guard !isShuttingDown else { return }
        guard !hasGlobalCapacityRetryPause else { return }
        let availableSlots = refreshPolicy.maxConcurrentStatusComputes - worktreeTasks.count
        guard availableSlots > 0 else { return }

        let candidates = pendingAdmissionCandidates()
        guard !candidates.isEmpty else { return }

        var admittedWorktreeIds: [UUID] = []
        let runningDemandTiers = worktreeTasks.keys.map { worktreeId in
            admittedDemandTierByWorktreeId[worktreeId] ?? demandTier(for: worktreeId)
        }
        var runningCountByTier = Dictionary(grouping: runningDemandTiers, by: { $0 })
            .mapValues(\.count)
        let runningLowerTierCount = runningDemandTiers.filter { $0 != .activePane }.count
        let reservedActivePaneSlotCount = min(
            refreshPolicy.activePaneMaxConcurrent,
            max(0, refreshPolicy.maxConcurrentStatusComputes - 1)
        )
        var availableLowerTierSlots = max(
            0,
            refreshPolicy.maxConcurrentStatusComputes
                - reservedActivePaneSlotCount
                - runningLowerTierCount
        )
        var selectedPacedAutomaticStart = false
        var scheduledGovernorWake = false
        var nextGovernorDeadline = nextAutomaticStartAt

        for candidate in candidates.sorted() {
            guard admittedWorktreeIds.count < availableSlots else { break }
            let worktreeId = candidate.worktreeId
            if candidate.isExplicit {
                guard admitPendingWorktreeAfterPathCheck(worktreeId: worktreeId) else { continue }
                admittedWorktreeIds.append(worktreeId)
                continue
            }

            let tier = candidate.tier
            let runningTierCount = runningCountByTier[tier, default: 0]
            guard runningTierCount < tier.maximumConcurrent(in: refreshPolicy) else { continue }
            if tier != .activePane {
                guard availableLowerTierSlots > 0 else { continue }
            }
            let requiresStartPacing =
                !capacityRearmedWorktreeIds.contains(worktreeId)
                && requiresAutomaticStartPacing(worktreeId: worktreeId, isExplicit: false)
            if requiresStartPacing {
                if selectedPacedAutomaticStart || deadlineClock.now < nextAutomaticStartAt {
                    if !scheduledGovernorWake {
                        setRefreshDeadline(
                            nextGovernorDeadline,
                            kind: .automatic,
                            worktreeId: worktreeId,
                            factKind: .governorPacing
                        )
                        scheduledGovernorWake = true
                    }
                    continue
                }
            }
            guard admitPendingWorktreeAfterPathCheck(worktreeId: worktreeId) else { continue }
            if requiresStartPacing {
                selectedPacedAutomaticStart = true
                nextGovernorDeadline = max(
                    nextAutomaticStartAt,
                    deadlineClock.now + refreshPolicy.minimumAutomaticStartInterval
                )
            }
            if tier != .activePane {
                availableLowerTierSlots -= 1
            }
            admittedWorktreeIds.append(worktreeId)
            runningCountByTier[tier, default: 0] += 1
        }

        for worktreeId in admittedWorktreeIds {
            startAdmittedWorktree(worktreeId: worktreeId)
        }
        if scheduledGovernorWake {
            rescheduleDeadlineTask()
        }
        guard !admittedWorktreeIds.isEmpty else { return }
        recordGitAdmissionTelemetry(
            admittedWorktreeIds: admittedWorktreeIds,
            availableSlots: availableSlots
        )
    }

    private func startAdmittedWorktree(worktreeId: UUID) {
        let isCapacityRearmed = capacityRearmedWorktreeIds.remove(worktreeId) != nil
        let isExplicit: Bool
        let admittedTier: GitDemandTier
        if isCapacityRearmed {
            isExplicit = refreshAttribution.admittedDemandClassByWorktreeId[worktreeId] == "explicit"
            admittedTier = admittedDemandTierByWorktreeId[worktreeId] ?? demandTier(for: worktreeId)
        } else {
            refreshAttribution.nextRequestSequence &+= 1
            refreshAttribution.requestSequenceByWorktreeId[worktreeId] = refreshAttribution.nextRequestSequence
            admissionStartedAtByWorktreeId[worktreeId] = envelopeClock.now
            isExplicit = explicitRefreshWorktreeIds.contains(worktreeId)
            admittedTier = demandTier(for: worktreeId)
            refreshAttribution.admittedDemandClassByWorktreeId[worktreeId] =
                isExplicit ? "explicit" : admittedTier.rawValue
            refreshAttribution.admittedCadenceTierByWorktreeId[worktreeId] = admittedTier.rawValue
            let admittedTriggerSource = refreshAttribution.triggerSourceByWorktreeId[worktreeId] ?? .registration
            refreshAttribution.admittedTriggerSourceByWorktreeId[worktreeId] = admittedTriggerSource
            recordAutomaticAdmission(worktreeId: worktreeId, isExplicit: isExplicit)
        }
        admittedDemandTierByWorktreeId[worktreeId] = admittedTier
        explicitRefreshWorktreeIds.remove(worktreeId)
        tierEligibleWorktreeIds.remove(worktreeId)
        if let changeset = pendingByWorktreeId[worktreeId] {
            closeIntakeFactOnce(
                worktreeId: worktreeId, batchSeq: changeset.batchSeq, fact: .changesetAccepted)
        }
        if let requestSequence = refreshAttribution.requestSequenceByWorktreeId[worktreeId] {
            admitRefreshFact(worktreeId: worktreeId, requestSequence: requestSequence)
        }
        startDrainTask(worktreeId: worktreeId)
    }

    func pendingAdmissionCandidates() -> [PendingAdmissionCandidate] {
        pendingByWorktreeId.compactMap { worktreeId, changeset in
            guard worktreeTasks[worktreeId] == nil,
                !suppressedWorktreeIds.contains(worktreeId),
                !quarantinedWorktreeIds.contains(worktreeId),
                !capacityRetryWorktreeIds.contains(worktreeId),
                isDemandEligible(worktreeId: worktreeId)
            else { return nil }
            let tier = pendingAdmissionDemandTier(for: worktreeId)
            let isExplicit = explicitRefreshWorktreeIds.contains(worktreeId)
            let tierPriority: Int =
                switch tier {
                case .activePane: 0
                case .visibleSidebar: 1
                case .openPane: 2
                case .background: 3
                }
            return PendingAdmissionCandidate(
                worktreeId: worktreeId,
                tier: tier,
                isExplicit: isExplicit,
                priority: isExplicit ? -1 : tierPriority,
                timestamp: changeset.timestamp,
                batchSeq: changeset.batchSeq,
                uuidString: worktreeId.uuidString
            )
        }
    }

    private func pendingAdmissionDemandTier(for worktreeId: UUID) -> GitDemandTier {
        guard capacityRearmedWorktreeIds.contains(worktreeId) else {
            return demandTier(for: worktreeId)
        }
        return admittedDemandTierByWorktreeId[worktreeId] ?? demandTier(for: worktreeId)
    }

    func demandTier(for worktreeId: UUID) -> GitDemandTier {
        if activePaneWorktreeId == worktreeId { return .activePane }
        if backgroundOnlyAutomaticWorktreeIds.contains(worktreeId) { return .background }
        if sidebarVisibleWorktreeIds.contains(worktreeId) { return .visibleSidebar }
        if activeWorktreeIds.contains(worktreeId) { return .openPane }
        return .background
    }

    func isDemandEligible(worktreeId: UUID) -> Bool {
        if registeredContext(for: worktreeId) == nil
            || explicitRefreshWorktreeIds.contains(worktreeId)
            || hasRequiredIntent(worktreeId: worktreeId)
        {
            return true
        }
        guard isAutomaticEligible(worktreeId: worktreeId) else { return false }
        return activePaneWorktreeId == worktreeId
            || activeWorktreeIds.contains(worktreeId)
            || tierEligibleWorktreeIds.contains(worktreeId)
    }

}
