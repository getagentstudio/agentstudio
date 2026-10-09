import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation

enum WorktreeCreationCommandLineDocuments {
    struct CreatedDocument: Decodable {
        let outcome: String
        let operation: String
        let branch: BranchDocument
        let path: String
        let repository: String
        let materialization: WorktreeLargeFileCLIContract.MaterializationDocument?
        let start: StartDocument
        let fetch: FetchDocument
        let largeFiles: LargeFilesDocument?
    }

    /// LR31 `branch`.
    struct BranchDocument: Decodable, Equatable {
        let name: String
        let status: String
        let upstream: String?
    }

    /// LR31 `start`.
    struct StartDocument: Decodable, Equatable {
        let commit: String?
        let from: String
        let ref: String?
        let localOnlyCommits: Int?
    }

    /// LR30 `fetch`.
    struct FetchDocument: Decodable, Equatable {
        let remote: String?
        let branch: String?
        let status: String
        let commit: String?
        let reason: String?
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
        let alternatives: [String]?
        let options: [WorktreeStopOption]?
        let fetch: FetchDocument?
    }
}
