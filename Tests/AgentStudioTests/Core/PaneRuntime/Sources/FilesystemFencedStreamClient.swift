import AgentStudioTestHarness
import Foundation
import Synchronization

@testable import AgentStudioCore

// Preserve the existing transport and owner acknowledgement, optionally holding
// one real fence before it reaches FilesystemActor. Failure terminates transport.
final class FilesystemFencedStreamClient: FSEventStreamClient, Sendable {
    private let base: any FSEventStreamClient
    private let stream: AsyncStream<FSEventIngressItem>
    private let continuation: AsyncStream<FSEventIngressItem>.Continuation?
    private let forwardingTask: Task<Void, Never>?
    private let onAcknowledgement: @Sendable (FSEventActivityProcessingFenceID) -> Void

    init(
        base: any FSEventStreamClient,
        fence: HeldStep<FSEventActivityProcessingFenceID>? = nil,
        onAcknowledgement: @escaping @Sendable (FSEventActivityProcessingFenceID) -> Void = { _ in }
    ) {
        self.base = base
        self.onAcknowledgement = onAcknowledgement
        if let fence {
            let (stream, continuation) = AsyncStream.makeStream(
                of: FSEventIngressItem.self, bufferingPolicy: .unbounded)
            self.stream = stream
            self.continuation = continuation
            forwardingTask = Task {
                for await item in base.events() {
                    if case .activityProcessingFence(let identifier) = item {
                        do { try await fence.arrive(identifier) } catch {
                            base.shutdown()
                            continuation.finish()
                            return
                        }
                    }
                    continuation.yield(item)
                }
                continuation.finish()
            }
        } else {
            stream = base.events()
            continuation = nil
            forwardingTask = nil
        }
    }

    func events() -> AsyncStream<FSEventIngressItem> { stream }
    func consumeOverflowRecoveries() -> [FSEventOverflowRecovery] { base.consumeOverflowRecoveries() }
    func consumeActivityOverflowRecoveries() -> [FSEventActivityOverflowRecovery] {
        base.consumeActivityOverflowRecoveries()
    }
    func consumeCoarseActivityOverflowWorktreeIds() -> Set<UUID> { base.consumeCoarseActivityOverflowWorktreeIds() }
    func register(worktreeId: UUID, repoId: UUID, rootPath: URL) -> FSEventStreamRegistrationOutcome {
        base.register(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
    }
    func unregister(worktreeId: UUID) { base.unregister(worktreeId: worktreeId) }
    func beginActivityShutdown() { base.beginActivityShutdown() }
    func shutdown() {
        base.shutdown()
        forwardingTask?.cancel()
        continuation?.finish()
    }
    func acknowledgeActivityProcessingFence(_ identifier: FSEventActivityProcessingFenceID) {
        base.acknowledgeActivityProcessingFence(identifier)
        onAcknowledgement(identifier)
    }
    func captureActivityBarrier() async -> FSEventActivityBarrier? { await base.captureActivityBarrier() }
    func join() async { await forwardingTask?.value }
}

enum FilesystemCallbackFact: Sendable {
    case submitted(WatchedFolderScanRequest)
    case acknowledged(FSEventActivityProcessingFenceID)
}

enum FilesystemFenceDeliveryFailure: Error { case unavailable }

final class FilesystemCallbackWindow: Sendable {
    private let selected = Mutex<UInt64>(0)
    var identifier: UInt64 { selected.withLock { $0 } }
    func select(_ identifier: UInt64) { selected.withLock { $0 = identifier } }
}
