import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge development product host shared construction")
struct BridgeDevHostSharedConstructionTests {
    @Test("initial and explicit-target publications omit same-source refresh classification")
    func initialAndExplicitTargetPublicationsOmitRefreshClassification() async throws {
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-unclassified-publications"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let provider = BridgeDevelopmentSharedConstructionReviewProvider()
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: worktreeRoot),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )

        try await withShutdownDevelopmentProductHost(host) {
            _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
            let initialPublication = try #require(await host.diagnosticCommittedReviewPublication())
            #expect(initialPublication.classifiedRefreshImpact == nil)

            let productAdmission = await host.productAdmission
            await admitDevelopmentReviewComparisonIntent(
                host: host,
                workerDerivationEpoch: 1,
                productAdmission: productAdmission
            )
            await host.applyCommittedReviewComparisonUpdate(
                BridgeProductReviewComparisonUpdateRequest(target: .branch(name: "stack/base")),
                workerDerivationEpoch: 1,
                productAdmission: productAdmission
            )
            let comparisonTask = await host.activeReviewComparisonTask
            await comparisonTask?.value

            let explicitTargetPublication = try #require(await host.diagnosticCommittedReviewPublication())
            #expect(explicitTargetPublication.package.reviewGeneration == 2)
            #expect(explicitTargetPublication.classifiedRefreshImpact == nil)
            #expect(await provider.snapshot().refreshImpactRequestCount == 0)
        }
    }

    @Test("observed worktree refresh publishes existing provider classification")
    func observedWorktreeRefreshPublishesProviderClassification() async throws {
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-classified-observed-refresh"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let provider = BridgeDevelopmentSharedConstructionReviewProvider(
            changedFiles: [
                makeBridgeEndpointChangedFile(
                    fileId: "reviewed-file",
                    path: "tracked.txt",
                    sizeBytes: 100,
                    newContentHash: "sha256:initial"
                )
            ]
        )
        let source = makeDevelopmentProductSource(worktreeRoot: worktreeRoot)
        let host = try await BridgeDevelopmentProductHost(
            source: source,
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )

        try await withShutdownDevelopmentProductHost(host) {
            _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
            let displayedPublication = try #require(await host.diagnosticCommittedReviewPublication())
            let coordinator = await host.reviewPublicationCoordinator
            let productAdmission = await host.productAdmission
            let workerInstanceId = "development-refresh-classification-worker"
            let admission = await coordinator.admitDisplayInstallation(
                expectedDisplayedPublicationId: nil,
                candidatePublicationId: displayedPublication.publicationId,
                workerInstanceId: workerInstanceId,
                productAdmission: productAdmission
            )
            #expect(admission == .admitted)
            let application = await coordinator.recordDisplayedApplication(
                publicationId: displayedPublication.publicationId,
                workerInstanceId: workerInstanceId,
                productAdmission: productAdmission
            )
            #expect(application == .advanced)
            await provider.setChangedFiles([
                makeBridgeEndpointChangedFile(
                    fileId: "reviewed-file",
                    path: "tracked.txt",
                    sizeBytes: 101,
                    newContentHash: "sha256:successor"
                )
            ])

            await host.handleObservedWorktreeInvalidation(
                developmentFileInvalidation(source: source, batchSequence: 1)
            )
            let refreshTask = await host.activeReviewComparisonTask
            await refreshTask?.value

            let refreshedPublication = try #require(await host.diagnosticCommittedReviewPublication())
            #expect(refreshedPublication.package.reviewGeneration == displayedPublication.package.reviewGeneration)
            #expect(refreshedPublication.package.packageId == displayedPublication.package.packageId)
            #expect(refreshedPublication.package.query.queryId == displayedPublication.package.query.queryId)
            #expect(refreshedPublication.package.revision == displayedPublication.package.revision + 1)
            #expect(refreshedPublication.package.baseEndpoint == displayedPublication.package.baseEndpoint)
            #expect(refreshedPublication.package.headEndpoint == displayedPublication.package.headEndpoint)
            let delta = try #require(refreshedPublication.delta)
            #expect(delta.revision == refreshedPublication.package.revision)
            #expect(delta.reviewGeneration == displayedPublication.package.reviewGeneration)
            #expect(delta.operations.updateItems.count == 1)
            #expect(refreshedPublication.classifiedRefreshImpact == .developmentHostTestImpact)
            let providerSnapshot = await provider.snapshot()
            #expect(providerSnapshot.refreshImpactRequestCount == 1)
            #expect(providerSnapshot.reviewGenerationValues == [1, 1])
            #expect(providerSnapshot.reviewAttemptAuthorityGenerations[1] > 0)
            #expect(providerSnapshot.gitRefreshScopes[1] == .exactPaths(["tracked.txt"]))
        }
    }

    @Test("committed comparison update acknowledges before its publication is delivered")
    func committedComparisonUpdateAcknowledgesBeforePublicationDelivery() async throws {
        // Arrange
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-comparison-update"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let provider = BridgeDevelopmentSharedConstructionReviewProvider()
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: worktreeRoot),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )
        try await withShutdownDevelopmentProductHost(host) {
            _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
            let initialPresentation = await host.diagnosticPanePresentation()
            guard
                case .current(let initialDisplayedSnapshot) =
                    initialPresentation.reviewComparison?.displayedSnapshot
            else {
                Issue.record("Expected an initial committed Review snapshot")
                return
            }
            let comparisonGate = BridgeComparisonGate()
            await provider.setComparisonGate(comparisonGate)
            let completionRecorder = BridgeComparisonUpdateCompletionRecorder()
            let productAdmission = await host.productAdmission
            let updatedTarget = WorkspaceReviewContributionTarget.branch(name: "stack/base")
            await admitDevelopmentReviewComparisonIntent(
                host: host,
                workerDerivationEpoch: 1,
                productAdmission: productAdmission
            )
            let update = Task {
                await host.applyCommittedReviewComparisonUpdate(
                    BridgeProductReviewComparisonUpdateRequest(target: updatedTarget),
                    workerDerivationEpoch: 1,
                    productAdmission: productAdmission
                )
                await completionRecorder.recordCompletion()
            }
            await comparisonGate.waitForStartedComparisonCount(1)
            await completionRecorder.waitForCompletion()

            // Act
            let pendingPresentation = await host.diagnosticPanePresentation()
            let canonicalPaneState = await host.paneState
            let canonicalTarget: WorkspaceReviewContributionTarget?
            if case .workspace(_, let canonicalBaseline)? = canonicalPaneState.source {
                canonicalTarget = canonicalBaseline?.contributionTarget
            } else {
                canonicalTarget = nil
            }

            // Assert
            #expect(await completionRecorder.isComplete)
            #expect(canonicalTarget == updatedTarget)
            #expect(pendingPresentation.reviewComparison?.activeTarget == updatedTarget)
            #expect(pendingPresentation.reviewComparison?.attempt == .pending(reviewGeneration: 2))
            #expect(
                pendingPresentation.reviewComparison?.displayedSnapshot
                    == .stale(initialDisplayedSnapshot)
            )

            await comparisonGate.releaseAll()
            await update.value
            let reviewComparisonTask = await host.activeReviewComparisonTask
            await reviewComparisonTask?.value

            let settledPresentation = await host.diagnosticPanePresentation()
            let activePublication = await host.diagnosticCommittedReviewPublication()
            let providerSnapshot = await provider.snapshot()
            #expect(await completionRecorder.isComplete)
            #expect(activePublication?.package.reviewGeneration == 2)
            #expect(activePublication?.package.packageId != initialDisplayedSnapshot.packageId)
            #expect(settledPresentation.reviewComparison?.activeTarget == updatedTarget)
            #expect(settledPresentation.reviewComparison?.attempt == .settled(reviewGeneration: 2))
            #expect(
                settledPresentation.reviewComparison?.displayedSnapshot
                    == .current(
                        BridgePaneReviewDisplayedSnapshotIdentity(
                            packageId: activePublication?.package.packageId ?? "",
                            reviewGeneration: 2,
                            revision: activePublication?.package.revision ?? 0
                        )
                    )
            )
            #expect(providerSnapshot.contributionTargets == [.ref(name: "HEAD"), updatedTarget])
            #expect(providerSnapshot.reviewGenerationValues == [1, 2])
        }
    }

    @Test("a newer comparison update supersedes the host-owned publication task")
    func newerComparisonUpdateSupersedesPublicationTask() async throws {
        // Arrange
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-comparison-supersede"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let provider = BridgeDevelopmentSharedConstructionReviewProvider()
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: worktreeRoot),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )
        try await withShutdownDevelopmentProductHost(host) {
            _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
            let comparisonGate = BridgeComparisonGate()
            await provider.setComparisonGate(comparisonGate)
            let productAdmission = await host.productAdmission
            let supersededTarget = WorkspaceReviewContributionTarget.branch(name: "stack/first")
            let currentTarget = WorkspaceReviewContributionTarget.branch(name: "stack/second")

            // Act
            await admitDevelopmentReviewComparisonIntent(
                host: host,
                workerDerivationEpoch: 2,
                productAdmission: productAdmission
            )
            await host.applyCommittedReviewComparisonUpdate(
                BridgeProductReviewComparisonUpdateRequest(target: supersededTarget),
                workerDerivationEpoch: 2,
                productAdmission: productAdmission
            )
            await comparisonGate.waitForStartedComparisonCount(1)
            await admitDevelopmentReviewComparisonIntent(
                host: host,
                workerDerivationEpoch: 3,
                productAdmission: productAdmission
            )
            await host.applyCommittedReviewComparisonUpdate(
                BridgeProductReviewComparisonUpdateRequest(target: currentTarget),
                workerDerivationEpoch: 3,
                productAdmission: productAdmission
            )
            await comparisonGate.waitForStartedComparisonCount(2)
            await comparisonGate.releaseAll()
            let reviewComparisonTask = await host.activeReviewComparisonTask
            await reviewComparisonTask?.value

            // Assert
            let settledPresentation = await host.diagnosticPanePresentation()
            let activePublication = await host.diagnosticCommittedReviewPublication()
            #expect(settledPresentation.reviewComparison?.activeTarget == currentTarget)
            #expect(settledPresentation.reviewComparison?.attempt == .settled(reviewGeneration: 3))
            #expect(activePublication?.package.reviewGeneration == 3)
            #expect(
                await provider.snapshot().contributionTargets
                    == [.ref(name: "HEAD"), supersededTarget, currentTarget]
            )
        }
    }

    @Test("source invalidations supersede the development Review publication task")
    func sourceInvalidationsSupersedeDevelopmentReviewPublicationTask() async throws {
        // Arrange
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-source-refresh"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let provider = BridgeDevelopmentSharedConstructionReviewProvider()
        let source = makeDevelopmentProductSource(worktreeRoot: worktreeRoot)
        let host = try await BridgeDevelopmentProductHost(
            source: source,
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )
        try await withShutdownDevelopmentProductHost(host) {
            _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
            let comparisonGate = BridgeComparisonGate()
            await provider.setComparisonGate(comparisonGate)

            // Act
            await host.handleObservedWorktreeInvalidation(
                developmentFileInvalidation(source: source, batchSequence: 10)
            )
            await comparisonGate.waitForStartedComparisonCount(1)
            await host.handleObservedWorktreeInvalidation(
                developmentFileInvalidation(source: source, batchSequence: 11)
            )
            await comparisonGate.waitForStartedComparisonCount(2)
            await comparisonGate.releaseAll()
            let reviewTask = await host.activeReviewComparisonTask
            await reviewTask?.value
            let didDrainRetiringTasks = await waitForRetiringReviewTasksToDrain(host)

            // Assert
            let publication = await host.diagnosticCommittedReviewPublication()
            let requests = await provider.snapshot()
            #expect(publication?.package.reviewGeneration == 1)
            #expect(requests.reviewGenerationValues == [1, 1, 1])
            #expect(requests.reviewAttemptAuthorityGenerations.count == 3)
            #expect(
                zip(
                    requests.reviewAttemptAuthorityGenerations,
                    requests.reviewAttemptAuthorityGenerations.dropFirst()
                ).allSatisfy { $0 < $1 }
            )
            #expect(didDrainRetiringTasks)
        }
    }

    @Test("shutdown cancels and drains the host-owned comparison publication task")
    func shutdownCancelsAndDrainsComparisonPublicationTask() async throws {
        // Arrange
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-comparison-shutdown"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let source = makeDevelopmentProductSource(worktreeRoot: worktreeRoot)
        let factSource = makeDevelopmentProductHostShutdownFactSource()
        let facts = try factSource.attach()
        let shutdownScope = BridgeDevelopmentProductHostFactScope(paneID: source.paneID)
        let provider = BridgeDevelopmentSharedConstructionReviewProvider()
        let host = try await BridgeDevelopmentProductHost(
            source: source,
            shutdownFactSink: factSource.sink,
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )
        _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
        let comparisonGate = BridgeComparisonGate()
        await provider.setComparisonGate(comparisonGate)
        let productAdmission = await host.productAdmission
        await admitDevelopmentReviewComparisonIntent(
            host: host,
            workerDerivationEpoch: 1,
            productAdmission: productAdmission
        )
        await host.applyCommittedReviewComparisonUpdate(
            BridgeProductReviewComparisonUpdateRequest(target: .branch(name: "stack/base")),
            workerDerivationEpoch: 1,
            productAdmission: productAdmission
        )
        await comparisonGate.waitForStartedComparisonCount(1)

        // Act
        let shutdown = Task { await host.shutdown() }
        do {
            try await facts.expectNext(in: shutdownScope, .shutdownStarted)
        } catch {
            await comparisonGate.releaseAll()
            _ = await shutdown.value
            throw error
        }
        #expect(await host.isShutdown)
        await comparisonGate.releaseAll()
        let shutdownResult = await shutdown.value
        try await facts.expectNext(in: shutdownScope, .shutdownResolved(shutdownResult))

        // Assert
        #expect(
            await host.diagnosticPanePresentation().reviewComparison?.attempt
                == .unavailable(failureKind: "publication_failed", retryable: true)
        )
        #expect(await host.activeReviewComparisonTask == nil)
        factSource.end()
        try await facts.finish()
    }

    @Test("shutdown fact contract reports entry and resolution")
    func shutdownFactContractReportsEntryAndResolution() async throws {
        // Arrange
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-shutdown-fact-contract"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let source = makeDevelopmentProductSource(worktreeRoot: worktreeRoot)
        let factSource = makeDevelopmentProductHostShutdownFactSource()
        let facts = try factSource.attach()
        let scope = BridgeDevelopmentProductHostFactScope(paneID: source.paneID)
        let provider = BridgeDevelopmentSharedConstructionReviewProvider()
        let host = try await BridgeDevelopmentProductHost(
            source: source,
            shutdownFactSink: factSource.sink,
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )

        // Act
        let shutdownResult = await host.shutdown()

        // Assert
        try await facts.expectNext(in: scope, .shutdownStarted)
        try await facts.expectNext(in: scope, .shutdownResolved(shutdownResult))
        factSource.end()
        try await facts.finish()
    }

    @Test("detected observation terminal retains the last complete Review publication")
    func detectedObservationTerminalRetainsLastCompleteReviewPublication() async throws {
        // Arrange
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-observation-terminal"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let provider = BridgeDevelopmentSharedConstructionReviewProvider()
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: worktreeRoot),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )
        try await withShutdownDevelopmentProductHost(host) {
            _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
            let initialPublication = try #require(
                await host.diagnosticCommittedReviewPublication()
            )

            // Act
            await host.handleObservedWorktreeTerminal()

            // Assert
            let presentation = await host.diagnosticPanePresentation()
            let retainedPublication = await host.diagnosticCommittedReviewPublication()
            #expect(presentation.fileRefreshFailure?.failureKind == .fileRefreshFailed)
            #expect(presentation.fileRefreshFailure?.retryable == false)
            #expect(
                presentation.reviewComparison?.attempt
                    == .unavailable(failureKind: "observation_terminal", retryable: false)
            )
            #expect(retainedPublication?.publicationId == initialPublication.publicationId)
        }
    }

    @Test("initial Review bootstrap settles presentation for the restored symbolic target")
    func initialReviewBootstrapSettlesRestoredTargetPresentation() async throws {
        // Arrange
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-initial-presentation"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let repositoryDefaultTarget = BridgeReviewComparisonDefaultTargetIdentity(
            remoteName: "origin",
            branchName: "main"
        )
        let provider = BridgeDevelopmentSharedConstructionReviewProvider(
            repositoryDefaultTarget: repositoryDefaultTarget
        )
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: worktreeRoot),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )
        try await withShutdownDevelopmentProductHost(host) {
            // Act
            _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
            let presentation = await host.diagnosticPanePresentation()

            // Assert
            #expect(presentation.reviewComparison?.activeTarget == .ref(name: "HEAD"))
            #expect(presentation.reviewComparison?.attempt == .settled(reviewGeneration: 1))
            #expect(presentation.reviewComparison?.repositoryDefaultTarget == repositoryDefaultTarget)
            #expect(await provider.snapshot().reviewComparisonTargetReadCount == 1)
            guard case .current(let displayedSnapshot) = presentation.reviewComparison?.displayedSnapshot else {
                Issue.record("Expected the initial package to become the displayed comparison snapshot")
                return
            }
            #expect(displayedSnapshot.reviewGeneration == 1)
        }
    }

    @Test("successor comparison clears and refreshes repository default identity")
    func successorComparisonClearsAndRefreshesRepositoryDefaultIdentity() async throws {
        // Arrange
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-default-refresh"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let initialDefaultTarget = BridgeReviewComparisonDefaultTargetIdentity(
            remoteName: "origin",
            branchName: "main"
        )
        let successorDefaultTarget = BridgeReviewComparisonDefaultTargetIdentity(
            remoteName: "upstream",
            branchName: "trunk"
        )
        let provider = BridgeDevelopmentSharedConstructionReviewProvider(
            repositoryDefaultTarget: initialDefaultTarget
        )
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: worktreeRoot),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )
        try await withShutdownDevelopmentProductHost(host) {
            _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
            let defaultTargetGate = BridgeComparisonGate()
            await provider.setRepositoryDefaultTarget(successorDefaultTarget)
            await provider.setDefaultTargetGate(defaultTargetGate)
            let productAdmission = await host.productAdmission

            // Act
            await admitDevelopmentReviewComparisonIntent(
                host: host,
                workerDerivationEpoch: 1,
                productAdmission: productAdmission
            )
            await host.applyCommittedReviewComparisonUpdate(
                BridgeProductReviewComparisonUpdateRequest(
                    target: .branch(name: "stack/base")
                ),
                workerDerivationEpoch: 1,
                productAdmission: productAdmission
            )
            await defaultTargetGate.waitForStartedComparisonCount(1)
            let pendingPresentation = await host.diagnosticPanePresentation()
            await defaultTargetGate.releaseAll()
            let reviewComparisonTask = await host.activeReviewComparisonTask
            await reviewComparisonTask?.value
            let settledPresentation = await host.diagnosticPanePresentation()

            // Assert
            #expect(
                pendingPresentation.reviewComparison?.repositoryDefaultTarget
                    == initialDefaultTarget
            )
            #expect(
                settledPresentation.reviewComparison?.repositoryDefaultTarget
                    == successorDefaultTarget
            )
            #expect(await provider.snapshot().reviewComparisonTargetReadCount == 2)
        }
    }

    @Test("Review bootstrap uses the existing shared construction authority")
    func reviewBootstrapUsesSharedConstructionAuthority() async throws {
        // Arrange
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-shared-review"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let provider = BridgeDevelopmentSharedConstructionReviewProvider()
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: worktreeRoot),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )
        try await withShutdownDevelopmentProductHost(host) {
            let request = try makeDevelopmentBootstrapRequest(surface: "review")

            // Act
            _ = try await host.issueBootstrap(for: request)
            let snapshot = await provider.snapshot()

            // Assert
            #expect(snapshot.regularComparisonCount == 0)
            #expect(snapshot.contributionCaptureCount == 1)
            #expect(snapshot.sharedEndpointResolutionCount == 0)
            #expect(snapshot.sharedComparisonCount == 0)
            #expect(snapshot.sharedCaptureCount == 1)
            #expect(snapshot.sharedInstallCount == 1)
        }
    }

    @Test("a cancelled Review bootstrap cannot commit after its successor")
    func cancelledReviewBootstrapCannotCommitAfterSuccessor() async throws {
        // Arrange
        let worktreeRoot = try makeDevelopmentWorktreeRoot(
            named: "bridge-development-product-host-overlap"
        )
        defer { try? FileManager.default.removeItem(at: worktreeRoot) }
        let comparisonGate = BridgeComparisonGate()
        let provider = BridgeDevelopmentSharedConstructionReviewProvider(
            comparisonGate: comparisonGate
        )
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: worktreeRoot),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: worktreeRoot
            ),
            makeReviewProvider: { _, _ in provider }
        )
        try await withShutdownDevelopmentProductHost(host) {
            let reviewRequest = try makeDevelopmentBootstrapRequest(surface: "review")
            let fileRequest = try makeDevelopmentBootstrapRequest(surface: "file")
            let abandonedBootstrap = Task {
                try await host.issueBootstrap(for: reviewRequest)
            }
            do {
                await comparisonGate.waitForStartedComparisonCount(1)

                // Act
                abandonedBootstrap.cancel()
                let successorBootstrap = Task {
                    try await host.issueBootstrap(for: fileRequest)
                }
                await comparisonGate.releaseAll()

                // Assert
                await #expect(throws: CancellationError.self) {
                    _ = try await abandonedBootstrap.value
                }
                _ = try await successorBootstrap.value
            } catch {
                abandonedBootstrap.cancel()
                await comparisonGate.releaseAll()
                _ = await abandonedBootstrap.result
                throw error
            }
        }
    }
}

func developmentFileInvalidation(
    source: BridgeDevelopmentProductSource,
    batchSequence: UInt64
) -> BridgePaneWorktreeProductInvalidation {
    .filesChanged(
        FileChangeset(
            worktreeId: source.worktreeID,
            repoId: source.repoID,
            rootPath: source.worktreeRoot,
            paths: ["tracked.txt"],
            timestamp: .now,
            batchSeq: batchSequence
        )
    )
}

private func waitForRetiringReviewTasksToDrain(
    _ host: BridgeDevelopmentProductHost
) async -> Bool {
    let retiringTasks = await Array(host.retiringReviewComparisonTasks.values)
    for task in retiringTasks {
        await task.value
    }
    return await host.retiringReviewComparisonTasks.isEmpty
}

struct BridgeDevSharedReviewProviderSnapshot: Sendable {
    let contributionCaptureCount: Int
    let contributionTargets: [WorkspaceReviewContributionTarget]
    let regularComparisonCount: Int
    let reviewComparisonTargetReadCount: Int
    let sharedCaptureCount: Int
    let sharedComparisonCount: Int
    let sharedEndpointResolutionCount: Int
    let sharedInstallCount: Int
    let reviewGenerationValues: [Int]
    let reviewAttemptAuthorityGenerations: [UInt64]
    let gitRefreshScopes: [ReviewGitRefreshScope]
    let refreshImpactRequestCount: Int
}

private actor BridgeComparisonUpdateCompletionRecorder {
    private(set) var isComplete = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func recordCompletion() {
        isComplete = true
        let waiters = completionWaiters
        completionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForCompletion() async {
        guard !isComplete else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }
}

actor BridgeDevelopmentSharedConstructionReviewProvider:
    BridgeSharedReviewConstructionSourceProvider,
    BridgeReviewRefreshImpactSourceProvider
{
    func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        reviewComparisonTargetReadCount += 1
        await defaultTargetGate?.waitUntilReleased()
        return repositoryDefaultTarget
    }

    func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
        -> BridgeContributionComparisonCapture
    {
        contributionCaptureCount += 1
        contributionTargets.append(request.symbolicTarget)
        reviewGenerationValues.append(request.reviewGenerationValue)
        reviewAttemptAuthorityGenerations.append(request.reviewAttemptAuthorityGeneration)
        gitRefreshScopes.append(request.gitRefreshScope)
        try await contributionCaptureHold?(request)
        await comparisonGate?.waitUntilReleased()
        let baseEndpoint = resolvedEndpoint(request.baseEndpoint)
        return BridgeContributionComparisonCapture(
            resolvedTargetOID: String(repeating: "a", count: 40),
            reviewedHeadOID: String(repeating: "b", count: 40),
            baseRole: .commonCommit,
            baseOID: String(repeating: "a", count: 40),
            comparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: request.headEndpoint,
                changedFiles: changedFiles
            ),
            gitRefreshSeed: request.gitRefreshSeed
        )
    }

    private var comparisonGate: BridgeComparisonGate?
    private var contributionCaptureHold: (@Sendable (BridgeContributionComparisonRequest) async throws -> Void)?
    private var contributionCaptureCount = 0
    private var contributionTargets: [WorkspaceReviewContributionTarget] = []
    private var regularComparisonCount = 0
    private var repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity?
    private var defaultTargetGate: BridgeComparisonGate?
    private var reviewComparisonTargetReadCount = 0
    private var sharedCaptureCount = 0
    private var sharedComparisonCount = 0
    private var sharedEndpointResolutionCount = 0
    private var sharedInstallCount = 0
    private var reviewGenerationValues: [Int] = []
    private var reviewAttemptAuthorityGenerations: [UInt64] = []
    private var gitRefreshScopes: [ReviewGitRefreshScope] = []
    private var refreshImpactRequestCount = 0
    private var changedFiles: [BridgeEndpointChangedFile]

    init(
        comparisonGate: BridgeComparisonGate? = nil,
        repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity? = nil,
        changedFiles: [BridgeEndpointChangedFile] = []
    ) {
        self.comparisonGate = comparisonGate
        self.repositoryDefaultTarget = repositoryDefaultTarget
        self.changedFiles = changedFiles
    }

    func setComparisonGate(_ comparisonGate: BridgeComparisonGate?) {
        self.comparisonGate = comparisonGate
    }

    func setContributionCaptureHold(
        _ contributionCaptureHold: (@Sendable (BridgeContributionComparisonRequest) async throws -> Void)?
    ) {
        self.contributionCaptureHold = contributionCaptureHold
    }

    func setRepositoryDefaultTarget(
        _ repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity?
    ) {
        self.repositoryDefaultTarget = repositoryDefaultTarget
    }

    func setDefaultTargetGate(_ defaultTargetGate: BridgeComparisonGate?) {
        self.defaultTargetGate = defaultTargetGate
    }

    func setChangedFiles(_ changedFiles: [BridgeEndpointChangedFile]) {
        self.changedFiles = changedFiles
    }

    func resolveEndpoint(
        _ request: BridgeEndpointResolutionRequest
    ) async throws -> BridgeSourceEndpoint {
        resolvedEndpoint(request.endpoint)
    }

    func compareEndpoints(
        _ request: BridgeEndpointComparisonRequest
    ) async throws -> BridgeEndpointComparison {
        regularComparisonCount += 1
        await comparisonGate?.waitUntilReleased()
        return BridgeEndpointComparison(
            baseEndpoint: request.baseEndpoint,
            headEndpoint: request.headEndpoint,
            changedFiles: []
        )
    }

    func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
        BridgeTreeReadResult(endpoint: request.endpoint, descriptors: [])
    }

    func readReviewItemDescriptor(
        _ request: BridgeReviewItemDescriptorRequest
    ) async throws -> BridgeReviewItemDescriptor {
        throw BridgeProviderFailure.providerFailed(message: "No Review items are available")
    }

    func resolveCheckpointEndpoint(
        _ request: BridgeCheckpointEndpointRequest
    ) async throws -> BridgeSourceEndpoint {
        throw BridgeProviderFailure.providerFailed(message: "No checkpoints are available")
    }

    func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
        throw BridgeProviderFailure.missingContent(handleId: request.handle.handleId)
    }

    func resolveEndpoint(
        _ request: BridgeEndpointResolutionRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeSourceEndpoint {
        _ = freshnessKey
        sharedEndpointResolutionCount += 1
        return resolvedEndpoint(request.endpoint)
    }

    func compareEndpoints(
        _ request: BridgeEndpointComparisonRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeEndpointComparison {
        _ = freshnessKey
        sharedComparisonCount += 1
        await comparisonGate?.waitUntilReleased()
        return BridgeEndpointComparison(
            baseEndpoint: request.baseEndpoint,
            headEndpoint: request.headEndpoint,
            changedFiles: []
        )
    }

    func readTree(
        _ request: BridgeTreeReadRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeTreeReadResult {
        _ = freshnessKey
        return BridgeTreeReadResult(endpoint: request.endpoint, descriptors: [])
    }

    func readReviewItemDescriptor(
        _ request: BridgeReviewItemDescriptorRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeReviewItemDescriptor {
        _ = freshnessKey
        throw BridgeProviderFailure.providerFailed(message: "No Review items are available")
    }

    func captureSharedContent(
        handles: [BridgeContentHandle],
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeSharedReviewContentBacking {
        _ = handles
        _ = freshnessKey
        sharedCaptureCount += 1
        return BridgeSharedReviewContentBacking(
            artifactIdentity: UUIDv7.generate(),
            sourceByIdentity: [:]
        )
    }

    func installSharedContent(
        backing: BridgeSharedReviewContentBacking,
        handles: [BridgeContentHandle]
    ) async throws {
        _ = backing
        _ = handles
        sharedInstallCount += 1
    }

    func measureRefreshImpact(
        displayedPackage: BridgeReviewPackage,
        candidatePackage: BridgeReviewPackage,
        candidateGeneration: BridgeReviewGeneration
    ) async throws -> BridgeReviewRefreshImpact {
        _ = displayedPackage
        _ = candidatePackage
        _ = candidateGeneration
        refreshImpactRequestCount += 1
        return .developmentHostTestImpact
    }

    func snapshot() -> BridgeDevSharedReviewProviderSnapshot {
        BridgeDevSharedReviewProviderSnapshot(
            contributionCaptureCount: contributionCaptureCount,
            contributionTargets: contributionTargets,
            regularComparisonCount: regularComparisonCount,
            reviewComparisonTargetReadCount: reviewComparisonTargetReadCount,
            sharedCaptureCount: sharedCaptureCount,
            sharedComparisonCount: sharedComparisonCount,
            sharedEndpointResolutionCount: sharedEndpointResolutionCount,
            sharedInstallCount: sharedInstallCount,
            reviewGenerationValues: reviewGenerationValues,
            reviewAttemptAuthorityGenerations: reviewAttemptAuthorityGenerations,
            gitRefreshScopes: gitRefreshScopes,
            refreshImpactRequestCount: refreshImpactRequestCount
        )
    }

    private func resolvedEndpoint(_ endpoint: BridgeSourceEndpoint) -> BridgeSourceEndpoint {
        guard endpoint.kind == .gitRef else { return endpoint }
        let objectId = String(repeating: "a", count: 40)
        return BridgeSourceEndpoint(
            endpointId: endpoint.endpointId,
            kind: endpoint.kind,
            repoId: endpoint.repoId,
            worktreeId: endpoint.worktreeId,
            label: endpoint.label,
            createdAtUnixMilliseconds: endpoint.createdAtUnixMilliseconds,
            contentSetHash: objectId,
            providerIdentity: objectId
        )
    }
}

extension BridgeReviewRefreshImpact {
    fileprivate static let developmentHostTestImpact = exact(
        newlyImportedCommitCount: 10,
        affectedFileCount: 1,
        addedLineCount: 4,
        deletedLineCount: 3,
        affectedStableFileIdentities: []
    )
}

private func makeDevelopmentWorktreeRoot(named name: String) throws -> URL {
    let worktreeRoot = FileManager.default.temporaryDirectory.appending(
        path: "\(name)-\(UUIDv7.generate().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: false)
    let gitDirectory = worktreeRoot.appending(path: ".git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: false)
    return worktreeRoot
}

private func makeDevelopmentProductHostShutdownFactSource() -> LocalFactSource<
    BridgeDevelopmentProductHostFactScope,
    BridgeDevelopmentProductHostFact
> {
    LocalFactSource(
        vocabulary: FactVocabulary(
            describeScope: { String(describing: $0) },
            describeFact: { String(describing: $0) },
            isClosing: { _, fact in
                if case .shutdownResolved = fact { return true }
                return false
            }
        )
    )
}

func makeDevelopmentBootstrapRequest(
    surface: String
) throws -> BridgeDevelopmentProductBootstrapRequest {
    try JSONDecoder().decode(
        BridgeDevelopmentProductBootstrapRequest.self,
        from: Data(
            #"{"navigationIntent":{"commandId":"open-\#(surface)-view","commandKind":"activateContext","surface":"\#(surface)"},"reason":"initial","tabId":"owner-tab-1"}"#
                .utf8
        )
    )
}
