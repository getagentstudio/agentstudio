import AgentStudioInfrastructure
import Foundation

/// The owner's presentation decision, independent of native window animation or layout.
enum PaneContextPopoverPresentationEvent {
    enum Producer {
        case synchronous
        case task(Task<Void, Never>)
    }
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
