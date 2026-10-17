import Foundation

/// Identity and pull progress for one finite E4. N3 owns the shared credit
/// accounting in BridgeProductViewSenderState, keyed by this read's scope.
struct BridgeProductContentCreditReadState {
    static let maximumReservedFrameByteCount =
        BridgeProductWireContract.maximumContentFrameBytes + MemoryLayout<UInt32>.size

    let scope: BridgeProductCreditScope
    let handle: String
    private var lastPulledSequence = -1

    init(admission: BridgeProductContentAdmission, credits: inout BridgeProductCreditWindow) {
        scope = .contentRead(
            contentRequestId: admission.contentRequestId,
            leaseId: admission.leaseId
        )
        handle = admission.leaseId
        credits.open(scope, handle: handle, firstSequence: 0)
    }

    func hasCapacity(for byteCount: Int, credits: BridgeProductCreditWindow) -> Bool {
        credits.canAdmitPart(for: scope, byteCount: byteCount)
    }

    func admit(sequence: Int, byteCount: Int, credits: inout BridgeProductCreditWindow) -> Bool {
        credits.admitPart(for: scope, handle: handle, sequence: sequence, byteCount: byteCount)
    }

    mutating func pulled(sequence: Int) {
        lastPulledSequence = max(lastPulledSequence, sequence)
    }

    mutating func acknowledge(
        through sequence: Int,
        credits: inout BridgeProductCreditWindow
    ) -> Bool {
        guard sequence <= lastPulledSequence else { return false }
        return credits.acknowledge(for: scope, handle: handle, through: sequence)
            || credits.wasAlreadySatisfied(for: scope, handle: handle, through: sequence)
    }

    func wasAcknowledged(through sequence: Int, credits: BridgeProductCreditWindow) -> Bool {
        credits.wasAlreadySatisfied(for: scope, handle: handle, through: sequence)
    }

    mutating func replaceOutstandingWithTerminal(
        sequence: Int,
        byteCount: Int,
        credits: inout BridgeProductCreditWindow
    ) -> Bool {
        credits.open(scope, handle: handle, firstSequence: sequence)
        lastPulledSequence = sequence - 1
        return admit(sequence: sequence, byteCount: byteCount, credits: &credits)
    }

    func close(credits: inout BridgeProductCreditWindow) {
        credits.close(scope)
    }
}
