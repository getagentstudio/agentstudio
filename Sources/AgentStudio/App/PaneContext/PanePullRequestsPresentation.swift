import AgentStudioInfrastructure
import Observation
import SwiftUI

/// One workspace controller's request to its anchored pane host.
@MainActor
@Observable
final class PanePullRequestsPresentation {
    struct Request: Equatable, Identifiable {
        let id: UUID
        let paneId: UUID
    }
    private(set) var pendingRequest: Request?
    func present(_ paneId: UUID) { pendingRequest = .init(id: UUIDv7.generate(), paneId: paneId) }
    func clear(_ request: Request) {
        if pendingRequest?.id == request.id { pendingRequest = nil }
    }
}

private struct PanePullRequestsPresentationKey: EnvironmentKey {
    static let defaultValue: PanePullRequestsPresentation? = nil
}
extension EnvironmentValues {
    var panePullRequestsPresentation: PanePullRequestsPresentation? {
        get { self[PanePullRequestsPresentationKey.self] }
        set { self[PanePullRequestsPresentationKey.self] = newValue }
    }
}
