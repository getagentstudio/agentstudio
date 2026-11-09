import AgentStudioInfrastructure
import Foundation

package protocol ForgeStatusProvider: Sendable {
    func pullRequests(
        origin: String,
        demandedBranches: Set<String>
    ) async -> ForgePullRequestQueryOutcome
}

package struct ForgePullRequest: Equatable, Sendable {
    package let headRefName: String
    package let url: URL
    package let readiness: PullRequestReadiness?

    package init(
        headRefName: String,
        url: URL,
        readiness: PullRequestReadiness? = nil
    ) {
        self.headRefName = headRefName
        self.url = url
        self.readiness = readiness
    }
}

package enum ForgePullRequestQueryOutcome: Equatable, Sendable {
    case complete([ForgePullRequest])
    case truncated
    case rateLimited(retryAfterSeconds: Int?)
    case failed(message: String)
}

package struct GitHubCLIForgeStatusProvider: ForgeStatusProvider, ForgePullRequestDetailsProviding {
    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private struct GraphQLResponse: Decodable {
        let data: ResponseData

        struct ResponseData: Decodable {
            let repository: Repository?
        }

        struct Repository: Decodable {
            let connectionsByAlias: [String: PullRequestConnection]

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: DynamicCodingKey.self)
                var connections: [String: PullRequestConnection] = [:]
                for key in container.allKeys {
                    connections[key.stringValue] = try container.decode(
                        PullRequestConnection.self,
                        forKey: key
                    )
                }
                connectionsByAlias = connections
            }
        }

        struct PullRequestConnection: Decodable {
            let nodes: [PullRequestRow]
            let pageInfo: PageInfo
        }

        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
    }

    private struct PullRequestRow: Decodable {
        let headRefName: String
        let url: URL
        let isDraft: Bool?
        let reviewDecision: String?
        let mergeable: String?
        let mergeStateStatus: String?
        let statusCheckRollup: StatusCheckRollup?

        struct StatusCheckRollup: Decodable {
            let state: String
        }
    }

    private struct BranchQuery {
        let alias: String
        let branch: String
        let afterCursor: String?
        let pageCount: Int
    }

    private let processExecutor: any ProcessExecutor

    private enum FetchPageOutcome {
        case success([String: GraphQLResponse.PullRequestConnection])
        case failure(ForgePullRequestQueryOutcome)
    }

    package init(
        processExecutor: any ProcessExecutor = DefaultProcessExecutor(
            timeout: AppPolicies.ForgeRefresh.providerTimeoutSeconds
        )
    ) {
        self.processExecutor = processExecutor
    }

    package func pullRequests(
        origin: String,
        demandedBranches: Set<String>
    ) async -> ForgePullRequestQueryOutcome {
        guard let repoSlug = RemoteIdentityNormalizer.extractSlug(origin) else {
            return .failed(message: "Unsupported GitHub remote")
        }
        let slugParts = repoSlug.split(separator: "/", maxSplits: 1).map(String.init)
        guard slugParts.count == 2 else {
            return .failed(message: "Unsupported GitHub repository slug")
        }
        let branches = Set(
            demandedBranches.compactMap { branch in
                ForgePresentationFacts.normalizedBranch(branch)
            }
        ).sorted()
        guard !branches.isEmpty else { return .complete([]) }

        var pullRequestsByBranch: [String: [ForgePullRequest]] = [:]
        for batchStart in stride(
            from: 0,
            to: branches.count,
            by: AppPolicies.ForgeRefresh.maximumBranchAliasesPerBatch
        ) {
            let batchEnd = min(
                batchStart + AppPolicies.ForgeRefresh.maximumBranchAliasesPerBatch,
                branches.count
            )
            let batchBranches = Array(branches[batchStart..<batchEnd])
            var pendingQueries = batchBranches.enumerated().map { index, branch in
                BranchQuery(alias: "branch\(index)", branch: branch, afterCursor: nil, pageCount: 0)
            }

            while !pendingQueries.isEmpty {
                let pageOutcome = await fetchPage(
                    owner: slugParts[0],
                    name: slugParts[1],
                    queries: pendingQueries
                )
                switch pageOutcome {
                case .failure(let outcome):
                    return outcome
                case .success(let connectionsByAlias):
                    guard Set(connectionsByAlias.keys) == Set(pendingQueries.map { $0.alias }) else {
                        return .truncated
                    }
                    var nextQueries: [BranchQuery] = []
                    for query in pendingQueries {
                        guard let connection = connectionsByAlias[query.alias] else {
                            return .truncated
                        }
                        guard connection.nodes.allSatisfy({ $0.headRefName == query.branch }) else {
                            return .failed(message: "GitHub branch-filtered response contained another branch")
                        }
                        pullRequestsByBranch[query.branch, default: []].append(
                            contentsOf: connection.nodes.map(Self.makePullRequest)
                        )
                        guard connection.pageInfo.hasNextPage else { continue }
                        guard query.pageCount + 1 < AppPolicies.ForgeRefresh.maximumPagesPerBranch else {
                            return .truncated
                        }
                        guard let endCursor = connection.pageInfo.endCursor else {
                            return .failed(message: "GitHub pull request page omitted its end cursor")
                        }
                        nextQueries.append(
                            BranchQuery(
                                alias: query.alias,
                                branch: query.branch,
                                afterCursor: endCursor,
                                pageCount: query.pageCount + 1
                            )
                        )
                    }
                    pendingQueries = nextQueries
                }
            }
        }
        let pullRequests = branches.flatMap { pullRequestsByBranch[$0] ?? [] }
        return .complete(pullRequests)
    }

    @concurrent package func pullRequestDetails(identities: Set<ForgePullRequestIdentity>) async
        -> [ForgePullRequestIdentity: ForgePullRequestDetailsFetchResult]
    {
        await GitHubPullRequestDetailsQuery.execute(identities: identities, processExecutor: processExecutor)
    }

    private func fetchPage(
        owner: String,
        name: String,
        queries: [BranchQuery]
    ) async -> FetchPageOutcome {
        let graphQLQuery = Self.graphQLQuery(for: queries)
        var arguments = [
            "api", "graphql",
            "-f", "query=\(graphQLQuery)",
            "-F", "owner=\(owner)",
            "-F", "name=\(name)",
        ]
        for query in queries {
            arguments.append(contentsOf: ["-F", "\(query.alias)=\(query.branch)"])
            if let afterCursor = query.afterCursor {
                arguments.append(contentsOf: ["-F", "after\(query.alias.dropFirst(6))=\(afterCursor)"])
            }
        }

        let result: ProcessResult
        do {
            result = try await processExecutor.execute(
                command: "gh",
                args: arguments,
                cwd: nil,
                environment: nil
            )
        } catch {
            return .failure(.failed(message: String(describing: error)))
        }

        guard result.succeeded else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            if Self.isRateLimited(message) {
                return .failure(
                    .rateLimited(retryAfterSeconds: Self.retryAfterSeconds(in: message))
                )
            }
            return .failure(.failed(message: message))
        }
        guard let data = result.stdout.data(using: .utf8) else {
            return .failure(.failed(message: "gh output is not valid UTF-8"))
        }

        do {
            let response = try JSONDecoder().decode(GraphQLResponse.self, from: data)
            guard let repository = response.data.repository else {
                return .failure(.failed(message: "GitHub repository was not found"))
            }
            return .success(repository.connectionsByAlias)
        } catch {
            return .failure(.failed(message: "Invalid gh pull request response: \(error)"))
        }
    }

    private static func graphQLQuery(for queries: [BranchQuery]) -> String {
        let variables = queries.flatMap { query in
            ["$\(query.alias): String!", "$after\(query.alias.dropFirst(6)): String"]
        }.joined(separator: ", ")
        let connections = queries.map { query -> String in
            let cursorVariable = "after\(query.alias.dropFirst(6))"
            return """
                \(query.alias): pullRequests(
                  first: \(AppPolicies.ForgeRefresh.graphQLPageSize),
                  after: $\(cursorVariable),
                  states: OPEN,
                  headRefName: $\(query.alias)
                ) {
                  nodes {
                    headRefName
                    url
                    isDraft
                    reviewDecision
                    mergeable
                    mergeStateStatus
                    statusCheckRollup { state }
                  }
                  pageInfo { hasNextPage endCursor }
                }
                """
        }.joined(separator: "\n")
        return """
            query($owner: String!, $name: String!, \(variables)) {
              repository(owner: $owner, name: $name) {
                \(connections)
              }
            }
            """
    }

    private static func makePullRequest(_ row: PullRequestRow) -> ForgePullRequest {
        ForgePullRequest(
            headRefName: row.headRefName,
            url: row.url,
            readiness: PullRequestReadiness(
                isDraft: row.isDraft ?? false,
                checkStatus: checkStatus(row.statusCheckRollup?.state),
                reviewStatus: reviewStatus(row.reviewDecision),
                mergeability: mergeability(row.mergeable),
                mergeState: mergeState(row.mergeStateStatus)
            )
        )
    }

    static func checkStatus(_ rawValue: String?) -> PullRequestCheckStatus {
        switch rawValue {
        case "SUCCESS": .passed
        case "EXPECTED", "PENDING": .running
        case "ERROR", "FAILURE": .failed
        default: .unknown
        }
    }

    static func reviewStatus(_ rawValue: String?) -> PullRequestReviewStatus {
        switch rawValue {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: .unknown
        }
    }

    static func mergeability(_ rawValue: String?) -> PullRequestMergeability {
        switch rawValue {
        case "MERGEABLE": .mergeable
        case "CONFLICTING": .conflicting
        default: .unknown
        }
    }

    static func mergeState(_ rawValue: String?) -> PullRequestMergeState {
        switch rawValue {
        case "CLEAN": .clean
        case "BLOCKED": .blocked
        case "BEHIND": .behind
        case "DIRTY": .dirty
        case "DRAFT": .draft
        case "HAS_HOOKS": .hasHooks
        case "UNSTABLE": .unstable
        default: .unknown
        }
    }

    static func isRateLimited(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("rate limit")
    }

    static func retryAfterSeconds(in message: String) -> Int? {
        let lowercaseMessage = message.lowercased()
        guard let markerRange = lowercaseMessage.range(of: "retry-after:") else { return nil }
        let suffix = lowercaseMessage[markerRange.upperBound...].drop { $0.isWhitespace }
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }
}
