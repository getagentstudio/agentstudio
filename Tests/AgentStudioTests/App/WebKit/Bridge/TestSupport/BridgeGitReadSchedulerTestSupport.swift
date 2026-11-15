import AgentStudioCore
import AgentStudioTestSupport
import Foundation

@testable import AgentStudioBridge

extension BridgeReviewSourceProviderFactory {
    static func gitProvider(
        repositoryPath: URL?,
        gitReadContext: BridgeGitReadContext?
    ) -> any BridgeReviewSourceProvider {
        gitProvider(
            repositoryPath: repositoryPath,
            gitReadContext: gitReadContext,
            statusPhysicalGate: AgentStudioGitStatusPhysicalGate()
        )
    }
}

final class BridgeGitReadManualDeadlineScheduler: BridgeGitReadDeadlineScheduling, @unchecked Sendable {
    private struct ScheduledDeadline {
        let id: UInt64
        let handler: @Sendable () -> Void
        var isCancelled = false
    }

    private let lock = NSLock()
    private var nextDeadlineId: UInt64 = 1
    private var deadlines: [ScheduledDeadline] = []

    func schedule(
        after _: Duration,
        _ handler: @escaping @Sendable () -> Void
    ) -> BridgeGitReadScheduledDeadline {
        let deadlineId = lock.withLock {
            let deadlineId = nextDeadlineId
            nextDeadlineId &+= 1
            deadlines.append(ScheduledDeadline(id: deadlineId, handler: handler))
            return deadlineId
        }
        return BridgeGitReadScheduledDeadline { [weak self] in
            self?.cancel(deadlineId: deadlineId)
        }
    }

    @discardableResult
    func fireNextActiveDeadline() -> Bool {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let deadlineIndex = deadlines.firstIndex(where: { !$0.isCancelled }) else {
                return nil
            }
            let handler = deadlines[deadlineIndex].handler
            deadlines[deadlineIndex].isCancelled = true
            return handler
        }
        handler?()
        return handler != nil
    }

    var activeDeadlineCount: Int {
        lock.withLock {
            deadlines.count { !$0.isCancelled }
        }
    }

    private func cancel(deadlineId: UInt64) {
        lock.withLock {
            guard let deadlineIndex = deadlines.firstIndex(where: { $0.id == deadlineId }) else {
                return
            }
            deadlines[deadlineIndex].isCancelled = true
        }
    }
}

final class BridgeGitReadSchedulerEventProbe: @unchecked Sendable {
    private struct EventWaiter {
        let kind: BridgeGitReadSchedulerEventKind
        let occurrence: Int
        let continuation: CheckedContinuation<BridgeGitReadSchedulerEvent, Never>
    }

    private let lock = NSLock()
    private var recordedEvents: [BridgeGitReadSchedulerEvent] = []
    private var eventWaiters: [EventWaiter] = []

    var eventSink: BridgeGitReadSchedulerEventSink {
        { [weak self] event in
            self?.record(event)
        }
    }

    var events: [BridgeGitReadSchedulerEvent] {
        lock.withLock { recordedEvents }
    }

    func waitFor(
        _ kind: BridgeGitReadSchedulerEventKind,
        occurrence: Int = 1
    ) async -> BridgeGitReadSchedulerEvent {
        precondition(occurrence > 0)
        if let event = lock.withLock({ matchingEvent(kind: kind, occurrence: occurrence) }) {
            return event
        }
        return await withCheckedContinuation { continuation in
            let immediateEvent = lock.withLock { () -> BridgeGitReadSchedulerEvent? in
                if let event = matchingEvent(kind: kind, occurrence: occurrence) {
                    return event
                }
                eventWaiters.append(
                    EventWaiter(kind: kind, occurrence: occurrence, continuation: continuation)
                )
                return nil
            }
            if let immediateEvent {
                continuation.resume(returning: immediateEvent)
            }
        }
    }

    private func record(_ event: BridgeGitReadSchedulerEvent) {
        let resumptions = lock.withLock {
            () -> [(CheckedContinuation<BridgeGitReadSchedulerEvent, Never>, BridgeGitReadSchedulerEvent)] in
            recordedEvents.append(event)
            var remainingWaiters: [EventWaiter] = []
            var readyWaiters: [(CheckedContinuation<BridgeGitReadSchedulerEvent, Never>, BridgeGitReadSchedulerEvent)] =
                []
            for waiter in eventWaiters {
                if let matchingEvent = matchingEvent(kind: waiter.kind, occurrence: waiter.occurrence) {
                    readyWaiters.append((waiter.continuation, matchingEvent))
                } else {
                    remainingWaiters.append(waiter)
                }
            }
            eventWaiters = remainingWaiters
            return readyWaiters
        }
        for (continuation, matchingEvent) in resumptions {
            continuation.resume(returning: matchingEvent)
        }
    }

    private func matchingEvent(
        kind: BridgeGitReadSchedulerEventKind,
        occurrence: Int
    ) -> BridgeGitReadSchedulerEvent? {
        let matchingEvents = recordedEvents.filter { $0.kind == kind }
        guard matchingEvents.count >= occurrence else { return nil }
        return matchingEvents[occurrence - 1]
    }
}

func makeBridgeGitReadSchedulerTopology(
    metadataSlotCount: Int = 1,
    contentSlotCount: Int = 1,
    maximumQueuedOperationCountPerClass: Int = 8,
    maximumLogicalWaiterCountPerOperation: Int = 4
) -> BridgeGitReadSchedulerTopology {
    precondition(metadataSlotCount > 0)
    precondition(contentSlotCount > 0)
    return BridgeGitReadSchedulerTopology(
        slotsByOperationClass: [
            .reviewMetadata: (1...metadataSlotCount).map {
                BridgeGitReadSlotID(token: "metadata-slot-\($0)")
            },
            .selectedVisibleContent: (1...contentSlotCount).map {
                BridgeGitReadSlotID(token: "content-slot-\($0)")
            },
        ],
        maximumQueuedOperationCountByClass: [
            .reviewMetadata: maximumQueuedOperationCountPerClass,
            .selectedVisibleContent: maximumQueuedOperationCountPerClass,
        ],
        maximumLogicalWaiterCountPerOperation: maximumLogicalWaiterCountPerOperation
    )
}

func makeBridgeGitReadRequest(
    worktree: String,
    operationClass: BridgeGitReadOperationClass = .reviewMetadata,
    key: String,
    freshnessKey: BridgeGitReadFreshnessKey = .unversioned
) -> BridgeGitReadRequest {
    BridgeGitReadRequest(
        worktreeKey: BridgeGitReadWorktreeKey(token: worktree),
        operationClass: operationClass,
        coalescingKey: BridgeGitReadCoalescingKey(token: key),
        freshnessKey: freshnessKey,
        deadline: .seconds(30)
    )
}

func makeBridgeGitReadContext(rootURL: URL) -> BridgeGitReadContext {
    BridgeGitReadContext(
        scheduler: BridgeGitReadScheduler(
            topology: .recoveryBaseline,
            deadlineScheduler: BridgeGitReadManualDeadlineScheduler()
        ),
        worktreeKey: BridgeGitReadWorktreeKey(token: StableKey.fromPath(rootURL))
    )
}
