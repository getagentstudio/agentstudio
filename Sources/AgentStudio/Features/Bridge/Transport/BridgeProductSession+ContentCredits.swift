import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

struct BridgeProductContentCreditWaiter {
    enum Condition {
        case capacity(byteCount: Int)
        case acknowledged(sequence: Int)
    }

    let condition: Condition
    let continuation: CheckedContinuation<Bool, Never>
    let token: UUID
}

extension BridgeProductSession {
    func enqueueContentFrame(
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        build: @Sendable (Int) throws -> BridgeProductProducerFrame,
        overflowReset: @Sendable (Int) throws -> BridgeProductProducerFrame
    ) async throws -> BridgeProductProducerEnqueueResult {
        guard
            await waitForContentCredit(
                for: lease,
                byteCount: BridgeProductContentCreditReadState.maximumReservedFrameByteCount,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else { return .rejected(.lifecycleClosed) }
        return try foregroundWorkAdmission.withValidAdmission {
            guard
                contentCreditsByProducerLease[lease]?.hasCapacity(
                    for: BridgeProductContentCreditReadState.maximumReservedFrameByteCount,
                    credits: viewSenderState.credits
                ) == true
            else { return .rejected(.closeRequired) }
            let result = try enqueueProducerFrame(
                for: lease,
                productAdmission: productAdmission,
                build: build,
                overflowReset: overflowReset
            )
            if case .enqueued(let frame) = result {
                let admitted =
                    contentCreditsByProducerLease[lease]?.admit(
                        sequence: frame.sequence,
                        byteCount: frame.data.count,
                        credits: &viewSenderState.credits
                    ) == true
                if !admitted {
                    precondition(
                        frame.terminal
                            && contentCreditsByProducerLease[lease]?
                                .replaceOutstandingWithTerminal(
                                    sequence: frame.sequence,
                                    byteCount: frame.data.count,
                                    credits: &viewSenderState.credits
                                ) == true,
                        "Content credit admission diverged from queued frame")
                }
            }
            return result
        } ?? .rejected(.lifecycleClosed)
    }

    func recordContentFramePulled(_ receipt: BridgeProductProducerFrameReceipt) {
        contentCreditsByProducerLease[receipt.producerLease]?.pulled(sequence: receipt.sequence)
    }

    func waitForContentCredit(
        for lease: BridgeProductProducerLease,
        byteCount: Int,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> Bool {
        await waitForContentCondition(
            .capacity(byteCount: byteCount),
            for: lease,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission
        )
    }

    func waitForContentAcknowledgement(
        for lease: BridgeProductProducerLease,
        sequence: Int,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> Bool {
        await waitForContentCondition(
            .acknowledged(sequence: sequence),
            for: lease,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission
        )
    }

    private func waitForContentCondition(
        _ condition: BridgeProductContentCreditWaiter.Condition,
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> Bool {
        let token = UUIDv7.generate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                    foregroundWorkAdmission.withValidAdmission({ true }) == true,
                    productAdmission.withValidAdmission({ true }) == true,
                    producerAdmissionMatches(productAdmission, for: lease),
                    contentCreditsByProducerLease[lease] != nil
                else {
                    continuation.resume(returning: false)
                    return
                }
                if contentConditionIsSatisfied(condition, for: lease) {
                    continuation.resume(returning: true)
                    return
                }
                precondition(contentCreditWaitersByProducerLease[lease] == nil)
                contentCreditWaitersByProducerLease[lease] = .init(
                    condition: condition,
                    continuation: continuation,
                    token: token
                )
            }
        } onCancel: {
            Task { await self.cancelContentCreditWaiter(for: lease, token: token) }
        }
    }

    private func contentConditionIsSatisfied(
        _ condition: BridgeProductContentCreditWaiter.Condition,
        for lease: BridgeProductProducerLease
    ) -> Bool {
        guard let credits = contentCreditsByProducerLease[lease] else { return false }
        return switch condition {
        case .capacity(let byteCount):
            credits.hasCapacity(for: byteCount, credits: viewSenderState.credits)
        case .acknowledged(let sequence):
            credits.wasAcknowledged(through: sequence, credits: viewSenderState.credits)
        }
    }

    func resumeContentCreditWaiterIfPossible(for lease: BridgeProductProducerLease) {
        guard let waiter = contentCreditWaitersByProducerLease[lease],
            contentConditionIsSatisfied(waiter.condition, for: lease)
        else { return }
        contentCreditWaitersByProducerLease.removeValue(forKey: lease)
        waiter.continuation.resume(returning: true)
    }

    func cancelContentCreditWaiter(for lease: BridgeProductProducerLease, token: UUID? = nil) {
        guard let waiter = contentCreditWaitersByProducerLease[lease],
            token == nil || waiter.token == token
        else { return }
        contentCreditWaitersByProducerLease.removeValue(forKey: lease)
        waiter.continuation.resume(returning: false)
    }
}
