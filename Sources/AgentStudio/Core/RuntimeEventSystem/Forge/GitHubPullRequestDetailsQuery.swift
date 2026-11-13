import AgentStudioInfrastructure
import Foundation

enum GitHubPullRequestDetailsQuery {
    private struct PullRequestRow: Decodable {
        let title: String
        let state: String
        let isDraft: Bool
        let reviewDecision: String?
        let mergeable: String?
        let mergeStateStatus: String?
        let statusCheckRollup: Rollup?
        let updatedAt: Date
        let url: URL
        struct Rollup: Decodable { let state: String }
    }

    private enum RowValue {
        case missing
        case malformed
        case loaded(PullRequestRow)
    }

    private struct RepositoryValue: Decodable {
        let row: RowValue
        private enum CodingKeys: String, CodingKey { case pullRequest }
        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self), container.contains(.pullRequest)
            else {
                row = .malformed
                return
            }
            if (try? container.decodeNil(forKey: .pullRequest)) == true {
                row = .missing
                return
            }
            do { row = .loaded(try container.decode(PullRequestRow.self, forKey: .pullRequest)) } catch {
                row = .malformed
            }
        }
    }

    private enum PathElement: Decodable {
        case key(String)
        case index(Int)
        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let key = try? value.decode(String.self) {
                self = .key(key)
            } else {
                self = .index(try value.decode(Int.self))
            }
        }
        var key: String? { if case .key(let key) = self { key } else { nil } }
    }

    private struct QueryError: Decodable {
        let type: String?
        let path: [PathElement]?
    }
    private struct Response: Decodable {
        let data: [String: RepositoryValue?]?
        let errors: [QueryError]?
    }

    static func execute(identities: Set<ForgePullRequestIdentity>, processExecutor: any ProcessExecutor) async
        -> [ForgePullRequestIdentity: ForgePullRequestDetailsFetchResult]
    {
        let ordered = identities.filter { $0.host == "github.com" }.sorted {
            if $0.host != $1.host { return $0.host < $1.host }
            if $0.owner != $1.owner { return $0.owner < $1.owner }
            if $0.repository != $1.repository { return $0.repository < $1.repository }
            return $0.number < $1.number
        }
        var results = Dictionary(
            uniqueKeysWithValues: identities.filter { $0.host != "github.com" }.map {
                ($0, ForgePullRequestDetailsFetchResult.failed(.failed))
            })
        for start in stride(from: 0, to: ordered.count, by: AppPolicies.ForgeRefresh.maximumBranchAliasesPerBatch) {
            let batch = Array(
                ordered[start..<min(ordered.count, start + AppPolicies.ForgeRefresh.maximumBranchAliasesPerBatch)])
            let fetched = await fetch(batch: batch, processExecutor: processExecutor)
            results.merge(fetched) { _, latest in latest }
        }
        return results
    }

    private static func fetch(batch: [ForgePullRequestIdentity], processExecutor: any ProcessExecutor) async
        -> [ForgePullRequestIdentity: ForgePullRequestDetailsFetchResult]
    {
        var arguments = ["api", "graphql", "-f", "query=\(query(aliasCount: batch.count))"]
        for (index, identity) in batch.enumerated() {
            arguments += [
                "-f", "owner\(index)=\(identity.owner)", "-f", "repository\(index)=\(identity.repository)", "-F",
                "number\(index)=\(identity.number)",
            ]
        }
        let process: ProcessResult
        do {
            process = try await processExecutor.execute(command: "gh", args: arguments, cwd: nil, environment: nil)
        } catch {
            let failure: ForgePullRequestDetailsFailure = error is ProcessError ? .offline : .failed
            return Dictionary(uniqueKeysWithValues: batch.map { ($0, .failed(failure)) })
        }
        let fallback = failure(message: process.stderr)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(Response.self, from: Data(process.stdout.utf8)) else {
            return Dictionary(uniqueKeysWithValues: batch.map { ($0, .failed(fallback)) })
        }
        return Dictionary(
            uniqueKeysWithValues: batch.enumerated().map { index, identity in
                let alias = "pr\(index)"
                let errors = (response.errors ?? []).filter { $0.path?.first?.key == alias || $0.path == nil }
                if let error = errors.first {
                    return (identity, .failed(failure(error: error, message: process.stderr)))
                }
                guard let repositories = response.data, let value = repositories[alias], let repository = value else {
                    let reason: ForgePullRequestDetailsFailure =
                        response.data?.keys.contains(alias) == true ? .notFound : fallback
                    return (identity, .failed(reason))
                }
                switch repository.row {
                case .missing: return (identity, .failed(.notFound))
                case .malformed: return (identity, .failed(.failed))
                case .loaded(let row):
                    guard let details = details(row) else { return (identity, .failed(.failed)) }
                    return (identity, .loaded(details))
                }
            })
    }

    private static func query(aliasCount: Int) -> String {
        let variables = (0..<aliasCount).flatMap {
            ["$owner\($0): String!", "$repository\($0): String!", "$number\($0): Int!"]
        }.joined(separator: ", ")
        let aliases = (0..<aliasCount).map { index in
            """
            pr\(index): repository(owner: $owner\(index), name: $repository\(index)) {
              pullRequest(number: $number\(index)) {
                title state isDraft reviewDecision mergeable mergeStateStatus
                statusCheckRollup { state }
                updatedAt url
              }
            }
            """
        }.joined(separator: "\n")
        return "query(\(variables)) {\n\(aliases)\n}"
    }

    private static func details(_ row: PullRequestRow) -> ForgePullRequestDetails? {
        let state: ForgePullRequestState
        switch row.state {
        case "OPEN": state = row.isDraft ? .draft : .open
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: return nil
        }
        return .init(
            title: row.title, state: state,
            readiness: .init(
                isDraft: row.isDraft,
                checkStatus: GitHubCLIForgeStatusProvider.checkStatus(row.statusCheckRollup?.state),
                reviewStatus: GitHubCLIForgeStatusProvider.reviewStatus(row.reviewDecision),
                mergeability: GitHubCLIForgeStatusProvider.mergeability(row.mergeable),
                mergeState: GitHubCLIForgeStatusProvider.mergeState(row.mergeStateStatus)),
            updatedAt: row.updatedAt, url: row.url)
    }

    private static func failure(error: QueryError, message: String) -> ForgePullRequestDetailsFailure {
        switch error.type?.uppercased() {
        case "NOT_FOUND": .notFound
        case "FORBIDDEN", "UNAUTHORIZED", "INSUFFICIENT_SCOPES": .noAccess
        case "RATE_LIMITED":
            .rateLimited(retryAfterSeconds: GitHubCLIForgeStatusProvider.retryAfterSeconds(in: message))
        default: failure(message: message)
        }
    }

    private static func failure(message: String) -> ForgePullRequestDetailsFailure {
        if GitHubCLIForgeStatusProvider.isRateLimited(message) {
            return .rateLimited(retryAfterSeconds: GitHubCLIForgeStatusProvider.retryAfterSeconds(in: message))
        }
        let text = message.lowercased()
        if ["http 401", "http 403", "bad credentials", "forbidden", "resource not accessible", "gh auth login"]
            .contains(
                where: text.contains)
        {
            return .noAccess
        }
        if text.contains("could not resolve to") || text.contains("http 404") { return .notFound }
        if ["error connecting", "could not resolve host", "network is unreachable", "dial tcp", "offline"].contains(
            where: text.contains)
        {
            return .offline
        }
        return .failed
    }
}
