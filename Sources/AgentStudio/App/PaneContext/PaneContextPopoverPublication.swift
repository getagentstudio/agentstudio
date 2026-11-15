import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

enum PaneContextPopoverProducer: Hashable, Sendable {
    case execution(UUID)
    case input(UUID)

    nonisolated var id: UUID {
        switch self {
        case .execution(let id), .input(let id): id
        }
    }
    nonisolated func scope(for key: PaneContextPopoverConsumerKey) -> PaneContextPopoverOwnerScope {
        switch self {
        case .execution(let id): .execution(key, id)
        case .input(let id): .input(id)
        }
    }
}

/// Scalar publication identity accompanies the prepared payload through native application.
struct PaneContextPopoverPublication: Sendable {
    let id: UUID
    var producer: PaneContextPopoverProducer { request.producer }
    let request: PaneContextPopoverRequestIdentity
}

struct PaneContextPopoverApplication: Sendable, Equatable {
    let publication: PaneContextPopoverPublication
    let value: PaneManagementIdentityCapture.VisiblePresentation
    let feedback: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.publication.id == rhs.publication.id
    }
}

enum PaneContextPopoverApplicationEvent: Sendable {
    case prepared(PaneContextPopoverApplication)
    case applied(PaneContextPopoverApplication)
    case retired(PaneContextPopoverApplication)
}
typealias PaneContextPopoverApplicationObserver = @MainActor @Sendable (PaneContextPopoverApplicationEvent) -> Void

struct PaneContextPopoverMessageApplicationEvent: Sendable {
    let publication: PaneContextPopoverPublication
    let event: PaneContextMessageTextApplication.Event
}

enum PaneContextNoteApplication: Equatable, Sendable {
    struct Value: Equatable, Sendable {
        let paneId: PaneId
        let location: PaneContextPopoverLocation
        let openRequest: UInt64
        let text: String
    }
    case applied(Value)
    case retired(Value)
}
typealias PaneContextNoteApplicationObserver = @MainActor (PaneContextNoteApplication) -> Void
