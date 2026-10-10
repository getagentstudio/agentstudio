typealias GitProjectorScope = String
enum GitProjectorFact { case refreshFinished(branchChanged: Bool) }
typealias GitProjectorFactSink = (GitProjectorScope, GitProjectorFact) -> Void

actor GitWorkingDirectoryProjector {
    let factSink: GitProjectorFactSink?

    init(factSink: GitProjectorFactSink?) {
        self.factSink = factSink
    }

    func finishRefresh(previousBranch: String?, branch: String) {
        var branchChanged = false
        if previousBranch != branch {
            emitRuntimeBranchChanged(from: previousBranch, to: branch)
            branchChanged = true
        }
        guard let factSink else { return }
        let scope = GitProjectorScope()
        factSink(scope, .refreshFinished(branchChanged: branchChanged))
    }

    private func emitRuntimeBranchChanged(from: String?, to: String) {}
}
