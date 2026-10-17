import AgentStudioInfrastructure

package enum PendingAffectedOwners: Sendable, Equatable {
    case owners(Set<PaneId>)
    case all

    package mutating func insert(contentsOf paneIds: Set<PaneId>) {
        guard case .owners(var owners) = self else { return }
        for paneId in paneIds {
            owners.insert(paneId)
            if owners.count > AppPolicies.PaneContext.maximumPendingAffectedOwners {
                self = .all
                return
            }
        }
        self = .owners(owners)
    }
}
