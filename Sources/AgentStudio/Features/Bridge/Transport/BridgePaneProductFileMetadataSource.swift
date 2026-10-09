import AgentStudioCore
import Foundation

actor BridgePaneProductFileMetadataSource: BridgePaneProductFileMetadataProducing {
    struct SubscriptionContext: Sendable {
        let manifestIndex: BridgeWorktreeFileManifestIndex
        var openedSource: BridgeWorktreeFileOpenedSource
        var constructionLease: BridgeSharedFileSnapshotConsumerLease?
        let productAdmission: BridgeProductAdmissionContext
        let productSource: BridgeProductFileSourceIdentity
        var descriptorByPath: [String: BridgeProductFileDescriptorReadyPayload]
        var descriptorInterestRevisionByPath: [String: Int]
        var inFlightDescriptorInterestRevisionByPath: [String: Int]
        let subscription: BridgeProductSubscriptionSnapshot
        var viewDemand: BridgePaneProductFileViewDemand?
        var canonicalPathScope: [String]
        var demandGeneration: Int
        var initialEnumerationInFlight = true
        var deferredChangedPaths: Set<String> = []
        var deferredStatusResult: GitWorkingTreeStatusResult?
    }

    struct DescriptorReconciliationRequest: Sendable {
        let emit: BridgePaneProductFileSourceFactSink
        let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
        let productAdmission: BridgeProductAdmissionContext
        let productSource: BridgeProductFileSourceIdentity
        let rows: [BridgeWorktreeTreeRowMetadata]
        let subscriptionId: String
        let demand: BridgePaneProductFileViewDemand
        let demandGeneration: Int
    }

    struct InstalledContextBootstrapRequest: Sendable {
        let context: SubscriptionContext
        let emit: BridgePaneProductFileSourceFactSink
        let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
        let pathScope: [String]
        let productAdmission: BridgeProductAdmissionContext
        let productSource: BridgeProductFileSourceIdentity
        let sourceSpec: BridgeProductFileSourceSpec
        let subscription: BridgeProductSubscriptionSnapshot
    }

    struct InitialTreeEnumerationRequest: Sendable {
        let emit: BridgePaneProductFileSourceFactSink
        let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
        let manifestIndex: BridgeWorktreeFileManifestIndex
        let openedSource: BridgeWorktreeFileOpenedSource
        let pathScope: [String]
        let productAdmission: BridgeProductAdmissionContext
        let productSource: BridgeProductFileSourceIdentity
        let subscription: BridgeProductSubscriptionSnapshot
    }

    struct RefreshedTreeDeltaRequest: Sendable {
        let demandedPaths: [String: BridgeProductDemandLane]
        let emit: BridgePaneProductFileSourceFactSink
        let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
        let productAdmission: BridgeProductAdmissionContext
        let productSource: BridgeProductFileSourceIdentity
        let rows: [BridgeWorktreeTreeRowMetadata]
        let subscriptionId: String
        let demand: BridgePaneProductFileViewDemand
        let demandGeneration: Int
    }

    struct DescriptorUnavailablePathInvalidationRequest: Sendable {
        let emit: BridgePaneProductFileSourceFactSink
        let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
        let paths: Set<String>
        let productAdmission: BridgeProductAdmissionContext
        let productSource: BridgeProductFileSourceIdentity
        let subscriptionId: String
        let demand: BridgePaneProductFileViewDemand
        let demandGeneration: Int
    }

    let authority: BridgePaneProductFileSourceAuthority
    let descriptorMaterializer: BridgePaneProductFileDescriptorMaterializer
    let sharedConstructionBinder: BridgePaneProductFileSharedConstructionBinder
    let statusProvider: any GitWorkingTreeStatusProvider
    var sourceAcceptedObserver: BridgePaneProductFileSourceAcceptedObserver
    let treeRowRefresher: BridgePaneProductFileTreeRowRefresher
    let revisionFloorCapture: @Sendable (BridgeWorktreeFileManifestIndex) async -> Int
    var contextBySubscriptionId: [String: SubscriptionContext] = [:]
    var retiringContextBySubscriptionId: [String: SubscriptionContext] = [:]
    var nextSourceGeneration = 0
    var lastIssuedFileViewRevision = 0

    init(
        authority: BridgePaneProductFileSourceAuthority,
        gitReadContext: BridgeGitReadContext,
        constructionCoordinator: BridgeWorktreeProductConstructionCoordinator,
        sourceAcceptedObserver: @escaping BridgePaneProductFileSourceAcceptedObserver = { _ in },
        statusProvider: any GitWorkingTreeStatusProvider,
        revisionFloorCapture: @escaping @Sendable (BridgeWorktreeFileManifestIndex) async -> Int =
            BridgePaneProductFileMetadataSource.captureRevisionFloor,
        snapshotPreparationLoader: BridgePaneProductFileSnapshotPreparationLoader? = nil,
        sharedSnapshotBuilder: @escaping BridgePaneProductFileSharedSnapshotBuilder =
            BridgeWorktreeFileMaterializer.buildSharedSnapshot,
        ignorePolicyLoader: BridgePaneProductFileIgnorePolicyLoader? = nil,
        treeRowRefresher: BridgePaneProductFileTreeRowRefresher? = nil,
        descriptorMaterializer: @escaping BridgePaneProductFileDescriptorMaterializer =
            BridgePaneProductFileContentSource.materialize
    ) {
        self.authority = authority
        self.descriptorMaterializer = descriptorMaterializer
        self.statusProvider = statusProvider
        self.revisionFloorCapture = revisionFloorCapture
        let resolvedPreparationLoader: BridgePaneProductFileSnapshotPreparationLoader =
            if let snapshotPreparationLoader {
                snapshotPreparationLoader
            } else if let ignorePolicyLoader {
                { rootURL, _ in
                    async let ignorePolicy = ignorePolicyLoader(rootURL)
                    async let statusResult = statusProvider.statusResult(for: rootURL)
                    let preparation = await BridgeSharedFileSnapshotPreparation(
                        ignorePolicy: ignorePolicy,
                        statusResult: statusResult,
                        retainedByteCount: 0
                    )
                    return BridgeSharedFileSnapshotPreparation(
                        ignorePolicy: preparation.ignorePolicy,
                        statusResult: preparation.statusResult,
                        retainedByteCount:
                            BridgeWorktreeFileMaterializer.estimatedPreparationRetainedByteCount(
                                ignorePolicy: preparation.ignorePolicy,
                                statusResult: preparation.statusResult
                            )
                    )
                }
            } else {
                { rootURL, constructionGitReadContext in
                    await BridgeWorktreeFileMaterializer.prepareSharedSnapshot(
                        rootURL: rootURL,
                        gitReadContext: constructionGitReadContext,
                        statusProvider: statusProvider
                    )
                }
            }
        self.sharedConstructionBinder = BridgePaneProductFileSharedConstructionBinder(
            coordinator: constructionCoordinator,
            gitReadContext: gitReadContext,
            preparationLoader: resolvedPreparationLoader,
            snapshotBuilder: sharedSnapshotBuilder,
            worktree: authority.worktree
        )
        self.sourceAcceptedObserver = sourceAcceptedObserver
        self.treeRowRefresher =
            treeRowRefresher ?? { rootURL, relativePaths, includeAncestorDirectories in
                await BridgeWorktreeFileMaterializer.refreshTreeRows(
                    rootURL: rootURL,
                    relativePaths: relativePaths,
                    includeAncestorDirectories: includeAncestorDirectories
                )
            }
    }

    nonisolated static func captureRevisionFloor(_ index: BridgeWorktreeFileManifestIndex) async -> Int {
        await index.captureKeyedSnapshot().targetRevision
    }

    func setSourceAcceptedObserver(
        _ observer: @escaping BridgePaneProductFileSourceAcceptedObserver
    ) {
        sourceAcceptedObserver = observer
    }

    func captureKeyedSnapshot(
        subscriptionId: String,
        demand: BridgePaneProductFileViewDemand,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? {
        guard let context = contextBySubscriptionId[subscriptionId],
            context.viewDemand == demand,
            context.productAdmission.matches(productAdmission),
            productAdmission.withValidAdmission({ true }) == true
        else { return nil }
        let snapshot = await context.manifestIndex.captureKeyedSnapshot()
        guard let current = contextBySubscriptionId[subscriptionId],
            current.productSource == context.productSource,
            current.viewDemand == demand,
            current.demandGeneration == context.demandGeneration,
            current.productAdmission.matches(productAdmission),
            productAdmission.withValidAdmission({ true }) == true
        else { return nil }
        guard !current.canonicalPathScope.isEmpty else { return snapshot }
        let canonicalRootURL = authority.worktree.path.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRanges = current.canonicalPathScope.map {
            canonicalRootURL.appending(path: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return .init(
            isEnumerationComplete: snapshot.isEnumerationComplete,
            memberStatus: snapshot.memberStatus,
            records: snapshot.records.filter {
                Self.isWithinPathScope($0.row.path, scope: current.canonicalPathScope)
            },
            targetRevision: snapshot.targetRevision,
            tombstoneRevisionByKey: snapshot.tombstoneRevisionByKey.filter {
                Self.isWithinPathScope($0.key, scope: canonicalRanges)
            },
            absenceFloorRevisionByRange: snapshot.absenceFloorRevisionByRange.filter { entry in
                Self.isWithinPathScope(entry.key, scope: canonicalRanges)
                    || canonicalRanges.contains {
                        Self.isWithinPathScope($0, scope: [entry.key])
                    }
            }
        )
    }

    func currentWorktreeAnnotationFingerprint(
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSourceFingerprint {
        try await worktreeAnnotationFingerprintImplementation(productAdmission: productAdmission)
    }

    func currentWorktreeAnnotationSourceGeneration(
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> Int {
        try await worktreeAnnotationSourceGenerationImplementation(productAdmission: productAdmission)
    }

    func currentWorktreeAnnotationRefresh(
        requirements: [WorktreeAnnotationSourceRefreshRequirement],
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationSourceRefreshCapture {
        try await worktreeAnnotationRefreshImplementation(
            requirements: requirements,
            productAdmission: productAdmission
        )
    }

    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        try Task.checkCancellation()
        guard let sourceSpec = subscription.subscription.fileMetadataSource else {
            return
        }
        await cancel(subscriptionId: subscription.subscriptionId)
        try Task.checkCancellation()
        guard
            let context = try installContext(
                subscription: subscription,
                sourceSpec: sourceSpec,
                pathScope: [],
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else { return }
        let productSource = context.productSource
        let retainsInstalledContext: Bool
        do {
            retainsInstalledContext = try await bootstrapInstalledContext(
                .init(
                    context: context,
                    emit: emit,
                    foregroundWorkAdmission: foregroundWorkAdmission,
                    pathScope: [],
                    productAdmission: productAdmission,
                    productSource: productSource,
                    sourceSpec: sourceSpec,
                    subscription: subscription
                )
            )
        } catch {
            await releaseContext(
                subscriptionId: subscription.subscriptionId,
                expectedSource: productSource
            )
            throw error
        }
        guard retainsInstalledContext else {
            await releaseContext(
                subscriptionId: subscription.subscriptionId,
                expectedSource: productSource
            )
            return
        }
    }

    func publish(
        status: GitWorkingTreeStatus,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async -> [BridgePaneProductFileMetadataEmission] {
        var emissions: [BridgePaneProductFileMetadataEmission] = []
        for subscriptionId in contextBySubscriptionId.keys.sorted() {
            if deferFileChanges(
                subscriptionId: subscriptionId, changedPaths: [], statusResult: .available(status),
                productAdmission: productAdmission, foregroundWorkAdmission: foregroundWorkAdmission)
            {
                continue
            }
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true,
                productAdmission.withValidAdmission({ true }) == true,
                let context = contextBySubscriptionId[subscriptionId],
                let sourceSpec = context.subscription.subscription.fileMetadataSource,
                context.productAdmission.matches(productAdmission),
                sourceSpec.includeStatuses,
                (try? await context.manifestIndex.updateMemberStatus(
                    state: .ready,
                    branchName: status.branch,
                    ahead: status.summary.aheadCount,
                    behind: status.summary.behindCount,
                    staged: status.summary.staged,
                    unstaged: status.summary.changed,
                    untracked: status.summary.untracked,
                    productAdmission: productAdmission
                )) == true
            else { continue }
            emissions.append(
                .init(
                    fact: .statusChanged(context.productSource),
                    subscriptionId: subscriptionId
                )
            )
        }
        return emissions
    }

    func isCurrent(
        subscriptionId: String,
        demand: BridgePaneProductFileViewDemand,
        demandGeneration: Int,
        source: BridgeProductFileSourceIdentity,
        productAdmission: BridgeProductAdmissionContext
    ) -> Bool {
        guard let context = contextBySubscriptionId[subscriptionId] else { return false }
        return context.productSource == source
            && context.productAdmission.matches(productAdmission)
            && context.viewDemand == demand
            && context.demandGeneration == demandGeneration
    }

    private func installContext(
        subscription: BridgeProductSubscriptionSnapshot,
        sourceSpec: BridgeProductFileSourceSpec,
        pathScope: [String],
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) throws -> SubscriptionContext? {
        let sourceGeneration = nextSourceGeneration + 1
        let legacySourceSpec = try BridgePaneProductFileMetadataEncoding.legacySourceSpec(
            sourceSpec: sourceSpec,
            subscriptionId: subscription.subscriptionId,
            pathScope: pathScope
        )
        let openedSource = try BridgeWorktreeFileSourceProvider.openSource(
            spec: legacySourceSpec,
            worktree: authority.worktree,
            paneIdentity: authority.paneId,
            subscriptionGeneration: sourceGeneration
        )
        let productSource = try BridgeProductFileSourceIdentity(
            repoId: openedSource.source.repoId,
            rootRevisionToken: openedSource.source.rootRevisionToken,
            sourceCursor: openedSource.source.sourceCursor,
            sourceId: openedSource.source.sourceId,
            subscriptionGeneration: openedSource.source.subscriptionGeneration,
            worktreeId: openedSource.source.worktreeId
        )
        let context = SubscriptionContext(
            manifestIndex: .init(
                generation: sourceGeneration,
                rootURL: authority.worktree.path,
                productAdmission: productAdmission,
                source: productSource,
                initialRevision: lastIssuedFileViewRevision + 1
            ),
            openedSource: openedSource,
            constructionLease: nil,
            productAdmission: productAdmission,
            productSource: productSource,
            descriptorByPath: [:],
            descriptorInterestRevisionByPath: [:],
            inFlightDescriptorInterestRevisionByPath: [:],
            subscription: subscription,
            viewDemand: nil,
            canonicalPathScope: [],
            demandGeneration: 0
        )
        return foregroundWorkAdmission.withValidAdmission {
            productAdmission.withValidAdmission {
                nextSourceGeneration = sourceGeneration
                contextBySubscriptionId[subscription.subscriptionId] = context
                return context
            }
        }.flatMap { $0 }
    }

    private func clearInFlightDescriptorInterest(
        path: String,
        revision: Int,
        subscriptionId: String,
        source: BridgeProductFileSourceIdentity
    ) {
        guard var context = contextBySubscriptionId[subscriptionId],
            context.productSource == source,
            context.inFlightDescriptorInterestRevisionByPath[path] == revision
        else { return }
        context.inFlightDescriptorInterestRevisionByPath.removeValue(forKey: path)
        contextBySubscriptionId[subscriptionId] = context
    }

    static func isWithinPathScope(_ path: String, scope: [String]) -> Bool {
        scope.contains { scopedPath in
            scopedPath == "." || path == scopedPath || path.hasPrefix("\(scopedPath)/")
        }
    }

}

extension BridgePaneProductFileMetadataSource {

    func reconcileDescriptor(
        _ row: BridgeWorktreeTreeRowMetadata,
        request: DescriptorReconciliationRequest
    ) async throws -> Bool {
        guard reserveDescriptorInterest(for: row, request: request) else { return false }
        guard let context = contextBySubscriptionId[request.subscriptionId],
            context.productSource == request.productSource,
            let attempt = await context.manifestIndex.reserveDescriptorAttempt(
                for: row.path,
                source: request.productSource,
                memberIncarnation: BridgeProductViewDomain.singleDomain.rawValue,
                interestRevision: request.demandGeneration,
                productAdmission: request.productAdmission,
                foregroundWorkAdmission: request.foregroundWorkAdmission
            )
        else {
            clearInFlightDescriptorInterest(
                path: row.path,
                revision: request.demandGeneration,
                subscriptionId: request.subscriptionId,
                source: request.productSource
            )
            return false
        }
        let materialized: BridgePaneProductFileDescriptorMaterialization
        do {
            materialized = try await descriptorMaterializer(
                .init(
                    relativePath: row.path,
                    rootURL: authority.worktree.path,
                    row: row,
                    source: request.productSource
                )
            )
        } catch {
            clearInFlightDescriptorInterest(
                path: row.path,
                revision: request.demandGeneration,
                subscriptionId: request.subscriptionId,
                source: request.productSource
            )
            throw error
        }
        guard !Task.isCancelled else {
            clearInFlightDescriptorInterest(
                path: row.path,
                revision: request.demandGeneration,
                subscriptionId: request.subscriptionId,
                source: request.productSource
            )
            throw CancellationError()
        }
        guard descriptorInterestIsAdmitted(for: row, request: request) else {
            clearInFlightDescriptorInterest(
                path: row.path,
                revision: request.demandGeneration,
                subscriptionId: request.subscriptionId,
                source: request.productSource
            )
            return false
        }
        guard await context.manifestIndex.acceptDescriptorOutcome(materialized.payload, for: attempt)
        else {
            clearInFlightDescriptorInterest(
                path: row.path,
                revision: request.demandGeneration,
                subscriptionId: request.subscriptionId,
                source: request.productSource
            )
            return false
        }
        guard let commit = commitDescriptorInterest(materialized, for: row, request: request)
        else {
            clearInFlightDescriptorInterest(
                path: row.path,
                revision: request.demandGeneration,
                subscriptionId: request.subscriptionId,
                source: request.productSource
            )
            return false
        }
        do {
            try await request.emit(.descriptorReady(materialized.payload))
        } catch {
            rollbackDescriptorInterest(commit, for: row, request: request)
            throw error
        }
        guard descriptorInterestCommitIsCurrent(commit, for: row, request: request) else {
            rollbackDescriptorInterest(commit, for: row, request: request)
            return false
        }
        return true
    }

    fileprivate func reserveDescriptorInterest(
        for row: BridgeWorktreeTreeRowMetadata,
        request: DescriptorReconciliationRequest
    ) -> Bool {
        request.foregroundWorkAdmission.withValidAdmission({
            request.productAdmission.withValidAdmission {
                guard var currentContext = contextBySubscriptionId[request.subscriptionId],
                    currentContext.productSource == request.productSource,
                    currentContext.productAdmission.matches(request.productAdmission),
                    currentContext.viewDemand == request.demand,
                    currentContext.demandGeneration == request.demandGeneration,
                    currentContext.descriptorInterestRevisionByPath[row.path]
                        != request.demandGeneration,
                    currentContext.inFlightDescriptorInterestRevisionByPath[row.path]
                        != request.demandGeneration
                else { return false }
                currentContext.inFlightDescriptorInterestRevisionByPath[row.path] =
                    request.demandGeneration
                contextBySubscriptionId[request.subscriptionId] = currentContext
                return true
            } ?? false
        }) == true
    }

    fileprivate func descriptorInterestIsAdmitted(
        for row: BridgeWorktreeTreeRowMetadata,
        request: DescriptorReconciliationRequest
    ) -> Bool {
        request.foregroundWorkAdmission.withValidAdmission({
            request.productAdmission.withValidAdmission {
                guard let currentContext = contextBySubscriptionId[request.subscriptionId],
                    currentContext.productSource == request.productSource,
                    currentContext.productAdmission.matches(request.productAdmission),
                    currentContext.viewDemand == request.demand,
                    currentContext.demandGeneration == request.demandGeneration,
                    currentContext.inFlightDescriptorInterestRevisionByPath[row.path]
                        == request.demandGeneration
                else { return false }
                return true
            } ?? false
        }) == true
    }

}
