typealias GitProjectorScope = String
enum GitProjectorFact { case refreshStarted }
typealias GitProjectorFactSink = (GitProjectorScope, GitProjectorFact) -> Void

actor GitWorkingDirectoryProjector {
    let factSink: GitProjectorFactSink?

    init(factSink: GitProjectorFactSink?) {
        self.factSink = factSink
    }
}

final class FilesystemGitPipeline {
    let projector: GitWorkingDirectoryProjector

    init(projectorFactSink: GitProjectorFactSink? = nil) {
        projector = GitWorkingDirectoryProjector(factSink: projectorFactSink)
    }
}

func productionConstruction(testSource: (String, GitProjectorFact) -> Void) {
    _ = FilesystemGitPipeline(projectorFactSink: testSource)
}
