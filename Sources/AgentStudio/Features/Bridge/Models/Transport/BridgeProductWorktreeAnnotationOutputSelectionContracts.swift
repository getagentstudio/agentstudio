import Foundation

extension BridgeProductWorktreeAnnotationOperation {
    enum OutputKind: String, Codable, Equatable, Sendable {
        case clipboardMarkdown
        case jsonFile
    }

    enum OutputScope: String, Codable, Equatable, Sendable {
        case pending
        case all
    }

    enum OutputDestination: String, Codable, Equatable, Sendable {
        case remembered
        case choose
    }

    struct OutputScopeCommitBody: Codable, Equatable, Sendable {
        let displayedProjectionRevision: Int
        let expectedSessionRevision: Int
        let outputKind: OutputKind
        let destination: OutputDestination?
        let scope: OutputScope
        let sessionId: UUID
        let sourceGeneration: Int

        init(
            displayedProjectionRevision: Int,
            expectedSessionRevision: Int,
            outputKind: OutputKind,
            destination: OutputDestination? = nil,
            scope: OutputScope,
            sessionId: UUID,
            sourceGeneration: Int
        ) {
            self.displayedProjectionRevision = displayedProjectionRevision
            self.expectedSessionRevision = expectedSessionRevision
            self.outputKind = outputKind
            self.destination = destination
            self.scope = scope
            self.sessionId = sessionId
            self.sourceGeneration = sourceGeneration
        }
    }

    struct OutputHandledClearBody: Codable, Equatable, Sendable {
        let attemptId: UUID
        let expectedSessionRevision: Int
    }
}
