import AgentStudioCore
import AgentStudioTestHarness
import Foundation

extension FactVocabulary<RepoCacheStoreSaveScope, RepoCacheStoreFact> {
    package static let repoCacheStore = FactVocabulary(
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

extension FactRecorder where Scope == RepoCacheStoreSaveScope, Fact == RepoCacheStoreFact {
    package func expectNextSaveCompleted(
        workspaceId: UUID,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> UInt64 {
        let scope = try await expectNextOperation(
            matching: { $0.workspaceId == workspaceId }, opening: { $0 == .saveStarted },
            "repo cache save started for \(workspaceId)",
            fileID: fileID, line: line, function: function
        )
        try await expectNext(in: scope, .saveStarted, fileID: fileID, line: line, function: function)
        let completed = try await expectNext(
            in: scope,
            where: {
                if case .saveCompleted = $0 { return true }
                return false
            },
            "repo cache save completed",
            fileID: fileID, line: line, function: function
        )
        guard case .saveCompleted(let sourceRevision) = completed else {
            throw UnexpectedFact.forExpectation(
                expected: "repo cache save completed", actual: String(describing: completed),
                scope: String(describing: scope), callSite: "\(fileID):\(line) \(function)")
        }
        return sourceRevision
    }
}

/// Adapts the store's synchronous owner-fact sink to the canonical local recorder.
package final class RepoCacheStoreFactSource: Sendable {
    private let localSource = LocalFactSource(
        vocabulary: FactVocabulary<RepoCacheStoreSaveScope, RepoCacheStoreFact>.repoCacheStore)

    package init() {}

    package var sink: RepoCacheStoreFactSink { localSource.sink }

    package func attach() throws -> FactRecorder<RepoCacheStoreSaveScope, RepoCacheStoreFact> {
        try localSource.attach()
    }
}
