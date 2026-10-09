import AgentStudioInfrastructure
import Foundation

/// The one pane-admission claim minted at a product or native-job ingress.
///
/// The context carries the original epoch through suspension. Mutation owners
/// validate it synchronously at the mutation boundary; no downstream owner may
/// reacquire admission after work has started.
package struct BridgeProductAdmissionContext: Sendable, Equatable {
    fileprivate let gate: BridgeProductAdmissionGate
    fileprivate let token: BridgeProductAdmissionGate.Token
    fileprivate var installation: InstallationAuthority?

    fileprivate struct InstallationAuthority: Sendable {
        let gate: BridgeProductAdmissionGate
        let token: BridgeProductAdmissionGate.Token
    }

    package func withValidAdmission<MutationResult>(
        _ mutation: () throws -> MutationResult
    ) rethrows -> MutationResult? {
        try gate.withValidAdmission(token) { () throws -> MutationResult? in
            if let installation {
                return try installation.gate.withValidAdmission(installation.token, perform: mutation)
            }
            return try mutation()
        }.flatMap { $0 }
    }

    /// Makes a successfully validated installation commit pane-readable without minting a new token.
    /// The original pane + E1 admission remains held while `mutation` records the pane-owned result.
    func withCanonicalPaneAuthority<MutationResult>(
        _ mutation: (Self) throws -> MutationResult
    ) rethrows -> MutationResult? {
        try withValidAdmission {
            try mutation(Self(gate: gate, token: token))
        }
    }

    func matches(_ other: Self) -> Bool {
        guard hasSamePaneAuthority(as: other) else { return false }
        switch (installation, other.installation) {
        case (nil, nil): return true
        case (.some(let own), .some(let other)):
            return own.gate === other.gate && own.token.matches(other.token)
        default: return false
        }
    }

    package static func == (left: Self, right: Self) -> Bool { left.matches(right) }

    /// Identity and epoch comparison only; use under the current request's composed guard.
    func hasSamePaneAuthority(as other: Self) -> Bool {
        gate === other.gate && token.matches(other.token)
    }

    var isPaneOnly: Bool { installation == nil }

    /// Only canonical pane jobs use this relation. E1/subscription equality remains `matches`.
    func isCanonicalPaneAuthority(for request: Self) -> Bool {
        isPaneOnly && hasSamePaneAuthority(as: request)
    }

    func withInstallation(_ installationGate: BridgeProductAdmissionGate) -> Self? {
        precondition(gate !== installationGate)
        return gate.withValidAdmission(token) { () -> Self? in
            guard installation == nil, let authority = installationGate.acquire() else { return nil }
            return Self(
                gate: gate, token: token,
                installation: .init(gate: installationGate, token: authority.token))
        }.flatMap { $0 }
    }

    func wasMinted(by expectedGate: BridgeProductAdmissionGate) -> Bool {
        gate === expectedGate && isPaneOnly
    }

    func wasMinted(by paneGate: BridgeProductAdmissionGate, installationGate: BridgeProductAdmissionGate) -> Bool {
        gate === paneGate && installation?.gate === installationGate
    }

    package func observeClose(_ observer: @escaping @Sendable () -> Void) -> BridgeProductAdmissionCloseObservation {
        let signal = BridgeProductAdmissionCloseSignal(observer)
        let paneObservation = gate.observeClose { signal.fire() }
        let installationObservation = installation?.gate.observeClose { signal.fire() }
        return BridgeProductAdmissionCloseObservation {
            paneObservation.cancel()
            installationObservation?.cancel()
        }
    }

    func diagnosticRelation(to other: Self) -> BridgeProductAdmissionDiagnosticRelation {
        BridgeProductAdmissionDiagnosticRelation(
            matches: matches(other),
            sameEpoch: token.epoch == other.token.epoch,
            sameGate: gate === other.gate,
            sameInstallation: matches(other),
            selfIsValid: withValidAdmission { true } == true,
            otherIsValid: other.withValidAdmission { true } == true
        )
    }
}

struct BridgeProductAdmissionDiagnosticRelation: Equatable, Sendable {
    let matches: Bool
    let sameEpoch: Bool
    let sameGate: Bool
    let sameInstallation: Bool
    let selfIsValid: Bool
    let otherIsValid: Bool
}

/// Synchronously linearizes pane admission with terminal pane teardown.
///
/// Callers carry the original token across suspension, then perform each visible
/// mutation through ``withValidAdmission(_:perform:)``. The mutation closure is
/// synchronous so the gate never holds its lock across an `await`.
final class BridgeProductAdmissionGate: @unchecked Sendable {
    fileprivate final class Identity: Sendable {}

    struct Token: Sendable {
        fileprivate let gateIdentity: Identity
        fileprivate let epoch: UInt64

        fileprivate func matches(_ other: Self) -> Bool {
            gateIdentity === other.gateIdentity && epoch == other.epoch
        }
    }

    struct DiagnosticSnapshot: Equatable, Sendable {
        let isOpen: Bool
        let epoch: UInt64
    }

    private let lock = NSLock()
    private let identity = Identity()
    private var admissionIsOpen = true
    private var epoch: UInt64 = 0
    private var closeObservers: [UUID: @Sendable () -> Void] = [:]

    var isOpen: Bool {
        lock.withLock { admissionIsOpen }
    }

    var diagnosticSnapshot: DiagnosticSnapshot {
        lock.withLock {
            DiagnosticSnapshot(isOpen: admissionIsOpen, epoch: epoch)
        }
    }

    func acquire() -> BridgeProductAdmissionContext? {
        lock.withLock {
            guard admissionIsOpen else { return nil }
            return BridgeProductAdmissionContext(
                gate: self,
                token: Token(gateIdentity: identity, epoch: epoch)
            )
        }
    }

    func withValidAdmission<MutationResult>(
        _ token: Token,
        perform mutation: () throws -> MutationResult
    ) rethrows -> MutationResult? {
        try lock.withLock {
            guard
                admissionIsOpen,
                token.gateIdentity === identity,
                token.epoch == epoch
            else {
                return nil
            }
            return try mutation()
        }
    }

    func close() {
        let observers: [@Sendable () -> Void] = lock.withLock {
            guard admissionIsOpen else { return [] }
            admissionIsOpen = false
            epoch += 1
            let observers = Array(closeObservers.values)
            closeObservers.removeAll()
            return observers
        }
        for observer in observers { observer() }
    }

    fileprivate func observeClose(_ observer: @escaping @Sendable () -> Void) -> BridgeProductAdmissionCloseObservation
    {
        let observationId = UUIDv7.generate()
        let registered = lock.withLock {
            guard admissionIsOpen else { return false }
            closeObservers[observationId] = observer
            return true
        }
        if !registered { observer() }
        return BridgeProductAdmissionCloseObservation { [weak self] in
            _ = self?.lock.withLock { self?.closeObservers.removeValue(forKey: observationId) }
        }
    }
}

package final class BridgeProductAdmissionCloseObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(_ cancellation: @escaping @Sendable () -> Void) { self.cancellation = cancellation }

    package func cancel() {
        let cancel = lock.withLock {
            let cancel = cancellation
            cancellation = nil
            return cancel
        }
        cancel?()
    }

    deinit { cancel() }
}

private final class BridgeProductAdmissionCloseSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: (@Sendable () -> Void)?
    init(_ observer: @escaping @Sendable () -> Void) { self.observer = observer }
    func fire() {
        let callback = lock.withLock {
            let callback = observer
            observer = nil
            return callback
        }
        callback?()
    }
}
