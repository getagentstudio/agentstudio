import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Worktree annotation source capture")
struct WorktreeAnnotationSourceCaptureTests {
    @Test("Review evidence comes from the retained publication without a Git HEAD read")
    func reviewEvidenceComesFromRetainedPublication() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let publication = makeReviewPackage(
            itemCount: 1,
            comparisonOrigin: .contribution(
                BridgeReviewContributionOrigin(
                    symbolicTarget: .originDefaultBranch(
                        remoteName: "origin",
                        branchName: "main"
                    ),
                    resolvedTargetOID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    reviewedHeadOID: "1111111111111111111111111111111111111111",
                    reviewedSubjectBranchName: "feature/x",
                    baseRole: .commonCommit,
                    baseOID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                )
            )
        )
        let publicationCoordinator = BridgeReviewPublicationCoordinator()
        let identity = try await commit(
            package: publication,
            coordinator: publicationCoordinator,
            productAdmission: productAdmission.context
        )
        let evidenceSource = WorktreeAnnotationGitEvidenceSourceFake()
        let resolver = WorktreeAnnotationSourceCapture.resolver(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewPublicationCoordinator: publicationCoordinator,
            reviewContentLoaderCache: BridgeReviewContentLoaderCache(
                provider: BridgeReviewSourceProviderFake(
                    comparison: BridgeEndpointComparison(
                        baseEndpoint: publication.baseEndpoint,
                        headEndpoint: publication.headEndpoint,
                        changedFiles: []
                    ),
                    contentByHandleId: [:]
                )
            ),
            gitEvidenceSource: evidenceSource
        )

        let evidence = try await resolver.currentReviewedSubjectEvidence(
            .review,
            identity,
            productAdmission.context
        )

        let expectedEvidence = try WorktreeAnnotationReviewedSubjectEvidence(
            branchName: "feature/x",
            reviewedHeadOID: "1111111111111111111111111111111111111111"
        )
        #expect(evidence == expectedEvidence)
        #expect(await evidenceSource.currentEvidenceCallCount() == 0)
    }
    @Test("Review refresh loads its exact head handle and ignores File-only origins")
    func reviewRefreshLoadsExactPublishedHeadHandleAndIgnoresFileOrigins() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let publication = makeReviewPackage(
            itemCount: 1,
            comparisonOrigin: .contribution(
                BridgeReviewContributionOrigin(
                    symbolicTarget: .branch(name: "main"),
                    resolvedTargetOID: "resolved-target-oid",
                    reviewedHeadOID: "committed-head-oid",
                    baseRole: .commonCommit,
                    baseOID: "base-oid"
                )
            )
        )
        let item = try #require(publication.itemsById[publication.orderedItemIds[0]])
        let headHandle = try #require(item.contentRoles.head)
        let headPath = try #require(item.headPath)
        let provider = BridgeReviewSourceProviderFake(
            comparison: BridgeEndpointComparison(
                baseEndpoint: publication.baseEndpoint,
                headEndpoint: publication.headEndpoint,
                changedFiles: []
            ),
            contentByHandleId: [
                headHandle.handleId: makeContentResult(handle: headHandle, data: "content")
            ]
        )
        let contentLoaderCache = BridgeReviewContentLoaderCache(provider: provider)
        let publicationCoordinator = BridgeReviewPublicationCoordinator()
        let identity = try await commit(
            package: publication,
            coordinator: publicationCoordinator,
            productAdmission: productAdmission.context
        )

        let capture = try await WorktreeAnnotationSourceCapture.reviewRefresh(
            identity: identity,
            publicationCoordinator: publicationCoordinator,
            contentLoaderCache: contentLoaderCache,
            requirements: [
                WorktreeAnnotationSourceRefreshRequirement(
                    threadID: WorktreeAnnotationThreadID(
                        rawValue: UUID(uuidString: "11111111-1111-7111-8111-111111111111")!
                    ),
                    origin: .located(
                        WorktreeAnnotationLocatedOrigin(
                            repositoryRelativePath: headPath,
                            startLine: 1,
                            endLine: 1,
                            sourceRole: .reviewHead,
                            diffSide: .additions,
                            sourceIdentity: headHandle.handleId,
                            selectedExcerpt: "content",
                            contextBefore: nil,
                            contextAfter: nil
                        )
                    )
                ),
                WorktreeAnnotationSourceRefreshRequirement(
                    threadID: WorktreeAnnotationThreadID(
                        rawValue: UUID(uuidString: "55555555-5555-7555-8555-555555555555")!
                    ),
                    origin: .located(
                        WorktreeAnnotationLocatedOrigin(
                            repositoryRelativePath: "Sources/FileOnly.swift",
                            startLine: 1,
                            endLine: 1,
                            sourceRole: .file,
                            diffSide: nil,
                            sourceIdentity: "file-source-1",
                            selectedExcerpt: "file content",
                            contextBefore: nil,
                            contextAfter: nil
                        )
                    )
                ),
            ],
            productAdmission: productAdmission.context
        )

        #expect(
            capture.material
                == .available([
                    WorktreeAnnotationCurrentSourceFile(
                        path: headPath,
                        sourceRole: .reviewHead,
                        sourceIdentity: headHandle.handleId,
                        body: "content"
                    )
                ])
        )
        #expect(await provider.recordedContentRequestsCount(handleId: headHandle.handleId) == 1)
    }

    @Test("Review refresh does not load unrelated package handles")
    func reviewRefreshDoesNotLoadUnrelatedPackageHandles() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let publication = makeReviewPackage(
            itemCount: 2,
            comparisonOrigin: .contribution(
                BridgeReviewContributionOrigin(
                    symbolicTarget: .branch(name: "main"),
                    resolvedTargetOID: "resolved-target-oid",
                    reviewedHeadOID: "committed-head-oid",
                    baseRole: .commonCommit,
                    baseOID: "base-oid"
                )
            )
        )
        let requiredItem = try #require(publication.itemsById[publication.orderedItemIds[0]])
        let requiredHandle = try #require(requiredItem.contentRoles.head)
        let requiredPath = try #require(requiredItem.headPath)
        let unrelatedItem = try #require(publication.itemsById[publication.orderedItemIds[1]])
        let unrelatedHandle = try #require(unrelatedItem.contentRoles.head)
        let provider = BridgeReviewSourceProviderFake(
            comparison: BridgeEndpointComparison(
                baseEndpoint: publication.baseEndpoint,
                headEndpoint: publication.headEndpoint,
                changedFiles: []
            ),
            contentByHandleId: [
                requiredHandle.handleId: makeContentResult(handle: requiredHandle, data: "content")
            ]
        )
        let contentLoaderCache = BridgeReviewContentLoaderCache(provider: provider)
        let publicationCoordinator = BridgeReviewPublicationCoordinator()
        let identity = try await commit(
            package: publication,
            coordinator: publicationCoordinator,
            productAdmission: productAdmission.context
        )

        let capture = try await WorktreeAnnotationSourceCapture.reviewRefresh(
            identity: identity,
            publicationCoordinator: publicationCoordinator,
            contentLoaderCache: contentLoaderCache,
            requirements: [
                WorktreeAnnotationSourceRefreshRequirement(
                    threadID: WorktreeAnnotationThreadID(
                        rawValue: UUID(uuidString: "22222222-2222-7222-8222-222222222222")!
                    ),
                    origin: .located(
                        WorktreeAnnotationLocatedOrigin(
                            repositoryRelativePath: requiredPath,
                            startLine: 1,
                            endLine: 1,
                            sourceRole: .reviewHead,
                            diffSide: .additions,
                            sourceIdentity: requiredHandle.handleId,
                            selectedExcerpt: "content",
                            contextBefore: nil,
                            contextAfter: nil
                        )
                    )
                )
            ],
            productAdmission: productAdmission.context
        )

        #expect(
            capture.material
                == .available([
                    WorktreeAnnotationCurrentSourceFile(
                        path: requiredPath,
                        sourceRole: .reviewHead,
                        sourceIdentity: requiredHandle.handleId,
                        body: "content"
                    )
                ])
        )
        #expect(await provider.recordedContentRequestsCount(handleId: requiredHandle.handleId) == 1)
        #expect(await provider.recordedContentRequestsCount(handleId: unrelatedHandle.handleId) == 0)
    }

    @Test("Review refresh prefers the exact handle over a colliding path")
    func reviewRefreshPrefersExactHandleOverCollidingPath() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let initialPublication = makeReviewPackage(
            itemCount: 2,
            comparisonOrigin: .contribution(
                BridgeReviewContributionOrigin(
                    symbolicTarget: .branch(name: "main"),
                    resolvedTargetOID: "resolved-target-oid",
                    reviewedHeadOID: "committed-head-oid",
                    baseRole: .commonCommit,
                    baseOID: "base-oid"
                )
            )
        )
        let requiredItemID = initialPublication.orderedItemIds[0]
        let collidingItemID = initialPublication.orderedItemIds[1]
        let requiredItem = try #require(initialPublication.itemsById[requiredItemID])
        let requiredHandle = try #require(requiredItem.contentRoles.head)
        let requiredPath = try #require(requiredItem.headPath)
        let collidingItem = makeBridgeReviewItemDescriptor(
            itemId: collidingItemID,
            path: requiredPath,
            fileClass: .source
        )
        let collidingHandle = try #require(collidingItem.contentRoles.head)
        let publication = replacingReviewPackage(
            initialPublication,
            revision: initialPublication.revision + 1,
            itemsById: [
                requiredItemID: requiredItem,
                collidingItemID: collidingItem,
            ]
        )
        let provider = BridgeReviewSourceProviderFake(
            comparison: BridgeEndpointComparison(
                baseEndpoint: publication.baseEndpoint,
                headEndpoint: publication.headEndpoint,
                changedFiles: []
            ),
            contentByHandleId: [
                requiredHandle.handleId: makeContentResult(handle: requiredHandle, data: "content")
            ]
        )
        let contentLoaderCache = BridgeReviewContentLoaderCache(provider: provider)
        let publicationCoordinator = BridgeReviewPublicationCoordinator()
        let identity = try await commit(
            package: publication,
            coordinator: publicationCoordinator,
            productAdmission: productAdmission.context
        )

        let capture = try await WorktreeAnnotationSourceCapture.reviewRefresh(
            identity: identity,
            publicationCoordinator: publicationCoordinator,
            contentLoaderCache: contentLoaderCache,
            requirements: [
                WorktreeAnnotationSourceRefreshRequirement(
                    threadID: WorktreeAnnotationThreadID(
                        rawValue: UUID(uuidString: "33333333-3333-7333-8333-333333333333")!
                    ),
                    origin: .located(
                        WorktreeAnnotationLocatedOrigin(
                            repositoryRelativePath: requiredPath,
                            startLine: 1,
                            endLine: 1,
                            sourceRole: .reviewHead,
                            diffSide: .additions,
                            sourceIdentity: requiredHandle.handleId,
                            selectedExcerpt: "content",
                            contextBefore: nil,
                            contextAfter: nil
                        )
                    )
                )
            ],
            productAdmission: productAdmission.context
        )

        #expect(
            capture.material
                == .available([
                    WorktreeAnnotationCurrentSourceFile(
                        path: requiredPath,
                        sourceRole: .reviewHead,
                        sourceIdentity: requiredHandle.handleId,
                        body: "content"
                    )
                ])
        )
        #expect(await provider.recordedContentRequestsCount(handleId: requiredHandle.handleId) == 1)
        #expect(await provider.recordedContentRequestsCount(handleId: collidingHandle.handleId) == 0)
    }

    @Test("Review refresh preserves ambiguous relocation evidence when the exact handle is absent")
    func reviewRefreshPreservesAmbiguousRelocationEvidenceWhenExactHandleIsAbsent() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let initialPublication = makeReviewPackage(
            itemCount: 2,
            comparisonOrigin: .contribution(
                BridgeReviewContributionOrigin(
                    symbolicTarget: .branch(name: "main"),
                    resolvedTargetOID: "resolved-target-oid",
                    reviewedHeadOID: "committed-head-oid",
                    baseRole: .commonCommit,
                    baseOID: "base-oid"
                )
            )
        )
        let renamedItemID = initialPublication.orderedItemIds[0]
        let duplicateItemID = initialPublication.orderedItemIds[1]
        let sourceBody = "before\nselected line\nafter\n"
        let renamedHandle = makeBridgeContentHandle(
            itemId: renamedItemID,
            role: .head,
            contentHash: bridgeSHA256ContentHash(sourceBody)
        )
        let duplicateHandle = makeBridgeContentHandle(
            itemId: duplicateItemID,
            role: .head,
            contentHash: bridgeSHA256ContentHash(sourceBody)
        )
        let renamedItem = reviewItem(
            try #require(initialPublication.itemsById[renamedItemID]),
            basePath: "Sources/Old.swift",
            headPath: "Sources/Renamed.swift",
            contentRoles: .init(head: renamedHandle)
        )
        let duplicateItem = reviewItem(
            try #require(initialPublication.itemsById[duplicateItemID]),
            basePath: "Sources/Duplicate.swift",
            headPath: "Sources/Duplicate.swift",
            contentRoles: .init(head: duplicateHandle)
        )
        let publication = replacingReviewPackage(
            initialPublication,
            revision: initialPublication.revision + 1,
            itemsById: [
                renamedItemID: renamedItem,
                duplicateItemID: duplicateItem,
            ]
        )
        let provider = BridgeReviewSourceProviderFake(
            comparison: BridgeEndpointComparison(
                baseEndpoint: publication.baseEndpoint,
                headEndpoint: publication.headEndpoint,
                changedFiles: []
            ),
            contentByHandleId: [
                renamedHandle.handleId: makeContentResult(handle: renamedHandle, data: sourceBody),
                duplicateHandle.handleId: makeContentResult(handle: duplicateHandle, data: sourceBody),
            ]
        )
        let contentLoaderCache = BridgeReviewContentLoaderCache(provider: provider)
        let publicationCoordinator = BridgeReviewPublicationCoordinator()
        let identity = try await commit(
            package: publication,
            coordinator: publicationCoordinator,
            productAdmission: productAdmission.context
        )
        let origin = WorktreeAnnotationLocatedOrigin(
            repositoryRelativePath: "Sources/Old.swift",
            startLine: 2,
            endLine: 2,
            sourceRole: .reviewHead,
            diffSide: .additions,
            sourceIdentity: "retired-head-handle",
            selectedExcerpt: "selected line",
            contextBefore: "before",
            contextAfter: "after"
        )

        let capture = try await WorktreeAnnotationSourceCapture.reviewRefresh(
            identity: identity,
            publicationCoordinator: publicationCoordinator,
            contentLoaderCache: contentLoaderCache,
            requirements: [
                WorktreeAnnotationSourceRefreshRequirement(
                    threadID: WorktreeAnnotationThreadID(
                        rawValue: UUID(uuidString: "44444444-4444-7444-8444-444444444444")!
                    ),
                    origin: .located(origin)
                )
            ],
            productAdmission: productAdmission.context
        )
        let placement = try reviewPlacement(
            origin: origin,
            fingerprint: capture.fingerprint,
            material: capture.material
        )

        #expect(placement == .outdated)
        #expect(await provider.recordedContentRequestsCount(handleId: renamedHandle.handleId) == 1)
        #expect(await provider.recordedContentRequestsCount(handleId: duplicateHandle.handleId) == 1)
    }

    @Test("Review refresh prefers the original path when a retired handle exceeds relocation bounds")
    func reviewRefreshPrefersOriginalPathWhenRetiredHandleExceedsRelocationBounds() async throws {
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let publication = makeReviewPackage(
            itemCount: AppPolicies.Bridge.worktreeAnnotationMaximumSourceCandidateCount + 1,
            comparisonOrigin: .contribution(
                BridgeReviewContributionOrigin(
                    symbolicTarget: .branch(name: "main"),
                    resolvedTargetOID: "resolved-target-oid",
                    reviewedHeadOID: "committed-head-oid",
                    baseRole: .commonCommit,
                    baseOID: "base-oid"
                )
            )
        )
        let requiredItem = try #require(publication.itemsById[publication.orderedItemIds[0]])
        let requiredHandle = try #require(requiredItem.contentRoles.head)
        let requiredPath = try #require(requiredItem.headPath)
        let sourceBody = "content"
        let provider = BridgeReviewSourceProviderFake(
            comparison: BridgeEndpointComparison(
                baseEndpoint: publication.baseEndpoint,
                headEndpoint: publication.headEndpoint,
                changedFiles: []
            ),
            contentByHandleId: [
                requiredHandle.handleId: makeContentResult(handle: requiredHandle, data: sourceBody)
            ]
        )
        let contentLoaderCache = BridgeReviewContentLoaderCache(provider: provider)
        let publicationCoordinator = BridgeReviewPublicationCoordinator()
        let identity = try await commit(
            package: publication,
            coordinator: publicationCoordinator,
            productAdmission: productAdmission.context
        )

        let capture = try await WorktreeAnnotationSourceCapture.reviewRefresh(
            identity: identity,
            publicationCoordinator: publicationCoordinator,
            contentLoaderCache: contentLoaderCache,
            requirements: [
                WorktreeAnnotationSourceRefreshRequirement(
                    threadID: WorktreeAnnotationThreadID(
                        rawValue: UUID(uuidString: "66666666-6666-7666-8666-666666666666")!
                    ),
                    origin: .located(
                        WorktreeAnnotationLocatedOrigin(
                            repositoryRelativePath: requiredPath,
                            startLine: 1,
                            endLine: 1,
                            sourceRole: .reviewHead,
                            diffSide: .additions,
                            sourceIdentity: "retired-head-handle",
                            selectedExcerpt: sourceBody,
                            contextBefore: nil,
                            contextAfter: nil
                        )
                    )
                )
            ],
            productAdmission: productAdmission.context
        )

        #expect(
            capture.material
                == .available([
                    WorktreeAnnotationCurrentSourceFile(
                        path: requiredPath,
                        sourceRole: .reviewHead,
                        sourceIdentity: requiredHandle.handleId,
                        body: sourceBody
                    )
                ])
        )
        #expect(await provider.recordedContentRequestsCount(handleId: requiredHandle.handleId) == 1)
    }

    @Test("Review refresh uses the named retained publication and identifies retirement")
    func reviewRefreshIdentifiesRetiredPublication() async throws {
        let admission = try BridgeProductAdmissionTestContext.make()
        let package = makeReviewPackage(
            itemCount: 1,
            comparisonOrigin: .contribution(
                .init(
                    symbolicTarget: .branch(name: "main"),
                    resolvedTargetOID: "target-oid",
                    reviewedHeadOID: "head-oid",
                    baseRole: .commonCommit,
                    baseOID: "base-oid"
                )
            )
        )
        let coordinator = BridgeReviewPublicationCoordinator()
        let identity = try await commit(
            package: package, coordinator: coordinator, productAdmission: admission.context
        )
        let cache = BridgeReviewContentLoaderCache(
            provider: BridgeReviewSourceProviderFake(
                comparison: .init(
                    baseEndpoint: package.baseEndpoint,
                    headEndpoint: package.headEndpoint,
                    changedFiles: []
                ),
                contentByHandleId: [:]
            )
        )
        let retained = try await WorktreeAnnotationSourceCapture.reviewRefresh(
            identity: identity,
            publicationCoordinator: coordinator,
            contentLoaderCache: cache,
            requirements: [],
            productAdmission: admission.context
        )
        #expect(retained.fingerprint.reviewComparisonOrigin?.reviewedHeadOID == "head-oid")
        _ = coordinator.close()
        await #expect(throws: WorktreeAnnotationSourceResolutionError.unavailable) {
            _ = try await WorktreeAnnotationSourceCapture.reviewRefresh(
                identity: identity,
                publicationCoordinator: coordinator,
                contentLoaderCache: cache,
                requirements: [],
                productAdmission: admission.context
            )
        }
    }

    private func commit(
        package: BridgeReviewPackage,
        coordinator: BridgeReviewPublicationCoordinator,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeProductReviewAnnotationPublicationIdentity {
        let prepared = try #require(
            await BridgeReviewPreparedPublication.prepare(
                BridgeReviewPublicationCandidate(
                    package: package,
                    delta: nil,
                    contentHandles: package.itemsById.values.flatMap(\.contentRoles.allHandles)
                )
            )
        )
        let token = try #require(
            coordinator.stage(prepared, productAdmission: productAdmission)
        )
        guard
            case .committed(let committedPublication) = coordinator.commit(
                token,
                productAdmission: productAdmission,
                captureCommittedPresentation: reviewCommittedPresentationSnapshot,
                presentCommitted: { _ in }
            )
        else {
            Issue.record("Expected Review publication commit")
            throw WorktreeAnnotationSourceResolutionError.unavailable
        }
        return try BridgeProductReviewAnnotationPublicationIdentity(
            packageId: committedPublication.package.packageId,
            publicationId: committedPublication.publicationId,
            reviewGeneration: committedPublication.package.reviewGeneration.rawValue,
            revision: committedPublication.package.revision,
            sourceIdentity: committedPublication.package.query.queryId
        )
    }

    private func reviewItem(
        _ item: BridgeReviewItemDescriptor,
        basePath: String,
        headPath: String,
        contentRoles: BridgeReviewItemDescriptor.ContentRoles
    ) -> BridgeReviewItemDescriptor {
        BridgeReviewItemDescriptor(
            itemId: item.itemId,
            itemKind: item.itemKind,
            itemVersion: item.itemVersion,
            basePath: basePath,
            headPath: headPath,
            changeKind: item.changeKind,
            fileClass: item.fileClass,
            language: item.language,
            extension: item.extension,
            sizeBytes: item.sizeBytes,
            baseContentHash: item.baseContentHash,
            headContentHash: contentRoles.head?.contentHash,
            contentHashAlgorithm: item.contentHashAlgorithm,
            additions: item.additions,
            deletions: item.deletions,
            isHiddenByDefault: item.isHiddenByDefault,
            hiddenReason: item.hiddenReason,
            reviewPriority: item.reviewPriority,
            contentRoles: contentRoles,
            cacheKey: contentRoles.allHandles.map(\.cacheKey).joined(separator: "|"),
            provenance: item.provenance,
            annotationSummary: item.annotationSummary,
            reviewState: item.reviewState,
            collapsed: item.collapsed
        )
    }

    private func reviewPlacement(
        origin: WorktreeAnnotationLocatedOrigin,
        fingerprint: WorktreeAnnotationSourceFingerprint,
        material: WorktreeAnnotationSourceMaterial
    ) throws -> WorktreeAnnotationPlacement? {
        let repository = try makeAnnotationRepository()
        let detail = try repository.createRootDraft(
            .init(
                admission: .implicitOrSingle,
                repositoryID: fingerprint.repositoryID,
                worktreeID: fingerprint.worktreeID,
                sourceFingerprint: fingerprint,
                origin: .located(origin),
                body: "Review this relocation",
                editToken: "review-relocation-editor",
                now: Date(timeIntervalSince1970: 2)
            )
        ).canonicalResult
        let evaluation = try WorktreeAnnotationSourceEvaluator.evaluate(
            .init(
                session: detail.session,
                threads: detail.threads.map(\.thread),
                surface: .review,
                sourceEpoch: "1",
                currentFingerprint: fingerprint,
                material: material
            )
        )
        let threadID = try #require(detail.threads.first?.thread.id)
        return evaluation.placements[threadID]?.placement
    }
}

private actor WorktreeAnnotationGitEvidenceSourceFake: WorktreeAnnotationGitEvidenceSource {
    private var evidenceCalls = 0

    func currentWorktreeAnnotationReviewedSubjectEvidence(
        sourceGeneration _: Int
    ) -> WorktreeAnnotationReviewedSubjectEvidence? {
        evidenceCalls += 1
        return nil
    }

    func worktreeAnnotationAncestryDisposition(
        acceptedReviewedHeadOID _: String,
        currentReviewedHeadOID _: String,
        sourceGeneration _: Int
    ) -> WorktreeAnnotationAncestryDisposition {
        .notEvaluated
    }

    func currentEvidenceCallCount() -> Int { evidenceCalls }
}
