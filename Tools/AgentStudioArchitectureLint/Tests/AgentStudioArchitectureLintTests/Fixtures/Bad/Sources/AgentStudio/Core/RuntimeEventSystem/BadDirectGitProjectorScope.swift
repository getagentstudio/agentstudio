enum DirectGitProjectorScope {
    case refresh(worktreeId: String, requestSequence: UInt64)
}

enum DirectGitProjectorFact { case refreshAdmitted }
typealias DirectGitProjectorFactSink = (DirectGitProjectorScope, DirectGitProjectorFact) -> Void

actor BadDirectGitProjectorScope {
    let factSink: DirectGitProjectorFactSink?

    init(factSink: DirectGitProjectorFactSink?) {
        self.factSink = factSink
    }

    func admitRefresh(worktreeID: String, requestSequence: UInt64) {
        let scope = DirectGitProjectorScope.refresh(
            worktreeId: worktreeID,
            requestSequence: requestSequence
        )
        guard let factSink else { return }
        factSink(scope, .refreshAdmitted)
    }
}
