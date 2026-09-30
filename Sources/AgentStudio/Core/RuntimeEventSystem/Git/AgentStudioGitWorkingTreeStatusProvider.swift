import AgentStudioGit
import AgentStudioInfrastructure
import Dispatch
import Foundation
import os

typealias AgentStudioGitCompleteStatusReader =
    @Sendable (
        URL,
        AgentStudioGit.GitStatusOptions
    ) async throws -> AgentStudioGit.GitCompleteStatusSnapshot
typealias AgentStudioGitStatusFactsReader =
    @Sendable (URL, AgentStudioGit.GitStatusOptions) async throws -> AgentStudioGit.GitStatusFactsSnapshot
typealias AgentStudioGitVerifiedStatusFactsReader =
    @Sendable (
        URL,
        AgentStudioGit.GitStatusOptions,
        AgentStudioGit.GitStatusObservationPlan?
    ) async throws -> AgentStudioGit.GitStatusFactsRead
typealias AgentStudioGitStatusObservationPlanReader =
    @Sendable (URL) async throws -> AgentStudioGit.GitStatusObservationPlan
typealias AgentStudioGitLineDetailReader =
    @Sendable (URL) async throws -> AgentStudioGit.GitStatusLineCountDetail

package struct AgentStudioGitWorkingTreeStatusProvider: GitExactCleanStatusProviding {
    private static let logger = Logger(subsystem: "com.agentstudio", category: "AgentStudioGitWorkingTree")

    private let statusReader: AgentStudioGitCompleteStatusReader
    private let statusFactsReader: AgentStudioGitStatusFactsReader
    private let verifiedStatusFactsReader: AgentStudioGitVerifiedStatusFactsReader?
    private let statusObservationPlanReader: AgentStudioGitStatusObservationPlanReader?
    private let lineDetailReader: AgentStudioGitLineDetailReader
    private let continuityWitness: (any GitCleanContinuityWitness)?
    private let slowThreshold: Duration
    private let slowObservationScheduler: any AgentStudioGitStatusSlowObservationScheduler
    private let physicalGate: AgentStudioGitStatusPhysicalGate

    package init(
        client: any AgentStudioGit.AgentStudioGitLocalClient = AgentStudioGit.LibGit2AgentStudioGitLocalClient(),
        physicalGate: AgentStudioGitStatusPhysicalGate,
        continuityWitness: (any GitCleanContinuityWitness)? = nil,
        slowThreshold: Duration = AppPolicies.GitRefresh.defaultStatusReadTimeout
    ) {
        self.init(
            slowThreshold: slowThreshold,
            slowObservationScheduler: DispatchGitStatusSlowObservationScheduler(),
            physicalGate: physicalGate,
            continuityWitness: continuityWitness,
            statusObservationPlanReader: { worktreePath in
                try await client.statusObservationPlan(for: worktreePath)
            },
            verifiedStatusFactsReader: { worktreePath, options, observationPlan in
                try await client.statusFacts(
                    for: worktreePath,
                    options: options,
                    observationPlan: observationPlan
                )
            },
            statusFactsReader: { worktreePath, options in
                try await client.statusFacts(for: worktreePath, options: options).facts
            },
            lineDetailReader: { worktreePath in
                try await client.exactLineCountDetail(for: worktreePath)
            },
            statusReader: { worktreePath, options in
                try await client.completeStatus(for: worktreePath, options: options)
            }
        )
    }

    init(
        slowThreshold: Duration = AppPolicies.GitRefresh.defaultStatusReadTimeout,
        slowObservationScheduler: any AgentStudioGitStatusSlowObservationScheduler =
            DispatchGitStatusSlowObservationScheduler(),
        physicalGate: AgentStudioGitStatusPhysicalGate = AgentStudioGitStatusPhysicalGate(),
        continuityWitness: (any GitCleanContinuityWitness)? = nil,
        statusObservationPlanReader: AgentStudioGitStatusObservationPlanReader? = nil,
        verifiedStatusFactsReader: AgentStudioGitVerifiedStatusFactsReader? = nil,
        statusFactsReader: AgentStudioGitStatusFactsReader? = nil,
        lineDetailReader: AgentStudioGitLineDetailReader? = nil,
        statusReader: @escaping AgentStudioGitCompleteStatusReader
    ) {
        self.statusReader = statusReader
        self.continuityWitness = continuityWitness
        self.statusObservationPlanReader = statusObservationPlanReader
        self.verifiedStatusFactsReader = verifiedStatusFactsReader
        self.statusFactsReader =
            statusFactsReader ?? { rootPath, options in
                try await statusReader(rootPath, options).facts
            }
        self.lineDetailReader =
            lineDetailReader ?? { rootPath in
                try await statusReader(rootPath, AgentStudioGit.GitStatusOptions()).lineCountDetail
            }
        self.slowThreshold = slowThreshold
        self.slowObservationScheduler = slowObservationScheduler
        self.physicalGate = physicalGate
    }

    package func statusResult(for rootPath: URL, pathspecs: [String]?) async -> GitWorkingTreeStatusResult {
        await Self.computeStatusResult(
            rootPath: rootPath,
            pathspecs: pathspecs,
            slowThreshold: slowThreshold,
            slowObservationScheduler: slowObservationScheduler,
            physicalGate: physicalGate,
            statusReader: statusReader
        )
    }

    package func statusFactsResult(
        for rootPath: URL,
        pathspecs: [String]?
    ) async -> GitWorkingTreeStatusFactsResult {
        do {
            let snapshot = try await readPhysical(rootPath: rootPath) {
                try await statusFactsReader(
                    rootPath,
                    AgentStudioGit.GitStatusOptions(
                        includeIgnored: false,
                        includeUntracked: true,
                        pathspecs: pathspecs
                    )
                )
            }
            guard !Task.isCancelled else {
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .cancelled))
            }
            return .available(Self.mapFacts(snapshot, isPathspecScoped: pathspecs != nil))
        } catch {
            return .unavailable(Self.mapUnavailable(error))
        }
    }

    package func exactCleanStatusFactsResult(
        for worktreeId: UUID,
        rootPath: URL
    ) async -> GitExactCleanStatusFactsResult {
        guard let continuityWitness,
            let statusObservationPlanReader,
            let verifiedStatusFactsReader
        else {
            return Self.mapOrdinaryResult(await statusFactsResult(for: rootPath, pathspecs: nil))
        }

        do {
            let result = try await readPhysical(rootPath: rootPath) {
                let observationPlan: AgentStudioGit.GitStatusObservationPlan?
                do {
                    observationPlan = try await statusObservationPlanReader(rootPath)
                } catch {
                    observationPlan = nil
                }
                let barrier: GitCleanContinuityBarrier?
                if let observationPlan {
                    let prepareOutcome = await continuityWitness.prepare(
                        worktreeId: worktreeId,
                        rootPath: rootPath,
                        observationPlan: observationPlan
                    )
                    barrier = prepareOutcome.barrier
                } else {
                    barrier = nil
                }
                let read = try await verifiedStatusFactsReader(
                    rootPath,
                    AgentStudioGit.GitStatusOptions(
                        includeIgnored: false,
                        includeUntracked: true,
                        pathspecs: nil
                    ),
                    observationPlan
                )
                guard let observationPlan,
                    let barrier,
                    read.exactCleanBaseline?.observationIdentity == observationPlan.identity
                else {
                    return GitExactCleanStatusFactsResult.available(
                        Self.mapFacts(read.facts, isPathspecScoped: false)
                    )
                }
                switch await continuityWitness.commit(barrier) {
                case .requiresExact(let reason):
                    return GitExactCleanStatusFactsResult.requiresExact(reason)
                case .authoritative(let authority):
                    return GitExactCleanStatusFactsResult.available(
                        Self.mapFacts(
                            read.facts,
                            isPathspecScoped: false,
                            exactCleanAuthority: authority
                        )
                    )
                }
            }
            guard !Task.isCancelled else {
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .cancelled))
            }
            return result
        } catch {
            return .unavailable(Self.mapUnavailable(error))
        }
    }

    nonisolated private static func mapOrdinaryResult(
        _ result: GitWorkingTreeStatusFactsResult
    ) -> GitExactCleanStatusFactsResult {
        switch result {
        case .available(let facts): .available(facts)
        case .unavailable(let unavailable): .unavailable(unavailable)
        }
    }

    package func renewExactCleanAuthority(
        _ authority: GitCleanContinuityAuthority
    ) async -> GitExactCleanRenewalResult {
        guard let continuityWitness else {
            return .requiresExact(.unsupportedObservation)
        }
        switch await continuityWitness.renew(authority) {
        case .authoritative(let renewed):
            return .renewed(renewed)
        case .requiresExact(let reason):
            return .requiresExact(reason)
        }
    }

    package func retireExactCleanAuthority(worktreeId: UUID, rootPath: URL) {
        continuityWitness?.retire(worktreeId: worktreeId, rootPath: rootPath)
    }

    package func lineDetailResult(for rootPath: URL) async -> GitWorkingTreeLineDetailResult {
        do {
            let detail = try await readPhysical(rootPath: rootPath) {
                try await lineDetailReader(rootPath)
            }
            guard !Task.isCancelled else {
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .cancelled))
            }
            return .available(
                GitWorkingTreeLineDetail(
                    linesAdded: detail.linesAdded,
                    linesDeleted: detail.linesDeleted
                )
            )
        } catch {
            return .unavailable(Self.mapUnavailable(error))
        }
    }

    package func physicalCompletionGeneration() -> UInt64? {
        physicalGate.currentCompletionGeneration()
    }

    package func waitForPhysicalCompletion(after generation: UInt64) async {
        await physicalGate.waitForCompletion(after: generation)
    }

    private func readPhysical<ReadValue: Sendable>(
        rootPath: URL,
        operation: @Sendable () async throws -> ReadValue
    ) async throws -> ReadValue {
        let slowObservation = slowObservationScheduler.scheduleObservation(after: slowThreshold) {
            Self.logger.warning("AgentStudioGit status remained active past the slow threshold")
        }
        defer { slowObservation.cancel() }
        return try await physicalGate.withPhysicalRead(for: rootPath, operation: operation)
    }

    @concurrent
    nonisolated private static func computeStatusResult(
        rootPath: URL,
        pathspecs: [String]?,
        slowThreshold: Duration,
        slowObservationScheduler: any AgentStudioGitStatusSlowObservationScheduler,
        physicalGate: AgentStudioGitStatusPhysicalGate,
        statusReader: @escaping AgentStudioGitCompleteStatusReader
    ) async -> GitWorkingTreeStatusResult {
        do {
            let slowObservation = slowObservationScheduler.scheduleObservation(after: slowThreshold) {
                logger.warning("AgentStudioGit status remained active past the slow threshold")
            }
            defer { slowObservation.cancel() }
            let snapshot = try await physicalGate.withPhysicalRead(for: rootPath) {
                try await statusReader(
                    rootPath,
                    AgentStudioGit.GitStatusOptions(
                        includeIgnored: false,
                        includeUntracked: true,
                        pathspecs: pathspecs
                    )
                )
            }
            guard !Task.isCancelled else {
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .cancelled))
            }
            return .available(map(snapshot, isPathspecScoped: pathspecs != nil))
        } catch AgentStudioGitStatusPhysicalGateError.sameRootAlreadyInFlight {
            return .unavailable(GitWorkingTreeStatusUnavailable(reason: .readAlreadyInFlight))
        } catch AgentStudioGitStatusPhysicalGateError.capacityExceeded {
            return .unavailable(GitWorkingTreeStatusUnavailable(reason: .readCapacityExceeded))
        } catch is CancellationError {
            return .unavailable(GitWorkingTreeStatusUnavailable(reason: .cancelled))
        } catch {
            logger.error(
                """
                AgentStudioGit status failed for \(rootPath.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
            return .unavailable(GitWorkingTreeStatusUnavailable(reason: .sdkError))
        }
    }

    nonisolated fileprivate static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let (secondsNanoseconds, multiplicationOverflow) =
            components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let attosecondNanoseconds = components.attoseconds / 1_000_000_000
        let (totalNanoseconds, additionOverflow) =
            secondsNanoseconds.addingReportingOverflow(attosecondNanoseconds)

        guard !multiplicationOverflow, !additionOverflow else {
            return .seconds(Int.max)
        }
        guard totalNanoseconds > 0 else {
            return .nanoseconds(0)
        }
        guard totalNanoseconds <= Int64(Int.max) else {
            return .seconds(Int.max)
        }
        return .nanoseconds(Int(totalNanoseconds))
    }

    nonisolated private static func map(
        _ snapshot: AgentStudioGit.GitCompleteStatusSnapshot,
        isPathspecScoped: Bool
    ) -> GitWorkingTreeStatus {
        let facts = snapshot.facts
        return GitWorkingTreeStatus(
            summary: mapSummary(
                facts.summary,
                lineCountDetail: snapshot.lineCountDetail,
                headKind: facts.head.kind
            ),
            branch: mapBranch(facts.head),
            originResolution: mapOrigin(facts.originResolution),
            entries: facts.entries.map(mapEntry),
            containsPathIdentityAmbiguity: isPathspecScoped
                && facts.entries.contains(where: hasStandalonePathIdentityChange)
        )
    }

    nonisolated private static func mapFacts(
        _ facts: AgentStudioGit.GitStatusFactsSnapshot,
        isPathspecScoped: Bool,
        exactCleanAuthority: GitCleanContinuityAuthority? = nil
    ) -> GitWorkingTreeStatusFacts {
        let detail = AgentStudioGit.GitStatusLineCountDetail(
            repositoryRoot: facts.repositoryRoot,
            worktreePath: facts.worktreePath,
            generatedAtUnixMilliseconds: facts.generatedAtUnixMilliseconds,
            linesAdded: 0,
            linesDeleted: 0
        )
        return GitWorkingTreeStatusFacts(
            status: GitWorkingTreeStatus(
                summary: mapSummary(facts.summary, lineCountDetail: detail, headKind: facts.head.kind),
                branch: mapBranch(facts.head),
                originResolution: mapOrigin(facts.originResolution),
                entries: facts.entries.map(mapEntry),
                containsPathIdentityAmbiguity: isPathspecScoped
                    && facts.entries.contains(where: hasStandalonePathIdentityChange)
            ),
            exactCleanAuthority: exactCleanAuthority
        )
    }

    nonisolated private static func mapUnavailable(_ error: Error) -> GitWorkingTreeStatusUnavailable {
        let reason: GitWorkingTreeStatusUnavailableReason
        switch error {
        case AgentStudioGitStatusPhysicalGateError.sameRootAlreadyInFlight:
            reason = .readAlreadyInFlight
        case AgentStudioGitStatusPhysicalGateError.capacityExceeded:
            reason = .readCapacityExceeded
        case is CancellationError:
            reason = .cancelled
        default:
            reason = .sdkError
        }
        return GitWorkingTreeStatusUnavailable(reason: reason)
    }

    nonisolated private static func hasStandalonePathIdentityChange(
        _ entry: AgentStudioGit.GitStatusEntry
    ) -> Bool {
        if let previousPath = entry.previousPath, !previousPath.isEmpty {
            return false
        }
        return entry.untracked
            || isStandalonePathIdentityState(entry.indexState)
            || isStandalonePathIdentityState(entry.worktreeState)
    }

    nonisolated private static func isStandalonePathIdentityState(
        _ state: AgentStudioGit.GitStatusState?
    ) -> Bool {
        switch state {
        case .added?, .deleted?:
            true
        case .modified?, .renamed?, .copied?, .typeChanged?, .unmerged?, nil:
            false
        }
    }

    nonisolated private static func mapEntry(
        _ entry: AgentStudioGit.GitStatusEntry
    ) -> GitWorkingTreeStatusEntry {
        GitWorkingTreeStatusEntry(
            path: entry.path,
            previousPath: entry.previousPath,
            hasStagedChange: entry.indexState != nil,
            hasUnstagedChange: entry.worktreeState != nil,
            isUntracked: entry.untracked,
            isRename: entry.indexState == .renamed || entry.worktreeState == .renamed
        )
    }

    nonisolated private static func mapSummary(
        _ summary: AgentStudioGit.GitStatusFactSummary,
        lineCountDetail: AgentStudioGit.GitStatusLineCountDetail,
        headKind: AgentStudioGit.GitHeadKind
    ) -> GitWorkingTreeSummary {
        let syncCounts = mapSyncCounts(summary, headKind: headKind)
        return GitWorkingTreeSummary(
            changed: summary.unstagedFileCount,
            staged: summary.stagedFileCount,
            untracked: summary.untrackedFileCount,
            linesAdded: lineCountDetail.linesAdded,
            linesDeleted: lineCountDetail.linesDeleted,
            aheadCount: syncCounts.aheadCount,
            behindCount: syncCounts.behindCount,
            hasUpstream: syncCounts.hasUpstream
        )
    }

    nonisolated private static func mapSyncCounts(
        _ summary: AgentStudioGit.GitStatusFactSummary,
        headKind: AgentStudioGit.GitHeadKind
    ) -> (aheadCount: Int?, behindCount: Int?, hasUpstream: Bool?) {
        guard headKind == .branch else {
            return (aheadCount: nil, behindCount: nil, hasUpstream: nil)
        }
        guard summary.hasUpstream else {
            return (aheadCount: nil, behindCount: nil, hasUpstream: false)
        }
        if summary.aheadCount == 0, summary.behindCount == 0 {
            return (aheadCount: 0, behindCount: 0, hasUpstream: true)
        }
        return (
            aheadCount: summary.aheadCount > 0 ? summary.aheadCount : nil,
            behindCount: summary.behindCount > 0 ? summary.behindCount : nil,
            hasUpstream: true
        )
    }

    nonisolated private static func mapBranch(_ head: AgentStudioGit.GitHeadSnapshot) -> String? {
        guard head.kind == .branch else { return nil }
        return head.shortName
    }

    nonisolated private static func mapOrigin(
        _ originResolution: AgentStudioGit.GitOriginResolution
    ) -> GitOriginResolution {
        switch originResolution {
        case .awaitingResolution:
            .awaitingResolution
        case .confirmedAbsent:
            .confirmedAbsent
        case .resolved(let remote):
            .resolved(remote.rawURL)
        }
    }
}

struct AgentStudioGitStatusPhysicalReadKey: Hashable, Sendable {
    private let path: String

    init(_ rootPath: URL) {
        self.path = rootPath.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

package enum AgentStudioGitStatusPhysicalGateError: Error, Equatable, Sendable {
    case sameRootAlreadyInFlight
    case capacityExceeded
}

package final class AgentStudioGitStatusPhysicalGate: @unchecked Sendable {
    private let lock = NSLock()
    private let maxActiveReadCount: Int
    private var activeReadKeys: Set<AgentStudioGitStatusPhysicalReadKey> = []
    private var inactiveWaiters: [AgentStudioGitStatusPhysicalReadKey: [CheckedContinuation<Void, Never>]] = [:]
    private var completionGeneration: UInt64 = 0
    private var nextCompletionWaiterId: UInt64 = 0
    private var completionWaiters: [UInt64: (generation: UInt64, continuation: CheckedContinuation<Void, Never>)] = [:]

    package init(maxActiveReadCount: Int = AppPolicies.GitRefresh.defaultDetachedStatusReadLimit) {
        precondition(maxActiveReadCount > 0)
        self.maxActiveReadCount = maxActiveReadCount
    }

    package func withPhysicalRead<ReturnValue: Sendable>(
        for rootPath: URL,
        operation: @Sendable () async throws -> ReturnValue
    ) async throws -> ReturnValue {
        let key = AgentStudioGitStatusPhysicalReadKey(rootPath)
        try start(key)
        defer { finish(key) }
        return try await operation()
    }

    private func start(_ key: AgentStudioGitStatusPhysicalReadKey) throws {
        lock.lock()
        if activeReadKeys.contains(key) {
            lock.unlock()
            throw AgentStudioGitStatusPhysicalGateError.sameRootAlreadyInFlight
        }
        guard activeReadKeys.count < maxActiveReadCount else {
            lock.unlock()
            throw AgentStudioGitStatusPhysicalGateError.capacityExceeded
        }
        activeReadKeys.insert(key)
        lock.unlock()
    }

    private func finish(_ key: AgentStudioGitStatusPhysicalReadKey) {
        let waiters: [CheckedContinuation<Void, Never>]
        let completionWaitersToResume: [CheckedContinuation<Void, Never>]
        lock.lock()
        activeReadKeys.remove(key)
        waiters = inactiveWaiters.removeValue(forKey: key) ?? []
        completionGeneration &+= 1
        completionWaitersToResume =
            completionWaiters.values
            .filter { $0.generation < completionGeneration }
            .map(\.continuation)
        completionWaiters = completionWaiters.filter { $0.value.generation >= completionGeneration }
        lock.unlock()

        for waiter in waiters + completionWaitersToResume {
            waiter.resume()
        }
    }

    package func currentCompletionGeneration() -> UInt64 {
        lock.withLock { completionGeneration }
    }

    package func waitForCompletion(after generation: UInt64) async {
        let waiterId = lock.withLock {
            nextCompletionWaiterId &+= 1
            return nextCompletionWaiterId
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled, completionGeneration <= generation else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                completionWaiters[waiterId] = (generation: generation, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            cancelCompletionWaiter(waiterId)
        }
    }

    private func cancelCompletionWaiter(_ waiterId: UInt64) {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        continuation = completionWaiters.removeValue(forKey: waiterId)?.continuation
        lock.unlock()
        continuation?.resume()
    }

    func waitUntilInactive(_ rootPath: URL) async {
        let key = AgentStudioGitStatusPhysicalReadKey(rootPath)
        await withCheckedContinuation { continuation in
            lock.lock()
            guard activeReadKeys.contains(key) else {
                lock.unlock()
                continuation.resume()
                return
            }
            inactiveWaiters[key, default: []].append(continuation)
            lock.unlock()
        }
    }
}

protocol AgentStudioGitStatusSlowObservationScheduler: Sendable {
    func scheduleObservation(
        after threshold: Duration,
        _ handler: @escaping @Sendable () -> Void
    ) -> AgentStudioGitScheduledSlowObservation
}

struct AgentStudioGitScheduledSlowObservation: Sendable {
    private let box: AgentStudioGitScheduledSlowObservationBox

    init(cancel: @escaping () -> Void) {
        box = AgentStudioGitScheduledSlowObservationBox(cancel: cancel)
    }

    func cancel() {
        box.cancel()
    }
}

private final class AgentStudioGitScheduledSlowObservationBox: @unchecked Sendable {
    private let cancelHandler: () -> Void

    init(cancel: @escaping () -> Void) {
        cancelHandler = cancel
    }

    func cancel() {
        cancelHandler()
    }
}

struct DispatchGitStatusSlowObservationScheduler: AgentStudioGitStatusSlowObservationScheduler {
    private static let observationQueue = DispatchQueue(
        label: "com.agentstudio.git-status-slow-observation",
        qos: .userInitiated
    )

    func scheduleObservation(
        after threshold: Duration,
        _ handler: @escaping @Sendable () -> Void
    ) -> AgentStudioGitScheduledSlowObservation {
        let workItem = DispatchWorkItem(block: handler)
        Self.observationQueue.asyncAfter(
            deadline: .now() + AgentStudioGitWorkingTreeStatusProvider.dispatchInterval(for: threshold),
            execute: workItem
        )
        return AgentStudioGitScheduledSlowObservation {
            workItem.cancel()
        }
    }
}
