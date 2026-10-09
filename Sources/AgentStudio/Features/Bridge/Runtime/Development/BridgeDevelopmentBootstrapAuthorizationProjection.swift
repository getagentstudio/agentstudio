import Foundation

struct BridgeDevelopmentBootstrapAuthorizationSnapshot: Equatable, Sendable {
    let revision: UInt64
    let tabId: String?
    let paneSessionId: String
    let navigationBindingRevision: Int
    let isShutdown: Bool
}

/// Read-only cross-actor projection. Only the host publishes its authoritative mutations.
final class BridgeDevelopmentBootstrapAuthorizationProjection: @unchecked Sendable {
    private let lock = NSLock()
    private var state: BridgeDevelopmentBootstrapAuthorizationSnapshot

    init(paneSessionId: String) {
        state = .init(
            revision: 0, tabId: nil, paneSessionId: paneSessionId,
            navigationBindingRevision: 0, isShutdown: false)
    }

    var snapshot: BridgeDevelopmentBootstrapAuthorizationSnapshot { lock.withLock { state } }

    func publish(tabId: String?, navigationBindingRevision: Int, isShutdown: Bool) {
        lock.withLock {
            state = .init(
                revision: state.revision &+ 1, tabId: tabId,
                paneSessionId: state.paneSessionId,
                navigationBindingRevision: navigationBindingRevision, isShutdown: isShutdown)
        }
    }
}
