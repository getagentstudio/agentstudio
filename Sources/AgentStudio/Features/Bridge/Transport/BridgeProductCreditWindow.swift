import Foundation

struct BridgeProductViewOutstandingPart: Sendable {
    let viewDomain: BridgeProductViewDomainKey
    let handle: String
    let sequence: Int
    let admittedAt: Duration
    let admissionOrder: Int
}

enum BridgeProductCreditScope: Hashable {
    case view(BridgeProductViewDomainKey)
    case contentRead(contentRequestId: String, leaseId: String)

    var accountingKey: BridgeProductCreditAccountingKey {
        switch self {
        case .view(let viewDomain): .view(viewDomain.viewId)
        case .contentRead(let contentRequestId, let leaseId):
            .contentRead(contentRequestId: contentRequestId, leaseId: leaseId)
        }
    }
}

enum BridgeProductCreditAccountingKey: Hashable {
    case view(String)
    case contentRead(contentRequestId: String, leaseId: String)
}

/// N3's common part and byte accounting. A view's domains share one budget;
/// each finite content read has an independent scope and budget.
struct BridgeProductCreditWindow {
    private struct OutstandingPart {
        let sequence: Int
        let byteCount: Int
        let admittedAt: Duration
        let admissionOrder: Int
    }

    private struct ViewState {
        let handle: String
        let firstSequence: Int
        var receivedThroughSequence: Int
        var lastAdmittedSequence: Int
        var outstandingParts: [OutstandingPart] = []
        var outstandingBytes = 0
    }

    private struct ViewCreditUsage {
        var partCount = 0
        var byteCount = 0
    }

    private let maximumParts: Int
    private let maximumBytes: Int
    private var stateByScope: [BridgeProductCreditScope: ViewState] = [:]
    private var creditUsageByAccountingKey: [BridgeProductCreditAccountingKey: ViewCreditUsage] = [:]
    private var nextAdmissionOrder = 0

    init(maximumParts: Int, maximumBytes: Int) {
        precondition(maximumParts > 0 && maximumBytes > 0)
        self.maximumParts = maximumParts
        self.maximumBytes = maximumBytes
    }

    mutating func open(_ scope: BridgeProductCreditScope, handle: String, firstSequence: Int = 1) {
        precondition(!handle.isEmpty)
        precondition(firstSequence >= 0)
        close(scope)
        stateByScope[scope] = ViewState(
            handle: handle,
            firstSequence: firstSequence,
            receivedThroughSequence: firstSequence - 1,
            lastAdmittedSequence: firstSequence - 1
        )
    }

    mutating func close(_ scope: BridgeProductCreditScope) {
        guard let state = stateByScope.removeValue(forKey: scope) else { return }
        adjustUsage(for: scope.accountingKey, parts: -state.outstandingParts.count, bytes: -state.outstandingBytes)
    }

    func outstandingPartCount(for scope: BridgeProductCreditScope) -> Int {
        stateByScope[scope]?.outstandingParts.count ?? 0
    }

    func oldestUnacknowledgedPart() -> BridgeProductViewOutstandingPart? {
        stateByScope.compactMap { scope, state in
            guard case .view(let viewDomain) = scope else { return nil }
            return state.outstandingParts.first.map { part in
                BridgeProductViewOutstandingPart(
                    viewDomain: viewDomain,
                    handle: state.handle,
                    sequence: part.sequence,
                    admittedAt: part.admittedAt,
                    admissionOrder: part.admissionOrder
                )
            }
        }.min {
            $0.admittedAt == $1.admittedAt
                ? $0.admissionOrder < $1.admissionOrder
                : $0.admittedAt < $1.admittedAt
        }
    }

    /// A late receipt for already returned or abandoned credits is a no-op.
    /// It may be answered without releasing any capacity a second time.
    func wasAlreadySatisfied(
        for scope: BridgeProductCreditScope,
        handle: String,
        through sequence: Int
    ) -> Bool {
        guard let state = stateByScope[scope], state.handle == handle else { return false }
        return sequence >= state.firstSequence && sequence <= state.receivedThroughSequence
    }

    func canAdmitPart(for scope: BridgeProductCreditScope, byteCount: Int) -> Bool {
        let usage = creditUsageByAccountingKey[scope.accountingKey] ?? ViewCreditUsage()
        return stateByScope[scope] != nil
            && byteCount > 0
            && byteCount <= maximumBytes - usage.byteCount
            && usage.partCount < maximumParts
    }

    var maximumPartByteCount: Int { maximumBytes }

    /// Abandoning one staging bank returns only its in-transit credits. Reserved
    /// delivery sequences that never reached admission are skipped so the next
    /// sealed batch can keep its monotonic sequence. A late receipt cannot
    /// release successor capacity.
    mutating func abandonOutstanding(
        for scope: BridgeProductCreditScope,
        throughReservedSequence: Int? = nil
    ) {
        guard var state = stateByScope[scope] else { return }
        adjustUsage(for: scope.accountingKey, parts: -state.outstandingParts.count, bytes: -state.outstandingBytes)
        state.outstandingParts.removeAll()
        state.outstandingBytes = 0
        let abandonedThroughSequence = max(state.lastAdmittedSequence, throughReservedSequence ?? 0)
        state.lastAdmittedSequence = abandonedThroughSequence
        state.receivedThroughSequence = abandonedThroughSequence
        stateByScope[scope] = state
    }

    mutating func admitPart(
        for scope: BridgeProductCreditScope,
        handle: String,
        sequence: Int,
        byteCount: Int,
        admittedAt: Duration = .zero
    ) -> Bool {
        let usage = creditUsageByAccountingKey[scope.accountingKey] ?? ViewCreditUsage()
        guard var state = stateByScope[scope],
            state.handle == handle,
            sequence == state.lastAdmittedSequence + 1,
            byteCount > 0,
            byteCount <= maximumBytes - usage.byteCount,
            usage.partCount < maximumParts
        else {
            return false
        }
        nextAdmissionOrder += 1
        state.outstandingParts.append(
            .init(
                sequence: sequence,
                byteCount: byteCount,
                admittedAt: admittedAt,
                admissionOrder: nextAdmissionOrder
            )
        )
        state.outstandingBytes += byteCount
        state.lastAdmittedSequence = sequence
        adjustUsage(for: scope.accountingKey, parts: 1, bytes: byteCount)
        stateByScope[scope] = state
        return true
    }

    /// A cumulative receipt is valid only through a part this view admitted.
    /// Duplicate and speculative receipts do not change the credit balance.
    mutating func acknowledge(
        for scope: BridgeProductCreditScope,
        handle: String,
        through receivedSequence: Int
    ) -> Bool {
        guard var state = stateByScope[scope],
            state.handle == handle,
            receivedSequence > state.receivedThroughSequence,
            receivedSequence <= state.lastAdmittedSequence
        else {
            return false
        }
        let receivedParts = state.outstandingParts.prefix {
            $0.sequence <= receivedSequence
        }
        let returnedPartCount = receivedParts.count
        let returnedByteCount = receivedParts.reduce(0) { $0 + $1.byteCount }
        state.outstandingBytes -= returnedByteCount
        state.outstandingParts.removeFirst(returnedPartCount)
        state.receivedThroughSequence = receivedSequence
        adjustUsage(for: scope.accountingKey, parts: -returnedPartCount, bytes: -returnedByteCount)
        stateByScope[scope] = state
        return true
    }

    private mutating func adjustUsage(for accountingKey: BridgeProductCreditAccountingKey, parts: Int, bytes: Int) {
        var usage = creditUsageByAccountingKey[accountingKey] ?? ViewCreditUsage()
        usage.partCount += parts
        usage.byteCount += bytes
        precondition(usage.partCount >= 0 && usage.byteCount >= 0)
        if usage.partCount == 0 && usage.byteCount == 0 {
            creditUsageByAccountingKey.removeValue(forKey: accountingKey)
        } else {
            creditUsageByAccountingKey[accountingKey] = usage
        }
    }
}
