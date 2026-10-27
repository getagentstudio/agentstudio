import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// The owner's presentation decision, independent of native window animation or layout.
enum PaneContextPopoverPresentationEvent {
    enum Producer {
        case synchronous
        case task(Task<Void, Never>)
    }
    case opened(PaneContextPopoverOpeningReadback)
    case started(UUID, Producer)
    case decided(UUID, isPresented: Bool)
}

typealias PaneContextPopoverPresentationObserver = @MainActor (PaneContextPopoverPresentationEvent) -> Void

@MainActor
struct PaneContextPopoverPresentationObservation {
    let isPresented: @MainActor () -> Bool
    let observe: PaneContextPopoverPresentationObserver

    func operation() -> Operation {
        Operation(id: UUIDv7.generate(), isPresented: isPresented, observe: observe)
    }

    @MainActor struct Operation {
        let id: UUID
        let isPresented: @MainActor () -> Bool
        let observe: PaneContextPopoverPresentationObserver

        func started(_ producer: PaneContextPopoverPresentationEvent.Producer) { observe(.started(id, producer)) }
        func decided() { observe(.decided(id, isPresented: isPresented())) }
    }
}

/// A passive read of one installed opening; retirement drops its live State getter.
@MainActor
final class PaneContextPopoverOpeningReadback {
    struct Snapshot: Equatable {
        let isPresented: Bool
        let paneId: PaneId?
        let controllerIdentity: ObjectIdentifier?
        let openRequest: UInt64
    }
    enum Failure: Error, Equatable { case retired, superseded }
    private enum Lifetime {
        case active(@MainActor () -> Snapshot)
        case retired
    }
    let ownerIdentity: ObjectIdentifier
    let opening: UInt64
    private var lifetime: Lifetime

    init(ownerIdentity: ObjectIdentifier, opening: UInt64, read: @escaping @MainActor () -> Snapshot) {
        self.ownerIdentity = ownerIdentity
        self.opening = opening
        lifetime = .active(read)
    }

    func read() throws -> Snapshot {
        guard case .active(let read) = lifetime else { throw Failure.retired }
        let snapshot = read()
        guard snapshot.openRequest == opening else { throw Failure.superseded }
        return snapshot
    }

    func retire() { lifetime = .retired }
}
