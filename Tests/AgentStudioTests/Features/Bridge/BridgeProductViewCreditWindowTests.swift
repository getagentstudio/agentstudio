import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product view receipt credits")
struct BridgeProductViewCreditWindowTests {
    @Test("receipt credits let a batch exceed its in-flight window")
    func batchLargerThanWindowProgresses() {
        var credits = BridgeProductCreditWindow(maximumParts: 2, maximumBytes: 8)
        let viewDomain = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        credits.open(.view(viewDomain), handle: "first-handle")

        let firstAdmitted = credits.admitPart(for: .view(viewDomain), handle: "first-handle", sequence: 1, byteCount: 4)
        let secondAdmitted = credits.admitPart(
            for: .view(viewDomain), handle: "first-handle", sequence: 2, byteCount: 4)
        let thirdBeforeReceipt = credits.admitPart(
            for: .view(viewDomain), handle: "first-handle", sequence: 3, byteCount: 4)
        #expect(firstAdmitted && secondAdmitted && !thirdBeforeReceipt)

        let firstReceived = credits.acknowledge(for: .view(viewDomain), handle: "first-handle", through: 1)
        let thirdAfterReceipt = credits.admitPart(
            for: .view(viewDomain), handle: "first-handle", sequence: 3, byteCount: 4)
        #expect(firstReceived && thirdAfterReceipt)
        #expect(credits.outstandingPartCount(for: .view(viewDomain)) == 2)
        let remainderReceived = credits.acknowledge(for: .view(viewDomain), handle: "first-handle", through: 3)
        #expect(remainderReceived)
        #expect(credits.outstandingPartCount(for: .view(viewDomain)) == 0)
    }

    @Test("stale handles and acknowledgements cannot return credits")
    func staleAcknowledgementsDoNotReturnCredits() {
        var credits = BridgeProductCreditWindow(maximumParts: 1, maximumBytes: 8)
        let viewDomain = BridgeProductViewDomainKey(viewId: "review-view", domain: .singleDomain, incarnation: "first")
        credits.open(.view(viewDomain), handle: "first-handle")
        let firstAdmitted = credits.admitPart(for: .view(viewDomain), handle: "first-handle", sequence: 1, byteCount: 8)
        #expect(firstAdmitted)
        credits.open(.view(viewDomain), handle: "second-handle")
        let replacementAdmitted = credits.admitPart(
            for: .view(viewDomain), handle: "second-handle", sequence: 1, byteCount: 8)
        #expect(replacementAdmitted)

        let staleReceipt = credits.acknowledge(for: .view(viewDomain), handle: "first-handle", through: 1)
        let speculativeReceipt = credits.acknowledge(for: .view(viewDomain), handle: "second-handle", through: 2)
        let partBeforeReceipt = credits.admitPart(
            for: .view(viewDomain), handle: "second-handle", sequence: 2, byteCount: 1)
        let validReceipt = credits.acknowledge(for: .view(viewDomain), handle: "second-handle", through: 1)
        let duplicateReceipt = credits.acknowledge(for: .view(viewDomain), handle: "second-handle", through: 1)
        let partAfterReceipt = credits.admitPart(
            for: .view(viewDomain), handle: "second-handle", sequence: 2, byteCount: 1)
        #expect(!staleReceipt && !speculativeReceipt && !partBeforeReceipt)
        #expect(validReceipt && !duplicateReceipt && partAfterReceipt)
    }

    @Test("domains share transport credits and old receipts cannot release successor capacity")
    func domainsShareCreditsWithSeparateReceiptAttribution() {
        var credits = BridgeProductCreditWindow(maximumParts: 1, maximumBytes: 4)
        let retired = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        let successor = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "second")
        credits.open(.view(retired), handle: "shared-handle")
        credits.open(.view(successor), handle: "shared-handle")
        let oldAdmitted = credits.admitPart(for: .view(retired), handle: "shared-handle", sequence: 1, byteCount: 4)
        let newBeforeRelease = credits.admitPart(
            for: .view(successor), handle: "shared-handle", sequence: 1, byteCount: 4)
        credits.close(.view(retired))
        let newAfterRelease = credits.admitPart(
            for: .view(successor), handle: "shared-handle", sequence: 1, byteCount: 4)
        let staleReceipt = credits.acknowledge(for: .view(retired), handle: "shared-handle", through: 1)

        #expect(oldAdmitted && !newBeforeRelease && newAfterRelease && !staleReceipt)
        #expect(credits.outstandingPartCount(for: .view(retired)) == 0)
        #expect(credits.outstandingPartCount(for: .view(successor)) == 1)
    }

    @Test("a full File part window leaves a sibling Review E3 able to receive")
    func siblingPartWindowsAreIndependent() {
        var credits = BridgeProductCreditWindow(maximumParts: 1, maximumBytes: 8)
        let file = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        let review = BridgeProductViewDomainKey(viewId: "review-view", domain: .singleDomain, incarnation: "first")
        credits.open(.view(file), handle: "file-handle")
        credits.open(.view(review), handle: "review-handle")

        let fileAdmitted = credits.admitPart(for: .view(file), handle: "file-handle", sequence: 1, byteCount: 4)
        let reviewAdmitted = credits.admitPart(for: .view(review), handle: "review-handle", sequence: 1, byteCount: 4)
        #expect(fileAdmitted && reviewAdmitted)
        #expect(credits.outstandingPartCount(for: .view(file)) == 1)
        #expect(credits.outstandingPartCount(for: .view(review)) == 1)
        let reviewAcknowledged = credits.acknowledge(for: .view(review), handle: "review-handle", through: 1)
        let reviewNextAdmitted = credits.admitPart(
            for: .view(review), handle: "review-handle", sequence: 2, byteCount: 4)
        #expect(reviewAcknowledged && reviewNextAdmitted)
        #expect(credits.outstandingPartCount(for: .view(file)) == 1)
    }

    @Test("a full File byte window leaves a sibling Review E3 able to receive")
    func siblingByteWindowsAreIndependent() {
        var credits = BridgeProductCreditWindow(maximumParts: 2, maximumBytes: 4)
        let file = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        let review = BridgeProductViewDomainKey(viewId: "review-view", domain: .singleDomain, incarnation: "first")
        credits.open(.view(file), handle: "file-handle")
        credits.open(.view(review), handle: "review-handle")

        let fileAdmitted = credits.admitPart(for: .view(file), handle: "file-handle", sequence: 1, byteCount: 4)
        let reviewAdmitted = credits.admitPart(for: .view(review), handle: "review-handle", sequence: 1, byteCount: 4)
        #expect(fileAdmitted && reviewAdmitted)
        #expect(credits.outstandingPartCount(for: .view(file)) == 1)
        #expect(credits.outstandingPartCount(for: .view(review)) == 1)
    }

    @Test("late acknowledgement after resnapshot is satisfied without returning successor credit")
    func abandonedReceiptIsSatisfiedWithoutDoubleCredit() {
        var credits = BridgeProductCreditWindow(maximumParts: 1, maximumBytes: 8)
        let view = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        credits.open(.view(view), handle: "handle-1")
        let firstAdmitted = credits.admitPart(for: .view(view), handle: "handle-1", sequence: 1, byteCount: 8)
        #expect(firstAdmitted)
        credits.abandonOutstanding(for: .view(view))
        #expect(credits.outstandingPartCount(for: .view(view)) == 0)

        let abandonedReceiptReturnedCredit = credits.acknowledge(for: .view(view), handle: "handle-1", through: 1)
        #expect(!abandonedReceiptReturnedCredit)
        #expect(credits.wasAlreadySatisfied(for: .view(view), handle: "handle-1", through: 1))
        #expect(!credits.wasAlreadySatisfied(for: .view(view), handle: "wrong-handle", through: 1))
        #expect(!credits.wasAlreadySatisfied(for: .view(view), handle: "handle-1", through: 2))
        let successorPartAdmitted = credits.admitPart(for: .view(view), handle: "handle-1", sequence: 2, byteCount: 8)
        #expect(successorPartAdmitted)
        #expect(credits.wasAlreadySatisfied(for: .view(view), handle: "handle-1", through: 1))
        #expect(credits.outstandingPartCount(for: .view(view)) == 1)
    }

    @Test("reserved but unissued parts advance the credit floor without crediting late receipts")
    func reservedUnissuedSequencesDoNotBlockReplacement() {
        var credits = BridgeProductCreditWindow(maximumParts: 1, maximumBytes: 8)
        let view = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        credits.open(.view(view), handle: "handle-1")
        credits.abandonOutstanding(for: .view(view), throughReservedSequence: 3)

        #expect(credits.wasAlreadySatisfied(for: .view(view), handle: "handle-1", through: 3))
        let replacementAdmitted = credits.admitPart(for: .view(view), handle: "handle-1", sequence: 4, byteCount: 8)
        let lateReceiptReturnedCredit = credits.acknowledge(for: .view(view), handle: "handle-1", through: 3)
        #expect(replacementAdmitted)
        #expect(!lateReceiptReturnedCredit)
        #expect(credits.outstandingPartCount(for: .view(view)) == 1)
        let replacementReceiptReturnedCredit = credits.acknowledge(for: .view(view), handle: "handle-1", through: 4)
        #expect(replacementReceiptReturnedCredit)
        #expect(credits.outstandingPartCount(for: .view(view)) == 0)
    }

    @Test("content read cumulative credits and abandonment leave a sibling view intact")
    func contentReadCreditsAreIndependentOfView() {
        var credits = BridgeProductCreditWindow(maximumParts: 2, maximumBytes: 8)
        let view = BridgeProductViewDomainKey(
            viewId: "file-view", domain: .singleDomain, incarnation: "first"
        )
        let read: BridgeProductCreditScope = .contentRead(
            contentRequestId: "content-request-1", leaseId: "content-lease-1"
        )
        credits.open(.view(view), handle: "view-handle")
        credits.open(read, handle: "content-lease-1", firstSequence: 0)

        let viewAdmitted = credits.admitPart(for: .view(view), handle: "view-handle", sequence: 1, byteCount: 8)
        let openingAdmitted = credits.admitPart(for: read, handle: "content-lease-1", sequence: 0, byteCount: 2)
        let firstDataAdmitted = credits.admitPart(for: read, handle: "content-lease-1", sequence: 1, byteCount: 3)
        #expect(viewAdmitted && openingAdmitted && firstDataAdmitted)
        #expect(!credits.canAdmitPart(for: read, byteCount: 1))
        let cumulativeAcknowledged = credits.acknowledge(for: read, handle: "content-lease-1", through: 1)
        let duplicateAcknowledged = credits.acknowledge(for: read, handle: "content-lease-1", through: 1)
        #expect(cumulativeAcknowledged && !duplicateAcknowledged)
        #expect(credits.wasAlreadySatisfied(for: read, handle: "content-lease-1", through: 1))
        let secondDataAdmitted = credits.admitPart(for: read, handle: "content-lease-1", sequence: 2, byteCount: 8)
        #expect(secondDataAdmitted)
        #expect(!credits.canAdmitPart(for: read, byteCount: 1))

        credits.close(read)
        #expect(credits.outstandingPartCount(for: read) == 0)
        #expect(credits.outstandingPartCount(for: .view(view)) == 1)
        let lateReadAcknowledged = credits.acknowledge(for: read, handle: "content-lease-1", through: 2)
        let viewAcknowledged = credits.acknowledge(for: .view(view), handle: "view-handle", through: 1)
        #expect(!lateReadAcknowledged && viewAcknowledged)
    }
}
