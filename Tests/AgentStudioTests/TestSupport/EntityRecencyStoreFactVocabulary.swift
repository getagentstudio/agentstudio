import AgentStudioCore
import AgentStudioTestHarness

extension FactVocabulary<EntityRecencyStoreSaveScope, EntityRecencyStoreFact> {
    package static let entityRecencyStore = FactVocabulary(
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

extension FactRecorder where Scope == EntityRecencyStoreSaveScope, Fact == EntityRecencyStoreFact {
    package func expectNextSaveCompleted(
        in lane: EntityRecencyStoreSaveLane,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> EntityRecencyStoreSaveScope {
        let scope = try await expectNextOperation(
            matching: { $0.lane == lane }, opening: { $0 == .saveStarted },
            "entity recency save started in \(lane)",
            fileID: fileID, line: line, function: function
        )
        try await expectNext(in: scope, .saveStarted, fileID: fileID, line: line, function: function)
        try await expectNext(in: scope, .saveCompleted, fileID: fileID, line: line, function: function)
        return scope
    }
}

/// Adapts the store's synchronous owner-fact sink to the canonical local recorder.
package final class EntityRecencyStoreFactSource: Sendable {
    private let localSource = LocalFactSource(
        vocabulary: FactVocabulary<EntityRecencyStoreSaveScope, EntityRecencyStoreFact>.entityRecencyStore)

    package init() {}

    package var sink: EntityRecencyStoreFactSink { localSource.sink }

    package func attach() throws -> FactRecorder<EntityRecencyStoreSaveScope, EntityRecencyStoreFact> {
        try localSource.attach()
    }
}
