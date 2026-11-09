package enum WorkspaceStoreFlushOutcome: Equatable {
    case persisted
    case failed(String)

    package var succeeded: Bool {
        if case .persisted = self {
            return true
        }
        return false
    }
}
