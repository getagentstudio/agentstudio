import AgentStudioInfrastructure
import Foundation
import GRDB

extension PaneContextStorage {
    private static let pullRequestScope = "pane_id = ? AND host = ? AND owner = ? AND repository = ? AND number = ?"

    private static func pullRequestArguments(paneId: PaneId, identity: ForgePullRequestIdentity) -> StatementArguments {
        [paneId.uuidString, identity.host, identity.owner, identity.repository, identity.number]
    }

    static func addPullRequest(
        _ database: Database, paneId: PaneId, identity: ForgePullRequestIdentity, author: PanePullRequestAuthor,
        now: Date
    ) throws -> PanePullRequestAddResult {
        let arguments = pullRequestArguments(paneId: paneId, identity: identity)
        let exists =
            try Bool.fetchOne(
                database, sql: "SELECT EXISTS(SELECT 1 FROM pane_pull_request WHERE \(pullRequestScope))",
                arguments: arguments) == true
        if !exists {
            let count =
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM pane_pull_request WHERE pane_id = ?",
                    arguments: [paneId.uuidString]) ?? 0
            guard count < AppPolicies.PaneContext.maximumPullRequests else { return .paneFull }
            try database.execute(
                sql: "INSERT INTO pane_pull_request VALUES (?, ?, ?, ?, ?, ?)",
                arguments: arguments + [try timestamp(now)])
        }
        let authorKey = PanePullRequestAuthorKeyCodec.encode(author)
        try database.execute(
            sql: "INSERT OR IGNORE INTO pane_pull_request_contribution VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: arguments + [authorKey, try timestamp(now)])
        guard database.changesCount > 0 else { return .alreadyPresent }
        try bumpRevision(database, paneId: paneId)
        return .added
    }

    static func removePullRequest(
        _ database: Database, paneId: PaneId, identity: ForgePullRequestIdentity, author: PanePullRequestAuthor?
    ) throws -> PanePullRequestRemoveResult {
        let arguments = pullRequestArguments(paneId: paneId, identity: identity)
        guard
            try Bool.fetchOne(
                database, sql: "SELECT EXISTS(SELECT 1 FROM pane_pull_request WHERE \(pullRequestScope))",
                arguments: arguments) == true
        else { return .notOnPane }
        if let author {
            try database.execute(
                sql: "DELETE FROM pane_pull_request_contribution WHERE \(pullRequestScope) AND author_key = ?",
                arguments: arguments + [PanePullRequestAuthorKeyCodec.encode(author)])
        } else {
            try database.execute(
                sql: "DELETE FROM pane_pull_request_contribution WHERE \(pullRequestScope)", arguments: arguments)
        }
        guard database.changesCount > 0 else { return .addedBySomeoneElse }
        let hasContributions =
            try Bool.fetchOne(
                database, sql: "SELECT EXISTS(SELECT 1 FROM pane_pull_request_contribution WHERE \(pullRequestScope))",
                arguments: arguments) == true
        if !hasContributions {
            try database.execute(sql: "DELETE FROM pane_pull_request WHERE \(pullRequestScope)", arguments: arguments)
        }
        try bumpRevision(database, paneId: paneId)
        return .removed
    }

    static func pullRequests(_ database: Database, paneId: PaneId) throws -> [PanePullRequestRecord] {
        try Row.fetchAll(
            database,
            sql:
                "SELECT * FROM pane_pull_request WHERE pane_id = ? ORDER BY created_at DESC, host, owner, repository, number",
            arguments: [paneId.uuidString]
        ).map { row in
            let identity = try ForgePullRequestIdentity(
                host: required(row, "host"), owner: required(row, "owner"), repository: required(row, "repository"),
                number: required(row, "number"))
            let contributions = try Row.fetchAll(
                database,
                sql:
                    "SELECT author_key, created_at FROM pane_pull_request_contribution WHERE \(pullRequestScope) ORDER BY created_at, author_key",
                arguments: pullRequestArguments(paneId: paneId, identity: identity)
            ).map { contribution in
                PanePullRequestContribution(
                    author: try PanePullRequestAuthorKeyCodec.decode(required(contribution, "author_key")),
                    createdAt: try date(contribution, "created_at"))
            }
            guard !contributions.isEmpty else { throw PaneContextStorageFailure.decode("pullRequest.contributions") }
            return PanePullRequestRecord(
                identity: identity, createdAt: try date(row, "created_at"), contributions: contributions)
        }
    }
}
