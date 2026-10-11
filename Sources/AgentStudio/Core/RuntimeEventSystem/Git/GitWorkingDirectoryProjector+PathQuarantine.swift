import AgentStudioInfrastructure
import Foundation

/// Dead-path quarantine: a registered worktree whose root directory has vanished
/// from disk keeps failing its git status compute (`sdk_error`) forever, burning
/// the global concurrent-status budget that live worktrees need. Instead of
/// deleting such a worktree, the projector quarantines it: the worktree is skipped
/// at admission and at periodic re-enqueue, then one bounded background deadline
/// checks whether the path returned. A file-change or registration/context change
/// may still re-arm it sooner. Split from the projector actor body to keep it under
/// the type/file length caps.
extension GitWorkingDirectoryProjector {
    /// Live filesystem probe wired at the production composition root and reused by
    /// quarantine tests against real temp directories. The projector's own default
    /// is permissive so unit tests that register synthetic paths stay unaffected.
    package static let liveRootPathProbe: @Sendable (URL) -> Bool = { rootPath in
        FileManager.default.fileExists(atPath: rootPath.path)
    }

    /// Checks one worktree only after projector task capacity, demand, tier
    /// capacity, and process pacing have otherwise selected it. Shared physical
    /// capacity is acquired later by the provider. Successful status acceptance
    /// retains this exact-root validation for ordinary re-enqueue; capacity-only
    /// rejection retains it for retry. Unsuccessful drains and lifecycle changes
    /// invalidate it. A missing root is quarantined without consuming the
    /// projector slot so selection can continue.
    func admitPendingWorktreeAfterPathCheck(worktreeId: UUID) -> Bool {
        guard let rootPath = pendingByWorktreeId[worktreeId]?.rootPath else { return false }
        guard !quarantinedWorktreeIds.contains(worktreeId) else { return false }
        if validatedRootPathByWorktreeId[worktreeId] == rootPath {
            return true
        }
        guard pathExistenceProbe(rootPath) else {
            quarantineWorktreePath(worktreeId: worktreeId)
            return false
        }
        validatedRootPathByWorktreeId[worktreeId] = rootPath
        return true
    }

    func clearValidatedRootPath(worktreeId: UUID) {
        validatedRootPathByWorktreeId.removeValue(forKey: worktreeId)
    }

    /// Marks a worktree quarantined: drops its pending refresh so the pending map
    /// does not retain dead entries, keeps one bounded self-heal deadline, and emits
    /// a single open fact.
    private func quarantineWorktreePath(worktreeId: UUID) {
        guard quarantinedWorktreeIds.insert(worktreeId).inserted else { return }
        capacityRearmedWorktreeIds.remove(worktreeId)
        clearValidatedRootPath(worktreeId: worktreeId)
        pendingByWorktreeId.removeValue(forKey: worktreeId)
        clearImmediateRefreshIntent(worktreeId: worktreeId)
        clearRequiredIntent(worktreeId: worktreeId)
        scheduleQuarantineRecheck(worktreeId: worktreeId)
        emitPathQuarantineTelemetry(worktreeId: worktreeId, quarantined: true)
        rescheduleDeadlineTask()
        if let factSink {
            let episode = quarantineFactEpisodeByWorktreeId[worktreeId, default: 0] + 1
            quarantineFactEpisodeByWorktreeId[worktreeId] = episode
            factSink(.quarantine(worktreeId: worktreeId, episode: episode), .quarantineOpened)
        }
    }

    /// Rechecks one quarantined root at its existing automatic deadline. A missing
    /// root retains quarantine and one successor deadline; a restored root closes
    /// quarantine and may proceed through ordinary refresh preparation/admission.
    func admitAutomaticRefreshAfterQuarantine(worktreeId: UUID) -> Bool {
        guard quarantinedWorktreeIds.contains(worktreeId) else { return true }
        guard let context = registeredContext(for: worktreeId) else { return false }
        guard pathExistenceProbe(context.rootPath) else {
            scheduleQuarantineRecheck(worktreeId: worktreeId)
            return false
        }
        clearQuarantineEmittingClose(worktreeId: worktreeId)
        return true
    }

    /// Event-driven re-arm gate for a file-change on a possibly-quarantined
    /// worktree. Returns whether the change should proceed into the pending map:
    /// - not quarantined: `true` (normal flow, no stat call);
    /// - quarantined and path still missing: `false` (dropped; stays quarantined,
    ///   no telemetry so a persistently-dead path emits exactly one open fact);
    /// - quarantined and path returned: clears the mark, emits the close fact, and
    ///   returns `true` so the worktree recomputes.
    func admitFileChangeAfterQuarantine(worktreeId: UUID, rootPath: URL) -> Bool {
        guard quarantinedWorktreeIds.contains(worktreeId) else { return true }
        guard pathExistenceProbe(rootPath) else { return false }
        clearQuarantineEmittingClose(worktreeId: worktreeId)
        return true
    }

    /// Clears a quarantine mark and emits the close fact. Used on the file-change
    /// re-arm path where the path was confirmed to have returned.
    private func clearQuarantineEmittingClose(worktreeId: UUID) {
        guard quarantinedWorktreeIds.remove(worktreeId) != nil else { return }
        emitPathQuarantineTelemetry(worktreeId: worktreeId, quarantined: false)
        if let factSink, let episode = quarantineFactEpisodeByWorktreeId[worktreeId] {
            factSink(.quarantine(worktreeId: worktreeId, episode: episode), .quarantineClosed)
        }
    }

    /// Silently drops a quarantine mark for lifecycle transitions (unregistration,
    /// context change) where the old path is no longer the worktree's identity, so
    /// no close fact is warranted. Mirrors the non-emitting `clearStatusBackoffState`.
    func clearQuarantineState(worktreeId: UUID) {
        guard quarantinedWorktreeIds.remove(worktreeId) != nil else { return }
        if let factSink, let episode = quarantineFactEpisodeByWorktreeId[worktreeId] {
            factSink(.quarantine(worktreeId: worktreeId, episode: episode), .quarantineClosed)
        }
    }

    private func scheduleQuarantineRecheck(worktreeId: UUID) {
        guard isAutomaticEligible(worktreeId: worktreeId) else {
            automaticRefreshDeadlineByWorktreeId.removeValue(forKey: worktreeId)
            cancelDeadlineFact(worktreeId: worktreeId, sourceKind: .automatic)
            return
        }
        setRefreshDeadline(
            deadlineClock.now + refreshPolicy.backgroundCadence,
            kind: .automatic,
            worktreeId: worktreeId
        )
    }

    private func emitPathQuarantineTelemetry(worktreeId: UUID, quarantined: Bool) {
        guard let performanceTraceRecorder else { return }
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.worktree.id": .string(worktreeId.uuidString),
            "agentstudio.performance.git.path_quarantined": .bool(quarantined),
            "agentstudio.performance.git.quarantined.count": .int(quarantinedWorktreeIds.count),
            "agentstudio.performance.git.pending.count": .int(pendingByWorktreeId.count),
            "agentstudio.performance.git.running.count": .int(worktreeTasks.count),
        ]
        if quarantined {
            attributes["agentstudio.performance.git.path_quarantine.reason"] = .string("path_missing")
        }
        performanceTraceRecorder.record(.gitPathQuarantine, attributes: attributes)
    }
}
