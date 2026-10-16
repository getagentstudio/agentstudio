import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation

@testable import AgentStudioCore

actor FilesystemHeldScanProvider {
    private let steps: [HeldStep<WatchedFolderScanRequest>]
    private let results: [RepoScannerResult]
    private var sessionCount = 0

    init(steps: [HeldStep<WatchedFolderScanRequest>], results: [RepoScannerResult]) {
        precondition(steps.count == results.count)
        self.steps = steps
        self.results = results
    }

    func makeSession(request: WatchedFolderScanRequest) -> WatchedFolderScannerSessionPort {
        let ordinal = sessionCount
        sessionCount += 1
        precondition(ordinal < steps.count, "Unexpected additional filesystem scan")
        let step = steps[ordinal]
        let result = results[ordinal]
        return WatchedFolderScannerSessionPort(
            id: RepoScannerSessionID(rawValue: UUIDv7.generate()),
            advanceOneQuantum: {
                do {
                    try await step.arrive(request)
                    return .finished(result)
                } catch {
                    return .finished(failedResult())
                }
            },
            cancel: { .cancellationRequested },
            consumeValidationCompletion: { _ in .rejected(.sessionFinished) })
    }

    func makeScheduler() throws -> WatchedFolderScanScheduler {
        try WatchedFolderScanScheduler(
            maximumConcurrentScans: 1, now: { .zero },
            validationExecutor: RepoScannerValidationExecutor(validationClient: FilesystemUnusedValidationClient()),
            sessionFactory: { request, _ in await self.makeSession(request: request) })
    }
}

struct FilesystemUnusedValidationClient: RepoDiscoveryReadClient {
    func validateDiscoveryCandidate(at _: URL) async -> GitRepositoryDiscoveryOutcome {
        .failure(.serviceFailed(detail: "unexpected held filesystem scan validation"))
    }
}
