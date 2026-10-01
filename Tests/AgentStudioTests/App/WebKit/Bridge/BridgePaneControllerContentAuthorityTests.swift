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
    struct BridgePaneControllerContentAuthorityTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        private actor FailsAfterFirstComparisonReviewSourceProvider: BridgeReviewSourceProvider {
            private let firstComparison: BridgeEndpointComparison
            private var comparisonCount = 0

            init(firstComparison: BridgeEndpointComparison) {
                self.firstComparison = firstComparison
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
                comparisonCount += 1
                guard comparisonCount == 1 else {
                    throw BridgeProviderFailure.providerUnavailable
                }
                return BridgeEndpointComparison(
                    baseEndpoint: request.baseEndpoint,
                    headEndpoint: request.headEndpoint,
                    changedFiles: firstComparison.changedFiles
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
        }

        @Test("loadDiff preserves previous package and content authority after failed reload")
        func loadDiff_preserves_previous_package_and_content_authority_after_failed_reload() async throws {
            let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
            let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
            let changedFile = makeBridgeEndpointChangedFile(
                fileId: "source",
                path: "Sources/App/View.swift",
                sizeBytes: 100,
                oldContentHash: bridgeSHA256ContentHash("old"),
                newContentHash: bridgeSHA256ContentHash("new")
            )
            let headHandle = BridgeReviewPackageBuilder.contentHandle(
                for: changedFile,
                endpoint: headEndpoint,
                role: .head,
                reviewGeneration: 1
            )
            let provider = FailsAfterFirstComparisonReviewSourceProvider(
                firstComparison: BridgeEndpointComparison(
                    baseEndpoint: baseEndpoint,
                    headEndpoint: headEndpoint,
                    changedFiles: [changedFile]
                )
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
            let firstCommandId = UUID()
            let secondCommandId = UUID()

            let firstResult = await controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: headEndpoint.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: firstCommandId,
                correlationId: nil
            )
            #expect(firstResult == .success(commandId: firstCommandId))
            _ = try await controller.loadContentForIPC(
                contentHandleId: headHandle.handleId,
                reviewGeneration: 1
            )
            let initialPackage = try #require(controller.paneState.diff.packageMetadata)
            let initialDelta = controller.paneState.diff.packageDelta

            let secondResult = await controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: headEndpoint.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: secondCommandId,
                correlationId: nil
            )

            #expect(secondResult == .failure(.backendUnavailable(backend: "BridgeReviewSourceProvider")))
            #expect(controller.paneState.diff.packageMetadata == initialPackage)
            #expect(controller.paneState.diff.packageDelta == initialDelta)
            await #expect(throws: Never.self) {
                _ = try await controller.loadContentForIPC(
                    contentHandleId: headHandle.handleId,
                    reviewGeneration: 1
                )
            }
        }

        @Test("loadDiff keeps previous package and content authority while reload is in flight")
        func loadDiff_keeps_previous_package_and_content_authority_while_reload_is_in_flight() async throws {
            let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
            let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
            let initialFile = makeBridgeEndpointChangedFile(
                fileId: "old",
                path: "Sources/App/Old.swift",
                sizeBytes: 11,
                newContentHash: bridgeSHA256ContentHash("old content")
            )
            let nextFile = makeBridgeEndpointChangedFile(
                fileId: "new",
                path: "Sources/App/New.swift",
                sizeBytes: 100
            )
            let initialHandle = BridgeReviewPackageBuilder.contentHandle(
                for: initialFile,
                endpoint: headEndpoint,
                role: .head,
                reviewGeneration: 1
            )
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: baseEndpoint,
                    headEndpoint: headEndpoint,
                    changedFiles: [initialFile]
                ),
                contentByHandleId: [
                    initialHandle.handleId: makeContentResult(handle: initialHandle, data: "old content")
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
            let firstCommandId = UUID()
            let secondCommandId = UUID()

            let firstResult = await controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: headEndpoint.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: firstCommandId,
                correlationId: nil
            )
            #expect(firstResult == .success(commandId: firstCommandId))
            _ = try await controller.loadContentForIPC(
                contentHandleId: initialHandle.handleId,
                reviewGeneration: 1
            )
            let initialPackage = try #require(controller.paneState.diff.packageMetadata)
            let initialDelta = controller.paneState.diff.packageDelta

            let reloadGate = BridgeComparisonGate()
            await provider.setComparisonGate(reloadGate)
            await provider.setComparison(
                BridgeEndpointComparison(
                    baseEndpoint: baseEndpoint,
                    headEndpoint: headEndpoint,
                    changedFiles: [nextFile]
                ))
            let reloadTask = Task { @MainActor in
                await controller.handleDiffCommand(
                    .loadDiff(
                        DiffArtifact(
                            diffId: UUIDv7.generate(),
                            worktreeId: headEndpoint.worktreeId,
                            patchData: Data()
                        )
                    ),
                    commandId: secondCommandId,
                    correlationId: nil
                )
            }
            await reloadGate.waitForStartedComparisonCount(1)

            #expect(controller.paneState.diff.packageMetadata == initialPackage)
            #expect(controller.paneState.diff.packageDelta == initialDelta)
            await #expect(throws: Never.self) {
                _ = try await controller.loadContentForIPC(
                    contentHandleId: initialHandle.handleId,
                    reviewGeneration: 1
                )
            }

            await reloadGate.releaseAll()
            let reloadResult = await reloadTask.value

            #expect(reloadResult == .success(commandId: secondCommandId))
            #expect(controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-new"])
        }

        @Test("refresh preserves previous content authority when new metadata is invalid")
        func refresh_preserves_previous_content_authority_when_new_metadata_is_invalid() async throws {
            let fixture = try await makeRefreshRevisionFixture()
            defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let initialHandle = BridgeReviewPackageBuilder.contentHandle(
                for: makeBridgeEndpointChangedFile(
                    fileId: "old",
                    path: "Sources/App/Old.swift",
                    sizeBytes: 100
                ),
                endpoint: fixture.headEndpoint,
                role: .head,
                reviewGeneration: 1
            )
            let loadResult = await fixture.controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: fixture.headEndpoint.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: fixture.commandId,
                correlationId: nil
            )
            #expect(loadResult == .success(commandId: fixture.commandId))
            _ = try await fixture.controller.loadContentForIPC(
                contentHandleId: initialHandle.handleId,
                reviewGeneration: initialHandle.reviewGeneration.rawValue
            )
            let initialPackage = try #require(fixture.controller.paneState.diff.packageMetadata)
            let initialDelta = fixture.controller.paneState.diff.packageDelta

            let invalidRefreshFile = makeBridgeEndpointChangedFile(
                fileId: "bad-size",
                path: "Sources/App/BadSize.swift",
                sizeBytes: -1
            )
            let invalidRefreshHandle = BridgeReviewPackageBuilder.contentHandle(
                for: invalidRefreshFile,
                endpoint: fixture.headEndpoint,
                role: .head,
                reviewGeneration: initialPackage.reviewGeneration
            )
            await setRefreshComparison(fixture, changedFile: invalidRefreshFile)
            await postRefreshEvent(fixture, path: "Sources/App/BadSize.swift", batchSeq: 50)

            _ = try await fixture.controller.loadContentForIPC(
                contentHandleId: initialHandle.handleId,
                reviewGeneration: initialHandle.reviewGeneration.rawValue
            )
            await #expect(throws: BridgeIPCProjectionError.self) {
                _ = try await fixture.controller.loadContentForIPC(
                    contentHandleId: invalidRefreshHandle.handleId,
                    reviewGeneration: invalidRefreshHandle.reviewGeneration.rawValue
                )
            }
            #expect(fixture.controller.paneState.diff.packageMetadata == initialPackage)
            #expect(fixture.controller.paneState.diff.packageDelta == initialDelta)
        }

        @Test("teardown synchronously revokes direct review content authority")
        func teardown_synchronously_revokes_direct_review_content_authority() async throws {
            let fixture = try await makeRefreshRevisionFixture()
            let initialHandle = BridgeReviewPackageBuilder.contentHandle(
                for: makeBridgeEndpointChangedFile(
                    fileId: "old",
                    path: "Sources/App/Old.swift",
                    sizeBytes: 100
                ),
                endpoint: fixture.headEndpoint,
                role: .head,
                reviewGeneration: 1
            )
            let loadResult = await fixture.controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: fixture.headEndpoint.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: fixture.commandId,
                correlationId: nil
            )
            #expect(loadResult == .success(commandId: fixture.commandId))
            _ = try await fixture.controller.loadContentForIPC(
                contentHandleId: initialHandle.handleId,
                reviewGeneration: initialHandle.reviewGeneration.rawValue
            )

            let teardownRetirement = fixture.controller.beginTeardown()

            await #expect(throws: BridgeIPCProjectionError.self) {
                _ = try await fixture.controller.loadContentForIPC(
                    contentHandleId: initialHandle.handleId,
                    reviewGeneration: initialHandle.reviewGeneration.rawValue
                )
            }
            _ = await teardownRetirement.value
        }

        @Test("teardown prevents in-flight loadDiff from reauthorizing review content")
        func teardown_prevents_in_flight_loadDiff_from_reauthorizing_review_content() async throws {
            let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
            let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
            let changedFile = makeBridgeEndpointChangedFile(
                fileId: "source",
                path: "Sources/App/View.swift",
                sizeBytes: 100
            )
            let comparisonGate = BridgeComparisonGate()
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: baseEndpoint,
                    headEndpoint: headEndpoint,
                    changedFiles: [changedFile]
                ),
                contentByHandleId: [:],
                comparisonGate: comparisonGate
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
            let commandId = UUID()
            let headHandle = BridgeReviewPackageBuilder.contentHandle(
                for: changedFile,
                endpoint: headEndpoint,
                role: .head,
                reviewGeneration: 1
            )
            let loadTask = Task { @MainActor in
                await controller.handleDiffCommand(
                    .loadDiff(
                        DiffArtifact(
                            diffId: UUIDv7.generate(),
                            worktreeId: headEndpoint.worktreeId,
                            patchData: Data()
                        )
                    ),
                    commandId: commandId,
                    correlationId: nil
                )
            }
            await comparisonGate.waitForStartedComparisonCount(1)

            let teardownRetirement = controller.beginTeardown()
            await comparisonGate.releaseAll()
            let result = await loadTask.value

            #expect(result == .failure(.invalidPayload(description: "Stale bridge review load")))
            await #expect(throws: BridgeIPCProjectionError.self) {
                _ = try await controller.loadContentForIPC(
                    contentHandleId: headHandle.handleId,
                    reviewGeneration: 1
                )
            }
            _ = await teardownRetirement.value
        }

        @Test("loadDiff rejects invalid content handles before installing authority")
        func loadDiff_rejects_invalid_content_handles_before_installing_authority() async throws {
            let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
            let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
            let invalidFile = makeBridgeEndpointChangedFile(
                fileId: "bad-size",
                path: "Sources/App/BadSize.swift",
                sizeBytes: -1
            )
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: baseEndpoint,
                    headEndpoint: headEndpoint,
                    changedFiles: [invalidFile]
                ),
                contentByHandleId: [:]
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
            let invalidHandle = BridgeReviewPackageBuilder.contentHandle(
                for: invalidFile,
                endpoint: headEndpoint,
                role: .head,
                reviewGeneration: 1
            )
            let result = await controller.handleDiffCommand(
                .loadDiff(
                    DiffArtifact(
                        diffId: UUIDv7.generate(),
                        worktreeId: headEndpoint.worktreeId,
                        patchData: Data()
                    )
                ),
                commandId: commandId,
                correlationId: nil
            )

            #expect(result == .failure(.invalidPayload(description: "Failed to load bridge review package")))
            await #expect(throws: BridgeIPCProjectionError.self) {
                _ = try await controller.loadContentForIPC(
                    contentHandleId: invalidHandle.handleId,
                    reviewGeneration: invalidHandle.reviewGeneration.rawValue
                )
            }
            #expect(controller.paneState.diff.packageMetadata == nil)
            #expect(controller.paneState.diff.status == .error)
        }

        private func makeController(
            state: BridgePaneState,
            reviewSourceProvider: any BridgeReviewSourceProvider
        ) -> BridgePaneController {
            BridgePaneController(
                paneId: UUIDv7.generate(),
                state: state,
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: reviewSourceProvider,
                initialPaneActivity: .foreground
            )
        }
    }
}
