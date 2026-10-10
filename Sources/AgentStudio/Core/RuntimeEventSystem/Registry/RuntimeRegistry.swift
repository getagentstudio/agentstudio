import Foundation
import os.log

private let runtimeRegistryLogger = Logger(subsystem: "com.agentstudio", category: "RuntimeRegistry")

@MainActor
package final class RuntimeRegistry {

    package init() {}

    package enum RegistrationResult: Equatable {
        case inserted
        case duplicateRejected
    }

    private var runtimes: [PaneId: any PaneRuntime] = [:]
    private var kindIndex: [PaneContentType: Set<PaneId>] = [:]

    @discardableResult
    package func register(_ runtime: any PaneRuntime) -> RegistrationResult {
        if runtimes[runtime.paneId] != nil {
            runtimeRegistryLogger.error(
                "Duplicate registration rejected for pane \(runtime.paneId, privacy: .public); existing runtime preserved"
            )
            return .duplicateRejected
        }

        runtimes[runtime.paneId] = runtime
        kindIndex[runtime.metadata.contentType, default: []].insert(runtime.paneId)
        return .inserted
    }

    @discardableResult
    package func unregister(_ paneId: PaneId) -> (any PaneRuntime)? {
        guard let runtime = runtimes.removeValue(forKey: paneId) else {
            return nil
        }
        removeFromKindIndex(paneId: paneId, contentType: runtime.metadata.contentType)
        return runtime
    }

    package func runtime(for paneId: PaneId) -> (any PaneRuntime)? {
        runtimes[paneId]
    }

    func runtimes(ofType type: PaneContentType) -> [any PaneRuntime] {
        (kindIndex[type] ?? []).compactMap { runtimes[$0] }
    }

    var readyRuntimes: [any PaneRuntime] {
        runtimes.values.filter { $0.lifecycle == .ready }
    }

    /// Find a pane whose live facets have the given worktreeId.
    /// Returns the first matching PaneId, or nil.
    func findPaneWithWorktree(worktreeId: UUID) -> PaneId? {
        for (paneId, runtime) in runtimes {
            if runtime.metadata.facets.worktreeId == worktreeId {
                return paneId
            }
        }
        return nil
    }

    func shutdownAll(timeout: Duration) async -> [PaneId: [UUID]] {
        var unfinished: [PaneId: [UUID]] = [:]
        // PaneRuntime is MainActor-isolated, so shutdown is intentionally ordered here.
        // A task group would still hop back to MainActor for each call without true parallel execution.
        for (paneId, runtime) in runtimes {
            let ids = await runtime.shutdown(timeout: timeout)
            if !ids.isEmpty {
                unfinished[paneId] = ids
            }
        }
        runtimes.removeAll()
        kindIndex.removeAll()
        return unfinished
    }

    var count: Int { runtimes.count }

    private func removeFromKindIndex(paneId: PaneId, contentType: PaneContentType) {
        kindIndex[contentType]?.remove(paneId)
        if kindIndex[contentType]?.isEmpty == true {
            kindIndex.removeValue(forKey: contentType)
        }
    }
}
