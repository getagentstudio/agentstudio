import Foundation
import GRDB

extension PaneContextService {
    package func addPullRequest(paneId: PaneId, identity: ForgePullRequestIdentity, author: PanePullRequestAuthor)
        async throws -> PanePullRequestAddResult
    {
        do {
            try await ensureOpen()
            let identity = try canonicalPullRequestIdentity(identity)
            let admission = scopeAdmission()
            let now = wallNow
            let result = try await sqliteAccess.write { database in
                guard try admission(paneId, database) else { throw PanePullRequestServiceError.paneGone }
                return try PaneContextStorage.addPullRequest(
                    database, paneId: paneId, identity: identity, author: author, now: now())
            }
            if result == .added {
                await refreshPullRequestList(paneId: paneId)
                await refreshPullRequestDemand()
            }
            return result
        } catch let error as PanePullRequestServiceError { throw error } catch {
            throw PanePullRequestServiceError.unavailable(storageFailure(error, writing: true))
        }
    }

    package func removePullRequest(paneId: PaneId, identity: ForgePullRequestIdentity, author: PanePullRequestAuthor)
        async throws -> PanePullRequestRemoveResult
    {
        try await removePullRequestContributions(paneId: paneId, identity: identity, author: author)
    }

    package func removePullRequestForPerson(paneId: PaneId, identity: ForgePullRequestIdentity)
        async throws -> PanePullRequestRemoveResult
    {
        try await removePullRequestContributions(paneId: paneId, identity: identity, author: nil)
    }

    package func listPullRequests(paneId: PaneId) async throws -> [PanePullRequestRow] {
        do {
            try await ensureOpen()
            let list = try await composePullRequestList(paneId: paneId)
            pullRequestLists[paneId] = list
            return list.rows
        } catch let error as PanePullRequestServiceError { throw error } catch {
            throw PanePullRequestServiceError.unavailable(storageFailure(error))
        }
    }

    private func removePullRequestContributions(
        paneId: PaneId, identity: ForgePullRequestIdentity, author: PanePullRequestAuthor?
    ) async throws -> PanePullRequestRemoveResult {
        do {
            try await ensureOpen()
            let identity = try canonicalPullRequestIdentity(identity)
            let admission = scopeAdmission()
            let result = try await sqliteAccess.write { database in
                guard try admission(paneId, database) else { throw PanePullRequestServiceError.paneGone }
                return try PaneContextStorage.removePullRequest(
                    database, paneId: paneId, identity: identity, author: author)
            }
            if result == .removed {
                await refreshPullRequestList(paneId: paneId)
                await refreshPullRequestDemand()
            }
            return result
        } catch let error as PanePullRequestServiceError { throw error } catch {
            throw PanePullRequestServiceError.unavailable(storageFailure(error, writing: true))
        }
    }

    private func canonicalPullRequestIdentity(_ identity: ForgePullRequestIdentity) throws -> ForgePullRequestIdentity {
        guard identity.host == "github.com" else { throw PaneContextStorageFailure.decode("pullRequest.host") }
        return try ForgePullRequestIdentity(
            host: identity.host, owner: identity.owner.lowercased(), repository: identity.repository.lowercased(),
            number: identity.number)
    }
}
