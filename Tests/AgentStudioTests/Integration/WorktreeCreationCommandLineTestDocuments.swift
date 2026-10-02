import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation

enum WorktreeCreationCommandLineDocuments {
    struct CreatedDocument: Decodable {
        let outcome: String
        let operation: String
        let branch: String
        let path: String
        let repository: String
        let materialization: WorktreeLargeFileCLIContract.MaterializationDocument?
        let largeFiles: LargeFilesDocument?
    }

    struct LargeFilesDocument: Decodable {
        let materialized: Int
        let missing: [GitLargeFileFillMiss]
        let missingCount: Int
        let options: [String]?
        let scan: WorktreeLargeFileCLIContract.ScanDocument
    }

    struct RefusedDocument: Decodable {
        let outcome: String
        let reason: String
        let path: String?
        let detail: String?
        let alternative: String?
        let options: [WorktreeStopOption]?
    }
}
