typealias EntityRecencyStoreSaveScope = String
enum EntityRecencyStoreSaveLane { case workspace(String) }
enum EntityRecencyStoreFact { case saveStarted }
typealias EntityRecencyStoreFactSink = (EntityRecencyStoreSaveScope, EntityRecencyStoreFact) -> Void

@MainActor
final class EntityRecencyStore {
    let factSink: EntityRecencyStoreFactSink?

    func flush(workspaceID: String) {
        let saveScope = beginSaveFact(in: .workspace(workspaceID))
        saveProductionState()
        if let saveScope { factSink?(saveScope, .saveStarted) }
    }

    private func beginSaveFact(in lane: EntityRecencyStoreSaveLane) -> EntityRecencyStoreSaveScope? {
        guard let factSink else { return nil }
        return EntityRecencyStoreSaveScope()
    }

    private func saveProductionState() {}
}
