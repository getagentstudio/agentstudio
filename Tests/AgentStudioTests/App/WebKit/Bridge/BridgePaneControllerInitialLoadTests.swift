import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    @MainActor
    @Suite(.serialized)
    struct BridgePaneControllerInitialLoadTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("source backed controller can load its initial review package")
        func sourceBackedControllerCanLoadInitialReviewPackage() async throws {
            let repoId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            let worktreeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree),
                    changedFiles: [
                        makeBridgeEndpointChangedFile(
                            fileId: "source",
                            path: "Sources/App/View.swift",
                            sizeBytes: 100,
                            oldContentHash: bridgeSHA256ContentHash("old"),
                            newContentHash: bridgeSHA256ContentHash("new")
                        )
                    ]
                ),
                contentByHandleId: [:]
            )
            let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
            let controller = makeController(
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .unstaged),
                repoId: repoId,
                worktreeId: worktreeId,
                provider: provider,
                reviewBuildAdmissionFactSink: buildFacts.source.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            let result = try await beginInitialReviewInNativeFixture(controller, facts: buildFacts)

            guard case .succeeded = result else {
                Issue.record("Expected initial Bridge review package load to succeed")
                return
            }
            #expect(controller.paneState.diff.status == .ready)
            #expect(controller.paneState.diff.packageMetadata?.query.repoId == repoId)
            #expect(controller.paneState.diff.packageMetadata?.query.worktreeId == worktreeId)
            #expect(controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-source"])
            #expect(controller.paneState.diff.packageMetadata?.comparisonOrigin == nil)
            let request = try #require(await provider.recordedComparisonRequests().first)
            #expect(request.query.repoId == repoId)
            #expect(request.query.worktreeId == worktreeId)
            #expect(request.query.viewFilter.showBinaryFiles)
            #expect(request.query.viewFilter.showHiddenFiles)
            #expect(request.query.viewFilter.showLargeFiles)
            #expect(request.baseEndpoint.repoId == repoId)
            #expect(request.baseEndpoint.worktreeId == worktreeId)
            #expect(request.headEndpoint.repoId == repoId)
            #expect(request.headEndpoint.worktreeId == worktreeId)
            #expect(await provider.recordedContentRequestsCount() == 0)
        }

        @Test("origin symbolic default adopts its exact remote target and publishes the repository default")
        func originSymbolicDefaultAdoptsExactRemoteTargetAndPublishesRepositoryDefault() async throws {
            let repoId = UUIDv7.generate()
            let worktreeId = UUIDv7.generate()
            let provider = CanonicalContributionReviewSourceProvider()
            let targetRecorder = AutomaticContributionTargetRecorder()
            let reviewerState = BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .branch(name: "reviewer-selected")
                )
            )
            let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: nil
                    )
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    contentType: .diff,
                    title: "Bridge Review",
                    facets: PaneContextFacets(
                        repoId: repoId,
                        worktreeId: worktreeId,
                        worktreeName: "feature-worktree"
                    ),
                    checkoutRef: "feature/ref"
                ),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground,
                initialContributionTargetCommit: { target in
                    targetRecorder.record(target)
                    return .unchanged(reviewerState)
                },
                reviewBuildAdmissionFactSink: buildFacts.source.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            let result = try await beginInitialReviewInNativeFixture(controller, facts: buildFacts)

            guard case .succeeded = result else {
                Issue.record("Expected canonical reviewer target contribution load to succeed")
                return
            }
            #expect(await provider.recordedReviewComparisonTargetReadCount() == 1)
            #expect(
                targetRecorder.target
                    == .originDefaultBranch(remoteName: "upstream", branchName: "trunk")
            )
            #expect(await provider.recordedComparisonReadCount() == 0)
            let contributionRequest = try #require(await provider.recordedContributionRequests().first)
            #expect(contributionRequest.symbolicTarget == .branch(name: "reviewer-selected"))
            let package = try #require(controller.paneState.diff.packageMetadata)
            #expect(package.reviewedSubjectLabel == "feature-worktree")
            guard case .contribution(let origin) = package.comparisonOrigin else {
                Issue.record("Expected contribution origin")
                return
            }
            #expect(origin.symbolicTarget == .branch(name: "reviewer-selected"))
            guard case .workspace(_, let canonicalBaseline) = controller.bridgePaneState.source else {
                Issue.record("Expected workspace canonical state")
                return
            }
            #expect(canonicalBaseline?.contributionTarget == .branch(name: "reviewer-selected"))
            #expect(
                controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison?
                    .repositoryDefaultTarget
                    == CanonicalContributionReviewSourceProvider.repositoryDefaultTarget
            )
            let comparisonPresentation = try #require(
                controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison
            )
            #expect(comparisonPresentation.activeTarget == .branch(name: "reviewer-selected"))
            #expect(comparisonPresentation.attempt == .settled(reviewGeneration: package.reviewGeneration.rawValue))
            #expect(
                comparisonPresentation.displayedSnapshot
                    == .current(
                        BridgePaneReviewDisplayedSnapshotIdentity(
                            packageId: package.packageId,
                            reviewGeneration: package.reviewGeneration.rawValue,
                            revision: package.revision
                        )
                    )
            )
        }

        @Test("workspace review compare targets select git ref baseline against working tree")
        func workspaceReviewCompareTargetsSelectGitRefBaselineAgainstWorkingTree() async throws {
            for testCase in reviewContributionEndpointCases {
                let repoId = UUIDv7.generate()
                let worktreeId = UUIDv7.generate()
                let comparison = BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                    changedFiles: [
                        makeBridgeEndpointChangedFile(
                            fileId: "source",
                            path: "Sources/App/View.swift",
                            sizeBytes: 100
                        )
                    ]
                )
                let provider = BridgeReviewSourceProviderFake(
                    comparison: comparison,
                    contentByHandleId: [:],
                    contributionCapture: BridgeContributionComparisonCapture(
                        resolvedTargetOID: "resolved-target-oid",
                        reviewedHeadOID: "reviewed-head-oid",
                        baseRole: .commonCommit,
                        baseOID: "contribution-base-oid",
                        comparison: comparison
                    ),
                )
                let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
                let controller = makeController(
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: testCase.baseline
                    ),
                    repoId: repoId,
                    worktreeId: worktreeId,
                    provider: provider,
                    reviewBuildAdmissionFactSink: buildFacts.source.sink
                )
                defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

                let result = try await beginInitialReviewInNativeFixture(controller, facts: buildFacts)

                guard case .succeeded = result else {
                    Issue.record("Expected initial Bridge review package load to succeed")
                    return
                }
                let requests = await provider.recordedContributionRequests()
                let request = try #require(requests.first)
                #expect(request.baseEndpoint.endpointId == testCase.expectedEndpointId)
                #expect(request.baseEndpoint.kind == .gitRef)
                #expect(request.baseEndpoint.label == testCase.expectedLabel)
                #expect(request.baseEndpoint.providerIdentity == testCase.expectedProviderIdentity)
                #expect(request.baseEndpoint.repoId == repoId)
                #expect(request.baseEndpoint.worktreeId == worktreeId)
                #expect(request.headEndpoint.kind == .workingTree)
                #expect(request.headEndpoint.label == "Working tree")
                #expect(request.headEndpoint.repoId == repoId)
                #expect(request.headEndpoint.worktreeId == worktreeId)
                #expect(request.symbolicTarget == testCase.baseline.contributionTarget)
                #expect(request.reviewGenerationValue == 1)
                #expect(await provider.recordedComparisonRequestsCount() == 0)
            }
        }

        @Test("workspace contribution without a target requires selection and does not fabricate HEAD")
        func workspaceContributionWithoutTargetRequiresSelectionAndDoesNotFabricateHead() async throws {
            let worktreeId = UUIDv7.generate()
            let targetRecorder = AutomaticContributionTargetRecorder()
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree),
                    changedFiles: [
                        makeBridgeEndpointChangedFile(
                            fileId: "unborn",
                            path: "Sources/App/NewFile.swift",
                            sizeBytes: 100
                        )
                    ]
                ),
                contentByHandleId: [:],
                comparisonFailureByBaseProviderIdentity: [:]
            )
            let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
            let controller = makeController(
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: nil
                ),
                worktreeId: worktreeId,
                provider: provider,
                initialContributionTargetCommit: { target in
                    targetRecorder.record(target)
                    return .paneMissing
                },
                reviewBuildAdmissionFactSink: buildFacts.source.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            let result = try await beginInitialReviewInNativeFixture(controller, facts: buildFacts)

            guard case .failed = result else {
                Issue.record("Expected targetless contribution load to require selection")
                return
            }
            #expect(await provider.recordedContributionRequests().isEmpty)
            #expect(await provider.recordedComparisonRequests().isEmpty)
            #expect(targetRecorder.target == nil)
            #expect(controller.paneState.diff.status == .error)
        }

        @Test("contribution failure prose does not trigger narrow fallback")
        func contributionFailureProseDoesNotTriggerNarrowFallback() async throws {
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [:],
                contributionFailure: .providerFailed(message: "revspec 'HEAD' not found")
            )
            let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
            let controller = makeController(
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .ref(name: "HEAD")
                ),
                worktreeId: UUIDv7.generate(),
                provider: provider,
                reviewBuildAdmissionFactSink: buildFacts.source.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            let result = try await beginInitialReviewInNativeFixture(controller, facts: buildFacts)

            guard case .failed = result else {
                Issue.record("Expected raw provider prose to remain a failure")
                return
            }
            #expect(await provider.recordedContributionRequests().count == 1)
            #expect(await provider.recordedComparisonRequests().isEmpty)
        }

        @Test("workspace review does not fallback for a named ref")
        func workspaceReviewDoesNotFallbackForNamedRef() async throws {
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [:],
                contributionFailure: .unavailableEndpoint(endpointId: "baseline-main")
            )
            let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
            let controller = makeController(
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .ref(name: "main")
                ),
                worktreeId: UUIDv7.generate(),
                provider: provider,
                reviewBuildAdmissionFactSink: buildFacts.source.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            let result = try await beginInitialReviewInNativeFixture(controller, facts: buildFacts)

            guard case .failed = result else {
                Issue.record("Expected named-ref failure without fallback")
                return
            }
            #expect(await provider.recordedContributionRequests().count == 1)
            #expect(await provider.recordedComparisonRequests().isEmpty)
        }

        @Test("workspace review exposes scrubbed git data-plane package load failures")
        func workspaceReviewExposesScrubbedGitDataPlanePackageLoadFailures() async throws {
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [:],
                contributionFailure: .providerFailed(
                    message:
                        "gitDataPlane:libgit2Failure:code=-1:klass=2:reason=operationNotPermitted"
                )
            )
            let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
            let controller = makeController(
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .branch(name: "main")
                ),
                worktreeId: UUIDv7.generate(),
                provider: provider,
                reviewBuildAdmissionFactSink: buildFacts.source.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            let result = try await beginInitialReviewInNativeFixture(controller, facts: buildFacts)

            guard case .failed = result else {
                Issue.record("Expected native review package load to fail")
                return
            }
            #expect(controller.paneState.diff.status == .error)
            #expect(
                controller.paneState.diff.error
                    == "loadFailed:package:providerFailed:git.libgit2Failure:code=-1:klass=2:reason=operationNotPermitted"
            )
        }

        @Test("review package failure summaries scrub raw provider paths")
        func reviewPackageFailureSummariesScrubRawProviderPaths() {
            let rawPath = "/Users/shravansunder/Documents/dev/project-dev/secret.txt"

            let summary = BridgePaneController.reviewPackageLoadFailureSummary(
                for: BridgeProviderFailure.providerFailed(message: "Git path escapes repository: \(rawPath)"),
                stage: "package"
            )

            #expect(summary == "loadFailed:package:providerFailed:pathEscapesRepository")
            #expect(!summary.contains(rawPath))
        }

        @Test("review package failure summaries classify timeout-shaped provider messages")
        func reviewPackageFailureSummariesClassifyTimeoutShapedProviderMessages() {
            let summary = BridgePaneController.reviewPackageLoadFailureSummary(
                for: BridgeProviderFailure.providerFailed(
                    message: "Bridge Git data plane read timed out"
                ),
                stage: "package"
            )

            #expect(summary == "loadFailed:package:providerFailed:gitDataPlaneTimeout")
        }

        @Test("generic controller skips initial review package load")
        func genericControllerSkipsInitialReviewPackageLoad() async {
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                    changedFiles: [
                        makeBridgeEndpointChangedFile(
                            fileId: "source",
                            path: "Sources/App/View.swift",
                            sizeBytes: 100
                        )
                    ]
                ),
                contentByHandleId: [:]
            )
            let controller = makeController(source: nil, worktreeId: nil, provider: provider)
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            let result = await controller.loadInitialReviewPackageIfPossible(correlationId: nil)

            #expect(result == nil)
            #expect(controller.paneState.diff.status == .idle)
            #expect(controller.paneState.diff.packageMetadata == nil)
            #expect(await provider.recordedComparisonRequestsCount() == 0)
        }

        @Test("failed initial Review publication does not self-retry without new intake")
        func failedInitialReviewPublicationDoesNotSelfRetryWithoutNewIntake() async throws {
            // Arrange — the slash produces an invalid Review item identifier at the metadata
            // reservation boundary while leaving the native pane in its initial loading state.
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                    changedFiles: [
                        makeBridgeEndpointChangedFile(
                            fileId: "nested/source",
                            path: "Sources/App/View.swift",
                            sizeBytes: 100
                        )
                    ]
                ),
                contentByHandleId: [:]
            )
            let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
            let controller = makeController(
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .unstaged),
                worktreeId: UUIDv7.generate(),
                provider: provider,
                reviewBuildAdmissionFactSink: buildFacts.source.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            // Act — wait for the exact scheduled attempt, not for elapsed time. A completion
            // callback that manufactures another intake replaces activeReviewRefreshTask before
            // this captured task returns.
            #expect(try await beginInitialReviewInNativeFixture(controller, facts: buildFacts) == .failed)

            // Assert
            #expect(await provider.recordedComparisonRequestsCount() == 1)
            #expect(controller.activeReviewRefreshTask == nil)
            #expect(controller.paneState.diff.status == .error)
            #expect(controller.paneState.diff.error == "loadFailed:publication")
            #expect(controller.paneState.diff.packageMetadata == nil)
        }

        @Test("fresh Review intake can recover native error state")
        func freshReviewIntakeCanRecoverNativeErrorState() async throws {
            // Arrange
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [:]
            )
            let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
            let controller = makeController(
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .unstaged),
                worktreeId: UUIDv7.generate(),
                provider: provider,
                reviewBuildAdmissionFactSink: buildFacts.source.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            controller.paneState.diff.setStatus(.error, error: "metadataUnavailable")

            // Act
            #expect(try await beginInitialReviewInNativeFixture(controller, facts: buildFacts) == .succeeded)

            // Assert
            #expect(await provider.recordedComparisonRequestsCount() == 1)
            #expect(controller.paneState.diff.status == .ready)
            #expect(controller.paneState.diff.error == nil)
            #expect(controller.paneState.diff.packageMetadata?.orderedItemIds.isEmpty == true)
        }

        @Test("foreground transition does not retry native Review error state")
        func foregroundTransitionDoesNotRetryNativeReviewErrorState() async {
            // Arrange
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [:]
            )
            let controller = makeController(
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .unstaged),
                worktreeId: UUIDv7.generate(),
                provider: provider
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            controller.paneState.diff.setStatus(.error, error: "metadataUnavailable")
            // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
            _ = controller.applyBridgePaneActivity(.loadedHidden)

            // Act
            // fire-and-forget: the test asserts admission state; the presentation transition handle is not its claim
            _ = controller.applyBridgePaneActivity(.foreground)
            if let foregroundAttempt = controller.activeReviewRefreshTask {
                await foregroundAttempt.value
            }

            // Assert
            #expect(await provider.recordedComparisonRequestsCount() == 0)
            #expect(controller.paneState.diff.status == .error)
            #expect(controller.paneState.diff.packageMetadata == nil)
        }

        @Test("real-git multi-window fixture commits one initial Review package")
        func realGitMultiWindowFixtureCommitsOneInitialReviewPackage() async throws {
            // Arrange
            let repoURL = try await FilesystemTestGitRepo.create(
                named: "bridge-review-initial-load-multi-window"
            )
            defer { FilesystemTestGitRepo.destroy(repoURL) }
            try await seedRealGitMultiWindowFixture(at: repoURL)
            let paneId = UUIDv7.generate()
            let repoId = UUIDv7.generate()
            let worktreeId = UUIDv7.generate()
            let gitReadContext = makeBridgeGitReadContext(rootURL: repoURL)
            let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
            let controller = BridgePaneController(
                paneId: paneId,
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: repoURL.path,
                        baseline: .localDefaultBranch(branchName: "main")
                    )
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    paneId: PaneId(existingUUID: paneId),
                    contentType: .diff,
                    launchDirectory: repoURL,
                    title: "Real Git Initial Review",
                    facets: PaneContextFacets(
                        repoId: repoId,
                        worktreeId: worktreeId,
                        worktreeName: "real-git-initial-review",
                        cwd: repoURL
                    )
                ),
                reviewSourceProvider: BridgeReviewSourceProviderFactory.gitProvider(
                    repositoryPath: repoURL,
                    gitReadContext: gitReadContext
                ),
                gitReadContext: gitReadContext,
                initialPaneActivity: .foreground,
                reviewBuildAdmissionFactSink: buildFacts.source.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            // Act
            let result = try await beginInitialReviewInNativeFixture(controller, facts: buildFacts)

            // Assert
            guard case .succeeded = result else {
                Issue.record(
                    "Expected one real-git initial load to commit; result=\(String(describing: result)), status=\(controller.paneState.diff.status), error=\(controller.paneState.diff.error ?? "none"), publication=\(controller.reviewPublicationCoordinator.diagnosticSnapshot), generation=\(controller.nextReviewGeneration.rawValue)"
                )
                return
            }
            let package = try #require(controller.paneState.diff.packageMetadata)
            #expect(controller.paneState.diff.status == .ready)
            #expect(package.orderedItemIds.count >= 37)
            #expect(controller.reviewPublicationCoordinator.diagnosticSnapshot.active != nil)
        }

        @Test("real-git multi-window package fits Review metadata reservation")
        func realGitMultiWindowPackageFitsReviewMetadataReservation() async throws {
            // Arrange
            let repoURL = try await FilesystemTestGitRepo.create(
                named: "bridge-review-metadata-reservation-multi-window"
            )
            defer { FilesystemTestGitRepo.destroy(repoURL) }
            try await seedRealGitMultiWindowFixture(at: repoURL)
            let repoId = UUIDv7.generate()
            let worktreeId = UUIDv7.generate()
            let provider = BridgeReviewSourceProviderFactory.gitProvider(
                repositoryPath: repoURL,
                gitReadContext: makeBridgeGitReadContext(rootURL: repoURL)
            )
            let pipeline = BridgeReviewPipeline(provider: provider)
            let productAdmission = try #require(BridgeProductAdmissionGate().acquire())
            let result = try await pipeline.loadPackage(
                makeRealGitMultiWindowPipelineRequest(
                    repoId: repoId,
                    worktreeId: worktreeId
                )
            )
            let source = BridgePaneProductReviewMetadataSource()

            // Act
            let reservation: BridgeReviewMetadataPublicationReservation
            do {
                reservation = try await source.reserve(
                    package: result.package,
                    publicationId: UUIDv7.generate(),
                    productAdmission: productAdmission
                )
            } catch {
                Issue.record(
                    "Expected Review metadata reservation to accept the real-git package; errorType=\(String(describing: type(of: error))), error=\(String(describing: error)), items=\(result.package.orderedItemIds.count)"
                )
                return
            }

            // Assert
            #expect(result.package.orderedItemIds.count >= 37)
            #expect(reservation.packageId == result.package.packageId)
            #expect(reservation.reviewGeneration == result.package.reviewGeneration)
        }

        @Test("file viewer controller loads its initial review package for a review switch")
        func fileViewerControllerLoadsInitialReviewPackage() async throws {
            let worktreeId = UUIDv7.generate()
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                    changedFiles: [
                        makeBridgeEndpointChangedFile(
                            fileId: "source",
                            path: "Sources/App/View.swift",
                            sizeBytes: 100
                        )
                    ]
                ),
                contentByHandleId: [:]
            )
            let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
            let controller = makeController(
                panelKind: .fileViewer,
                source: .workspace(
                    rootPath: "/tmp/worktree",
                    baseline: .unstaged),
                worktreeId: worktreeId,
                provider: provider,
                reviewBuildAdmissionFactSink: buildFacts.source.sink
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            let result = try await beginInitialReviewInNativeFixture(controller, facts: buildFacts)

            guard case .succeeded = result else {
                Issue.record("Expected a file-viewer pane to load its review package for a review switch")
                return
            }
            #expect(controller.paneState.diff.status == .ready)
            #expect(controller.paneState.diff.packageMetadata?.query.worktreeId == worktreeId)
            #expect(await provider.recordedComparisonRequestsCount() == 1)
        }

        @Test("foreground File pane waits for active mode or background intake before Review")
        func foregroundFilePaneDoesNotEagerlyLoadReview() async throws {
            // Arrange
            let worktreeId = UUIDv7.generate()
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [:]
            )
            let controller = makeController(
                panelKind: .fileViewer,
                source: .workspace(rootPath: "/tmp/worktree", baseline: .unstaged),
                worktreeId: worktreeId,
                provider: provider,
                initialPaneActivity: .loadedHidden
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            // Act
            let foregroundTransition = controller.applyBridgePaneActivity(.foreground)
            await foregroundTransition?.value

            // Assert
            #expect(controller.activeReviewRefreshTask == nil)
            #expect(await provider.recordedComparisonRequestsCount() == 0)
        }

        @Test("active Review mode starts the initial Review package")
        func activeReviewModeStartsInitialReviewPackage() async throws {
            // Arrange
            let worktreeId = UUIDv7.generate()
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "base", kind: .gitRef),
                    headEndpoint: makeBridgeEndpoint(endpointId: "head", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [:]
            )
            let controller = makeController(
                source: .workspace(rootPath: "/tmp/worktree", baseline: .unstaged),
                worktreeId: worktreeId,
                provider: provider
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let productAdmission = try #require(controller.productAdmissionGate.acquire())

            // Act
            await controller.handleCommittedProductActiveViewerModeUpdate(
                sessionId: "initial-review-session",
                sequence: 1,
                mode: .review,
                activeSource: nil,
                productAdmission: productAdmission
            )
            let reviewTask = try #require(controller.activeReviewRefreshTask)
            await reviewTask.value

            // Assert
            #expect(await provider.recordedComparisonRequestsCount() == 1)
            #expect(controller.paneState.diff.status == .ready)
        }

        private func makeController(
            panelKind: BridgePanelKind = .diffViewer,
            source: BridgePaneSource?,
            repoId: UUID? = nil,
            worktreeId: UUID?,
            provider: any BridgeReviewSourceProvider,
            initialPaneActivity: BridgePaneActivity = .foreground,
            initialContributionTargetCommit:
                (@MainActor @Sendable (WorkspaceReviewContributionTarget) -> BridgePaneStateMutationResult)? = nil,
            reviewBuildAdmissionFactSink: @escaping BridgePaneReviewBuildAdmissionFactSink = { _, _ in }
        ) -> BridgePaneController {
            BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: panelKind, source: source),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    contentType: .diff,
                    title: "Bridge Review",
                    facets: PaneContextFacets(repoId: repoId, worktreeId: worktreeId)
                ),
                reviewSourceProvider: provider,
                initialPaneActivity: initialPaneActivity,
                initialContributionTargetCommit: initialContributionTargetCommit,
                reviewBuildAdmissionFactSink: reviewBuildAdmissionFactSink
            )
        }

        private func seedRealGitMultiWindowFixture(at repoURL: URL) async throws {
            try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repoURL)
            for index in 0..<36 {
                let directory = repoURL.appending(
                    path: String(format: "Sources/Group%02d", index / 9)
                )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try "review item \(index)\n".write(
                    to: directory.appending(path: String(format: "item-%03d.txt", index)),
                    atomically: true,
                    encoding: .utf8
                )
            }
            let largeBody = (0..<520).map { "large line \($0)" }.joined(separator: "\n")
            try "\(largeBody)\n".write(
                to: repoURL.appending(path: "Sources/Group00/large-position.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        private func makeRealGitMultiWindowPipelineRequest(
            repoId: UUID,
            worktreeId: UUID
        ) -> BridgeReviewPipelineRequest {
            let base = BridgeSourceEndpoint(
                endpointId: "baseline-local-default",
                kind: .gitRef,
                repoId: repoId,
                worktreeId: worktreeId,
                label: "main",
                createdAtUnixMilliseconds: 1,
                contentSetHash: nil,
                providerIdentity: "main"
            )
            let head = BridgeSourceEndpoint(
                endpointId: "working-tree",
                kind: .workingTree,
                repoId: repoId,
                worktreeId: worktreeId,
                label: "Working tree",
                createdAtUnixMilliseconds: 1,
                contentSetHash: nil,
                providerIdentity: "working-tree:\(worktreeId.uuidString)"
            )
            return BridgeReviewPipelineRequest(
                packageId: "real-git-multi-window-package",
                query: BridgeReviewQuery(
                    queryId: "real-git-multi-window-query",
                    queryKind: .compare,
                    repoId: repoId,
                    worktreeId: worktreeId,
                    baseEndpointId: base.endpointId,
                    headEndpointId: head.endpointId,
                    comparisonSemantics: .workingTreeDelta,
                    pathScope: [],
                    fileTarget: nil,
                    viewFilter: BridgeViewFilter(),
                    grouping: BridgeChangeGrouping(kind: .flat),
                    provenanceFilter: BridgeProvenanceFilter()
                ),
                baseEndpoint: base,
                headEndpoint: head,
                checkpointIds: [],
                reviewGeneration: 1,
                generatedAtUnixMilliseconds: 1
            )
        }
    }
}
