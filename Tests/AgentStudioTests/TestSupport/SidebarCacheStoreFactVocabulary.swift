import AgentStudioCore
import AgentStudioTestHarness
import Foundation

extension FactVocabulary<SidebarCacheStoreSaveScope, SidebarCacheStoreFact> {
    package static let sidebarCacheStore = FactVocabulary(
        describeScope: { String(describing: $0) },
        describeFact: { String(describing: $0) },
        isClosing: { _, fact in
            switch fact {
            case .saveStarted: false
            case .saveCompleted, .saveFailed, .saveCancelled: true
            }
        }
    )
}

extension FactRecorder where Scope == SidebarCacheStoreSaveScope, Fact == SidebarCacheStoreFact {
    package func expectNextSaveCompleted(
        workspaceId: UUID,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> SidebarCacheStoreSaveScope {
        let scope = try await expectNextOperation(
            matching: { $0.workspaceId == workspaceId }, opening: { $0 == .saveStarted },
            "sidebar cache save started for \(workspaceId)",
            fileID: fileID, line: line, function: function
        )
        try await expectNext(in: scope, .saveStarted, fileID: fileID, line: line, function: function)
        try await expectNext(in: scope, .saveCompleted, fileID: fileID, line: line, function: function)
        return scope
    }
}

/// Adapts the store's synchronous owner-fact sink to the canonical local recorder.
package final class SidebarCacheStoreFactSource: Sendable {
    private let localSource = LocalFactSource(
        vocabulary: FactVocabulary<SidebarCacheStoreSaveScope, SidebarCacheStoreFact>.sidebarCacheStore)

    package init() {}

    package var sink: SidebarCacheStoreFactSink { localSource.sink }

    package func attach() throws -> FactRecorder<SidebarCacheStoreSaveScope, SidebarCacheStoreFact> {
        try localSource.attach()
    }
}
