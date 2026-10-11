typealias WorkspaceCacheApplicationScope = String
enum WorkspaceCacheCoordinatorFact { case applied }
typealias WorkspaceCacheCoordinatorFactSink =
    (WorkspaceCacheApplicationScope, WorkspaceCacheCoordinatorFact) -> Void

struct PendingWorktreeEnrichment {
    let scope: WorkspaceCacheApplicationScope
    let payload: String
}

@MainActor
final class WorkspaceCacheCoordinator {
    let factSink: WorkspaceCacheCoordinatorFactSink?

    func enqueueAndApply(_ envelope: String) {
        let scope = WorkspaceCacheApplicationScope()
        let pending = PendingWorktreeEnrichment(scope: scope, payload: envelope)
        productionGovernorEnqueue(pending)
        applyProductionEnrichment(pending)
        factSink?(scope, .applied)
    }

    private func productionGovernorEnqueue(_ pending: PendingWorktreeEnrichment) {}
    private func applyProductionEnrichment(_ pending: PendingWorktreeEnrichment) {}
}
