import Foundation

@testable import AgentStudioCommandBar

enum StubBranchListingError: Error {
    case unavailable
}

actor StubWorktreeBranchListing: WorktreeBranchListing {
    private let result: Result<[String], StubBranchListingError>
    private(set) var requestedRepositoryIds: [UUID] = []

    init(result: Result<[String], StubBranchListingError>) {
        self.result = result
    }

    func branchNames(
        forRepositoryId repositoryId: UUID,
        repositoryPath _: URL,
        openingToken _: UUID
    ) throws -> [String] {
        requestedRepositoryIds.append(repositoryId)
        return try result.get()
    }
}

actor SequencedBranchListing: WorktreeBranchListing {
    private var queryCount = 0
    private var pending: [Int: CheckedContinuation<[String], Never>] = [:]
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func branchNames(
        forRepositoryId _: UUID,
        repositoryPath _: URL,
        openingToken _: UUID
    ) async -> [String] {
        let index = queryCount
        queryCount += 1
        let ready = arrivalWaiters.filter { $0.0 <= queryCount }
        arrivalWaiters.removeAll { $0.0 <= queryCount }
        for (_, continuation) in ready { continuation.resume() }
        return await withCheckedContinuation { pending[index] = $0 }
    }

    func awaitQueries(count: Int) async -> Int {
        if queryCount < count {
            await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
        }
        return queryCount
    }

    func answer(at index: Int, with names: [String]) {
        pending.removeValue(forKey: index)?.resume(returning: names)
    }
}
