import AgentStudioCore
import AgentStudioTestHarness
import Foundation

extension FactVocabulary<UIStateStoreSaveScope, UIStateStoreFact> {
    package static let uiStateStore = FactVocabulary(
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

extension FactRecorder where Scope == UIStateStoreSaveScope, Fact == UIStateStoreFact {
    package func expectNextSaveCompleted(
        workspaceId: UUID,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> UIStateStoreSaveScope {
        let scope = try await expectNextOperation(
            matching: { $0.workspaceId == workspaceId }, opening: { $0 == .saveStarted },
            "UI state save started for \(workspaceId)",
            fileID: fileID, line: line, function: function
        )
        try await expectNext(in: scope, .saveStarted, fileID: fileID, line: line, function: function)
        try await expectNext(in: scope, .saveCompleted, fileID: fileID, line: line, function: function)
        return scope
    }
}

/// Adapts the store's synchronous owner-fact sink to the canonical local recorder.
package final class UIStateStoreFactSource: Sendable {
    private let localSource = LocalFactSource(
        vocabulary: FactVocabulary<UIStateStoreSaveScope, UIStateStoreFact>.uiStateStore)

    package init() {}

    package var sink: UIStateStoreFactSink { localSource.sink }

    package func attach() throws -> FactRecorder<UIStateStoreSaveScope, UIStateStoreFact> {
        try localSource.attach()
    }
}
