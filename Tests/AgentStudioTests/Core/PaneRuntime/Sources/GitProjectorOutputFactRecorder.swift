import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization

@testable import AgentStudioCore

private enum GitOutputScope: Hashable, Sendable {
    case snapshot(UUID)
    case status(UUID)
    case branch(UUID)
    case origin(UUID)
    case subscription
}

/// Real bus facts are applied by the synchronous classifier before recorder insertion.
/// The only waiting mechanism is the canonical EventBus adapter and FactRecorder.
final class GitProjectorOutputFactRecorder: Sendable {
    private struct OutputHistory: Sendable {
        var snapshots: [UUID: [GitWorkingTreeSnapshot]] = [:]
        var statuses: [UUID: [GitStatusOutcome]] = [:]
        var branches: [UUID: [(String, String)]] = [:]
        var origins: [UUID: [(String, String)]] = [:]
        var consumedCounts: [GitOutputScope: Int] = [:]

        mutating func apply(_ envelope: RuntimeEnvelope) -> (GitOutputScope, GitWorkingDirectoryEvent)? {
            guard case .worktree(let worktree) = envelope,
                case .gitWorkingDirectory(let event) = worktree.event
            else { return nil }
            switch event {
            case .snapshotChanged(let snapshot):
                snapshots[snapshot.worktreeId, default: []].append(snapshot)
                return (.snapshot(snapshot.worktreeId), event)
            case .statusOutcome(let status):
                statuses[status.worktreeId, default: []].append(status.outcome)
                return (.status(status.worktreeId), event)
            case .branchChanged(let worktreeId, _, let from, let to):
                branches[worktreeId, default: []].append((from, to))
                return (.branch(worktreeId), event)
            case .originChanged(let repoId, let from, let to):
                origins[repoId, default: []].append((from, to))
                return (.origin(repoId), event)
            case .originUnavailable(let repoId):
                origins[repoId, default: []].append(("", ""))
                return (.origin(repoId), event)
            case .worktreeDiscovered, .worktreeRemoved, .diffAvailable:
                return nil
            }
        }
    }

    private let history = Mutex(OutputHistory())
    private let recorder = Mutex<FactRecorder<GitOutputScope, GitWorkingDirectoryEvent>?>(nil)

    func start(on bus: EventBus<RuntimeEnvelope>) async {
        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: "projector output facts")
        let facts = EventBusFactSource.attach(
            subscription: subscription,
            vocabulary: FactVocabulary<GitOutputScope, GitWorkingDirectoryEvent>(
                describeScope: { String(describing: $0) },
                describeFact: { String(describing: $0) },
                isClosing: { _, _ in false }
            ),
            replayWasTruncated: {
                if case .possiblyTruncated = subscription.replayStatus { return true }
                return false
            },
            classify: { [self] envelope in history.withLock { $0.apply(envelope) } }
        )
        recorder.withLock { $0 = facts }
    }

    func finish() async throws {
        try await attachedRecorder.finish()
    }

    /// Capture the finite accepted boundary after the projector's correlated close.
    /// Unlike collector catch-up, later posts cannot move this boundary.
    func markAcceptedOutputs() async {
        _ = await attachedRecorder.mark(.subscription)
    }

    func expectSnapshots(
        for worktreeId: UUID, through count: Int,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> [GitWorkingTreeSnapshot] {
        try await consume(
            scope: .snapshot(worktreeId), through: count,
            fileID: fileID, line: line, function: function
        )
        return history.withLock { Array($0.snapshots[worktreeId, default: []].prefix(count)) }
    }

    func expectNextSnapshot(
        for worktreeId: UUID, where matches: @escaping @Sendable (GitWorkingTreeSnapshot) -> Bool,
        _ description: String,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> [GitWorkingTreeSnapshot] {
        let scope = GitOutputScope.snapshot(worktreeId)
        _ = try await attachedRecorder.expectNext(
            in: scope,
            where: {
                if case .snapshotChanged(let snapshot) = $0 { return matches(snapshot) }
                return false
            }, description, fileID: fileID, line: line, function: function
        )
        return history.withLock {
            $0.consumedCounts[scope, default: 0] += 1
            return Array($0.snapshots[worktreeId, default: []].prefix($0.consumedCounts[scope, default: 0]))
        }
    }

    func expectStatusOutcomes(
        for worktreeId: UUID, through count: Int,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> [GitStatusOutcome] {
        try await consume(
            scope: .status(worktreeId), through: count, fileID: fileID, line: line, function: function
        )
        return history.withLock { Array($0.statuses[worktreeId, default: []].prefix(count)) }
    }

    func expectBranchEvents(
        for worktreeId: UUID, through count: Int,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> [(String, String)] {
        try await consume(
            scope: .branch(worktreeId), through: count, fileID: fileID, line: line, function: function
        )
        return history.withLock { Array($0.branches[worktreeId, default: []].prefix(count)) }
    }

    func expectOriginEvents(
        for repoId: UUID, through count: Int,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> [(String, String)] {
        try await consume(
            scope: .origin(repoId), through: count, fileID: fileID, line: line, function: function
        )
        return history.withLock { Array($0.origins[repoId, default: []].prefix(count)) }
    }

    func snapshotCount(for worktreeId: UUID) async -> Int {
        history.withLock { $0.snapshots[worktreeId]?.count ?? 0 }
    }

    func latestSnapshot(for worktreeId: UUID) async -> GitWorkingTreeSnapshot? {
        history.withLock { $0.snapshots[worktreeId]?.last }
    }

    func statusOutcomeCount(for worktreeId: UUID) async -> Int {
        history.withLock { $0.statuses[worktreeId]?.count ?? 0 }
    }

    func branchEventCount(for worktreeId: UUID) async -> Int {
        history.withLock { $0.branches[worktreeId]?.count ?? 0 }
    }

    func originEventCount(for repoId: UUID) async -> Int {
        history.withLock { $0.origins[repoId]?.count ?? 0 }
    }

    func latestOriginEvent(for repoId: UUID) async -> (String, String)? {
        history.withLock { $0.origins[repoId]?.last }
    }

    private var attachedRecorder: FactRecorder<GitOutputScope, GitWorkingDirectoryEvent> {
        recorder.withLock {
            guard let recorder = $0 else { preconditionFailure("Attach output facts before stimulus") }
            return recorder
        }
    }

    private func consume(
        scope: GitOutputScope, through count: Int,
        fileID: String, line: Int, function: String
    ) async throws {
        while history.withLock({ $0.consumedCounts[scope, default: 0] < count }) {
            _ = try await attachedRecorder.expectNext(
                in: scope, where: { _ in true }, "output fact \(scope) through \(count)",
                fileID: fileID, line: line, function: function
            )
            history.withLock { $0.consumedCounts[scope, default: 0] += 1 }
        }
    }
}
