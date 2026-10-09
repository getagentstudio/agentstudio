import AgentStudioCore
import AgentStudioTestHarness

extension FactVocabulary<RepositoryTopologyStoreSaveScope, RepositoryTopologyStoreFact> {
    package static let repositoryTopologyStore = FactVocabulary(
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

extension FactRecorder where Scope == RepositoryTopologyStoreSaveScope, Fact == RepositoryTopologyStoreFact {
    package func expectNextSaveCompleted(
        captureRevision: UInt64,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> RepositoryTopologyStoreSaveScope {
        let scope = try await expectNextOperation(
            matching: { _ in true }, opening: { $0 == .saveStarted },
            "repository topology save started",
            fileID: fileID, line: line, function: function
        )
        try await expectNext(in: scope, .saveStarted, fileID: fileID, line: line, function: function)
        try await expectNext(
            in: scope, .saveCompleted(captureRevision: captureRevision),
            fileID: fileID, line: line, function: function)
        return scope
    }
}

/// Adapts the store's synchronous owner-fact sink to the canonical local recorder.
package final class RepositoryTopologyStoreFactSource: Sendable {
    private let localSource = LocalFactSource(
        vocabulary: FactVocabulary<RepositoryTopologyStoreSaveScope, RepositoryTopologyStoreFact>
            .repositoryTopologyStore)

    package init() {}

    package var sink: RepositoryTopologyStoreFactSink { localSource.sink }

    package func attach() throws -> FactRecorder<RepositoryTopologyStoreSaveScope, RepositoryTopologyStoreFact> {
        try localSource.attach()
    }
}
