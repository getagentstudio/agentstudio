import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

extension GitWorkingDirectoryProjectorAdmissionTests {
    @Test("prepared admission keys match the independent priority and fairness oracle")
    func preparedAdmissionKeysMatchOrderingOracle() async {
        // Arrange: explicit priority, every retained/current tier, and all tie breakers.
        let timestamp = ContinuousClock().now
        let rows = admissionOrderRows(timestamp: timestamp)
        let projector = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero
        )
        await installAdmissionOrderRows(rows, in: projector)
        let expectedIds = rows.sorted(by: admissionOrderOracle).map(\.worktreeId)

        // Act: capture keys, then change the live attention and pending state.
        let candidates = await projector.pendingAdmissionCandidates()
        await removeAdmissionOrderInputs(from: projector)

        // Assert: sorting the captured values cannot consult changed actor state.
        #expect(candidates.sorted().map(\.worktreeId) == expectedIds)
        #expect(Set(candidates.map(\.worktreeId)) == Set(rows.map(\.worktreeId)))
        await projector.shutdown()
    }

    @Test("mixed-tier admission retains capacity, reserved slots and pacing", arguments: [false, true])
    func mixedTierAdmissionMatchesCapacityAndPacingOracle(pacingIsBlocked: Bool) async throws {
        // Arrange: a paid visible-tier retry now has background attention.
        let clock = TestPushClock()
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let admissions = Mutex<[UUID]>([])
        let heldStatus = HeldStep<Void>("mixed-tier admitted status reads")
        let policy = AppPolicies.GitRefresh.Policy(
            maxConcurrentStatusComputes: 5,
            activePaneMaxConcurrent: 1,
            visibleSidebarMaxConcurrent: 2,
            openPaneMaxConcurrent: 2,
            backgroundMaxConcurrent: 2,
            minimumAutomaticStartInterval: .milliseconds(10)
        )
        let projector = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in
                try? await heldStatus.arrive(())
                return GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main", origin: nil
                )
            },
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: { scope, fact in
                source.sink(scope, fact)
                if case .refresh(let worktreeId, _) = scope, fact == .refreshAdmitted {
                    admissions.withLock { $0.append(worktreeId) }
                }
            }
        )
        let timestamp = ContinuousClock().now
        let rows = [
            AdmissionOrderRow(tier: .background, explicit: true, timestamp: timestamp, batchSeq: 9),
            AdmissionOrderRow(tier: .activePane, timestamp: timestamp, batchSeq: 8),
            AdmissionOrderRow(tier: .background, retainedTier: .visibleSidebar, timestamp: timestamp, batchSeq: 1),
            AdmissionOrderRow(tier: .visibleSidebar, timestamp: timestamp, batchSeq: 3),
            AdmissionOrderRow(tier: .visibleSidebar, timestamp: timestamp, batchSeq: 2),
            AdmissionOrderRow(tier: .openPane, timestamp: timestamp, batchSeq: 1),
            AdmissionOrderRow(tier: .background, timestamp: timestamp, batchSeq: 0),
        ]
        await installAdmissionOrderRows(rows, in: projector)
        await setAdmissionOrderPacing(projector, blocked: pacingIsBlocked)
        let expectedIds = admissionCapacityOracle(rows, policy: policy, pacingIsBlocked: pacingIsBlocked)

        // Act: one synchronous selection pass; status reads remain held.
        await projector.admitPendingWorktrees()

        // Assert: request admission facts establish order before provider scheduling.
        #expect(admissions.withLock { $0 } == expectedIds)
        #expect(await projector.worktreeTasks.count == expectedIds.count)
        #expect(await projector.pendingByWorktreeId.count >= rows.count - expectedIds.count)
        let deadlineScope = try await source.expectDeadlineRegistered(facts: facts, kind: .governorPacing)
        let opening = await facts.mark(deadlineScope)
        for worktreeId in expectedIds {
            _ = try await facts.expectNextRefreshStarted(worktreeId: worktreeId)
        }
        #expect(await projector.pendingByWorktreeId.count == rows.count - expectedIds.count)

        // Advancing the controlled clock admits one additional paced candidate.
        let deadline = clock.now.advanced(by: policy.minimumAutomaticStartInterval)
        #expect(await clock.waitForPendingSleep(deadline: deadline) == deadline)
        clock.advance(to: deadline)
        try await facts.expectNone(
            of: { $0 == .deadlineDisposition(.cancelled) }, "cancelled governor wake",
            from: opening, closedBy: { if case .deadlineDisposition = $0 { true } else { false } }
        )
        let expectedAfterWake = expectedIds + [pacingIsBlocked ? rows[4].worktreeId : rows[5].worktreeId]
        #expect(admissions.withLock { $0 } == expectedAfterWake)
        #expect(await projector.worktreeTasks.count == expectedAfterWake.count)
        #expect(await projector.worktreeTasks.count <= policy.maxConcurrentStatusComputes)

        heldStatus.release()
        await projector.shutdown()
        try await facts.finish()
    }

    @Test("lower-tier paid retries leave the active-pane reservation available")
    func paidRetriesPreserveReservedActivePaneSlots() async throws {
        // Arrange: all tier limits allow work, but two of four slots are reserved.
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let heldStatus = HeldStep<Void>("reserved-slot status reads")
        let projector = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in
                try? await heldStatus.arrive(())
                return GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main", origin: nil
                )
            },
            coalescingWindow: .zero,
            sleepClock: TestPushClock(),
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                maxConcurrentStatusComputes: 4, activePaneMaxConcurrent: 2,
                visibleSidebarMaxConcurrent: 2, openPaneMaxConcurrent: 2, backgroundMaxConcurrent: 2
            ),
            factSink: source.sink
        )
        let timestamp = ContinuousClock().now
        let rows = [GitDemandTier.visibleSidebar, .openPane, .background].map { tier in
            AdmissionOrderRow(tier: .background, retainedTier: tier, timestamp: timestamp, batchSeq: 0)
        }
        await installAdmissionOrderRows(rows, in: projector)

        // Act / Assert: only the two highest-ranked lower tiers can take slots.
        await projector.admitPendingWorktrees()
        for row in rows.prefix(2) {
            _ = try await facts.expectNextRefreshStarted(worktreeId: row.worktreeId)
        }
        #expect(await Set(projector.worktreeTasks.keys) == Set(rows.prefix(2).map(\.worktreeId)))
        #expect(await projector.pendingByWorktreeId[rows[2].worktreeId] != nil)
        heldStatus.release()
        await projector.shutdown()
        try await facts.finish()
    }
}

private struct AdmissionOrderRow: Sendable {
    let worktreeId = UUIDv7.generate()
    let tier: GitDemandTier
    var retainedTier: GitDemandTier?
    var explicit = false
    let timestamp: ContinuousClock.Instant
    let batchSeq: UInt64

    var effectiveTier: GitDemandTier { retainedTier ?? tier }
    var rootPath: URL { URL(fileURLWithPath: "/tmp/admission-order-\(worktreeId)") }
}

private func admissionOrderRows(timestamp: ContinuousClock.Instant) -> [AdmissionOrderRow] {
    var rows = [AdmissionOrderRow(tier: .activePane, timestamp: timestamp, batchSeq: 0)]
    for tier in [GitDemandTier.visibleSidebar, .openPane, .background] {
        for explicit in [false, true] {
            for retainedTier in [GitDemandTier.activePane, .visibleSidebar, .openPane, .background] {
                for batchSeq in [UInt64(1), 2, 0, 0] {
                    rows.append(
                        AdmissionOrderRow(
                            tier: tier, retainedTier: retainedTier, explicit: explicit,
                            timestamp: timestamp.advanced(by: batchSeq == 1 ? .milliseconds(-1) : .zero),
                            batchSeq: batchSeq
                        ))
                }
            }
        }
        rows.append(AdmissionOrderRow(tier: tier, timestamp: timestamp, batchSeq: 0))
    }
    return rows
}

// Documented rule: explicit first; active, visible, open, background; then oldest
// pending timestamp, smallest batch sequence, and lexicographic UUID string.
private func admissionOrderOracle(_ lhs: AdmissionOrderRow, _ rhs: AdmissionOrderRow) -> Bool {
    let ranks: [GitDemandTier: Int] = [.activePane: 0, .visibleSidebar: 1, .openPane: 2, .background: 3]
    let lhsRank = lhs.explicit ? -1 : ranks[lhs.effectiveTier, default: 3]
    let rhsRank = rhs.explicit ? -1 : ranks[rhs.effectiveTier, default: 3]
    if lhsRank != rhsRank { return lhsRank < rhsRank }
    if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
    if lhs.batchSeq != rhs.batchSeq { return lhs.batchSeq < rhs.batchSeq }
    return lhs.worktreeId.uuidString < rhs.worktreeId.uuidString
}

private func admissionCapacityOracle(
    _ rows: [AdmissionOrderRow], policy: AppPolicies.GitRefresh.Policy, pacingIsBlocked: Bool
) -> [UUID] {
    let tierLimits: [GitDemandTier: Int] = [
        .activePane: policy.activePaneMaxConcurrent, .visibleSidebar: policy.visibleSidebarMaxConcurrent,
        .openPane: policy.openPaneMaxConcurrent, .background: policy.backgroundMaxConcurrent,
    ]
    var selected: [UUID] = []
    var tierCounts: [GitDemandTier: Int] = [:]
    var lowerSlots =
        policy.maxConcurrentStatusComputes
        - min(policy.activePaneMaxConcurrent, max(0, policy.maxConcurrentStatusComputes - 1))
    var pacedStartUsed = pacingIsBlocked
    for row in rows.sorted(by: admissionOrderOracle) {
        if selected.count == policy.maxConcurrentStatusComputes { break }
        if row.explicit {
            selected.append(row.worktreeId)
            continue
        }
        let tier = row.effectiveTier
        if tierCounts[tier, default: 0] == tierLimits[tier] { continue }
        if tier != .activePane, lowerSlots == 0 { continue }
        let isPaced = row.retainedTier == nil && row.tier != .activePane
        if isPaced, pacedStartUsed { continue }
        selected.append(row.worktreeId)
        tierCounts[tier, default: 0] += 1
        if tier != .activePane { lowerSlots -= 1 }
        if isPaced { pacedStartUsed = true }
    }
    return selected
}

private func installAdmissionOrderRows(
    _ rows: [AdmissionOrderRow], in projector: isolated GitWorkingDirectoryProjector
) {
    for row in rows {
        projector.rootPathByWorktreeId[row.worktreeId] = row.rootPath
        projector.repoIdByWorktreeId[row.worktreeId] = row.worktreeId
        projector.tierEligibleWorktreeIds.insert(row.worktreeId)
        projector.pendingByWorktreeId[row.worktreeId] = FileChangeset(
            worktreeId: row.worktreeId, repoId: row.worktreeId, rootPath: row.rootPath, paths: ["tracked.txt"],
            timestamp: row.timestamp, batchSeq: row.batchSeq
        )
        projector.refreshAttribution.triggerSourceByWorktreeId[row.worktreeId] = .filesystemChange
        if row.explicit { projector.explicitRefreshWorktreeIds.insert(row.worktreeId) }
        switch row.tier {
        case .activePane: projector.activePaneWorktreeId = row.worktreeId
        case .visibleSidebar: projector.sidebarVisibleWorktreeIds.insert(row.worktreeId)
        case .openPane: projector.activeWorktreeIds.insert(row.worktreeId)
        case .background: break
        }
        if let retainedTier = row.retainedTier {
            projector.capacityRearmedWorktreeIds.insert(row.worktreeId)
            projector.admittedDemandTierByWorktreeId[row.worktreeId] = retainedTier
            projector.refreshAttribution.requestSequenceByWorktreeId[row.worktreeId] = 100
        }
    }
}

private func setAdmissionOrderPacing(_ projector: isolated GitWorkingDirectoryProjector, blocked: Bool) {
    projector.nextAutomaticStartAt = blocked ? .milliseconds(10) : .zero
}

private func removeAdmissionOrderInputs(from projector: isolated GitWorkingDirectoryProjector) {
    projector.pendingByWorktreeId.removeAll()
    projector.explicitRefreshWorktreeIds.removeAll()
    projector.activePaneWorktreeId = nil
    projector.sidebarVisibleWorktreeIds.removeAll()
    projector.activeWorktreeIds.removeAll()
    projector.capacityRearmedWorktreeIds.removeAll()
    projector.admittedDemandTierByWorktreeId.removeAll()
}
