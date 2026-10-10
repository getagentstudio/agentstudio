typealias GitProjectorScope = String
enum GitProjectorFact { case refreshStarted }
typealias GitProjectorFactSink = (GitProjectorScope, GitProjectorFact) -> Void

actor GitWorkingDirectoryProjector {
    let factSink: GitProjectorFactSink?

    init(factSink: GitProjectorFactSink? = nil) {
        self.factSink = factSink
    }
}

extension GitWorkingDirectoryProjector {}

final class FilesystemGitPipeline {
    private let projectorFactSink: GitProjectorFactSink?
    let projector: GitWorkingDirectoryProjector

    init(projectorFactSink: GitProjectorFactSink? = nil) {
        self.projectorFactSink = projectorFactSink
        projector = GitWorkingDirectoryProjector(factSink: projectorFactSink)
    }
}

func productionConstruction(testSource: (String, GitProjectorFact) -> Void) {
    _ = FilesystemGitPipeline(projectorFactSink: testSource)
}
