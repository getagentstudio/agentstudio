extension WatchedFolderScanScheduler {
    enum ReadyRootNodeInspection: Equatable, Sendable {
        case absent
        case present(previousSourceTag: String?, nextSourceTag: String?)
    }

    struct ReadyRootSynchronizationSnapshot: Equatable, Sendable {
        let observedState: SchedulingStateCase
        let rereadState: SchedulingStateCase
        let readyCount: Int
        let scheduledRootCount: Int
        let readyNodeCount: Int
        let selectedSourceTag: String
        let schedulerTag: String?
        let firstReadySourceTag: String?
        let lastReadySourceTag: String?
        let selectedNode: ReadyRootNodeInspection
        let transitionOrdinal: UInt64
        let transitions: [SchedulingTransition]
    }

    static func formatReadyRootSynchronization(_ snapshot: ReadyRootSynchronizationSnapshot) -> String {
        let state = "state: observed=\(snapshot.observedState.rawValue), reread=\(snapshot.rereadState.rawValue)"
        let selected =
            "selected: source=\(snapshot.selectedSourceTag), scheduler=\(snapshot.schedulerTag ?? "unavailable")"
        let queue =
            "ready-queue: head=\(snapshot.firstReadySourceTag ?? "none"), tail=\(snapshot.lastReadySourceTag ?? "none")"
        let node: String
        switch snapshot.selectedNode {
        case .absent:
            node = "selected-node: absent"
        case .present(let previousSourceTag, let nextSourceTag):
            node = "selected-node: present, previous=\(previousSourceTag ?? "none"), next=\(nextSourceTag ?? "none")"
        }
        let transitions = snapshot.transitions.map { entry in
            "transition: \(entry.ordinal):\(entry.sourceTag):\(entry.fromCase)->\(entry.toCase):no-op=\(entry.isNoOp)"
        }
        return
            ([
                state, selected, queue, node,
                "transitions: ordinal=\(snapshot.transitionOrdinal), count=\(transitions.count)",
            ] + transitions)
            .joined(separator: "\n")
    }
}
