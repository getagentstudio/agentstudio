import AgentStudioProgrammaticControl
import AgentStudioTestHarness
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
    struct BridgePaneControllerIPCProjectionTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("IPC refresh builds package from pane worktree context")
        func ipcRefresh_buildsPackageFromPaneWorktreeContext() async throws {
            let worktreeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let baseEndpoint = makeBridgeEndpoint(endpointId: "index", kind: .index)
            let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
            let changedFile = makeBridgeEndpointChangedFile(
                fileId: "source",
                path: "Sources/App/View.swift",
                sizeBytes: 100,
                oldContentHash: bridgeSHA256ContentHash("old"),
                newContentHash: bridgeSHA256ContentHash("new")
            )
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: baseEndpoint,
                    headEndpoint: headEndpoint,
                    changedFiles: [changedFile]
                ),
                contentByHandleId: [:]
            )
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: .unstaged)
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    contentType: .diff,
                    title: "Bridge Review",
                    facets: PaneContextFacets(worktreeId: worktreeId)
                ),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let correlationId = UUID()
            try await showIPCReviewPageAndAwaitInitialPackage(controller)

            let result = try await controller.refreshReviewForIPC(correlationId: correlationId)

            #expect(result.paneId == controller.paneId)
            #expect(result.refreshed == true)
            #expect(result.status == "ready")
            #expect(result.correlationId == correlationId)
            #expect(result.packageId == controller.paneState.diff.packageMetadata?.packageId)
            #expect(controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-source"])
            #expect(await provider.recordedContentRequestsCount() == 0)
        }

        @Test("IPC package snapshot projects authoritative ordered item summaries")
        func ipcPackageSnapshot_projectsAuthoritativeOrderedItemSummaries() async throws {
            let worktreeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
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
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: .unstaged)
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    contentType: .diff,
                    title: "Bridge Review",
                    facets: PaneContextFacets(worktreeId: worktreeId)
                ),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            try await showIPCReviewPageAndAwaitInitialPackage(controller)
            _ = try await controller.refreshReviewForIPC(correlationId: nil)

            let result = try controller.ipcReviewPackageSnapshot()
            let encodedResult = try JSONEncoder().encode(result)
            let encodedPayload = try #require(String(data: encodedResult, encoding: .utf8))

            #expect(result.paneId == controller.paneId)
            #expect(result.status == "ready")
            #expect(result.packageId == controller.paneState.diff.packageMetadata?.packageId)
            #expect(result.reviewGeneration == controller.paneState.diff.packageMetadata?.reviewGeneration.rawValue)
            #expect(result.summary?.filesChanged == 1)
            #expect(
                result.items == [
                    IPCBridgeReviewItemSummary(
                        itemId: "item-source",
                        displayPath: "Sources/App/View.swift",
                        itemKind: "diff",
                        changeKind: "modified",
                        collapsed: false
                    )
                ]
            )
            #expect(encodedPayload.contains("\"package\"") == false)
            #expect(encodedPayload.contains("\"contentRoles\"") == false)
            #expect(encodedPayload.contains("\"provenance\"") == false)
        }

        @Test("IPC package snapshot projects the exact contribution origin and reviewed subject")
        func ipcPackageSnapshot_projectsExactContributionOriginAndReviewedSubject() throws {
            let controller = makeIPCForegroundController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            controller.paneState.diff.setPackageMetadata(
                makeIPCReviewPackage(
                    descriptors: [],
                    orderedItemIds: [],
                    comparisonOrigin: .contribution(
                        BridgeReviewContributionOrigin(
                            symbolicTarget: .commit(
                                oid: "0123456789abcdef0123456789abcdef01234567"
                            ),
                            resolvedTargetOID: "1111111111111111111111111111111111111111",
                            reviewedHeadOID: "2222222222222222222222222222222222222222",
                            baseRole: .selectedTarget,
                            baseOID: "3333333333333333333333333333333333333333"
                        )
                    ),
                    reviewedSubjectLabel: "feature/review-comments"
                )
            )

            let result = try controller.ipcReviewPackageSnapshot()
            let encodedResult = try JSONEncoder().encode(result)
            let payload = try #require(
                JSONSerialization.jsonObject(with: encodedResult) as? [String: Any]
            )
            let origin = try #require(payload["comparisonOrigin"] as? [String: Any])
            let symbolicTarget = try #require(origin["symbolicTarget"] as? [String: Any])

            #expect(payload["reviewedSubjectLabel"] as? String == "feature/review-comments")
            #expect(origin["kind"] as? String == "contribution")
            #expect(origin["baseRole"] as? String == "selectedTarget")
            #expect(origin["comparedRole"] as? String == "capturedWorkingTree")
            #expect(symbolicTarget["kind"] as? String == "commit")
            #expect(
                symbolicTarget["oid"] as? String
                    == "0123456789abcdef0123456789abcdef01234567"
            )
            #expect(origin["resolvedTargetOID"] as? String == "1111111111111111111111111111111111111111")
            #expect(origin["reviewedHeadOID"] as? String == "2222222222222222222222222222222222222222")
            #expect(origin["baseOID"] as? String == "3333333333333333333333333333333333333333")
        }

        @Test("IPC package summaries preserve package order and descriptor fields")
        func ipcPackageSnapshot_preservesPackageOrderAndDescriptorFields() throws {
            let controller = makeIPCForegroundController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let descriptors = [
                makeIPCReviewItemDescriptor(
                    itemId: "middle",
                    itemKind: .file,
                    basePath: "Sources/OldMiddle.swift",
                    headPath: "Sources/Middle.swift",
                    changeKind: .renamed,
                    collapsed: true
                ),
                makeIPCReviewItemDescriptor(
                    itemId: "final",
                    itemKind: .diff,
                    basePath: "Sources/Final.swift",
                    headPath: nil,
                    changeKind: .deleted,
                    collapsed: false
                ),
                makeIPCReviewItemDescriptor(
                    itemId: "early",
                    itemKind: .diff,
                    basePath: nil,
                    headPath: "Sources/Early.swift",
                    changeKind: .added,
                    collapsed: false
                ),
            ]
            controller.paneState.diff.setPackageMetadata(
                makeIPCReviewPackage(
                    descriptors: descriptors,
                    orderedItemIds: ["early", "middle", "final"]
                )
            )

            let result = try controller.ipcReviewPackageSnapshot()

            #expect(result.items.map(\.itemId) == ["early", "middle", "final"])
            #expect(
                result.items.map(\.displayPath) == [
                    "Sources/Early.swift", "Sources/Middle.swift", "Sources/Final.swift",
                ])
            #expect(result.items.map(\.itemKind) == ["diff", "file", "diff"])
            #expect(result.items.map(\.changeKind) == ["added", "renamed", "deleted"])
            #expect(result.items.map(\.collapsed) == [false, true, false])
        }

        @Test("IPC package summary rejects a descriptor without a display path")
        func ipcPackageSnapshot_rejectsDescriptorWithoutDisplayPath() {
            let controller = makeIPCForegroundController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let descriptor = makeIPCReviewItemDescriptor(
                itemId: "pathless",
                itemKind: .diff,
                basePath: nil,
                headPath: nil,
                changeKind: .modified,
                collapsed: false
            )
            controller.paneState.diff.setPackageMetadata(
                makeIPCReviewPackage(
                    descriptors: [descriptor],
                    orderedItemIds: [descriptor.itemId]
                )
            )

            #expect(throws: BridgeIPCProjectionError(reason: .validationRejected)) {
                try controller.ipcReviewPackageSnapshot()
            }
        }

        @Test("IPC content descriptor returns metadata without loading body bytes")
        func ipcContentDescriptor_returnsMetadataWithoutLoadingBodyBytes() async throws {
            let handle = makeBridgeContentHandle(
                itemId: "item-source",
                role: .head,
                reviewGeneration: 7,
                contentHash: bridgeSHA256ContentHash("let value = 1\n"),
                sizeBytes: 14
            )
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [
                    handle.handleId: makeContentResult(handle: handle, data: "let value = 1\n")
                ]
            )
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            try await installIPCContentDescriptorPackage(handle, in: controller)

            let result = try await controller.loadContentForIPC(
                contentHandleId: handle.handleId,
                reviewGeneration: 7
            )

            let encodedResult = try JSONEncoder().encode(result)
            let encodedPayload = try #require(String(data: encodedResult, encoding: .utf8))
            #expect(result.paneId == controller.paneId)
            #expect(result.handle.handleId == handle.handleId)
            #expect(result.mimeType == handle.mimeType)
            #expect(result.byteCount == handle.sizeBytes)
            #expect(encodedPayload.contains("resourceUrl") == false)
            #expect(encodedPayload.contains("contentText") == false)
            #expect(encodedPayload.contains("contentBase64") == false)
            #expect(await provider.recordedContentRequestsCount() == 0)
        }

        @Test("IPC content descriptor rejects content after teardown revokes review authority")
        func ipcContentDescriptor_rejectsContentAfterTeardownRevokesReviewAuthority() async throws {
            let handle = makeBridgeContentHandle(
                itemId: "item-source",
                role: .head,
                reviewGeneration: 7,
                contentHash: bridgeSHA256ContentHash("let value = 1\n"),
                sizeBytes: 14
            )
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [
                    handle.handleId: makeContentResult(handle: handle, data: "let value = 1\n")
                ]
            )
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            try await installIPCContentDescriptorPackage(handle, in: controller)

            let teardownRetirement = controller.beginTeardown()

            await #expect(throws: BridgeIPCProjectionError.self) {
                _ = try await controller.loadContentForIPC(
                    contentHandleId: handle.handleId,
                    reviewGeneration: 7
                )
            }
            #expect(await provider.recordedContentRequestsCount() == 0)
            _ = await teardownRetirement.value
        }

        @Test("IPC content descriptor does not start provider body load")
        func ipcContentDescriptor_doesNotStartProviderBodyLoad() async throws {
            let handle = makeBridgeContentHandle(
                itemId: "item-source",
                role: .head,
                reviewGeneration: 7,
                contentHash: bridgeSHA256ContentHash("let value = 1\n"),
                sizeBytes: 14
            )
            let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [
                    handle.handleId: makeContentResult(handle: handle, data: "let value = 1\n")
                ],
                contentLoadGate: gate
            )
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            try await installIPCContentDescriptorPackage(handle, in: controller)

            let result = try await controller.loadContentForIPC(
                contentHandleId: handle.handleId,
                reviewGeneration: 7
            )

            #expect(result.handle.handleId == handle.handleId)
            #expect(await provider.recordedContentRequestsCount() == 0)
            gate.release()
        }

        @Test("IPC content descriptor reflects active handle after byte cap tightens")
        func ipcContentDescriptor_reflectsActiveHandleAfterByteCapTightens() async throws {
            let handle = makeBridgeContentHandle(
                itemId: "item-source",
                role: .head,
                reviewGeneration: 7,
                contentHash: bridgeSHA256ContentHash("preserved"),
                sizeBytes: 9
            )
            let tightenedHandle = BridgeContentHandle(
                handleId: handle.handleId,
                itemId: handle.itemId,
                role: handle.role,
                endpointId: handle.endpointId,
                reviewGeneration: handle.reviewGeneration,
                contentHash: handle.contentHash,
                contentHashAlgorithm: handle.contentHashAlgorithm,
                cacheKey: handle.cacheKey,
                mimeType: handle.mimeType,
                language: handle.language,
                sizeBytes: 4,
                isBinary: handle.isBinary
            )
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [
                    handle.handleId: makeContentResult(handle: handle, data: "preserved")
                ]
            )
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            try await installIPCContentDescriptorPackage(handle, in: controller)
            let initialResult = try await controller.loadContentForIPC(
                contentHandleId: handle.handleId,
                reviewGeneration: 7
            )
            #expect(initialResult.byteCount == 9)

            try await installIPCContentDescriptorPackage(
                tightenedHandle,
                revision: 1,
                in: controller
            )

            let tightenedResult = try await controller.loadContentForIPC(
                contentHandleId: handle.handleId,
                reviewGeneration: 7
            )
            #expect(tightenedResult.byteCount == 4)
            #expect(await provider.recordedContentRequestsCount() == 0)
        }

        @Test("IPC content descriptor does not serialize oversized body payloads")
        func ipcContentDescriptor_doesNotSerializeOversizedBodyPayloads() async throws {
            let oversizedText = String(repeating: "a", count: 1_000_000)
            let handle = makeBridgeContentHandle(
                itemId: "item-source",
                role: .head,
                reviewGeneration: 7,
                contentHash: bridgeSHA256ContentHash(oversizedText),
                sizeBytes: oversizedText.utf8.count
            )
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree),
                    changedFiles: []
                ),
                contentByHandleId: [
                    handle.handleId: makeContentResult(handle: handle, data: oversizedText)
                ]
            )
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(panelKind: .diffViewer, source: nil),
                appRootURL: testBridgeAppRootURL(),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            try await installIPCContentDescriptorPackage(handle, in: controller)

            let result = try await controller.loadContentForIPC(
                contentHandleId: handle.handleId,
                reviewGeneration: 7
            )

            let encodedResult = try JSONEncoder().encode(result)
            let encodedPayload = try #require(String(data: encodedResult, encoding: .utf8))
            #expect(result.byteCount == oversizedText.utf8.count)
            #expect(encodedPayload.contains(oversizedText) == false)
            #expect(await provider.recordedContentRequestsCount() == 0)
        }

        @Test("IPC package snapshot rejects oversized ordered item summaries before frame encoding")
        func ipcPackageSnapshot_rejectsOversizedOrderedItemSummariesBeforeFrameEncoding() async throws {
            let worktreeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let longPathSegment = String(repeating: "very-long-folder-name/", count: 180)
            let changedFiles = (0..<260).map { index in
                makeBridgeEndpointChangedFile(
                    fileId: "source-\(index)",
                    path: "Sources/\(longPathSegment)File\(index).swift",
                    sizeBytes: 100,
                    oldContentHash: bridgeSHA256ContentHash("old-\(index)"),
                    newContentHash: bridgeSHA256ContentHash("new-\(index)")
                )
            }
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
                    headEndpoint: makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree),
                    changedFiles: changedFiles
                ),
                contentByHandleId: [:]
            )
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: .unstaged)
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    contentType: .diff,
                    title: "Bridge Review",
                    facets: PaneContextFacets(worktreeId: worktreeId)
                ),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            try await showIPCReviewPageAndAwaitInitialPackage(controller)

            #expect(throws: BridgeIPCProjectionError(reason: .payloadTooLarge)) {
                try controller.ipcReviewPackageSnapshot()
            }
        }

        @Test("IPC Review selection preserves package-unavailable validation")
        func ipcReviewSelection_preservesPackageUnavailableValidation() async {
            let controller = makeIPCForegroundController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            await #expect(throws: BridgeIPCProjectionError(reason: .packageUnavailable)) {
                _ = try await controller.selectReviewItemForIPC(
                    itemId: "item-source",
                    correlationId: nil
                )
            }
        }

        @Test("IPC Review selection preserves item-not-found validation")
        func ipcReviewSelection_preservesItemNotFoundValidation() async throws {
            let worktreeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
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
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: .unstaged)
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    contentType: .diff,
                    title: "Bridge Review",
                    facets: PaneContextFacets(worktreeId: worktreeId)
                ),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            try await showIPCReviewPageAndAwaitInitialPackage(controller)

            await #expect(throws: BridgeIPCProjectionError(reason: .itemNotFound)) {
                _ = try await controller.selectReviewItemForIPC(
                    itemId: "missing-item",
                    correlationId: nil
                )
            }
        }

        @Test("IPC Review selection without a current metadata stream fails and cannot replay")
        func ipcReviewSelection_withoutCurrentMetadataStreamFailsAndCannotReplay() async throws {
            let controller = try await makeIPCReviewSelectionController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

            await #expect(throws: CancellationError.self) {
                _ = try await controller.selectReviewItemForIPC(
                    itemId: "item-source",
                    correlationId: nil
                )
            }

            #expect(controller.selectedReviewItemId == nil)
            let snapshot = controller.surfaceSelectionAuthority.diagnosticSnapshot
            #expect(snapshot.currentRequest == nil)
            #expect(snapshot.desiredSurface == nil)
            #expect(snapshot.lastAcceptedRequest == nil)
            #expect(!snapshot.needsDelivery)
        }

        @Test("IPC Review selection completes after accepted native publication without active-viewer receipt")
        func ipcReviewSelection_completesAfterNativePublicationWithoutActiveViewerReceipt() async throws {
            let controller = try await makeIPCReviewSelectionController()
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let installation = try #require(await controller.productSessionOwner.activeInstallation)
            let productProvider = try #require(controller.productSchemeProvider)
            let productAdmission = try #require(controller.productAdmissionGate.acquire())
            let metadataProducerLease = try await installRefreshAdmissionMetadataProducer(
                installation: installation,
                productProvider: productProvider,
                productAdmission: productAdmission
            )

            let result = try await controller.selectReviewItemForIPC(
                itemId: "item-source",
                correlationId: nil
            )
            let request = try await consumeIPCReviewSelectionRequest(
                metadataProducerLease: metadataProducerLease,
                installation: installation,
                productAdmission: productAdmission
            )

            #expect(result.itemId == "item-source")
            #expect(result.selected)
            #expect(controller.selectedReviewItemId == "item-source")
            guard case .activateReviewTarget(_, _, let source, let target) = request.navigationCommand
            else {
                Issue.record("Expected an exact Review navigation command in the metadata stream")
                return
            }
            let committedPackage = try #require(controller.paneState.diff.packageMetadata)
            #expect(source.metadataSourceId == committedPackage.query.queryId)
            #expect(source.generation == committedPackage.reviewGeneration.rawValue)
            #expect(source.packageId == committedPackage.packageId)
            #expect(target.reviewItemId == "item-source")

            try await closeBridgeProductSessionProducer(
                metadataProducerLease,
                in: installation.session
            )
            await productProvider.closeAndDrain()
            await #expect(throws: CancellationError.self) {
                _ = try await controller.selectReviewItemForIPC(
                    itemId: "item-source",
                    correlationId: nil
                )
            }
        }

        @Test("IPC telemetry snapshot reports package status without exposing samples")
        func ipcTelemetrySnapshot_reportsPackageStatusWithoutExposingSamples() async throws {
            let worktreeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let provider = BridgeReviewSourceProviderFake(
                comparison: BridgeEndpointComparison(
                    baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
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
            let controller = BridgePaneController(
                paneId: UUIDv7.generate(),
                state: BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/worktree",
                        baseline: .unstaged)
                ),
                appRootURL: testBridgeAppRootURL(),
                metadata: PaneMetadata(
                    contentType: .diff,
                    title: "Bridge Review",
                    facets: PaneContextFacets(worktreeId: worktreeId)
                ),
                reviewSourceProvider: provider,
                initialPaneActivity: .foreground
            )
            defer { _ = controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            try await showIPCReviewPageAndAwaitInitialPackage(controller)

            let snapshot = try await controller.telemetrySnapshotForIPC()

            #expect(snapshot.paneId == controller.paneId)
            #expect(snapshot.kind == .unavailable)
            #expect(snapshot.unavailableReason == .disabled)
            #expect(snapshot.report == nil)
        }
    }
}

@MainActor
private func makeIPCForegroundController() -> BridgePaneController {
    BridgePaneController(
        paneId: UUIDv7.generate(),
        state: BridgePaneState(panelKind: .diffViewer, source: nil),
        appRootURL: testBridgeAppRootURL(),
        initialPaneActivity: .foreground
    )
}

@MainActor
private func showIPCReviewPageAndAwaitInitialPackage(
    _ controller: BridgePaneController
) async throws {
    let productAdmission = try #require(controller.productAdmissionGate.acquire())
    await sendPageActiveViewerMode(
        .review,
        controller: controller,
        productAdmission: productAdmission,
        sequence: 1
    )
    if let initialReviewBuild = controller.activeReviewRefreshTask {
        await initialReviewBuild.value
    }
}

@MainActor
private func makeIPCReviewSelectionController() async throws -> BridgePaneController {
    let worktreeId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let provider = BridgeReviewSourceProviderFake(
        comparison: BridgeEndpointComparison(
            baseEndpoint: makeBridgeEndpoint(endpointId: "index", kind: .index),
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
    let controller = BridgePaneController(
        paneId: UUIDv7.generate(),
        state: BridgePaneState(
            panelKind: .diffViewer,
            source: .workspace(
                rootPath: "/tmp/worktree", baseline: .unstaged)
        ),
        appRootURL: testBridgeAppRootURL(),
        metadata: PaneMetadata(
            contentType: .diff,
            title: "Bridge Review",
            facets: PaneContextFacets(worktreeId: worktreeId)
        ),
        reviewSourceProvider: provider,
        initialPaneActivity: .foreground
    )
    try await showIPCReviewPageAndAwaitInitialPackage(controller)
    return controller
}

private func consumeIPCReviewSelectionRequest(
    metadataProducerLease: BridgeProductProducerLease,
    installation: BridgeProductSessionInstallation,
    productAdmission: BridgeProductAdmissionContext
) async throws -> BridgeProductPaneSurfaceSelectionRequestedFrame {
    for _ in 0..<16 {
        let queuedFrame = try #require(
            await consumeNextBridgeProductProducerFrame(
                for: metadataProducerLease,
                from: installation.session,
                productAdmission: productAdmission
            )
        )
        let decoder = try BridgeProductMetadataFrameDecoder()
        guard let frame = try decoder.append(queuedFrame.data).first else { continue }
        if case .paneSurfaceSelectionRequested(let request) = frame {
            return request
        }
    }
    throw IPCReviewSelectionTestError.expectedSurfaceSelectionFrame
}

private enum IPCReviewSelectionTestError: Error {
    case expectedSurfaceSelectionFrame
}

@MainActor
private func installIPCContentDescriptorPackage(
    _ handle: BridgeContentHandle,
    revision: Int = 0,
    in controller: BridgePaneController
) async throws {
    let baseEndpoint = makeBridgeEndpoint(endpointId: "base", kind: .gitRef)
    let headEndpoint = makeBridgeEndpoint(endpointId: handle.endpointId, kind: .workingTree)
    let descriptor = makeBridgeReviewItemDescriptor(
        itemId: handle.itemId,
        path: "\(handle.itemId).swift",
        fileClass: .source,
        contentRoles: BridgeReviewItemDescriptor.ContentRoles(head: handle)
    )
    let package = BridgeReviewPackage(
        packageId: "ipc-content-descriptor-package",
        schemaVersion: 1,
        reviewGeneration: handle.reviewGeneration,
        revision: revision,
        query: makeBridgeReviewQuery(
            baseEndpointId: baseEndpoint.endpointId,
            headEndpointId: headEndpoint.endpointId
        ),
        baseEndpoint: baseEndpoint,
        headEndpoint: headEndpoint,
        orderedItemIds: [handle.itemId],
        itemsById: [handle.itemId: descriptor],
        groups: [],
        summary: BridgeReviewPackageSummary(
            filesChanged: 1,
            additions: 0,
            deletions: 0,
            visibleFileCount: 1,
            hiddenFileCount: 0
        ),
        filterState: BridgeViewFilter(),
        generatedAtUnixMilliseconds: 1
    )
    let preparedPublication = try #require(
        await BridgeReviewPreparedPublication.prepare(
            BridgeReviewPublicationCandidate(
                package: package,
                delta: nil,
                contentHandles: [handle]
            )
        )
    )
    let productAdmission = try #require(controller.productAdmissionGate.acquire())
    let token = try #require(
        controller.reviewPublicationCoordinator.stage(
            preparedPublication,
            productAdmission: productAdmission
        )
    )
    guard
        case .committed = controller.reviewPublicationCoordinator.commit(
            token,
            productAdmission: productAdmission,
            captureCommittedPresentation: { _ in
                controller.refreshAdmissionCoordinator.productPresentationSnapshot
            },
            presentCommitted: { committedPublication in
                controller.paneState.diff.setPackageMetadata(committedPublication.package)
            }
        )
    else {
        Issue.record("Expected IPC content descriptor publication to commit")
        return
    }
}

private func makeIPCReviewItemDescriptor(
    itemId: String,
    itemKind: BridgeReviewItemDescriptor.Kind,
    basePath: String?,
    headPath: String?,
    changeKind: BridgeFileChangeKind,
    collapsed: Bool
) -> BridgeReviewItemDescriptor {
    let handle = makeBridgeContentHandle(itemId: itemId, role: .head)
    let contentRoles = BridgeReviewItemDescriptor.ContentRoles(head: handle)
    return BridgeReviewItemDescriptor(
        itemId: itemId,
        itemKind: itemKind,
        itemVersion: 1,
        basePath: basePath,
        headPath: headPath,
        changeKind: changeKind,
        fileClass: .source,
        language: "swift",
        extension: "swift",
        sizeBytes: 100,
        baseContentHash: basePath == nil ? nil : "sha256:base-\(itemId)",
        headContentHash: headPath == nil ? nil : "sha256:head-\(itemId)",
        contentHashAlgorithm: "sha256",
        additions: 1,
        deletions: 1,
        isHiddenByDefault: false,
        hiddenReason: nil,
        reviewPriority: .normal,
        contentRoles: contentRoles,
        cacheKey: handle.cacheKey,
        provenance: BridgeProvenanceSummary(),
        annotationSummary: BridgeAnnotationSummary(
            threadCount: 0,
            unresolvedThreadCount: 0,
            commentCount: 0
        ),
        reviewState: .unreviewed,
        collapsed: collapsed
    )
}

private func makeIPCReviewPackage(
    descriptors: [BridgeReviewItemDescriptor],
    orderedItemIds: [String],
    comparisonOrigin: BridgeReviewComparisonOrigin? = nil,
    reviewedSubjectLabel: String? = nil
) -> BridgeReviewPackage {
    let baseEndpoint = makeBridgeEndpoint(endpointId: "base", kind: .gitRef)
    let headEndpoint = makeBridgeEndpoint(endpointId: "head", kind: .workingTree)
    return BridgeReviewPackage(
        packageId: "ipc-review-package",
        schemaVersion: 1,
        reviewGeneration: BridgeReviewGeneration(1),
        revision: 1,
        query: makeBridgeReviewQuery(
            baseEndpointId: baseEndpoint.endpointId,
            headEndpointId: headEndpoint.endpointId
        ),
        baseEndpoint: baseEndpoint,
        headEndpoint: headEndpoint,
        orderedItemIds: orderedItemIds,
        itemsById: Dictionary(uniqueKeysWithValues: descriptors.map { ($0.itemId, $0) }),
        groups: [],
        summary: BridgeReviewPackageSummary(
            filesChanged: descriptors.count,
            additions: descriptors.reduce(0) { $0 + $1.additions },
            deletions: descriptors.reduce(0) { $0 + $1.deletions },
            visibleFileCount: descriptors.count,
            hiddenFileCount: 0
        ),
        filterState: BridgeViewFilter(),
        generatedAtUnixMilliseconds: 1,
        comparisonOrigin: comparisonOrigin,
        reviewedSubjectLabel: reviewedSubjectLabel
    )
}
