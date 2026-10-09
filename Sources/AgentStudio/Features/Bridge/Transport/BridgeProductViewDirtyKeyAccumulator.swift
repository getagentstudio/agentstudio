import Foundation

/// The view sender's domain identity is internal until the multi-root wire
/// contract is settled. Today's subscriptions use one domain.
struct BridgeProductViewDomain: Hashable, Sendable {
    static let singleDomain = Self(rawValue: "default")

    let rawValue: String

    init(rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }
}

struct BridgeProductViewDomainKey: Hashable, Sendable {
    let viewId: String
    let domain: BridgeProductViewDomain
    let incarnation: String

    init(viewId: String, domain: BridgeProductViewDomain, incarnation: String) {
        precondition(!viewId.isEmpty && !incarnation.isEmpty)
        self.viewId = viewId
        self.domain = domain
        self.incarnation = incarnation
    }
}

private struct BridgeProductViewDomainIdentity: Hashable {
    let viewId: String
    let domain: BridgeProductViewDomain
}

enum BridgeProductViewPendingChange: Equatable, Sendable {
    case keys([String: Int])
    case snapshotRequired(BridgeProductSnapshotCause)
}

/// Holds only the newest revision of each dirty key. Captures are taken before
/// batch construction; if that construction fails, restore merges with changes
/// that arrived in the meantime instead of rolling their revisions backward.
struct BridgeProductViewDirtyKeyAccumulator {
    private let maximumDirtyKeysPerViewDomain: Int
    private var activeByViewDomain: [BridgeProductViewDomainIdentity: (incarnation: String, scanGeneration: Int)] = [:]
    private var pendingByViewDomain: [BridgeProductViewDomainKey: BridgeProductViewPendingChange] = [:]

    init(maximumDirtyKeysPerViewDomain: Int) {
        precondition(maximumDirtyKeysPerViewDomain > 0)
        self.maximumDirtyKeysPerViewDomain = maximumDirtyKeysPerViewDomain
    }

    func pending(for viewDomain: BridgeProductViewDomainKey) -> BridgeProductViewPendingChange {
        pendingByViewDomain[viewDomain] ?? .keys([:])
    }

    func accepts(_ viewDomain: BridgeProductViewDomainKey, scanGeneration: Int) -> Bool {
        let identity = BridgeProductViewDomainIdentity(viewId: viewDomain.viewId, domain: viewDomain.domain)
        guard let active = activeByViewDomain[identity] else { return false }
        return active.incarnation == viewDomain.incarnation && active.scanGeneration == scanGeneration
    }

    func hasActiveIncarnation(_ viewDomain: BridgeProductViewDomainKey) -> Bool {
        let identity = BridgeProductViewDomainIdentity(viewId: viewDomain.viewId, domain: viewDomain.domain)
        return activeByViewDomain[identity]?.incarnation == viewDomain.incarnation
    }

    mutating func open(_ viewDomain: BridgeProductViewDomainKey, scanGeneration: Int) {
        precondition(scanGeneration >= 0)
        let identity = BridgeProductViewDomainIdentity(viewId: viewDomain.viewId, domain: viewDomain.domain)
        if let previous = activeByViewDomain[identity] {
            pendingByViewDomain.removeValue(
                forKey: .init(viewId: viewDomain.viewId, domain: viewDomain.domain, incarnation: previous.incarnation)
            )
        }
        activeByViewDomain[identity] = (viewDomain.incarnation, scanGeneration)
        pendingByViewDomain[viewDomain] = .snapshotRequired(.open)
    }

    mutating func advanceScanGeneration(for viewDomain: BridgeProductViewDomainKey, to scanGeneration: Int) -> Bool {
        let identity = BridgeProductViewDomainIdentity(viewId: viewDomain.viewId, domain: viewDomain.domain)
        guard let active = activeByViewDomain[identity],
            active.incarnation == viewDomain.incarnation,
            scanGeneration > active.scanGeneration
        else { return false }
        activeByViewDomain[identity] = (viewDomain.incarnation, scanGeneration)
        merge(.snapshotRequired(.newerInput), for: viewDomain)
        return true
    }

    mutating func relabelScanGenerationPreservingPending(
        for viewDomain: BridgeProductViewDomainKey, to scanGeneration: Int
    ) -> Bool {
        let identity = BridgeProductViewDomainIdentity(viewId: viewDomain.viewId, domain: viewDomain.domain)
        guard let active = activeByViewDomain[identity],
            active.incarnation == viewDomain.incarnation,
            scanGeneration > active.scanGeneration
        else { return false }
        activeByViewDomain[identity] = (viewDomain.incarnation, scanGeneration)
        return true
    }

    mutating func recordChange(
        for viewDomain: BridgeProductViewDomainKey,
        scanGeneration: Int,
        recordKey: String,
        revision: Int
    ) -> Bool {
        precondition(revision > 0)
        guard accepts(viewDomain, scanGeneration: scanGeneration) else { return false }
        merge(.keys([recordKey: revision]), for: viewDomain)
        return true
    }

    mutating func requireSnapshot(for viewDomain: BridgeProductViewDomainKey, cause: BridgeProductSnapshotCause) {
        guard hasActiveIncarnation(viewDomain) else { return }
        merge(.snapshotRequired(cause), for: viewDomain)
    }

    mutating func takePending(
        for viewDomain: BridgeProductViewDomainKey
    ) -> BridgeProductViewPendingChange {
        pendingByViewDomain.removeValue(forKey: viewDomain) ?? .keys([:])
    }

    mutating func restore(
        _ unfinished: BridgeProductViewPendingChange,
        for viewDomain: BridgeProductViewDomainKey
    ) {
        guard hasActiveIncarnation(viewDomain) else { return }
        merge(unfinished, for: viewDomain)
    }

    mutating func removeViewDomain(_ viewDomain: BridgeProductViewDomainKey) {
        pendingByViewDomain.removeValue(forKey: viewDomain)
        let identity = BridgeProductViewDomainIdentity(viewId: viewDomain.viewId, domain: viewDomain.domain)
        if activeByViewDomain[identity]?.incarnation == viewDomain.incarnation {
            activeByViewDomain.removeValue(forKey: identity)
        }
    }

    private mutating func merge(
        _ incoming: BridgeProductViewPendingChange,
        for viewDomain: BridgeProductViewDomainKey
    ) {
        switch (pending(for: viewDomain), incoming) {
        case (.snapshotRequired(let current), .snapshotRequired(let additional)):
            pendingByViewDomain[viewDomain] = .snapshotRequired(current.merging(additional))
        case (.snapshotRequired, .keys): break
        case (.keys, .snapshotRequired): pendingByViewDomain[viewDomain] = incoming
        case (.keys(var current), .keys(let additional)):
            for (recordKey, revision) in additional {
                current[recordKey] = max(current[recordKey] ?? revision, revision)
            }
            pendingByViewDomain[viewDomain] =
                current.count > maximumDirtyKeysPerViewDomain
                ? .snapshotRequired(.newerInput)
                : .keys(current)
        }
    }
}
