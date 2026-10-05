import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

struct InertSchedulerValidationDeadline: RepoDiscoveryDeadlineScheduler {
    func scheduleDeadline(
        after duration: Duration,
        _ handler: @escaping @Sendable () -> Void
    ) -> RepoDiscoveryScheduledDeadline {
        RepoDiscoveryScheduledDeadline(cancel: {})
    }
}

struct ValidationSchedulerFixture {
    let validationClient = ControlledSchedulerValidationClient()
    let consumer = WatchedFolderScanResultConsumerToken.make()
    let scheduler: WatchedFolderScanScheduler
    let validationFacts: LocalFactSource<WatchedFolderScanValidationScope, WatchedFolderScanSchedulerFact>
    let facts: FactRecorder<WatchedFolderScanValidationScope, WatchedFolderScanSchedulerFact>

    init(
        maximumConcurrentScans: Int,
        validationBudget: RepoDiscoveryValidationBudget = .productionDefault,
        validationAdmissionAdapter: (
            @Sendable (RepoScannerValidationExecutor, RepoDiscoveryValidationRequest) async ->
                RepoDiscoveryValidationAdmissionResult
        )? = nil,
        validationCompletionSink: (@Sendable (FSEventRegistrationToken, GitRepositoryDiscoveryOutcome) -> Void)? = nil,
        schedulerFactObserver: WatchedFolderScanSchedulerFactSink? = nil,
        sessionFactoryObservation: (@Sendable (WatchedFolderScanRequest, UInt64) async -> Void)? = nil
    ) throws {
        let validationClient = self.validationClient
        let validationFacts = LocalFactSource<WatchedFolderScanValidationScope, WatchedFolderScanSchedulerFact>(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) },
                describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .validationSettled = fact { return true }
                    return false
                }
            )
        )
        self.validationFacts = validationFacts
        facts = try validationFacts.attach()
        let executor = try RepoScannerValidationExecutor(
            validationClient: validationClient,
            deadlineScheduler: InertSchedulerValidationDeadline(),
            budget: validationBudget
        )
        scheduler = try WatchedFolderScanScheduler(
            maximumConcurrentScans: maximumConcurrentScans,
            now: { .zero },
            validationExecutor: executor,
            factSink: { scope, fact in
                schedulerFactObserver?(scope, fact)
                // Lifecycle observations have their own shutdown operation in tests.
                switch fact {
                case .validationParked, .validationResubmitted, .validationSettled:
                    validationFacts.sink(scope, fact)
                case .shutdownAwaitingAdmission, .validationDiscardedDuringShutdown:
                    break
                }
            },
            validationAdmissionSubmitter: { request in
                if let validationAdmissionAdapter {
                    return await validationAdmissionAdapter(executor, request)
                }
                return await executor.submit(request)
            },
            sessionFactory: { request, scanRunGeneration in
                await sessionFactoryObservation?(request, scanRunGeneration)
                let rootURL = URL(
                    fileURLWithPath: request.canonicalRoot.aliases.onceResolvedCanonical.path,
                    isDirectory: true
                )
                let scannerPort = RepoScanner().makeSession(
                    in: rootURL,
                    serviceClock: TestPushClock()
                )
                return WatchedFolderScannerSessionPort(
                    id: scannerPort.id,
                    advanceOneQuantum: scannerPort.advanceOneQuantum,
                    cancel: scannerPort.cancel,
                    consumeValidationCompletion: { completion in
                        validationCompletionSink?(request.canonicalRoot.registration, completion.outcome)
                        return scannerPort.consumeValidationCompletion(completion)
                    }
                )
            }
        )
    }

    func expectParkedValidation(
        for request: WatchedFolderScanRequest, scanRunGeneration: UInt64
    ) async throws -> WatchedFolderScanValidationScope {
        let scope = try await facts.expectNextOperation(
            matching: {
                $0.registration == request.canonicalRoot.registration
                    && $0.scanRunGeneration == scanRunGeneration
            },
            opening: { $0 == .validationParked },
            "replacement validation parked waiting for stale physical drain"
        )
        try await facts.expectNext(in: scope, .validationParked)
        return scope
    }

    func makeRequest(
        name: String,
        containsGitMarker: Bool,
        sourceID: FilesystemSourceID? = nil,
        registrationGeneration: UInt64 = 1,
        rootURL: URL? = nil
    ) throws -> WatchedFolderScanRequest {
        let rootURL =
            rootURL
            ?? FileManager.default.temporaryDirectory.appending(
                path: "scheduler-validation-\(name)-\(UUIDv7.generate())",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if containsGitMarker {
            try FileManager.default.createDirectory(
                at: rootURL.appending(path: ".git", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        let sourceID =
            sourceID
            ?? FilesystemSourceID(kind: .watchedParentMembership, rootID: UUIDv7.generate())
        let descriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                FilesystemHostAuthorizedRootInput(
                    registration: FSEventRegistrationToken(
                        sourceID: sourceID,
                        registrationGeneration: registrationGeneration,
                        rootGeneration: 1
                    ),
                    authorizedBoundary: rootURL,
                    registeredRoot: rootURL
                )
            )
        )
        return WatchedFolderScanRequest(canonicalRoot: descriptor, cause: .manual)
    }

    func nextLease() async throws -> WatchedFolderScanResultLease {
        _ = await scheduler.bindResultConsumer(consumer)
        guard case .leased(let lease) = await scheduler.nextResultLease(for: consumer) else {
            Issue.record("expected scheduled result lease")
            throw ValidationSchedulerTestError.expectedLease
        }
        return lease
    }

    func transfer(
        _ lease: WatchedFolderScanResultLease
    ) async -> WatchedFolderScanResultLeaseResolutionResult {
        await scheduler.resolveResultLease(
            for: consumer,
            leaseID: lease.leaseID,
            resolution: .transferred
        )
    }

}

enum ValidationSchedulerTestError: Error {
    case expectedLease
}
