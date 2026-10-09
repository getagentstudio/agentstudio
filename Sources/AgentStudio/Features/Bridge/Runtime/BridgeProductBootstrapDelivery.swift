import AgentStudioInfrastructure
import Foundation
import os.log

private let bootstrapPhysicalDeliveryLogger = Logger(subsystem: "com.agentstudio", category: "BridgeProductBootstrap")

/// Settles the logical reply independently of a WebKit call that may ignore cancellation.
/// The physical reply retains only its captured request; it cannot re-enter installation effects.
final class BridgeProductBootstrapDelivery: @unchecked Sendable {
    enum Outcome: Sendable {
        case delivered
        case failed(any Error)
        case deadlineExpired
        case admissionClosed
        case superseded
    }

    private struct SettlementCleanup {
        let physicalReply: Task<Void, Never>?
        let deadlineTask: Task<Void, Never>?
        let closeObservation: BridgeProductAdmissionCloseObservation?
        let hasDetachedPhysicalReply: Bool
    }

    let requestId: String
    private let lock = NSLock()
    private let outcomes: AsyncStream<Outcome>
    private let continuation: AsyncStream<Outcome>.Continuation
    private var isSettled = false
    private var isPhysicalFinished = false
    private var physicalReply: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var closeObservation: BridgeProductAdmissionCloseObservation?

    init(requestId: String) {
        self.requestId = requestId
        (outcomes, continuation) = AsyncStream.makeStream(of: Outcome.self, bufferingPolicy: .bufferingNewest(1))
    }

    func start(
        admission: BridgeProductAdmissionContext,
        delay: AsyncDelay,
        reply: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        let physicalReply = Task { @MainActor in
            do {
                try Task.checkCancellation()
                try await reply()
                recordPhysicalCompletion()
                settle(.delivered)
            } catch {
                recordPhysicalCompletion()
                settle(.failed(error))
            }
        }
        let deadlineTask = Task { await expireAfterDeadline(delay: delay) }
        let closeObservation = admission.observeClose { [self] in settle(.admissionClosed) }
        let alreadySettled = lock.withLock {
            guard !isSettled else { return true }
            self.physicalReply = physicalReply
            self.deadlineTask = deadlineTask
            self.closeObservation = closeObservation
            return false
        }
        if alreadySettled {
            physicalReply.cancel()
            deadlineTask.cancel()
            closeObservation.cancel()
        }
    }

    func settle(_ outcome: Outcome) {
        let resources = lock.withLock { () -> SettlementCleanup? in
            guard !isSettled else { return nil }
            isSettled = true
            let resources = SettlementCleanup(
                physicalReply: physicalReply, deadlineTask: deadlineTask, closeObservation: closeObservation,
                hasDetachedPhysicalReply: !isPhysicalFinished)
            physicalReply = nil
            deadlineTask = nil
            closeObservation = nil
            return resources
        }
        guard let resources else { return }
        if resources.hasDetachedPhysicalReply {
            bootstrapPhysicalDeliveryLogger.notice(
                "Physical bootstrap reply detached requestId=\(self.requestId, privacy: .private)"
            )
        }
        resources.physicalReply?.cancel()
        resources.deadlineTask?.cancel()
        resources.closeObservation?.cancel()
        continuation.yield(outcome)
        continuation.finish()
    }

    private func recordPhysicalCompletion() {
        let wasDetached = lock.withLock {
            isPhysicalFinished = true
            return isSettled
        }
        if wasDetached {
            bootstrapPhysicalDeliveryLogger.notice(
                "Detached physical bootstrap reply completed requestId=\(self.requestId, privacy: .private)"
            )
        }
    }

    @concurrent
    private func expireAfterDeadline(delay: AsyncDelay) async {
        do {
            try await delay.wait(AppPolicies.Bridge.productBootstrapDeliveryProgressDeadline)
            settle(.deadlineExpired)
        } catch {
            // Cancellation is cleanup after another ender, never a second outcome.
        }
    }

    @concurrent
    func waitForOutcome() async -> Outcome {
        await withTaskCancellationHandler {
            var iterator = outcomes.makeAsyncIterator()
            return await iterator.next() ?? .admissionClosed
        } onCancel: {
            self.settle(.admissionClosed)
        }
    }
}

@MainActor
extension BridgePaneController {
    func deliverProductBootstrapReply(
        requestId: String,
        admission: BridgeProductAdmissionContext,
        reply: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        let delivery = BridgeProductBootstrapDelivery(requestId: requestId)
        productBootstrapDelivery = delivery
        delivery.start(admission: admission, delay: productSessionBootstrapDelay, reply: reply)
        defer {
            if productBootstrapDelivery === delivery { productBootstrapDelivery = nil }
        }
        switch await delivery.waitForOutcome() {
        case .delivered: return
        case .failed(let error): throw error
        case .deadlineExpired: throw BridgeError.encoding("Product bootstrap delivery deadline expired")
        case .admissionClosed, .superseded: throw CancellationError()
        }
    }
}
