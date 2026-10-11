typealias RepoCacheStoreSaveScope = String
enum RepoCacheStoreFact { case saveCompleted }
typealias RepoCacheStoreFactSink = (RepoCacheStoreSaveScope, RepoCacheStoreFact) -> Void

@MainActor
final class RepoCacheStore {
    let factSink: RepoCacheStoreFactSink?

    func persist(workspaceID: String) async throws {
        let saveScope = RepoCacheStoreSaveScope()
        var didCompleteSave = false
        try await saveRepoCacheState(workspaceID)
        didCompleteSave = true
        if didCompleteSave {
            factSink?(saveScope, .saveCompleted)
        }
    }

    private func saveRepoCacheState(_ workspaceID: String) async throws {}
}
