import AgentStudioGit
import AgentStudioInfrastructure
import CryptoKit
import Foundation
import os.log

private let annotationSourceContextLogger = Logger(
    subsystem: "com.agentstudio",
    category: "WorktreeAnnotationSourceContext"
)

enum WorktreeAnnotationSourceCapture {
    struct LocatedOriginProps {
        let data: Data
        let path: String
        let startLine: Int
        let endLine: Int
        let sourceRole: WorktreeAnnotationSourceRole
        let diffSide: WorktreeAnnotationDiffSide?
        let sourceIdentity: String
    }

    static func locatedOrigin(_ props: LocatedOriginProps) throws -> WorktreeAnnotationLocatedOrigin {
        guard let source = String(bytes: props.data, encoding: .utf8) else {
            throw WorktreeAnnotationSourceResolutionError.unavailable
        }
        let lines = worktreeAnnotationSourceFileLines(source)
        guard props.startLine > 0, props.endLine >= props.startLine, props.endLine <= lines.count else {
            throw WorktreeAnnotationSourceResolutionError.invalidSource
        }
        let selectedExcerpt = lines[(props.startLine - 1)...(props.endLine - 1)].joined(separator: "\n")
        let contextBefore = props.startLine > 1 ? lines[props.startLine - 2] : nil
        let contextAfter = props.endLine < lines.count ? lines[props.endLine] : nil
        return WorktreeAnnotationLocatedOrigin(
            repositoryRelativePath: props.path,
            startLine: props.startLine,
            endLine: props.endLine,
            sourceRole: props.sourceRole,
            diffSide: props.diffSide,
            sourceIdentity: props.sourceIdentity,
            selectedExcerpt: selectedExcerpt,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )
    }

    static func resolver(
        fileMetadataSource: any BridgePaneProductFileMetadataProducing,
        reviewPublicationCoordinator: BridgeReviewPublicationCoordinator,
        reviewContentLoaderCache: BridgeReviewContentLoaderCache,
        gitEvidenceSource: (any WorktreeAnnotationGitEvidenceSource)? = nil
    ) -> WorktreeAnnotationSourceResolver {
        WorktreeAnnotationSourceResolver(
            capture: { origin, surface, reviewPublicationIdentity, productAdmission in
                switch surface {
                case .file:
                    try await fileMetadataSource.captureWorktreeAnnotationSource(
                        origin: origin,
                        productAdmission: productAdmission
                    )
                case .review:
                    try await captureReviewSource(
                        origin: origin,
                        identity: try requireReviewIdentity(reviewPublicationIdentity),
                        publicationCoordinator: reviewPublicationCoordinator,
                        contentLoaderCache: reviewContentLoaderCache,
                        productAdmission: productAdmission
                    )
                }
            },
            currentFingerprint: { surface, reviewPublicationIdentity, productAdmission in
                switch surface {
                case .file:
                    try await fileMetadataSource.currentWorktreeAnnotationFingerprint(
                        productAdmission: productAdmission
                    )
                case .review:
                    try await reviewFingerprint(
                        identity: try requireReviewIdentity(reviewPublicationIdentity),
                        publicationCoordinator: reviewPublicationCoordinator,
                        productAdmission: productAdmission
                    )
                }
            },
            refresh: { surface, reviewPublicationIdentity, productAdmission, requirements in
                switch surface {
                case .file:
                    try await fileMetadataSource.currentWorktreeAnnotationRefresh(
                        requirements: requirements,
                        productAdmission: productAdmission
                    )
                case .review:
                    try await reviewRefresh(
                        identity: try requireReviewIdentity(reviewPublicationIdentity),
                        publicationCoordinator: reviewPublicationCoordinator,
                        contentLoaderCache: reviewContentLoaderCache,
                        requirements: requirements,
                        productAdmission: productAdmission
                    )
                }
            },
            currentSourceGeneration: { surface, reviewPublicationIdentity, productAdmission in
                switch surface {
                case .file:
                    return try await fileMetadataSource.currentWorktreeAnnotationSourceGeneration(
                        productAdmission: productAdmission
                    )
                case .review:
                    let publication = try await retainedReviewPublication(
                        identity: try requireReviewIdentity(reviewPublicationIdentity),
                        publicationCoordinator: reviewPublicationCoordinator,
                        productAdmission: productAdmission
                    )
                    return publication.package.reviewGeneration.rawValue
                }
            },
            currentReviewedSubjectEvidence: { surface, reviewPublicationIdentity, productAdmission in
                switch surface {
                case .file:
                    guard let gitEvidenceSource else {
                        throw WorktreeAnnotationSourceResolutionError.unavailable
                    }
                    let sourceGeneration =
                        try await fileMetadataSource
                        .currentWorktreeAnnotationSourceGeneration(productAdmission: productAdmission)
                    return try await gitEvidenceSource.currentWorktreeAnnotationReviewedSubjectEvidence(
                        sourceGeneration: sourceGeneration
                    )
                case .review:
                    let publication = try await retainedReviewPublication(
                        identity: try requireReviewIdentity(reviewPublicationIdentity),
                        publicationCoordinator: reviewPublicationCoordinator,
                        productAdmission: productAdmission
                    )
                    return try reviewedSubjectEvidence(for: publication.package)
                }
            },
            ancestryDisposition: { acceptedOID, currentOID, sourceGeneration in
                guard let gitEvidenceSource else { return .readFailure }
                return try await gitEvidenceSource.worktreeAnnotationAncestryDisposition(
                    acceptedReviewedHeadOID: acceptedOID,
                    currentReviewedHeadOID: currentOID,
                    sourceGeneration: sourceGeneration
                )
            }
        )
    }

    static func reviewRefresh(
        identity: BridgeProductReviewAnnotationPublicationIdentity,
        publicationCoordinator: BridgeReviewPublicationCoordinator,
        contentLoaderCache: BridgeReviewContentLoaderCache,
        requirements: [WorktreeAnnotationSourceRefreshRequirement],
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSourceRefreshCapture {
        let publication = try await retainedReviewPublication(
            identity: identity,
            publicationCoordinator: publicationCoordinator,
            productAdmission: productAdmission
        )
        let fingerprint = try reviewFingerprint(for: publication.package)
        let candidates = try reviewRefreshCandidates(
            requirements: requirements,
            package: publication.package
        )
        return WorktreeAnnotationSourceRefreshCapture(
            fingerprint: fingerprint,
            material: await reviewMaterial(
                candidates: candidates,
                publication: publication,
                contentLoaderCache: contentLoaderCache,
                productAdmission: productAdmission
            )
        )
    }

    private struct ReviewRefreshCandidate {
        let itemID: String
        let path: String
        let sourceRole: WorktreeAnnotationSourceRole
        let handle: BridgeContentHandle
        let dependentThreadIDs: Set<WorktreeAnnotationThreadID>
    }

    private struct ReviewSourceLoadAdmission {
        let affectedItemIDs: Set<String>
        let cachedUnaffectedResultByHandleID: [String: BridgeContentLoadResult]
    }

    private struct ReviewRefreshRequirement {
        let threadID: WorktreeAnnotationThreadID
        let fallbackPath: String?
        let sourceRole: WorktreeAnnotationSourceRole
        let sourceIdentity: String?
        let exactHandleID: String?
    }

    private struct ReviewRefreshHandleKey: Hashable {
        let sourceRole: String
        let handleID: String
    }

    private static func reviewRefreshCandidates(
        requirements: [WorktreeAnnotationSourceRefreshRequirement],
        package: BridgeReviewPackage
    ) throws -> [ReviewRefreshCandidate] {
        let orderedItems = try package.orderedItemIds.map { itemID in
            guard let item = package.itemsById[itemID] else {
                throw WorktreeAnnotationSourceResolutionError.invalidSource
            }
            return item
        }
        let availableHandleKeys = Set(
            orderedItems.flatMap { item in
                [
                    item.contentRoles.base.map {
                        ReviewRefreshHandleKey(
                            sourceRole: WorktreeAnnotationSourceRole.reviewBase.rawValue,
                            handleID: $0.handleId
                        )
                    },
                    item.contentRoles.head.map {
                        ReviewRefreshHandleKey(
                            sourceRole: WorktreeAnnotationSourceRole.reviewHead.rawValue,
                            handleID: $0.handleId
                        )
                    },
                ].compactMap { $0 }
            }
        )
        let normalizedRequirements = try requirements.compactMap { requirement in
            try reviewRefreshRequirement(requirement)
        }.map { requirement in
            let exactHandleID = requirement.sourceIdentity.flatMap { sourceIdentity in
                availableHandleKeys.contains(
                    ReviewRefreshHandleKey(
                        sourceRole: requirement.sourceRole.rawValue,
                        handleID: sourceIdentity
                    )
                ) ? sourceIdentity : nil
            }
            let fallbackPath: String? = requirement.fallbackPath.flatMap { fallbackPath in
                guard exactHandleID == nil,
                    orderedItems.contains(where: { item in
                        reviewRefreshCandidate(for: requirement, item: item)?.path == fallbackPath
                    })
                else { return nil }
                return fallbackPath
            }
            return ReviewRefreshRequirement(
                threadID: requirement.threadID,
                fallbackPath: fallbackPath,
                sourceRole: requirement.sourceRole,
                sourceIdentity: requirement.sourceIdentity,
                exactHandleID: exactHandleID
            )
        }
        var candidateIndexByHandleKey: [ReviewRefreshHandleKey: Int] = [:]
        var candidates: [ReviewRefreshCandidate] = []
        for item in orderedItems {
            for requirement in normalizedRequirements {
                guard let candidate = reviewRefreshCandidate(for: requirement, item: item) else {
                    continue
                }
                let handleKey = ReviewRefreshHandleKey(
                    sourceRole: candidate.sourceRole.rawValue,
                    handleID: candidate.handle.handleId
                )
                if let index = candidateIndexByHandleKey[handleKey] {
                    let existing = candidates[index]
                    candidates[index] = ReviewRefreshCandidate(
                        itemID: existing.itemID,
                        path: existing.path,
                        sourceRole: existing.sourceRole,
                        handle: existing.handle,
                        dependentThreadIDs: existing.dependentThreadIDs.union(
                            candidate.dependentThreadIDs
                        )
                    )
                } else {
                    candidateIndexByHandleKey[handleKey] = candidates.count
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    private static func reviewRefreshRequirement(
        _ requirement: WorktreeAnnotationSourceRefreshRequirement
    ) throws -> ReviewRefreshRequirement? {
        switch requirement.origin {
        case .session:
            return nil
        case .wholeFile(let path, let sourceRole):
            guard sourceRole == .reviewBase || sourceRole == .reviewHead else { return nil }
            return ReviewRefreshRequirement(
                threadID: requirement.threadID,
                fallbackPath: path,
                sourceRole: sourceRole,
                sourceIdentity: nil,
                exactHandleID: nil
            )
        case .located(let origin):
            guard origin.sourceRole == .reviewBase || origin.sourceRole == .reviewHead else {
                return nil
            }
            return ReviewRefreshRequirement(
                threadID: requirement.threadID,
                fallbackPath: origin.repositoryRelativePath,
                sourceRole: origin.sourceRole,
                sourceIdentity: origin.sourceIdentity,
                exactHandleID: nil
            )
        }
    }

    private static func reviewRefreshCandidate(
        for requirement: ReviewRefreshRequirement,
        item: BridgeReviewItemDescriptor
    ) -> ReviewRefreshCandidate? {
        let currentPath: String?
        let handle: BridgeContentHandle?
        switch requirement.sourceRole {
        case .reviewBase:
            currentPath = item.basePath
            handle = item.contentRoles.base
        case .reviewHead:
            currentPath = item.headPath
            handle = item.contentRoles.head
        case .file:
            return nil
        }
        guard let currentPath, let handle else { return nil }
        if let exactHandleID = requirement.exactHandleID {
            guard handle.handleId == exactHandleID else { return nil }
        } else if let fallbackPath = requirement.fallbackPath {
            guard currentPath == fallbackPath else { return nil }
        }
        return ReviewRefreshCandidate(
            itemID: item.itemId,
            path: currentPath,
            sourceRole: requirement.sourceRole,
            handle: handle,
            dependentThreadIDs: [requirement.threadID]
        )
    }

    private static func reviewMaterial(
        candidates: [ReviewRefreshCandidate],
        publication: BridgeReviewCommittedPublication,
        contentLoaderCache: BridgeReviewContentLoaderCache,
        productAdmission: BridgeProductAdmissionContext
    ) async -> WorktreeAnnotationSourceMaterial {
        guard !candidates.isEmpty,
            candidates.count <= AppPolicies.Bridge.worktreeAnnotationMaximumSourceCandidateCount
        else {
            return .unavailable
        }
        let proportionalAdmission = await reviewSourceLoadAdmission(
            candidates: candidates,
            publication: publication,
            contentLoaderCache: contentLoaderCache,
            productAdmission: productAdmission
        )
        var files: [WorktreeAnnotationCurrentSourceFile] = []
        var unavailableThreadIDs = Set<WorktreeAnnotationThreadID>()
        files.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard !candidate.path.isEmpty,
                !candidate.handle.isBinary,
                candidate.handle.sizeBytes
                    <= AppPolicies.Bridge.worktreeAnnotationMaximumSourceFileByteCount
            else {
                unavailableThreadIDs.formUnion(candidate.dependentThreadIDs)
                continue
            }
            let result: BridgeContentLoadResult
            if let proportionalAdmission,
                !proportionalAdmission.affectedItemIDs.contains(candidate.itemID)
            {
                guard
                    let cachedResult = proportionalAdmission.cachedUnaffectedResultByHandleID[
                        candidate.handle.handleId
                    ]
                else {
                    unavailableThreadIDs.formUnion(candidate.dependentThreadIDs)
                    continue
                }
                result = cachedResult
            } else {
                do {
                    result = try await contentLoaderCache.load(
                        handle: candidate.handle,
                        productAdmission: productAdmission
                    )
                } catch {
                    unavailableThreadIDs.formUnion(candidate.dependentThreadIDs)
                    continue
                }
            }
            guard
                result.data.count
                    <= AppPolicies.Bridge.worktreeAnnotationMaximumSourceFileByteCount,
                let body = String(data: result.data, encoding: .utf8)
            else {
                unavailableThreadIDs.formUnion(candidate.dependentThreadIDs)
                continue
            }
            files.append(
                WorktreeAnnotationCurrentSourceFile(
                    path: candidate.path,
                    sourceRole: candidate.sourceRole,
                    sourceIdentity: candidate.handle.handleId,
                    body: body
                )
            )
        }
        guard !unavailableThreadIDs.isEmpty else { return .available(files) }
        return .availableWithThreadFailures(
            files: files,
            unavailableThreadIDs: unavailableThreadIDs
        )
    }

    private static func reviewSourceLoadAdmission(
        candidates: [ReviewRefreshCandidate],
        publication: BridgeReviewCommittedPublication,
        contentLoaderCache: BridgeReviewContentLoaderCache,
        productAdmission: BridgeProductAdmissionContext
    ) async -> ReviewSourceLoadAdmission? {
        guard let affectedItemIDs = reviewSourceLoadAffectedItemIDs(publication: publication) else {
            return nil
        }
        let unaffectedHandles = candidates.compactMap { candidate in
            affectedItemIDs.contains(candidate.itemID) ? nil : candidate.handle
        }
        guard
            let cachedResults = await contentLoaderCache.cachedResultsIfAllResident(
                handles: unaffectedHandles,
                productAdmission: productAdmission
            )
        else { return nil }
        return ReviewSourceLoadAdmission(
            affectedItemIDs: affectedItemIDs,
            cachedUnaffectedResultByHandleID: cachedResults
        )
    }

    static func reviewSourceLoadAffectedItemIDs(
        publication: BridgeReviewCommittedPublication
    ) -> Set<String>? {
        guard let delta = publication.delta,
            publication.package.revision > 0,
            delta.packageId == publication.package.packageId,
            delta.reviewGeneration == publication.package.reviewGeneration,
            delta.revision == publication.package.revision
        else { return nil }
        let addedItemIDs = delta.operations.addItems.map(\.itemId)
        let updatedItemIDs = delta.operations.updateItems.map(\.itemId)
        let removedItemIDs = delta.operations.removeItems
        let affectedItemIDs = Set(addedItemIDs + updatedItemIDs + removedItemIDs)
        guard affectedItemIDs.count == addedItemIDs.count + updatedItemIDs.count + removedItemIDs.count,
            addedItemIDs.allSatisfy({ publication.package.itemsById[$0] != nil }),
            updatedItemIDs.allSatisfy({ publication.package.itemsById[$0] != nil }),
            removedItemIDs.allSatisfy({ publication.package.itemsById[$0] == nil })
        else { return nil }
        return affectedItemIDs
    }

    private static func captureReviewSource(
        origin: BridgeProductWorktreeAnnotationOrigin,
        identity: BridgeProductReviewAnnotationPublicationIdentity,
        publicationCoordinator: BridgeReviewPublicationCoordinator,
        contentLoaderCache: BridgeReviewContentLoaderCache,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationCapturedSource {
        let publication = try await retainedReviewPublication(
            identity: identity,
            publicationCoordinator: publicationCoordinator,
            productAdmission: productAdmission
        )
        let fingerprint = try reviewFingerprint(for: publication.package)
        let resolved = try reviewHandle(
            path: origin.path,
            sourceRole: origin.sourceRole,
            package: publication.package
        )
        guard resolved.handle.handleId == origin.sourceIdentity else {
            throw WorktreeAnnotationSourceResolutionError.invalidSource
        }
        let content = try await contentLoaderCache.load(
            handle: resolved.handle,
            productAdmission: productAdmission
        )
        let locatedOrigin = try locatedOrigin(
            .init(
                data: content.data,
                path: origin.path,
                startLine: origin.startLine,
                endLine: origin.endLine,
                sourceRole: origin.sourceRole.domainValue,
                diffSide: origin.diffSide?.domainValue,
                sourceIdentity: origin.sourceIdentity
            )
        )
        return .init(fingerprint: fingerprint, origin: .located(locatedOrigin))
    }

    private static func reviewFingerprint(
        identity: BridgeProductReviewAnnotationPublicationIdentity,
        publicationCoordinator: BridgeReviewPublicationCoordinator,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSourceFingerprint {
        let publication = try await retainedReviewPublication(
            identity: identity,
            publicationCoordinator: publicationCoordinator,
            productAdmission: productAdmission
        )
        return try reviewFingerprint(for: publication.package)
    }

    private static func reviewedSubjectEvidence(
        for package: BridgeReviewPackage
    ) throws -> WorktreeAnnotationReviewedSubjectEvidence? {
        guard case .contribution(let comparisonOrigin)? = package.comparisonOrigin else {
            return nil
        }
        return try WorktreeAnnotationReviewedSubjectEvidence(
            branchName: comparisonOrigin.reviewedSubjectBranchName,
            reviewedHeadOID: comparisonOrigin.reviewedHeadOID
        )
    }

    private static func retainedReviewPublication(
        identity: BridgeProductReviewAnnotationPublicationIdentity,
        publicationCoordinator: BridgeReviewPublicationCoordinator,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewCommittedPublication {
        guard
            let publication = await publicationCoordinator.retainedPublication(
                matching: identity,
                productAdmission: productAdmission
            )
        else {
            throw WorktreeAnnotationSourceResolutionError.unavailable
        }
        return publication
    }

    private static func requireReviewIdentity(
        _ identity: BridgeProductReviewAnnotationPublicationIdentity?
    ) throws -> BridgeProductReviewAnnotationPublicationIdentity {
        guard let identity else { throw WorktreeAnnotationSourceResolutionError.unavailable }
        return identity
    }

    private static func reviewFingerprint(
        for package: BridgeReviewPackage
    ) throws -> WorktreeAnnotationSourceFingerprint {
        guard case .contribution(let comparisonOrigin)? = package.comparisonOrigin else {
            throw WorktreeAnnotationSourceResolutionError.unavailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let symbolicTargetData = try encoder.encode(comparisonOrigin.symbolicTarget)
        guard let symbolicTarget = String(data: symbolicTargetData, encoding: .utf8) else {
            throw WorktreeAnnotationSourceResolutionError.unavailable
        }
        return WorktreeAnnotationSourceFingerprint(
            repositoryID: package.query.repoId.uuidString.lowercased(),
            worktreeID: package.query.worktreeId.uuidString.lowercased(),
            fileSourceIdentity: nil,
            reviewComparisonOrigin: .init(
                symbolicTarget: symbolicTarget,
                resolvedTargetOID: comparisonOrigin.resolvedTargetOID,
                reviewedHeadOID: comparisonOrigin.reviewedHeadOID,
                baseRole: comparisonOrigin.baseRole.rawValue,
                baseOID: comparisonOrigin.baseOID
            )
        )
    }

    private static func reviewHandle(
        path: String,
        sourceRole: BridgeProductWorktreeAnnotationSourceRole,
        package: BridgeReviewPackage
    ) throws -> (item: BridgeReviewItemDescriptor, handle: BridgeContentHandle) {
        let matches: [(BridgeReviewItemDescriptor, BridgeContentHandle)] =
            package.itemsById.values.compactMap { item in
                switch sourceRole {
                case .reviewBase:
                    guard item.basePath == path, let handle = item.contentRoles.base else { return nil }
                    return (item, handle)
                case .reviewHead:
                    guard item.headPath == path, let handle = item.contentRoles.head else { return nil }
                    return (item, handle)
                case .file:
                    return nil
                }
            }
        guard matches.count == 1, let match = matches.first else {
            throw WorktreeAnnotationSourceResolutionError.invalidSource
        }
        return match
    }
}

extension BridgePaneProductFileMetadataSource {
    func worktreeAnnotationAdmissionDiagnostic(
        to productAdmission: BridgeProductAdmissionContext
    ) -> BridgeWorktreeAnnotationAdmissionDiagnostic {
        let relations = worktreeAnnotationContextRelations(to: productAdmission)
        return BridgeWorktreeAnnotationAdmissionDiagnostic(
            relations: relations,
            selectedGeneration: try? currentAnnotationContext(
                productAdmission: productAdmission
            ).productSource.subscriptionGeneration
        )
    }

    func worktreeAnnotationRepositoryPath() -> URL {
        authority.worktree.path
    }

    func worktreeAnnotationRefreshImplementation(
        requirements: [WorktreeAnnotationSourceRefreshRequirement],
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSourceRefreshCapture {
        let context = try currentAnnotationContext(productAdmission: productAdmission)
        var candidatePaths = Set<String>(
            context.descriptorByPath.compactMap { path, payload in
                guard case .available = payload.availability else { return nil }
                return path
            }
        )
        for requirement in requirements {
            switch requirement.origin {
            case .session:
                continue
            case .wholeFile(let path, let sourceRole):
                guard sourceRole == .file || sourceRole == .reviewHead else { continue }
                candidatePaths.insert(path)
            case .located(let origin):
                guard origin.sourceRole == .file || origin.sourceRole == .reviewHead else {
                    continue
                }
                candidatePaths.insert(origin.repositoryRelativePath)
            }
        }
        let candidates = candidatePaths.sorted().map { path in
            WorktreeAnnotationSourceMaterialCandidate(
                path: path,
                sourceRole: .file,
                sourceIdentity: .currentFileDescriptor,
                target: .workingTree
            )
        }
        let provider = GitWorktreeAnnotationSourceMaterialProvider(
            client: LibGit2AgentStudioGitLocalClient()
        )
        return WorktreeAnnotationSourceRefreshCapture(
            fingerprint: annotationFingerprint(for: context.productSource),
            material: await provider.material(
                .init(repositoryPath: authority.worktree.path, candidates: candidates)
            )
        )
    }

    func captureWorktreeAnnotationSource(
        origin: BridgeProductWorktreeAnnotationOrigin,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationCapturedSource {
        let context = try currentAnnotationContext(productAdmission: productAdmission)
        let fingerprint = annotationFingerprint(for: context.productSource)
        let descriptor = try annotationContentDescriptor(
            path: origin.path,
            sourceIdentity: origin.sourceIdentity,
            context: context
        )
        let data = try await readCompleteAnnotationFile(
            descriptor: descriptor,
            path: origin.path
        )
        return .init(
            fingerprint: fingerprint,
            origin: .located(
                try WorktreeAnnotationSourceCapture.locatedOrigin(
                    .init(
                        data: data,
                        path: origin.path,
                        startLine: origin.startLine,
                        endLine: origin.endLine,
                        sourceRole: origin.sourceRole.domainValue,
                        diffSide: origin.diffSide?.domainValue,
                        sourceIdentity: origin.sourceIdentity
                    )
                )
            )
        )
    }

    func worktreeAnnotationFingerprintImplementation(
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSourceFingerprint {
        let context = try currentAnnotationContext(productAdmission: productAdmission)
        return annotationFingerprint(for: context.productSource)
    }

    func worktreeAnnotationSourceGenerationImplementation(
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> Int {
        try currentAnnotationContext(productAdmission: productAdmission)
            .productSource.subscriptionGeneration
    }

    private func currentAnnotationContext(
        productAdmission: BridgeProductAdmissionContext
    ) throws -> SubscriptionContext {
        let contexts = contextBySubscriptionId.values.filter {
            $0.productAdmission.matches(productAdmission)
        }
        guard
            let context = contexts.max(by: {
                $0.productSource.subscriptionGeneration < $1.productSource.subscriptionGeneration
            })
        else {
            let diagnostic = worktreeAnnotationContextRelations(to: productAdmission)
            let sameGateCount = diagnostic.filter(\.sameGate).count
            let sameEpochCount = diagnostic.filter(\.sameEpoch).count
            let requestIsValid = productAdmission.withValidAdmission { true } == true
            annotationSourceContextLogger.error(
                """
                File annotation context unavailable: contexts=\(diagnostic.count, privacy: .public) \
                sameGate=\(sameGateCount, privacy: .public) sameEpoch=\(sameEpochCount, privacy: .public) \
                requestValid=\(requestIsValid, privacy: .public) latestGeneration=\(self.nextSourceGeneration, privacy: .public)
                """
            )
            throw WorktreeAnnotationSourceResolutionError.unavailable
        }
        return context
    }

    private func worktreeAnnotationContextRelations(
        to productAdmission: BridgeProductAdmissionContext
    ) -> [BridgeProductAdmissionDiagnosticRelation] {
        contextBySubscriptionId.values.map {
            $0.productAdmission.diagnosticRelation(to: productAdmission)
        }
    }

    private func annotationFingerprint(
        for productSource: BridgeProductFileSourceIdentity
    ) -> WorktreeAnnotationSourceFingerprint {
        WorktreeAnnotationSourceFingerprint(
            repositoryID: productSource.repoId.lowercased(),
            worktreeID: productSource.worktreeId.lowercased(),
            fileSourceIdentity: productSource.sourceId,
            reviewComparisonOrigin: nil
        )
    }

    private func annotationContentDescriptor(
        path: String,
        sourceIdentity: String,
        context: SubscriptionContext
    ) throws -> BridgeProductFileContentDescriptor {
        guard
            let payload = context.descriptorByPath[path],
            payload.source == context.productSource,
            case .available(let descriptor) = payload.availability,
            descriptor.descriptorId == sourceIdentity
        else {
            throw WorktreeAnnotationSourceResolutionError.invalidSource
        }
        return descriptor
    }

    private func readCompleteAnnotationFile(
        descriptor: BridgeProductFileContentDescriptor,
        path: String
    ) async throws -> Data {
        let plan = BridgePaneProductFileContentReadPlan(
            descriptor: descriptor,
            relativePath: path,
            rootURL: authority.worktree.path
        )
        let reader: any BridgePaneProductFileContentReading
        do {
            reader = try await BridgePaneProductFileContentSource.openReadSession(plan)
        } catch BridgePaneProductFileContentSourceError.sourceChanged {
            throw WorktreeAnnotationSourceResolutionError.invalidSource
        }
        var data = Data()
        do {
            while let chunk = try await reader.nextChunk(maximumByteCount: 128 * 1024) {
                data.append(chunk)
            }
            await reader.close()
        } catch {
            await reader.close()
            throw error
        }
        guard data.count == descriptor.declaredByteLength,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                == descriptor.expectedSha256
        else {
            throw WorktreeAnnotationSourceResolutionError.invalidSource
        }
        return data
    }
}

struct BridgeWorktreeAnnotationAdmissionDiagnostic: Equatable, Sendable {
    let relations: [BridgeProductAdmissionDiagnosticRelation]
    let selectedGeneration: Int?
}

extension BridgeProductWorktreeAnnotationSourceRole {
    fileprivate var domainValue: WorktreeAnnotationSourceRole {
        switch self {
        case .file: .file
        case .reviewBase: .reviewBase
        case .reviewHead: .reviewHead
        }
    }
}

extension BridgeProductWorktreeAnnotationDiffSide {
    fileprivate var domainValue: WorktreeAnnotationDiffSide {
        switch self {
        case .additions: .additions
        case .deletions: .deletions
        }
    }
}
