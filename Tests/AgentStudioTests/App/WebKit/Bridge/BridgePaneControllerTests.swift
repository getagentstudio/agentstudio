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
    struct BridgePaneControllerTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        actor OutOfOrderBridgeReviewSourceProvider: BridgeReviewSourceProvider {
            private let firstGenerationComparison: BridgeEndpointComparison
            private let laterGenerationComparison: BridgeEndpointComparison
            private var firstGenerationStarted = false
            private var firstGenerationStartWaiters: [CheckedContinuation<Void, Never>] = []
            private var firstGenerationReleaseContinuations: [CheckedContinuation<Void, Never>] = []

            init(
                firstGenerationComparison: BridgeEndpointComparison,
                laterGenerationComparison: BridgeEndpointComparison
            ) {
                self.firstGenerationComparison = firstGenerationComparison
                self.laterGenerationComparison = laterGenerationComparison
            }

            func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? { nil }

            func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
                -> BridgeContributionComparisonCapture
            {
                throw BridgeProviderFailure.providerFailed(message: "Contribution capture not configured")
            }

            func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws -> BridgeSourceEndpoint {
                request.endpoint
            }

            func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws -> BridgeEndpointComparison {
                if request.reviewGeneration == 1 {
                    firstGenerationStarted = true
                    resumeFirstGenerationStartWaiters()
                    await withCheckedContinuation { continuation in
                        firstGenerationReleaseContinuations.append(continuation)
                    }
                    return firstGenerationComparison
                }
                return BridgeEndpointComparison(
                    baseEndpoint: request.baseEndpoint,
                    headEndpoint: request.headEndpoint,
                    changedFiles: laterGenerationComparison.changedFiles
                )
            }

            func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
                BridgeTreeReadResult(endpoint: request.endpoint, descriptors: [])
            }

            func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
                -> BridgeReviewItemDescriptor
            {
                makeBridgeReviewItemDescriptor(itemId: "item-\(request.path)", path: request.path, fileClass: .source)
            }

            func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws
                -> BridgeSourceEndpoint
            {
                makeBridgeEndpoint(endpointId: request.checkpointId, kind: .promptCheckpoint)
            }

            func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
                throw BridgeProviderFailure.missingContent(handleId: request.handle.handleId)
            }

            func waitForFirstGenerationStarted() async {
                guard !firstGenerationStarted else { return }
                await withCheckedContinuation { continuation in
                    firstGenerationStartWaiters.append(continuation)
                }
            }

            func releaseFirstGeneration() {
                let continuations = firstGenerationReleaseContinuations
                firstGenerationReleaseContinuations.removeAll()
                for continuation in continuations {
                    continuation.resume()
                }
            }

            private func resumeFirstGenerationStartWaiters() {
                let waiters = firstGenerationStartWaiters
                firstGenerationStartWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }

        func makeController(
            state: BridgePaneState = BridgePaneState(panelKind: .diffViewer, source: nil),
            reviewSourceProvider: (any BridgeReviewSourceProvider)? = nil,
            telemetryScopeGate: BridgeTelemetryScopeGate? = nil,
            telemetryRecorder: (any BridgePerformanceTraceRecording)? = nil,
            traceContextFactory: BridgeTraceContextFactory = .live
        ) -> BridgePaneController {
            BridgePaneController(
                paneId: UUIDv7.generate(),
                state: state,
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: reviewSourceProvider,
                telemetryScopeGate: telemetryScopeGate,
                telemetryRecorder: telemetryRecorder,
                traceContextFactory: traceContextFactory,
                initialPaneActivity: .foreground
            )
        }

        @Test("handleBridgeReady sets bridge readiness and teardown resets it")
        func handleBridgeReady_setsReadyAndTeardownResets() {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            #expect(controller.isBridgeReady == false)

            controller.handleBridgeReady()
            #expect(controller.isBridgeReady == true)

            // fire-and-forget: synchronous test; the next assertion reads the synchronous teardown fence
            _ = controller.beginTeardown()
            #expect(controller.isBridgeReady == false)
        }

        @Test("handleBridgeReady is idempotent while ready")
        func handleBridgeReady_isIdempotent() {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            controller.handleBridgeReady()
            #expect(controller.isBridgeReady == true)

            controller.handleBridgeReady()
            #expect(controller.isBridgeReady == true)
        }

        @Test("teardown terminally rejects a later bridge ready handshake")
        func teardown_rejectsReadyRestartAfterReset() {
            let controller = makeController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            controller.handleBridgeReady()
            #expect(controller.isBridgeReady == true)

            // fire-and-forget: synchronous test; the next assertion reads the synchronous teardown fence
            _ = controller.beginTeardown()
            #expect(controller.isBridgeReady == false)

            #expect(controller.handleBridgeReady() == false)
            #expect(controller.isBridgeReady == false)
        }

        @Test("teardown synchronously closes pane product admission")
        func teardownSynchronouslyClosesPaneProductAdmission() throws {
            // Arrange
            let controller = makeController()
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            var lateMutationRan = false

            // Act
            let retirementTask = controller.beginTeardown()
            let lateMutationResult = productAdmission.withValidAdmission {
                lateMutationRan = true
                return true
            }

            // Assert
            #expect(controller.productAdmissionGate.acquire() == nil)
            #expect(lateMutationResult == nil)
            #expect(!lateMutationRan)
            _ = retirementTask
        }

        @Test("loadDiff publishes package metadata and registers content handles")
        func loadDiff_publishes_package_metadata_and_registers_content_handles() async throws {
            let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
            let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
            let changedFile = makeBridgeEndpointChangedFile(
                fileId: "source",
                path: "Sources/App/View.swift",
                sizeBytes: 100,
                oldContentHash: bridgeSHA256ContentHash("old"),
                newContentHash: bridgeSHA256ContentHash("new")
            )
            let baseHandle = BridgeReviewPackageBuilder.contentHandle(
                for: changedFile,
                endpoint: baseEndpoint,
                role: .base,
                reviewGeneration: 1
            )
            let headHandle = BridgeReviewPackageBuilder.contentHandle(
                for: changedFile,
                endpoint: headEndpoint,
                role: .head,
                reviewGeneration: 1
            )
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: baseEndpoint,
                    headEndpoint: headEndpoint,
                    changedFiles: [changedFile]
                ),
                contentByHandleId: [
                    baseHandle.handleId: makeContentResult(handle: baseHandle, data: "old"),
                    headHandle.handleId: makeContentResult(handle: headHandle, data: "new"),
                ]
            )
            let controller = makeController(
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "Sources",
                        baseline: .unstaged)
                ),
                reviewSourceProvider: provider
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            try await showReviewInNativeFixture(controller)
            let commandId = UUID()
            let artifact = DiffArtifact(
                diffId: UUIDv7.generate(),
                worktreeId: headEndpoint.worktreeId,
                patchData: Data()
            )

            let result = await controller.handleDiffCommand(
                .loadDiff(artifact),
                commandId: commandId,
                correlationId: nil
            )

            #expect(result == .success(commandId: commandId))
            #expect(controller.paneState.diff.status == .ready)
            #expect(controller.paneState.diff.error == nil)
            #expect(controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-source"])
            #expect(controller.paneState.diff.packageMetadata?.summary.filesChanged == 1)
            #expect(await provider.recordedContentRequestsCount() == 0)
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let registered = try await controller.reviewContentLoaderCache.load(
                handle: headHandle,
                productAdmission: productAdmission
            )
            #expect(registered.handle == headHandle)
        }
    }
}
