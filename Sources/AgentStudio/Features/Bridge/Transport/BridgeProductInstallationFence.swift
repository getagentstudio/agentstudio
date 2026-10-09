import Foundation

/// Immutable E1 handle. Keeping A's handle never grants authority over successor B.
struct BridgeProductInstallationFence: Sendable, Equatable {
    let workerInstanceId: String
    let gate: BridgeProductAdmissionGate

    static func == (left: Self, right: Self) -> Bool {
        left.workerInstanceId == right.workerInstanceId && left.gate === right.gate
    }

    func close() { gate.close() }
}

struct BridgeProductInstallationFenceSnapshot: Sendable, Equatable {
    let revision: UInt64
    let installation: BridgeProductInstallationFence?

    func close() { installation?.close() }
}

/// Synchronous projection of SessionOwner's installation, never a lifecycle decision owner.
final class BridgeProductInstallationFenceProjection: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var installation: BridgeProductInstallationFence?

    init(_ installation: BridgeProductInstallationFence?) { self.installation = installation }

    var snapshot: BridgeProductInstallationFenceSnapshot {
        lock.withLock { .init(revision: revision, installation: installation) }
    }

    func publish(_ installation: BridgeProductInstallationFence?) {
        lock.withLock {
            self.installation = installation
            revision &+= 1
        }
    }
}
