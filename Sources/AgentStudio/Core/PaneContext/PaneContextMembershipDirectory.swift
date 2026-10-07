import Foundation
import Synchronization

package struct PaneContextMembershipEntry: Sendable, Equatable {
    package let paneId: PaneId
    package let placement: PaneStructuralFacts.Placement
    package let ownedDrawerChildIds: [PaneId]

    package init(paneId: PaneId, placement: PaneStructuralFacts.Placement, ownedDrawerChildIds: [PaneId]) {
        self.paneId = paneId
        self.placement = placement
        self.ownedDrawerChildIds = ownedDrawerChildIds
    }
}

package struct PaneContextMembershipInstallation: Sendable, Equatable {
    package let workspaceId: UUID
    package let membershipRevision: UInt64
    package let entries: [PaneContextMembershipEntry]
    let entriesByPaneId: [PaneId: PaneContextMembershipEntry]
    let versionsByPaneId: [PaneId: UInt64]

    package init(workspaceId: UUID, membershipRevision: UInt64, entries: [PaneContextMembershipEntry]) {
        self.workspaceId = workspaceId
        self.membershipRevision = membershipRevision
        self.entries = entries
        entriesByPaneId = Dictionary(uniqueKeysWithValues: entries.map { ($0.paneId, $0) })
        versionsByPaneId = Dictionary(uniqueKeysWithValues: entries.map { ($0.paneId, membershipRevision) })
    }
}

package struct PaneContextMembershipView: Sendable, Equatable {
    package let workspaceId: UUID
    package let membershipRevision: UInt64
    package let sources: [PaneId]
}

package struct PaneContextMembershipOwner: Sendable, Equatable {
    package let paneId: PaneId
    package let membershipRevision: UInt64
}

/// The canonical graph publishes only presence, placement and owned child ids.
package final class PaneContextMembershipDirectory: PaneContextMembershipReading, Sendable {
    private struct DirectoryState {
        var workspaceId: UUID?
        var revision: UInt64 = 0
        var entries: [PaneId: PaneContextMembershipEntry] = [:]
        var versions: [PaneId: UInt64] = [:]
        var pending = PendingAffectedOwners.owners([])

        func ownerPaneId(for paneId: PaneId) -> PaneId? {
            guard let child = entries[paneId], case .drawerChild(let parentUUID) = child.placement else { return nil }
            let parentId = PaneId(existingUUID: parentUUID)
            guard let parent = entries[parentId], parent.placement == .layout,
                parent.ownedDrawerChildIds.contains(paneId)
            else { return nil }
            return parentId
        }

        func sources(for paneId: PaneId) -> [PaneId]? {
            guard let entry = entries[paneId] else { return nil }
            guard entry.placement == .layout else { return [paneId] }
            return [paneId] + entry.ownedDrawerChildIds.filter { ownerPaneId(for: $0) == paneId }
        }

        func affected(by entry: PaneContextMembershipEntry) -> Set<PaneId> {
            var owners = Set([entry.paneId])
            owners.formUnion(entry.ownedDrawerChildIds)
            if case .drawerChild(let parent) = entry.placement { owners.insert(PaneId(existingUUID: parent)) }
            return owners
        }
    }

    private let state = Mutex(DirectoryState())
    package let wakes: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    package init() {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeContinuation = channel.continuation
        wakes = channel.stream
    }

    package func install(_ installation: PaneContextMembershipInstallation) {
        state.withLock { directory in
            directory.pending = .all
            directory.workspaceId = installation.workspaceId
            directory.entries = installation.entriesByPaneId
            directory.revision = installation.membershipRevision
            directory.versions = installation.versionsByPaneId
        }
        wakeContinuation.yield(())
    }

    package func commit(changed: [PaneContextMembershipEntry], removed: [PaneId]) {
        let accepted = state.withLock { directory in
            guard directory.workspaceId != nil else { return false }
            var affected = Set<PaneId>()
            for paneId in removed {
                if let previous = directory.entries.removeValue(forKey: paneId) {
                    affected.formUnion(directory.affected(by: previous))
                }
            }
            for entry in changed where directory.entries[entry.paneId] != entry {
                if let previous = directory.entries[entry.paneId] {
                    affected.formUnion(directory.affected(by: previous))
                }
                affected.formUnion(directory.affected(by: entry))
                directory.entries[entry.paneId] = entry
            }
            guard !affected.isEmpty else { return false }
            directory.revision &+= 1
            for paneId in affected {
                directory.versions[paneId] = directory.entries[paneId] == nil ? nil : directory.revision
            }
            directory.pending.insert(contentsOf: affected)
            return true
        }
        if accepted { wakeContinuation.yield(()) }
    }

    package func contains(paneID: UUID, inWorkspace workspaceID: UUID) -> Bool {
        state.withLock { $0.workspaceId == workspaceID && $0.entries[PaneId(existingUUID: paneID)] != nil }
    }

    package func view(for paneId: PaneId) -> PaneContextMembershipView? {
        state.withLock { directory in
            guard let workspaceId = directory.workspaceId, let sources = directory.sources(for: paneId) else {
                return nil
            }
            return .init(
                workspaceId: workspaceId, membershipRevision: directory.versions[paneId] ?? directory.revision,
                sources: sources)
        }
    }

    package func ownerPaneId(for paneId: PaneId) -> PaneId? {
        state.withLock { $0.ownerPaneId(for: paneId) }
    }

    package func sources(for paneId: PaneId) -> [PaneId]? {
        state.withLock { $0.sources(for: paneId) }
    }

    package func currentOwners() -> [PaneContextMembershipOwner] {
        state.withLock { directory in
            directory.entries.keys.map {
                .init(paneId: $0, membershipRevision: directory.versions[$0] ?? directory.revision)
            }
        }
    }

    package func takeAffectedOwners() -> PendingAffectedOwners {
        state.withLock { directory in
            defer { directory.pending = .owners([]) }
            return directory.pending
        }
    }
}
