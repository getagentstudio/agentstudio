import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

struct BridgeProductWebKitCarrierApplicationReceipt: Equatable, Sendable {
    let applicationResult: BridgeReviewDisplayedApplicationResult
    let publicationId: UUID
}

func assertReviewApplicationReceiptAdvances(
    _ receipts: [BridgeProductWebKitCarrierApplicationReceipt],
    expectedPublicationIds: [UUID]
) {
    var advancedPublicationIds: [UUID] = []
    for receipt in receipts {
        switch receipt.applicationResult {
        case .advanced:
            advancedPublicationIds.append(receipt.publicationId)
        case .duplicate:
            #expect(
                advancedPublicationIds.contains(receipt.publicationId),
                "a duplicate receipt must name an already-acknowledged publication"
            )
        case .rejected:
            Issue.record("The worker reported a rejected displayed application receipt")
        }
    }
    #expect(advancedPublicationIds == expectedPublicationIds, "displayed advancement order and count must be exact")
}

@MainActor
final class BridgeProductWebKitCarrierControllerTarget {
    private struct ApplicationReceiptWaiter {
        let publicationId: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    weak var controller: BridgePaneController?
    private(set) var applicationReceipts: [BridgeProductWebKitCarrierApplicationReceipt] = []
    private(set) var reviewContentSource: BridgePaneProductReviewContentSource?
    private var nextApplicationReceiptWaiterID: UInt64 = 0
    private var applicationReceiptWaiters: [UInt64: ApplicationReceiptWaiter] = [:]

    func install(_ controller: BridgePaneController) {
        self.controller = controller
        reviewContentSource = BridgePaneProductReviewContentSource(
            loaderCache: controller.reviewContentLoaderCache,
            acquireContentLease: { [weak controller] descriptor, productAdmission in
                controller?.reviewPublicationCoordinator.acquireContentLease(
                    handleId: descriptor.descriptorId,
                    packageId: descriptor.packageId,
                    requestedGeneration: BridgeReviewGeneration(descriptor.reviewGeneration),
                    sourceIdentity: descriptor.sourceIdentity,
                    productAdmission: productAdmission
                )
            },
            settleContentLease: { [weak controller] lease in
                controller?.reviewPublicationCoordinator.settleContentLease(lease) == true
            }
        )
    }

    func committedPublication(
        productAdmission: BridgeProductAdmissionContext
    ) -> BridgeReviewCommittedPublication? {
        controller?.reviewPublicationCoordinator.committedPublicationForReplay(
            productAdmission: productAdmission
        )
    }

    func isCurrentPublication(
        _ publicationId: UUID,
        productAdmission: BridgeProductAdmissionContext
    ) -> Bool {
        controller?.reviewPublicationCoordinator.isCurrentPublication(
            publicationId: publicationId,
            productAdmission: productAdmission
        ) == true
    }

    func recordApplication(
        _ publicationId: UUID,
        workerInstanceId: String,
        productAdmission: BridgeProductAdmissionContext
    ) -> BridgeReviewDisplayedApplicationResult {
        let result =
            controller?.reviewPublicationCoordinator.recordDisplayedApplication(
                publicationId: publicationId,
                workerInstanceId: workerInstanceId,
                productAdmission: productAdmission
            ) ?? .rejected
        applicationReceipts.append(
            BridgeProductWebKitCarrierApplicationReceipt(
                applicationResult: result,
                publicationId: publicationId
            )
        )
        resumeApplicationReceiptWaitersIfReady()
        return result
    }

    func waitForAcceptedApplication(
        publicationId: UUID,
        timeout: Duration
    ) async -> Bool {
        guard !hasAcceptedApplication(for: publicationId) else { return true }
        let waiterID = nextApplicationReceiptWaiterID
        nextApplicationReceiptWaiterID += 1
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return await self.waitForAcceptedApplicationEvent(
                    publicationId: publicationId,
                    waiterID: waiterID
                )
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                    return false
                } catch {
                    return nil
                }
            }
            let result = await group.next()
            group.cancelAll()
            guard let result else { return false }
            return result ?? false
        }
    }

    private func hasAcceptedApplication(for publicationId: UUID) -> Bool {
        applicationReceipts.contains {
            $0.applicationResult != .rejected && $0.publicationId == publicationId
        }
    }

    private func waitForAcceptedApplicationEvent(
        publicationId: UUID,
        waiterID: UInt64
    ) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if hasAcceptedApplication(for: publicationId) {
                    continuation.resume(returning: true)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    applicationReceiptWaiters[waiterID] = ApplicationReceiptWaiter(
                        publicationId: publicationId,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelApplicationReceiptWaiter(waiterID: waiterID)
            }
        }
    }

    private func cancelApplicationReceiptWaiter(waiterID: UInt64) {
        applicationReceiptWaiters.removeValue(forKey: waiterID)?.continuation.resume(
            returning: false
        )
    }

    private func resumeApplicationReceiptWaitersIfReady() {
        let readyIDs = applicationReceiptWaiters.compactMap { waiterID, waiter in
            hasAcceptedApplication(for: waiter.publicationId) ? waiterID : nil
        }
        for waiterID in readyIDs {
            applicationReceiptWaiters.removeValue(forKey: waiterID)?.continuation.resume(
                returning: true
            )
        }
    }
}

struct BridgeProductWebKitCarrierReviewContentRelay:
    BridgePaneProductReviewContentProducing
{
    let target: BridgeProductWebKitCarrierControllerTarget

    func authoritativeItemId(
        for request: BridgeProductReviewContentRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async -> String? {
        guard let source = await target.reviewContentSource else { return nil }
        return await source.authoritativeItemId(
            for: request,
            productAdmission: productAdmission
        )
    }

    func contentBody(
        for request: BridgeProductReviewContentRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewContentBody {
        guard let source = await target.reviewContentSource else {
            throw BridgePaneProductReviewContentSourceError.unavailablePackage
        }
        return try await source.contentBody(
            for: request,
            productAdmission: productAdmission
        )
    }
}
